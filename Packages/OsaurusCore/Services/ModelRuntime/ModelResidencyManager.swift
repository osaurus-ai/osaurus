//
//  ModelResidencyManager.swift
//  osaurus
//
//  Actor-isolated idle timers for local model memory residency.
//

import Foundation

/// Schedules idle unloads after a model's final generation lease drops.
///
/// The actor owns only Osaurus policy state. `ModelRuntime` remains the
/// authority for loading/unloading containers, while `ModelLease` remains the
/// crash-safety boundary that proves no stream is still using model buffers.
public actor ModelResidencyManager {
    public struct Snapshot: Equatable, Sendable {
        public var modelName: String
        public var lastUsedAt: Date
        public var unloadAt: Date?
        public var policy: ModelIdleResidencyPolicy
    }

    public typealias Sleep = @Sendable (UInt64) async -> Void

    public static let shared = ModelResidencyManager()

    private struct Entry {
        var generation: UInt64
        var lastUsedAt: Date
        var unloadAt: Date?
        var policy: ModelIdleResidencyPolicy
        var task: Task<Void, Never>?
    }

    private var entries: [String: Entry] = [:]
    private var nextGeneration: UInt64 = 0
    private let sleep: Sleep

    public init(
        sleep: @escaping Sleep = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.sleep = sleep
    }

    /// Mark a model as actively used and cancel any pending idle timer.
    public func markActive(modelName: String, now: Date = Date()) {
        nextGeneration &+= 1
        let existing = entries[modelName]
        existing?.task?.cancel()
        entries[modelName] = Entry(
            generation: nextGeneration,
            lastUsedAt: now,
            unloadAt: nil,
            policy: existing?.policy ?? .never,
            task: nil
        )
    }

    /// Schedule the policy decision that runs after a generation lease drops.
    public func scheduleIdleUnload(
        modelName: String,
        policy: ModelIdleResidencyPolicy,
        now: Date = Date(),
        unload: @Sendable @escaping (String) async -> Void,
        leaseCount: @Sendable @escaping (String) async -> Int,
        isResident: @Sendable @escaping (String) async -> Bool
    ) {
        nextGeneration &+= 1
        let generation = nextGeneration
        entries[modelName]?.task?.cancel()

        let unloadAt: Date?
        let delayNanoseconds: UInt64?
        switch policy {
        case .immediately:
            unloadAt = now
            delayNanoseconds = 0
        case .afterSeconds(let seconds):
            let clamped = max(0, seconds)
            unloadAt = now.addingTimeInterval(TimeInterval(clamped))
            delayNanoseconds = UInt64(clamped) * 1_000_000_000
        case .never:
            entries[modelName] = Entry(
                generation: generation,
                lastUsedAt: now,
                unloadAt: nil,
                policy: policy,
                task: nil
            )
            return
        }

        let task = Task { [sleep] in
            if let delayNanoseconds, delayNanoseconds > 0 {
                await sleep(delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await self.fire(
                modelName: modelName,
                generation: generation,
                unload: unload,
                leaseCount: leaseCount,
                isResident: isResident
            )
        }

        entries[modelName] = Entry(
            generation: generation,
            lastUsedAt: now,
            unloadAt: unloadAt,
            policy: policy,
            task: task
        )
    }

    /// Shorten an already-scheduled idle unload to fire after `grace` seconds.
    ///
    /// Used when the last chat window referencing a model closes: instead of
    /// waiting out the full idle policy (default 15 minutes), the model is
    /// released after a short grace period that still covers a quick reopen.
    ///
    /// Semantics — all deliberate, to stay race-free against API traffic:
    /// - Only ever SHORTENS a pending deadline; if the existing deadline is
    ///   already sooner, this is a no-op.
    /// - No-op when the model has no pending unload timer (model is actively
    ///   generating, or policy is `.never`). An active generation's release
    ///   re-arms the full policy afterwards, so API usage always wins.
    /// - Participates in the generation counter: any `markActive` (a new
    ///   chat/API generation starting) cancels the accelerated timer exactly
    ///   like a policy timer.
    /// - The fire path re-checks lease count, residency, and the optional
    ///   `shouldStillUnload` guard (e.g. "no open chat window re-selected
    ///   this model") before unloading.
    public func accelerateIdleUnload(
        modelName: String,
        grace: TimeInterval,
        now: Date = Date(),
        unload: @Sendable @escaping (String) async -> Void,
        leaseCount: @Sendable @escaping (String) async -> Int,
        isResident: @Sendable @escaping (String) async -> Bool,
        shouldStillUnload: @Sendable @escaping (String) async -> Bool = { _ in true }
    ) {
        guard let existing = entries[modelName],
            existing.task != nil,
            let existingUnloadAt = existing.unloadAt
        else { return }

        let clampedGrace = max(0, grace)
        let target = now.addingTimeInterval(clampedGrace)
        guard target < existingUnloadAt else { return }

        nextGeneration &+= 1
        let generation = nextGeneration
        existing.task?.cancel()

        let delayNanoseconds = UInt64(clampedGrace * 1_000_000_000)
        let task = Task { [sleep] in
            if delayNanoseconds > 0 {
                await sleep(delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await self.fire(
                modelName: modelName,
                generation: generation,
                unload: unload,
                leaseCount: leaseCount,
                isResident: isResident,
                shouldStillUnload: shouldStillUnload
            )
        }

        entries[modelName] = Entry(
            generation: generation,
            lastUsedAt: existing.lastUsedAt,
            unloadAt: target,
            policy: existing.policy,
            task: task
        )
    }

    public func cancel(modelName: String) {
        entries[modelName]?.task?.cancel()
        entries.removeValue(forKey: modelName)
    }

    public func cancelAll() {
        for entry in entries.values {
            entry.task?.cancel()
        }
        entries.removeAll()
    }

    public func snapshots(_: Date = Date()) -> [Snapshot] {
        entries.map { modelName, entry in
            Snapshot(
                modelName: modelName,
                lastUsedAt: entry.lastUsedAt,
                unloadAt: entry.unloadAt,
                policy: entry.policy
            )
        }
        .sorted { lhs, rhs in
            lhs.modelName < rhs.modelName
        }
    }

    private func fire(
        modelName: String,
        generation: UInt64,
        unload: @Sendable @escaping (String) async -> Void,
        leaseCount: @Sendable @escaping (String) async -> Int,
        isResident: @Sendable @escaping (String) async -> Bool,
        shouldStillUnload: @Sendable @escaping (String) async -> Bool = { _ in true }
    ) async {
        guard let entry = entries[modelName], entry.generation == generation else { return }

        guard await leaseCount(modelName) == 0 else {
            clearCompletedTimer(modelName: modelName, generation: generation)
            return
        }

        guard await isResident(modelName) else {
            entries.removeValue(forKey: modelName)
            return
        }

        // Caller-supplied late guard (e.g. chat-close acceleration re-checks
        // that no reopened window wants the model). On refusal the entry is
        // kept without a timer — the next generation's release re-arms the
        // normal policy — mirroring the lease-held case above.
        guard await shouldStillUnload(modelName) else {
            clearCompletedTimer(modelName: modelName, generation: generation)
            return
        }

        guard let current = entries[modelName], current.generation == generation else { return }
        entries.removeValue(forKey: modelName)
        await unload(modelName)
    }

    private func clearCompletedTimer(modelName: String, generation: UInt64) {
        guard var entry = entries[modelName], entry.generation == generation else { return }
        entry.unloadAt = nil
        entry.task = nil
        entries[modelName] = entry
    }
}
