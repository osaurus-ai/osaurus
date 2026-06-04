//
//  ModelRuntime.swift
//  osaurus
//
//  Owns the lifecycle of MLX `ModelContainer` instances and submits each
//  request through `MLXBatchAdapter` (a thin wrapper over vmlx-swift's
//  `BatchEngine`). KV caching, tool-call parsing, and reasoning extraction
//  are entirely owned by vmlx-swift — see OSAURUS-INTEGRATION.md.
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
        let draftStrategyDescription: String?
        let nativeMTPDepth: Int?
        let mlxPressStatus: MLXPressStatus
        let cacheStats: CacheCoordinatorStatsSnapshot?
        let cacheTopology: ModelCacheTopologySnapshot?
    }

    struct LiveVoiceAudioPreencodeResult: Sendable, Equatable {
        enum Status: String, Sendable {
            case stored
            case skippedNoSamples
            case skippedUnsupportedModel
            case skippedModelNotResident
            case skippedModelUnavailable
            case failed
        }

        let status: Status
        let sampleCount: Int
        let sampleRate: Int
        let encodeMs: Int
        let message: String?
    }

    private final class SessionHolder: NSObject, @unchecked Sendable {
        let name: String
        let container: ModelContainer
        let weightsSizeBytes: Int64
        let isVLM: Bool
        let draftStrategy: MLXLMCommon.DraftStrategy?
        var cacheTopology: ModelCacheTopologySnapshot?
        init(
            name: String,
            container: ModelContainer,
            weightsSizeBytes: Int64,
            isVLM: Bool = false,
            draftStrategy: MLXLMCommon.DraftStrategy? = nil
        ) {
            self.name = name
            self.container = container
            self.weightsSizeBytes = weightsSizeBytes
            self.isVLM = isVLM
            self.draftStrategy = draftStrategy
        }
    }

    private struct NativeMTPLaunchPlan: Sendable {
        let loadConfiguration: LoadConfiguration
        let draftStrategy: MLXLMCommon.DraftStrategy?
        let statusLine: String?
        let reason: String
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
    private struct LoadingTaskRecord {
        let id: UInt64
        let task: Task<SessionHolder, Error>
    }

    private var loadingTasks: [String: LoadingTaskRecord] = [:]
    private var supersededLoadingTaskIDs = Set<UInt64>()
    private var nextLoadingTaskID: UInt64 = 0

    /// On-disk weight bytes reserved by loads that are past the pre-load gate
    /// but not yet resident in `modelCache`, keyed by model name. The
    /// coordination loop in `loadContainer` only serializes loads that have
    /// already registered a `loadingTasks` record — but the expensive pre-load
    /// awaits (`ensureComplete`, JANGTQ sidecar, flexible-budget eviction) run
    /// BEFORE registration. Two cold loads of different models can therefore
    /// both clear the `while` loop, suspend on those awaits, and reach
    /// `checkRAMFeasibility` each seeing only `modelCache` (blind to the other
    /// in-flight materialization) → double the unified-memory footprint → OOM.
    /// Recording the reservation the instant the weight size is known — and
    /// counting it in the feasibility gate — closes that window without a
    /// global cold-load lock.
    private var inflightLoadWeights: [String: Int64] = [:]
    private var currentModelName: String?
    private var cachedConfig: RuntimeConfig?

    /// Result of the most recent pre-load RAM feasibility check. Surfaced via
    /// `lastRAMFeasibilitySnapshot()` so `/health` and the model picker can
    /// show why a load was refused or flagged as tight without re-scanning.
    private var lastRAMFeasibility: RAMFeasibility?

    /// Every in-flight generation wrapper task, keyed by a monotonic id.
    /// `ModelLease` is the authoritative "is anyone still using the model"
    /// signal; these records exist so shutdown / same-model unload can
    /// defensively cancel tasks that were cancelled mid-setup before their
    /// lease became visible. Tracking *all* concurrent streams (not just the
    /// most recent) means quit can cancel every in-flight request directly
    /// instead of relying solely on the lease drain.
    private struct ActiveGenerationRecord {
        let modelName: String
        let task: Task<Void, Never>
    }
    private var activeGenerationTasks: [UInt64: ActiveGenerationRecord] = [:]
    private var nextGenerationTaskID: UInt64 = 0

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
                isCurrent: holder.name == currentModelName,
                draftStrategyDescription: Self.describeDraftStrategy(holder.draftStrategy),
                nativeMTPDepth: Self.nativeMTPDepth(holder.draftStrategy),
                mlxPressStatus: holder.container.mlxPressStatus(),
                cacheStats: holder.container.cacheCoordinator?.snapshotStats(),
                cacheTopology: holder.cacheTopology
            )
        }.sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return lhs.name < rhs.name
        }
    }

    func preencodeLiveVoiceAudioIfResident(
        modelName: String,
        attachmentId: UUID,
        samples: [Float],
        sampleRate: Int
    ) async -> LiveVoiceAudioPreencodeResult {
        guard !samples.isEmpty, sampleRate > 0 else {
            return LiveVoiceAudioPreencodeResult(
                status: .skippedNoSamples,
                sampleCount: samples.count,
                sampleRate: sampleRate,
                encodeMs: 0,
                message: nil
            )
        }

        guard ModelFamilyNames.isNemotronOmniFamily(modelName) else {
            return LiveVoiceAudioPreencodeResult(
                status: .skippedUnsupportedModel,
                sampleCount: samples.count,
                sampleRate: sampleRate,
                encodeMs: 0,
                message: nil
            )
        }

        guard
            let holder = modelCache[modelName]
                ?? modelCache.values.first(where: {
                    $0.name.caseInsensitiveCompare(modelName) == .orderedSame
                })
        else {
            return LiveVoiceAudioPreencodeResult(
                status: .skippedModelNotResident,
                sampleCount: samples.count,
                sampleRate: sampleRate,
                encodeMs: 0,
                message: nil
            )
        }

        await ModelResidencyManager.shared.markActive(modelName: holder.name)
        await ModelLease.shared.acquire(holder.name)
        let soloLease = await MLXBatchAdapter.Registry.shared.acquireSoloLease(for: holder.name)

        final class OutBox: @unchecked Sendable {
            var result: LiveVoiceAudioPreencodeResult?
        }
        let box = OutBox()

        do {
            try await holder.container.perform { context in
                guard let omni = context.model as? NemotronHOmni else {
                    box.result = LiveVoiceAudioPreencodeResult(
                        status: .skippedModelUnavailable,
                        sampleCount: samples.count,
                        sampleRate: sampleRate,
                        encodeMs: 0,
                        message: "Resident model is not NemotronHOmni"
                    )
                    return
                }

                let startedAt = CFAbsoluteTimeGetCurrent()
                guard
                    case .preEncoded(let encodedSamples, let encodedSampleRate, let embedding) =
                        try MLXBatchAdapter.preencodedAudio(
                            .samples(samples, sampleRate: sampleRate),
                            using: omni
                        )
                else {
                    box.result = LiveVoiceAudioPreencodeResult(
                        status: .skippedModelUnavailable,
                        sampleCount: samples.count,
                        sampleRate: sampleRate,
                        encodeMs: 0,
                        message: "Nemotron audio encoder returned no embedding"
                    )
                    return
                }

                let encodeMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                LiveVoiceAudioInputRegistry.shared.storePreencoded(
                    samples: encodedSamples,
                    sampleRate: encodedSampleRate,
                    sourceSampleCount: samples.count,
                    sourceSampleRate: sampleRate,
                    embedding: embedding,
                    encodeMs: encodeMs,
                    for: attachmentId
                )
                box.result = LiveVoiceAudioPreencodeResult(
                    status: .stored,
                    sampleCount: samples.count,
                    sampleRate: sampleRate,
                    encodeMs: encodeMs,
                    message: nil
                )
            }
        } catch {
            await soloLease.release()
            await ModelLease.shared.release(holder.name)
            await scheduleIdleResidency(for: holder.name)
            return LiveVoiceAudioPreencodeResult(
                status: .failed,
                sampleCount: samples.count,
                sampleRate: sampleRate,
                encodeMs: 0,
                message: String(describing: error)
            )
        }

        await soloLease.release()
        await ModelLease.shared.release(holder.name)
        await scheduleIdleResidency(for: holder.name)

        return box.result
            ?? LiveVoiceAudioPreencodeResult(
                status: .skippedModelUnavailable,
                sampleCount: samples.count,
                sampleRate: sampleRate,
                encodeMs: 0,
                message: nil
            )
    }

    // MARK: - Model lifecycle

    /// Defensive helper: cancels and awaits every tracked generation task
    /// (optionally filtered to one model). With `ModelLease` enforcing
    /// per-stream lifetime the unload paths already wait on
    /// `waitForZero(name)` first, so this primarily catches the rare race
    /// where a task was launched but never made it to `acquire`, and — at
    /// quit — guarantees *all* concurrent streams are cancelled, not just
    /// the most recent. Callers should still treat the lease as authoritative.
    private func cancelActiveGeneration(for modelName: String? = nil) async {
        let records = activeGenerationTasks.filter { _, record in
            modelName == nil || record.modelName == modelName
        }
        guard !records.isEmpty else { return }
        for (_, record) in records { record.task.cancel() }
        for (_, record) in records { _ = await record.task.value }
        for id in records.keys { activeGenerationTasks.removeValue(forKey: id) }
    }

    /// Allocate a monotonic id for a new generation wrapper task.
    private func allocateGenerationTaskID() -> UInt64 {
        nextGenerationTaskID &+= 1
        return nextGenerationTaskID
    }

    /// Remove a generation record once its wrapper task finishes on its own
    /// (success or cancellation), so the tracking dictionary doesn't grow
    /// unbounded across a long-lived process.
    private func clearGenerationTask(id: UInt64) {
        activeGenerationTasks.removeValue(forKey: id)
    }

    /// Quit-path helper: cancel every in-flight generation across all models
    /// without evicting containers or freeing buffers. Run early in the
    /// termination sequence so SSE producers stop and the HTTP server's
    /// graceful shutdown can drain its child channels; `clearAll(quit:)`
    /// performs the full container/GPU teardown afterward.
    func cancelAllGenerations() async {
        await MLXBatchAdapter.Registry.shared.shutdownAll()
        await cancelActiveGeneration()
    }

    /// Cancel the active decode for `name` without evicting the loaded
    /// container. HTTP non-streaming callers use this when the client drops
    /// before any response body can be written; otherwise the server can keep
    /// decoding for a request nobody is still reading.
    func cancelGeneration(name: String) async {
        await MLXBatchAdapter.Registry.shared.shutdownEngine(for: name)
        await cancelActiveGeneration(for: name)
    }

    private func allocateLoadingTaskID() -> UInt64 {
        nextLoadingTaskID &+= 1
        return nextLoadingTaskID
    }

    private func cancelAndDrainLoadingTasks(
        _ records: [(String, LoadingTaskRecord)],
        quit: Bool = false
    ) async {
        guard !records.isEmpty else { return }

        for (name, record) in records {
            if loadingTasks[name]?.id == record.id {
                supersededLoadingTaskIDs.insert(record.id)
            }
            record.task.cancel()
        }

        // The join below (`await record.task.value`) can block for the full
        // remaining weight-materialization of a cold load — Swift
        // cancellation is cooperative and `loadModelContainer` only checks
        // it before/after the MLX load. On the normal eviction path we pay
        // that to disable caching on the superseded holder; at *quit* we
        // skip the join (and the intermediate GPU fence) so a load in
        // progress can't stall process exit. The OS reclaims GPU resources
        // on exit, and `clearAll(quit:)` still issues a final, watchdog-
        // bounded `Stream.gpu.synchronize()`.
        if !quit {
            for (_, record) in records {
                if let holder = try? await record.task.value,
                    supersededLoadingTaskIDs.contains(record.id)
                {
                    holder.container.disableCaching()
                }
            }
        }

        for (name, record) in records {
            if loadingTasks[name]?.id == record.id {
                loadingTasks.removeValue(forKey: name)
            }
            supersededLoadingTaskIDs.remove(record.id)
        }

        if !quit {
            Stream.gpu.synchronize()
            Memory.clearCache()
        }
    }

    private func cancelLoadingTask(name: String, loadID: UInt64) async {
        guard let record = loadingTasks[name], record.id == loadID else { return }
        await cancelAndDrainLoadingTasks([(name, record)])
    }

    private func finishLoadedContainer(
        name: String,
        holder: SessionHolder,
        loadID: UInt64
    ) async throws -> SessionHolder {
        if let cached = modelCache[name], cached === holder {
            return cached
        }

        guard loadingTasks[name]?.id == loadID,
            !supersededLoadingTaskIDs.contains(loadID)
        else {
            holder.container.disableCaching()
            throw CancellationError()
        }

        modelCache[name] = holder
        loadingTasks.removeValue(forKey: name)
        currentModelName = name
        Memory.cacheLimit = mlxCacheLimit()

        // Enable multi-tier KV caching via vmlx-swift's CacheCoordinator.
        // Cache tier config is entirely osaurus-internal — not user-visible.
        await installCacheCoordinator(on: holder)

        genLog.info(
            "loadContainer: loaded \(name, privacy: .public) isVLM=\(holder.isVLM, privacy: .public)"
        )
        return holder
    }

    /// Unload `name`, blocking until any in-flight generation against this
    /// model has fully released its lease. The lease is held for the entire
    /// stream lifetime (see `generateEventStream`), so this guarantees we
    /// never free buffers that an active Metal command buffer still references.
    func unload(name: String) async {
        await ModelResidencyManager.shared.cancel(modelName: name)

        // Shut the BatchEngine first so its scheduling loop stops issuing
        // new model forward passes; then wait for any in-flight per-request
        // leases to drain before we touch the container.
        await MLXBatchAdapter.Registry.shared.shutdownEngine(for: name)
        await ModelLease.shared.waitForZero(name)
        // Defensive: cancel the latest tracked wrapper task. The lease drain
        // above already covers in-flight requests; this only catches the
        // rare case where a task was cancelled mid-setup before acquiring.
        await cancelActiveGeneration(for: name)

        if let record = loadingTasks[name] {
            await cancelAndDrainLoadingTasks([(name, record)])
        }

        modelCache[name]?.container.disableCaching()

        autoreleasepool {
            _ = modelCache.removeValue(forKey: name)
        }
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

    /// Tear down all loaded/loading models and free GPU buffers.
    ///
    /// - Parameter quit: when `true`, every otherwise-unbounded wait is
    ///   capped so a stuck lease or in-flight cold load can't hang app
    ///   termination. The lease drain uses the timed `waitForZero` variant
    ///   and the cold-load drain skips its cooperative join. Callers on the
    ///   normal (settings-change / GC) path leave this `false` for the full,
    ///   correctness-first teardown.
    func clearAll(quit: Bool = false) async {
        await ModelResidencyManager.shared.cancelAll()

        // Shut down every BatchEngine so they stop scheduling new forward
        // passes and cancel ALL tracked generation wrapper tasks, then wait
        // for every leased model to drain before we touch any container.
        await cancelAllGenerations()
        var hasStuckLease = false
        for name in modelCache.keys {
            if quit {
                // Force-proceed fallback: a never-released lease (a producer
                // that ignored cancellation) returns `false` here after the
                // cap instead of hanging the quit chain forever. We record
                // it so we can skip the buffer free below — see the UAF note.
                let drained = await ModelLease.shared.waitForZero(name, timeoutSeconds: 2.0)
                if !drained { hasStuckLease = true }
            } else {
                await ModelLease.shared.waitForZero(name)
            }
        }

        let loadingRecords = loadingTasks.map { ($0.key, $0.value) }
        await cancelAndDrainLoadingTasks(loadingRecords, quit: quit)

        // Quit-path use-after-free guard: `ModelLease` exists precisely to
        // stop us from freeing a model's Metal buffers while a generation
        // still references them (`notifyExternalReferencesNonZeroOnDealloc`).
        // If a holder ignored cancellation and the lease never drained, the
        // safe move on the way out is NOT to free anything: calling
        // `disableCaching()` / `Stream.gpu.synchronize()` against a live,
        // stuck command buffer is either a UAF or a hang. The process is
        // terminating, so let the OS reclaim GPU memory on `exit()` instead
        // of a partial container free. (`cancelAllGenerations` already shut
        // down every BatchEngine, so no new GPU work can be scheduled.)
        if quit && hasStuckLease {
            genLog.error(
                "clearAll(quit:) detected a stuck model lease — skipping buffer free; OS will reclaim GPU on exit"
            )
            loadingTasks.removeAll()
            supersededLoadingTaskIDs.removeAll()
            currentModelName = nil
            cachedConfig = nil
            return
        }

        for holder in modelCache.values {
            holder.container.disableCaching()
        }

        autoreleasepool {
            modelCache.removeAll()
        }
        loadingTasks.removeAll()
        supersededLoadingTaskIDs.removeAll()
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

    private func scheduleIdleResidency(for modelName: String) async {
        let policy =
            await ServerConfigurationStore.load()?.modelIdleResidencyPolicy
            ?? ServerConfiguration.default.modelIdleResidencyPolicy

        await ModelResidencyManager.shared.scheduleIdleUnload(
            modelName: modelName,
            policy: policy,
            unload: { name in await ModelRuntime.shared.unload(name: name) },
            leaseCount: { name in await ModelLease.shared.count(for: name) },
            isResident: { name in await ModelRuntime.shared.isResident(name: name) }
        )
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

    private static func flexibleResidentBudgetBytes() -> Int64 {
        Int64(Double(ProcessInfo.processInfo.physicalMemory) * 0.70)
    }

    /// Snapshot of the most recent pre-load RAM feasibility assessment.
    public struct RAMFeasibility: Sendable, Equatable {
        public enum Verdict: String, Sendable, Equatable {
            /// Comfortably within budget.
            case ok
            /// Above the soft (warn) threshold but below the hard ceiling —
            /// loaded anyway, but resident pressure is high.
            case tight
            /// Above the hard ceiling — the load was refused.
            case refused
        }
        public let modelName: String
        public let verdict: Verdict
        public let incomingWeightsBytes: Int64
        public let residentWeightsBytes: Int64
        public let kvHeadroomBytes: Int64
        public let projectedBytes: Int64
        public let physicalMemoryBytes: Int64
        public let softLimitBytes: Int64
        public let hardLimitBytes: Int64
        public let timestamp: Date
    }

    /// Fraction of physical RAM above which a load is flagged `tight` (warn).
    private static let ramSoftThreshold = 0.70
    /// Fraction of physical RAM above which a load is `refused`.
    private static let ramHardThreshold = 0.90

    /// Estimated KV-cache + activation headroom an incoming load needs beyond
    /// its static weights. We don't know the exact context length up front, so
    /// scale modestly with weight size and floor it so even a small model
    /// reserves something. Intentionally conservative — the goal is to catch
    /// "this clearly won't fit" before the OS jetsams us, not to be exact.
    private static func estimatedKVHeadroomBytes(forWeights weights: Int64) -> Int64 {
        let scaled = Int64(Double(weights) * 0.20)
        let floor: Int64 = 512 * 1024 * 1024
        return max(scaled, floor)
    }

    /// Public read of the last feasibility assessment for `/health` + UI.
    public func lastRAMFeasibilitySnapshot() -> RAMFeasibility? {
        lastRAMFeasibility
    }

    /// Pre-load RAM feasibility gate. Records `lastRAMFeasibility` for
    /// observability and throws when the projected footprint exceeds the hard
    /// ceiling. Applies to all eviction policies.
    private func checkRAMFeasibility(
        modelName: String,
        incomingWeightsBytes: Int64,
        excludingResident excludedName: String?
    ) throws {
        let physical = Int64(ProcessInfo.processInfo.physicalMemory)
        guard physical > 0, incomingWeightsBytes > 0 else { return }

        let resident = residentWeightBytes(excluding: excludedName)
        // Other cold loads already past the gate but not yet resident. Without
        // this, two concurrent loads of different models each see only the
        // (empty) cache and both pass, doubling the real footprint.
        let inflightOther = inflightLoadWeightBytes(excluding: excludedName)
        let kvHeadroom = Self.estimatedKVHeadroomBytes(forWeights: incomingWeightsBytes)
        let projected = resident + inflightOther + incomingWeightsBytes + kvHeadroom
        let softLimit = Int64(Double(physical) * Self.ramSoftThreshold)
        let hardLimit = Int64(Double(physical) * Self.ramHardThreshold)

        let verdict: RAMFeasibility.Verdict
        if projected > hardLimit {
            verdict = .refused
        } else if projected > softLimit {
            verdict = .tight
        } else {
            verdict = .ok
        }

        lastRAMFeasibility = RAMFeasibility(
            modelName: modelName,
            verdict: verdict,
            incomingWeightsBytes: incomingWeightsBytes,
            residentWeightsBytes: resident,
            kvHeadroomBytes: kvHeadroom,
            projectedBytes: projected,
            physicalMemoryBytes: physical,
            softLimitBytes: softLimit,
            hardLimitBytes: hardLimit,
            timestamp: Date()
        )

        switch verdict {
        case .ok:
            break
        case .tight:
            genLog.error(
                "loadContainer: RAM tight for \(modelName, privacy: .public) projected=\(projected, privacy: .public) soft=\(softLimit, privacy: .public) physical=\(physical, privacy: .public)"
            )
        case .refused:
            genLog.error(
                "loadContainer: refusing \(modelName, privacy: .public) — projected footprint \(projected, privacy: .public)B exceeds hard limit \(hardLimit, privacy: .public)B (physical \(physical, privacy: .public)B)"
            )
            let projGB = String(format: "%.1f", Double(projected) / 1_073_741_824)
            let physGB = String(format: "%.1f", Double(physical) / 1_073_741_824)
            throw NSError(
                domain: "ModelRuntime",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Not enough memory to load \(modelName): needs ~\(projGB) GB (weights + KV headroom) but this Mac has \(physGB) GB. Free up RAM, choose a smaller/more-quantized model, or close other models."
                ]
            )
        }
    }

    private func residentWeightBytes(excluding excludedName: String? = nil) -> Int64 {
        modelCache.reduce(Int64(0)) { total, entry in
            if entry.key == excludedName { return total }
            return total + entry.value.weightsSizeBytes
        }
    }

    /// Weight bytes reserved by loads in flight (past the pre-load gate, not
    /// yet resident). Counted by `checkRAMFeasibility` so a concurrent cold
    /// load of a *different* model is visible to the gate.
    private func inflightLoadWeightBytes(excluding excludedName: String? = nil) -> Int64 {
        inflightLoadWeights.reduce(Int64(0)) { total, entry in
            if entry.key == excludedName { return total }
            return total + entry.value
        }
    }

    /// Flexible mode can keep multiple small models resident, but it must not
    /// keep a huge model while starting another huge load. The vmlx load path
    /// applies a 70% MLX memory budget; mirror that budget before entering
    /// `loadWeights` so Hy3-sized residents do not collide with the next load.
    private func unloadForFlexibleResidentBudget(
        targetName: String,
        incomingWeightsSizeBytes: Int64
    ) async {
        let limit = Self.flexibleResidentBudgetBytes()
        guard limit > 0 else { return }

        while residentWeightBytes(excluding: targetName) + incomingWeightsSizeBytes > limit {
            guard
                let candidate =
                    modelCache
                    .filter({ $0.key != targetName })
                    .max(by: { $0.value.weightsSizeBytes < $1.value.weightsSizeBytes })
            else {
                return
            }

            genLog.info(
                "loadContainer: flexible budget eviction of \(candidate.key, privacy: .public) before loading \(targetName, privacy: .public) residentBytes=\(self.residentWeightBytes(excluding: targetName), privacy: .public) incomingBytes=\(incomingWeightsSizeBytes, privacy: .public) limitBytes=\(limit, privacy: .public)"
            )
            await unload(name: candidate.key)
        }
    }

    private func loadContainer(id: String, name: String) async throws -> SessionHolder {
        try Task.checkCancellation()
        let policy = await ServerConfigurationStore.load()?.modelEvictionPolicy ?? .strictSingleModel
        let loadStartedAt = CFAbsoluteTimeGetCurrent()
        genLog.info(
            "loadContainer: begin model=\(name, privacy: .public) id=\(id, privacy: .public) policy=\(policy.rawValue, privacy: .public)"
        )
        // Timeline breadcrumb so a main-thread hang that surfaces with an unsymbolicated
        // native stack still shows whether a model load was in flight. Model id only, no PII.
        CrashReportingService.recordBreadcrumb(category: "model.load", message: "begin model=\(name)")

        while true {
            try Task.checkCancellation()
            if let existing = modelCache[name] {
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - loadStartedAt) * 1000)
                genLog.info(
                    "loadContainer: cache hit model=\(name, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)"
                )
                return existing
            }

            if let existingRecord = loadingTasks[name] {
                do {
                    let holder = try await existingRecord.task.value
                    return try await finishLoadedContainer(
                        name: name,
                        holder: holder,
                        loadID: existingRecord.id
                    )
                } catch is CancellationError {
                    if loadingTasks[name]?.id == existingRecord.id {
                        loadingTasks.removeValue(forKey: name)
                    }
                    supersededLoadingTaskIDs.remove(existingRecord.id)
                    continue
                } catch {
                    if loadingTasks[name]?.id == existingRecord.id {
                        loadingTasks.removeValue(forKey: name)
                    }
                    supersededLoadingTaskIDs.remove(existingRecord.id)
                    throw error
                }
            }

            if let otherLoading = loadingTasks.first(where: { $0.key != name }) {
                let otherName = otherLoading.key
                let otherRecord = otherLoading.value
                if policy == .strictSingleModel {
                    genLog.info(
                        "loadContainer: strict drain of in-flight load \(otherName, privacy: .public)"
                    )
                    await cancelAndDrainLoadingTasks([(otherName, otherRecord)])
                } else {
                    do {
                        let holder = try await otherRecord.task.value
                        _ = try? await finishLoadedContainer(
                            name: otherName,
                            holder: holder,
                            loadID: otherRecord.id
                        )
                    } catch {
                        if loadingTasks[otherName]?.id == otherRecord.id {
                            loadingTasks.removeValue(forKey: otherName)
                        }
                        supersededLoadingTaskIDs.remove(otherRecord.id)
                    }
                }
                continue
            }

            if policy == .strictSingleModel,
                let other = modelCache.keys.first(where: { $0 != name })
            {
                genLog.info("loadContainer: strict eviction of \(other, privacy: .public)")
                await unload(name: other)
                continue
            }

            break
        }

        try Task.checkCancellation()
        guard let localURL = Self.findLocalDirectory(forModelId: id) else {
            throw NSError(
                domain: "ModelRuntime",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Model not downloaded: \(name)"]
            )
        }
        genLog.info(
            "loadContainer: local directory model=\(name, privacy: .public) path=\(localURL.path, privacy: .public)"
        )

        let probe = MLXModel(id: id, name: name, description: "", downloadURL: "")
        let completeVerified = await ModelDownloadService.ensureComplete(for: probe, directory: localURL)
        if !completeVerified {
            // `ensureComplete` returns false when the remote file list couldn't
            // be fetched (offline / HF down) or a missing-file fetch failed. A
            // complete local bundle is still loadable offline, so this is a
            // warning, not a hard failure — the shard-manifest verification
            // below is the authoritative local-integrity gate.
            genLog.warning(
                "loadContainer: ensureComplete could not verify remote completeness model=\(name, privacy: .public) — proceeding on local files; will manifest-verify shards"
            )
        }
        try Task.checkCancellation()

        // Manifest-verify ALL weight shards. `MLXModel.isDownloaded` only
        // requires *one* `*.safetensors` file, so a partially-downloaded
        // sharded bundle (one shard present, the rest missing) passes the UI
        // gate but makes vmlx abort() the whole process on the first forward
        // pass when it can't find a referenced tensor. Fail loud here with a
        // clear error and keep the server up.
        try Self.verifyShardManifest(at: localURL, name: name)
        try Task.checkCancellation()

        // Preflight: JANGTQ/TurboQuant variants need a `jangtq_runtime.safetensors`
        // sidecar (signs + codebook arrays for the Metal kernels). vmlx's
        // LLMModelFactory dispatches to the JANGTQ class strictly on
        // `jang_config.json.weight_format == "mxtq"`, but the runtime cache is
        // only populated when the sidecar file exists. If the config asks for
        // JANGTQ and the sidecar is missing, vmlx reaches the first forward
        // pass, hits a precondition in TurboQuantSwitchLinear, and abort()s
        // the whole process — taking osaurus with it. Caught here so the user
        // gets a clear error and the server stays up.
        try Self.validateUnsupportedPlainDSV4AffineJANG(at: localURL, name: name)
        try await Self.ensureJANGTQSidecar(at: localURL, modelId: id, name: name)
        // Compute the incoming bundle's on-disk weight size for *every* policy.
        // Previously only `manualMultiModel` did this (strict left it 0), which
        // meant the resident-RAM accounting — and the pre-load feasibility gate
        // below — were blind under the default strict policy. The value also
        // feeds `mlxCacheLimit()` and the `/health` + model-picker surfaces.
        let weightsBytes = Self.computeWeightsSizeBytes(at: localURL)
        genLog.info(
            "loadContainer: pre-load checks done model=\(name, privacy: .public) weightsBytes=\(weightsBytes, privacy: .public)"
        )

        // Reserve this load's footprint the instant it's known, BEFORE the
        // feasibility gate and the task registration below, so a concurrent
        // cold load of a different model that is also past the coordination
        // loop sees it. Cleared on every exit path (refuse, cancel, success)
        // — by the time the success path returns, the model is already
        // resident in `modelCache`, so dropping the reservation can't
        // momentarily under-count.
        inflightLoadWeights[name] = weightsBytes
        defer { inflightLoadWeights.removeValue(forKey: name) }

        try Task.checkCancellation()

        if policy == .manualMultiModel {
            await unloadForFlexibleResidentBudget(
                targetName: name,
                incomingWeightsSizeBytes: weightsBytes
            )
        }
        try Task.checkCancellation()

        // Pre-load RAM feasibility gate (all policies). After strict eviction /
        // flexible budget trimming above, `resident` reflects what will still
        // be alive when this load lands. If projected footprint blows past the
        // hard ceiling, refuse with a clear error instead of letting the OS
        // jetsam/OOM-kill us mid-load. A softer threshold only warns.
        try checkRAMFeasibility(
            modelName: name,
            incomingWeightsBytes: weightsBytes,
            excludingResident: name
        )

        // Tool-call format + reasoning parser are stamped automatically by
        // vmlx-swift's LLM/VLM factories from `jang_config.json` capabilities
        // and `config.json.model_type`. Server Runtime Settings may layer an
        // explicit parser override on top; the resulting ModelConfiguration
        // still enters through vmlx's factory registry, so BatchEngine remains
        // the single owner of parser execution and `.toolCall` emission.

        let loadID = allocateLoadingTaskID()
        let task = Task<SessionHolder, Error> {
            let taskStartedAt = CFAbsoluteTimeGetCurrent()
            genLog.info(
                "loadContainer: task start model=\(name, privacy: .public) loadID=\(loadID, privacy: .public)"
            )
            try Task.checkCancellation()
            let tokenizerLoader = SwiftTransformersTokenizerLoader()
            let serverSettings = ServerRuntimeSettingsStore.snapshot()
            let mtpPlan = Self.resolveNativeMTPLaunchPlan(
                modelDirectory: localURL,
                settings: serverSettings
            )
            genLog.info(
                "loadContainer: native MTP plan model=\(name, privacy: .public) nativeMTP=\(mtpPlan.loadConfiguration.nativeMTP, privacy: .public) draftStrategy=\(Self.describeDraftStrategy(mtpPlan.draftStrategy), privacy: .public) reason=\(mtpPlan.reason, privacy: .public) status=\(mtpPlan.statusLine ?? "none", privacy: .public)"
            )
            let container = try await loadModelContainer(
                from: localURL,
                using: tokenizerLoader,
                configuration: serverSettings.resolvedModelConfiguration(
                    base: ModelConfiguration(directory: localURL)
                ),
                loadConfiguration: mtpPlan.loadConfiguration
            )
            if Task.isCancelled {
                container.disableCaching()
                throw CancellationError()
            }
            let isVLM = await container.isVLM
            if Task.isCancelled {
                container.disableCaching()
                throw CancellationError()
            }
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - taskStartedAt) * 1000)
            genLog.info(
                "loadContainer: task loaded model=\(name, privacy: .public) loadID=\(loadID, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public) isVLM=\(isVLM, privacy: .public)"
            )
            return SessionHolder(
                name: name,
                container: container,
                weightsSizeBytes: weightsBytes,
                isVLM: isVLM,
                draftStrategy: mtpPlan.draftStrategy
            )
        }

        loadingTasks[name] = LoadingTaskRecord(id: loadID, task: task)

        do {
            let holder = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task {
                    await ModelRuntime.shared.cancelLoadingTask(name: name, loadID: loadID)
                }
            }
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - loadStartedAt) * 1000)
            genLog.info(
                "loadContainer: task value returned model=\(name, privacy: .public) loadID=\(loadID, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)"
            )
            CrashReportingService.recordBreadcrumb(
                category: "model.load", message: "loaded model=\(name) elapsedMs=\(elapsedMs)")
            return try await finishLoadedContainer(
                name: name,
                holder: holder,
                loadID: loadID
            )
        } catch {
            if loadingTasks[name]?.id == loadID {
                loadingTasks.removeValue(forKey: name)
            }
            supersededLoadingTaskIDs.remove(loadID)
            throw error
        }
    }

    // MARK: - Cache coordinator plumbing
    //
    // KV caching is package-owned by vmlx-swift — `CacheCoordinator`
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
    //   - `defaultKVMode`                   — owned by vmlx
    //                                        `VMLXServerRuntimeSettings`.
    //                                        `engine_selected` resolves to
    //                                        automatic TurboQuant KV for
    //                                        ordinary full-history KV layers;
    //                                        DSV4/ZAYA/SSM/rotating caches
    //                                        keep their typed companion-state
    //                                        serializers and are not replaced
    //                                        by generic KV compression.
    //   - `defaultMaxKVSize: 65536`        — 64K ring window for slots that
    //                                        submit `maxKVSize: nil`. Matches
    //                                        the vmlx OSAURUS-PRODUCTION-
    //                                        REFERENCE-2026-05-01.md §6
    //                                        example. The prior 8192 value
    //                                        silently truncated long-context
    //                                        prompts (50K-token PDFs lost
    //                                        ~84% of attention context) past
    //                                        the 16K trigger. Worst-case
    //                                        wired memory at 65K × 88 layers
    //                                        × 8 KV-heads × 128 head_dim ×
    //                                        2 bytes (fp16) × 2 (K+V) ≈
    //                                        2.4 GB per slot on Mistral 3.5
    //                                        (largest layer count we ship);
    //                                        on TurboQuant KV steady state is
    //                                        much smaller. With
    //                                        `engine_selected`, ordinary KV
    //                                        layers use the vmlx automatic
    //                                        codec; the rotating cap only
    //                                        kicks in for prompts past 131K
    //                                        (65536 × 2.0), so small chats
    //                                        are unaffected.
    //   - `longPromptMultiplier: 2.0`      — cap kicks in only past 131K
    //                                        (65536 * 2.0) prompt tokens,
    //                                        so short and medium prompts
    //                                        keep full attention.
    //
    // Per-request explicit values still override these. We continue to
    // pass `modelKey` (per-model isolation) and `diskCacheDir` /
    // `enableDiskCache` (osaurus-managed disk path, sandbox-aware).
    // Everything else (`maxCacheBlocks`, `diskCacheMaxGB`, `pagedBlockSize`,
    // `ssmMaxEntries`) is left at the library default.

    /// Builds a `CacheCoordinatorConfig` with the overrides recommended
    /// by vmlx-swift's `OSAURUS-INTEGRATION.md` (Coordinator-owned KV
    /// sizing) plus osaurus's per-environment disk-path config. See the
    /// file-level comment for rationale on each knob.
    private nonisolated static func buildCacheCoordinatorConfig(
        modelName: String,
        cacheTopology: ModelCacheTopologySnapshot? = nil
    ) -> CacheCoordinatorConfig {
        let settings = ServerRuntimeSettingsStore.snapshot()
        let diskCacheDir = Self.cacheDiskDirectoryOverride(for: settings.cache)
        if let diskCacheDir {
            OsaurusPaths.ensureExistsSilent(diskCacheDir)
        }
        let diskDirUsable = diskCacheDir.map(isDirectoryWritable) ?? false
        if let diskCacheDir, !diskDirUsable {
            genLog.warning(
                "buildCacheCoordinatorConfig: disk cache dir not writable, forcing memory-only: \(diskCacheDir.path, privacy: .public)"
            )
        }

        // The Metal `notifyExternalReferencesNonZeroOnDealloc` crash on the
        // `Cache disk hit … prefilling 0 remaining` path is fixed upstream
        // in vmlx-swift `0756dc0` ("close trim-path Metal lifecycle crash
        // on full disk-cache hit") — the trimmed compiled-cache list is now
        // forced to realize before its underlying Metal buffers go out of
        // scope. Now wired in through the `0e22eba` pin. The
        // `eval_http_stability.py` suite is the regression check; re-run on
        // any future pin bump that touches the CacheCoordinator restore path.
        //
        // L2 disk-cache modelKey fingerprint includes the KV mode tag and
        // native cache-topology tags so runtime upgrades cannot serve stale
        // entries encoded under a different serializer contract. This matters
        // for path-dependent caches such as DSV4's SWA+CSA+HSA pool and
        // ZAYA's CCA state: a content hash alone proves prompt identity, not
        // cache-layout compatibility.
        let effectiveDefaultKVMode = defaultKVMode(
            for: settings.cache,
            modelName: modelName,
            cacheTopology: cacheTopology
        )
        let kvModeTag = cacheKVModeTag(
            for: settings.cache,
            modelName: modelName,
            cacheTopology: cacheTopology
        )
        let scopedKey = Self.cacheCoordinatorModelKey(
            modelName: modelName,
            kvModeTag: kvModeTag,
            cacheTopology: cacheTopology
        )

        // Delegate the full coordinator config to vmlx's spec'd builder
        // so every cache field set in the Server → Settings panel
        // (prefix, paged, block disk, legacy disk, SSM rederive, KV
        // codec, defaultMaxKVSize, longPromptMultiplier) flows into
        // BatchEngine. The diskCacheDirectory override is either the
        // user-configured disk directory or the writable Osaurus default;
        // when that path is unusable, disable disk cache instead of letting
        // vmlx fall back to a different implicit location.
        var config = settings.cacheCoordinatorConfig(
            modelKey: scopedKey,
            diskCacheDirectory: diskDirUsable ? diskCacheDir : nil,
            ssmMaxEntries: 50
        )
        config.defaultKVMode = effectiveDefaultKVMode
        if diskCacheDir != nil, !diskDirUsable {
            config.enableDiskCache = false
            config.diskCacheDir = nil
        }
        return config
    }

    nonisolated static func cacheDiskDirectoryOverride(
        for cache: VMLXServerCacheSettings
    ) -> URL? {
        guard cache.prefix.enabled else { return nil }

        let directory: String?
        if cache.pagedKV.enabled {
            guard cache.blockDisk.enabled else { return nil }
            directory = cache.blockDisk.directory
        } else {
            guard cache.legacyDisk.enabled else { return nil }
            directory = cache.legacyDisk.directory
        }

        return resolvedServerRuntimeDirectory(directory) ?? OsaurusPaths.diskKVCache()
    }

    private nonisolated static func resolvedServerRuntimeDirectory(_ path: String?) -> URL? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty
        else { return nil }
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        if path.hasPrefix("~/") {
            let suffix = String(path.dropFirst(2))
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(suffix, isDirectory: true)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Stable fingerprint for the effective live KV codec. Appended to
    /// the L2 disk-cache model key so a mid-session change to the
    /// actual KV representation doesn't serve stale entries.
    nonisolated static func defaultKVMode(
        for cache: VMLXServerCacheSettings,
        modelName: String,
        cacheTopology: ModelCacheTopologySnapshot? = nil
    ) -> KVQuantizationMode {
        switch cache.liveKVCodec {
        case .engineSelected:
            return shouldUseTurboQuantByDefault(
                modelName: modelName,
                cacheTopology: cacheTopology
            ) ? .turboQuant() : .none
        case .native, .none:
            return .none
        case .turboQuant:
            return cache.defaultKVMode
        }
    }

    nonisolated static func cacheKVModeTag(
        for cache: VMLXServerCacheSettings,
        modelName: String,
        cacheTopology: ModelCacheTopologySnapshot? = nil
    ) -> String {
        switch defaultKVMode(for: cache, modelName: modelName, cacheTopology: cacheTopology) {
        case .none:
            return "fp16"
        case .affine(let bits, let groupSize):
            return "affine(\(bits),\(groupSize))"
        case .turboQuant(let keyBits, let valueBits):
            return "turbo(\(keyBits),\(valueBits))"
        }
    }

    nonisolated static func shouldUseTurboQuantByDefault(
        modelName: String,
        cacheTopology: ModelCacheTopologySnapshot? = nil
    ) -> Bool {
        // Hybrid and path-dependent caches keep fp16 live KV by default until
        // a row proves TurboQuant for that exact topology. TurboQuant KV is
        // not a substitute for SSM/CCA/CSA/HSA/SWA companion-state restore.
        //
        // Step 3.7 mixes full-attention KV layers with rotating/SWA layers.
        // Current no-sign Osaurus warm rows prove disk L2 restore on that
        // topology, but not TurboQuant-KV decode stability after tool history,
        // so engine-selected defaults must leave Step live KV native/fp16.
        if ModelFamilyNames.isStepFamily(modelName) {
            return false
        }

        if ModelFamilyNames.isDSV4Family(modelName)
            || ModelFamilyNames.isZayaFamily(modelName)
            || ModelFamilyNames.isZayaVLFamily(modelName)
            || ModelFamilyNames.isGemmaFamily(modelName)
            || Self.isKnownHybridModel(name: modelName)
        {
            return false
        }
        if let cacheTopology {
            if cacheTopology.mambaLayerCount > 0
                || cacheTopology.arraysLayerCount > 0
                || cacheTopology.hybridPoolLayerCount > 0
                || cacheTopology.rotatingKVLayerCount > 0
                || cacheTopology.rotatingWrapperLayerCount > 0
            {
                return false
            }
            return cacheTopology.kvLayerCount > 0
        }
        return ModelFamilyNames.isMiniMaxFamily(modelName)
    }

    nonisolated static func cacheCoordinatorModelKey(
        modelName: String,
        kvModeTag: String,
        cacheTopology: ModelCacheTopologySnapshot? = nil
    ) -> String {
        var tags = [
            modelName,
            "kv=\(kvModeTag)",
            // vmlx `TQDiskSerializer.currentFormatVersion == 2` at the
            // pinned runtime. Keep this in the host key so older L2 records
            // cannot cross serializer generations after an app update.
            "cachefmt=2",
            // Restore semantics are part of the cache contract too. The
            // paired vmlx fix materializes full-hit trim mutations before
            // the one-token seed forward on the B=1 TokenIterator path.
            "restore=fullhit-trim-eval1",
        ]

        if let cacheTopology {
            tags.append("topology=real")
            tags.append(contentsOf: cacheTopology.topologyTags)
        }

        if ModelFamilyNames.isDSV4Family(modelName) {
            tags.append("layers=deepseekV4")
            tags.append("prefix=hybrid-pool-disk")
            tags.append("decode=max-rp110")
        } else if ModelFamilyNames.isZayaFamily(modelName) {
            tags.append("layers=zayaCCA")
            tags.append("prefix=path-dependent-disk")
        } else if Self.isKnownHybridModel(name: modelName) {
            tags.append("layers=hybrid-ssm")
        }

        if ModelFamilyNames.isNemotronOmniFamily(modelName) {
            tags.append("media=omni-audio-video")
        }

        return tags.joined(separator: "|")
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
    private func installCacheCoordinator(on holder: SessionHolder) async {
        let cacheTopology = await holder.container.cacheTopologySnapshot()
        holder.cacheTopology = cacheTopology
        let cacheConfig = Self.buildCacheCoordinatorConfig(
            modelName: holder.name,
            cacheTopology: cacheTopology
        )
        await holder.container.enableCachingAsync(config: cacheConfig)
        let topologyTags = cacheTopology.topologyTags.joined(separator: ",")

        genLog.info(
            "installCacheCoordinator: enabled for \(holder.name, privacy: .public) disk=\(cacheConfig.enableDiskCache, privacy: .public) hybrid=\(cacheTopology.requiresSSMCompanionState, privacy: .public) topology=\(topologyTags, privacy: .public) (sizing left to vmlx defaults)"
        )
    }

    /// Substring-match against the families whose per-layer cache lists
    /// vmlx's `newCache(parameters:)` populates with `MambaCache` /
    /// `ArraysCache` slots. Lower-cased model_id, so picker forms (without
    /// the org prefix) match too.
    ///
    /// The list intentionally tracks model_type _families_, not exact ids,
    /// so new bundles in the same architecture (e.g. another Holo3 / Qwen
    /// 3.x MoE quant tier) flip the flag without a registry edit.
    nonisolated static func isKnownHybridModel(name: String) -> Bool {
        let lower = name.lowercased()
        // Mamba+Attn+MoE — Nemotron-3 / Omni / Cascade-2 / Hyper. vmlx
        // `Models/NemotronH.swift` allocates `MambaCache` slots for the
        // Mamba layers and standard KV for the attention layers; the
        // `SSMStateCache` companion covers the Mamba state.
        if lower.contains("nemotron-3") || lower.contains("nemotron-cascade")
            || lower.contains("nemotron_h") || lower.contains("nemotron-omni")
            || lower.contains("nemotron_omni")
        {
            return true
        }
        // Qwen 3.5 / 3.6 MoE family (qwen3_5_moe model_type) covers Holo3 too.
        // vmlx `Models/Qwen35.swift` + `Qwen35JANGTQ.swift` allocate
        // `ArraysCache` for the linear-attention slots.
        if lower.contains("qwen3.5") || lower.contains("qwen3.6")
            || lower.contains("qwen3_5") || lower.contains("qwen3_6")
            || lower.contains("qwen35") || lower.contains("qwen36")
            || lower.contains("holo3") || lower.contains("holo-3")
        {
            return true
        }
        // Qwen3-Next (qwen3_next model_type) — newer hybrid MoE that vmlx
        // dispatches via `Qwen3Next.swift`. Same `ArraysCache` companion
        // pattern as the 3.5 / 3.6 family.
        if lower.contains("qwen3-next") || lower.contains("qwen3_next")
            || lower.contains("qwen3next")
        {
            return true
        }
        // Bailing / Ling hybrid: Linear-Attn companion ArraysCache + MLA
        // cache. Covers `bailing_hybrid`, `bailing_moe_v2_5`, and the
        // explicit Ling-2.6 Flash bundles via `isLingFamily`.
        if lower.contains("bailing") || ModelFamilyNames.isLingFamily(name) {
            return true
        }
        // Zyphra ZAYA1 CCA-attention hybrid: per-layer caches contain
        // `ZayaCCACache` (KV + path-dependent conv_state + prev_hs). vmlx's
        // `extractSSMStates` / `restoreSSMStates` round-trips the CCA state
        // through the `SSMStateCache` companion, so eager `setHybrid(true)`
        // mirrors the Mamba families above. vmlx's BatchEngine auto-flips
        // on first ZayaCCACache slot admission; this is the parity flip
        // for the single-slot `Evaluate` path.
        if ModelFamilyNames.isZayaFamily(name) {
            return true
        }
        // Granite-MoE-Hybrid (granitemoehybrid model_type) — IBM Granite
        // hybrid Mamba+Attn-MoE. vmlx `Models/GraniteMoeHybrid.swift`
        // allocates `MambaCache` for the SSM layers. Match the collapsed
        // model_type AND the conventional bundle-id form
        // (`granite-3.0-moe-hybrid-7b` etc.) by looking for "granite"
        // alongside "moe-hybrid" / "moe_hybrid" — the conjunction guards
        // against false positives like `moe-hybridge` lacking the family
        // prefix.
        if lower.contains("granitemoehybrid") {
            return true
        }
        if lower.contains("granite")
            && (lower.contains("moe-hybrid") || lower.contains("moe_hybrid"))
        {
            return true
        }
        // Falcon-H1 (falcon_h1 model_type) — TII hybrid Mamba+Attn. vmlx
        // `Models/FalconH1.swift`. Match dash, underscore, AND collapsed
        // forms; reject `falcon-h11` / `falcon_h10` etc. with the
        // boundary regex below.
        if lower.range(
            of: #"(^|/)falcon[\-_]?h1([\-_].*)?$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        // Baichuan-M1 (baichuan_m1 model_type) — Baichuan hybrid (linear +
        // sliding-window attention with Mamba mix). vmlx
        // `Models/BaichuanM1.swift`.
        if lower.range(
            of: #"(^|/)baichuan[\-_]?m1([\-_].*)?$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        // Jamba (jamba_3b model_type) — AI21 hybrid Mamba+Attn-MoE. vmlx
        // `Models/Jamba.swift` allocates `MambaCache` slots. Match
        // `jamba-`, `jamba_`, and dot/digit forms; reject `jamba` alone
        // with the boundary regex.
        if lower.range(
            of: #"(^|/)jamba[\-_\.0-9]"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        // LFM2 / LFM2.5 / LFM2-MoE (lfm2 / lfm2_moe model_types) —
        // Liquid Foundation Mamba hybrids. vmlx `Models/LFM2.swift` +
        // `LFM2MoE.swift`. Accept dot-versioned bundle ids such as
        // `LFM2.5-8B-A1B-JANG_2L` without opening the matcher to adjacent
        // sibling strings like `lfm21` or `lfm2x`.
        if lower.range(
            of: #"(^|/)lfm2(([\._-]?5)?([\-_].*)?)?$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        return false
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
        rawPromptBuilder: (@Sendable () -> String)? = nil,
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool]?,
        toolChoice: ToolChoiceOption?,
        modelId: String,
        modelName: String
    ) async throws -> AsyncThrowingStream<ModelRuntimeEvent, Error> {
        let trace = parameters.ttftTrace
        trace?.mark("runtime_start")

        // No serialization gate against `activeGenerationTask` here:
        // `ModelLease` is the authoritative "is anyone still using the model"
        // signal (per the field's own doc on line 82-87 — "tracks at most one
        // task even when many are active — the lease drains the rest"), and
        // the lease + container-load discipline already block model-swap
        // teardown. Awaiting the previous generation here serialized
        // same-model overlapping requests *before* `MLXBatchAdapter.generate`
        // could submit them to vmlx's `BatchEngine`, defeating the
        // continuous-batching path that osaurus advertises as a feature.
        // Removed 2026-05-07 (vmlx pin b9da180 also adds engine-side
        // `isShutdown` defense in depth, so a stale handle landing during
        // unload now returns a `.cancelled` info instead of restarting GPU
        // work).
        if Task.isCancelled { throw CancellationError() }

        genLog.info("generateEventStream: start model=\(modelName, privacy: .public)")
        await ModelResidencyManager.shared.markActive(modelName: modelName)

        // Scoped start/finish around ONLY a cold container load. Hot
        // resident turns still call `loadContainer` to get the holder, but
        // that is a cache hit and must not flash the UI back to
        // "Loading Model..." on every message.
        let cfg = await getConfig()
        trace?.mark("load_container_start")
        let shouldReportModelLoad = modelCache[modelName] == nil
        if shouldReportModelLoad {
            InferenceProgressManager.shared.modelLoadWillStartAsync()
        }
        let holder: SessionHolder
        do {
            holder = try await loadContainer(id: modelId, name: modelName)
        } catch {
            await ModelResidencyManager.shared.cancel(modelName: modelName)
            if shouldReportModelLoad {
                InferenceProgressManager.shared.modelLoadDidFinishAsync()
            }
            throw error
        }
        if shouldReportModelLoad {
            InferenceProgressManager.shared.modelLoadDidFinishAsync()
        }
        trace?.mark("load_container_done")

        if Task.isCancelled {
            await ModelResidencyManager.shared.cancel(modelName: modelName)
            if shouldReportModelLoad {
                await unload(name: modelName)
            } else {
                await scheduleIdleResidency(for: modelName)
            }
            throw CancellationError()
        }

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
                buildRawPrompt: rawPromptBuilder,
                generation: parameters,
                toolChoice: toolChoice,
                stopSequences: stopSequences,
                draftStrategy: holder.draftStrategy,
                runtime: cfg,
                maxBatchSize: InferenceFeatureFlags.mlxBatchEngineMaxBatchSize
            )
        } catch {
            InferenceProgressManager.shared.prefillDidFinishAsync()
            await ModelLease.shared.release(modelName)
            await scheduleIdleResidency(for: modelName)
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
        let genID = allocateGenerationTaskID()
        let activeTask = Task<Void, Never> {
            await withTaskCancellationHandler {
                await innerProducer.value
            } onCancel: {
                innerProducer.cancel()
            }
            await ModelLease.shared.release(modelName)
            await self.scheduleIdleResidency(for: modelName)
            self.clearGenerationTask(id: genID)
        }
        activeGenerationTasks[genID] = ActiveGenerationRecord(modelName: modelName, task: activeTask)

        return GenerationEventMapper.map(events: prepared.stream, modelName: modelName, trace: trace)
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
        let forcedToolMessages = ModelRuntime.applyForcedToolChoiceDirective(
            messages,
            toolChoice: toolChoice
        )
        let augmented = ModelRuntime.applyJSONMode(forcedToolMessages, jsonMode: parameters.jsonMode)
        let events = try await generateEventStream(
            chatBuilder: {
                ModelRuntime.mapOpenAIChatToMLX(
                    augmented,
                    trace: parameters.ttftTrace,
                    preserveStructuredToolHistory: !tools.isEmpty
                )
            },
            parameters: parameters,
            stopSequences: stopSequences,
            tools: tools,
            toolChoice: toolChoice,
            modelId: modelId,
            modelName: modelName
        )
        // Drain the entire stream so multiple tool invocations parsed by
        // vmlx-swift in a single completion are surfaced together
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

    /// Stream a completion from a raw, pre-formatted prompt — no chat template,
    /// no tools, no reasoning channel. Backs the OpenAI-legacy
    /// `/v1/completions` endpoint (FIM autocomplete), where the prompt must
    /// reach the model verbatim. Yields plain text deltas only.
    func streamRawText(
        prompt: String,
        parameters: GenerationParameters,
        stopSequences: [String],
        modelId: String,
        modelName: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        let events = try await generateEventStream(
            chatBuilder: { [] },
            rawPromptBuilder: { prompt },
            parameters: parameters,
            stopSequences: stopSequences,
            tools: nil,
            toolChoice: nil,
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
                    // Raw completions only surface generated text. Reasoning,
                    // tool calls, and stats events are irrelevant to the
                    // legacy completions wire format and are dropped.
                    if case .tokens(let s) = ev, !s.isEmpty {
                        continuation.yield(s)
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

    func streamWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        modelId: String,
        modelName: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        let forcedToolMessages = ModelRuntime.applyForcedToolChoiceDirective(
            messages,
            toolChoice: toolChoice
        )
        let augmented = ModelRuntime.applyJSONMode(forcedToolMessages, jsonMode: parameters.jsonMode)
        let events = try await generateEventStream(
            chatBuilder: {
                ModelRuntime.mapOpenAIChatToMLX(
                    augmented,
                    trace: parameters.ttftTrace,
                    preserveStructuredToolHistory: !tools.isEmpty
                )
            },
            parameters: parameters,
            stopSequences: stopSequences,
            tools: tools,
            toolChoice: toolChoice,
            modelId: modelId,
            modelName: modelName
        )
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let producerTask = Task {
            // Chat UI streaming should execute a parsed tool call immediately.
            // Continuing to drain model text after the tool event can leak the
            // model's pseudo-tool prose before the app renders/runs the tool.
            do {
                for try await ev in events {
                    if case .completionInfo(
                        let tokenCount,
                        let tokensPerSecond,
                        let unclosedReasoning,
                        let stopReason
                    ) = ev {
                        continuation.yield(
                            StreamingStatsHint.encode(
                                tokenCount: tokenCount,
                                tokensPerSecond: tokensPerSecond,
                                unclosedReasoning: unclosedReasoning,
                                stopReason: stopReason
                            )
                        )
                        continue
                    }

                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    switch ev {
                    case .tokens(let s):
                        if !s.isEmpty { continuation.yield(s) }
                    case .reasoning(let s):
                        if !s.isEmpty { continuation.yield(StreamingReasoningHint.encode(s)) }
                    case .toolInvocation(let name, let argsJSON):
                        continuation.yield(StreamingToolHint.encode(name))
                        continuation.yield(StreamingToolHint.encodeArgs(argsJSON))
                        continuation.finish(
                            throwing: ServiceToolInvocation(
                                toolName: name,
                                jsonArguments: argsJSON
                            )
                        )
                        return
                    case .completionInfo:
                        continue
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

    /// Computes a deterministic legacy hash from system content and tool names.
    /// Used by the HTTP API to expose a prefix_hash field in responses.
    public nonisolated static func computePrefixHash(
        systemContent: String,
        toolNames: [String]
    ) -> String {
        PromptPrefixHasher.hash(systemContent: systemContent, toolNames: toolNames)
    }

    /// Computes a deterministic hash from system content and the exact
    /// canonical tool payloads handed to the tokenizer/chat template.
    nonisolated static func computePrefixHash(
        systemContent: String,
        tools: [Tool]
    ) -> String {
        PromptPrefixHasher.hash(systemContent: systemContent, tools: tools)
    }

    /// Build the `GenerateParameters` value handed to `BatchEngine.generate`.
    ///
    /// We deliberately do NOT pass `maxKVSize`. Cache sizing is owned by
    /// vmlx-swift's `CacheCoordinator` and by each model's own
    /// architecture (sliding-window attention layers carry a fixed per-layer
    /// cache window — Gemma-4's is 1024). Forcing a global rotating window
    /// from the app layer here historically caused
    /// `[broadcast_shapes] (1,1,1,N) and (1,16,1,1024)` crashes on the
    /// first decode step. Per OSAURUS-INTEGRATION.md, the only inputs the
    /// engine wants from us are temperature / topP / topK / minP / maxTokens /
    /// penalties / stop sequences. `stopSequences` becomes `extraStopStrings` — the
    /// library matches against the post-reasoning, post-tool-call `.chunk`
    /// stream and halts with `.info(stopReason: .stop)` on a hit.
    nonisolated static func makeGenerateParameters(
        temperature: Float,
        maxTokens: Int,
        topP: Float,
        topK: Int = 0,
        minP: Float = 0,
        repetitionPenalty: Float?,
        stopSequences: [String] = [],
        draftStrategy: MLXLMCommon.DraftStrategy? = nil,
        enableCompiledBatchDecode: Bool = true,
        prefillStepSize: Int? = nil
    ) -> MLXLMCommon.GenerateParameters {
        var params = MLXLMCommon.GenerateParameters(
            maxTokens: maxTokens,
            enableCompiledBatchDecode: enableCompiledBatchDecode,
            temperature: temperature,
            topP: topP,
            topK: topK,
            minP: minP,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: 20,
            extraStopStrings: stopSequences
        )
        params.draftStrategy = draftStrategy
        if let prefillStepSize, prefillStepSize > 0 {
            params.prefillStepSize = prefillStepSize
        }
        return params
    }

    private nonisolated static func resolveNativeMTPLaunchPlan(
        modelDirectory: URL,
        settings: VMLXServerRuntimeSettings
    ) -> NativeMTPLaunchPlan {
        let configData = try? Data(contentsOf: modelDirectory.appendingPathComponent("config.json"))
        let jangConfig = try? JangLoader.loadConfig(at: modelDirectory)
        let status: MTPBundleStatus?
        do {
            status = try MTPBundleInspector.inspect(
                modelDirectory: modelDirectory,
                jangConfig: jangConfig
            )
        } catch {
            genLog.error(
                "native MTP inspection failed for \(modelDirectory.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return NativeMTPLaunchPlan(
                loadConfiguration: .default,
                draftStrategy: nil,
                statusLine: nil,
                reason: "MTP inspection failed; using autoregressive load."
            )
        }

        let launch = settings.resolvedMTPLaunch(
            configData: configData,
            jangConfig: jangConfig,
            status: status
        )
        let loadConfiguration = settings.resolvedLoadConfiguration(
            base: .default,
            configData: configData,
            jangConfig: jangConfig,
            status: status
        )
        let draftStrategy = settings.resolvedMTPDraftStrategy(
            configData: configData,
            jangConfig: jangConfig,
            status: status
        )

        return NativeMTPLaunchPlan(
            loadConfiguration: loadConfiguration,
            draftStrategy: draftStrategy,
            statusLine: status?.statusLine,
            reason: launch.reason
        )
    }

    private nonisolated static func describeDraftStrategy(
        _ strategy: MLXLMCommon.DraftStrategy?
    ) -> String {
        switch strategy {
        case nil:
            return "none"
        case .some(.none):
            return "none"
        case .some(.nativeMTP(depth: let depth, verifierMode: _)):
            return "native_mtp:d\(depth)"
        case .some(let strategy):
            return strategy.kindName
        }
    }

    private nonisolated static func nativeMTPDepth(
        _ strategy: MLXLMCommon.DraftStrategy?
    ) -> Int? {
        switch strategy {
        case .some(.nativeMTP(depth: let depth, verifierMode: _)):
            return depth
        default:
            return nil
        }
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
            case .auto, .required:
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

    nonisolated static func applyForcedToolChoiceDirective(
        _ messages: [ChatMessage],
        toolChoice: ToolChoiceOption?
    ) -> [ChatMessage] {
        // Named `tool_choice` is enforced by `makeTokenizerTools`: the
        // tokenizer sees only the requested function's schema. Do not add a
        // generic system directive here. Some model-family templates,
        // including DSV4 DSML, treat that out-of-template prose as ordinary
        // instruction text and can respond with an empty visible answer
        // instead of the selected protocol block.
        messages
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
        _ msgs: [ChatMessage],
        trace: TTFTTrace? = nil,
        preserveStructuredToolHistory: Bool = true
    ) -> [MLXLMCommon.Chat.Message] {
        var out: [MLXLMCommon.Chat.Message] = []
        out.reserveCapacity(max(6, msgs.count))
        var audioMetrics = AudioMaterializationMetrics()
        for m in msgs {
            let images = extractImageSources(from: m)
            let videos = extractVideoSources(from: m)
            let audios = extractAudioSources(from: m, metrics: &audioMetrics)
            switch m.role {
            case "system":
                out.append(
                    MLXLMCommon.Chat.Message(
                        role: .system,
                        content: m.content ?? "",
                        images: images,
                        videos: videos,
                        audios: audios
                    )
                )
            case "user":
                out.append(
                    MLXLMCommon.Chat.Message(
                        role: .user,
                        content: m.content ?? "",
                        images: images,
                        videos: videos,
                        audios: audios
                    )
                )
            case "assistant":
                let content = (m.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let reasoningContent = m.reasoning_content?.trimmingCharacters(in: .whitespacesAndNewlines)
                let toolCalls = preserveStructuredToolHistory ? toMLXToolCalls(m.tool_calls) : nil
                // Skip fully-empty assistant turns. Reasoning-only assistant
                // turns are NOT empty for local MLX templates: ZAYA,
                // Nemotron-H/Omni, MiniMax and DSV4 read
                // `message.reasoning_content` to reconstruct prior
                // `<think>...</think>` history on follow-ups.
                if content.isEmpty
                    && (reasoningContent?.isEmpty ?? true)
                    && (toolCalls?.isEmpty ?? true)
                {
                    continue
                }
                out.append(
                    MLXLMCommon.Chat.Message(
                        role: .assistant,
                        content: content,
                        images: images,
                        videos: videos,
                        audios: audios,
                        reasoningContent: reasoningContent,
                        toolCalls: toolCalls,
                        toolCallId: nil
                    )
                )
            case "tool":
                if preserveStructuredToolHistory {
                    out.append(
                        MLXLMCommon.Chat.Message(
                            role: .tool,
                            content: m.content ?? "",
                            images: images,
                            videos: videos,
                            audios: audios,
                            toolCalls: nil,
                            toolCallId: m.tool_call_id
                        )
                    )
                } else if let content = m.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(
                        MLXLMCommon.Chat.Message(
                            role: .user,
                            content: "Tool result: \(content)",
                            images: images,
                            videos: videos,
                            audios: audios
                        )
                    )
                }
            default:
                out.append(
                    MLXLMCommon.Chat.Message(
                        role: .user,
                        content: m.content ?? "",
                        images: images,
                        videos: videos,
                        audios: audios
                    )
                )
            }
        }
        if audioMetrics.inputCount > 0 {
            trace?.set("input_audio_count", audioMetrics.inputCount)
            trace?.set("input_audio_materialized_count", audioMetrics.materializedCount)
            trace?.set("input_audio_local_sample_count", audioMetrics.localSampleCount)
            trace?.set("input_audio_local_preencoded_count", audioMetrics.localPreencodedCount)
            trace?.set("input_audio_bytes", audioMetrics.byteCount)
            trace?.set("input_audio_materialize_ms", audioMetrics.materializeMs)
            trace?.mark("input_audio_materialize_done")
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
                id: tc.id,
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

    /// Extract `[UserInput.Video]` from `video_url` content parts. Mirrors
    /// `extractImageSources` — `data:` URLs are written to a temp file so
    /// AVAsset can decode them; `http(s):` URLs go through directly. The
    /// vmlx side (`NemotronHOmniProcessor.prepare()`) extracts frames via
    /// `nemotronOmniExtractVideoFrames` regardless of source shape.
    nonisolated private static func extractVideoSources(
        from message: ChatMessage
    ) -> [MLXLMCommon.UserInput.Video] {
        let urls = message.videoUrls
        guard !urls.isEmpty else { return [] }

        var sources: [MLXLMCommon.UserInput.Video] = []
        for urlString in urls {
            if urlString.hasPrefix("data:video/") {
                // data:video/<container>;base64,<bytes>
                if let url = materializeMediaDataUrl(urlString, defaultExtension: "mp4") {
                    sources.append(.url(url))
                }
            } else if let url = URL(string: urlString) {
                sources.append(.url(url))
            }
        }
        return sources
    }

    /// Extract `[UserInput.Audio]` from `input_audio` content parts. The
    /// OpenAI wire shape is `{data: <base64>, format: "wav"|"mp3"|...}`. Valid
    /// WAV payloads decode directly to PCM samples so the Nemotron Omni adapter
    /// can pre-encode without a temp-file re-decode. Other supported containers
    /// still materialize to a temp file and let vmlx's AVAudioConverter path
    /// handle codec-specific decoding. Live in-app voice may also carry local
    /// PCM samples aligned to the same audio part, in which case we hand those
    /// samples directly to vmlx and keep the encoded bytes only as the portable
    /// history/fallback representation.
    private struct AudioMaterializationMetrics {
        var inputCount = 0
        var localSampleCount = 0
        var localPreencodedCount = 0
        var materializedCount = 0
        var byteCount = 0
        var materializeMs = 0
    }

    nonisolated private static func extractAudioSources(
        from message: ChatMessage,
        metrics: inout AudioMaterializationMetrics
    ) -> [MLXLMCommon.UserInput.Audio] {
        let inputs = message.audioInputsWithLocalSamples
        guard !inputs.isEmpty else { return [] }

        var sources: [MLXLMCommon.UserInput.Audio] = []
        let startedAt = CFAbsoluteTimeGetCurrent()
        metrics.inputCount += inputs.count
        for (data, format, localSamples) in inputs {
            if let localSamples {
                if let attachmentId = localSamples.preencodedAttachmentId,
                    let preencoded = LiveVoiceAudioInputRegistry.shared.freshPreencodedAudio(
                        for: attachmentId,
                        sourceSampleCount: localSamples.samples.count,
                        sampleRate: localSamples.sampleRate
                    )
                {
                    metrics.localPreencodedCount += 1
                    sources.append(preencoded)
                    continue
                }

                metrics.localSampleCount += 1
                sources.append(.samples(localSamples.samples, sampleRate: localSamples.sampleRate))
                continue
            }

            if let bytes = Data(base64Encoded: data),
                let decoded = decodeWAVAudioSamples(bytes)
            {
                metrics.localSampleCount += 1
                metrics.byteCount += decoded.byteCount
                sources.append(.samples(decoded.samples, sampleRate: decoded.sampleRate))
                continue
            }

            let ext = format.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            let fallbackExtension = ext.isEmpty ? "wav" : ext
            // Synthesize a `data:audio/<format>;base64,<data>` URL so we can
            // reuse the same materializer the video path uses. The audio data
            // comes in as a bare base64 string from `input_audio.data`, not a
            // data URL — wrap it before handing off so the helper's data-URL
            // parsing applies uniformly.
            let dataUrl = "data:audio/\(fallbackExtension);base64,\(data)"
            if let file = materializeMediaDataUrlResult(dataUrl, defaultExtension: fallbackExtension) {
                metrics.materializedCount += 1
                metrics.byteCount += file.byteCount
                sources.append(.url(file.url))
            }
        }
        metrics.materializeMs += Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        return sources
    }

    private struct DecodedAudioSamples {
        let samples: [Float]
        let sampleRate: Int
        let byteCount: Int
    }

    nonisolated private static func decodeWAVAudioSamples(_ bytes: Data) -> DecodedAudioSamples? {
        guard bytes.count >= 44 else { return nil }
        guard ascii(bytes, offset: 0, count: 4) == "RIFF",
            ascii(bytes, offset: 8, count: 4) == "WAVE"
        else { return nil }

        var offset = 12
        var audioFormat: UInt16?
        var channelCount: UInt16?
        var sampleRate: Int?
        var blockAlign: UInt16?
        var bitsPerSample: UInt16?
        var dataRange: Range<Int>?

        while offset + 8 <= bytes.count {
            guard let chunkId = ascii(bytes, offset: offset, count: 4),
                let chunkSize = readUInt32LE(bytes, offset: offset + 4)
            else { return nil }

            let chunkStart = offset + 8
            let chunkEnd = chunkStart + Int(chunkSize)
            guard chunkEnd <= bytes.count else { return nil }

            switch chunkId {
            case "fmt ":
                guard chunkSize >= 16,
                    let format = readUInt16LE(bytes, offset: chunkStart),
                    let channels = readUInt16LE(bytes, offset: chunkStart + 2),
                    let rate = readUInt32LE(bytes, offset: chunkStart + 4),
                    let align = readUInt16LE(bytes, offset: chunkStart + 12),
                    let bits = readUInt16LE(bytes, offset: chunkStart + 14)
                else { return nil }
                audioFormat = format
                if format == 0xFFFE, chunkSize >= 40,
                    let subformat = readUInt16LE(bytes, offset: chunkStart + 24)
                {
                    audioFormat = subformat
                }
                channelCount = channels
                sampleRate = Int(rate)
                blockAlign = align
                bitsPerSample = bits

            case "data":
                dataRange = chunkStart ..< chunkEnd

            default:
                break
            }

            offset = chunkEnd + (Int(chunkSize) & 1)
        }

        guard let format = audioFormat,
            let channels = channelCount,
            let rate = sampleRate,
            let align = blockAlign,
            let bits = bitsPerSample,
            let range = dataRange,
            channels > 0,
            rate > 0,
            align > 0
        else { return nil }

        let channelTotal = Int(channels)
        let bytesPerSample = Int(bits / 8)
        guard bytesPerSample > 0, Int(align) >= channelTotal * bytesPerSample else { return nil }
        guard format == 1 || format == 3 else { return nil }
        if format == 3 {
            guard bits == 32 else { return nil }
        } else {
            guard bits == 8 || bits == 16 || bits == 24 || bits == 32 else { return nil }
        }

        let frameStride = Int(align)
        let frameCount = range.count / frameStride
        guard frameCount > 0 else { return nil }

        var samples: [Float] = []
        samples.reserveCapacity(frameCount)
        for frame in 0 ..< frameCount {
            let frameOffset = range.lowerBound + frame * frameStride
            var mixed = Float(0)
            for channel in 0 ..< channelTotal {
                let sampleOffset = frameOffset + channel * bytesPerSample
                guard let sample = decodeWAVSample(bytes, offset: sampleOffset, format: format, bits: bits)
                else { return nil }
                mixed += sample
            }
            samples.append(mixed / Float(channelTotal))
        }

        return DecodedAudioSamples(samples: samples, sampleRate: rate, byteCount: bytes.count)
    }

    nonisolated private static func decodeWAVSample(
        _ bytes: Data,
        offset: Int,
        format: UInt16,
        bits: UInt16
    ) -> Float? {
        switch (format, bits) {
        case (1, 8):
            guard offset < bytes.count else { return nil }
            return max(-1, min(1, (Float(bytes[offset]) - 128.0) / 127.0))
        case (1, 16):
            guard let raw = readUInt16LE(bytes, offset: offset) else { return nil }
            return max(-1, min(1, Float(Int16(bitPattern: raw)) / Float(Int16.max)))
        case (1, 24):
            guard let raw = readInt24LE(bytes, offset: offset) else { return nil }
            return max(-1, min(1, Float(raw) / 8_388_607.0))
        case (1, 32):
            guard let raw = readUInt32LE(bytes, offset: offset) else { return nil }
            return max(-1, min(1, Float(Int32(bitPattern: raw)) / Float(Int32.max)))
        case (3, 32):
            guard let raw = readUInt32LE(bytes, offset: offset) else { return nil }
            return Float(bitPattern: raw)
        default:
            return nil
        }
    }

    nonisolated private static func ascii(_ bytes: Data, offset: Int, count: Int) -> String? {
        guard offset >= 0, count >= 0, offset + count <= bytes.count else { return nil }
        return String(data: bytes[offset ..< offset + count], encoding: .ascii)
    }

    nonisolated private static func readUInt16LE(_ bytes: Data, offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    nonisolated private static func readUInt32LE(_ bytes: Data, offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    nonisolated private static func readInt24LE(_ bytes: Data, offset: Int) -> Int32? {
        guard offset >= 0, offset + 3 <= bytes.count else { return nil }
        var raw =
            Int32(bytes[offset])
            | (Int32(bytes[offset + 1]) << 8)
            | (Int32(bytes[offset + 2]) << 16)
        if (raw & 0x0080_0000) != 0 {
            raw |= ~0x00FF_FFFF
        }
        return raw
    }

    /// Decode a `data:<mediatype>;base64,<bytes>` URL into a temp file URL with
    /// an extension reflecting the mediatype. Returns `nil` on parse / decode
    /// failure.
    ///
    /// Lifecycle: temp files live in `FileManager.default.temporaryDirectory`
    /// and are not actively cleaned up here. macOS evicts the system temp dir
    /// on its own schedule (`/private/var/folders/.../T/` rotates per session
    /// and on reboot). Per-request cleanup would require threading a teardown
    /// hook through the generation lifecycle, which is more complexity than
    /// it's worth for what amounts to short-lived audio/video bytes.
    nonisolated private static func materializeMediaDataUrl(
        _ urlString: String,
        defaultExtension: String
    ) -> URL? {
        materializeMediaDataUrlResult(urlString, defaultExtension: defaultExtension)?.url
    }

    private struct MaterializedMediaFile {
        let url: URL
        let byteCount: Int
    }

    nonisolated private static func materializeMediaDataUrlResult(
        _ urlString: String,
        defaultExtension: String
    ) -> MaterializedMediaFile? {
        // Expect `data:<mediatype>[;base64],<payload>`. Pull the mediatype
        // subtype as the file extension when available so AVFoundation /
        // AVAudioConverter's extension-keyed dispatch picks the right decoder.
        guard urlString.hasPrefix("data:") else { return nil }
        guard let commaIndex = urlString.firstIndex(of: ",") else { return nil }
        let header = String(urlString[urlString.index(urlString.startIndex, offsetBy: 5) ..< commaIndex])
        let payload = String(urlString[urlString.index(after: commaIndex)...])
        guard let bytes = Data(base64Encoded: payload) else { return nil }

        // Header looks like `audio/wav;base64` or `video/mp4`. Take the part
        // after the slash, before any `;`.
        var ext = defaultExtension
        let isAudioMime = header.lowercased().hasPrefix("audio/")
        if let slash = header.firstIndex(of: "/") {
            let afterSlash = header[header.index(after: slash)...]
            if let semi = afterSlash.firstIndex(of: ";") {
                ext = String(afterSlash[..<semi]).lowercased()
            } else {
                ext = String(afterSlash).lowercased()
            }
            // Coerce audio mediatypes to the canonical extensions vmlx's
            // AVAudioConverter recognizes. Guarded on `audio/` mime so a
            // `data:video/mp4` URL keeps `.mp4` and isn't downgraded to the
            // audio-only `.m4a` extension that the previous unconditional
            // table produced.
            if isAudioMime {
                switch ext {
                case "x-wav", "wave": ext = "wav"
                case "mpeg", "mp3", "x-mpeg": ext = "mp3"
                case "x-m4a", "mp4": ext = "m4a"
                default: break
                }
            }
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        do {
            try bytes.write(to: tmp, options: .atomic)
            return MaterializedMediaFile(url: tmp, byteCount: bytes.count)
        } catch {
            return nil
        }
    }

    private static func computeWeightsSizeBytes(at url: URL) -> Int64 {
        let fm = FileManager.default
        let fileURLs: [URL]
        if let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            fileURLs = entries
        } else {
            return 0
        }
        var total: Int64 = 0
        for fileURL in fileURLs {
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

    /// Verify every weight shard referenced by a `*.safetensors.index.json`
    /// manifest is present on disk before load. Sharded bundles list each
    /// tensor's owning file in the manifest's `weight_map`; if any referenced
    /// shard is missing, vmlx aborts the process on the first forward pass.
    /// Single-file bundles (no manifest) are a no-op here — the one-file
    /// `isDownloaded` check already covers them.
    static func verifyShardManifest(at directory: URL, name: String) throws {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else { return }

        let indexFiles = entries.filter {
            $0.lastPathComponent.hasSuffix(".safetensors.index.json")
        }
        // No manifest → not a sharded bundle; nothing to cross-check.
        guard let indexURL = indexFiles.first else { return }

        guard
            let data = try? Data(contentsOf: indexURL),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let weightMap = obj["weight_map"] as? [String: String]
        else {
            throw NSError(
                domain: "ModelRuntime",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Model \(name) has an unreadable shard manifest (\(indexURL.lastPathComponent)). Re-download to repair."
                ]
            )
        }

        let referencedShards = Set(weightMap.values)
        let missing = referencedShards.sorted().filter {
            !fm.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        guard missing.isEmpty else {
            let sample = missing.prefix(3).joined(separator: ", ")
            throw NSError(
                domain: "ModelRuntime",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Model \(name) is incomplete: \(missing.count) of \(referencedShards.count) weight shard(s) missing (e.g. \(sample)). Re-download to repair."
                ]
            )
        }
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
    ///    `vmlx-swift 9e647a6` vmlx fails-fast with an NSError at load
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

        // Read only routing stamps; ignore all other fields so format drift
        // (new fields, missing optionals) doesn't break the preflight.
        struct JangConfigProbe: Decodable {
            let weight_format: String?
            let format: String?
        }
        guard let data = try? Data(contentsOf: jangConfigURL),
            let probe = try? JSONDecoder().decode(JangConfigProbe.self, from: data)
        else {
            return
        }

        let sidecarURL = directory.appendingPathComponent("jangtq_runtime.safetensors")
        let sidecarPresent = FileManager.default.fileExists(atPath: sidecarURL.path)
        // Normalize stamp comparison: pipelines/users have shipped `MXTQ`,
        // ` mxtq `, and `Mxtq` in jang_config.json over time. We treat all
        // of those as the same canonical declaration so the JANGTQ family
        // (Qwen / MiniMax / DSV4 / Nemotron / Mistral 3 / Laguna / etc.)
        // never silently slips past the preflight just because of casing.
        let normalizedStamp = (probe.weight_format ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isMxtq = normalizedStamp == "mxtq"
        let normalizedFormat = (probe.format ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let declaresJANGTQFormat = normalizedFormat == "jangtq"

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
        if sidecarPresent && !isMxtq && !declaresJANGTQFormat {
            let actualStamp = (probe.weight_format?.isEmpty == false) ? probe.weight_format! : "absent"
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

    /// Blocks the known-bad plain affine DeepSeek V4 Flash JANG bundle before
    /// vmlx starts loading hundreds of GB of shards. The production DSV4 path
    /// is JANGTQ (`weight_format == "mxtq"` + `jangtq_runtime.safetensors`),
    /// which dispatches to TurboQuantSwitchGLU. Plain affine DSV4 JANG falls
    /// through to the generic SwitchGLU route; current engine evidence shows
    /// unusable decode speed and high memory pressure, not a shippable row.
    ///
    /// Engine developers can still opt in for diagnostics with
    /// `OSAURUS_ALLOW_EXPERIMENTAL_DSV4_AFFINE_JANG=1` or
    /// `VMLINUX_ALLOW_EXPERIMENTAL_DSV4_AFFINE_JANG=1`.
    static func validateUnsupportedPlainDSV4AffineJANG(at directory: URL, name: String) throws {
        guard !Self.experimentalDSV4AffineJANGAllowed else { return }

        let fm = FileManager.default
        let jangConfigURL = directory.appendingPathComponent("jang_config.json")
        let configURL = directory.appendingPathComponent("config.json")
        guard fm.fileExists(atPath: jangConfigURL.path),
            fm.fileExists(atPath: configURL.path)
        else { return }

        let sidecarURL = directory.appendingPathComponent("jangtq_runtime.safetensors")
        guard !fm.fileExists(atPath: sidecarURL.path) else { return }

        let jang = Self.readJSONObject(at: jangConfigURL)
        let config = Self.readJSONObject(at: configURL)
        let modelType = Self.stringValue(config["model_type"])?.lowercased()
        guard modelType == "deepseek_v4" else { return }

        let weightFormat = Self.stringValue(jang["weight_format"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let codec = ((jang["quantization"] as? [String: Any])?["routed_experts"] as? [String: Any])
            .flatMap { Self.stringValue($0["codec"]) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isAffine =
            weightFormat == nil
            || weightFormat == "affine"
            || weightFormat == "jang"
            || weightFormat == "jang_v2"
            || codec == "affine"

        let routedExperts =
            Self.intValue(config["n_routed_experts"])
            ?? Self.intValue(config["num_experts"])
            ?? Self.intValue(config["num_routed_experts"])

        guard isAffine, (routedExperts ?? 0) >= 128 else { return }

        throw NSError(
            domain: "ModelRuntime",
            code: 5,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Model '\(name)' is a plain affine DeepSeek V4 Flash JANG bundle. "
                    + "That path is not production-supported in this Osaurus build because "
                    + "it loads through the generic SwitchGLU route and can consume very high "
                    + "memory while decoding at unusable speed. Use the JANGTQ2 or JANGTQ-K "
                    + "DeepSeek V4 Flash bundle instead. For engine diagnostics only, set "
                    + "OSAURUS_ALLOW_EXPERIMENTAL_DSV4_AFFINE_JANG=1."
            ]
        )
    }

    private static var experimentalDSV4AffineJANGAllowed: Bool {
        let env = ProcessInfo.processInfo.environment
        for key in [
            "OSAURUS_ALLOW_EXPERIMENTAL_DSV4_AFFINE_JANG",
            "VMLINUX_ALLOW_EXPERIMENTAL_DSV4_AFFINE_JANG",
        ] {
            guard let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                continue
            }
            if ["1", "true", "yes", "on"].contains(raw) {
                return true
            }
        }
        return false
    }

    private static func readJSONObject(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    /// Async wrapper around `validateJANGTQSidecarIfRequired` that, on a
    /// "missing sidecar but stamp says JANGTQ" failure (and ONLY that
    /// specific failure), tries once to download
    /// `jangtq_runtime.safetensors` from the model's Hugging Face repo and
    /// then re-runs the sync validator. Any other failure mode (inverse
    /// mismatch, malformed jang_config, etc.) propagates immediately
    /// untouched — the auto-fetch never speculatively fires.
    ///
    /// The remote URL is built dynamically from `modelId` using the same
    /// `<repo>/resolve/main/<path>` shape the rest of the download stack
    /// uses; a flat-layout id (no `/` in it) cannot be mapped back to an
    /// HF repo and skips the fetch entirely, surfacing the original error.
    static func ensureJANGTQSidecar(at directory: URL, modelId: String, name: String) async throws {
        if Self.isStepJANGTQName(modelId) || Self.isStepJANGTQName(name) {
            let sidecarURL = directory.appendingPathComponent("jangtq_runtime.safetensors")
            guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
                throw NSError(
                    domain: "ModelRuntime",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Model '\(name)' is a Step 3.7 JANGTQ bundle but is missing "
                            + "required sidecar file 'jangtq_runtime.safetensors'. "
                            + "Re-download the full model or obtain the sidecar from the original publisher."
                    ]
                )
            }
            return
        }

        do {
            try validateJANGTQSidecarIfRequired(at: directory, name: name)
            return
        } catch let error as NSError
            where error.domain == "ModelRuntime" && error.code == 2
        {
            // Forward mismatch: stamp says mxtq, sidecar missing. Try one HF fetch.
            // Build the candidate id list: canonical `<org>/<repo>` first,
            // then — for flat-layout local ids that aren't directly mappable
            // to a single HF repo — known JANGTQ publisher orgs as fallbacks.
            let candidates = jangtqHFRepoCandidates(for: modelId)
            guard !candidates.isEmpty else {
                throw error
            }

            let dest = directory.appendingPathComponent("jangtq_runtime.safetensors")

            var lastFetchError: Error?
            var lastTriedRepo: String?
            for repoId in candidates {
                guard
                    let url = ModelDownloadService.resolveURL(
                        repoId: repoId,
                        path: "jangtq_runtime.safetensors"
                    ),
                    let scheme = url.scheme, scheme == "https",
                    url.host == "huggingface.co"
                else { continue }

                lastTriedRepo = repoId
                do {
                    try await Self.fetchSidecar(from: url, to: dest)
                    // Confirm the freshly-downloaded file actually satisfies
                    // the check before declaring success — guards against a
                    // mirror that returns a stub.
                    try validateJANGTQSidecarIfRequired(at: directory, name: name)
                    return
                } catch {
                    lastFetchError = error
                    // Try next candidate.
                    continue
                }
            }

            // All candidates exhausted — surface the last error wrapped so the
            // UI can distinguish "we tried, none worked" from "we never tried".
            let triedList = candidates.joined(separator: ", ")
            let detail = lastFetchError.map { $0.localizedDescription } ?? "no candidate URL was reachable"
            throw NSError(
                domain: "ModelRuntime",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Model '\(name)' is missing 'jangtq_runtime.safetensors' "
                        + "and we could not auto-fetch it. Tried: \(triedList). "
                        + "Last error from huggingface.co/\(lastTriedRepo ?? "?"): \(detail). "
                        + "Re-download the full model or place the sidecar next "
                        + "to the safetensors manually."
                ]
            )
        }
    }

    private static func isStepJANGTQName(_ value: String) -> Bool {
        let normalized =
            value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        return normalized.contains("step-3.7")
            && normalized.contains("jangtq")
    }

    /// Build the ordered list of HF `<org>/<repo>` candidates to try when
    /// auto-fetching a sidecar. Strict gating up-front so we never hit the
    /// network on garbage, and case-tolerant so a lowercased model id
    /// (osaurus's chat router lowercases names internally) still resolves
    /// to the canonical-cased HF org.
    ///
    /// Resolution order:
    ///   1. If the supplied id is a valid `<org>/<repo>`, try it FIRST
    ///      verbatim — for users with a custom-cased org that genuinely
    ///      ships the sidecar at that exact path.
    ///   2. Always append canonical-cased fallbacks built from the
    ///      basename (the part after the last `/`, or the whole id for
    ///      flat-layout): `OsaurusAI/<basename>`, `JANGQ-AI/<basename>`,
    ///      `mlx-community/<basename>`. This recovers from both
    ///      case-mismatch (`jangq-ai/...` → `JANGQ-AI/...`) and
    ///      wrong-org-guess scenarios.
    ///   3. Each candidate is independently `isValidHFRepoId`-validated;
    ///      duplicates are pruned in order so the canonical id never
    ///      gets retried via a fallback.
    ///   4. Empty / malformed input → empty list, no fetch.
    static func jangtqHFRepoCandidates(for modelId: String) -> [String] {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var ordered: [String] = []
        var seen: Set<String> = []
        func add(_ s: String) {
            guard isValidHFRepoId(s), !seen.contains(s) else { return }
            seen.insert(s)
            ordered.append(s)
        }

        // Determine the basename — only TRUSTED for two shapes:
        //   1. Valid `<org>/<repo>` (basename = repo)
        //   2. Flat (no slash anywhere; basename = full id)
        // Any other shape (multi-slash, leading slash, etc.) is untrusted
        // and produces zero candidates so we never speculatively hit the
        // network with garbage.
        let basename: String?
        if isValidHFRepoId(trimmed) {
            // Verbatim canonical id is tried FIRST.
            add(trimmed)
            basename = trimmed.split(separator: "/").last.map(String.init)
        } else if !trimmed.contains("/") {
            // Pure flat layout — id IS the basename.
            basename = trimmed
        } else {
            return []  // Malformed (multi-slash, leading/trailing slash, …).
        }

        // Canonical-cased org fallbacks. OsaurusAI is the curated
        // publisher and ships the most user-facing JANGTQ + MXFP4
        // bundles, so it goes FIRST. JANGQ-AI is the user's primary
        // JANGTQ research org. mlx-community covers community quants.
        guard let base = basename, !base.isEmpty else { return ordered }
        let knownJANGTQOrgs = ["OsaurusAI", "JANGQ-AI", "mlx-community"]
        for org in knownJANGTQOrgs {
            add("\(org)/\(base)")
        }
        return ordered
    }

    /// Streams `url` into `dest` using an atomic temp-file → rename so a
    /// crashed/cancelled download never leaves a partial sidecar in place
    /// (which the next preflight would then misread as "present, fine").
    /// Overridable via `sidecarFetcherForTests` so unit tests don't have
    /// to hit the real network.
    static func fetchSidecar(from url: URL, to dest: URL) async throws {
        if let injected = $sidecarFetcherForTests.wrappedValue {
            try await injected(url, dest)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (tempURL, response) = try await GlobalProxySettings.sharedSession().download(for: request)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(
                domain: "ModelRuntime",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(code) fetching sidecar"]
            )
        }

        // Sanity: a real safetensors sidecar will be far larger than a stray
        // 404 HTML page that somehow returned 200. Reject zero-byte writes.
        let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        let size = (attrs[.size] as? Int64) ?? 0
        guard size > 0 else {
            throw NSError(
                domain: "ModelRuntime",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Sidecar fetch returned 0 bytes"]
            )
        }

        // Cross-volume safe + race tolerant install of the temp file:
        //   - moveItem fails with EXDEV when temp + dest are on different
        //     volumes (system temp vs an external drive like /Volumes/...).
        //     Fall back to copy + delete.
        //   - If a concurrent caller raced us and already wrote the dest
        //     between our removeItem and move/copy, treat that as a win and
        //     drop our copy on the floor — the post-fetch validator will
        //     accept whichever sidecar is on disk.
        let fm = FileManager.default
        let tmpDest = dest.deletingLastPathComponent()
            .appendingPathComponent(".jangtq_runtime.\(UUID().uuidString).part")

        do {
            try fm.copyItem(at: tempURL, to: tmpDest)
        } catch {
            // copy failed (permissions, disk full, etc.) — try a direct rename
            // as a last resort; if that ALSO fails, surface the error.
            try fm.moveItem(at: tempURL, to: tmpDest)
        }

        defer { try? fm.removeItem(at: tmpDest) }

        // Atomic in-volume rename. If the dest already exists (concurrent
        // fetch won), `replaceItem` swaps without error. Use replaceItemAt
        // because it handles "dest already exists" cleanly and stays atomic.
        if fm.fileExists(atPath: dest.path) {
            // Another writer beat us. Keep theirs.
            return
        }
        do {
            _ = try fm.replaceItemAt(dest, withItemAt: tmpDest)
        } catch {
            // Last-chance race recovery: if dest now exists, accept it.
            if fm.fileExists(atPath: dest.path) {
                return
            }
            throw error
        }
    }

    /// True iff `id` looks like a real Hugging Face `<org>/<repo>` path —
    /// strict enough that we never fire the auto-fetch on garbage input.
    /// Allowed chars match HF's repo-name rules: ASCII letters, digits,
    /// `-`, `_`, `.`. Each segment must be 1..96 chars; exactly one `/`
    /// separator; no leading / trailing slash; no whitespace anywhere.
    static func isValidHFRepoId(_ id: String) -> Bool {
        guard !id.isEmpty,
            !id.hasPrefix("/"),
            !id.hasSuffix("/")
        else { return false }
        let segments = id.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 2 else { return false }
        let allowed = CharacterSet(
            charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
        )
        for seg in segments {
            let s = String(seg)
            guard !s.isEmpty, s.count <= 96 else { return false }
            guard s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
            // Block `.` and `..` segments outright — they're individually
            // composed of allowed chars but represent path-traversal-style
            // paths that HF refuses anyway.
            guard s != "." && s != ".." else { return false }
        }
        return true
    }

    /// Test-only injection point. Production code never sets this.
    /// Stored as a `@TaskLocal` so parallel tests don't race on a single
    /// global, and so each test's override is naturally scoped to its own
    /// task tree via `withValue { ... }`.
    @TaskLocal
    static var sidecarFetcherForTests: (@Sendable (_ url: URL, _ dest: URL) async throws -> Void)? = nil

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
        guard hasConfig else {
            return nil
        }
        let directWeightSentinels = [
            "model.safetensors",
            "weights.safetensors",
            "model-00001-of-00001.safetensors",
        ]
        if directWeightSentinels.contains(where: {
            fm.fileExists(atPath: resolved.appendingPathComponent($0).path)
        }) {
            return resolved
        }
        for shardCount in 2 ... 256 {
            let candidate = String(format: "model-00001-of-%05d.safetensors", shardCount)
            if fm.fileExists(atPath: resolved.appendingPathComponent(candidate).path) {
                return resolved
            }
        }
        return nil
    }
}
