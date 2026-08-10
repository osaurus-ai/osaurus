//
//  MicroPerfEvaluator.swift
//  OsaurusCore
//
//  Fixed-shape generation micro-benchmark driver for the `micro_perf`
//  eval domain. Runs the SAME single-message prompt through the real
//  ChatEngine streaming path N+1 times (one unmeasured warm-up, N
//  measured reps) with a fixed decode cap, and samples each rep's wall
//  clock, TTFT, and the runtime's authoritative StreamingStatsHint
//  (decode tok/s, prefill tok/s, token count). No tools, no system
//  prompt, temperature 0 — both sides of the request are pinned so the
//  numbers are comparable run-over-run, unlike behaviour rows whose
//  prompt/decode sizes move with fixtures.
//
//  Lives in OsaurusCore (not the evals kit) because the streaming hint
//  decoders are internal runtime surface: this is the one sanctioned
//  place that turns them into a benchmark sample.
//

import Foundation

/// One measured generation of the fixed benchmark request.
public struct MicroPerfSample: Sendable, Codable {
    /// Wall clock for the whole rep (dispatch → stream end), ms.
    public let wallMs: Double
    /// Dispatch → first streamed delta (any channel), ms. nil when the
    /// stream produced nothing.
    public let ttftMs: Double?
    /// Authoritative decode speed from the runtime's end-of-step stats
    /// hint. nil when the path never emitted one (Foundation, most
    /// remotes) — callers may estimate, but must label it.
    public let decodeTokensPerSecond: Double?
    /// First positive prefill (prompt-processing) speed reading, tok/s.
    public let prefillTokensPerSecond: Double?
    /// Authoritative generated-token count from the stats hint.
    public let tokenCount: Int?
    /// Visible content characters streamed (estimation substrate for
    /// hint-less paths: chars/4 ≈ tokens).
    public let contentChars: Int

    public init(
        wallMs: Double,
        ttftMs: Double?,
        decodeTokensPerSecond: Double?,
        prefillTokensPerSecond: Double?,
        tokenCount: Int?,
        contentChars: Int
    ) {
        self.wallMs = wallMs
        self.ttftMs = ttftMs
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.tokenCount = tokenCount
        self.contentChars = contentChars
    }
}

/// Result of a micro-perf run: the measured samples, or the error that
/// stopped it (partial samples are kept for forensics).
public struct MicroPerfTranscript: Sendable, Codable {
    /// Measured reps, in order (the warm-up rep is never included).
    public let samples: [MicroPerfSample]
    /// Non-nil when a rep failed; `samples` holds the reps that finished.
    public let error: String?
    /// Which generation failed: 0 = warm-up, 1…N = measured rep index.
    public let failedRepIndex: Int?

    public init(samples: [MicroPerfSample], error: String? = nil, failedRepIndex: Int? = nil) {
        self.samples = samples
        self.error = error
        self.failedRepIndex = failedRepIndex
    }
}

/// Result of a model-lifecycle run (`micro_perf` cases with
/// `lifecycle: "cold_load"`): per-rep cold-start samples where the TTFT
/// includes a full unload → reload cycle, plus one warm sample for the
/// swap-latency contrast. Trend telemetry only — no floors.
public struct ModelLifecycleTranscript: Sendable, Codable {
    /// One sample per rep; `ttftMs` is dispatch → first token WITH the
    /// model evicted first, i.e. the user-visible cold-start latency.
    public let coldSamples: [MicroPerfSample]
    /// A final generation with the model resident (no eviction), for the
    /// cold-vs-warm contrast in one row. nil when a cold rep failed first.
    public let warmSample: MicroPerfSample?
    /// Non-nil when a generation failed; completed samples are kept.
    public let error: String?
    /// Non-nil when the host cannot run lifecycle rows at all (run model
    /// is not an installed local MLX model — nothing to unload). The
    /// harness maps this to SKIP, not fail.
    public let skipReason: String?

