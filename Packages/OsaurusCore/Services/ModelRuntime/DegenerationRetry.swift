//
//  DegenerationRetry.swift
//  osaurus
//
//  Caller-side retry-once-with-safe-settings for generation streams aborted
//  by `StreamGuardrailError.degeneration` (the live guardrail in
//  StreamDegenerationDetector.swift / GenerationEventMapper.swift). Composed
//  by `ModelRuntime.streamWithTools` / `respondWithTools` between
//  `generateEventStream` and their consumption loops, turning the dominant
//  detected-loop case into a hiccup instead of a hard error.
//
//  ## Retry-eligibility rule (read this before changing anything)
//
//  Full transparency after a mid-stream abort is IMPOSSIBLE: the detector
//  fires only after ~8 repeats, so by trigger time the consumer has already
//  received several repeats of the loop on whatever channel it ran on.
//  Deltas cannot be un-yielded. So the retry is attempted ONLY when the
//  abort happens BEFORE any content-bearing event has been forwarded to the
//  outer stream:
//
//    - content-bearing (blocks retry once forwarded): `.tokens`,
//      `.toolInvocation`, `.toolCallProgress` — retrying after any of these
//      would replay/append answer text or double-dispatch a tool call;
//    - NOT content-bearing (retry stays eligible): `.reasoning`,
//      `.prefillProgress` — the thinking channel is presentation-only
//      (ChatView Think panel / `reasoning_content`), so a second attempt's
//      reasoning appearing after the first attempt's truncated reasoning is
//      honest "the model started over" UX, not corrupted output.
//
//  This deliberately covers exactly the dominant real-world case — loops
//  that start inside the thinking channel (the documented `!!!!!…` inside
//  reasoning) or within the very first content delta (which the mapper never
//  yields when it triggers the abort) — and propagates the error unchanged,
//  as before, whenever loop text has already reached the consumer.
//
//  One retry maximum: a second degeneration propagates.
//
//  ## Safe settings for attempt 2
//
//  Greedy/low-temperature decoding is what gets stuck in deterministic
//  loops, so the retry re-runs with sampling forced on:
//    - temperature: max(effective, 0.7),
//    - repetitionPenalty: 1.1 when the request set none,
//    - draft strategy disabled for the attempt (native MTP self-drafting is
//      tuned for greedy decode; `generateEventStream(disableDraftStrategy:)`
//      drops it before `MLXBatchAdapter.generate`).
//
//  The retried attempt naturally re-runs prefill, but the vmlx prefix cache
//  makes that cheap: attempt 1 already stored the prompt's KV prefix, so
//  attempt 2 restores it instead of re-prefilling from scratch.
//

import Foundation
import MLXLMCommon
import os.log

private let retryLog = Logger(subsystem: "ai.osaurus", category: "Generation")

enum DegenerationRetry {
    /// UserDefaults key: `Bool`, default true. When off, a degeneration
    /// abort propagates immediately exactly as before this policy existed.
    static let flagKey = "ai.osaurus.guardrails.degenerationRetry"

    /// Sampling floor for attempt 2 — greedy loops break under sampling.
    static let retryTemperatureFloor: Float = 0.7
    /// Applied on attempt 2 when the request carried no repetition penalty.
    static let retryRepetitionPenalty: Float = 1.1

