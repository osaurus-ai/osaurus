//
//  TranscriptionCleanupService.swift
//  osaurus
//
//  Runs raw voice transcription through the local LLM to remove filler words
//  and fix punctuation. Always falls back to the raw text on any failure so
//  we never lose the user's words.
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.osaurus", category: "transcription_cleanup")

@MainActor
public final class TranscriptionCleanupService {
    public static let shared = TranscriptionCleanupService()

    private static let systemPrompt = """
        You clean up voice-to-text transcripts. Remove only non-lexical hesitation \
        sounds: "uh", "um", "uhh", "umm", "mm", "mmm", "er", "erm", "ah", "hmm" when \
        they appear as standalone fillers. Also remove stuttered word repetitions \
        (e.g. "I I went" → "I went") and immediate self-corrections (e.g. "go to — \
        I mean visit the store" → "visit the store"). Fix punctuation and \
        capitalization. Do NOT remove real words like "like", "you know", "I mean", \
        "so", "well", "right", "actually" — these can carry meaning and the speaker \
        may have intended them. Preserve the speaker's wording and meaning exactly \
        — do not paraphrase, summarize, rephrase, or add content. Return only the \
        cleaned transcript with no preamble, quotes, or commentary.
        """

    private static let minWordsForCleanup = 3
    private static let minHallucinationRatio: Double = 0.3
    private static let cleanupTimeout: TimeInterval = 10

    private init() {}

    /// Cleans `rawText` via a local LLM. Always returns a usable string —
    /// falls back to `rawText` on short input, no local model available,
    /// timeout, error, or suspiciously short output.
    public func clean(_ rawText: String) async -> String {
        debugLog("[cleanup] --- clean() called ---")
        debugLog("[cleanup] RAW input (\(rawText.count) chars): \(rawText)")

        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = trimmed.split(separator: " ").count
        guard wordCount >= Self.minWordsForCleanup else {
            debugLog("[cleanup] SKIP: too short (\(wordCount) words < \(Self.minWordsForCleanup))")
            return rawText
        }

        // wrap input in a delimiter so the model treats it as data not instructions
        let userPrompt = """
            Clean up the following transcript. Return only the cleaned text.

            <transcript>
            \(trimmed)
            </transcript>
            """

        // try the user's configured core model first.
        let coreModelId = ChatConfigurationStore.load().coreModelIdentifier ?? "<nil>"
        debugLog("[cleanup] Trying core model: \(coreModelId)")
        let start = Date()
        do {
            let response = try await CoreModelService.shared.generate(
                prompt: userPrompt,
                systemPrompt: Self.systemPrompt,
                temperature: 0.1,
                maxTokens: max(256, trimmed.count),
                timeout: Self.cleanupTimeout,
                // Tidying a voice transcript is never worth evicting the model
                // the user is chatting with. Declined → we keep the raw text.
                intent: .background
            )
            return postProcess(response: response, rawText: rawText, trimmed: trimmed, start: start, source: "core")
        } catch CoreModelError.modelUnavailable(let requested) {
            debugLog("[cleanup] Core model unavailable (\(requested)); trying local MLX fallback")
            return await tryLocalFallback(userPrompt: userPrompt, rawText: rawText, trimmed: trimmed)
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            debugLog(
                "[cleanup] ERROR after \(String(format: "%.2f", elapsed))s: \(error.localizedDescription) — using raw"
            )
            return rawText
        }
    }

    // MARK: - Local MLX fallback

    /// Pick a model this fallback may use without disturbing the user.
    ///
    /// This path used to take `installed.first` — an arbitrary model, chosen by
    /// install order. Under the strict single-model runtime that loads it and
    /// **evicts whatever the user is chatting with**, to clean up a voice
    /// transcript. So: prefer a model that is already resident (free, no load),
    /// accept any installed model when the runtime is idle, and otherwise
    /// decline — a tidier transcript is not worth the user's model.
    private func backgroundSafeModel(from installed: [String]) async -> String? {
        guard !installed.isEmpty else { return nil }

        let resident = await ModelRuntime.shared.residentModelNames()
        if let alreadyLoaded = installed.first(where: { candidate in
            let tail = candidate.split(separator: "/").last.map(String.init) ?? candidate
            return resident.contains {
                $0.caseInsensitiveCompare(candidate) == .orderedSame
                    || $0.caseInsensitiveCompare(tail) == .orderedSame
            }
        }) {
            return alreadyLoaded
        }

        // Nothing of ours is resident. Only fill a genuinely empty slot, and
        // never race a load the user is waiting on.
        if await ModelRuntime.shared.hasLoadInFlight() { return nil }
        if !resident.isEmpty { return nil }
        return installed.first
    }

    private func tryLocalFallback(userPrompt: String, rawText: String, trimmed: String) async -> String {
        let installed = MLXService.getAvailableModels()
        guard let fallbackModel = await backgroundSafeModel(from: installed) else {
            debugLog("[cleanup] FALLBACK: no background-safe local model, using raw")
            return rawText
        }
        debugLog("[cleanup] Local fallback model: \(fallbackModel)")

        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: Self.systemPrompt),
            ChatMessage(role: "user", content: userPrompt),
        ]
        // This fallback bypasses `CoreModelService` and calls `MLXService`
        // directly, so it has to declare its own intent: tidying a voice
        // transcript is never worth evicting the model someone is chatting with.
        // `backgroundSafeModel` above still picks well (prefer resident, accept
        // an idle runtime), but it is a heuristic on a stale snapshot — this is
        // the guard the runtime actually enforces, at the eviction itself.
        let params = GenerationParameters(
            temperature: 0.1,
            maxTokens: max(256, trimmed.count),
            loadIntent: .background
        )

        let start = Date()
        do {
            let response = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await MLXService.shared.generateOneShot(
                        messages: messages,
                        parameters: params,
                        requestedModel: fallbackModel
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(Self.cleanupTimeout))
                    throw CoreModelError.timedOut
                }
                let first = try await group.next() ?? ""
                group.cancelAll()
                return first
            }
            return postProcess(response: response, rawText: rawText, trimmed: trimmed, start: start, source: "mlx")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            debugLog(
                "[cleanup] FALLBACK ERROR after \(String(format: "%.2f", elapsed))s: \(error.localizedDescription) — using raw"
            )
            return rawText
        }
    }

    // MARK: - Shared post-processing

    private func postProcess(response: String, rawText: String, trimmed: String, start: Date, source: String) -> String
    {
        let elapsed = Date().timeIntervalSince(start)
        debugLog(
            "[cleanup] \(source) response in \(String(format: "%.2f", elapsed))s (\(response.count) chars): \(response)"
        )

        // strip streaming sentinel (\u{FFFE}) and anything that follows — MLX emits
        // trailing metadata like "\u{FFFE}stats:28;44.0129" after the actual text.
        let stripped: String
        if let sentinelRange = response.range(of: "\u{FFFE}") {
            stripped = String(response[..<sentinelRange.lowerBound])
        } else {
            stripped = response
        }

        let cleaned = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            debugLog("[cleanup] FALLBACK: empty response, using raw")
            return rawText
        }
        if trimmed.count > 50,
            Double(cleaned.count) / Double(trimmed.count) < Self.minHallucinationRatio
        {
            debugLog(
                "[cleanup] FALLBACK: hallucination guard (cleaned \(cleaned.count) / raw \(trimmed.count) = \(String(format: "%.2f", Double(cleaned.count) / Double(trimmed.count)))), using raw"
            )
            return rawText
        }
        debugLog("[cleanup] SUCCESS (\(source)): returning cleaned text")
        return cleaned
    }
}