    public init(
        coldSamples: [MicroPerfSample],
        warmSample: MicroPerfSample? = nil,
        error: String? = nil,
        skipReason: String? = nil
    ) {
        self.coldSamples = coldSamples
        self.warmSample = warmSample
        self.error = error
        self.skipReason = skipReason
    }
}

/// Result of a cancellation-lifecycle run (`micro_perf` cases with
/// `lifecycle: "cold_load_cancel"` / `"midgen_cancel"`): the user hits
/// Stop during a cold model load or mid-decode, and the runtime must
/// terminate the stream promptly, leave no zombie load, and serve the
/// next request normally. Cancellation cleanup is a first-class
/// reliability row for big-model hosts (see the AGENTS.md load-
/// cancellation non-negotiable), not trend telemetry.
public struct CancellationTranscript: Sendable, Codable {
    /// `"cold_load"` (cancel fired during a fresh model load) or
    /// `"mid_generation"` (cancel fired after the first streamed delta).
    public let phase: String
    /// ms from dispatch until the cancel signal fired (cold_load) or from
    /// the first delta until the cancel fired (mid_generation).
    public let cancelDelayMs: Double
    /// ms from the cancel signal to the stream actually terminating.
    /// nil when the stream never terminated inside the wait budget —
    /// that is the wedged-cancel failure, reported via `error`.
    public let cancelLatencyMs: Double?
    /// Streamed deltas observed before termination (context for triage).
    public let deltasBeforeTermination: Int
    /// Physical footprint (MB) before dispatch, after the cancelled
    /// stream terminated, and after the recovery generation. nil = probe
    /// failed for that sample.
    public let footprintBeforeMb: Double?
    public let footprintAfterCancelMb: Double?
    public let footprintAfterRecoveryMb: Double?
    /// The follow-up full generation proving the runtime recovered —
    /// no zombie load, no wedged engine. nil when it failed (see `error`).
    public let recoverySample: MicroPerfSample?
    public let error: String?
    /// Non-nil when the host can't run the row (run model not a local
    /// MLX model — nothing to load/cancel). Maps to SKIP.
    public let skipReason: String?

    public init(
        phase: String,
        cancelDelayMs: Double = 0,
        cancelLatencyMs: Double? = nil,
        deltasBeforeTermination: Int = 0,
        footprintBeforeMb: Double? = nil,
        footprintAfterCancelMb: Double? = nil,
        footprintAfterRecoveryMb: Double? = nil,
        recoverySample: MicroPerfSample? = nil,
        error: String? = nil,
        skipReason: String? = nil
    ) {
        self.phase = phase
        self.cancelDelayMs = cancelDelayMs
        self.cancelLatencyMs = cancelLatencyMs
        self.deltasBeforeTermination = deltasBeforeTermination
        self.footprintBeforeMb = footprintBeforeMb
        self.footprintAfterCancelMb = footprintAfterCancelMb
        self.footprintAfterRecoveryMb = footprintAfterRecoveryMb
        self.recoverySample = recoverySample
        self.error = error
        self.skipReason = skipReason
    }
}

/// Benchmark driver. MainActor for the same reason as the other eval
/// evaluators: engine construction and config-store reads are
/// main-actor-isolated.
@MainActor
public enum MicroPerfEvaluator {
    /// Run 1 unmeasured warm-up + `reps` measured generations of `prompt`
    /// with a fixed `maxTokens` decode cap. `model` defaults to whatever
    /// the config store routes to (the eval runner's ModelOverride).
    public static func run(
        prompt: String,
        maxTokens: Int,
        reps: Int,
        model: String? = nil
    ) async -> MicroPerfTranscript {
        let resolvedModel =
            model
            ?? ChatConfigurationStore.load().coreModelIdentifier
            ?? "foundation"
        let engine = ChatEngine()
        // One session for every rep: the content-addressed KV grouping sees
        // one conversation, so measured reps are steady-state (prefix warm)
        // — the stability this lane exists to provide.
        let sessionId = UUID().uuidString

        func runRep() async throws -> MicroPerfSample {
            try await measureRep(
                engine: engine,
                model: resolvedModel,
                prompt: prompt,
                maxTokens: maxTokens,
                sessionId: sessionId
            )
        }

        do {
            _ = try await runRep()  // warm-up: JIT + prefix store, discarded
        } catch {
            return MicroPerfTranscript(
                samples: [],
                error: "warm-up generation failed: \(error)",
                failedRepIndex: 0
            )
        }

        var samples: [MicroPerfSample] = []
        for index in 1 ... max(1, reps) {
            do {
                samples.append(try await runRep())
            } catch {
                return MicroPerfTranscript(
                    samples: samples,
                    error: "rep \(index)/\(reps) failed: \(error)",
                    failedRepIndex: index
                )
            }
        }
        return MicroPerfTranscript(samples: samples)
    }

