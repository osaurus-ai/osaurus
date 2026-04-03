//
//  ModelRuntime.swift
//  osaurus
//
//  Holds MLX runtime state (containers, gates, caches) behind an actor.
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

// Force-link MLXVLM so ModelFactoryRegistry discovers the VLM trampoline at runtime.
private let _vlmFactory = MLXVLM.VLMModelFactory.shared

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
    private var kvCacheStore = KVCacheStore()
    private var cachedConfig: RuntimeConfig?
    private var activeGenerationTask: Task<Void, Never>?
    // modelName:taskHash -> Task
    private var prefixCacheTasks: [String: Task<Void, Never>] = [:]

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

    /// Cancels any in-flight generation and waits for the GPU work to finish
    /// so that subsequent `Memory.clearCache()` calls don't free buffers that
    /// are still being read on the cooperative thread pool.
    private func cancelActiveGeneration() async {
        activeGenerationTask?.cancel()
        _ = await activeGenerationTask?.value
        activeGenerationTask = nil

        // also cancel and await all background prefix cache tasks
        for task in prefixCacheTasks.values {
            task.cancel()
            _ = await task.value
        }
        prefixCacheTasks.removeAll()
    }

    func unload(name: String) async {
        await cancelActiveGeneration()
        kvCacheStore.invalidateModel(name)

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

    /// Unloads any loaded model not referenced by an active window.
    func unloadModelsNotIn(_ activeNames: Set<String>) async {
        let toUnload = modelCache.keys.filter { !activeNames.contains($0) }
        for name in toUnload {
            print("[ModelRuntime] GC: Unloading unused model \(name)")
            await unload(name: name)
        }
    }

    func clearAll() async {
        await cancelActiveGeneration()
        kvCacheStore.clearAll()

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

    /// Invalidates the KV cache for a specific session (e.g., on window close).
    /// Does NOT call Memory.clearCache() -- the freed arrays will be reclaimed
    /// naturally once they exceed mlxCacheLimit. Flushing here would penalize
    /// any generation still running on other windows.
    func invalidateSession(_ sessionId: String) {
        kvCacheStore.invalidate(sessionId: sessionId)
    }

    // MARK: - Cache invalidation helpers

    private func invalidateCaches(sessionId: String?, modelName: String, prefixHash: String) {
        if let sid = sessionId {
            kvCacheStore.invalidate(sessionId: sid)
        }
        kvCacheStore.invalidatePrefixCache(modelName: modelName, hash: prefixHash)
    }

    /// Wraps a stream so that after it finishes successfully, a prefix KV cache
    /// is built for the given model+hash.  The build runs sequentially — never
    /// concurrently with the generation that produced this stream — because it
    /// only starts after the stream is fully consumed (i.e. the generation's
    /// `genTask` has completed and no Metal work is in flight).
    private func wrapWithPrefixCacheBuild(
        _ stream: AsyncThrowingStream<ModelRuntimeEvent, Error>,
        holder: SessionHolder,
        systemContent: String,
        tools: [Tool]?,
        toolChoice: ToolChoiceOption?,
        modelName: String,
        prefixHash: String,
        runtimeConfig: RuntimeConfig
    ) -> AsyncThrowingStream<ModelRuntimeEvent, Error> {
        let (wrapped, continuation) = AsyncThrowingStream<ModelRuntimeEvent, Error>.makeStream()
        let forwardTask = Task {
            do {
                for try await event in stream {
                    if Task.isCancelled { break }
                    continuation.yield(event)
                }
                continuation.finish()

                guard !Task.isCancelled else { return }
                guard !kvCacheStore.hasPrefixCache(modelName: modelName, hash: prefixHash) else { return }

                let taskKey = "\(modelName):\(prefixHash)"
                guard prefixCacheTasks[taskKey] == nil else { return }

                let prefixTask = Task {
                    await buildPrefixCache(
                        holder: holder,
                        systemContent: systemContent,
                        tools: tools,
                        toolChoice: toolChoice,
                        modelName: modelName,
                        hash: prefixHash,
                        runtimeConfig: runtimeConfig
                    )
                    await removePrefixTask(key: taskKey)
                }
                prefixCacheTasks[taskKey] = prefixTask
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { @Sendable _ in forwardTask.cancel() }
        return wrapped
    }

    /// Forwards events from `stream` and invalidates the relevant caches when
    /// iteration throws, so subsequent requests don't hit the same stale data.
    private func wrapWithCacheInvalidation(
        _ stream: AsyncThrowingStream<ModelRuntimeEvent, Error>,
        sessionId: String?,
        modelName: String,
        prefixHash: String
    ) -> AsyncThrowingStream<ModelRuntimeEvent, Error> {
        let (wrapped, continuation) = AsyncThrowingStream<ModelRuntimeEvent, Error>.makeStream()
        let forwardTask = Task {
            do {
                for try await event in stream {
                    if Task.isCancelled { break }
                    continuation.yield(event)
                }
                continuation.finish()
            } catch {
                invalidateCaches(sessionId: sessionId, modelName: modelName, prefixHash: prefixHash)
                print(
                    "[ModelRuntime] Stream failed with cache, invalidated for next attempt: \(error.localizedDescription)"
                )
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { @Sendable _ in forwardTask.cancel() }
        return wrapped
    }

    private func storeSessionCache(sessionId: String, cache: [any KVCache], promptTokens: [Int], modelName: String) {
        // Materialize all lazy MLXArrays before storing.
        //
        // During generation, TokenIterator uses asyncEval() to keep the GPU pipeline full.
        // Each in-place key/value write (`keys[..., prev..<offset, ...] = newKeys`) adds a
        // graph node.  After generateLoopTask completes and Stream().synchronize() returns,
        // the GPU is finished — but the MLXArray objects in the cache may still hold
        // unevaluated computation-graph references rather than concrete GPU buffers.  On the
        // next turn, MLX walks those graphs from scratch, triggering a full re-prefill even
        // though offset and token counts are correct.
        //
        // eval() forces the arrays to concrete buffers right now, so subsequent reads are
        // O(1) buffer accesses instead of O(n) graph replays.
        let arraysToEval = cache.flatMap { $0.state }
        if !arraysToEval.isEmpty {
            eval(arraysToEval)
        }

        kvCacheStore.putCache(sessionId: sessionId, cache: cache, tokens: promptTokens, modelName: modelName)
        let budget = currentKVBudget()
        kvCacheStore.ensureBudget(budget)
        let offset = effectiveCacheOffset(cache)
        genLog.info(
            "storeSessionCache: session=\(sessionId.prefix(8), privacy: .public) tokens=\(promptTokens.count, privacy: .public) offset=\(offset, privacy: .public)"
        )
    }

    // MARK: - Internals

    private func getConfig() async -> RuntimeConfig {
        if let cached = cachedConfig { return cached }
        let totalWeights = modelCache.values.reduce(Int64(0)) { $0 + $1.weightsSizeBytes }
        let cfg = await RuntimeConfig.snapshot(modelWeightsBytes: totalWeights)
        cachedConfig = cfg
        return cfg
    }

    private func currentKVBudget() -> Int {
        guard !modelCache.isEmpty else { return 0 }
        let modelBytes = modelCache.values.reduce(Int64(0)) { $0 + $1.weightsSizeBytes }
        return KVCacheStore.computeBudget(modelWeightsBytes: modelBytes)
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

        if let existingTask = loadingTasks[name] {
            return try await existingTask.value
        }

        guard let localURL = Self.findLocalDirectory(forModelId: id) else {
            throw NSError(
                domain: "ModelRuntime",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Model not downloaded: \(name)"]
            )
        }

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
            genLog.info("loadContainer: loaded \(name, privacy: .public) isVLM=\(holder.isVLM, privacy: .public)")
            return holder
        } catch {
            loadingTasks[name] = nil
            throw error
        }
    }

    private func removePrefixTask(key: String) async {
        prefixCacheTasks.removeValue(forKey: key)
    }

    /// Builds and persists a prefix KV cache for the given system content and
    /// tools via a minimal 1-token generation.  Called lazily on the first real
    /// query when no persisted prefix cache is found on disk.
    ///
    /// Always called from a background prefix-cache task (never inline in the
    /// generation path).  Awaits any active generation before starting its own
    /// GPU work so Metal command buffers never overlap.
    private func buildPrefixCache(
        holder: SessionHolder,
        systemContent: String,
        tools: [Tool]?,
        toolChoice: ToolChoiceOption?,
        modelName: String,
        hash: String,
        runtimeConfig: RuntimeConfig
    ) async {
        // Wait for any in-flight generation to finish before touching the GPU.
        // Closes the window where wrapWithPrefixCacheBuild's forwardTask creates
        // this task *after* the next generateEventStream's stale-task cleanup ran.
        _ = await activeGenerationTask?.value
        guard !Task.isCancelled else { return }

        let tokenizerTools = Self.makeTokenizerTools(tools: tools, toolChoice: toolChoice)
        let messages: [MLXLMCommon.Chat.Message] = [
            .init(role: .system, content: systemContent, images: [], videos: []),
            .init(role: .user, content: "Hi", images: [], videos: []),
        ]
        let params = GenerationParameters(temperature: 0.0, maxTokens: 1)

        do {
            let prefixResult = try await MLXGenerationEngine.prepareAndGenerate(
                container: holder.container,
                buildChat: { messages },
                buildToolsSpec: { tokenizerTools },
                generation: params,
                runtime: runtimeConfig,
                existingCache: nil,
                cachedTokens: nil
            )
            let (stream, cache, newTokens, genTask) = (
                prefixResult.stream, prefixResult.cache, prefixResult.promptTokens, prefixResult.genTask
            )

            for await _ in stream {
                if Task.isCancelled { break }
            }
            if !Task.isCancelled {
                await genTask.value
            } else {
                genTask.cancel()
            }

            guard !Task.isCancelled else { return }
            guard cache.contains(where: { $0.offset > 0 }) else {
                print("[ModelRuntime] Prefix cache incomplete, skipping persistence")
                return
            }

            let prefixArrays = cache.flatMap { $0.state }
            if !prefixArrays.isEmpty { eval(prefixArrays) }

            kvCacheStore.putPrefixCache(cache, tokens: newTokens, modelName: modelName, hash: hash)
            print("[ModelRuntime] Prefix cached for \(modelName) (hash: \(hash.prefix(8)))")
        } catch {
            print("[ModelRuntime] Failed to build prefix cache: \(error)")
        }
    }

    // MARK: - Driver helpers (actor-isolated)

    /// Builds and returns an event stream for a single generation request.
    /// If an existing session or prefix KV cache is available it is reused;
    /// when a stale cache causes a shape mismatch the cache is invalidated
    /// and the request is transparently retried with a fresh prefill.
    private func generateEventStream(
        chatBuilder: @Sendable () -> [MLXLMCommon.Chat.Message],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool]?,
        toolChoice: ToolChoiceOption?,
        modelId: String,
        modelName: String
    ) async throws -> AsyncThrowingStream<ModelRuntimeEvent, Error> {
        _ = await activeGenerationTask?.value
        if Task.isCancelled { throw CancellationError() }

        // Cancel and await any background prefix-cache tasks for this model so
        // we never have two concurrent Metal/MLX operations on the same container.
        let modelPrefix = "\(modelName):"
        let stalePrefixTasks = prefixCacheTasks.filter { $0.key.hasPrefix(modelPrefix) }
        for (key, task) in stalePrefixTasks {
            task.cancel()
            _ = await task.value
            prefixCacheTasks.removeValue(forKey: key)
        }
        if Task.isCancelled { throw CancellationError() }

        genLog.info("generateEventStream: start model=\(modelName, privacy: .public)")

        // Wait for any startup CoreML embedding work to finish before using the
        // GPU for MLX inference.  Prevents concurrent Metal command submissions
        // from CoreML and MLX that can SIGSEGV on Apple Silicon.
        await EmbeddingService.awaitStartupInit()
        if Task.isCancelled { throw CancellationError() }

        let effectiveStopSequences = stopSequences
        let cfg = await getConfig()
        let holder = try await loadContainer(id: modelId, name: modelName)

        let sessionId = parameters.sessionId
        let chatMessages = chatBuilder()
        let systemContent = chatMessages.first(where: { $0.role == .system })?.content ?? ""
        let toolNames = (tools ?? []).map { $0.function.name }
        let prefixHash =
            parameters.cacheHint
            ?? Self.computePrefixHash(systemContent: systemContent, toolNames: toolNames)

        // Look up existing KV cache for this session, or fall back to a
        // hash-keyed prefix cache for a warm start on new conversations.
        // nonisolated(unsafe) suppresses the Sendable check for [any KVCache] which
        // doesn't conform to Sendable but is safe here because access is serialized
        // through the ModelRuntime actor and ModelContainer.perform.
        nonisolated(unsafe) let existingCacheInfo: ([any KVCache]?, [Int]?) = {
            if let sid = sessionId {
                let (sessionCache, tokens) = kvCacheStore.getCache(sessionId: sid, modelName: modelName)
                if sessionCache != nil { return (sessionCache, tokens) }
            }
            return kvCacheStore.getPrefixCache(modelName: modelName, hash: prefixHash)
        }()

        nonisolated(unsafe) let existingCache = existingCacheInfo.0
        let cachedTokens = existingCacheInfo.1

        let capturedMessages = chatMessages
        let buildChat: @Sendable () -> [MLXLMCommon.Chat.Message] = { capturedMessages }
        let buildTools: @Sendable () -> [[String: any Sendable]]? = {
            ModelRuntime.makeTokenizerTools(tools: tools, toolChoice: toolChoice)
        }

        var rawStream: AsyncStream<MLXLMCommon.TokenGeneration>
        var tokenizer: any Tokenizer
        var cache: [any KVCache]
        var newTokens: [Int]
        var genTask: Task<Void, Never>
        var toolCallFormat: ToolCallFormat
        // Two-phase prefill sets this to the stable-boundary snapshot instead of the full-prompt snapshot.
        nonisolated(unsafe) var snapshotCacheOverride: ([any KVCache], [Int])? = nil

        genLog.info(
            "generateEventStream: prepareAndGenerate existingCache=\(existingCache != nil, privacy: .public) cachedTokens=\(cachedTokens?.count ?? 0, privacy: .public)"
        )

        // Signal that a prefill is starting (count unknown until prepareAndGenerate returns).
        // The UI shows a spinner; once the first generated token arrives prefillDidFinish() clears it.
        InferenceProgressManager.shared.prefillWillStartAsync(tokenCount: 0)

        do {
            let genResult = try await MLXGenerationEngine.prepareAndGenerate(
                container: holder.container,
                buildChat: buildChat,
                buildToolsSpec: buildTools,
                generation: parameters,
                runtime: cfg,
                existingCache: existingCache,
                cachedTokens: cachedTokens
            )
            (rawStream, tokenizer, cache, newTokens, genTask, toolCallFormat) = (
                genResult.stream, genResult.tokenizer, genResult.cache,
                genResult.promptTokens, genResult.genTask, genResult.toolCallFormat
            )
            // For two-phase prefill, override snapshot with the stable-boundary snapshot.
            if let snapCache = genResult.snapshotCache, let snapTokens = genResult.snapshotTokens {
                snapshotCacheOverride = (snapCache, snapTokens)
            }
        } catch {
            genLog.error(
                "generateEventStream: prepareAndGenerate failed (cache retry): \(error.localizedDescription, privacy: .public)"
            )
            guard existingCache != nil else {
                InferenceProgressManager.shared.prefillDidFinishAsync()
                throw error
            }
            genLog.warning("Cache incompatible, retrying: \(error.localizedDescription, privacy: .public)")
            invalidateCaches(sessionId: sessionId, modelName: modelName, prefixHash: prefixHash)
            // Re-signal for the retry prefill (still unknown count).
            InferenceProgressManager.shared.prefillWillStartAsync(tokenCount: 0)
            do {
                let retryResult = try await MLXGenerationEngine.prepareAndGenerate(
                    container: holder.container,
                    buildChat: buildChat,
                    buildToolsSpec: buildTools,
                    generation: parameters,
                    runtime: cfg,
                    existingCache: nil,
                    cachedTokens: nil
                )
                (rawStream, tokenizer, cache, newTokens, genTask, toolCallFormat) = (
                    retryResult.stream, retryResult.tokenizer, retryResult.cache,
                    retryResult.promptTokens, retryResult.genTask, retryResult.toolCallFormat
                )
                if let snapCache = retryResult.snapshotCache, let snapTokens = retryResult.snapshotTokens {
                    snapshotCacheOverride = (snapCache, snapTokens)
                }
            } catch {
                InferenceProgressManager.shared.prefillDidFinishAsync()
                throw error
            }
        }
        genLog.info("generateEventStream: stream created tokenCount=\(newTokens.count, privacy: .public)")
        // Prefill is now complete; update the display with the actual token count while
        // generation is warming up (the first token clears the indicator).
        InferenceProgressManager.shared.prefillWillStartAsync(tokenCount: newTokens.count)

        activeGenerationTask = genTask

        // Store a pre-generation snapshot of the cache immediately after prefill.
        //
        // Standard (single-phase) path: snapshot the full-prompt cache keyed by `newTokens`.
        // Two-phase path: use the stable-boundary snapshot from prepareAndGenerate (keyed by
        // stableTokens, before gen-prefix). This ensures the next turn's common-prefix check
        // hits exactly at cacheOffset, with toTrim == 0, even for MambaCache models.
        if let sid = sessionId {
            let (snapCacheToStore, snapTokensToStore): ([any KVCache], [Int])
            if let override = snapshotCacheOverride {
                // Two-phase: store the stable-boundary snapshot already deep-copied inside engine.
                snapCacheToStore = override.0
                snapTokensToStore = override.1
                genLog.info("twoPhase snapshot override: stableTokens=\(snapTokensToStore.count, privacy: .public)")
            } else {
                // Single-phase: snapshot full-prompt cache now.
                snapCacheToStore = KVCacheStore.deepCopyCache(cache)
                snapTokensToStore = newTokens
            }
            let arraysToEval = snapCacheToStore.flatMap { $0.state }
            if !arraysToEval.isEmpty { eval(arraysToEval) }
            kvCacheStore.putCache(
                sessionId: sid,
                cache: snapCacheToStore,
                tokens: snapTokensToStore,
                modelName: modelName
            )
            let budget = currentKVBudget()
            kvCacheStore.ensureBudget(budget)
            let snapshotOffset = effectiveCacheOffset(snapCacheToStore)
            genLog.info(
                "pre-gen snapshot stored session=\(sid.prefix(8), privacy: .public) tokens=\(snapTokensToStore.count, privacy: .public) offset=\(snapshotOffset, privacy: .public)"
            )
        }

        // Thread the tokenizer into StreamAccumulator so it can decode token IDs to text.
        let capturedToolsSpec = buildTools()
        let eventStream = StreamAccumulator.accumulate(
            events: rawStream,
            tokenizer: tokenizer,
            stopSequences: effectiveStopSequences,
            tools: tools,
            toolCallFormat: toolCallFormat,
            toolsSpec: capturedToolsSpec,
            generationTask: genTask,
            onGeneratedTokenIds: { _ in }
        ).asAsyncThrowingStream()

        // Compose wrappers: cache-invalidation on error.
        // The pre-generation snapshot is already stored above; no post-generation re-store
        // is needed (and would be harmful: it would overwrite the snapshot with a cache at
        // offset = promptTokens + generatedIds, which diverges from the next-turn prompt by
        // exactly the number of generated tokens, requiring trim that MambaCache cannot do).

        // For new conversations without a prefix cache, schedule building after
        // generation completes.  This runs sequentially (never concurrently with
        // the generation genTask) so Metal commands don't overlap.
        let needsPrefixCache =
            sessionId == nil
            && !holder.isVLM
            && !kvCacheStore.hasPrefixCache(modelName: modelName, hash: prefixHash)

        var composedStream = eventStream
        if needsPrefixCache {
            composedStream = wrapWithPrefixCacheBuild(
                composedStream,
                holder: holder,
                systemContent: systemContent,
                tools: tools,
                toolChoice: toolChoice,
                modelName: modelName,
                prefixHash: prefixHash,
                runtimeConfig: cfg
            )
        }

        guard existingCache != nil else { return composedStream }
        return wrapWithCacheInvalidation(
            composedStream,
            sessionId: sessionId,
            modelName: modelName,
            prefixHash: prefixHash
        )
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
        kvBits: Int?,
        kvGroup: Int,
        quantStart: Int,
        maxKV: Int?,
        prefillStep: Int
    ) -> MLXLMCommon.GenerateParameters {
        var p = MLXLMCommon.GenerateParameters(
            maxTokens: maxTokens,
            maxKVSize: maxKV,
            kvBits: kvBits,
            kvGroupSize: kvGroup,
            quantizedKVStart: quantStart,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: 20
        )
        p.prefillStepSize = prefillStep
        return p
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
        let parts = id.split(separator: "/").map(String.init)
        let base = DirectoryPickerService.effectiveModelsDirectory()
        let url = parts.reduce(base) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
        let fm = FileManager.default
        let hasConfig = fm.fileExists(atPath: url.appendingPathComponent("config.json").path)
        if let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
            hasConfig && items.contains(where: { $0.pathExtension == "safetensors" })
        {
            return url
        }
        return nil
    }
}
