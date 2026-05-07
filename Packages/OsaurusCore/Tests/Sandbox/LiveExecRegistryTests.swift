//
//  LiveExecRegistryTests.swift
//
//  Pin the contracts the chat UI relies on:
//   - register/lookup round-trips an entry by tool-call-id
//   - entriesPublisher emits on every register / unregister tick
//   - terminate closure is invoked exactly once per [Terminate] press
//   - clearAll cancels grace tasks and drops everything
//
//  We DON'T pin the 60s drop-grace timer here (that would slow CI by a
//  full minute); the public `clearAll` covers the cleanup path.
//

import Combine
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct LiveExecRegistryTests {

    private func makeEntry(
        toolCallId: String = "call-\(UUID().uuidString)",
        terminateCount: TerminateCounter = TerminateCounter()
    ) -> LiveExecRegistry.Entry {
        let outputSubject = PassthroughSubject<Data, Never>()
        // Wrap in a `@unchecked Sendable` box so the `currentStatus`
        // closure can capture without tripping strict-concurrency.
        // Mirrors `StatusSubjectBox` in the production code.
        let statusBox = TestStatusBox()
        return LiveExecRegistry.Entry(
            toolCallId: toolCallId,
            pid: "1234",
            command: "sleep 1",
            startedAt: Date(),
            outputPublisher: outputSubject.eraseToAnyPublisher(),
            statusPublisher: statusBox.publisher,
            currentStatus: { statusBox.current },
            seed: { Data() },
            terminate: { _ in await terminateCount.increment() }
        )
    }

    @Test func registerAndLookupRoundTrips() async {
        let registry = LiveExecRegistry()
        let entry = makeEntry(toolCallId: "abc")
        await registry.register(entry)
        let fetched = await registry.handle(toolCallId: "abc")
        #expect(fetched?.toolCallId == "abc")
        await registry.clearAll()
    }

    @Test func unknownIdReturnsNil() async {
        let registry = LiveExecRegistry()
        let fetched = await registry.handle(toolCallId: "missing")
        #expect(fetched == nil)
    }

    @Test func entriesPublisherEmitsOnRegister() async {
        let registry = LiveExecRegistry()
        let collector = SnapshotCollector<[String: LiveExecRegistry.Entry]>()
        let cancellable = registry.entriesPublisher.sink { snapshot in
            Task { await collector.append(snapshot) }
        }
        defer {
            cancellable.cancel()
        }

        await registry.register(makeEntry(toolCallId: "live-1"))
        await registry.register(makeEntry(toolCallId: "live-2"))

        // Give the sink enough time to drain the two emissions.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let history = await collector.snapshots
        // 1 initial empty + 1 per register.
        #expect(history.count >= 2)
        let lastIds = history.last.map { Set($0.keys) } ?? []
        #expect(lastIds.contains("live-1"))
        #expect(lastIds.contains("live-2"))
        await registry.clearAll()
    }

    @Test func terminateClosureForwardsToProducer() async {
        let counter = TerminateCounter()
        let entry = makeEntry(toolCallId: "kill-me", terminateCount: counter)
        let registry = LiveExecRegistry()
        await registry.register(entry)

        guard let handle = await registry.handle(toolCallId: "kill-me") else {
            Issue.record("expected entry to be registered")
            return
        }
        await handle.terminate(0)
        await handle.terminate(0)

        let n = await counter.count
        #expect(n == 2, "terminate should pass through every press; got \(n)")

        await registry.clearAll()
    }

    @Test func clearAllDropsEverythingImmediately() async {
        let registry = LiveExecRegistry()
        await registry.register(makeEntry(toolCallId: "a"))
        await registry.register(makeEntry(toolCallId: "b"))
        await registry.clearAll()
        #expect(await registry.handle(toolCallId: "a") == nil)
        #expect(await registry.handle(toolCallId: "b") == nil)
    }
}

private actor TerminateCounter {
    private var _count = 0
    var count: Int { _count }
    func increment() { _count += 1 }
}

private final class TestStatusBox: @unchecked Sendable {
    private let subject = CurrentValueSubject<LiveExecRegistry.LiveExecStatus, Never>(.running)
    var publisher: AnyPublisher<LiveExecRegistry.LiveExecStatus, Never> {
        subject.eraseToAnyPublisher()
    }
    var current: LiveExecRegistry.LiveExecStatus { subject.value }
    func send(_ status: LiveExecRegistry.LiveExecStatus) { subject.send(status) }
}

private actor SnapshotCollector<T: Sendable> {
    private var _snapshots: [T] = []
    var snapshots: [T] { _snapshots }
    func append(_ snapshot: T) { _snapshots.append(snapshot) }
}