    /// Model-lifecycle benchmark (`lifecycle: "cold_load"`): each measured
    /// rep evicts every resident model via the runtime's real teardown
    /// (`clearAll` — the same path settings changes drive) and then
    /// generates, so the rep's TTFT is the true cold-start latency the
    /// user sees after a model swap. Ends with one warm generation for
    /// the cold-vs-warm contrast. SKIPs (via `skipReason`) when the run
    /// model is not an installed local MLX model, because there is
    /// nothing to unload for Foundation or remote routes.
    public static func runLifecycle(
        prompt: String,
        maxTokens: Int,
        reps: Int,
        model: String? = nil
    ) async -> ModelLifecycleTranscript {
        let resolvedModel =
            model
            ?? ChatConfigurationStore.load().coreModelIdentifier
            ?? "foundation"
        guard
            ModelRuntime.resolveLocalModelDirectory(
                forModelId: resolvedModel,
                in: DirectoryPickerService.effectiveModelsDirectory()
            ) != nil
        else {
            return ModelLifecycleTranscript(
                coldSamples: [],
                skipReason:
                    "run model '\(resolvedModel)' is not an installed local MLX model; nothing to unload"
            )
        }

        let engine = ChatEngine()
        // Fresh session per rep: a cold-load row must not get prefix help
        // from the previous rep's KV entries surviving on disk.
        var coldSamples: [MicroPerfSample] = []
        for index in 1 ... max(1, reps) {
            await ModelRuntime.shared.clearAll()
            do {
                coldSamples.append(
                    try await measureRep(
                        engine: engine,
                        model: resolvedModel,
                        prompt: prompt,
                        maxTokens: maxTokens,
                        sessionId: UUID().uuidString
                    )
                )
            } catch {
                return ModelLifecycleTranscript(
                    coldSamples: coldSamples,
                    error: "cold rep \(index)/\(reps) failed: \(error)"
                )
            }
        }

        do {
            let warm = try await measureRep(
                engine: engine,
                model: resolvedModel,
                prompt: prompt,
                maxTokens: maxTokens,
                sessionId: UUID().uuidString
            )
            return ModelLifecycleTranscript(coldSamples: coldSamples, warmSample: warm)
        } catch {
            return ModelLifecycleTranscript(
                coldSamples: coldSamples,
                error: "warm contrast rep failed: \(error)"
            )
        }
    }

    /// Mutable observation shared between the streaming consumer task and
    /// the cancel scheduler. A MainActor class (not captured vars) so the
    /// concurrently-created consumer Task can mutate it under the same
    /// isolation the evaluator runs on.
    @MainActor
    private final class CancellationObservation {
        var firstDeltaAt: Date?
        var deltas = 0
        var terminatedAt: Date?
        var streamError: String?
    }

