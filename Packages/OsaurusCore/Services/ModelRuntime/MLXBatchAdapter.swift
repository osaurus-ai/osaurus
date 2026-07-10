//
//  MLXBatchAdapter.swift
//  osaurus
//
//  Single MLX entry point: routes each request through `BatchEngine.generate`,
//  which emits authoritative `.chunk(String)` / `.reasoning(String)` /
//  `.toolCall(ToolCall)` / `.info(GenerateCompletionInfo)` events. Reasoning,
//  tool-call extraction, and text-level stop matching are all owned by the
//  library — osaurus passes `stopSequences` as `GenerateParameters.extraStopStrings`
//  and forwards every event through `GenerationEventMapper`.
//
//  Osaurus no longer parses tool calls, reasoning, or stop sequences at the
//  app layer — see `GenerationEventMapper` for the trivial `Generation` →
//  `ModelRuntimeEvent` bridge that replaced the old token-level
//  `StreamAccumulator` and app-side `StopSequenceBuffer`.
//
//  Cache coordinator: captured automatically by `container.makeBatchEngine`.
//  Multi-turn KV reuse, mediaSalt for VLMs, sliding-window cache support —
//  all handled inside the engine. We do not need to plumb anything cache-
//  related through this layer.
//

import CoreImage
import Foundation
import MLX
@preconcurrency import MLXLMCommon
import MLXRandom
import MLXVLM  // MediaProcessing for image downscaling
import os.log

private let batchAdapterLog = Logger(subsystem: "ai.osaurus", category: "BatchAdapter")

struct MLXBatchAdapter {
    /// Native MTP is tuned for real chat prefixes, not tiny cold-start
    /// prompts. A 19-token cold user-only prompt reproduced a native-MTP loop
    /// while the same request decoded correctly with AR greedy fallback.
    static let nativeMTPTinyPromptMinimumTokens = 24

    /// Aggregate live diagnostics across every resolved
    /// `BatchEngine`. Used by the Server → Settings panel to render
    /// the concurrency live readout without exposing
    /// `BatchEngine`/`Registry` to UI code.
    static func snapshotDiagnostics() async -> BatchDiagnosticsSnapshot? {
        await Registry.shared.snapshotDiagnostics()
    }

    static func lastEffectiveGenerationSettingsSnapshot() async -> [String: EffectiveGenerationSettings] {
        await Registry.shared.lastEffectiveGenerationSettingsSnapshot()
    }

    /// Result handed back to `ModelRuntime`. The `Generation` stream is
    /// consumed by `GenerationEventMapper`, which translates the upstream
    /// events into `ModelRuntimeEvent`. The producer task exists so callers
    /// can cancel the underlying `BatchEngine` request via Swift's standard
    /// task-cancellation mechanism.
    struct PreparedStream {
        let stream: AsyncStream<Generation>
        let promptTokens: [Int]
        let genTask: Task<Void, Never>
        /// Which engine path this request was submitted on, resolved at
        /// submit time. Carried alongside the stream so the runtime's
        /// stats sentinel (and from there the HTTP `usage` block) can
        /// attribute the finished step without recomputing eligibility.
        let attribution: EngineAttribution
    }

    struct AudioPreencodeResult {
        let chat: [MLXLMCommon.Chat.Message]
        let inputCount: Int
        let convertedCount: Int
        let alreadyPreencodedCount: Int
    }

    struct EffectiveGenerationSettings: Equatable, Sendable {
        /// Which record this is: "pending_preload" (written before container
        /// load; attribution fields are placeholders),
        /// "submitted_to_batch_engine" (a real request, written at submit
        /// time), or "load_warmup" (the hidden 2-token generation
        /// `warmupNativeMTPAtLoad` runs at model load to consume the
        /// native-MTP cold-warmup — NOT user traffic; its engaged=false /
        /// cold_warmup row would otherwise be indistinguishable from a real
        /// request that failed to engage MTP).
        let stage: String
        let temperature: Float
        let maxTokens: Int
        let topP: Float
        let topK: Int
        let minP: Float
        let repetitionPenalty: Float?
        let compiledBatchDecode: Bool
        /// "solo" when the request routes vmlx's exclusive solo fast path;
        /// "batched" when it enters the shared continuous-batching
        /// scheduler loop. Mirrors `BatchEngine.generate`'s own routing:
        /// a submitted native-MTP strategy (BatchEngine.swift:566) or a
        /// block-diffusion target model (BatchEngine.swift:582, `context.model
        /// is any BlockDiffusionModel`) forces the exclusive solo path
        /// regardless of `maxBatchSize`; otherwise the solo fast path
        /// engages when `maxBatchSize == 1` (`canStartSoloFastPath`) —
        /// which coincides with the `SoloGenerationGate` lease. For
        /// `stage == "pending_preload"` records this is derived from
        /// `maxBatchSize` alone (neither the lease decision nor the draft
        /// strategy exists yet); `generate()` overwrites the record with
        /// the routing-derived value at submit time. See
        /// `engineAttribution(...)` for the submitted-path contract and
        /// the named residual cases.
        var enginePath: String
        /// True when the loaded model shipped a native-MTP draft strategy,
        /// independent of whether this request was eligible to use it.
        /// Always false for `pending_preload` records — the draft strategy
        /// is resolved during container load, after the pending record is
        /// written.
        var nativeMTPRequested: Bool
        /// True when the native-MTP strategy survived osaurus's eligibility
        /// gates (`effectiveDraftStrategy`), was submitted to the engine,
        /// AND passes vmlx's own public solo-fast-path gate
        /// (`GenerateParameters.canUseNativeMTP(for:)`, i.e.
        /// `isNativeMTPLosslessGreedyEligible` on the exact submitted
        /// parameters plus no media content). The engine gate matters:
        /// e.g. a model-shipped default `topP = 0.95` passes osaurus's
        /// explicit-greedy request check but vetoes MTP engine-side.
        var nativeMTPEngaged: Bool
        /// Mirror of the per-submit `nativeMTPFallback` log value:
        /// "cold_warmup" | "explicit_sampling" | "tiny_prompt" (strategy
        /// dropped before submit by osaurus's gates),
        /// "engine_sampling_gate" (strategy submitted, but the effective
        /// sampling parameters or media content fail vmlx's
        /// `canUseNativeMTP` check, so the engine runs plain AR on its
        /// solo path), or "engine_iterator_gate" (strategy submitted and
        /// the sampling gate passes, but a `NativeMTPTokenIterator.init`
        /// precondition fails — maxTokens ≤ 1, empty prompt, or depth < 1
        /// — so the engine's solo-MTP branch throws and yields a CANCELLED
        /// stream; nothing runs). Nil when MTP engaged or was never
        /// requested.
        var nativeMTPFallbackReason: String?
    }

    /// Boundary attribution for one submitted request: which engine code
    /// path serves it and why native MTP did or did not engage. Built once
    /// in `generate(...)` — single-sourced at submit time from the exact
    /// `GenerateParameters` handed to the engine and aligned with the
    /// engine's public eligibility gate
    /// (`GenerateParameters.canUseNativeMTP(for:)`); the same value feeds
    /// the wire flags, `/admin` JSON, and the per-submit os_log line, so
    /// those three surfaces agree by construction. Observed per-generation
    /// engagement (accepted draft tokens etc.) arrives separately via
    /// engine counters.
    struct EngineAttribution: Equatable, Sendable {
        /// See `EffectiveGenerationSettings.enginePath`.
        let enginePath: String
        /// True when the target model is a block-diffusion model
        /// (`BatchEngine` routes `context.model is any BlockDiffusionModel`
        /// to its exclusive solo canvas path; DiffusionGemma is the only
        /// shipped conformance). Detected by evaluating that SAME
        /// conformance predicate on the loaded model instance inside
        /// `prepareInput`'s existing `container.perform` hop — coextensive
        /// with the engine's routing by construction, not a name or
        /// model_type proxy.
        let blockDiffusion: Bool
        /// See `EffectiveGenerationSettings.nativeMTPRequested`. Gated on
        /// `usesNativeMTP` (not merely non-nil) so a block-diffusion or
        /// autoregressive draft strategy never reports as native MTP.
        let nativeMTPRequested: Bool
        /// See `EffectiveGenerationSettings.nativeMTPEngaged`.
        let nativeMTPEngaged: Bool
        /// See `EffectiveGenerationSettings.nativeMTPFallbackReason`.
        let nativeMTPFallbackReason: String?

        init(
            enginePath: String,
            blockDiffusion: Bool = false,
            nativeMTPRequested: Bool,
            nativeMTPEngaged: Bool,
            nativeMTPFallbackReason: String?
        ) {
            self.enginePath = enginePath
            self.blockDiffusion = blockDiffusion
            self.nativeMTPRequested = nativeMTPRequested
            self.nativeMTPEngaged = nativeMTPEngaged
            self.nativeMTPFallbackReason = nativeMTPFallbackReason
        }

        /// Wire value for the stats-hint `engine=` flag: "solo_mtp" is the
        /// engine's native-MTP solo branch, "solo_ar" the plain
        /// autoregressive solo path, "solo_diffusion" the exclusive
        /// block-diffusion canvas path, "batched" the shared engine loop
        /// (which never runs the native-MTP iterator).
        ///
        /// The flag names the SUBMITTED branch, so it switches on the
        /// fallback reason, not on `nativeMTPEngaged` alone:
        /// flag=solo_mtp with engaged=false marks a submitted native-MTP
        /// request the engine will CANCEL (`engine_iterator_gate`: the
        /// engine takes its solo-MTP branch, the iterator constructor
        /// throws, the stream terminates with stop=cancelled — plain AR
        /// never runs, so reporting solo_ar would be false). The
        /// `engine_sampling_gate` veto is the asymmetric case: there the
        /// engine's own `canUseNativeMTP` check fails BEFORE the MTP
        /// branch and the plain AR iterator actually runs, so solo_ar is
        /// the truthful flag.
        var engineFlag: String {
            guard enginePath == "solo" else { return "batched" }
            if blockDiffusion { return "solo_diffusion" }
            if nativeMTPEngaged || nativeMTPFallbackReason == "engine_iterator_gate" {
                return "solo_mtp"
            }
            return "solo_ar"
        }
    }

