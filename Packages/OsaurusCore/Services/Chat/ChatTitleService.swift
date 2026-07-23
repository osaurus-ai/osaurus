//
//  ChatTitleService.swift
//  osaurus
//
//  Generates a short descriptive chat title from the first user/assistant
//  exchange. Routes through `CoreModelService` with `.background` intent so
//  a title is never worth evicting the user's resident chat model, and with
//  the active chat model as a fallback per issue #823. All failures are
//  silent — the caller keeps the first-message preview title.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.osaurus", category: "core_model")

public actor ChatTitleService {
    public static let shared = ChatTitleService()

    /// Clips applied to the exchange before prompting. The model only needs
    /// enough of each side to name the topic; keeping the prompt bounded
    /// protects tiny Core Models' context windows and keeps the timeout real.
    private static let maxUserChars = 600
    private static let maxAssistantChars = 800
    /// A title is a handful of words; anything past this budget is the model
    /// rambling, and `sanitize` would clamp it away regardless.
    private static let maxTokens = 24
    private static let timeout: TimeInterval = 8
    /// Low temperature: we want the obvious topic, not a creative one.
    private static let temperature: Double = 0.2
    /// Display caps aligned with `ChatSessionData.generateTitle`'s 50-char
    /// preview so a generated title never renders longer than the fallback.
    static let maxTitleChars = 50
    static let maxTitleWords = 8

    private init() {}

    /// Generate a sanitized title for the first exchange of a chat.
    /// Returns nil on any failure, timeout, or quality miss — the caller
    /// keeps the preview title it already set.
    public func generateTitle(
        userMessage: String,
        assistantResponse: String,
        fallbackModel: String?
    ) async -> String? {
        let user = Self.clip(
            userMessage.trimmingCharacters(in: .whitespacesAndNewlines),
            to: Self.maxUserChars
        )
        let assistant = Self.clip(
            assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines),
            to: Self.maxAssistantChars
        )
        guard !user.isEmpty else { return nil }

        let systemPrompt = """
            You name chat conversations. Given the first exchange of a conversation, \
            reply with ONLY a title of 3 to 6 words that captures its topic. Write the \
            title in the same language as the conversation. No quotes, no trailing \
            punctuation, no emoji, no markdown, no explanations.
            """
        let prompt = """
            User message:
            \(user)

            Assistant response:
            \(assistant)

            Title:
            """

        #if DEBUG
            AutoTitleDebugLog.log(
                "service start user=\(user.count)ch assistant=\(assistant.count)ch fallback=\(fallbackModel ?? "nil")"
            )
            let startedAt = Date()
        #endif
        do {
            let raw = try await CoreModelService.shared.generate(
                prompt: prompt,
                systemPrompt: systemPrompt,
                temperature: Self.temperature,
                maxTokens: Self.maxTokens,
                timeout: Self.timeout,
                fallbackModel: fallbackModel,
                // A title is a nicety: never load/evict a model for it. When
                // no model is resident the call fails fast and the preview
                // title stands.
                intent: .background
            )
            let sanitized = Self.sanitize(raw)
            #if DEBUG
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                AutoTitleDebugLog.log(
                    "service done in \(elapsedMs)ms raw=\"\(raw.prefix(120))\" sanitized=\(sanitized.map { "\"\($0)\"" } ?? "REJECTED")"
                )
            #endif
            return sanitized
        } catch {
            #if DEBUG
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                AutoTitleDebugLog.log(
                    "service ERROR in \(elapsedMs)ms: \(error.localizedDescription)"
                )
            #endif
            logger.info("auto title: generation failed silently: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Sanitization

    /// Normalize a raw model completion into a sidebar-ready title, or nil
    /// when the output isn't usable. Pure function so tests can pin the
    /// contract without spinning up `CoreModelService`.
    static func sanitize(_ raw: String) -> String? {
        // First non-empty line only — chatty models sometimes append an
        // explanation on a second line despite the contract.
        guard
            var title = raw
                .components(separatedBy: .newlines)
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty })
        else { return nil }

        // Drop a leading "Title:" label some models echo back.
        if let range = title.range(of: #"^\s*title\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            title.removeSubrange(range)
        }

        // Strip markdown emphasis / heading noise and wrapping quotes.
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "#*_`"))
        title = title.trimmingCharacters(in: Self.wrappingQuoteCharacters)
        // Trailing sentence punctuation reads wrong on a title.
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = title.last, Self.trailingPunctuation.contains(last) {
            title.removeLast()
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !title.isEmpty else { return nil }
        // Structural characters mean the model leaked markup/JSON — the same
        // corruption signal the greeting service gates on. Reject outright
        // rather than salvage.
        if title.contains(where: { "<>{}|".contains($0) }) { return nil }

        // Word cap first (drops trailing words wholesale), then a
        // word-boundary character clamp matching the preview title's length.
        let words = title.split(separator: " ", omittingEmptySubsequences: true)
        title = words.prefix(Self.maxTitleWords).joined(separator: " ")
        if title.count > Self.maxTitleChars {
            var clamped = ""
            for word in title.split(separator: " ", omittingEmptySubsequences: true) {
                let candidate = clamped.isEmpty ? String(word) : clamped + " " + word
                if candidate.count > Self.maxTitleChars { break }
                clamped = candidate
            }
            // A single over-budget token falls back to a hard prefix.
            title = clamped.isEmpty ? String(title.prefix(Self.maxTitleChars)) : clamped
        }

        return title.isEmpty ? nil : title
    }

    private static let wrappingQuoteCharacters = CharacterSet(charactersIn: "\"'“”‘’«»")
    private static let trailingPunctuation: Set<Character> = [".", "!", "?", "…", ",", ";", ":", "。", "！", "？"]

    /// Truncate a string at a character budget, appending an ellipsis when
    /// content is dropped so the model knows there was more.
    private static func clip(_ text: String, to limit: Int) -> String {
        if text.count <= limit { return text }
        let endIndex = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<endIndex]) + "…"
    }
}
