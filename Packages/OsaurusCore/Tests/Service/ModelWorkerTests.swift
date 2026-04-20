//
//  ModelWorkerTests.swift
//  osaurus
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ModelWorkerTests {

    @Test func first_caller_admitted_immediately() async {
        let worker = ModelWorker(modelName: "test-model-\(UUID().uuidString)")
        await worker.acquire(priority: .interactive)
        let snap = await worker.snapshot()
        #expect(snap.active)
        await worker.release()
    }

    @Test func same_model_serializes() async {
        let worker = ModelWorker(modelName: "serial-model-\(UUID().uuidString)")
        await worker.acquire(priority: .plugin)

        let secondAdmitted = AtomicBool()
        let task = Task {
            await worker.acquire(priority: .plugin)
            secondAdmitted.set()
            await worker.release()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(!secondAdmitted.value)

        await worker.release()
        await task.value
        #expect(secondAdmitted.value)
    }

    @Test func priority_ordering_within_worker() async {
        let worker = ModelWorker(modelName: "prio-model-\(UUID().uuidString)")
        await worker.acquire(priority: .background)

        let order = Recorder()

        let lowTask = Task {
            await worker.acquire(priority: .background)
            order.record("background")
            await worker.release()
        }
        let highTask = Task {
            await worker.acquire(priority: .interactive)
            order.record("interactive")
            await worker.release()
        }
        let midTask = Task {
            await worker.acquire(priority: .plugin)
            order.record("plugin")
            await worker.release()
        }

        try? await Task.sleep(nanoseconds: 80_000_000)
        await worker.release()

        await lowTask.value
        await highTask.value
        await midTask.value

        #expect(order.values == ["interactive", "plugin", "background"])
    }

    @Test func registry_returns_same_worker_per_name() async {
        let registry = ModelWorkerRegistry.shared
        let name = "registry-test-\(UUID().uuidString)"
        let a = await registry.worker(for: name)
        let b = await registry.worker(for: name)
        #expect(a === b)
    }

    @Test func different_models_get_distinct_workers() async {
        let registry = ModelWorkerRegistry.shared
        let n1 = "a-\(UUID().uuidString)"
        let n2 = "b-\(UUID().uuidString)"
        let w1 = await registry.worker(for: n1)
        let w2 = await registry.worker(for: n2)
        #expect(w1 !== w2)

        // Two different workers can be active concurrently — verifies the
        // per-model isolation that Phase 3 multi-model concurrency relies on.
        await w1.acquire(priority: .plugin)
        await w2.acquire(priority: .plugin)
        let s1 = await w1.snapshot()
        let s2 = await w2.snapshot()
        #expect(s1.active)
        #expect(s2.active)

        await w1.release()
        await w2.release()
    }
}

private final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    var values: [String] { lock.withLock { _values } }
    func record(_ s: String) { lock.withLock { _values.append(s) } }
}
