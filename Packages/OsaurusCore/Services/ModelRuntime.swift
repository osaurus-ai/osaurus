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
import Tokenizers
import os.log

private let genLog = Logger(subsystem: "com.dinoki.osaurus", category: "Generation")

// Force MLXVLM to be linked by referencing VLMModelFactory
// This ensures VLM models can be loaded via the ModelFactoryRegistry
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

    /// Wraps a stream so that after it finishes successfully, the KV cache is
    /// persisted for the session. The cache object is a reference type whose
    /// `offset` field grows as tokens are generated, so we must store it only
    /// after the stream is drained (offset == promptTokens + generatedTokens).
    ///
    /// The stored token sequence is `promptTokens + generatedTokenIds` — the complete
    /// token sequence the cache has processed — so subsequent turns can find the
    /// correct common prefix even when the chat template reformats historical messages.
    private func wrapWithCacheStore(
        _ stream: AsyncThrowingStream<ModelRuntimeEvent, Error>,
        sessionId: String,
        cache: [any KVCache],
        promptTokens: [Int],
        generatedTokenIdsBox: @escaping @Sendable () -> [Int],
        modelName: String
    ) -> AsyncThrowingStream<ModelRuntimeEvent, Error> {
        let (wrapped, continuation) = AsyncThrowingStream<ModelRuntimeEvent, Error>.makeStream()
        nonisolated(unsafe) let capturedCache = cache
        let forwardTask = Task {
            do {
                for try await event in stream {
                    if Task.isCancelled { break }
                    continuation.yield(event)
                }
                // Stream finished normally — cache is now fully populated.
                // Combine prompt tokens + generated token IDs for a complete token sequence.
                let generatedIds = generatedTokenIdsBox()
                let fullTokens = promptTokens + generatedIds
                debugLog(
                    "[ModelRuntime] wrapWithCacheStore: promptTokens=\(promptTokens.count) generatedIds=\(generatedIds.count) fullTokens=\(fullTokens.count)"
                )
                storeSessionCache(
                    sessionId: sessionId,
                    cache: capturedCache,
                    promptTokens: fullTokens,
                    modelName: modelName
                )
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { @Sendable _ in forwardTask.cancel() }
        return wrapped
    }

    private func storeSessionCache(sessionId: String, cache: [any KVCache], promptTokens: [Int], modelName: String) {
        kvCacheStore.putCache(sessionId: sessionId, cache: cache, tokens: promptTokens, modelName: modelName)
        let budget = currentKVBudget()
        kvCacheStore.ensureBudget(budget)
        let offset = effectiveCacheOffset(cache)
        debugLog(
            "[ModelRuntime] stored session cache sessionId=\(sessionId.prefix(8)) promptTokens=\(promptTokens.count) effectiveCacheOffset=\(offset) budget=\(budget / 1024 / 1024)MB"
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
        debugLog("[ModelRuntime] loadContainer: start name=\(name)")
        if let existing = modelCache[name] {
            debugLog("[ModelRuntime] loadContainer: cache hit")
            return existing
        }
        debugLog("[ModelRuntime] loadContainer: cache miss, fetching policy...")
        let policy = await ServerConfigurationStore.load()?.modelEvictionPolicy ?? .strictSingleModel
        debugLog("[ModelRuntime] loadContainer: policy=\(policy)")

        if policy == .strictSingleModel {
            let otherModels = modelCache.keys.filter { $0 != name }
            for other in otherModels {
                print("[ModelRuntime] Enforcing strict policy: Unloading \(other)")
                await unload(name: other)
            }

            let otherTasks = loadingTasks.keys.filter { $0 != name }
            for other in otherTasks {
                print("[ModelRuntime] Cancelling pending load for \(other)")
                loadingTasks[other]?.cancel()
                loadingTasks.removeValue(forKey: other)
            }
        } else {
            if !modelCache.isEmpty {
                print("[ModelRuntime] Loading \(name) alongside existing models (Flexible Policy)")
            }
        }

        if let existingTask = loadingTasks[name] {
            debugLog("[ModelRuntime] loadContainer: joining existing load task")
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
            debugLog("[ModelRuntime] loadContainer: load task started isVLM check...")
            let isVLM = ModelManager.isVisionModel(at: localURL)
            debugLog("[ModelRuntime] loadContainer: isVLM=\(isVLM), loading model weights...")
            let container: ModelContainer

            if isVLM {
                let configuration = ModelConfiguration(directory: localURL)
                debugLog("[ModelRuntime] loadContainer: calling VLMModelFactory.loadContainer")
                container = try await VLMModelFactory.shared.loadContainer(configuration: configuration)
            } else {
                debugLog("[ModelRuntime] loadContainer: calling loadModelContainer (LLM path)")
                container = try await loadModelContainer(directory: localURL)
            }
            debugLog("[ModelRuntime] loadContainer: weights loaded, building holder")
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
            debugLog("[ModelRuntime] loadContainer: task.value resolved, setting cache")
            modelCache[name] = holder
            loadingTasks[name] = nil
            currentModelName = name

            Memory.cacheLimit = mlxCacheLimit()

            debugLog("[ModelRuntime] loadContainer: returning holder")
            return holder
        } catch {
            loadingTasks[name] = nil
            throw error
        }
    }

    /// Builds and persists a prefix KV cache for the given system content and
    /// tools via a minimal 1-token generation.  Called lazily on the first real
    /// query when no persisted prefix cache is found on disk.
    private func buildPrefixCache(
        holder: SessionHolder,
        systemContent: String,
        tools: [Tool]?,
        toolChoice: ToolChoiceOption?,
        modelName: String,
        hash: String,
        runtimeConfig: RuntimeConfig
    ) async {
        let tokenizerTools = Self.makeTokenizerTools(tools: tools, toolChoice: toolChoice)
        let messages: [MLXLMCommon.Chat.Message] = [
            .init(role: .system, content: systemContent, images: [], videos: []),
            .init(role: .user, content: "Hi", images: [], videos: []),
        ]
        let params = GenerationParameters(temperature: 0.0, maxTokens: 1)

        do {
            let (stream, _, cache, newTokens, genTask) = try await MLXGenerationEngine.prepareAndGenerate(
                container: holder.container,
                buildChat: { messages },
                buildToolsSpec: { tokenizerTools },
                generation: params,
                runtime: runtimeConfig,
                existingCache: nil,
                cachedTokens: nil
            )
            activeGenerationTask = genTask

            for await _ in stream {}
            await genTask.value

            guard !Task.isCancelled else { return }
            guard cache.contains(where: { $0.offset > 0 }) else {
                print("[ModelRuntime] Prefix cache incomplete, skipping persistence")
                return
            }

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
        debugLog("[ModelRuntime] generateEventStream: start model=\(modelName)")
        genLog.info("generateEventStream: start model=\(modelName, privacy: .public)")
        print("[ModelRuntime] generateEventStream: start model=\(modelName)")

        // Qwen2.5/3/3.5 chat templates always wrap tool calls in <tool_call>…</tool_call>.
        // Add </tool_call> as a stop sequence so generation halts after the closing tag,
        // giving ToolDetection a clean, complete XML block to parse.
        var effectiveStopSequences = stopSequences
        let lowerName = modelName.lowercased()
        if !(tools ?? []).isEmpty && lowerName.contains("qwen") {
            if !effectiveStopSequences.contains("</tool_call>") {
                effectiveStopSequences.append("</tool_call>")
            }
        }

        let cfg = await getConfig()
        debugLog("[ModelRuntime] generateEventStream: got config, loading container...")
        let holder = try await loadContainer(id: modelId, name: modelName)
        debugLog("[ModelRuntime] generateEventStream: container ready isVLM=\(holder.isVLM)")

        let sessionId = parameters.sessionId
        let chatMessages = chatBuilder()
        let systemContent = chatMessages.first(where: { $0.role == .system })?.content ?? ""
        let toolNames = (tools ?? []).map { $0.function.name }
        let prefixHash =
            parameters.cacheHint
            ?? Self.computePrefixHash(systemContent: systemContent, toolNames: toolNames)

        // Lazy prefix cache: build and persist on the first query when no
        // disk-cached prefix exists yet.  Subsequent queries (and future app
        // launches) load the persisted cache from disk.
        if sessionId == nil,
            !holder.isVLM,
            !kvCacheStore.hasPrefixCache(modelName: modelName, hash: prefixHash)
        {
            await buildPrefixCache(
                holder: holder,
                systemContent: systemContent,
                tools: tools,
                toolChoice: toolChoice,
                modelName: modelName,
                hash: prefixHash,
                runtimeConfig: cfg
            )
        }

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

        debugLog(
            "[ModelRuntime] generateEventStream: calling prepareAndGenerate existingCache=\(existingCache != nil) cachedTokens=\(cachedTokens?.count ?? 0) sessionId=\(sessionId?.prefix(8) ?? "nil")"
        )
        genLog.info(
            "generateEventStream: calling prepareAndGenerate existingCache=\(existingCache != nil, privacy: .public) cachedTokens=\(cachedTokens?.count ?? 0, privacy: .public)"
        )
        print(
            "[ModelRuntime] generateEventStream: calling prepareAndGenerate existingCache=\(existingCache != nil) cachedTokens=\(cachedTokens?.count ?? 0)"
        )

        // Signal that a prefill is starting (count unknown until prepareAndGenerate returns).
        // The UI shows a spinner; once the first generated token arrives prefillDidFinish() clears it.
        InferenceProgressManager.shared.prefillWillStartAsync(tokenCount: 0)

        do {
            (rawStream, tokenizer, cache, newTokens, genTask) = try await MLXGenerationEngine.prepareAndGenerate(
                container: holder.container,
                buildChat: buildChat,
                buildToolsSpec: buildTools,
                generation: parameters,
                runtime: cfg,
                existingCache: existingCache,
                cachedTokens: cachedTokens
            )
        } catch {
            genLog.error(
                "generateEventStream: prepareAndGenerate failed (cache retry): \(error.localizedDescription, privacy: .public)"
            )
            guard existingCache != nil else {
                InferenceProgressManager.shared.prefillDidFinishAsync()
                throw error
            }
            print("[ModelRuntime] Cache incompatible, retrying without cache: \(error.localizedDescription)")
            invalidateCaches(sessionId: sessionId, modelName: modelName, prefixHash: prefixHash)
            // Re-signal for the retry prefill (still unknown count).
            InferenceProgressManager.shared.prefillWillStartAsync(tokenCount: 0)
            do {
                (rawStream, tokenizer, cache, newTokens, genTask) = try await MLXGenerationEngine.prepareAndGenerate(
                    container: holder.container,
                    buildChat: buildChat,
                    buildToolsSpec: buildTools,
                    generation: parameters,
                    runtime: cfg,
                    existingCache: nil,
                    cachedTokens: nil
                )
            } catch {
                InferenceProgressManager.shared.prefillDidFinishAsync()
                throw error
            }
        }
        genLog.info("generateEventStream: stream created tokenCount=\(newTokens.count, privacy: .public)")
        print("[ModelRuntime] generateEventStream: stream created tokenCount=\(newTokens.count)")
        // Prefill is now complete; update the display with the actual token count while
        // generation is warming up (the first token clears the indicator).
        InferenceProgressManager.shared.prefillWillStartAsync(tokenCount: newTokens.count)

        activeGenerationTask = genTask

        // Thread the tokenizer into StreamAccumulator so it can decode token IDs to text.
        // The onGeneratedTokenIds callback captures the generated IDs so wrapWithCacheStore
        // can store promptTokens + generatedTokenIds as the complete cached token sequence.
        let capturedPromptTokens = newTokens
        nonisolated(unsafe) var generatedTokenIds: [Int] = []
        let eventStream = StreamAccumulator.accumulate(
            events: rawStream,
            tokenizer: tokenizer,
            stopSequences: effectiveStopSequences,
            tools: tools,
            generationTask: genTask,
            onGeneratedTokenIds: { ids in generatedTokenIds = ids }
        ).asAsyncThrowingStream()

        // Compose wrappers: cache-store on success (innermost), then cache-invalidation on error.
        // Cache must be stored after the stream drains so `cache.offset` reflects all processed tokens.
        var wrappedStream = eventStream
        if let sid = sessionId {
            wrappedStream = wrapWithCacheStore(
                wrappedStream,
                sessionId: sid,
                cache: cache,
                promptTokens: capturedPromptTokens,
                generatedTokenIdsBox: { generatedTokenIds },
                modelName: modelName
            )
        }
        guard existingCache != nil else { return wrappedStream }
        return wrapWithCacheInvalidation(
            wrappedStream,
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
