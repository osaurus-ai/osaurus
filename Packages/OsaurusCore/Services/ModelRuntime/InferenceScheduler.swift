//
//  InferenceScheduler.swift
//  osaurus
//
//  Priority-aware admission queue in front of MLX generation.
//
//  Why this exists: every MLX generation funnels through `MetalGate` which
//  serializes one stream at a time. The gate's internal queue is FIFO, so a
//  long-running plugin batch job blocks the user's keystroke response when
//  they're behind it in line.
//
//  This scheduler sits *in front of* `MetalGate` and decides which waiter
//  enters next based on `InferencePriority`. Within the same priority we
//  preserve FIFO so behaviour is predictable. The gate itself remains for
//  MLX-vs-CoreML coordination (embeddings).
//

import Foundation
import os.log

private let schedLog = Logger(subsystem: "ai.osaurus", category: "InferenceScheduler")

// MARK: - Priority

/// Priority levels for inference admission. Higher raw values jump ahead of
/// lower ones in the queue. New levels can be added without affecting existing
/// callers — defaults flow through `.plugin`.
public enum InferencePriority: Int, Sendable, Comparable, CaseIterable {
    /// Internal background work — preflight capability search, memory
    /// extraction, summarization, anything the user didn't explicitly request.
    case maintenance = 0
    /// Scheduled / detached background tasks (work mode dispatched via plugin
    /// or schedule). The user knows it's running; they don't expect typing
    /// latency from it.
    case background = 25
    /// Live plugin inference (`complete`, `complete_stream`, `embed`). Treated
    /// below interactive so a webhook flood can't starve a user mid-typing.
    case plugin = 50
    /// HTTP API requests from external clients. Bumped above plugins because
    /// users typically have an interactive UI on the other end.
    case httpAPI = 75
    /// Foreground UI typing — the user is actively waiting for tokens to render.
    case interactive = 100

    public static func < (lhs: InferencePriority, rhs: InferencePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .maintenance: return "maintenance"
        case .background: return "background"
        case .plugin: return "plugin"
        case .httpAPI: return "httpAPI"
        case .interactive: return "interactive"
        }
    }
}

// MARK: - Telemetry

/// Snapshot of the scheduler's current state. Cheap to compute and safe to
/// publish over Combine for a debug HUD.
public struct InferenceSchedulerSnapshot: Sendable {
    public let active: Bool
    public let activePriority: InferencePriority?
    public let queuedByPriority: [InferencePriority: Int]
    public let totalQueued: Int
    public let totalAdmitted: UInt64
    public let totalRejected: UInt64
}

// MARK: - Scheduler

/// Single-slot priority scheduler in front of `MetalGate`. Enter via
/// `acquire(priority:)`, do the work, then call `release()` from the same
/// task. The pair is symmetric — every `acquire` MUST be matched by exactly
/// one `release` on every exit path.
public actor InferenceScheduler {
    public static let shared = InferenceScheduler()

    private struct Waiter {
        let id: UUID
        let priority: InferencePriority
        let enqueuedAt: Date
        let continuation: CheckedContinuation<Void, Never>
    }

    private var waiters: [Waiter] = []
    private var generationActive = false
    private var activePriority: InferencePriority?

    private var queuedCounts: [InferencePriority: Int] = [:]
    private var totalAdmitted: UInt64 = 0
    private var totalRejected: UInt64 = 0

    private init() {}

    // MARK: - Acquire / release

    /// Take the single MLX slot. If another generation is in flight, parks the
    /// caller in the priority queue and resumes when it's their turn.
    public func acquire(priority: InferencePriority) async {
        if !generationActive {
            generationActive = true
            activePriority = priority
            totalAdmitted &+= 1
            schedLog.info(
                "scheduler: admitted \(priority.label, privacy: .public) (no queue)"
            )
            return
        }

        queuedCounts[priority, default: 0] += 1
        let queueDepth = waiters.count + 1
        schedLog.info(
            "scheduler: queued \(priority.label, privacy: .public) (depth=\(queueDepth, privacy: .public), active=\(self.activePriority?.label ?? "?", privacy: .public))"
        )

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(
                Waiter(
                    id: UUID(),
                    priority: priority,
                    enqueuedAt: Date(),
                    continuation: continuation
                )
            )
        }
        // When resumed, `release()` already promoted us to active; nothing to do.
    }

    /// Release the slot. If anyone is waiting, hands the slot to the
    /// highest-priority waiter (FIFO within priority).
    public func release() {
        if let next = popHighestPriority() {
            queuedCounts[next.priority] = max(0, (queuedCounts[next.priority] ?? 0) - 1)
            activePriority = next.priority
            totalAdmitted &+= 1
            // generationActive stays true — we're handing ownership over.
            schedLog.info(
                "scheduler: handing slot to \(next.priority.label, privacy: .public) (waited \(String(format: "%.0f", -next.enqueuedAt.timeIntervalSinceNow * 1000), privacy: .public)ms)"
            )
            next.continuation.resume()
        } else {
            generationActive = false
            activePriority = nil
        }
    }

    /// Convenience wrapper that pairs acquire with a guaranteed release on
    /// every throw or normal-return path. Use this for short critical sections;
    /// long-running streams should use the explicit acquire/release pair so
    /// the slot is held for the full stream lifetime.
    public func withSlot<T>(
        priority: InferencePriority,
        _ body: () async throws -> T
    ) async rethrows -> T {
        await acquire(priority: priority)
        do {
            let value = try await body()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func popHighestPriority() -> Waiter? {
        guard let maxPriority = waiters.lazy.map(\.priority).max() else { return nil }
        guard let idx = waiters.firstIndex(where: { $0.priority == maxPriority }) else {
            return nil
        }
        return waiters.remove(at: idx)
    }

    // MARK: - Inspection

    /// Whether at least one priority strictly higher than `current` is queued.
    /// Used by cooperative yield points to decide if they should pause and
    /// let a more-important request go (Phase 2 preemption).
    public func shouldYield(above current: InferencePriority) -> Bool {
        waiters.contains { $0.priority > current }
    }

    public func snapshot() -> InferenceSchedulerSnapshot {
        InferenceSchedulerSnapshot(
            active: generationActive,
            activePriority: activePriority,
            queuedByPriority: queuedCounts,
            totalQueued: waiters.count,
            totalAdmitted: totalAdmitted,
            totalRejected: totalRejected
        )
    }

    /// Test/diagnostic helper: rejects everyone currently waiting. Not used
    /// in production paths; provided so a future "drain on shutdown" or
    /// stress test can observe rejection counters.
    public func cancelAllWaiters() {
        let pending = waiters
        waiters.removeAll()
        queuedCounts.removeAll()
        totalRejected &+= UInt64(pending.count)
        for waiter in pending {
            waiter.continuation.resume()
        }
    }
}