    /// Derive the boundary attribution from the SAME branch structure
    /// `BatchEngine.generate` takes (osaurus submits every request through
    /// `engine.generate`; it never calls `engine.submit` directly):
    ///
    /// 1. `parameters.draftStrategy?.usesNativeMTP == true` → the EXCLUSIVE
    ///    solo fast path, regardless of `maxBatchSize`
    ///    (BatchEngine.swift:566). Inside that path the engine re-checks
    ///    its own public gate (`soloParameters.canUseNativeMTP(for:)`,
    ///    BatchEngine.swift:1051-1053) and runs the plain AR iterator when
    ///    it fails — still solo, so `enginePath == "solo"` either way and
    ///    the flag distinguishes `solo_mtp` from `solo_ar`. When the gate
    ///    PASSES, `NativeMTPTokenIterator.init` can still throw
    ///    (maxTokens ≤ 1, empty prompt, depth < 1, model without a usable
    ///    MTP head) and the engine yields a CANCELLED stream
    ///    (BatchEngine.swift:1114-1127); the host-checkable preconditions
    ///    are mirrored here as `engine_iterator_gate`.
    /// 2. `context.model is any BlockDiffusionModel` → the EXCLUSIVE solo
    ///    canvas path, regardless of `maxBatchSize`
    ///    (BatchEngine.swift:582-592). Reported as `enginePath == "solo"`
    ///    with flag `solo_diffusion`.
    /// 3. Otherwise the solo fast path engages when `maxBatchSize == 1`
    ///    and the engine is idle (`canStartSoloFastPath`); the osaurus
    ///    `SoloGenerationGate` lease is acquired exactly when
    ///    `maxBatchSize == 1` and serializes osaurus submits.
    /// 4. Everything else enters the shared batched scheduler loop.
    ///
    /// CONTRACT — SUBMITTED-path attribution. These fields state what
    /// osaurus submitted and what the engine's PUBLIC gates say about it,
    /// not an observation of the engine's internal choice. Named residuals:
    /// - Busy-engine hard reject (native-MTP or block-diffusion submit
    ///   while the engine is not idle): vmlx cancels the stream and nothing
    ///   runs; attribution still says "solo". Observable host-side via the
    ///   step's terminal stop reason (`cancelled`).
    /// - Post-disconnect drain window (any config, including single-slot):
    ///   on client disconnect osaurus's producer exits and releases the
    ///   solo lease while the engine's `soloFastPathTask` keeps draining to
    ///   the next chunk boundary (see `ModelRuntime.cancelGeneration(name:)`,
    ///   vmlx #111). An immediate retry then finds the engine busy: non-MTP
    ///   → the engine's `canStartSoloFastPath` is false and the request runs
    ///   BATCHED while we report solo_ar — not observable host-side today,
    ///   closable only by an engine-side path indicator; MTP → hard reject,
    ///   observable via stop=cancelled as above.
    ///
    /// - Parameters:
    ///   - isBlockDiffusionModel: whether the target model is a
    ///     block-diffusion model. Callers pass
    ///     `PreparedInput.isBlockDiffusionModel`, which evaluates
    ///     `context.model is any BlockDiffusionModel` on the loaded model
    ///     instance inside `prepareInput`'s existing `container.perform`
    ///     hop — the EXACT predicate `BatchEngine.generate` dispatches on
    ///     (BatchEngine.swift:581), so it cannot diverge from the engine's
    ///     routing (a renamed fine-tune that conforms still detects; a
    ///     look-alike model id that doesn't conform never false-positives).
    ///   - engineNativeMTPEligible: vmlx's own public gate evaluated on
    ///     the exact parameters submitted —
    ///     `mlxParams.canUseNativeMTP(for: input)` — NOT an osaurus
    ///     reimplementation. Only meaningful when a native-MTP strategy
    ///     was submitted.
    ///   - submittedMaxTokens: `mlxParams.maxTokens`, the exact value the
    ///     engine sees (`NativeMTPTokenIterator.init` throws on ≤ 1).
    ///   - promptTokenCount: `prepared.promptTokens.count` (the iterator
    ///     throws on an empty prompt).
    ///   - osaurusFallbackReason: the pre-submit fallback reason
    ///     ("cold_warmup" | "explicit_sampling" | "tiny_prompt") from
    ///     `nativeMTPFallbackReason(...)`, nil when osaurus's gates passed.
    ///
    /// DISCLOSED residual for `nativeMTPEngaged`: the iterator's
    /// `model.nativeMTPAvailable` guard (and the `any NativeMTPModel`
    /// downcast before it) checks the loaded model INSTANCE, which this
    /// path does not probe — no NEW `container.perform` hop is added for
    /// it. A model whose MTP weights were filtered at load would report
    /// engaged=true and then cancel engine-side (observable via
    /// stop=cancelled). Closable the same way the block-diffusion
    /// predicate was closed (piggyback on `prepareInput`'s existing
    /// perform hop), by a load-time capability probe, or by an
    /// engine-side path indicator.
    static func engineAttribution(
        soloLeaseHeld: Bool,
        isBlockDiffusionModel: Bool = false,
        requestedDraftStrategy: MLXLMCommon.DraftStrategy?,
        submittedDraftStrategy: MLXLMCommon.DraftStrategy?,
        engineNativeMTPEligible: Bool,
        submittedMaxTokens: Int? = nil,
        promptTokenCount: Int = 1,
        osaurusFallbackReason: String?
    ) -> EngineAttribution {
        let requested = requestedDraftStrategy?.usesNativeMTP == true
        let submitted = submittedDraftStrategy?.usesNativeMTP == true
        // Host-checkable `NativeMTPTokenIterator.init` preconditions,
        // mirrored on the exact submitted values. Osaurus constructs the
        // strategy, so depth is known here; `submittedMaxTokens` is
        // `mlxParams.maxTokens` verbatim. `model.nativeMTPAvailable` is NOT
        // host-checkable — see the disclosed residual in the doc above.
        let submittedDepth: Int? = {
            if case .some(.nativeMTP(depth: let depth, verifierMode: _)) = submittedDraftStrategy {
                return depth
            }
            return nil
        }()
        let iteratorPreconditionsPass =
            (submittedMaxTokens.map { $0 > 1 } ?? true)
            && promptTokenCount > 0
            && (submittedDepth ?? 1) >= 1
        let engaged = submitted && engineNativeMTPEligible && iteratorPreconditionsPass
        let fallbackReason: String?
        if !requested || engaged {
            fallbackReason = nil
        } else if submitted && engineNativeMTPEligible {
            // The engine's sampling gate passes, so it takes the solo-MTP
            // branch — and the iterator constructor then throws on one of
            // the mirrored preconditions, cancelling the stream. Distinct
            // from "engine_sampling_gate" (where plain AR actually runs).
            fallbackReason = "engine_iterator_gate"
        } else if submitted {
            // Survived osaurus's request-level gates but the engine's own
            // eligibility check on the EFFECTIVE parameters (or media
            // content) vetoes MTP — e.g. a model-shipped topP=0.95 default
            // the request never overrode. The engine runs plain AR on its
            // solo path.
            fallbackReason = "engine_sampling_gate"
        } else {
            fallbackReason = osaurusFallbackReason
        }
        return EngineAttribution(
            enginePath: (submitted || isBlockDiffusionModel || soloLeaseHeld) ? "solo" : "batched",
            blockDiffusion: isBlockDiffusionModel,
            nativeMTPRequested: requested,
            nativeMTPEngaged: engaged,
            nativeMTPFallbackReason: fallbackReason
        )
    }

    static func effectiveGenerationSettings(
        modelName: String,
        generation: GenerationParameters,
        runtimeDefaults: VMLXServerGenerationDefaults,
        maxBatchSize: Int,
        modelDefaults: LocalGenerationDefaults.Defaults,
        draftStrategy: MLXLMCommon.DraftStrategy? = nil,
        nativeMTPExplicitSamplingFallback: Bool = false,
        stage: String = "resolved"
    ) -> EffectiveGenerationSettings {
        let defaultTemperature: Float? = {
            if modelDefaults.doSample == false {
                return 0
            }
            return modelDefaults.temperature
        }()
        let engineDefaults = MLXLMCommon.GenerateParameters()

        // Merge order (per-request always wins): per-request →
        // model-shipped defaults → server runtime defaults → vmlx engine
        // defaults. Osaurus must not invent sampler defaults.
        let runtimeTopP: Float? = runtimeDefaults.topP.map { Float($0) }
        let runtimeMinP: Float? = runtimeDefaults.minP.map { Float($0) }
        let runtimeTopK: Int? = runtimeDefaults.topK
        let runtimeTemperature: Float? = runtimeDefaults.temperature.map { Float($0) }
        let runtimeMaxTokens: Int? = runtimeDefaults.maxTokens
        let runtimeRepetitionPenalty: Float? = runtimeDefaults.repetitionPenalty.map { Float($0) }
        let repetitionPenalty = Self.effectiveRepetitionPenalty(
            modelName: modelName,
            generation: generation,
            modelDefault: modelDefaults.repetitionPenalty,
            runtimeDefault: runtimeRepetitionPenalty
        )

        return EffectiveGenerationSettings(
            stage: stage,
            temperature: generation.temperature
                ?? defaultTemperature
                ?? runtimeTemperature
                ?? engineDefaults.temperature,
            maxTokens: generation.maxTokensExplicit
                ? generation.maxTokens
                : (modelDefaults.maxTokens ?? runtimeMaxTokens ?? generation.maxTokens),
            topP: generation.topPOverride ?? modelDefaults.topP ?? runtimeTopP ?? engineDefaults.topP,
            topK: generation.topKOverride ?? modelDefaults.topK ?? runtimeTopK ?? engineDefaults.topK,
            minP: generation.minPOverride ?? modelDefaults.minP ?? runtimeMinP ?? engineDefaults.minP,
            repetitionPenalty: repetitionPenalty,
            compiledBatchDecode: nativeMTPExplicitSamplingFallback
                ? false
                : shouldEnableCompiledBatchDecode(
                    modelName: modelName,
                    maxBatchSize: maxBatchSize
                ),
            // Pre-submit derivation only: `generate()` overwrites these
            // four fields with the routing-derived `EngineAttribution`
            // after the vmlx `GenerateParameters` are fully constructed
            // (the routing can be "solo" even when `maxBatchSize > 1`,
            // because a submitted native-MTP strategy forces the engine's
            // exclusive solo path).
            enginePath: maxBatchSize == 1 ? "solo" : "batched",
            nativeMTPRequested: false,
            nativeMTPEngaged: false,
            nativeMTPFallbackReason: nil
        )
    }

    /// Stage label for the `EffectiveGenerationSettings` record a submit
    /// writes: "submitted_to_batch_engine" for every user-facing path,
    /// or the internal override (`warmupNativeMTPAtLoad` passes
    /// "load_warmup" for its hidden 2-token generation). See the `stage`
    /// field doc on `EffectiveGenerationSettings`.
    static func submitStage(for generation: GenerationParameters) -> String {
        generation.effectiveSettingsStage ?? "submitted_to_batch_engine"
    }

    static func recordPendingEffectiveGenerationSettings(
        modelName: String,
        generation: GenerationParameters,
        runtimeDefaults: VMLXServerGenerationDefaults,
        maxBatchSize: Int
    ) async {
        let modelDefaults = LocalGenerationDefaults.defaults(forModelId: modelName)
        let effective = Self.effectiveGenerationSettings(
            modelName: modelName,
            generation: generation,
            runtimeDefaults: runtimeDefaults,
            maxBatchSize: maxBatchSize,
            modelDefaults: modelDefaults,
            stage: "pending_preload"
        )
        await Registry.shared.recordEffectiveGenerationSettings(
            modelName: modelName,
            settings: effective
        )
    }

    static func effectiveDraftStrategy(
        generation: GenerationParameters,
        draftStrategy: MLXLMCommon.DraftStrategy?,
        promptTokenCount: Int? = nil,
        disableNativeMTP: Bool = false
    ) -> MLXLMCommon.DraftStrategy? {
        guard draftStrategy?.usesNativeMTP == true else {
            return draftStrategy
        }
        if disableNativeMTP {
            return nil
        }
        guard
            requestSamplingIsExplicitGreedy(
                generation: generation,
                draftStrategy: draftStrategy
            )
        else {
            return nil
        }
        if let promptTokenCount,
            promptTokenCount < nativeMTPTinyPromptMinimumTokens
        {
            return nil
        }
        return draftStrategy
    }

