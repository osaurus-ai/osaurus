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
    }

    struct AudioPreencodeResult {
        let chat: [MLXLMCommon.Chat.Message]
        let inputCount: Int
        let convertedCount: Int
        let alreadyPreencodedCount: Int
    }

    struct EffectiveGenerationSettings: Equatable, Sendable {
        let stage: String
        let temperature: Float
        let maxTokens: Int
        let topP: Float
        let topK: Int
        let minP: Float
        let repetitionPenalty: Float?
        let compiledBatchDecode: Bool
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
                )
        )
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
        let effective = Self.effectiveGenerationSettings(
            modelName: modelName,
            generation: generation,
            runtimeDefaults: runtime.generation,
            maxBatchSize: maxBatchSize,
            modelDefaults: modelDefaults,
            draftStrategy: effectiveDraftStrategy,
            nativeMTPExplicitSamplingFallback: nativeMTPExplicitSamplingFallback,
            stage: "submitted_to_batch_engine"
        )
        await Registry.shared.recordEffectiveGenerationSettings(
            modelName: modelName,
            settings: effective
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

        // Per-request determinism now rides `GenerateParameters.randomSeed`
        // (set above): vmlx builds each request's sampler around its own
        // seeded `RandomState`, which is the only state sampling consults.
        // The previous global `MLXRandom.seed()` call was a sampling no-op
        // AND leaked deterministic state into unrelated global-RNG
        // consumers (diffusion decode, image latents), so it is gone.

        await MainActor.run {
            InferenceProgressManager.shared.prefillWillStart(
                tokenCount: prepared.promptTokens.count
            )
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
            "submit: model=\(modelName, privacy: .public) promptTokens=\(prepared.promptTokens.count, privacy: .public) temperature=\(effective.temperature, privacy: .public) topP=\(effective.topP, privacy: .public) topK=\(effective.topK, privacy: .public) minP=\(effective.minP, privacy: .public) maxTokens=\(effective.maxTokens, privacy: .public) draftStrategy=\(effectiveDraftStrategy?.kindName ?? "none", privacy: .public) nativeMTPFallback=\(nativeMTPFallbackReason ?? "none", privacy: .public) compiledBatchDecode=\(effective.compiledBatchDecode, privacy: .public)"
        )

        return PreparedStream(
            stream: outStream,
            promptTokens: prepared.promptTokens,
            genTask: producerTask
        )
    }

    // MARK: - Tokenization

    private struct PreparedInput: @unchecked Sendable {
        let input: LMInput
        let promptTokens: [Int]
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
        }
        let box = OutBox()
        let prepareStartedAt = CFAbsoluteTimeGetCurrent()

        try await container.perform { (context: MLXLMCommon.ModelContext) in
            box.performEnteredAt = CFAbsoluteTimeGetCurrent()
            trace?.mark("batch_container_perform_entered")
            let lmInput: LMInput
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
                    let prepared = try await context.processor.prepare(input: userInput)
                    lmInput = prepared.withToolSchemas(toolsSpec)
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

            box.result = PreparedInput(input: lmInput, promptTokens: tokens)
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