    /// Cancellation-lifecycle row (`lifecycle: "cold_load_cancel"` /
    /// `"midgen_cancel"`): dispatch a generation, cancel it at the declared
    /// point (during the cold model load, or `cancelAfterMs` after the
    /// first streamed delta), and prove the runtime terminates the stream,
    /// leaves no zombie state, and serves a full recovery generation
    /// afterwards. SKIPs when the run model is not an installed local MLX
    /// model (nothing to load or cancel).
    public static func runCancellation(
        prompt: String,
        maxTokens: Int,
        coldLoad: Bool,
        cancelAfterMs: Double,
        model: String? = nil
    ) async -> CancellationTranscript {
        let phase = coldLoad ? "cold_load" : "mid_generation"
        let resolvedModel =
            model
            ?? ChatConfigurationStore.load().coreModelIdentifier
            ?? "foundation"
        guard
            ModelRuntime.resolveLocalModelDirectory(
                forModelId: resolvedModel,
                in: DirectoryPickerService.effectiveModelsDirectory()
            ) != nil
        else {
            return CancellationTranscript(
                phase: phase,
                skipReason:
                    "run model '\(resolvedModel)' is not an installed local MLX model; nothing to load or cancel"
            )
        }

        let engine = ChatEngine()

        if coldLoad {
            // The cancel must land inside a REAL cold load.
            await ModelRuntime.shared.clearAll()
        } else {
            // Warm the model first so the cancel lands mid-decode, not
            // mid-load; a tiny decode keeps the warm-up cheap.
            do {
                _ = try await measureRep(
                    engine: engine,
                    model: resolvedModel,
                    prompt: prompt,
                    maxTokens: 8,
                    sessionId: UUID().uuidString
                )
            } catch {
                return CancellationTranscript(
                    phase: phase,
                    error: "warm-up before mid-generation cancel failed: \(error)"
                )
            }
        }

        let footprintBefore = ProcessMemoryProbe.currentPhysFootprintMB()

        let request = ChatCompletionRequest(
            model: resolvedModel,
            messages: [ChatMessage(role: "user", content: prompt)],
            temperature: 0.0,
            max_tokens: maxTokens,
            stream: true,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil,
            session_id: UUID().uuidString
        )

        let observation = CancellationObservation()
        let dispatchedAt = Date()
        let consumer = Task { @MainActor in
            do {
                let stream = try await engine.streamChat(request: request)
                for try await _ in stream {
                    observation.deltas += 1
                    if observation.firstDeltaAt == nil {
                        observation.firstDeltaAt = Date()
                    }
                }
            } catch is CancellationError {
                // Expected termination path for a cancelled stream.
            } catch {
                // A cancelled stream may also surface as a runtime error;
                // record it — the harness decides whether it is acceptable.
                observation.streamError = "\(error)"
            }
            observation.terminatedAt = Date()
        }

        func sleepMs(_ ms: Double) async {
            try? await Task.sleep(nanoseconds: UInt64(max(0, ms) * 1_000_000))
        }

        // Schedule the cancel at the declared point.
        var cancelDelayMs = cancelAfterMs
        if coldLoad {
            await sleepMs(cancelAfterMs)
        } else {
            // Wait (bounded) for the first delta, then the declared delay.
            let firstDeltaBudgetMs: Double = 120_000
            let waitStart = Date()
            while observation.firstDeltaAt == nil,
                observation.terminatedAt == nil,
                Date().timeIntervalSince(waitStart) * 1000 < firstDeltaBudgetMs
            {
                await sleepMs(25)
            }
            guard observation.firstDeltaAt != nil else {
                consumer.cancel()
                return CancellationTranscript(
                    phase: phase,
                    footprintBeforeMb: footprintBefore,
                    error: observation.streamError.map {
                        "stream failed before first delta: \($0)"
                    } ?? "no first delta within \(Int(firstDeltaBudgetMs))ms; cannot place a mid-generation cancel"
                )
            }
            await sleepMs(cancelAfterMs)
            cancelDelayMs = Date().timeIntervalSince(dispatchedAt) * 1000
        }

        let cancelledAt = Date()
        consumer.cancel()

        // Bounded wait for termination: a cancel that never terminates the
        // stream is THE failure this lane exists to catch — report it
        // instead of hanging the suite.
        let terminationBudgetMs: Double = 30_000
        while observation.terminatedAt == nil,
            Date().timeIntervalSince(cancelledAt) * 1000 < terminationBudgetMs
        {
            await sleepMs(25)
        }
        guard let terminatedAt = observation.terminatedAt else {
            return CancellationTranscript(
                phase: phase,
                cancelDelayMs: cancelDelayMs,
                deltasBeforeTermination: observation.deltas,
                footprintBeforeMb: footprintBefore,
                error:
                    "stream did not terminate within \(Int(terminationBudgetMs))ms of cancellation — wedged cancel"
            )
        }
        let cancelLatencyMs = terminatedAt.timeIntervalSince(cancelledAt) * 1000

        // Give teardown a beat to release transient buffers before sampling.
        await sleepMs(500)
        let footprintAfterCancel = ProcessMemoryProbe.currentPhysFootprintMB()

        // Recovery: a full generation must succeed after the cancel —
        // no zombie load, no wedged engine, no leaked session state.
        do {
            let recovery = try await measureRep(
                engine: engine,
                model: resolvedModel,
                prompt: prompt,
                maxTokens: maxTokens,
                sessionId: UUID().uuidString
            )
            return CancellationTranscript(
                phase: phase,
                cancelDelayMs: cancelDelayMs,
                cancelLatencyMs: cancelLatencyMs,
                deltasBeforeTermination: observation.deltas,
                footprintBeforeMb: footprintBefore,
                footprintAfterCancelMb: footprintAfterCancel,
                footprintAfterRecoveryMb: ProcessMemoryProbe.currentPhysFootprintMB(),
                recoverySample: recovery,
                error: observation.streamError.map { "cancelled stream surfaced error: \($0)" }
            )
        } catch {
            return CancellationTranscript(
                phase: phase,
                cancelDelayMs: cancelDelayMs,
                cancelLatencyMs: cancelLatencyMs,
                deltasBeforeTermination: observation.deltas,
                footprintBeforeMb: footprintBefore,
                footprintAfterCancelMb: footprintAfterCancel,
                error: "recovery generation after cancel failed: \(error)"
            )
        }
    }