    private static func nativeMTPFallbackReason(
        generation: GenerationParameters,
        draftStrategy: MLXLMCommon.DraftStrategy?,
        promptTokenCount: Int,
        coldWarmup: Bool
    ) -> String? {
        guard draftStrategy?.usesNativeMTP == true else { return nil }
        if coldWarmup { return "cold_warmup" }
        if !requestSamplingIsExplicitGreedy(
            generation: generation,
            draftStrategy: draftStrategy
        ) {
            return "explicit_sampling"
        }
        if promptTokenCount < nativeMTPTinyPromptMinimumTokens {
            return "tiny_prompt"
        }
        return nil
    }

    private static func requestSamplingIsExplicitGreedy(
        generation: GenerationParameters,
        draftStrategy: MLXLMCommon.DraftStrategy?
    ) -> Bool {
        guard draftStrategy?.usesNativeMTP == true else { return false }
        if generation.samplingParametersAreImplicit {
            return false
        }
        guard generation.temperature == 0 else { return false }
        if let topP = generation.topPOverride, topP < 1 { return false }
        if let topK = generation.topKOverride, topK != 0 { return false }
        if let minP = generation.minPOverride, minP != 0 { return false }
        if let repetitionPenalty = generation.repetitionPenalty,
            repetitionPenalty != 0,
            repetitionPenalty != 1
        {
            return false
        }
        return true
    }

    private static func effectiveRepetitionPenalty(
        modelName: String,
        generation: GenerationParameters,
        modelDefault: Float?,
        runtimeDefault: Float?
    ) -> Float? {
        if let explicit = generation.repetitionPenalty {
            return explicit
        }

        let resolved = modelDefault ?? runtimeDefault
        return resolved
    }

    /// Process-wide gate for the single-slot runtime path. With
    /// `maxBatchSize == 1`, vmlx can route through its TokenIterator-backed
    /// solo fast path. There is no batching upside to overlapping a second
    /// prompt-prep/eval against an active solo decode, and MLX/Metal command
    /// encoders are not safe to drive concurrently across solo engines.
    actor SoloGenerationGate {
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        struct Lease: @unchecked Sendable {
            fileprivate let gate: SoloGenerationGate

            func release() async {
                await gate.release()
            }
        }

        func acquire(modelName: String) async -> Lease {
            if !busy {
                busy = true
                return Lease(gate: self)
            }

            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
            return Lease(gate: self)
        }

        private func release() {
            guard busy else { return }
            if !waiters.isEmpty {
                let next = waiters.removeFirst()
                next.resume()
            } else {
                busy = false
            }
        }
    }

    // MARK: - Per-model engine cache

    /// Per-process cache of `BatchEngine` instances keyed by model name.
    ///
    /// Engines are heavyweight: they hold a captured `ModelContext` and run a
    /// background scheduling task. Creating one per request would defeat the
    /// continuous-batching point — the whole reason `BatchEngine` exists is
    /// to share a single forward pass across overlapping requests, which can
    /// only happen if those requests submit into the *same* engine instance.
    actor Registry {
        static let shared = Registry()
        private let soloGate = SoloGenerationGate()

        /// Single-flight cache for the per-model `BatchEngine` instance.
        /// Coalesces concurrent first-fetch callers onto the same
        /// creation `Task` so the registry never returns two `BatchEngine`
        /// objects bound to the same MLX `ModelContainer`. Two engines
        /// on one container would put concurrent producers on the shared
        /// GPU command queue, which surfaces as a Metal completion-queue
        /// abort. See `TaskCoalescer` for the construction-order
        /// invariant the coalescer enforces.
        private let coalescer = TaskCoalescer<BatchEngine>()
        private var nativeMTPWarmModels: Set<String> = []
        private var lastEffectiveGenerationSettings: [String: EffectiveGenerationSettings] = [:]

        /// Returns the cached engine for `modelName`, creating it on first
        /// use from the supplied `ModelContainer`. The container's existing
        /// cache coordinator is captured automatically by `makeBatchEngine`.
        ///
        /// `BatchEngine.maxBatchSize` is mutable at runtime as of vmlx
        /// `b9da180` via `BatchEngine.updateMaxBatchSize(_:)`. When a later
        /// request asks for a different `maxBatchSize` than the cached
        /// engine's, we hot-resize the existing engine instead of rebuilding
        /// (which would have raced in-flight callers holding the cached
        /// handle). vmlx's `updateMaxBatchSize` is fail-closed: an
        /// `engineShutdown` throw means the engine has been torn down and
        /// the next caller will create a fresh one through the coalescer.
        ///
        /// Submitting to a shut-down engine returns a `.cancelled` info
        /// event from vmlx (`b9da180`), so even if a stale handle leaks
        /// past this gate the upstream stream finishes cleanly instead of
        /// restarting GPU work.
        func engine(
            for modelName: String,
            container: ModelContainer,
            maxBatchSize: Int
        ) async -> BatchEngine {
            let engine = await makeAndRegister(
                modelName: modelName,
                maxBatchSize: maxBatchSize
            ) {
                await container.makeBatchEngine(maxBatchSize: maxBatchSize)
            }
            // `BatchEngine.maxBatchSize` is actor-isolated; the await
            // suspends the registry actor while we read it. Subsequent
            // callers see the engine in `coalescer` already and won't
            // race the read.
            let cached = await engine.maxBatchSize
            if cached != maxBatchSize {
                do {
                    try await engine.updateMaxBatchSize(maxBatchSize)
                    batchAdapterLog.info(
                        "registry: hot-resized BatchEngine for \(modelName, privacy: .public) maxBatchSize=\(cached, privacy: .public) → \(maxBatchSize, privacy: .public)"
                    )
                } catch BatchEngineConfigurationError.engineShutdown {
                    // The cached engine was torn down between calls. Leaving
                    // it in `values` would loop here forever (every future
                    // call would resize-fail-and-return the same dead
                    // handle). Evict it so the coalescer's next first-fetch
                    // builds a fresh engine. The dispose step is a defensive
                    // shutdown — vmlx makes shutdown idempotent, and
                    // tombstoning across the dispose blocks racers from
                    // building a fresh BatchEngine on the same
                    // `ModelContainer` while teardown completes.
                    batchAdapterLog.notice(
                        "registry: cached BatchEngine for \(modelName, privacy: .public) is shut down; evicting and rebuilding at maxBatchSize=\(maxBatchSize, privacy: .public)"
                    )
                    await coalescer.remove(modelName) { engine in
                        await engine.shutdown()
                    }
                    // Rebuild via the same path. The new engine is
                    // constructed with `maxBatchSize` directly, so the
                    // resize check on the recursive call sees a match and
                    // skips `updateMaxBatchSize`.
                    return await self.engine(
                        for: modelName,
                        container: container,
                        maxBatchSize: maxBatchSize
                    )
                } catch {
                    // Other errors (e.g. `invalidMaxBatchSize` from a
                    // caller bug) leave the cached engine intact — it's
                    // still serving requests at its construction value, and
                    // the next valid resize call will succeed.
                    batchAdapterLog.notice(
                        "registry: BatchEngine for \(modelName, privacy: .public) rejected updateMaxBatchSize(\(maxBatchSize, privacy: .public)) — \(String(describing: error), privacy: .public). Engine continues at cached \(cached, privacy: .public)."
                    )
                }
            }
            return engine
        }

        /// Test seam. Coalesces a concurrent first-fetch using a custom
        /// `factory`, returning whatever the factory produces. Production
        /// callers go through `engine(for:container:maxBatchSize:)`. The
        /// `maxBatchSize` argument is only used in the log line.
        internal func makeAndRegister(
            modelName: String,
            maxBatchSize: Int,
            factory: @Sendable @escaping () async -> BatchEngine
        ) async -> BatchEngine {
            let engine = await coalescer.value(for: modelName, factory: factory)
            batchAdapterLog.info(
                "registry: ready BatchEngine for \(modelName, privacy: .public) maxBatchSize=\(maxBatchSize, privacy: .public)"
            )
            return engine
        }

        /// Diagnostic accessor. Test-only; production callers do not need
        /// to inspect the coalescer's internal state. `draining` reports
        /// engines whose in-flight creation has been claimed by a
        /// concurrent `shutdownEngine` / `shutdownAll` but whose factory
        /// has not yet completed.
        internal func registrySnapshot() async -> (resolved: Int, inFlight: Int, draining: Int) {
            await coalescer.snapshot()
        }

        func recordEffectiveGenerationSettings(
            modelName: String,
            settings: EffectiveGenerationSettings
        ) {
            lastEffectiveGenerationSettings[modelName] = settings
        }

        func lastEffectiveGenerationSettingsSnapshot() -> [String: EffectiveGenerationSettings] {
            lastEffectiveGenerationSettings
        }

        /// Aggregate live BatchEngine diagnostics across every resolved
        /// engine in the registry. Used by the Server → Settings panel
        /// to render the "Live Diagnostics" subsection. Returns `nil`
        /// when no engine has been created yet.
        func snapshotDiagnostics() async -> BatchDiagnosticsSnapshot? {
            let engines = await coalescer.resolvedValues()
            guard !engines.isEmpty else { return nil }

            var pending = 0
            var active = 0
            var highWatermark = 0
            var decodeSplit = 0
            var turbo = 0
            var accepting = true
            let modelSummaries = await ModelRuntime.shared.cachedModelSummaries()
            var nativeDepths = Set<Int>()
            var cacheEnabled = 0
            var hybrid = 0
            var pagedIncompatible = 0
            var prefixHits = 0
            var prefixMisses = 0
            var diskL2Hits = 0
            var diskL2Misses = 0
            var diskL2Stores = 0
            var ssmHits = 0
            var ssmMisses = 0
            var ssmReDerives = 0
            for summary in modelSummaries {
                if let depth = summary.nativeMTPDepth {
                    nativeDepths.insert(depth)
                }
                guard let stats = summary.cacheStats else { continue }
                cacheEnabled += 1
                if stats.isHybrid { hybrid += 1 }
                if stats.isPagedIncompatible { pagedIncompatible += 1 }
                if let pagedStats = stats.pagedStats {
                    prefixHits += pagedStats.cacheHits
                    prefixMisses += pagedStats.cacheMisses
                }
                if let diskStats = stats.diskStats {
                    diskL2Hits += diskStats.hits
                    diskL2Misses += diskStats.misses
                    diskL2Stores += diskStats.stores
                }
                ssmHits += stats.ssmStats.hits
                ssmMisses += stats.ssmStats.misses
                ssmReDerives += stats.ssmStats.reDerives
            }
            for engine in engines {
                pending += await engine.pendingCount
                active += await engine.activeCount
                let watermark = await engine.activeCountHighWatermarkForDiagnostics
                highWatermark = max(highWatermark, watermark)
                decodeSplit += await engine.decodeCompatibilitySplitCountForDiagnostics
                turbo += await engine.turboQuantCompressionCountForDiagnostics
                if !(await engine.isAcceptingRequests) {
                    accepting = false
                }
            }
            return BatchDiagnosticsSnapshot(
                pendingCount: pending,
                activeCount: active,
                activeHighWatermark: highWatermark,
                decodeSplitCount: decodeSplit,
                turboQuantCompressions: turbo,
                isAcceptingRequests: accepting,
                loadedModelCount: modelSummaries.count,
                nativeMTPModelCount: modelSummaries.filter { $0.nativeMTPDepth != nil }.count,
                nativeMTPDepthSummary: nativeDepths.sorted().map { "d\($0)" }.joined(separator: ", "),
                cacheEnabledModelCount: cacheEnabled,
                hybridModelCount: hybrid,
                pagedIncompatibleModelCount: pagedIncompatible,
                prefixHits: prefixHits,
                prefixMisses: prefixMisses,
                diskL2Hits: diskL2Hits,
                diskL2Misses: diskL2Misses,
                diskL2Stores: diskL2Stores,
                ssmCompanionHits: ssmHits,
                ssmCompanionMisses: ssmMisses,
                ssmCompanionReDerives: ssmReDerives
            )
        }

        /// Shut down and remove the engine for `modelName`. Safe to call
        /// when no engine exists. Pending requests on the engine receive a
        /// `.cancelled` info event before the actor exits.
        ///
        /// Uses the coalescer's `dispose:` variant so the
        /// `engine.shutdown()` call runs INSIDE the `draining[key]`
        /// tombstone window. A racing `value(for:)` for the same model
        /// waits for the shutdown to complete before its post-drain fresh
        /// factory builds a new `BatchEngine` — preventing two engines on
        /// one `ModelContainer` (the Metal-abort scenario the registry
        /// exists to prevent).
        func shutdownEngine(for modelName: String) async {
            nativeMTPWarmModels.remove(modelName)
            await coalescer.remove(modelName) { engine in
                await engine.shutdown()
                batchAdapterLog.info(
                    "registry: shutdown BatchEngine for \(modelName, privacy: .public)"
                )
            }
        }

        /// Shut down every cached engine. Used by `ModelRuntime.clearAll()`.
        /// Drains in-flight creations and resolved entries through the
        /// coalescer's `dispose:` variant so per-key tombstones stay set
        /// across the per-engine `shutdown()` — same race protection as
        /// `shutdownEngine(for:)`, applied to every cached entry.
        func shutdownAll() async {
            nativeMTPWarmModels.removeAll()
            await coalescer.removeAll { modelName, engine in
                await engine.shutdown()
                batchAdapterLog.info(
                    "registry: shutdown BatchEngine for \(modelName, privacy: .public)"
                )
            }
        }

        func acquireSoloLease(for modelName: String) async -> SoloGenerationGate.Lease {
            await soloGate.acquire(modelName: modelName)
        }

        func consumeNativeMTPColdWarmup(modelName: String, requested: Bool) -> Bool {
            guard requested else { return false }
            if nativeMTPWarmModels.contains(modelName) {
                return false
            }
            nativeMTPWarmModels.insert(modelName)
            batchAdapterLog.info(
                "native MTP cold warmup: first request for \(modelName, privacy: .public) uses AR before enabling native MTP"
            )
            return true
        }

        func isNativeMTPWarm(modelName: String) -> Bool {
            nativeMTPWarmModels.contains(modelName)
        }

        /// Un-warms a model whose load-time warmup generation failed after
        /// it had already consumed the cold-warmup flag, so the next real
        /// request runs the AR warmup exactly as it would have without the
        /// load-time attempt.
        func resetNativeMTPWarmup(modelName: String) {
            nativeMTPWarmModels.remove(modelName)
        }

    }

