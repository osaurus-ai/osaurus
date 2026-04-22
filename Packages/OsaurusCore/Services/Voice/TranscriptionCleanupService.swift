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
            )
            return postProcess(response: response, rawText: rawText, trimmed: trimmed, start: start, source: "core")
        } catch CoreModelError.modelUnavailable(let requested) {
            debugLog("[cleanup] Core model unavailable (\(requested)); trying local MLX fallback")
            return await tryLocalFallback(userPrompt: userPrompt, rawText: rawText, trimmed: trimmed)
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            debugLog("[cleanup] ERROR after \(String(format: "%.2f", elapsed))s: \(error.localizedDescription) — using raw")
            return rawText
        }
    }

    // MARK: - Local MLX fallback

    private func tryLocalFallback(userPrompt: String, rawText: String, trimmed: String) async -> String {
        let installed = MLXService.getAvailableModels()
        guard let fallbackModel = installed.first else {
            debugLog("[cleanup] FALLBACK: no local MLX models installed, using raw")
            return rawText
        }
        debugLog("[cleanup] Local fallback model: \(fallbackModel)")

        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: Self.systemPrompt),
            ChatMessage(role: "user", content: userPrompt),
        ]
        let params = GenerationParameters(
            temperature: 0.1,
            maxTokens: max(256, trimmed.count),
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
            debugLog("[cleanup] FALLBACK ERROR after \(String(format: "%.2f", elapsed))s: \(error.localizedDescription) — using raw")
            return rawText
        }
    }

    // MARK: - Shared post-processing

    private func postProcess(response: String, rawText: String, trimmed: String, start: Date, source: String) -> String {
        let elapsed = Date().timeIntervalSince(start)
        debugLog("[cleanup] \(source) response in \(String(format: "%.2f", elapsed))s (\(response.count) chars): \(response)")

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
            debugLog("[cleanup] FALLBACK: hallucination guard (cleaned \(cleaned.count) / raw \(trimmed.count) = \(String(format: "%.2f", Double(cleaned.count) / Double(trimmed.count)))), using raw")
            return rawText
        }
        debugLog("[cleanup] SUCCESS (\(source)): returning cleaned text")
        return cleaned
    }
}
