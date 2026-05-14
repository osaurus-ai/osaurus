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
        runtimeTopP: Float,
        maxBatchSize: Int,
        modelDefaults: LocalGenerationDefaults.Defaults
    ) -> EffectiveGenerationSettings {
        let defaultTemperature: Float? = {
            if modelDefaults.doSample == false {
                return 0
            }
            return modelDefaults.temperature
        }()

        return EffectiveGenerationSettings(
            temperature: generation.temperature ?? defaultTemperature ?? 0.7,
            maxTokens: generation.maxTokensExplicit
                ? generation.maxTokens
                : (modelDefaults.maxTokens ?? generation.maxTokens),
            topP: generation.topPOverride ?? modelDefaults.topP ?? runtimeTopP,
            topK: modelDefaults.topK ?? 0,
            minP: generation.minPOverride ?? modelDefaults.minP ?? 0,
            repetitionPenalty: generation.repetitionPenalty ?? modelDefaults.repetitionPenalty,
            compiledBatchDecode: shouldEnableCompiledBatchDecode(
                modelName: modelName,
                maxBatchSize: maxBatchSize
            )
        )
    }

    /// Same-model gate for the single-slot runtime path. With
    /// `maxBatchSize == 1`, vmlx can route through its TokenIterator-backed
    /// solo fast path. There is no batching upside to overlapping a second
    /// prompt-prep/eval against that active decode, and MLX/Metal command
    /// encoders are not safe to drive concurrently from the same container.
    actor SoloGenerationGate {
        private var busyModels: Set<String> = []
        private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

        struct Lease: @unchecked Sendable {
            fileprivate let modelName: String
            fileprivate let gate: SoloGenerationGate

            func release() async {
                await gate.release(modelName)
            }
        }

        func acquire(modelName: String) async -> Lease {
            if !busyModels.contains(modelName) {
                busyModels.insert(modelName)
                return Lease(modelName: modelName, gate: self)
            }

            await withCheckedContinuation { continuation in
                waiters[modelName, default: []].append(continuation)
            }
            return Lease(modelName: modelName, gate: self)
        }

        private func release(_ modelName: String) {
            guard busyModels.contains(modelName) else { return }
            if var queue = waiters[modelName], !queue.isEmpty {
                let next = queue.removeFirst()
                waiters[modelName] = queue.isEmpty ? nil : queue
                next.resume()
            } else {
                busyModels.remove(modelName)
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
        modelName: String
    ) -> [String: any Sendable] {
        var context: [String: any Sendable] = [:]
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
            let effort: String
            if let normalizedReasoningEffort {
                effort = DSV4ReasoningProfile.normalizedEffort(normalizedReasoningEffort)
            } else if let disableThinking {
                effort = disableThinking ? "instruct" : "high"
            } else {
                effort = "instruct"
            }

            switch effort {
            case "max":
                context["enable_thinking"] = true
                context["reasoning_effort"] = Self.dsv4RawMaxEnabled ? "max" : "high"
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
            context["enable_thinking"] = false
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
        if ModelFamilyNames.isNemotronOmniFamily(modelName) {
            context["enable_thinking"] = hasPositiveReasoningEffort
            if hasPositiveReasoningEffort, let normalizedReasoningEffort {
                context["reasoning_effort"] = normalizedReasoningEffort
            }
            return context
        }
        if ModelFamilyNames.isZayaFamily(modelName) {
            context["enable_thinking"] = hasPositiveReasoningEffort
            if hasPositiveReasoningEffort, let normalizedReasoningEffort {
                context["reasoning_effort"] = normalizedReasoningEffort
            }
            return context
        }

        if let normalizedReasoningEffort, !directRailReasoningEffort {
            context["reasoning_effort"] = normalizedReasoningEffort
        }
        if directRailReasoningEffort {
            context["enable_thinking"] = false
            return context
        }
        context["enable_thinking"] = true
        return context
    }

    /// DSV4's raw `max` effort prepends an extreme "absolute maximum" thinking
    /// preface. Keep the UI's Max segment on the stable high-thinking rail by
    /// default; enable raw max only for explicit diagnostic runs.
    private static var dsv4RawMaxEnabled: Bool {
        switch ProcessInfo.processInfo.environment["OSAURUS_DSV4_RAW_MAX"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
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
    }

    // MARK: - Submission

    /// Tokenize the chat + tools, fetch (or create) the per-model
    /// `BatchEngine`, and submit one request via `engine.generate`. Returns
    /// the resulting `Generation` stream wrapped with cancellation plumbing.
    static func generate(
        modelName: String,
        container: ModelContainer,
        buildChat: @Sendable () -> [MLXLMCommon.Chat.Message],
        buildToolsSpec: @Sendable () -> [[String: any Sendable]]?,
        generation: GenerationParameters,
        stopSequences: [String],
        runtime: RuntimeConfig,
        maxBatchSize: Int
    ) async throws -> PreparedStream {
        let trace = generation.ttftTrace
        trace?.mark("batch_prepare_start")
        let soloLease =
            maxBatchSize == 1
            ? await Registry.shared.acquireSoloLease(for: modelName)
            : nil
        if Task.isCancelled {
            if let soloLease { await soloLease.release() }
            throw CancellationError()
        }

        let prepared: PreparedInput
        do {
            prepared = try await prepareInput(
                modelName: modelName,
                container: container,
                buildChat: buildChat,
                buildToolsSpec: buildToolsSpec,
                generation: generation,
                trace: trace
            )
        } catch {
            if let soloLease { await soloLease.release() }
            throw error
        }

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
        let effective = Self.effectiveGenerationSettings(
            modelName: modelName,
            generation: generation,
            runtimeTopP: runtime.topP,
            maxBatchSize: maxBatchSize,
            modelDefaults: modelDefaults
        )
        let mlxParams = ModelRuntime.makeGenerateParameters(
            temperature: effective.temperature,
            maxTokens: effective.maxTokens,
            topP: effective.topP,
            topK: effective.topK,
            minP: effective.minP,
            repetitionPenalty: effective.repetitionPenalty,
            stopSequences: stopSequences,
            enableCompiledBatchDecode: effective.compiledBatchDecode
        )

        // Best-effort per-request determinism: seed the MLX global random
        // state immediately before submission. Note: vmlx's `Sampler`
        // constructs its own `RandomState()` from time-of-day inside the
        // engine, so concurrent seeded requests against the same model
        // are NOT guaranteed reproducible. Single-request seeding still
        // benefits any MLX code path that consults `MLXRandom.globalState`.
        if let seed = generation.seed {
            MLXRandom.seed(seed)
        }

        // `engine.generate` returns `AsyncStream<Generation>` directly with
        // reasoning + tool-call extraction handled inside vmlx. We re-wrap
        // it so we can attach a producer `Task` for cancellation.
        //
        // Important: vmlx emits terminal `.info` before it performs the
        // post-generation disk-cache store and then finishes its stream. The
        // solo lease must be held until the upstream stream is actually done;
        // releasing it at `.info` lets the next same-model request enter
        // `prepareInput` while the previous request is still materializing
        // cache tensors on Metal.
        trace?.mark("batch_submit")
        let upstream = await engine.generate(
            input: prepared.input,
            parameters: mlxParams
        )

        let (outStream, continuation) = AsyncStream<Generation>.makeStream()
        let producerTask = Task<Void, Never> {
            defer {
                continuation.finish()
                if let soloLease {
                    Task { await soloLease.release() }
                }
            }
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
        }

        continuation.onTermination = { @Sendable _ in
            producerTask.cancel()
        }

        batchAdapterLog.info(
            "submit: model=\(modelName, privacy: .public) promptTokens=\(prepared.promptTokens.count, privacy: .public) temperature=\(effective.temperature, privacy: .public) topP=\(effective.topP, privacy: .public) topK=\(effective.topK, privacy: .public) minP=\(effective.minP, privacy: .public) maxTokens=\(effective.maxTokens, privacy: .public) compiledBatchDecode=\(effective.compiledBatchDecode, privacy: .public)"
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
        generation: GenerationParameters,
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

            // Reasoning template context. Hy3 uses `reasoning_effort`
            // instead of the generic boolean; Ling is force-off; ZAYA is
            // reasoning-capable but defaults off unless explicitly opted in.
            // Other thinking-capable families default to a truthy
            // `enable_thinking` kwarg.
            let additionalContext = additionalContext(for: generation, modelName: modelName)
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
            let lmInput: LMInput
            do {
                lmInput = try await context.processor.prepare(input: userInput)
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

            let tokens = lmInput.text.tokens.asArray(Int.self)
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
            guard key == "enable_thinking" || key == "reasoning_effort" else {
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