    // MARK: - Native MTP load-time warmup

    /// Escape hatch in case a family surfaces a first-generation issue that
    /// the two-token warmup does not absorb:
    ///   defaults write ai.osaurus ai.osaurus.mtp.disableLoadWarmup -bool true
    static let mtpLoadWarmupDisabledKey = "ai.osaurus.mtp.disableLoadWarmup"

    /// Runs the native-MTP cold warmup at model-load time instead of on the
    /// user's first request. The registry's cold-warmup rule forces the
    /// first generation per model into plain AR mode; without this, that
    /// "first generation" is the user's entire first response, which
    /// silently loses the MTP decode speedup. A hidden two-token greedy
    /// generation through the regular `generate` path (so gating, engine
    /// creation, and solo-lease behavior are identical to a real request)
    /// consumes the warmup for a fraction of a second instead.
    ///
    /// Failure is non-fatal and self-healing: the warm flag is reset so the
    /// next real request performs the AR warmup exactly as before.
    static func warmupNativeMTPAtLoad(
        modelName: String,
        container: ModelContainer,
        draftStrategy: MLXLMCommon.DraftStrategy?,
        runtime: RuntimeConfig,
        maxBatchSize: Int
    ) async {
        guard draftStrategy?.usesNativeMTP == true else { return }
        guard !UserDefaults.standard.bool(forKey: mtpLoadWarmupDisabledKey) else { return }
        guard await !Registry.shared.isNativeMTPWarm(modelName: modelName) else { return }

        let startedAt = CFAbsoluteTimeGetCurrent()
        do {
            let prepared = try await generate(
                modelName: modelName,
                container: container,
                buildChat: { [MLXLMCommon.Chat.Message(role: .user, content: "Hi")] },
                buildToolsSpec: { nil },
                // `effectiveSettingsStage: "load_warmup"` labels the /admin
                // `last_effective_generation` row this hidden generation
                // writes, so a maintainer reading the endpoint post-load
                // pre-traffic doesn't mistake its engaged=false/cold_warmup
                // record for a real user request.
                generation: GenerationParameters(
                    temperature: 0,
                    maxTokens: 2,
                    effectiveSettingsStage: "load_warmup"
                ),
                toolChoice: nil,
                stopSequences: [],
                draftStrategy: draftStrategy,
                runtime: runtime,
                maxBatchSize: maxBatchSize
            )
            for await _ in prepared.stream {}
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            batchAdapterLog.info(
                "native MTP load warmup: completed for \(modelName, privacy: .public) in \(elapsedMs, privacy: .public)ms; first user request decodes with MTP"
            )
        } catch {
            // The failed generation may already have consumed the warm flag;
            // reset it so the request path's AR warmup applies unchanged.
            await Registry.shared.resetNativeMTPWarmup(modelName: modelName)
            batchAdapterLog.notice(
                "native MTP load warmup failed for \(modelName, privacy: .public): \(String(describing: error), privacy: .public) — falling back to first-request AR warmup"
            )
        }
    }

    // MARK: - Image preprocessing

    private static let maxImageSize = CGSize(width: 1024, height: 1024)

