//
//  EmbeddingBatcher.swift
//  osaurus
//
//  Micro-batches concurrent single-text embedding requests into one batched
//  forward pass. Memory search and distillation fan out many single-text
//  embeds (VecturaKit embeds each search query with `embed(text:)`), and
//  without coalescing those callers serialize one-by-one through MetalGate.
//
//  Constraint: this layer sits ABOVE MetalGate. The backend it is given must
//  be the gate-acquiring path (`MetalSafeEmbedder.embed(texts:)`), so one
//  coalesced batch acquires the gate exactly once. The batcher itself never
//  touches the gate and must not change its semantics.
//
//  Constraint: a lone request's added latency is bounded by the coalescing
//  window (default 25 ms) — the window timer starts with the first request
//  and is never extended by later arrivals.
//

import Foundation
import VecturaKit

public enum EmbeddingBatcherError: Error, Equatable {
    /// The backend returned a different number of vectors than texts sent.
    case mismatchedResultCount(expected: Int, received: Int)
}

/// Coalesces single-text embedding requests that arrive within a short
/// window into one backend call, and distributes the resulting vectors back
/// to the awaiting callers by index.
public actor EmbeddingBatcher {
    /// One batched forward over the given texts. Must return exactly one
    /// vector per input text, in input order. This is the gate-acquiring
    /// boundary: it must acquire MetalGate once for the whole batch.
    public typealias Backend = @Sendable ([String]) async throws -> [[Float]]

    /// Coalescing window. 25 ms is long enough for a memory-search or
    /// distillation fan-out (tasks spawned in the same event-loop tick land
    /// within a millisecond) yet short enough that a lone caller's
    /// worst-case added latency stays negligible next to the embed forward
    /// itself. Batched-forward measurements in the MLX ecosystem show
    /// batch 4-8 giving ~1.5x throughput at this latency cost.
    public static let defaultWindow: Duration = .milliseconds(25)

    /// Upper bound on one coalesced batch. 16 keeps the padded [N, L, D]
    /// gather small (16 x 512 tokens x 128 dims of Float is ~4 MB) and keeps
    /// per-batch gate hold times short so generation is not starved.
    public static let defaultMaxBatchSize = 16

    private let window: Duration
    private let maxBatchSize: Int
    private let clock: any Clock<Duration>
    private let backend: Backend

    /// Texts of the batch currently accumulating in the open window.
    private var pendingBatch: [(id: UInt64, text: String)] = []
    /// Continuations for every request not yet resumed, including requests
    /// already handed to an in-flight backend call. Keyed by request id so a
    /// cancelled waiter can be resumed early without disturbing the batch.
    private var waiters: [UInt64: CheckedContinuation<[Float], any Error>] = [:]
    /// Requests whose cancellation raced ahead of their enqueue.
    private var cancelledBeforeEnqueue: Set<UInt64> = []
    /// Requests currently inside `embed`, so a late cancellation Task can
    /// tell "not yet enqueued" apart from "already completed" and never
    /// leaves a stale entry in `cancelledBeforeEnqueue`.
    private var activeIDs: Set<UInt64> = []
    private var windowTask: Task<Void, Never>?
    private var nextID: UInt64 = 0

    public init(
        window: Duration = EmbeddingBatcher.defaultWindow,
        maxBatchSize: Int = EmbeddingBatcher.defaultMaxBatchSize,
        clock: any Clock<Duration> = ContinuousClock(),
        backend: @escaping Backend
    ) {
        precondition(maxBatchSize >= 1, "maxBatchSize must be at least 1")
        self.window = window
        self.maxBatchSize = maxBatchSize
        self.clock = clock
        self.backend = backend
    }

    /// Embed one text, coalescing with other requests that arrive within the
    /// window. Worst-case added latency for a lone caller is one window.
    /// Cancelling the calling task resumes only this waiter with
    /// `CancellationError`; the rest of the batch proceeds.
    public func embed(_ text: String) async throws -> [Float] {
        let id = nextID
        nextID &+= 1
        activeIDs.insert(id)
        defer {
            activeIDs.remove(id)
            cancelledBeforeEnqueue.remove(id)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(id: id, text: text, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    // MARK: - Batch lifecycle

    private func enqueue(
        id: UInt64,
        text: String,
        continuation: CheckedContinuation<[Float], any Error>
    ) {
        if cancelledBeforeEnqueue.contains(id) {
            cancelledBeforeEnqueue.remove(id)
            continuation.resume(throwing: CancellationError())
            return
        }
        waiters[id] = continuation
        pendingBatch.append((id: id, text: text))

        if pendingBatch.count >= maxBatchSize {
            // Full batch: flush immediately instead of waiting out the window.
            windowTask?.cancel()
            windowTask = nil
            Task { await self.flush() }
        } else if windowTask == nil {
            // First request of an idle period opens the window. Later
            // arrivals join the batch but never extend the deadline, so the
            // first caller's added latency is bounded by one window.
            windowTask = Task { [clock, window] in
                do {
                    try await clock.sleep(for: window, tolerance: nil)
                } catch {
                    return  // Cancelled by a max-batch-size flush.
                }
                await self.windowExpired()
            }
        }
    }

    private func windowExpired() async {
        windowTask = nil
        await flush()
    }

    /// Drain the pending batch through the backend in chunks of at most
    /// `maxBatchSize`, resuming each waiter with its vector (or the batch
    /// error). Runs on the actor; the backend await is a reentrancy point,
    /// so new requests can keep enqueueing while a batch is in flight.
    private func flush() async {
        while !pendingBatch.isEmpty {
            let batch = Array(pendingBatch.prefix(maxBatchSize))
            pendingBatch.removeFirst(batch.count)
            do {
                let vectors = try await backend(batch.map(\.text))
                guard vectors.count == batch.count else {
                    throw EmbeddingBatcherError.mismatchedResultCount(
                        expected: batch.count, received: vectors.count
                    )
                }
                for (index, entry) in batch.enumerated() {
                    // nil when the waiter was cancelled mid-flight; its
                    // result is simply discarded.
                    waiters.removeValue(forKey: entry.id)?.resume(returning: vectors[index])
                }
            } catch {
                for entry in batch {
                    waiters.removeValue(forKey: entry.id)?.resume(throwing: error)
                }
            }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        if let continuation = waiters.removeValue(forKey: id) {
            // Still pending (not yet flushed): drop the text from the batch.
            // Already in flight: the batch keeps running for the others and
            // this waiter's slot is discarded on completion.
            pendingBatch.removeAll { $0.id == id }
            continuation.resume(throwing: CancellationError())
        } else if activeIDs.contains(id) {
            // Cancellation ran before enqueue registered the continuation.
            cancelledBeforeEnqueue.insert(id)
        }
    }
}

/// `VecturaEmbedder` front for the shared embedding path: single-text embeds
/// (VecturaKit search queries, incremental index updates) coalesce through
/// the `EmbeddingBatcher`; caller-assembled multi-text batches pass straight
/// to the direct embedder — they are already one batched forward, and
/// holding them for a window would only add latency.
///
/// The `direct` embedder must be the MetalGate-acquiring path
/// (`MetalSafeEmbedder`), and the batcher's backend must call that same
/// path, so every underlying forward — coalesced or pass-through — holds the
/// gate exactly once.
public struct CoalescingEmbedder: VecturaEmbedder {
    private let direct: any VecturaEmbedder
    private let batcher: EmbeddingBatcher

    public init(direct: any VecturaEmbedder, batcher: EmbeddingBatcher) {
        self.direct = direct
        self.batcher = batcher
    }

    public var dimension: Int {
        get async throws { try await direct.dimension }
    }

    public func embed(texts: [String]) async throws -> [[Float]] {
        try await direct.embed(texts: texts)
    }

    public func embed(text: String) async throws -> [Float] {
        try await batcher.embed(text)
    }
}
