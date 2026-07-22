//
//  SoloGateWarmupHardeningTests.swift
//  osaurusTests
//
//  Post-merge hardening coverage for the load-time MTP warmup (#1903):
//
//  - `SoloGenerationGate.tryAcquire` semantics: a probe returns a lease
//    when the gate is free, `nil` when busy, and a failed probe never
//    enqueues — queued `acquire` waiters are unaffected.
//  - `drainWithDeadline`: the warmup's stream drain must come back at the
//    deadline on a wedged generation (the caller holds the process-wide
//    cold-load slot), and must report completion when the stream ends.
//    The wedged case is exercised with an injected never-ending stream —
//    `drainWithDeadline` takes the `AsyncStream` directly, so no real
//    engine is needed.
//

import Foundation
@preconcurrency import MLXLMCommon
import Testing

@testable import OsaurusCore

struct SoloGateWarmupHardeningTests {

    // MARK: - SoloGenerationGate.tryAcquire

    @Test func tryAcquireReturnsLeaseWhenFreeAndNilWhenBusy() async {
        let gate = MLXBatchAdapter.SoloGenerationGate()

        let lease = await gate.tryAcquire(modelName: "model-a")
        #expect(lease != nil)

        // While held, a probe fails without queuing.
        #expect(await gate.tryAcquire(modelName: "model-b") == nil)

        await lease?.release()

        // Free again: the probe succeeds.
        let again = await gate.tryAcquire(modelName: "model-b")
        #expect(again != nil)
        await again?.release()
    }

    @Test func blockingAcquireStillWorksAfterFailedProbe() async {
        let gate = MLXBatchAdapter.SoloGenerationGate()

        let holder = await gate.acquire(modelName: "model-a")
        #expect(await gate.tryAcquire(modelName: "model-b") == nil)
        await holder.release()

        // The failed probe must not have corrupted the gate state.
        let next = await gate.acquire(modelName: "model-b")
        await next.release()
    }

    @Test func failedProbeDoesNotDisturbQueuedWaiters() async {
        let gate = MLXBatchAdapter.SoloGenerationGate()
        let holder = await gate.acquire(modelName: "model-a")

        // Queue a blocking waiter behind the holder.
        let waiter = Task {
            let lease = await gate.acquire(modelName: "model-b")
            await lease.release()
            return true
        }
        // Let the waiter park (best-effort; the assertions below hold on
        // either interleaving).
        try? await Task.sleep(nanoseconds: 50_000_000)

        // A probe while busy fails and must not enqueue.
        #expect(await gate.tryAcquire(modelName: "model-c") == nil)

        // Releasing the holder hands the gate to the queued waiter, which
        // completes normally — the failed probe left no trace.
        await holder.release()
        #expect(await waiter.value)
    }

    // MARK: - Warmup drain deadline

    @Test func drainReportsCompletionWhenStreamEnds() async {
        let stream = AsyncStream<Generation> { continuation in
            continuation.finish()
        }
        let finished = await MLXBatchAdapter.drainWithDeadline(
            stream, nanoseconds: 1_000_000_000)
        #expect(finished)
    }

    @Test func drainTimesOutOnWedgedStream() async {
        // Injected never-ending stream: the continuation is kept alive and
        // never finished (dropping it would auto-finish the stream), so
        // iteration would block forever without the deadline.
        let (stream, continuation) = AsyncStream<Generation>.makeStream()
        let start = Date()
        let finished = await MLXBatchAdapter.drainWithDeadline(
            stream, nanoseconds: 50_000_000)
        #expect(!finished)
        // Must come back at the deadline, not hang.
        #expect(Date().timeIntervalSince(start) < 5)
        continuation.finish()
    }
}