    /// One measured generation of the fixed benchmark request. Shared by
    /// the steady-state and lifecycle lanes.
    private static func measureRep(
        engine: ChatEngine,
        model: String,
        prompt: String,
        maxTokens: Int,
        sessionId: String
    ) async throws -> MicroPerfSample {
        let request = ChatCompletionRequest(
            model: model,
            messages: [ChatMessage(role: "user", content: prompt)],
            temperature: 0.0,
            max_tokens: maxTokens,
            stream: true,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil,
            session_id: sessionId
        )
        let started = Date()
        var ttftMs: Double?
        var decodeTps: Double?
        var prefillTps: Double?
        var tokenCount: Int?
        var contentChars = 0
        let stream = try await engine.streamChat(request: request)
        for try await delta in stream {
            if ttftMs == nil {
                ttftMs = Date().timeIntervalSince(started) * 1000
            }
            if StreamingReasoningHint.decode(delta) != nil { continue }
            if let stats = StreamingStatsHint.decode(delta) {
                if stats.tokensPerSecond > 0 { decodeTps = stats.tokensPerSecond }
                if stats.tokenCount > 0 { tokenCount = stats.tokenCount }
                if prefillTps == nil, let prefill = stats.prefillTokensPerSecond, prefill > 0 {
                    prefillTps = prefill
                }
                continue
            }
            if StreamingToolHint.isSentinel(delta) { continue }
            contentChars += delta.count
        }
        return MicroPerfSample(
            wallMs: Date().timeIntervalSince(started) * 1000,
            ttftMs: ttftMs,
            decodeTokensPerSecond: decodeTps,
            prefillTokensPerSecond: prefillTps,
            tokenCount: tokenCount,
            contentChars: contentChars
        )
    }
}