    private static func downscaleIfNeeded(_ image: CIImage) -> CIImage {
        let scale = min(MediaProcessing.bestFitScale(image.extent.size, in: maxImageSize), 1.0)
        guard scale < 1.0 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    /// Downscale CIImage attachments to a sane upper bound before tokenization.
    /// Pre-existing `URL` / `array` cases pass through untouched.
    ///
    /// Preserves media plus `reasoningContent`, `toolCalls`, and `toolCallId`
    /// through the rebuild. Dropping any of these fields silently unwinds the
    /// structured handoff set up by `ModelRuntime.mapOpenAIChatToMLX`: ZAYA,
    /// Nemotron-H/Omni, MiniMax, and DSV4 templates read
    /// `message.reasoning_content`; MiniMax and other templates read
    /// `message.tool_calls[i]`; omni/VL processors read media arrays.
    private static func preprocessImages(in chat: [MLXLMCommon.Chat.Message]) -> [MLXLMCommon.Chat.Message] {
        chat.map { message in
            let processedImages = message.images.map { userInputImage -> UserInput.Image in
                switch userInputImage {
                case .ciImage(let ciImage):
                    return .ciImage(downscaleIfNeeded(ciImage))
                default:
                    return userInputImage
                }
            }
            return MLXLMCommon.Chat.Message(
                role: message.role,
                content: message.content,
                images: processedImages,
                videos: message.videos,
                audios: message.audios,
                reasoningContent: message.reasoningContent,
                toolCalls: message.toolCalls,
                toolCallId: message.toolCallId
            )
        }
    }

    static func preencodeAudioSources(
        in chat: [MLXLMCommon.Chat.Message],
        encode: (MLXLMCommon.UserInput.Audio) throws -> MLXLMCommon.UserInput.Audio?
    ) rethrows -> AudioPreencodeResult {
        var inputCount = 0
        var convertedCount = 0
        var alreadyPreencodedCount = 0

        let mapped = try chat.map { message in
            guard !message.audios.isEmpty else { return message }
            var updated = message
            updated.audios = try message.audios.map { audio in
                inputCount += 1
                if case .preEncoded = audio {
                    alreadyPreencodedCount += 1
                    return audio
                }
                if let encoded = try encode(audio) {
                    convertedCount += 1
                    return encoded
                }
                return audio
            }
            return updated
        }

        return AudioPreencodeResult(
            chat: mapped,
            inputCount: inputCount,
            convertedCount: convertedCount,
            alreadyPreencodedCount: alreadyPreencodedCount
        )
    }

    private static func preencodeNemotronOmniAudioIfPossible(
        in chat: [MLXLMCommon.Chat.Message],
        modelName: String,
        model: any LanguageModel,
        trace: TTFTTrace?
    ) throws -> [MLXLMCommon.Chat.Message] {
        guard ModelFamilyNames.isNemotronOmniFamily(modelName),
            let omni = model as? NemotronHOmni
        else {
            return chat
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        let result = try preencodeAudioSources(in: chat) { audio in
            try preencodedAudio(audio, using: omni)
        }
        guard result.inputCount > 0 else { return result.chat }

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        trace?.set("omni_audio_preencode_input_count", result.inputCount)
        trace?.set("omni_audio_preencode_converted_count", result.convertedCount)
        trace?.set("omni_audio_preencode_existing_count", result.alreadyPreencodedCount)
        trace?.set("omni_audio_preencode_ms", elapsedMs)
        trace?.mark("omni_audio_preencode_done")
        batchAdapterLog.info(
            "preencodeAudio: model=\(modelName, privacy: .public) input=\(result.inputCount, privacy: .public) converted=\(result.convertedCount, privacy: .public) existing=\(result.alreadyPreencodedCount, privacy: .public) ms=\(elapsedMs, privacy: .public)"
        )
        return result.chat
    }

    static func preencodedAudio(
        _ audio: MLXLMCommon.UserInput.Audio,
        using omni: NemotronHOmni
    ) throws -> MLXLMCommon.UserInput.Audio? {
        let samples16k: [Float]
        switch audio {
        case .url(let url):
            samples16k = try nemotronOmniLoadAudioFile(
                url,
                targetSampleRate: Double(omni.config.soundSampleRate)
            )
        case .samples(let samples, let sampleRate):
            samples16k =
                sampleRate == omni.config.soundSampleRate
                ? samples
                : linearResamplePCM(
                    samples,
                    fromRate: sampleRate,
                    toRate: omni.config.soundSampleRate
                )
        case .array(let array, let sampleRate):
            let samples = array.reshaped([-1]).asType(.float32).asArray(Float.self)
            samples16k =
                sampleRate == omni.config.soundSampleRate
                ? samples
                : linearResamplePCM(
                    samples,
                    fromRate: sampleRate,
                    toRate: omni.config.soundSampleRate
                )
        case .preEncoded:
            return nil
        }

        let embedding = omni.extractAudioEmbeds(waveform: samples16k)
        MLX.eval(embedding)
        return .preEncoded(
            samples: samples16k,
            sampleRate: omni.config.soundSampleRate,
            embedding: embedding
        )
    }

    // MARK: - Thinking template context

    static func additionalContext(
        for generation: GenerationParameters,
        modelName: String,
        toolChoice: ToolChoiceOption? = nil,
        toolChoiceName: String? = nil
    ) -> [String: any Sendable] {
        var context: [String: any Sendable] = [:]
        if toolChoiceRequiresLocalCall(toolChoice) {
            context["tool_choice"] = "required"
        }
        if let toolChoiceName,
            !toolChoiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            context["tool_choice_name"] = toolChoiceName
        }
        let normalizedReasoningEffort: String? = {
            guard let effort = generation.modelOptions["reasoningEffort"]?.stringValue else {
                return nil
            }
            let normalized = effort.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }()
        let disableThinking = generation.modelOptions["disableThinking"]?.boolValue
        let directRailReasoningEffort = Self.isDirectRailReasoningEffort(normalizedReasoningEffort)
        let hasPositiveReasoningEffort =
            normalizedReasoningEffort != nil && !directRailReasoningEffort

        if DSV4ReasoningProfile.matches(modelId: modelName) {
            guard normalizedReasoningEffort != nil || disableThinking != nil else {
                return context
            }
            let effort: String
            if let normalizedReasoningEffort {
                effort = DSV4ReasoningProfile.normalizedEffort(normalizedReasoningEffort)
            } else if let disableThinking {
                effort = disableThinking ? "instruct" : "high"
            } else {
                return context
            }

            switch effort {
            case "max":
                context["enable_thinking"] = true
                context["reasoning_effort"] = "max"
            case "high":
                context["enable_thinking"] = true
                context["reasoning_effort"] = "high"
            default:
                context["enable_thinking"] = false
            }
            return context
        }

        if Hy3ReasoningProfile.matches(modelId: modelName) {
            if let normalizedReasoningEffort {
                context["reasoning_effort"] = Hy3ReasoningProfile.normalizedEffort(
                    normalizedReasoningEffort
                )
            } else if let disableThinking {
                context["reasoning_effort"] = disableThinking ? "no_think" : "high"
            }
            return context
        }

        if ModelFamilyNames.isLingFamily(modelName) {
            if let disableThinking {
                context["enable_thinking"] = !disableThinking
            } else if normalizedReasoningEffort != nil {
                context["enable_thinking"] = hasPositiveReasoningEffort
            }
            return context
        }

        if ModelFamilyNames.isZayaVLFamily(modelName) {
            return context
        }

        if let disableThinking {
            context["enable_thinking"] = !disableThinking
            if !disableThinking, let normalizedReasoningEffort {
                context["reasoning_effort"] = normalizedReasoningEffort
            }
            return context
        }
        if ModelFamilyNames.isQwenFamily(modelName) {
            if directRailReasoningEffort {
                context["enable_thinking"] = false
                return context
            }
            if hasPositiveReasoningEffort, let normalizedReasoningEffort {
                context["enable_thinking"] = true
                context["reasoning_effort"] = normalizedReasoningEffort
            } else {
                context["enable_thinking"] = false
            }
            return context
        }
        if ModelFamilyNames.isNemotronThinkingFamily(modelName) {
            if directRailReasoningEffort {
                context["enable_thinking"] = false
                return context
            }
            if hasPositiveReasoningEffort, let normalizedReasoningEffort {
                context["enable_thinking"] = true
                context["reasoning_effort"] = normalizedReasoningEffort
            } else {
                context["enable_thinking"] = false
            }
            return context
        }
        if ModelFamilyNames.isZayaFamily(modelName) {
            if directRailReasoningEffort {
                context["enable_thinking"] = false
                return context
            }
            if hasPositiveReasoningEffort, let normalizedReasoningEffort {
                context["enable_thinking"] = true
                context["reasoning_effort"] = normalizedReasoningEffort
            } else {
                context["enable_thinking"] = false
            }
            return context
        }
        if ModelFamilyNames.isMiniMaxFamily(modelName) {
            if directRailReasoningEffort {
                context["enable_thinking"] = false
                return context
            }
            if hasPositiveReasoningEffort, let normalizedReasoningEffort {
                context["enable_thinking"] = true
                context["reasoning_effort"] = normalizedReasoningEffort
            } else {
                context["enable_thinking"] = false
            }
            return context
        }

        if ModelFamilyNames.isLFM2Family(modelName) {
            if toolChoiceRequiresLocalCall(toolChoice) {
                context["enable_thinking"] = false
            } else if let disableThinking {
                context["enable_thinking"] = !disableThinking
            } else if normalizedReasoningEffort != nil {
                context["enable_thinking"] = hasPositiveReasoningEffort
            }
            return context
        }
        if ModelFamilyNames.isStepFamily(modelName) {
            if toolChoiceRequiresLocalCall(toolChoice) {
                context["enable_thinking"] = false
            } else if let disableThinking {
                context["enable_thinking"] = !disableThinking
            } else if normalizedReasoningEffort != nil {
                context["enable_thinking"] = hasPositiveReasoningEffort
            }
            return context
        }
        if ModelFamilyNames.isMiMoOrN2JANGRuntimeFamily(modelName) {
            if toolChoiceRequiresLocalCall(toolChoice) {
                context["enable_thinking"] = false
                return context
            }
            if directRailReasoningEffort {
                context["enable_thinking"] = false
                return context
            }
            if let disableThinking {
                context["enable_thinking"] = !disableThinking
            } else if hasPositiveReasoningEffort, let normalizedReasoningEffort {
                context["enable_thinking"] = true
                context["reasoning_effort"] = normalizedReasoningEffort
            } else if normalizedReasoningEffort != nil {
                context["enable_thinking"] = false
            }
            return context
        }
        if ModelFamilyNames.isGemmaFamily(modelName) {
            if directRailReasoningEffort {
                context["enable_thinking"] = false
                return context
            }
            if hasPositiveReasoningEffort, let normalizedReasoningEffort {
                context["enable_thinking"] = true
                context["reasoning_effort"] = normalizedReasoningEffort
            } else {
                context["enable_thinking"] = false
            }
            return context
        }

        if let normalizedReasoningEffort, !directRailReasoningEffort {
            context["reasoning_effort"] = normalizedReasoningEffort
            context["enable_thinking"] = true
        }
        if directRailReasoningEffort {
            context["enable_thinking"] = false
            return context
        }
        return context
    }

    private static func toolChoiceRequiresLocalCall(_ toolChoice: ToolChoiceOption?) -> Bool {
        guard let toolChoice else { return false }
        switch toolChoice {
        case .required, .function(_):
            return true
        case .auto, .none:
            return false
        }
    }

    private static func requiredToolChoiceName(
        toolChoice: ToolChoiceOption?,
        toolsSpec: [[String: any Sendable]]?
    ) -> String? {
        guard let toolChoice else { return nil }
        switch toolChoice {
        case .function(let target):
            return target.function.name
        case .required:
            guard let toolsSpec, toolsSpec.count == 1 else { return nil }
            let tool = toolsSpec[0]
            let function = (tool["function"] as? [String: any Sendable]) ?? tool
            return function["name"] as? String
        case .auto, .none:
            return nil
        }
    }

    private static func isDirectRailReasoningEffort(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "instruct", "chat", "none", "no_think", "nothink", "off", "disabled", "false":
            return true
        default:
            return false
        }
    }

    static func shouldEnableCompiledBatchDecode(modelName: String, maxBatchSize: Int) -> Bool {
        maxBatchSize == 1
            && !Hy3ReasoningProfile.matches(modelId: modelName)
            && !ModelFamilyNames.isMiniMaxFamily(modelName)
            && !ModelFamilyNames.isStepFamily(modelName)
            && !ModelRuntime.isKnownHybridModel(name: modelName)
    }

    // MARK: - Submission

    /// Sendable box for a chat snapshot built once before the prep gate.
    ///
    /// `MLXLMCommon.Chat.Message` is not `Sendable`, but the snapshot is
    /// immutable and only read from the downstream `buildChat` closure —
    /// same rationale as `ModelRuntime.ChatMessageBox`.
    private final class PrepChatBox: @unchecked Sendable {
        let messages: [MLXLMCommon.Chat.Message]
        init(_ messages: [MLXLMCommon.Chat.Message]) { self.messages = messages }

        /// Media attachments mean `prepareInput` will run GPU evals (audio
        /// pre-encode, VLM media encode) on the submitting thread.
        var hasMedia: Bool {
            messages.contains {
                !($0.images.isEmpty && $0.videos.isEmpty && $0.audios.isEmpty)
            }
        }
    }

