//
//  ModelRuntime.swift
//  osaurus
//
//  Holds MLX runtime state (containers, gates) behind an actor.
//  Cache management is delegated to vmlx-swift-lm's CacheCoordinator
//  (enabled per-container at load time).
//

import CoreImage
import CryptoKit
import Foundation
import MLX
import MLXLLM
@preconcurrency import MLXLMCommon
import MLXVLM
import os.log

private let genLog = Logger(subsystem: "com.dinoki.osaurus", category: "Generation")

// Force-link both trampolines so ModelFactoryRegistry discovers them at runtime.
// `loadModelContainer` iterates factories in order — without touching each
// `.shared` the trampoline's static initializer may never run, and a model
// that isn't a VLM (e.g. MiniMax, Qwen, DeepSeek LLMs) would see the VLM
// factory fail its `unsupportedModelType` check and then find no LLM factory
// registered to take over, leaving the load hung or throwing silently.
private let _vlmFactory = MLXVLM.VLMModelFactory.shared
private let _llmFactory = MLXLLM.LLMModelFactory.shared

actor ModelRuntime {
    // MARK: - Types

    struct ModelCacheSummary: Sendable {
        let name: String
        let bytes: Int64
        let isCurrent: Bool
    }

    private final class SessionHolder: NSObject, @unchecked Sendable {
        let name: String
        let container: ModelContainer
        let weightsSizeBytes: Int64
        let isVLM: Bool
        init(
            name: String,
            container: ModelContainer,
            weightsSizeBytes: Int64,
            isVLM: Bool = false
        ) {
            self.name = name
            self.container = container
            self.weightsSizeBytes = weightsSizeBytes
            self.isVLM = isVLM
        }
    }

    // MARK: - Singleton

    static let shared = ModelRuntime()

    // MARK: - State

    private var modelCache: [String: SessionHolder] = [:]
    private var loadingTasks: [String: Task<SessionHolder, Error>] = [:]
    private var currentModelName: String?
    private var cachedConfig: RuntimeConfig?

    /// Most recently launched generation wrapper task. `ModelLease` is the
    /// authoritative "is anyone still using the model" signal; this property
    /// only exists so `cancelActiveGeneration()` can defensively kill an
    /// in-flight task during shutdown / `clearAll`. It tracks at most one
    /// task even when many are active — the lease drains the rest.
    private var activeGenerationTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    func cachedModelSummaries() -> [ModelCacheSummary] {
        return modelCache.values.map { holder in
            ModelCacheSummary(
                name: holder.name,
                bytes: holder.weightsSizeBytes,
                isCurrent: holder.name == currentModelName
            )
        }.sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return lhs.name < rhs.name
        }
    }

    // MARK: - Model lifecycle

    /// Defensive helper: cancels and awaits the most recently launched
    /// generation task. With `ModelLease` enforcing per-stream lifetime
    /// the unload paths already wait on `waitForZero(name)` first, so this
    /// only catches the rare race where a task was launched but never made
    /// it to `acquire`. Callers should still treat the lease as authoritative.
    private func cancelActiveGeneration() async {
        activeGenerationTask?.cancel()
        _ = await activeGenerationTask?.value
        activeGenerationTask = nil
    }

    /// Unload `name`, blocking until any in-flight generation against this
    /// model has fully released its lease. The lease is held for the entire
    /// stream lifetime (see `generateEventStream`), so this guarantees we
    /// never free buffers that an active Metal command buffer still references.
    func unload(name: String) async {
        // Shut the BatchEngine first so its scheduling loop stops issuing
        // new model forward passes; then wait for any in-flight per-request
        // leases to drain before we touch the container.
        await BatchEngineAdapter.Registry.shared.shutdownEngine(for: name)
        await ModelLease.shared.waitForZero(name)
        // Defensive: cancel any single-slot tracked task (legacy pre-lease path).
        // With leases, in-flight tasks already drained above; this only catches
        // the rare case where a task was cancelled mid-setup before acquiring.
        await cancelActiveGeneration()

        if let holder = modelCache[name] {
            holder.container.disableCaching()
        }

        autoreleasepool {
            _ = modelCache.removeValue(forKey: name)
        }
        loadingTasks[name]?.cancel()
        loadingTasks.removeValue(forKey: name)
        if currentModelName == name { currentModelName = nil }

        Memory.cacheLimit = mlxCacheLimit()
        Stream.gpu.synchronize()
        Memory.clearCache()
    }

    /// Unloads any loaded model whose name is not in `activeNames`.
    /// Models with active leases (in-flight generations) are also kept; the
    /// per-model `unload` call internally waits for the lease to drop before
    /// freeing buffers, so this method is safe to call with a stale `activeNames`
    /// snapshot — at worst the unload is briefly deferred, never a crash.
    func unloadModelsNotIn(_ activeNames: Set<String>) async {
        let leaseHeld = await ModelLease.shared.activeNames()
        let keep = activeNames.union(leaseHeld)
        let toUnload = modelCache.keys.filter { !keep.contains($0) }
        for name in toUnload {
            print("[ModelRuntime] GC: Unloading unused model \(name)")
            await unload(name: name)
        }
    }

    func clearAll() async {
        // Shut down every BatchEngine so they stop scheduling new forward
        // passes, then cancel the legacy single-slot tracked task and wait
        // for every leased model to drain before we touch any container.
        await BatchEngineAdapter.Registry.shared.shutdownAll()
        await cancelActiveGeneration()
        for name in modelCache.keys {
            await ModelLease.shared.waitForZero(name)
        }

        for holder in modelCache.values {
            holder.container.disableCaching()
        }

        autoreleasepool {
            modelCache.removeAll()
        }
        for task in loadingTasks.values { task.cancel() }
        loadingTasks.removeAll()
        currentModelName = nil
        cachedConfig = nil

        Memory.cacheLimit = 0
        Stream.gpu.synchronize()
        Memory.clearCache()
    }

    /// Invalidates the cached RuntimeConfig so the next request reads fresh values.
    func invalidateConfig() {
        cachedConfig = nil
    }

    /// Called when a chat window closes. With the package-level CacheCoordinator
    /// the paged cache is content-addressed and bounded internally, so
    /// per-session invalidation is not needed — stale blocks are LRU-evicted.
    func invalidateSession(_ sessionId: String) {
        // No-op: CacheCoordinator handles eviction via LRU on PagedCacheManager.
    }

    // MARK: - Internals

    private func getConfig() async -> RuntimeConfig {
        if let cached = cachedConfig { return cached }
        let cfg = await RuntimeConfig.snapshot()
        cachedConfig = cfg
        return cfg
    }

    /// MLX freed-buffer cache limit sized for intermediate activation reuse.
    /// Scales with model weight size (larger models have larger activations)
    /// and is capped by a fraction of system RAM. Returns 0 when idle.
    private func mlxCacheLimit() -> Int {
        guard !modelCache.isEmpty else { return 0 }
        let systemRAM = Int(ProcessInfo.processInfo.physicalMemory)
        let totalWeights = Int(modelCache.values.reduce(Int64(0)) { $0 + $1.weightsSizeBytes })
        let byModel = max(totalWeights / 4, 1 * 1024 * 1024 * 1024)
        let bySystem = min(systemRAM / 8, 8 * 1024 * 1024 * 1024)
        return min(byModel, bySystem)
    }

    private func loadContainer(id: String, name: String) async throws -> SessionHolder {
        if let existing = modelCache[name] { return existing }

        let policy = await ServerConfigurationStore.load()?.modelEvictionPolicy ?? .strictSingleModel

        if policy == .strictSingleModel {
            for other in modelCache.keys where other != name {
                genLog.info("loadContainer: strict eviction of \(other, privacy: .public)")
                await unload(name: other)
            }
            for other in loadingTasks.keys where other != name {
                loadingTasks[other]?.cancel()
                loadingTasks.removeValue(forKey: other)
            }
        }

        // Re-entry fast path: another caller is already loading this model.
        // If their task was cancelled by an evictor between our enqueue and
        // our await (a real race when two chat windows trigger concurrent
        // loads under `strictSingleModel`), fall through and create a new
        // task instead of propagating the stale CancellationError to our
        // caller — which would leave the UI stuck at "loading" with no
        // recovery path short of quitting the app.
        if let existingTask = loadingTasks[name] {
            do {
                return try await existingTask.value
            } catch is CancellationError {
                genLog.info(
                    "loadContainer: existing load for \(name, privacy: .public) was cancelled mid-flight; retrying with fresh task"
                )
                loadingTasks[name] = nil
                // fall through to create a new task below
            }
        }

        guard let localURL = Self.findLocalDirectory(forModelId: id) else {
            throw NSError(
                domain: "ModelRuntime",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Model not downloaded: \(name)"]
            )
        }

        let probe = MLXModel(id: id, name: name, description: "", downloadURL: "")
        await ModelDownloadService.ensureComplete(for: probe, directory: localURL)

        // Preflight: JANGTQ/TurboQuant variants need a `jangtq_runtime.safetensors`
        // sidecar (signs + codebook arrays for the Metal kernels). vmlx's
        // LLMModelFactory dispatches to the JANGTQ class strictly on
        // `jang_config.json.weight_format == "mxtq"`, but the runtime cache is
        // only populated when the sidecar file exists. If the config asks for
        // JANGTQ and the sidecar is missing, vmlx reaches the first forward
        // pass, hits a precondition in TurboQuantSwitchLinear, and abort()s
        // the whole process — taking osaurus with it. Caught here so the user
        // gets a clear error and the server stays up.
        try Self.validateJANGTQSidecarIfRequired(at: localURL, name: name)

        // Resolve the JANG capability stamp (if any) and log the detection
        // source exactly once per cold load. The result is cached inside the
        // resolver; `StreamingDeltaProcessor` picks it up per-session without
        // this `actor` having to forward it down four call layers.
        let resolution = JANGReasoningResolver.resolve(modelKey: name, directory: localURL)
        genLog.info(
            "loadContainer: parser detection_source_reasoning=\(resolution.reasoningSource.rawValue, privacy: .public) detection_source_tool=\(resolution.toolCallSource.rawValue, privacy: .public) hasReasoningParser=\(resolution.reasoningParser != nil, privacy: .public) toolFormat=\(resolution.toolCallFormat?.rawValue ?? "none", privacy: .public) model=\(name, privacy: .public)"
        )

        let task = Task<SessionHolder, Error> {
            let tokenizerLoader = SwiftTransformersTokenizerLoader()
            let container = try await loadModelContainer(
                from: localURL,
                using: tokenizerLoader
            )
            let isVLM = await container.isVLM
            let weightsBytes = Self.computeWeightsSizeBytes(at: localURL)
            return SessionHolder(
                name: name,
                container: container,
                weightsSizeBytes: weightsBytes,
                isVLM: isVLM
            )
        }

        loadingTasks[name] = task

        do {
            let holder = try await task.value
            modelCache[name] = holder
            loadingTasks[name] = nil
            currentModelName = name
            Memory.cacheLimit = mlxCacheLimit()

            // Enable multi-tier KV caching via vmlx-swift-lm's CacheCoordinator.
            // Cache tier config is entirely osaurus-internal — not user-visible.
            await installCacheCoordinator(on: holder)

            genLog.info(
                "loadContainer: loaded \(name, privacy: .public) isVLM=\(holder.isVLM, privacy: .public)"
            )
            return holder
        } catch {
            loadingTasks[name] = nil
            throw error
        }
    }

    // MARK: - Cache coordinator plumbing

    /// Builds a `CacheCoordinatorConfig` with osaurus-internal defaults.
    ///
    /// **KV caching is package-owned** — osaurus does not expose any cache
    /// knobs to users. This helper exists only to:
    /// - Point the disk cache at osaurus's paths (`OsaurusPaths.diskKVCache()`)
    /// - Provide a sensible `modelKey` for per-model isolation
    /// - Pick a max-blocks default based on RAM
    /// - Fall back to memory-only when the disk cache dir is not writable
    ///
    /// Defaults chosen to be invisible and sensible. If the package's defaults
    /// ever drift in a way that matters to osaurus, this is the single place
    /// to override.
    private nonisolated static func buildCacheCoordinatorConfig(
        modelName: String
    ) -> CacheCoordinatorConfig {
        let diskCacheDir = OsaurusPaths.diskKVCache()
        OsaurusPaths.ensureExistsSilent(diskCacheDir)
        let diskDirUsable = isDirectoryWritable(diskCacheDir)
        if !diskDirUsable {
            genLog.warning(
                "buildCacheCoordinatorConfig: disk cache dir not writable, forcing memory-only: \(diskCacheDir.path, privacy: .public)"
            )
        }

        let ramGB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        let maxBlocks: Int
        switch ramGB {
        case 0 ..< 16: maxBlocks = 500  // 32k tokens at 64 per block
        case 16 ..< 48: maxBlocks = 1000  // 64k tokens
        default: maxBlocks = 2000  // 128k tokens
        }

        var cacheConfig = CacheCoordinatorConfig()
        cacheConfig.enableDiskCache = diskDirUsable
        cacheConfig.diskCacheDir = diskCacheDir
        cacheConfig.diskCacheMaxGB = 4.0
        cacheConfig.modelKey = modelName
        cacheConfig.maxCacheBlocks = maxBlocks
        return cacheConfig
    }

    /// Best-effort writability probe for the disk cache directory. Uses a
    /// tempfile round-trip rather than `FileManager.isWritableFile(atPath:)`
    /// so symlinks / ACLs / out-of-disk conditions are caught.
    private nonisolated static func isDirectoryWritable(_ url: URL) -> Bool {
        let probe = url.appendingPathComponent(".osaurus_write_probe_\(UUID().uuidString)")
        do {
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    /// Installs the cache coordinator on a freshly-loaded holder.
    ///
    /// Ordering: `enableCaching` → `setHybrid`. Safe because this method is
    /// actor-isolated — no other `generateEventStream` call can run until we
    /// return.
    private func installCacheCoordinator(on holder: SessionHolder) async {
        let cacheConfig = Self.buildCacheCoordinatorConfig(modelName: holder.name)
        holder.container.enableCaching(config: cacheConfig)

        // Auto-detect hybrid models (SSM layers) and set the flag on the
        // freshly-created coordinator.
        let isHybrid = await holder.container.perform { ctx -> Bool in
            let testCache = ctx.model.newCache(parameters: nil)
            return testCache.contains { $0 is MambaCache || $0 is ArraysCache }
        }
        holder.container.cacheCoordinator?.setHybrid(isHybrid)

        genLog.info(
            "installCacheCoordinator: enabled for \(holder.name, privacy: .public) isHybrid=\(isHybrid, privacy: .public) disk=\(cacheConfig.enableDiskCache, privacy: .public) maxBlocks=\(cacheConfig.maxCacheBlocks, privacy: .public)"
        )
    }

    // MARK: - Generation driver

    /// Top-level dispatcher: loads the container, takes the model lease, and
    /// hands off to the appropriate per-path runner. The per-path runners
    /// own all subsequent locking and release the lease in their producer
    /// task — every throw path here MUST release the lease before returning.
    ///
    /// Cache management is handled by the package's `CacheCoordinator` — the
    /// `TokenIterator` (or `BatchEngine`) performs prefix fetch, KV restore,
    /// partial prefill, and post-generation cache store automatically.
    private func generateEventStream(
        chatBuilder: @Sendable () -> [MLXLMCommon.Chat.Message],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool]?,
        toolChoice: ToolChoiceOption?,
        modelId: String,
        modelName: String
    ) async throws -> AsyncThrowingStream<ModelRuntimeEvent, Error> {
        let trace = parameters.ttftTrace
        trace?.mark("runtime_start")

        trace?.mark("await_active_gen")
        _ = await activeGenerationTask?.value
        if Task.isCancelled { throw CancellationError() }

        genLog.info("generateEventStream: start model=\(modelName, privacy: .public)")

        // Scoped start/finish around ONLY the container load — we want the
        // "loading model" UI flag to flip off as soon as the container is
        // ready, not after gate/scheduler waits below. The do/catch pairs
        // ensure symmetric bookkeeping on every exit; the refcount in
        // `InferenceProgressManager` keeps concurrent loads (e.g. two chat
        // windows starting different models) from corrupting each other.
        let cfg = await getConfig()
        trace?.mark("load_container_start")
        InferenceProgressManager.shared.modelLoadWillStartAsync()
        let holder: SessionHolder
        do {
            holder = try await loadContainer(id: modelId, name: modelName)
        } catch {
            InferenceProgressManager.shared.modelLoadDidFinishAsync()
            throw error
        }
        InferenceProgressManager.shared.modelLoadDidFinishAsync()
        trace?.mark("load_container_done")

        // Pin the model against eviction for the lifetime of this stream.
        // The runner that we hand off to releases the lease in its producer
        // task; if the runner itself throws before launching that task it is
        // responsible for releasing too.
        await ModelLease.shared.acquire(modelName)

        let chatMessages = chatBuilder()
        let buildChat: @Sendable () -> [MLXLMCommon.Chat.Message] = { chatMessages }
        let buildTools: @Sendable () -> [[String: any Sendable]]? = {
            ModelRuntime.makeTokenizerTools(tools: tools, toolChoice: toolChoice)
        }
        let priority = parameters.priority ?? .plugin

        // Branch: `BatchEngine` runs its own actor scheduling loop, so when
        // it's enabled we deliberately bypass MetalGate / InferenceScheduler /
        // ModelWorker — those layers serialize MLX access globally, which
        // would defeat the point of continuous batching. `ModelLease` (above)
        // and per-plugin in-flight caps (PluginHostAPI) still apply.
        if InferenceFeatureFlags.mlxBatchEngineEnabled {
            return try await runBatchEngineStream(
                holder: holder,
                modelName: modelName,
                buildChat: buildChat,
                buildTools: buildTools,
                tools: tools,
                stopSequences: stopSequences,
                parameters: parameters,
                runtime: cfg,
                priority: priority,
                trace: trace
            )
        }

        return try await runDirectStream(
            holder: holder,
            modelName: modelName,
            buildChat: buildChat,
            buildTools: buildTools,
            tools: tools,
            stopSequences: stopSequences,
            parameters: parameters,
            runtime: cfg,
            priority: priority,
            trace: trace
        )
    }

    // MARK: - Direct (TokenIterator) path

    /// Resource locks held for the lifetime of one direct-path stream, in
    /// release order. Released exactly once via `releaseAll()`. The order
    /// matters: gate first frees the Metal layer for the next caller; the
    /// scheduler then admits the next priority winner; the worker admits the
    /// next same-model waiter; the lease is last so any queued unload can
    /// finally proceed.
    private struct DirectStreamLocks: Sendable {
        let modelName: String
        let worker: ModelWorker
        let useGlobalScheduler: Bool

        func releaseAll() async {
            await MetalGate.shared.exitGeneration()
            if useGlobalScheduler {
                await InferenceScheduler.shared.release()
            }
            await worker.release()
            await ModelLease.shared.release(modelName)
        }
    }

    /// Non-batched path: take per-model worker → optional priority slot →
    /// MetalGate → run a single-request `TokenIterator`. Holds wired memory
    /// for the duration so the model's weights aren't paged out mid-decode.
    private func runDirectStream(
        holder: SessionHolder,
        modelName: String,
        buildChat: @Sendable () -> [MLXLMCommon.Chat.Message],
        buildTools: @Sendable () -> [[String: any Sendable]]?,
        tools: [Tool]?,
        stopSequences: [String],
        parameters: GenerationParameters,
        runtime: RuntimeConfig,
        priority: InferencePriority,
        trace: TTFTTrace?
    ) async throws -> AsyncThrowingStream<ModelRuntimeEvent, Error> {
        let wiredTicket = MLXLMCommon.WiredSumPolicy().ticket(
            size: Int(holder.weightsSizeBytes),
            kind: .active
        )

        // Per-model worker first. With multi-model concurrency OFF (default)
        // this is largely redundant with the global scheduler — only one
        // stream runs at a time. With it ON, the worker is the only thing
        // preventing same-model races.
        let worker = await ModelWorkerRegistry.shared.worker(for: modelName)
        trace?.mark("worker_enter")
        await worker.acquire(priority: priority)
        trace?.mark("worker_acquired")

        // Priority slot in front of MetalGate. The scheduler decides queue
        // ORDER (priority-aware) across all models while MetalGate still
        // serializes MLX-vs-CoreML access at the Metal layer. With
        // `mlxAllowConcurrentStreams` ON, the global scheduler step is
        // skipped so streams of different models can interleave; the
        // per-model worker above is what prevents same-model races.
        let useGlobalScheduler = !InferenceFeatureFlags.mlxAllowConcurrentStreams
        if useGlobalScheduler {
            trace?.mark("scheduler_enter")
            await InferenceScheduler.shared.acquire(priority: priority)
            trace?.mark("scheduler_acquired")
        }

        // Exclusive Metal access. Acquired after all throwing setup so the
        // gate is never left locked by a loadContainer failure. With
        // `mlxAllowConcurrentStreams` ON, this only waits for embeddings.
        trace?.mark("metal_gate_enter")
        await MetalGate.shared.enterGeneration()
        trace?.mark("metal_gate_acquired")

        let locks = DirectStreamLocks(
            modelName: modelName,
            worker: worker,
            useGlobalScheduler: useGlobalScheduler
        )

        if Task.isCancelled {
            await locks.releaseAll()
            throw CancellationError()
        }

        // Prefill count is unknown until `prepareAndGenerate` returns; signal
        // start with 0, then update once we have the real count.
        InferenceProgressManager.shared.prefillWillStartAsync(tokenCount: 0)

        trace?.mark("prepare_and_generate_start")
        let genResult: MLXGenerationEngineResult
        do {
            genResult = try await MLXGenerationEngine.prepareAndGenerate(
                container: holder.container,
                buildChat: buildChat,
                buildToolsSpec: buildTools,
                generation: parameters,
                runtime: runtime,
                wiredMemoryTicket: wiredTicket
            )
            trace?.mark("prepare_and_generate_done")
            trace?.set("promptTokens", genResult.promptTokens.count)
        } catch {
            InferenceProgressManager.shared.prefillDidFinishAsync()
            await locks.releaseAll()
            throw error
        }

        genLog.info(
            "generateEventStream: stream created tokenCount=\(genResult.promptTokens.count, privacy: .public)"
        )
        InferenceProgressManager.shared.prefillWillStartAsync(tokenCount: genResult.promptTokens.count)

        // Wrap genTask so every lock is released when generation finishes
        // (success or cancellation), in the order documented on
        // `DirectStreamLocks.releaseAll`.
        let innerTask = genResult.genTask
        activeGenerationTask = Task<Void, Never> {
            await withTaskCancellationHandler {
                await innerTask.value
            } onCancel: {
                innerTask.cancel()
            }
            await locks.releaseAll()
        }

        return StreamAccumulator.accumulate(
            events: genResult.stream,
            tokenizer: genResult.tokenizer,
            stopSequences: stopSequences,
            tools: tools,
            toolCallFormat: genResult.toolCallFormat,
            toolsSpec: buildTools(),
            generationTask: innerTask,
            onGeneratedTokenIds: { _ in },
            priority: priority
        ).asAsyncThrowingStream()
    }

    // MARK: - BatchEngine path

    /// Submit one request through the per-model `BatchEngine` and adapt its
    /// stream into the same `ModelRuntimeEvent` shape callers already consume.
    ///
    /// Concurrency: this path holds **only** the model lease (already acquired
    /// by the caller). The engine's own actor loop serializes model access,
    /// so MetalGate / InferenceScheduler / ModelWorker would only add latency
    /// without any safety benefit. Per-plugin in-flight caps in
    /// `PluginHostAPI` continue to back-pressure misbehaving plugins.
    private func runBatchEngineStream(
        holder: SessionHolder,
        modelName: String,
        buildChat: @Sendable () -> [MLXLMCommon.Chat.Message],
        buildTools: @Sendable () -> [[String: any Sendable]]?,
        tools: [Tool]?,
        stopSequences: [String],
        parameters: GenerationParameters,
        runtime: RuntimeConfig,
        priority: InferencePriority,
        trace: TTFTTrace?
    ) async throws -> AsyncThrowingStream<ModelRuntimeEvent, Error> {
        InferenceProgressManager.shared.prefillWillStartAsync(tokenCount: 0)

        let prepared: BatchEngineAdapter.PreparedStream
        do {
            prepared = try await BatchEngineAdapter.prepareAndSubmit(
                modelName: modelName,
                container: holder.container,
                buildChat: buildChat,
                buildToolsSpec: buildTools,
                generation: parameters,
                runtime: runtime,
                maxBatchSize: InferenceFeatureFlags.mlxBatchEngineMaxBatchSize
            )
        } catch {
            InferenceProgressManager.shared.prefillDidFinishAsync()
            await ModelLease.shared.release(modelName)
            throw error
        }

        trace?.set("promptTokens", prepared.promptTokens.count)
        InferenceProgressManager.shared.prefillWillStartAsync(tokenCount: prepared.promptTokens.count)
        genLog.info(
            "generateEventStream(batch): stream created tokenCount=\(prepared.promptTokens.count, privacy: .public)"
        )

        // Wrap the producer task so the lease is released when the stream
        // finishes (success or cancellation). The adapter's producer task
        // already routes Swift cancellation into `BatchEngine.cancel(id)`.
        let innerProducer = prepared.genTask
        activeGenerationTask = Task<Void, Never> {
            await withTaskCancellationHandler {
                await innerProducer.value
            } onCancel: {
                innerProducer.cancel()
            }
            await ModelLease.shared.release(modelName)
        }

        return StreamAccumulator.accumulate(
            events: prepared.stream,
            tokenizer: prepared.tokenizer,
            stopSequences: stopSequences,
            tools: tools,
            toolCallFormat: prepared.toolCallFormat,
            toolsSpec: buildTools(),
            generationTask: prepared.genTask,
            onGeneratedTokenIds: { _ in },
            priority: priority
        ).asAsyncThrowingStream()
    }

    // MARK: - New message-based (OpenAI ChatMessage) APIs

    func respondWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        modelId: String,
        modelName: String
    ) async throws -> String {
        var accumulated = ""
        let events = try await generateEventStream(
            chatBuilder: { ModelRuntime.mapOpenAIChatToMLX(messages) },
            parameters: parameters,
            stopSequences: stopSequences,
            tools: tools,
            toolChoice: toolChoice,
            modelId: modelId,
            modelName: modelName
        )
        for try await ev in events {
            switch ev {
            case .tokens(let s):
                accumulated += s
            case .toolInvocation(let name, let argsJSON):
                throw ServiceToolInvocation(toolName: name, jsonArguments: argsJSON)
            case .completionInfo:
                break
            }
        }
        return accumulated
    }

    func streamWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        modelId: String,
        modelName: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        let events = try await generateEventStream(
            chatBuilder: { ModelRuntime.mapOpenAIChatToMLX(messages) },
            parameters: parameters,
            stopSequences: stopSequences,
            tools: tools,
            toolChoice: toolChoice,
            modelId: modelId,
            modelName: modelName
        )
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let producerTask = Task {
            do {
                for try await ev in events {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    switch ev {
                    case .tokens(let s):
                        if !s.isEmpty { continuation.yield(s) }
                    case .toolInvocation(let name, let argsJSON):
                        continuation.yield(StreamingToolHint.encode(name))
                        continuation.yield(StreamingToolHint.encodeArgs(argsJSON))
                        continuation.finish(
                            throwing: ServiceToolInvocation(toolName: name, jsonArguments: argsJSON)
                        )
                        return
                    case .completionInfo(let tokenCount, let tokensPerSecond):
                        continuation.yield(
                            StreamingStatsHint.encode(
                                tokenCount: tokenCount,
                                tokensPerSecond: tokensPerSecond
                            )
                        )
                    }
                }
                continuation.finish()
            } catch {
                if Task.isCancelled {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: error)
                }
            }
        }

        continuation.onTermination = { @Sendable _ in
            producerTask.cancel()
        }

        return stream
    }

    // MARK: - Static helpers (nonisolated)

    /// Computes a deterministic hash from system content and tool names.
    /// Used by the HTTP API to expose a prefix_hash field in responses.
    nonisolated static func computePrefixHash(
        systemContent: String,
        toolNames: [String]
    ) -> String {
        let tools = toolNames.sorted().joined(separator: "\0")
        let combined = systemContent + "\0" + tools
        let digest = SHA256.hash(data: Data(combined.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func makeGenerateParameters(
        temperature: Float,
        maxTokens: Int,
        topP: Float,
        repetitionPenalty: Float?,
        maxKV: Int?
    ) -> MLXLMCommon.GenerateParameters {
        MLXLMCommon.GenerateParameters(
            maxTokens: maxTokens,
            maxKVSize: maxKV,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: 20
        )
    }

    nonisolated static func makeTokenizerTools(
        tools: [Tool]?,
        toolChoice: ToolChoiceOption?
    ) -> [[String: any Sendable]]? {
        guard let tools, !tools.isEmpty else { return nil }
        if let toolChoice {
            switch toolChoice {
            case .none:
                return nil
            case .auto:
                return tools.map { $0.toTokenizerToolSpec() }
            case .function(let target):
                let name = target.function.name
                let filtered = tools.filter { $0.function.name == name }
                return filtered.isEmpty ? nil : filtered.map { $0.toTokenizerToolSpec() }
            }
        } else {
            return tools.map { $0.toTokenizerToolSpec() }
        }
    }

    nonisolated static func mapOpenAIChatToMLX(
        _ msgs: [ChatMessage]
    ) -> [MLXLMCommon.Chat.Message] {
        var toolIdToName: [String: String] = [:]
        for m in msgs where m.role == "assistant" {
            if let calls = m.tool_calls {
                for call in calls { toolIdToName[call.id] = call.function.name }
            }
        }

        var out: [MLXLMCommon.Chat.Message] = []
        out.reserveCapacity(max(6, msgs.count))
        for m in msgs {
            let images = extractImageSources(from: m)

            switch m.role {
            case "system":
                out.append(
                    MLXLMCommon.Chat.Message(role: .system, content: m.content ?? "", images: images, videos: [])
                )
            case "user":
                out.append(
                    MLXLMCommon.Chat.Message(role: .user, content: m.content ?? "", images: images, videos: [])
                )
            case "assistant":
                if let calls = m.tool_calls, !calls.isEmpty, m.content == nil || m.content?.isEmpty == true {
                    break
                } else {
                    out.append(
                        MLXLMCommon.Chat.Message(
                            role: .assistant,
                            content: m.content ?? "",
                            images: images,
                            videos: []
                        )
                    )
                }
            case "tool":
                out.append(
                    MLXLMCommon.Chat.Message(role: .tool, content: m.content ?? "", images: images, videos: [])
                )
            default:
                out.append(
                    MLXLMCommon.Chat.Message(role: .user, content: m.content ?? "", images: images, videos: [])
                )
            }
        }
        return out
    }

    nonisolated private static func extractImageSources(
        from message: ChatMessage
    ) -> [MLXLMCommon.UserInput.Image] {
        let imageUrls = message.imageUrls
        guard !imageUrls.isEmpty else { return [] }

        var sources: [MLXLMCommon.UserInput.Image] = []
        for urlString in imageUrls {
            if urlString.hasPrefix("data:image/") {
                if let commaIndex = urlString.firstIndex(of: ",") {
                    let base64String = String(urlString[urlString.index(after: commaIndex)...])
                    if let imageData = Data(base64Encoded: base64String),
                        let ciImage = CIImage(data: imageData)
                    {
                        sources.append(.ciImage(ciImage))
                    }
                }
            } else if let url = URL(string: urlString) {
                sources.append(.url(url))
            }
        }
        return sources
    }

    private static func computeWeightsSizeBytes(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
            )
        else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "safetensors" {
                if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                    let size = attrs[.size] as? NSNumber
                {
                    total += size.int64Value
                }
            }
        }
        return total
    }

    private static func findLocalDirectory(forModelId id: String) -> URL? {
        return resolveLocalModelDirectory(forModelId: id, in: DirectoryPickerService.effectiveModelsDirectory())
    }

    /// Preflight check for JANGTQ-routed models. Reads `jang_config.json`
    /// and, if `weight_format == "mxtq"`, verifies the `jangtq_runtime.safetensors`
    /// sidecar is present in the model directory. Throws a clear error on
    /// mismatch so callers see a message instead of waiting for vmlx to
    /// report the same problem later.
    ///
    /// As of `vmlx-swift-lm 9e647a6`, vmlx itself fails-fast with an equivalent
    /// NSError at weight-load time, so this osaurus-side check is primarily a
    /// speed optimization: we refuse before the 60+ safetensors shards start
    /// loading, giving users an instant error instead of a multi-second wait.
    /// It also defends against older vmlx pins where the same mismatch would
    /// instead reach `TurboQuantSwitchLinear.fatalError` and abort the process.
    /// Exposed at module scope for unit testing (same pattern as
    /// `resolveLocalModelDirectory`).
    static func validateJANGTQSidecarIfRequired(at directory: URL, name: String) throws {
        let jangConfigURL = directory.appendingPathComponent("jang_config.json")
        // Non-JANG models have no jang_config.json — nothing to validate.
        guard FileManager.default.fileExists(atPath: jangConfigURL.path) else { return }

        // Only read the `weight_format` field; ignore anything else so format
        // drift (new fields, missing optionals) doesn't break the preflight.
        struct JangConfigProbe: Decodable {
            let weight_format: String?
        }
        guard let data = try? Data(contentsOf: jangConfigURL),
            let probe = try? JSONDecoder().decode(JangConfigProbe.self, from: data),
            probe.weight_format == "mxtq"
        else {
            return
        }

        let sidecarURL = directory.appendingPathComponent("jangtq_runtime.safetensors")
        guard !FileManager.default.fileExists(atPath: sidecarURL.path) else { return }

        throw NSError(
            domain: "ModelRuntime",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Model '\(name)' declares JANGTQ (weight_format: \"mxtq\") but is missing "
                    + "required sidecar file 'jangtq_runtime.safetensors'. "
                    + "Re-download the full model or obtain the sidecar from the original publisher."
            ]
        )
    }

    /// Pure, testable sibling of `findLocalDirectory` that takes the root
    /// explicitly. Exposed at module scope so the symlink-resolution
    /// behavior (the reason `findLocalDirectory` doesn't silently disagree
    /// with `ModelManager.scanLocalModels` anymore) can be covered by a
    /// unit test without standing up an `actor` or a bookmarked picker dir.
    static func resolveLocalModelDirectory(forModelId id: String, in base: URL) -> URL? {
        let parts = id.split(separator: "/").map(String.init)
        let url = parts.reduce(base) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
        let fm = FileManager.default
        // Resolve symlinks before `contentsOfDirectory`: on macOS
        // `contentsOfDirectory(at:)` returns POSIX ENOTDIR when the URL points
        // at a symbolic link to a directory (even though the target itself is
        // a directory and `fileExists` happily follows the link). Users who
        // keep models outside the default root and symlink them into the
        // picker directory would otherwise hit "Model not downloaded" on
        // every load despite `scanLocalModels` discovering the same repo —
        // that discovery path already resolves symlinks per-level, so keeping
        // the two symmetric here closes the asymmetry.
        let resolved = url.resolvingSymlinksInPath()
        let hasConfig = fm.fileExists(atPath: resolved.appendingPathComponent("config.json").path)
        if let items = try? fm.contentsOfDirectory(at: resolved, includingPropertiesForKeys: nil),
            hasConfig && items.contains(where: { $0.pathExtension == "safetensors" })
        {
            return resolved
        }
        return nil
    }
}