    /// Read the flag, treating an absent key as ON. Injectable defaults for
    /// tests (same pattern as `StreamGuardrailSettings.resolve`).
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: flagKey) as? Bool ?? true
    }

    // MARK: - Safe settings

    /// Rebuild the request parameters for the retry attempt: temperature
    /// raised to at least `retryTemperatureFloor` (measured against the same
    /// per-request → model-shipped-default resolution the adapter uses, so
    /// an already-hot request is never cooled down), a mild repetition
    /// penalty when none was set, and `samplingParametersAreImplicit` forced
    /// false — the retry explicitly chooses sampling, and acceleration paths
    /// must honor it rather than rewrite it (this also disqualifies native
    /// MTP's explicit-greedy gate independently of the draft-strategy knob).
    ///
    /// Server runtime defaults are deliberately not consulted here: they sit
    /// below model defaults in the adapter's merge and only matter when both
    /// the request and the bundle are silent, in which case the 0.7 floor is
    /// the safe answer anyway.
    static func safeParameters(
        retrying generation: GenerationParameters,
        modelDefaults: LocalGenerationDefaults.Defaults
    ) -> GenerationParameters {
        // Mirrors `MLXBatchAdapter.effectiveGenerationSettings`:
        // `do_sample == false` means the bundle asked for greedy (temp 0).
        let modelDefaultTemperature: Float? =
            modelDefaults.doSample == false ? 0 : modelDefaults.temperature
        let currentTemperature =
            generation.temperature
            ?? modelDefaultTemperature
            ?? MLXLMCommon.GenerateParameters().temperature
        return GenerationParameters(
            temperature: max(currentTemperature, retryTemperatureFloor),
            maxTokens: generation.maxTokens,
            maxTokensExplicit: generation.maxTokensExplicit,
            topPOverride: generation.topPOverride,
            topKOverride: generation.topKOverride,
            minPOverride: generation.minPOverride,
            repetitionPenalty: generation.repetitionPenalty ?? retryRepetitionPenalty,
            samplingParametersAreImplicit: false,
            frequencyPenalty: generation.frequencyPenalty,
            presencePenalty: generation.presencePenalty,
            seed: generation.seed,
            jsonMode: generation.jsonMode,
            modelOptions: generation.modelOptions,
            sessionId: generation.sessionId,
            ttftTrace: generation.ttftTrace,
            idempotencyKey: generation.idempotencyKey,
            runAsRemoteAgent: generation.runAsRemoteAgent,
            suppressProgressUI: generation.suppressProgressUI,
            warmupPrefill: generation.warmupPrefill,
            requestSource: generation.requestSource
        )
    }

    /// Convenience overload resolving the model bundle's shipped sampling
    /// defaults, exactly as `MLXBatchAdapter.generate` does.
    static func safeParameters(
        retrying generation: GenerationParameters,
        modelName: String
    ) -> GenerationParameters {
        safeParameters(
            retrying: generation,
            modelDefaults: LocalGenerationDefaults.defaults(forModelId: modelName)
        )
    }

    // MARK: - Stream splice

    /// Wrap a mapped event stream with the retry-once policy described in
    /// the file header. Events are forwarded unchanged; on a
    /// `StreamGuardrailError.degeneration` thrown before any content-bearing
    /// event was forwarded, `makeRetryStream` is invoked once (the caller
    /// builds it with `safeParameters` + `disableDraftStrategy: true`) and
    /// attempt 2's events are forwarded on the SAME outer stream — the
    /// HTTP/chat consumer never observes the splice. Any error from attempt
    /// 2, and any degeneration after content was forwarded, propagates
    /// unchanged.
    ///
    /// With `isEnabled` false the input stream is returned untouched — the
    /// pre-existing abort path, byte for byte.
    static func withRetry(
        events: AsyncThrowingStream<ModelRuntimeEvent, Error>,
        modelName: String,
        isEnabled: Bool = DegenerationRetry.isEnabled(),
        makeRetryStream: @escaping @Sendable () async throws -> AsyncThrowingStream<
            ModelRuntimeEvent, Error
        >
    ) -> AsyncThrowingStream<ModelRuntimeEvent, Error> {
        guard isEnabled else { return events }
        let (stream, continuation) = AsyncThrowingStream<ModelRuntimeEvent, Error>.makeStream()
        let task = Task {
            var current = events
            var hasForwardedContent = false
            var isRetryAttempt = false
            while true {
                do {
                    for try await event in current {
                        if !hasForwardedContent, Self.isContentBearing(event) {
                            hasForwardedContent = true
                        }
                        continuation.yield(event)
                    }
                    if isRetryAttempt {
                        retryLog.info(
                            "[Osaurus] guardrail: retry succeeded model=\(modelName, privacy: .public)"
                        )
                    }
                    continuation.finish()
                    return
                } catch StreamGuardrailError.degeneration(let fragment)
                    where !isRetryAttempt && !hasForwardedContent && !Task.isCancelled {
                    retryLog.error(
                        "[Osaurus] guardrail: retrying model=\(modelName, privacy: .public) after reasoning-channel degeneration (fragment=\"\(fragment, privacy: .public)\")"
                    )
                    do {
                        current = try await makeRetryStream()
                        isRetryAttempt = true
                    } catch {
                        retryLog.error(
                            "[Osaurus] guardrail: retry failed model=\(modelName, privacy: .public) — attempt 2 could not start: \(error.localizedDescription, privacy: .public)"
                        )
                        continuation.finish(throwing: error)
                        return
                    }
                } catch {
                    if isRetryAttempt {
                        retryLog.error(
                            "[Osaurus] guardrail: retry failed model=\(modelName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                    }
                    continuation.finish(throwing: error)
                    return
                }
            }
        }
        continuation.onTermination = { @Sendable _ in
            task.cancel()
        }
        return stream
    }

    /// Content-bearing = anything a consumer could have committed to:
    /// answer text, a dispatched (or previewing) tool call. Reasoning and
    /// prefill progress are presentation-only and keep the retry eligible —
    /// see the file header for the full rationale.
    private static func isContentBearing(_ event: ModelRuntimeEvent) -> Bool {
        switch event {
        case .tokens(let text):
            return !text.isEmpty
        case .toolInvocation, .toolCallProgress:
            return true
        case .reasoning, .prefillProgress, .completionInfo:
            return false
        }
    }
}
