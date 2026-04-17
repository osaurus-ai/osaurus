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

    /// Builds and returns an event stream for a single generation request.
    /// Cache management is handled by the package's CacheCoordinator — the
    /// TokenIterator performs prefix fetch, KV restore, partial prefill,
    /// and post-generation cache store automatically.
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

        let cfg = await getConfig()
        trace?.mark("load_container_start")
        // Scoped start/finish around ONLY the container load. Symmetric
        // bookkeeping via a do/catch pair — we can't use `defer` at
        // function scope here because the function returns early (before
        // generation runs, which happens inside `gatedGenTask`), and a
        // function-scoped defer would keep `isLoadingModel` true through
        // the MetalGate wait and the rest of setup. We want the flag to
        // flip off as soon as the container is actually loaded, matching
        // the pre-fix timing.
        //
        // The refcount in `InferenceProgressManager` guarantees that
        // concurrent loads (two chat windows) don't corrupt each other,
        // and `max(0, _ - 1)` on decrement floors the count so a
        // double-fire from a future refactor can't drive it negative.
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

        let wiredPolicy = MLXLMCommon.WiredSumPolicy()
        let wiredTicket = wiredPolicy.ticket(
            size: Int(holder.weightsSizeBytes),
            kind: .active
        )

        let effectiveStopSequences = stopSequences
        let chatMessages = chatBuilder()

        let capturedMessages = chatMessages
        let buildChat: @Sendable () -> [MLXLMCommon.Chat.Message] = { capturedMessages }
        let buildTools: @Sendable () -> [[String: any Sendable]]? = {
            ModelRuntime.makeTokenizerTools(tools: tools, toolChoice: toolChoice)
        }

        // Acquire exclusive Metal access after all throwing setup is complete.
        // This ensures the gate is never left locked by a loadContainer failure.
        trace?.mark("metal_gate_enter")
        await MetalGate.shared.enterGeneration()
        trace?.mark("metal_gate_acquired")
        if Task.isCancelled {
            await MetalGate.shared.exitGeneration()
            throw CancellationError()
        }

        // Signal prefill starting (count unknown until prepareAndGenerate returns).
        InferenceProgressManager.shared.prefillWillStartAsync(tokenCount: 0)

        trace?.mark("prepare_and_generate_start")
        let genResult:
            (
                stream: AsyncStream<MLXLMCommon.TokenGeneration>,
                tokenizer: any Tokenizer,
                promptTokens: [Int],
                genTask: Task<Void, Never>,
                toolCallFormat: ToolCallFormat
            )
        do {
            genResult = try await MLXGenerationEngine.prepareAndGenerate(
                container: holder.container,
                buildChat: buildChat,
                buildToolsSpec: buildTools,
                generation: parameters,
                runtime: cfg,
                wiredMemoryTicket: wiredTicket
            )
            trace?.mark("prepare_and_generate_done")
            trace?.set("promptTokens", genResult.promptTokens.count)
        } catch {
            InferenceProgressManager.shared.prefillDidFinishAsync()
            await MetalGate.shared.exitGeneration()
            throw error
        }

        let (rawStream, tokenizer, newTokens, genTask, toolCallFormat) = genResult

        genLog.info("generateEventStream: stream created tokenCount=\(newTokens.count, privacy: .public)")
        InferenceProgressManager.shared.prefillWillStartAsync(tokenCount: newTokens.count)

        // Wrap genTask so the MetalGate is released when generation finishes.
        let innerGenTask = genTask
        let gatedGenTask = Task<Void, Never> {
            await withTaskCancellationHandler {
                await innerGenTask.value
            } onCancel: {
                innerGenTask.cancel()
            }
            await MetalGate.shared.exitGeneration()
        }
        activeGenerationTask = gatedGenTask

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

        return eventStream
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