    /// Tokenize the chat + tools, fetch (or create) the per-model
    /// `BatchEngine`, and submit one request via `engine.generate`. Returns
    /// the resulting `Generation` stream wrapped with cancellation plumbing.
    static func generate(
        modelName: String,
        container: ModelContainer,
        buildChat: @Sendable () -> [MLXLMCommon.Chat.Message],
        buildToolsSpec: @Sendable () -> [[String: any Sendable]]?,
        buildRawPrompt: (@Sendable () -> String)? = nil,
        generation: GenerationParameters,
        toolChoice: ToolChoiceOption?,
        stopSequences: [String],
        draftStrategy: MLXLMCommon.DraftStrategy?,
        runtime: RuntimeConfig,
        maxBatchSize: Int
    ) async throws -> PreparedStream {
        let trace = generation.ttftTrace
        trace?.mark("batch_prepare_start")
        // Prefill diagnostics: a generation step's clock starts HERE. The
        // solo-lease acquire below blocks until the PREVIOUS step's producer
        // task has released — and that release happens only after vmlx's
        // post-generation disk-cache store. So `LEASE-ACQUIRED waitMs` measures
        // exactly how long this step waited on the prior step's KV store.
        let genEnterAt = CFAbsoluteTimeGetCurrent()
        PrefillDebugLog.shared.log(
            "==GEN GENERATE-ENTER model=\(modelName) maxBatch=\(maxBatchSize)"
        )
        let soloLease =
            maxBatchSize == 1
            ? await Registry.shared.acquireSoloLease(for: modelName)
            : nil
        if Task.isCancelled {
            if let soloLease { await soloLease.release() }
            throw CancellationError()
        }
        PrefillDebugLog.shared.log(
            "==GEN LEASE-ACQUIRED model=\(modelName) "
                + "waitMs=\(Int((CFAbsoluteTimeGetCurrent() - genEnterAt) * 1000)) "
                + "solo=\(soloLease != nil)"
        )

        // `prepareInput` can run a GPU eval on THIS submit thread before the
        // generation gate is taken below — notably the Nemotron-Omni audio
        // pre-encode (`MLX.eval` in `preencodedAudio`) and any media encoder
        // that materializes during `UserInputProcessor.prepare`. Those evals
        // happen OUTSIDE the `BatchEngine` actor loop, so under the shared
        // `gen:` owner they could encode concurrently with an in-flight
        // decode or another request's prep on the shared Metal command queue
        // (the driver-assert crash class the gate exists to prevent). So:
        // media-bearing prep takes the gate EXCLUSIVELY; text-only prep does
        // no GPU encode (CPU tokenization + data-backed arrays) and keeps the
        // shared generation owner, preserving same-model batching. Either
        // acquire is fully balanced before the generation gate below; the
        // brief window between them is eval-free.
        // Snapshot the chat once up front (empty on the raw-prompt path,
        // where `prepareInput` never invokes its chat builder). The box keeps
        // the snapshot Sendable, and passing a box-backed closure below —
        // rather than rebinding the non-escaping `buildChat` parameter —
        // avoids both a second `buildChat()` call and an escaping-parameter
        // diagnostic.
        let prepChat = PrepChatBox(buildRawPrompt == nil ? buildChat() : [])
        let prepIsExclusive = prepChat.hasMedia
        let prepared: PreparedInput
        if prepIsExclusive {
            await MetalGate.shared.enterMediaPrep(model: modelName)
        } else {
            await MetalGate.shared.enterGeneration(model: modelName)
        }
        func exitPrepGate() async {
            if prepIsExclusive {
                await MetalGate.shared.exitMediaPrep(model: modelName)
            } else {
                await MetalGate.shared.exitGeneration(model: modelName)
            }
        }
        do {
            prepared = try await prepareInput(
                modelName: modelName,
                container: container,
                buildChat: { prepChat.messages },
                buildToolsSpec: buildToolsSpec,
                buildRawPrompt: buildRawPrompt,
                generation: generation,
                toolChoice: toolChoice,
                trace: trace
            )
            await exitPrepGate()
        } catch {
            await exitPrepGate()
            if let soloLease { await soloLease.release() }
            throw error
        }

        // Timeline breadcrumb for diagnosing main-thread hangs that surface with an
        // unsymbolicated native (MLX/Metal) stack: records what inference was in flight.
        // Identifiers and counts only, never prompt content.
        CrashReportingService.recordBreadcrumb(
            category: "inference.generate",
            message: "begin model=\(modelName) input_tokens=\(prepared.promptTokens.count) batch=\(maxBatchSize)"
        )

        let engine = await Registry.shared.engine(
            for: modelName,
            container: container,
            maxBatchSize: maxBatchSize
        )

        // Honor the model's shipped generation defaults when the OpenAI-wire
        // request omits a field. This mirrors vmlx's direct-engine
        // `GenerateParameters(generationConfig:fallback:)` behavior for the
        // local app path instead of inventing osaurus-specific defaults.
        let modelDefaults = LocalGenerationDefaults.defaults(forModelId: modelName)
        let nativeMTPColdWarmup = await Registry.shared.consumeNativeMTPColdWarmup(
            modelName: modelName,
            requested: draftStrategy?.usesNativeMTP == true
        )
        let effectiveDraftStrategy = Self.effectiveDraftStrategy(
            generation: generation,
            draftStrategy: draftStrategy,
            promptTokenCount: prepared.promptTokens.count,
            disableNativeMTP: nativeMTPColdWarmup
        )
        let nativeMTPFallbackReason = Self.nativeMTPFallbackReason(
            generation: generation,
            draftStrategy: draftStrategy,
            promptTokenCount: prepared.promptTokens.count,
            coldWarmup: nativeMTPColdWarmup
        )
        let nativeMTPExplicitSamplingFallback =
            draftStrategy?.usesNativeMTP == true && effectiveDraftStrategy == nil
        // Attribution fields are filled in below, AFTER the vmlx
        // `GenerateParameters` are fully constructed — the engine
        // re-checks its own eligibility gate on the effective (merged)
        // sampling values, which are only knowable from `mlxParams`.
        var effective = Self.effectiveGenerationSettings(
            modelName: modelName,
            generation: generation,
            runtimeDefaults: runtime.generation,
            maxBatchSize: maxBatchSize,
            modelDefaults: modelDefaults,
            draftStrategy: effectiveDraftStrategy,
            nativeMTPExplicitSamplingFallback: nativeMTPExplicitSamplingFallback,
            stage: Self.submitStage(for: generation)
        )
        var mlxParams = ModelRuntime.makeGenerateParameters(
            temperature: effective.temperature,
            maxTokens: effective.maxTokens,
            topP: effective.topP,
            topK: effective.topK,
            minP: effective.minP,
            repetitionPenalty: effective.repetitionPenalty,
            presencePenalty: generation.presencePenalty,
            frequencyPenalty: generation.frequencyPenalty,
            randomSeed: generation.seed,
            stopSequences: stopSequences,
            draftStrategy: effectiveDraftStrategy,
            enableCompiledBatchDecode: effective.compiledBatchDecode,
            prefillStepSize: runtime.concurrency.prefillStepSize,
            modelName: modelName
        )
        // Block-diffusion speed/quality budget (DiffusionGemma): server
        // setting, default 16 (seeded by ServerRuntimeSettingsStore).
        // nil = bundle's generation_config.json value. Ignored by
        // autoregressive models.
        mlxParams.diffusionMaxDenoisingSteps =
            runtime.generation.diffusionMaxDenoisingSteps
        let cacheTopology = await container.cacheTopologySnapshot()
        let effectiveKVMode = ModelRuntime.defaultKVMode(
            for: ServerRuntimeSettingsStore.snapshot().cache,
            modelName: modelName,
            cacheTopology: cacheTopology
        )
        if case .none = mlxParams.kvMode {
            mlxParams.kvMode = effectiveKVMode
        }

        // Boundary attribution, built once from the SAME values submitted
        // to the engine — never recomputed downstream, so the stats-hint
        // flags, `/admin` JSON, and the per-submit os_log line below stay
        // in agreement. `mlxParams` is fully constructed at this point, so
        // `canUseNativeMTP(for:)` is vmlx's exact solo-fast-path gate
        // (effective sampling values + media content), not a
        // reimplementation.
        let attribution = Self.engineAttribution(
            soloLeaseHeld: soloLease != nil,
            // The engine's own dispatch predicate (`context.model is any
            // BlockDiffusionModel`, BatchEngine.swift:581), evaluated on
            // the loaded model instance inside `prepareInput`'s existing
            // `container.perform` hop — coextensive with the engine's
            // routing by construction, and zero added hops.
            isBlockDiffusionModel: prepared.isBlockDiffusionModel,
            requestedDraftStrategy: draftStrategy,
            submittedDraftStrategy: effectiveDraftStrategy,
            engineNativeMTPEligible: mlxParams.canUseNativeMTP(for: prepared.input),
            submittedMaxTokens: mlxParams.maxTokens,
            promptTokenCount: prepared.promptTokens.count,
            osaurusFallbackReason: nativeMTPFallbackReason
        )
        effective.enginePath = attribution.enginePath
        effective.nativeMTPRequested = attribution.nativeMTPRequested
        effective.nativeMTPEngaged = attribution.nativeMTPEngaged
        effective.nativeMTPFallbackReason = attribution.nativeMTPFallbackReason
        await Registry.shared.recordEffectiveGenerationSettings(
            modelName: modelName,
            settings: effective
        )

        // Per-request determinism now rides `GenerateParameters.randomSeed`
        // (set above): vmlx builds each request's sampler around its own
        // seeded `RandomState`, which is the only state sampling consults.
        // The previous global `MLXRandom.seed()` call was a sampling no-op
        // AND leaked deterministic state into unrelated global-RNG
        // consumers (diffusion decode, image latents), so it is gone.

        await MainActor.run {
            if !generation.suppressProgressUI {
                InferenceProgressManager.shared.prefillWillStart(
                    tokenCount: prepared.promptTokens.count
                )
            } else {
                WarmupProgressHub.shared.prefillWillStart(
                    model: modelName,
                    tokenCount: prepared.promptTokens.count
                )
            }
        }

        // Prefill diagnostics: snapshot the cumulative cache counters BEFORE the
        // step alongside the fully-tokenized prompt size. The matching STEP-STATS
        // line (from GenerationEventMapper) reports vmlx's actual promptTokenCount;
        // if it is smaller than tokenizedPrompt here, the KV prefix was reused.
        if PrefillDebugLog.shared.isEnabled {
            let before = await MLXBatchAdapter.snapshotDiagnostics()
            let cacheStr =
                before.map {
                    "cacheBefore{prefixHits=\($0.prefixHits) prefixMisses=\($0.prefixMisses) "
                        + "diskL2Hits=\($0.diskL2Hits) diskL2Misses=\($0.diskL2Misses) "
                        + "diskL2Stores=\($0.diskL2Stores)}"
                } ?? "cacheBefore{unavailable}"
            // Prefix-divergence: how many leading tokens match the previous
            // step. lcp≈min means this step prefix-extends (reuse possible); a
            // small lcp means early divergence → cold re-prefill. The tool/role
            // fields explain WHY a step diverged (e.g. the <tools> block
            // appearing/disappearing, or the last message flipping role).
            let (lcp, prevCount) = PrefillDebugLog.shared.recordPromptTokens(
                prepared.promptTokens,
                model: modelName
            )
            let toolsCount = buildToolsSpec()?.count ?? 0
            let lastRole = buildChat().last.map { "\($0.role)" } ?? "none"
            PrefillDebugLog.shared.log(
                "---- STEP-BEGIN model=\(modelName) "
                    + "tokenizedPrompt=\(prepared.promptTokens.count) "
                    + "lcpVsPrev=\(lcp)/\(prevCount) "
                    + "toolsInSpec=\(toolsCount) toolChoice=\(String(describing: toolChoice)) "
                    + "lastMsgRole=\(lastRole) \(cacheStr)"
            )
        }

        // `engine.generate` returns `AsyncStream<Generation>` directly with
        // reasoning + tool-call extraction handled inside vmlx. We re-wrap
        // it so we can attach a producer `Task` for cancellation.
        //
        // Important: vmlx emits terminal `.info` before it performs the
        // post-generation disk-cache store and then finishes its stream. The
        // solo lease must be held until the upstream stream is actually done;
        // releasing it at `.info` lets the next solo request enter
        // `prepareInput` while the previous request is still materializing
        // cache tensors on Metal.
        trace?.mark("batch_submit")
        CrashReportingService.recordBreadcrumb(
            category: "inference.generate",
            message: "submit model=\(modelName) batch=\(maxBatchSize)"
        )
        // Take the Metal gate's SHARED (generation) lock BEFORE submitting the
        // slot, so an external MLX user — the Model2Vec embedder behind
        // capability/memory search — cannot start a GPU eval while this
        // generation is in flight. Concurrent generations share the lock and
        // keep batching; only embedding is exclusive. Released by the producer
        // task once the upstream stream has fully drained, which (per the note
        // above) is AFTER vmlx's post-`.info` cache-store eval.
        await MetalGate.shared.enterGeneration(model: modelName)
        let upstream = await engine.generate(
            input: prepared.input,
            parameters: mlxParams
        )

        let (outStream, continuation) = AsyncStream<Generation>.makeStream()
        // Prefill diagnostics: clock the producer from submit. The upstream
        // loop drains only AFTER vmlx's post-`.info` disk-cache store, so
        // `STREAM-DRAINED postSubmitMs` = this step's decode + KV store, and the
        // lease (which the next step waits on) releases right after.
        let producerSubmitAt = CFAbsoluteTimeGetCurrent()
        let producerTask = Task<Void, Never> {
            await withTaskCancellationHandler {
                for await event in upstream {
                    if case .info = event {
                        continuation.yield(event)
                        continue
                    }
                    if !Task.isCancelled {
                        continuation.yield(event)
                    }
                }
            } onCancel: {
                // The upstream stream is bound to a single request inside
                // the engine; cancelling the consumer task closes it
                // cooperatively (engine emits a final `.info(.cancelled)`
                // and finishes the stream). Do not finish the wrapper from
                // here; the operation body gets the chance to drain and
                // forward that terminal `.info` event first.
            }
            // The upstream loop has fully drained (success or cancellation).
            // Finish the wrapper and release the solo lease *inline* —
            // `await`ed, not in a detached `Task` — so the lease is provably
            // released before this producer task completes. The old
            // `defer { Task { await soloLease.release() } }` released on an
            // unordered future hop, leaving a window where the next solo
            // request could enter `prepareInput` while this one's Metal
            // cache-store was still materializing.
            PrefillDebugLog.shared.log(
                "==GEN STREAM-DRAINED model=\(modelName) "
                    + "postSubmitMs=\(Int((CFAbsoluteTimeGetCurrent() - producerSubmitAt) * 1000)) "
                    + "(decode + post-gen disk store)"
            )
            continuation.finish()
            if let soloLease {
                await soloLease.release()
            }
            PrefillDebugLog.shared.log(
                "==GEN LEASE-RELEASED model=\(modelName) "
                    + "postSubmitMs=\(Int((CFAbsoluteTimeGetCurrent() - producerSubmitAt) * 1000))"
            )
            // Release the Metal gate's shared lock now that this generation's
            // GPU work (including the post-`.info` cache store) is fully done,
            // letting any waiting embedder run. Paired with the
            // `enterGeneration(model:)` taken before `engine.generate` above;
            // the producer task always runs to completion, so the pair always
            // balances.
            await MetalGate.shared.exitGeneration(model: modelName)
        }

        continuation.onTermination = { @Sendable _ in
            producerTask.cancel()
        }

        batchAdapterLog.info(
            "submit: model=\(modelName, privacy: .public) promptTokens=\(prepared.promptTokens.count, privacy: .public) temperature=\(effective.temperature, privacy: .public) topP=\(effective.topP, privacy: .public) topK=\(effective.topK, privacy: .public) minP=\(effective.minP, privacy: .public) maxTokens=\(effective.maxTokens, privacy: .public) engine=\(attribution.engineFlag, privacy: .public) draftStrategy=\(effectiveDraftStrategy?.kindName ?? "none", privacy: .public) nativeMTPFallback=\(attribution.nativeMTPFallbackReason ?? "none", privacy: .public) compiledBatchDecode=\(effective.compiledBatchDecode, privacy: .public)"
        )

        return PreparedStream(
            stream: outStream,
            promptTokens: prepared.promptTokens,
            genTask: producerTask,
            attribution: attribution
        )
    }

