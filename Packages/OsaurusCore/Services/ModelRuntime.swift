//
//  ModelRuntime.swift
//  osaurus
//
//  Owns the lifecycle of MLX `ModelContainer` instances and submits each
//  request through `MLXBatchAdapter` (a thin wrapper over vmlx-swift-lm's
//  `BatchEngine`). KV caching, tool-call parsing, and reasoning extraction
//  are entirely owned by vmlx-swift-lm — see OSAURUS-INTEGRATION.md.
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

public actor ModelRuntime {
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

    /// Sendable wrapper around an immutable snapshot of chat messages.
    ///
    /// `MLXLMCommon.Chat.Message` is not `Sendable`, but our use only ever
    /// reads the array from inside one downstream `@Sendable` closure (the
    /// adapter's `buildChat` callback). A class-typed heap box lets us
    /// capture the snapshot in the closure without tripping the Sendable
    /// diagnostic, which would otherwise produce a perpetual warning at the
    /// `buildChat` definition site.
    private final class ChatMessageBox: @unchecked Sendable {
        let messages: [MLXLMCommon.Chat.Message]
        init(_ messages: [MLXLMCommon.Chat.Message]) { self.messages = messages }
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

    /// True iff `name` is currently held in `modelCache`. Lets background
    /// callers skip work that would otherwise trigger a heavy cold load.
    func isResident(name: String) -> Bool {
        return modelCache[name] != nil
    }

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
        await MLXBatchAdapter.Registry.shared.shutdownEngine(for: name)
        await ModelLease.shared.waitForZero(name)
        // Defensive: cancel the latest tracked wrapper task. The lease drain
        // above already covers in-flight requests; this only catches the
        // rare case where a task was cancelled mid-setup before acquiring.
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
        // passes, then cancel the latest tracked wrapper task and wait for
        // every leased model to drain before we touch any container.
        await MLXBatchAdapter.Registry.shared.shutdownAll()
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

        // `clearAll` empties `modelCache`, so `mlxCacheLimit()` returns 0
        // anyway — but route through the shared helper so the policy stays
        // in one place if the heuristic ever picks a non-zero floor for
        // the idle case.
        Memory.cacheLimit = mlxCacheLimit()
        Stream.gpu.synchronize()
        Memory.clearCache()
    }

    /// Invalidates the cached RuntimeConfig so the next request reads fresh values.
    func invalidateConfig() {
        cachedConfig = nil
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

        // Tool-call format + reasoning parser are stamped automatically by
        // vmlx-swift-lm's LLM/VLM factories from `jang_config.json` capabilities
        // and `config.json.model_type`. Osaurus no longer resolves them at
        // the app layer — `BatchEngine.generate` reads them directly from
        // the resolved `ModelConfiguration` to emit `.toolCall` events.

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
    //
    // KV caching is package-owned by vmlx-swift-lm — `CacheCoordinator`
    // selects model-aware cache types per layer (rotating for sliding-window
    // attention, paged for global attention, SSM state for Mamba layers),
    // sizes them based on the loaded model, and auto-flips into hybrid mode
    // when the first SSM slot is admitted.
    //
    // Per OSAURUS-INTEGRATION.md §"Coordinator-owned KV sizing", osaurus
    // adopts the four recommended knobs the library now ships defaults for:
    //
    //   - `usePagedCache: true`            — content-addressed paged blocks
    //                                        (multi-turn cache reuse path)
    //   - `defaultKVMode: .turboQuant(3,3)`— ~5x KV memory savings on slots
    //                                        that submit `kvMode: .none`
    //   - `defaultMaxKVSize: 8192`         — 8K ring window for slots that
    //                                        submit `maxKVSize: nil`
    //   - `longPromptMultiplier: 2.0`      — cap kicks in only past 16K
    //                                        (8192 * 2.0) prompt tokens,
    //                                        so short prompts keep full
    //                                        attention.
    //
    // Per-request explicit values still override these. We continue to
    // pass `modelKey` (per-model isolation) and `diskCacheDir` /
    // `enableDiskCache` (osaurus-managed disk path, sandbox-aware).
    // Everything else (`maxCacheBlocks`, `diskCacheMaxGB`, `pagedBlockSize`,
    // `ssmMaxEntries`) is left at the library default.

    /// Builds a `CacheCoordinatorConfig` with the overrides recommended
    /// by vmlx-swift-lm's `OSAURUS-INTEGRATION.md` (Coordinator-owned KV
    /// sizing) plus osaurus's per-environment disk-path config. See the
    /// file-level comment for rationale on each knob.
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

        // TEMPORARY: disable the L2 disk cache pending an upstream fix.
        //
        // vmlx-swift-lm's `CacheCoordinator` disk-restore path crashes Metal
        // (`notifyExternalReferencesNonZeroOnDealloc` inside
        // `BatchEngine.stepPrefill` → `CustomKernel.eval_gpu` →
        // `Device::clear_library`) on any second request whose prompt is fully
        // satisfied by a previously-stored entry — i.e. the
        // `Cache disk hit ... prefilling 0 remaining` path. Reproducible on
        // both `070dc5b8…` and `a7db6e5f…` pins; tracked upstream. Until a
        // pin lands that actually fixes the restore code path, force
        // memory-only KV caching so the server can't be killed by a
        // back-to-back request from any harness or chat UI.
        //
        // To re-enable once upstream is fixed: replace `false` with
        // `diskDirUsable` and bump the vmlx-swift-lm pin in
        // `Package.resolved`. The `eval_http_stability.py` suite is the
        // regression check.
        let enableDiskCache = false && diskDirUsable

        return CacheCoordinatorConfig(
            usePagedCache: true,
            enableDiskCache: enableDiskCache,
            diskCacheDir: diskCacheDir,
            modelKey: modelName,
            defaultKVMode: .turboQuant(keyBits: 3, valueBits: 3),
            defaultMaxKVSize: 8192,
            longPromptMultiplier: 2.0
        )
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
    /// Single call to `enableCaching(config:)` is all that's needed — vmlx
    /// auto-detects hybrid SSM models on first slot admission inside
    /// `BatchEngine`, so osaurus must not call `setHybrid(_:)` manually
    /// (per OSAURUS-INTEGRATION.md). Actor-isolated, so the install is
    /// observed atomically by the next request.
    private func installCacheCoordinator(on holder: SessionHolder) async {
        let cacheConfig = Self.buildCacheCoordinatorConfig(modelName: holder.name)
        holder.container.enableCaching(config: cacheConfig)

        genLog.info(
            "installCacheCoordinator: enabled for \(holder.name, privacy: .public) disk=\(cacheConfig.enableDiskCache, privacy: .public) (sizing left to vmlx defaults)"
        )
    }

    // MARK: - Generation driver

    /// Top-level dispatcher: loads the container, takes the model lease, and
    /// submits the request through `MLXBatchAdapter`. `BatchEngine` is the
    /// single MLX entry point — its actor loop is the serialization point
    /// for model access, so osaurus only needs `ModelLease` (held for the
    /// stream's lifetime to defer eviction) plus per-plugin in-flight caps
    /// in `PluginHostAPI`.
    ///
    /// `BatchEngine.generate` performs prefix fetch, KV restore, partial
    /// prefill, and post-generation cache store via the container-attached
    /// `CacheCoordinator` — osaurus does not need to plumb anything cache-
    /// related through this path.
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

        // Scoped start/finish around ONLY the container load — the "loading
        // model" UI flag flips off as soon as the container is ready. The
        // refcount in `InferenceProgressManager` keeps concurrent loads
        // (two chat windows starting different models) from corrupting
        // each other.
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

        // Pin the model against eviction for the stream's lifetime.
        await ModelLease.shared.acquire(modelName)

        // `MLXLMCommon.Chat.Message` is non-Sendable but the message array
        // never escapes the producer task. Heap-box the snapshot so the
        // `@Sendable` closure passed to `MLXBatchAdapter` can capture it
        // without tripping the Sendable-capture diagnostic.
        let chatBox = ChatMessageBox(chatBuilder())
        let buildChat: @Sendable () -> [MLXLMCommon.Chat.Message] = { chatBox.messages }
        let buildTools: @Sendable () -> [[String: any Sendable]]? = {
            ModelRuntime.makeTokenizerTools(tools: tools, toolChoice: toolChoice)
        }

        InferenceProgressManager.shared.prefillWillStartAsync(tokenCount: 0)

        let prepared: MLXBatchAdapter.PreparedStream
        do {
            prepared = try await MLXBatchAdapter.generate(
                modelName: modelName,
                container: holder.container,
                buildChat: buildChat,
                buildToolsSpec: buildTools,
                generation: parameters,
                stopSequences: stopSequences,
                runtime: cfg,
                maxBatchSize: InferenceFeatureFlags.mlxBatchEngineMaxBatchSize
            )
        } catch {
            InferenceProgressManager.shared.prefillDidFinishAsync()
            await ModelLease.shared.release(modelName)
            throw error
        }

        trace?.set("promptTokens", prepared.promptTokens.count)
        InferenceProgressManager.shared.prefillWillStartAsync(
            tokenCount: prepared.promptTokens.count
        )
        genLog.info(
            "generateEventStream: stream created tokenCount=\(prepared.promptTokens.count, privacy: .public)"
        )

        // Wrap the producer task so the lease is released when the stream
        // finishes (success or cancellation). The adapter's producer task
        // forwards Swift cancellation into the upstream stream.
        let innerProducer = prepared.genTask
        activeGenerationTask = Task<Void, Never> {
            await withTaskCancellationHandler {
                await innerProducer.value
            } onCancel: {
                innerProducer.cancel()
            }
            await ModelLease.shared.release(modelName)
        }

        return GenerationEventMapper.map(events: prepared.stream)
    }

    // MARK: - New message-based (OpenAI ChatMessage) APIs

    /// Convert a list of `ServiceToolInvocation`s into the throw shape
    /// `respondWithTools` / `streamWithTools` clients expect: nothing for an
    /// empty list, the single invocation directly for one (backwards
    /// compatibility with consumers that catch `ServiceToolInvocation`),
    /// and a `ServiceToolInvocations` batch for two or more.
    private static func throwIfTools(_ invs: [ServiceToolInvocation]) throws {
        if invs.count == 1 {
            throw invs[0]
        } else if !invs.isEmpty {
            throw ServiceToolInvocations(invocations: invs)
        }
    }

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
        var pendingTools: [ServiceToolInvocation] = []
        let augmented = ModelRuntime.applyJSONMode(messages, jsonMode: parameters.jsonMode)
        let events = try await generateEventStream(
            chatBuilder: { ModelRuntime.mapOpenAIChatToMLX(augmented) },
            parameters: parameters,
            stopSequences: stopSequences,
            tools: tools,
            toolChoice: toolChoice,
            modelId: modelId,
            modelName: modelName
        )
        // Drain the entire stream so multiple tool invocations parsed by
        // vmlx-swift-lm in a single completion are surfaced together
        // (`BatchEngine.generate` emits one `.toolCall` event per detected
        // call, so iterating to natural EOS captures all of them).
        for try await ev in events {
            switch ev {
            case .tokens(let s):
                accumulated += s
            case .reasoning:
                // Non-streaming caller — reasoning is dropped, mirroring
                // the historical `respondWithTools` shape (callers that
                // want reasoning use `streamWithTools`).
                break
            case .toolInvocation(let name, let argsJSON):
                pendingTools.append(
                    ServiceToolInvocation(toolName: name, jsonArguments: argsJSON)
                )
            case .completionInfo:
                break
            }
        }
        try Self.throwIfTools(pendingTools)
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
        let augmented = ModelRuntime.applyJSONMode(messages, jsonMode: parameters.jsonMode)
        let events = try await generateEventStream(
            chatBuilder: { ModelRuntime.mapOpenAIChatToMLX(augmented) },
            parameters: parameters,
            stopSequences: stopSequences,
            tools: tools,
            toolChoice: toolChoice,
            modelId: modelId,
            modelName: modelName
        )
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let modelSupportsThinking =
            LocalReasoningCapability.capability(forModelId: modelName).supportsThinking
        let producerTask = Task {
            // Collect every tool invocation parsed from this completion. Local
            // models can emit multiple `<tool_call>` blocks per response;
            // vmlx-swift-lm's `BatchEngine.generate` surfaces each as its own
            // `.toolCall` event, so we keep iterating until the stream
            // finishes naturally instead of bailing on the first invocation.
            var pendingTools: [ServiceToolInvocation] = []
            // Defensive scrubber for orphan `<think>` / `</think>` markers
            // that vmlx's reasoning parser leaves in `.chunk` text when a
            // low-bit MoE checkpoint emits a closer without a matching
            // opener (or vice versa). Only engaged when the model
            // declares thinking support — non-thinking models route
            // through the untouched passthrough so legitimate `<think>`
            // text in code blocks stays intact.
            var scrubber = ThinkTagScrubber()
            do {
                for try await ev in events {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    switch ev {
                    case .tokens(let s):
                        if !s.isEmpty {
                            let cleaned = modelSupportsThinking ? scrubber.scrub(s) : s
                            if !cleaned.isEmpty { continuation.yield(cleaned) }
                        }
                    case .reasoning(let s):
                        if !s.isEmpty {
                            if modelSupportsThinking {
                                continuation.yield(StreamingReasoningHint.encode(s))
                            } else {
                                continuation.yield(s)
                            }
                        }
                    case .toolInvocation(let name, let argsJSON):
                        continuation.yield(StreamingToolHint.encode(name))
                        continuation.yield(StreamingToolHint.encodeArgs(argsJSON))
                        pendingTools.append(
                            ServiceToolInvocation(toolName: name, jsonArguments: argsJSON)
                        )
                    case .completionInfo(let tokenCount, let tokensPerSecond, let unclosedReasoning):
                        continuation.yield(
                            StreamingStatsHint.encode(
                                tokenCount: tokenCount,
                                tokensPerSecond: tokensPerSecond,
                                unclosedReasoning: unclosedReasoning
                            )
                        )
                    }
                }
                // Drain any tail bytes the scrubber held back as a
                // partial-tag candidate. If the stream ended without a
                // following chunk to complete the candidate, those bytes
                // are real content (the model just happened to end on
                // `<` or `<th` etc.) and must be surfaced.
                let tail = scrubber.flush()
                if !tail.isEmpty { continuation.yield(tail) }
                do {
                    try Self.throwIfTools(pendingTools)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            } catch {
                if Task.isCancelled {
                    continuation.finish()
                } else if !pendingTools.isEmpty {
                    // Mid-stream failure with parsed tools — surface them
                    // so the caller can still execute what we got. The
                    // upstream error is swallowed in this branch by
                    // design (parity with the previous behaviour).
                    do {
                        try Self.throwIfTools(pendingTools)
                    } catch let surfaced {
                        continuation.finish(throwing: surfaced)
                    }
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
    public nonisolated static func computePrefixHash(
        systemContent: String,
        toolNames: [String]
    ) -> String {
        let tools = toolNames.sorted().joined(separator: "\0")
        let combined = systemContent + "\0" + tools
        let digest = SHA256.hash(data: Data(combined.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Build the `GenerateParameters` value handed to `BatchEngine.generate`.
    ///
    /// We deliberately do NOT pass `maxKVSize`. Cache sizing is owned by
    /// vmlx-swift-lm's `CacheCoordinator` and by each model's own
    /// architecture (sliding-window attention layers carry a fixed per-layer
    /// cache window — Gemma-4's is 1024). Forcing a global rotating window
    /// from the app layer here historically caused
    /// `[broadcast_shapes] (1,1,1,N) and (1,16,1,1024)` crashes on the
    /// first decode step. Per OSAURUS-INTEGRATION.md, the only inputs the
    /// engine wants from us are temperature / topP / maxTokens / penalties /
    /// stop sequences. `stopSequences` becomes `extraStopStrings` — the
    /// library matches against the post-reasoning, post-tool-call `.chunk`
    /// stream and halts with `.info(stopReason: .stop)` on a hit.
    nonisolated static func makeGenerateParameters(
        temperature: Float,
        maxTokens: Int,
        topP: Float,
        topK: Int = 0,
        repetitionPenalty: Float?,
        stopSequences: [String] = []
    ) -> MLXLMCommon.GenerateParameters {
        MLXLMCommon.GenerateParameters(
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            topK: topK,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: 20,
            extraStopStrings: stopSequences
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

    /// When `jsonMode` is true, prepend (or augment) a system instruction
    /// telling the model to respond with a single valid JSON object.
    /// OpenAI's `response_format: {type: json_object}` semantics — local
    /// models honor it via prompt injection (vmlx does not yet ship a
    /// constraint-grammar sampler hook). Returns `messages` unchanged
    /// when `jsonMode` is false so the no-op path is free.
    nonisolated static func applyJSONMode(
        _ messages: [ChatMessage],
        jsonMode: Bool
    ) -> [ChatMessage] {
        guard jsonMode else { return messages }
        let directive = """
            You must respond with a single valid JSON object and nothing else. \
            Do not include markdown code fences, prose, or explanations — output \
            only the JSON.
            """
        var out = messages
        if let firstSystemIdx = out.firstIndex(where: { $0.role == "system" }) {
            let existing = out[firstSystemIdx].content ?? ""
            out[firstSystemIdx] = ChatMessage(
                role: "system",
                content: existing.isEmpty ? directive : existing + "\n\n" + directive,
                tool_calls: out[firstSystemIdx].tool_calls,
                tool_call_id: out[firstSystemIdx].tool_call_id
            )
        } else {
            out.insert(
                ChatMessage(role: "system", content: directive, tool_calls: nil, tool_call_id: nil),
                at: 0
            )
        }
        return out
    }

    /// Map OpenAI-format chat messages to MLX `Chat.Message`s.
    ///
    /// Assistant tool calls and tool-role responses flow through
    /// `Chat.Message.toolCalls` / `toolCallId` (vmlx ≥ a99efeb). The
    /// `DefaultMessageGenerator` emits them into the Jinja dict so every
    /// template that reads `message.tool_calls[i]` or `message.tool_call_id`
    /// — MiniMax, Llama 3.1/3.2, Qwen 2.5 Instruct, Mistral Large, canonical
    /// OpenAI — receives structured tool state instead of the old
    /// XML-in-content workaround (which raised
    /// `TemplateException: "Message has tool role, but there was no
    /// previous assistant message with a tool call!"` on MiniMax).
    nonisolated static func mapOpenAIChatToMLX(
        _ msgs: [ChatMessage]
    ) -> [MLXLMCommon.Chat.Message] {
        var out: [MLXLMCommon.Chat.Message] = []
        out.reserveCapacity(max(6, msgs.count))
        for m in msgs {
            let images = extractImageSources(from: m)
            switch m.role {
            case "system":
                out.append(.init(role: .system, content: m.content ?? "", images: images))
            case "user":
                out.append(.init(role: .user, content: m.content ?? "", images: images))
            case "assistant":
                let content = (m.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let toolCalls = toMLXToolCalls(m.tool_calls)
                // Skip fully-empty assistant turns (no content AND no tool calls).
                if content.isEmpty && (toolCalls?.isEmpty ?? true) { continue }
                out.append(
                    MLXLMCommon.Chat.Message(
                        role: .assistant,
                        content: content,
                        images: images,
                        videos: [],
                        toolCalls: toolCalls,
                        toolCallId: nil
                    )
                )
            case "tool":
                out.append(
                    MLXLMCommon.Chat.Message(
                        role: .tool,
                        content: m.content ?? "",
                        images: images,
                        videos: [],
                        toolCalls: nil,
                        toolCallId: m.tool_call_id
                    )
                )
            default:
                out.append(.init(role: .user, content: m.content ?? "", images: images))
            }
        }
        return out
    }

    /// Convert the OpenAI-wire `ToolCall` list (arguments: JSON string) to
    /// the vmlx `MLXLMCommon.ToolCall` list (arguments: `[String: JSONValue]`).
    /// Returns `nil` for a nil/empty input so callers can pass the result
    /// straight into `Chat.Message(toolCalls:)`.
    nonisolated private static func toMLXToolCalls(
        _ calls: [ToolCall]?
    ) -> [MLXLMCommon.ToolCall]? {
        guard let calls, !calls.isEmpty else { return nil }
        return calls.map { tc in
            let argsData = tc.function.arguments.data(using: .utf8) ?? Data()
            let args: [String: MLXLMCommon.JSONValue] =
                (try? JSONDecoder().decode(
                    [String: MLXLMCommon.JSONValue].self,
                    from: argsData
                )) ?? [:]
            return MLXLMCommon.ToolCall(
                function: .init(name: tc.function.name, arguments: args)
            )
        }
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
    /// and validates the bundle's `weight_format` stamp against the presence
    /// of the `jangtq_runtime.safetensors` sidecar. Throws a clear error
    /// on either mismatch (forward or inverse) so callers see a message
    /// instead of waiting for vmlx to report the same problem 60+ shards
    /// later — or worse, hitting an unhandled-keys runtime crash.
    ///
    /// Two failure modes detected:
    ///
    /// 1. **Forward mismatch**: `weight_format == "mxtq"` declared but the
    ///    sidecar is absent. vmlx's `LLMModelFactory.dispatchDeepseekV4`
    ///    routes to the JANGTQ class purely on the stamp, then
    ///    `TurboQuantSwitchLinear.callAsFunction` `fatalError`s on the first
    ///    forward pass when the runtime cache is empty. (As of
    ///    `vmlx-swift-lm 9e647a6` vmlx fails-fast with an NSError at load
    ///    time instead of aborting, but defense-in-depth costs nothing.)
    ///
    /// 2. **Inverse mismatch (mislabeled bundle)**: sidecar IS present but
    ///    `weight_format != "mxtq"` (typically stamped `"bf16"` from a
    ///    quantization pipeline that forgot to update the label after
    ///    swapping in TurboQuant codebooks). vmlx's factory then dispatches
    ///    to the BASE `DeepseekV4Model` / `MiniMaxModel` / etc. class, hits
    ///    the `tq_norms` / `tq_packed` keys in the safetensors, and the
    ///    parameter loader throws `Unhandled keys [...]`. Confirmed in the
    ///    wild on early DSV4-Flash JANGTQ bundles (live-repro 2026-04-25).
    ///    The vmlx integration doc explicitly notes this case via the
    ///    `DSV4_FORCE_JANGTQ=1` env-var workaround. Throwing here gives the
    ///    user a remediation step (patch `weight_format` to `"mxtq"` or
    ///    re-download from a corrected source) before vmlx loads any shards.
    ///
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
            let probe = try? JSONDecoder().decode(JangConfigProbe.self, from: data)
        else {
            return
        }

        let sidecarURL = directory.appendingPathComponent("jangtq_runtime.safetensors")
        let sidecarPresent = FileManager.default.fileExists(atPath: sidecarURL.path)
        let isMxtq = probe.weight_format == "mxtq"

        // Forward mismatch: declared JANGTQ, sidecar missing.
        if isMxtq && !sidecarPresent {
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

        // Inverse mismatch: sidecar present but stamp says non-JANGTQ. The
        // safetensors carry `tq_norms` / `tq_packed` keys vmlx's base class
        // can't decode → "Unhandled keys" runtime error. Catch it here.
        if sidecarPresent && !isMxtq {
            let actualStamp = probe.weight_format ?? "absent"
            throw NSError(
                domain: "ModelRuntime",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Model '\(name)' ships the JANGTQ runtime sidecar "
                        + "('jangtq_runtime.safetensors') but its jang_config.json "
                        + "declares weight_format: \"\(actualStamp)\". This is a mislabeled "
                        + "bundle — the safetensors carry TurboQuant tensors (tq_norms / "
                        + "tq_packed) that vmlx's base model class cannot decode. "
                        + "Fix: set weight_format to \"mxtq\" in jang_config.json, "
                        + "or re-download from a corrected source."
                ]
            )
        }
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
