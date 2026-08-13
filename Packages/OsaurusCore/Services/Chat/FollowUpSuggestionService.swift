//
//  FollowUpSuggestionService.swift
//  osaurus
//
//  Proposes a few next questions the user might ask after a chat turn
//  completes, rendered as clickable rows beneath the assistant response.
//  Routes through `CoreModelService` with `.background` intent so a set of
//  suggestions is never worth evicting the user's resident chat model, and
//  with the active chat model as a fallback — the same resolution order and
//  silent-failure contract as `ChatTitleService`. All failures are silent:
//  the caller simply renders no suggestions.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.osaurus", category: "core_model")

public actor FollowUpSuggestionService {
    public static let shared = FollowUpSuggestionService()

    /// Clips applied to the exchange before prompting. The model only needs
    /// enough of each side to propose plausible next questions; keeping the
    /// prompt bounded protects tiny Core Models' context windows and keeps the
    /// timeout real (mirrors `ChatTitleService`).
    private static let maxUserChars = 800
    private static let maxAssistantChars = 1_600
    /// A handful of short questions. Budget headroom covers a thinking model
    /// that reasons before answering — reasoning deltas are sentinel-stripped
    /// by `generateOneShot`, so every reasoning token spends budget while
    /// producing no visible text. Thinking is explicitly disabled below; this
    /// covers models whose profile has no thinking toggle.
    private static let maxTokens = 256
    /// Longer than the title timeout: the request explicitly expects follow-up
    /// generation to run anywhere from a few seconds up to ~30s on small,
    /// remote models. This is background work the user isn't blocked on.
    private static let timeout: TimeInterval = 30
    /// A little warmth so the four suggestions aren't near-duplicates, but not
    /// so much that they wander off-topic.
    private static let temperature: Double = 0.4

    /// How many suggestions we ask for and, at most, return. Four matches the
    /// reference design (Open WebUI) and the attached mock.
    static let suggestionCount = 4
    /// Reject a suggestion longer than this — a runaway line means the model
    /// leaked prose instead of a question, and a giant row breaks the layout.
    static let maxSuggestionChars = 160

    private init() {}

    /// Generate follow-up question suggestions for a completed exchange.
    /// Returns an empty array on any failure, timeout, or quality miss — the
    /// caller renders nothing.
    /// - Parameter modelOverride: When non-empty, generation runs on this model
    ///   instead of the shared core model (per-agent
    ///   `AgentFollowUpConfig.modelIdentifier`). This is the only per-agent
    ///   lever by design: routing to a separate model keeps follow-up
    ///   generation off the resident chat model, so the chat's KV cache prefix
    ///   is never evicted. The suggester system prompt is fixed for the same
    ///   reason — a per-agent prompt would vary the prefill prefix.
    public func generateSuggestions(
        userMessage: String,
        assistantResponse: String,
        fallbackModel: String?,
        modelOverride: String? = nil
    ) async -> [String] {
        let user = Self.clip(
            userMessage.trimmingCharacters(in: .whitespacesAndNewlines),
            to: Self.maxUserChars
        )
        let assistant = Self.clip(
            assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines),
            to: Self.maxAssistantChars
        )
        // No assistant answer means there's nothing to build on.
        guard !assistant.isEmpty else { return [] }

        // Fixed suggester prompt (never per-agent): a varying prompt would
        // change the prefill prefix and evict the chat model's KV cache when
        // generation falls back to it.
        let systemPrompt = """
            You suggest follow-up questions for a conversation. Given the last \
            exchange, propose exactly \(Self.suggestionCount) short, specific \
            questions the user might naturally ask next to explore the topic \
            further. Write each question in the same language as the \
            conversation, from the user's point of view, as if they were typing \
            it. Return ONLY a JSON array of strings and nothing else — no \
            numbering, no markdown, no commentary. Example: \
            ["First question?", "Second question?"]
            """
        let prompt = """
            User message:
            \(user)

            Assistant response:
            \(assistant)

            Follow-up questions (JSON array):
            """

        // Disable thinking for the model that will actually serve the call
        // (the configured core model, else the chat-model fallback — same
        // resolution order as `CoreModelService.generate`). A reasoning
        // preamble is pure waste here: it burns the token budget on
        // sentinel-stripped output. `thinkingStoredOption` is the canonical
        // semantic→stored conversion so inverted options can't flip the wrong
        // way. Models without a thinking toggle just send no option.
        let coreModelIdentifier = await MainActor.run {
            AppConfiguration.shared.chatConfig.coreModelIdentifier
        }
        // Resolution order matches CoreModelService: per-agent override first,
        // then the shared core model, then the chat-model fallback.
        let trimmedOverrideModel = modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let servingModelId =
            (trimmedOverrideModel?.isEmpty == false ? trimmedOverrideModel : nil)
            ?? coreModelIdentifier ?? fallbackModel
        var modelOptions: [String: ModelOptionValue] = [:]
        if let servingModelId,
            let stored = ModelProfileRegistry.thinkingStoredOption(
                for: servingModelId,
                enabled: false
            )
        {
            modelOptions[stored.id] = stored.value
        }

        do {
            let raw = try await CoreModelService.shared.generate(
                prompt: prompt,
                systemPrompt: systemPrompt,
                temperature: Self.temperature,
                maxTokens: Self.maxTokens,
                timeout: Self.timeout,
                fallbackModel: fallbackModel,
                // Follow-ups are a nicety: never load/evict a model for them.
                // When no model is resident the call fails fast and we render
                // nothing.
                intent: .background,
                modelOverride: modelOverride,
                modelOptions: modelOptions
            )
            return Self.parse(raw)
        } catch {
            logger.info(
                "follow-up suggestions: generation failed silently: \(error.localizedDescription)"
            )
            return []
        }
    }

    // MARK: - Parsing

    /// Normalize a raw model completion into clean suggestion strings, or an
    /// empty array when the output isn't usable. Pure function so tests can
    /// pin the contract without spinning up `CoreModelService`. Tolerant of
    /// the common small-model deviations: a JSON array wrapped in prose, a
    /// fenced code block, or a plain newline / numbered list.
    static func parse(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let candidates = parseJSONArray(trimmed) ?? parseLineList(trimmed)

        var seen = Set<String>()
        var result: [String] = []
        for candidate in candidates {
            guard let cleaned = sanitizeSuggestion(candidate) else { continue }
            // Case-insensitive dedupe: small models love to rephrase the same
            // question twice.
            let key = cleaned.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(cleaned)
            if result.count == suggestionCount { break }
        }
        return result
    }

    /// Extract a JSON string array from the first `[` … `]` span in the text,
    /// tolerating a prose preamble or a ```json fence around it. Returns nil
    /// when there's no array to decode so the caller can fall back to the
    /// line-list parser.
    private static func parseJSONArray(_ text: String) -> [String]? {
        guard
            let start = text.firstIndex(of: "["),
            let end = text.lastIndex(of: "]"),
            start < end
        else { return nil }
        let slice = String(text[start...end])
        guard
            let data = slice.data(using: .utf8),
            let array = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        return array
    }

    /// Fallback parser for models that ignore the JSON contract and emit a
    /// plain list — one question per line, optionally bulleted or numbered.
    private static func parseLineList(_ text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Clean a single raw suggestion into a display-ready question, or nil when
    /// it isn't usable (empty, structural leakage, over budget).
    private static func sanitizeSuggestion(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip a leading list marker: "- ", "* ", "1. ", "1) ".
        if let range = text.range(
            of: #"^\s*(?:[-*•]|\d+[.)])\s+"#,
            options: [.regularExpression]
        ) {
            text.removeSubrange(range)
        }

        // Drop wrapping quotes and stray markdown emphasis.
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "#*_`"))
        text = text.trimmingCharacters(in: wrappingQuoteCharacters)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { return nil }
        // Structural characters mean the model leaked markup/JSON — reject
        // rather than salvage (same signal `ChatTitleService` gates on).
        if text.contains(where: { "<>{}|".contains($0) }) { return nil }
        // A suggestion is a single question; a very long line is leaked prose.
        if text.count > maxSuggestionChars { return nil }
        return text
    }

    private static let wrappingQuoteCharacters = CharacterSet(charactersIn: "\"'“”‘’«»")

    /// Truncate a string at a character budget, appending an ellipsis when
    /// content is dropped so the model knows there was more.
    private static func clip(_ text: String, to limit: Int) -> String {
        if text.count <= limit { return text }
        let endIndex = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<endIndex]) + "…"
    }
}