    // MARK: - Tokenization

    private struct PreparedInput: @unchecked Sendable {
        let input: LMInput
        let promptTokens: [Int]
        /// `context.model is any BlockDiffusionModel`, evaluated on the
        /// loaded model instance inside `prepareInput`'s existing
        /// `container.perform` closure (see
        /// `isBlockDiffusionModelInstance`). Carried back so the hot path
        /// gets the engine's exact dispatch predicate with zero added
        /// container hops.
        let isBlockDiffusionModel: Bool
    }

    /// The block-diffusion dispatch predicate `BatchEngine.generate` keys
    /// its routing on, verbatim: `context.model is any BlockDiffusionModel`
    /// (BatchEngine.swift:581) sends the request to the exclusive solo
    /// canvas path regardless of `maxBatchSize`. Evaluated on the loaded
    /// model INSTANCE, so it is coextensive with the engine's routing by
    /// construction — unlike any model-name or `model_type` proxy, a
    /// renamed fine-tune that conforms still detects and a look-alike
    /// model id that doesn't conform never false-positives.
    static func isBlockDiffusionModelInstance(_ model: any LanguageModel) -> Bool {
        model is any BlockDiffusionModel
    }

    /// Prepare a warm-up prompt as the send-invariant prefix of the NEXT
    /// real send's rendering.
    ///
    /// The warm-up payload is history-only (system + completed turns); the
    /// real send appends a user turn whose text is unknown at warm-up time.
    /// Rendering the history alone is not template-safe: some native
    /// templates require a user query (Ornith / qwen3_5 raises
    /// `'No user query found in messages.'`) and the tokenizer bridge then
    /// silently substitutes a built-in fallback template — the warm-up
    /// stores KV for a byte sequence the real send never renders, and the
    /// cache misses in full. Index-sensitive templates (reasoning replay
    /// keyed off the last user index) have the same divergence in milder
    /// form.
    ///
    /// Instead, render the history PLUS a probe user turn twice with two
    /// different probe texts, and keep the longest common token prefix.
    /// Whatever the template renders identically for both probes is by
    /// construction independent of the user text — the exact prefix the
    /// real send extends (system + tools + completed turns + the user-turn
    /// header). No template shape is assumed and nothing user-text-derived
    /// can leak into the stored prefix: any divergent token ends the LCP.
    ///
    /// Returns nil (caller falls back to
    /// ``truncatingToCanonicalCacheBoundary``) when the chat carries media,
    /// already ends in a user turn, a probe render fails, or the two probe
    /// renders share no usable prefix.
    static func prepareWarmupInputAtSendInvariantPrefix(
        chat: [MLXLMCommon.Chat.Message],
        toolsSpec: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable],
        processor: any MLXLMCommon.UserInputProcessor
    ) async -> LMInput? {
        let hasMedia = chat.contains {
            !$0.images.isEmpty || !$0.videos.isEmpty || !$0.audios.isEmpty
        }
        guard !hasMedia else { return nil }

        let prefix = await warmupSendInvariantPrefixTokens(chat: chat) { probeText in
            var probeChat = chat
            probeChat.append(.user(probeText))
            let input = MLXLMCommon.UserInput(
                chat: probeChat,
                processing: .init(),
                tools: toolsSpec,
                additionalContext: additionalContext
            )
            guard let prepared = try? await processor.prepare(input: input),
                !prepared.hasMediaContent
            else { return nil }
            return prepared.text.tokenIds
                ?? MLXCacheIOLock.withSerializedMLXCacheIO {
                    prepared.text.tokens.asArray(Int.self)
                }
        }

        guard let prefix else {
            batchAdapterLog.info(
                "warmupPrefill: probe renders unavailable or share no prefix; falling back to canonical boundary truncation"
            )
            return nil
        }

        // The scope salt is derived from additionalContext alone, so the
        // probe render's salt matches the real send's.
        let scopeSalt = MLXLMCommon.cacheScopeSalt(from: additionalContext)
        batchAdapterLog.info(
            "warmupPrefill: truncated prompt to send-invariant prefix of \(prefix.count, privacy: .public) tokens"
        )
        // Prompt tokens are batch-shaped [1, N] by processor contract (see
        // `truncatingToCanonicalCacheBoundary`).
        return LMInput(
            tokens: MLXArray(prefix).expandedDimensions(axis: 0),
            tokenIds: prefix,
            cacheScopeSalt: scopeSalt,
            cachePrefixTokenCounts: [],
            toolSchemas: toolsSpec
        )
    }

    /// Token-level core of ``prepareWarmupInputAtSendInvariantPrefix``:
    /// render the history plus two different probe user turns and return
    /// their longest common token prefix. Returns nil when the history
    /// already ends in a user turn (the next send would not simply append
    /// one), a probe render fails, or the renders share no usable prefix.
    static func warmupSendInvariantPrefixTokens(
        chat: [MLXLMCommon.Chat.Message],
        renderProbe: (String) async -> [Int]?
    ) async -> [Int]? {
        guard chat.last?.role != .user else { return nil }
        // Probe texts start with different characters so their first content
        // tokens differ and the LCP ends exactly at the user-turn header.
        guard let probeA = await renderProbe("0"),
            let probeB = await renderProbe("z"),
            let boundary = warmupSendInvariantBoundary(probeA: probeA, probeB: probeB)
        else { return nil }
        return Array(probeA.prefix(boundary))
    }

    /// Longest common token prefix of the two probe renders, or nil when it
    /// is unusable: empty (renders diverge immediately — nothing stable to
    /// store) or covering an entire probe render (the probes failed to
    /// diverge, so the boundary cannot be proven to exclude probe-derived
    /// tokens or the generation prompt).
    static func warmupSendInvariantBoundary(probeA: [Int], probeB: [Int]) -> Int? {
        let n = min(probeA.count, probeB.count)
        var lcp = 0
        while lcp < n, probeA[lcp] == probeB[lcp] { lcp += 1 }
        guard lcp > 0, lcp < probeA.count, lcp < probeB.count else { return nil }
        return lcp
    }

    /// Truncate a warm-up prompt to the processor's canonical history cache
    /// boundary (the render WITHOUT the generation prompt).
    ///
    /// The engine stores a finished request's KV under its exact prompt token
    /// sequence, and a later request can only restore a stored sequence that
    /// is a true token-prefix of its own prompt. A warm-up rendered with the
    /// generation prompt ends in tokens (e.g. Gemma 4's `<|turn>model\n`)
    /// that the real send does NOT contain at that position, so nothing it
    /// stored could ever be restored. Full-attention models recover via the
    /// engine's trimmed history-boundary entry, but sliding-window models
    /// (RotatingKVCache) are not trimmable once the prompt exceeds the
    /// window and the boundary rederive is skipped for disk-backed cache
    /// topologies — for them the warm-up prompt itself must end at the
    /// boundary.
    ///
    /// The boundary comes from the processor's own `cachePrefixTokenCounts`
    /// when populated (LLM factory prompts). VLM processors (e.g. Gemma 4)
    /// don't compute it, so the fallback derives the generation-prompt token
    /// suffix from the model's own template — a tiny probe render with and
    /// without the generation prompt — and strips it from the prompt tail.
    /// Both paths are verified against the actual tokens; no per-family
    /// template strings are hardcoded. Truncating is always cache-safe: the
    /// engine keys stored KV by the exact token sequence it prefilled, so a
    /// shorter prompt simply stores a shorter (still content-verified)
    /// prefix. Prompts with media content or without a derivable boundary
    /// pass through unchanged.
    static func truncatingToCanonicalCacheBoundary(
        _ input: LMInput,
        tokenizer: (any MLXLMCommon.Tokenizer)? = nil,
        additionalContext: [String: any Sendable]? = nil
    ) -> LMInput {
        guard !input.hasMediaContent else { return input }
        let tokens =
            input.text.tokenIds
            ?? MLXCacheIOLock.withSerializedMLXCacheIO {
                input.text.tokens.asArray(Int.self)
            }
        let boundary = warmupCacheBoundary(
            tokens: tokens,
            cachePrefixTokenCounts: input.cachePrefixTokenCounts,
            tokenizer: tokenizer,
            additionalContext: additionalContext
        )
        guard let boundary else {
            batchAdapterLog.info(
                "warmupPrefill: no cache boundary derivable; prefilling full prompt (\(tokens.count, privacy: .public) tokens)"
            )
            return input
        }
        let prefix = Array(tokens.prefix(boundary))
        batchAdapterLog.info(
            "warmupPrefill: truncated prompt to cache boundary \(boundary, privacy: .public)/\(tokens.count, privacy: .public) tokens"
        )
        // Prompt tokens are batch-shaped [1, N] by processor contract; model
        // prepare paths subscript with a leading batch index and trap on a
        // flat [N] array.
        return LMInput(
            tokens: MLXArray(prefix).expandedDimensions(axis: 0),
            tokenIds: prefix,
            cacheScopeSalt: input.cacheScopeSalt,
            cachePrefixTokenCounts: [],
            toolSchemas: input.toolSchemas
        )
    }

    /// Compute where a warm-up prompt should stop so the stored KV prefix is
    /// extendable by the real send. Prefers the processor's canonical
    /// boundary; falls back to stripping a tokenizer-derived
    /// generation-prompt suffix. Returns nil when no boundary can be proven
    /// against the actual tokens.
    static func warmupCacheBoundary(
        tokens: [Int],
        cachePrefixTokenCounts: [Int],
        tokenizer: (any MLXLMCommon.Tokenizer)?,
        additionalContext: [String: any Sendable]?
    ) -> Int? {
        if let canonical = cachePrefixTokenCounts.max(),
            canonical > 0, canonical < tokens.count
        {
            return canonical
        }
        if let suffix = generationPromptTokenSuffix(
            tokenizer: tokenizer,
            additionalContext: additionalContext
        ),
            tokens.count > suffix.count,
            Array(tokens.suffix(suffix.count)) == suffix
        {
            return tokens.count - suffix.count
        }
        return nil
    }

    /// Derive the template's generation-prompt token suffix (e.g. Gemma 4's
    /// `<|turn>model\n`) by rendering a minimal probe conversation with and
    /// without the generation prompt and diffing the tails. Returns nil when
    /// the tokenizer doesn't support generation-prompt control or the two
    /// renders don't share the expected prefix relationship (in which case
    /// the caller skips truncation — never guesses).
    ///
    /// `additionalContext` is forwarded so flags that alter the generation
    /// prompt itself (e.g. thinking openers appended after the assistant
    /// header) produce the same suffix the real prompt was rendered with.
    private static func generationPromptTokenSuffix(
        tokenizer: (any MLXLMCommon.Tokenizer)?,
        additionalContext: [String: any Sendable]?
    ) -> [Int]? {
        guard
            let controllable = tokenizer as? any MLXLMCommon.GenerationPromptControllableTokenizer
        else { return nil }
        let probe: [[String: any Sendable]] = [["role": "user", "content": "x"]]
        guard
            let with = try? controllable.applyChatTemplate(
                messages: probe,
                tools: nil,
                additionalContext: additionalContext,
                addGenerationPrompt: true
            ),
            let without = try? controllable.applyChatTemplate(
                messages: probe,
                tools: nil,
                additionalContext: additionalContext,
                addGenerationPrompt: false
            ),
            with.count > without.count,
            Array(with.prefix(without.count)) == without
        else { return nil }
        return Array(with.dropFirst(without.count))
    }

    private static func prepareInput(
        modelName: String,
        container: ModelContainer,
        buildChat: @Sendable () -> [MLXLMCommon.Chat.Message],
        buildToolsSpec: @Sendable () -> [[String: any Sendable]]?,
        buildRawPrompt: (@Sendable () -> String)? = nil,
        generation: GenerationParameters,
        toolChoice: ToolChoiceOption?,
        trace: TTFTTrace?
    ) async throws -> PreparedInput {
        // Heap-allocated outbox so the throwing closure can hand a value back
        // across the actor boundary.
        final class OutBox: @unchecked Sendable {
            var result: PreparedInput?
            var performEnteredAt: CFAbsoluteTime?
            var chatBuiltAt: CFAbsoluteTime?
            var toolsBuiltAt: CFAbsoluteTime?
            var contextBuiltAt: CFAbsoluteTime?
            var processorDoneAt: CFAbsoluteTime?
            var tokenArrayDoneAt: CFAbsoluteTime?
            var chatCount = 0
            var toolCount = 0
            var imageCount = 0
            var videoCount = 0
            var audioCount = 0
            var contextKeys: [String] = []
            var contextSummary = ""
            var promptTokenCount = 0
            var isBlockDiffusionModel = false
        }
        let box = OutBox()
        let prepareStartedAt = CFAbsoluteTimeGetCurrent()

        try await container.perform { (context: MLXLMCommon.ModelContext) in
            box.performEnteredAt = CFAbsoluteTimeGetCurrent()
            trace?.mark("batch_container_perform_entered")
            // Engine-attribution signal: the exact `BatchEngine.generate`
            // block-diffusion dispatch predicate, evaluated here because
            // this closure already holds the loaded model instance — no
            // extra container hop on the hot path.
            box.isBlockDiffusionModel = Self.isBlockDiffusionModelInstance(context.model)
            var lmInput: LMInput
            if let buildRawPrompt {
                // Raw completion path (OpenAI-legacy `/v1/completions`, e.g.
                // FIM autocomplete): tokenize the prompt verbatim and bypass
                // the chat template, so tokens like `<|fim_prefix|>` reach the
                // model exactly as the client sent them. The chat / media /
                // tools building is skipped entirely.
                let raw = buildRawPrompt()
                let now = CFAbsoluteTimeGetCurrent()
                box.chatBuiltAt = now
                box.toolsBuiltAt = now
                box.contextBuiltAt = now
                trace?.mark("batch_tokenization_start")
                let promptTokens = context.tokenizer.encode(text: raw)
                lmInput = LMInput(tokens: MLXArray(promptTokens))
                box.processorDoneAt = CFAbsoluteTimeGetCurrent()
                trace?.mark("batch_tokenization_done")
            } else {
                var chat = preprocessImages(in: buildChat())
                chat = try preencodeNemotronOmniAudioIfPossible(
                    in: chat,
                    modelName: modelName,
                    model: context.model,
                    trace: trace
                )
                box.chatBuiltAt = CFAbsoluteTimeGetCurrent()
                box.chatCount = chat.count
                box.imageCount = chat.reduce(0) { $0 + $1.images.count }
                box.videoCount = chat.reduce(0) { $0 + $1.videos.count }
                box.audioCount = chat.reduce(0) { $0 + $1.audios.count }
                let toolsSpec = buildToolsSpec()
                box.toolsBuiltAt = CFAbsoluteTimeGetCurrent()
                box.toolCount = toolsSpec?.count ?? 0
                let requiredToolName = requiredToolChoiceName(
                    toolChoice: toolChoice,
                    toolsSpec: toolsSpec
                )

                // Reasoning template context. Only explicit request controls are
                // translated into model-specific template kwargs; omitted controls
                // leave the model template/default contract untouched.
                let additionalContext = additionalContext(
                    for: generation,
                    modelName: modelName,
                    toolChoice: toolChoice,
                    toolChoiceName: requiredToolName
                )
                box.contextBuiltAt = CFAbsoluteTimeGetCurrent()
                box.contextKeys = additionalContext.keys.sorted()
                box.contextSummary = Self.safeContextSummary(additionalContext)
                let userInput = MLXLMCommon.UserInput(
                    chat: chat,
                    processing: .init(),
                    tools: toolsSpec,
                    additionalContext: additionalContext
                )

                trace?.mark("batch_tokenization_start")
                do {
                    // Warm-up prompts must be rendered exactly like the next
                    // real send, then cut to the send-invariant prefix. The
                    // probe path appends a synthetic user turn before
                    // rendering, because several native templates (e.g.
                    // Ornith / qwen3_5's `raise_exception('No user query
                    // found in messages.')`) refuse a history-only message
                    // list — the tokenizer bridge then silently renders with
                    // a built-in fallback template whose bytes share nothing
                    // with the real send, so the stored KV can never be
                    // restored. See `prepareWarmupInputAtSendInvariantPrefix`.
                    if generation.warmupPrefill,
                        let probeTruncated = await Self.prepareWarmupInputAtSendInvariantPrefix(
                            chat: chat,
                            toolsSpec: toolsSpec,
                            additionalContext: additionalContext,
                            processor: context.processor
                        )
                    {
                        lmInput = probeTruncated
                    } else {
                        let prepared = try await context.processor.prepare(input: userInput)
                        lmInput = prepared.withToolSchemas(toolsSpec)
                        if generation.warmupPrefill {
                            lmInput = Self.truncatingToCanonicalCacheBoundary(
                                lmInput,
                                tokenizer: context.tokenizer,
                                additionalContext: additionalContext
                            )
                        }
                    }
                } catch {
                    let detail =
                        (error as? LocalizedError)?.errorDescription
                        ?? String(describing: error)
                    throw NSError(
                        domain: "MLXBatchAdapter",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Chat template error: \(detail)"]
                    )
                }
                box.processorDoneAt = CFAbsoluteTimeGetCurrent()
                trace?.mark("batch_tokenization_done")
            }

            let tokens =
                lmInput.text.tokenIds
                ?? MLXCacheIOLock.withSerializedMLXCacheIO {
                    lmInput.text.tokens.asArray(Int.self)
                }
            box.tokenArrayDoneAt = CFAbsoluteTimeGetCurrent()
            box.promptTokenCount = tokens.count
            guard !tokens.isEmpty else {
                throw NSError(
                    domain: "MLXBatchAdapter",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Tokenizer produced no tokens for the given input"]
                )
            }

            box.result = PreparedInput(
                input: lmInput,
                promptTokens: tokens,
                isBlockDiffusionModel: box.isBlockDiffusionModel
            )
        }

        let doneAt = CFAbsoluteTimeGetCurrent()
        func ms(_ start: CFAbsoluteTime?, _ end: CFAbsoluteTime?) -> Int {
            guard let start, let end else { return -1 }
            return Int((end - start) * 1000)
        }
        let contextKeyString = box.contextKeys.joined(separator: ",")
        let totalPrepareMs = Int((doneAt - prepareStartedAt) * 1000)
        trace?.set("prompt_prepare_ms", totalPrepareMs)
        trace?.set("processor_prepare_ms", ms(box.contextBuiltAt, box.processorDoneAt))
        trace?.set("token_array_ms", ms(box.processorDoneAt, box.tokenArrayDoneAt))
        trace?.set("chat_message_count", box.chatCount)
        trace?.set("chat_image_count", box.imageCount)
        trace?.set("chat_video_count", box.videoCount)
        trace?.set("chat_audio_count", box.audioCount)
        batchAdapterLog.info(
            "prepareInput: model=\(modelName, privacy: .public) totalMs=\(totalPrepareMs, privacy: .public) waitForContainerMs=\(ms(prepareStartedAt, box.performEnteredAt), privacy: .public) chatBuildMs=\(ms(box.performEnteredAt, box.chatBuiltAt), privacy: .public) toolsBuildMs=\(ms(box.chatBuiltAt, box.toolsBuiltAt), privacy: .public) contextMs=\(ms(box.toolsBuiltAt, box.contextBuiltAt), privacy: .public) processorPrepareMs=\(ms(box.contextBuiltAt, box.processorDoneAt), privacy: .public) tokenArrayMs=\(ms(box.processorDoneAt, box.tokenArrayDoneAt), privacy: .public) chat=\(box.chatCount, privacy: .public) tools=\(box.toolCount, privacy: .public) images=\(box.imageCount, privacy: .public) videos=\(box.videoCount, privacy: .public) audios=\(box.audioCount, privacy: .public) promptTokens=\(box.promptTokenCount, privacy: .public) contextKeys=\(contextKeyString, privacy: .public) context=\(box.contextSummary, privacy: .public)"
        )

        guard let prepared = box.result else {
            throw NSError(
                domain: "MLXBatchAdapter",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Prepared input missing after container.perform"]
            )
        }
        return prepared
    }

    private static func safeContextSummary(_ context: [String: any Sendable]) -> String {
        context.keys.sorted().compactMap { key in
            guard
                key == "enable_thinking" || key == "reasoning_effort" || key == "tool_choice"
                    || key == "tool_choice_name"
            else {
                return nil
            }
            let value = context[key]
            if let bool = value as? Bool {
                return "\(key)=\(bool)"
            }
            if let string = value as? String {
                return "\(key)=\(string)"
            }
            return "\(key)=<\(type(of: value))>"
        }.joined(separator: ",")
    }
}
