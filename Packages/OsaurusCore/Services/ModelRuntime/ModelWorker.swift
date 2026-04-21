//
//  ModelWorker.swift
//  osaurus
//
//  Per-model serialization point sitting between `InferenceScheduler`
//  (priority-aware admission) and `ModelRuntime.generateEventStream`
//  (actual generation).
//
//  Today this is a thin wrapper — same-model requests serialize because
//  `MLXLMCommon.TokenIterator` does not expose a checkpoint at which one
//  iterator can yield to another. The design intentionally preserves the
//  shape needed for future improvements:
//
//   - When MLX exposes a pause/resume API, time-multiplexing two same-model
//     streams becomes a localized change inside `ModelWorker`.
//   - When the `mlxAllowConcurrentStreams` feature flag is on (Phase 3
//     Todo 2), `MetalGate` stops gating MLX-vs-MLX and per-model workers
//     are the only serialization for the same model.
//
//  This file has no runtime-behaviour change on its own — code that wants
//  per-model serialization opts in by routing through `ModelWorkerRegistry`.
//

import Foundation
import os.log

private let workerLog = Logger(subsystem: "ai.osaurus", category: "ModelWorker")

// MARK: - Worker

/// Per-model serialization actor. Within one worker, only one task can hold
/// the slot at a time; waiters are admitted in priority order (FIFO within
/// the same priority).
public actor ModelWorker {
    public let modelName: String

    private struct Waiter {
        let priority: InferencePriority
        let enqueuedAt: Date
        let continuation: CheckedContinuation<Void, Never>
    }

    private var active = false
    private var activePriority: InferencePriority?
    private var waiters: [Waiter] = []

    init(modelName: String) {
        self.modelName = modelName
    }

    /// Take the per-model slot. Caller MUST pair with exactly one `release()`.
    public func acquire(priority: InferencePriority) async {
        if !active {
            active = true
            activePriority = priority
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(
                Waiter(
                    priority: priority,
                    enqueuedAt: Date(),
                    continuation: continuation
                )
            )
        }
    }

    /// Release the slot, handing it to the highest-priority waiter (FIFO
    /// within priority).
    public func release() {
        if let next = popHighestPriority() {
            activePriority = next.priority
            // active stays true — handing over.
            next.continuation.resume()
        } else {
            active = false
            activePriority = nil
        }
    }

    private func popHighestPriority() -> Waiter? {
        guard let maxPriority = waiters.lazy.map(\.priority).max() else { return nil }
        guard let idx = waiters.firstIndex(where: { $0.priority == maxPriority }) else {
            return nil
        }
        return waiters.remove(at: idx)
    }

    public struct Snapshot: Sendable {
        public let modelName: String
        public let active: Bool
        public let activePriority: InferencePriority?
        public let queueDepth: Int
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            modelName: modelName,
            active: active,
            activePriority: activePriority,
            queueDepth: waiters.count
        )
    }
}

// MARK: - Registry

/// Global registry of per-model workers. Workers are created lazily on first
/// access and never destroyed during process lifetime — the cost is one tiny
/// actor per loaded model name.
public actor ModelWorkerRegistry {
    public static let shared = ModelWorkerRegistry()

    private var workers: [String: ModelWorker] = [:]

    private init() {}

    /// Get-or-create the worker for `modelName`. Names should be the same
    /// canonical strings used elsewhere (e.g. `ModelLease.acquire`) so the
    /// per-model scope lines up.
    public func worker(for modelName: String) -> ModelWorker {
        if let existing = workers[modelName] { return existing }
        let worker = ModelWorker(modelName: modelName)
        workers[modelName] = worker
        workerLog.info("registered worker for \(modelName, privacy: .public)")
        return worker
    }

    /// Snapshot of every worker's state. Used by the scheduler debug HUD to
    /// show per-model queue depth, and by tests.
    public func snapshots() async -> [ModelWorker.Snapshot] {
        var out: [ModelWorker.Snapshot] = []
        out.reserveCapacity(workers.count)
        for worker in workers.values {
            out.append(await worker.snapshot())
        }
        return out.sorted { $0.modelName < $1.modelName }
    }
}
