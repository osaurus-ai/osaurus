//
//  SubagentAdmissionTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Unit coverage of the process-wide admission gate that serializes local
//  subagent runs (the parallel-batch handoff race fix) while letting remote
//  runs fan out. Uses a private instance with a fast poll so the tests are
//  deterministic and quick; one session-level test proves two exclusive runs
//  never overlap end to end through `SubagentSession.run`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("SubagentAdmission")
struct SubagentAdmissionTests {

    private func makeGate() -> SubagentAdmission {
        SubagentAdmission(pollNanoseconds: 2_000_000)  // 2 ms poll for tests
    }

    @Test("remote admits concurrently, even while an exclusive run is active")
    func remoteAlwaysAdmits() async {
        let gate = makeGate()
        #expect(await gate.admit(.localExclusive) == .admitted)
        #expect(await gate.admit(.remote) == .admitted)
        #expect(await gate.admit(.remote) == .admitted)
        let counts = await gate.snapshot()
        #expect(counts.exclusive == 1)
        #expect(counts.remote == 2)
        await gate.release(.remote)
        await gate.release(.remote)
        await gate.release(.localExclusive)
    }

    @Test("in-place runs coexist with each other")
    func inPlaceCoexists() async {
        let gate = makeGate()
        #expect(await gate.admit(.localInPlace) == .admitted)
        #expect(await gate.admit(.localInPlace) == .admitted)
        let counts = await gate.snapshot()
        #expect(counts.inPlace == 2)
        await gate.release(.localInPlace)
        await gate.release(.localInPlace)
    }

    @Test("a second exclusive run queues until the first releases")
    func exclusiveSerializes() async {
        let gate = makeGate()
        #expect(await gate.admit(.localExclusive) == .admitted)

        let waited = WaitFlag()
        let second = Task {
            await gate.admit(
                .localExclusive,
                timeoutSeconds: 5,
                onWait: { _ in waited.set() }
            )
        }
        // Give the second admit time to hit the wait loop, then release.
        try? await Task.sleep(nanoseconds: 20_000_000)
        await gate.release(.localExclusive)

        let outcome = await second.value
        #expect(outcome == .admitted)
        #expect(waited.isSet)
        await gate.release(.localExclusive)
        let counts = await gate.snapshot()
        #expect(counts.exclusive == 0)
    }

    @Test("an exclusive run waits for in-place runs to drain")
    func exclusiveWaitsForInPlace() async {
        let gate = makeGate()
        #expect(await gate.admit(.localInPlace) == .admitted)
        let second = Task {
            await gate.admit(.localExclusive, timeoutSeconds: 5)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await gate.release(.localInPlace)
        #expect(await second.value == .admitted)
        await gate.release(.localExclusive)
    }

    @Test("an in-place run is blocked only by an exclusive run")
    func inPlaceBlockedByExclusive() async {
        let gate = makeGate()
        #expect(await gate.admit(.localExclusive) == .admitted)
        let second = Task {
            await gate.admit(.localInPlace, timeoutSeconds: 5)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await gate.release(.localExclusive)
        #expect(await second.value == .admitted)
        await gate.release(.localInPlace)
    }

    @Test("a blocked run times out with the active-run description")
    func timeout() async {
        let gate = makeGate()
        #expect(await gate.admit(.localExclusive) == .admitted)
        let outcome = await gate.admit(.localExclusive, timeoutSeconds: 0.05)
        guard case .timedOut(let active) = outcome else {
            Issue.record("expected .timedOut, got \(outcome)")
            return
        }
        #expect(active.contains("local handoff"))
        await gate.release(.localExclusive)
    }

    @Test("cancelling a waiting task returns .cancelled without taking a slot")
    func cancelledWaiter() async {
        let gate = makeGate()
        #expect(await gate.admit(.localExclusive) == .admitted)
        let waiter = Task {
            await gate.admit(.localExclusive, timeoutSeconds: 30)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        waiter.cancel()
        #expect(await waiter.value == .cancelled)
        let counts = await gate.snapshot()
        #expect(counts.exclusive == 1)
        await gate.release(.localExclusive)
    }

    @Test("release clamps at zero (defensive against double-release)")
    func releaseClamps() async {
        let gate = makeGate()
        await gate.release(.localExclusive)
        let counts = await gate.snapshot()
        #expect(counts.exclusive == 0)
        #expect(await gate.admit(.localExclusive) == .admitted)
        await gate.release(.localExclusive)
    }

    // MARK: - Plan → class mapping

    @Test("residency plan maps onto the admission class")
    func planMapping() {
        let unloadPlan = ResidencyPlan(shouldUnload: true)
        #expect(
            SubagentResidency.admissionClass(isLocal: true, plan: unloadPlan) == .localExclusive
        )
        #expect(SubagentResidency.admissionClass(isLocal: true, plan: .none) == .localInPlace)
        #expect(SubagentResidency.admissionClass(isLocal: false, plan: .none) == .remote)
    }
}

// MARK: - Session-level serialization

@Suite("SubagentSession admission")
struct SubagentSessionAdmissionTests {

    /// A kind that reports `.localExclusive` and records run overlap.
    private final class ExclusiveKind: SubagentKind, @unchecked Sendable {
        let capability = SubagentCapability(
            id: "exclusive-scripted",
            toolNames: ["exclusive-scripted"],
            gate: .sandboxExec
        )
        let tracker: OverlapTracker

        init(tracker: OverlapTracker) { self.tracker = tracker }

        func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
            ResolvedModel(name: "scripted-local", id: "scripted-local", isLocal: true)
        }
        func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
            .allow
        }
        func admissionClass(_ resolved: ResolvedModel) -> SubagentAdmissionClass {
            .localExclusive
        }
        func run(
            _ scope: SubagentScope,
            _ resolved: ResolvedModel,
            feed: SubagentFeed,
            interrupt: InterruptToken
        ) async throws -> SubagentResult {
            tracker.enter()
            try? await Task.sleep(nanoseconds: 50_000_000)
            tracker.exit()
            return SubagentResult(payload: ["kind": "scripted", "summary": "done"])
        }
    }

    @Test("two concurrent exclusive runs never overlap through the host")
    func exclusiveRunsSerializeThroughSession() async {
        let tracker = OverlapTracker()
        let a = ExclusiveKind(tracker: tracker)
        let b = ExclusiveKind(tracker: tracker)
        async let first = SubagentSession.run(a, tool: "exclusive-scripted")
        async let second = SubagentSession.run(b, tool: "exclusive-scripted")
        let envelopes = await [first, second]
        #expect(envelopes.allSatisfy { ToolEnvelope.isSuccess($0) })
        #expect(tracker.maxConcurrent == 1)
        #expect(tracker.totalRuns == 2)
    }

    /// A kind that reports `.remote` and holds inside `run` until BOTH runs
    /// are in flight (rendezvous), proving remote spawns fan out in parallel.
    /// If remote runs were wrongly serialized, the first would hold its slot
    /// while waiting for a second that can never start — the rendezvous times
    /// out and `maxConcurrent` stays 1.
    private final class RemoteKind: SubagentKind, @unchecked Sendable {
        let capability = SubagentCapability(
            id: "remote-scripted",
            toolNames: ["remote-scripted"],
            gate: .sandboxExec
        )
        let tracker: OverlapTracker

        init(tracker: OverlapTracker) { self.tracker = tracker }

        func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
            ResolvedModel(name: "scripted-remote", isLocal: false)
        }
        func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
            .allow
        }
        func admissionClass(_ resolved: ResolvedModel) -> SubagentAdmissionClass {
            .remote
        }
        func run(
            _ scope: SubagentScope,
            _ resolved: ResolvedModel,
            feed: SubagentFeed,
            interrupt: InterruptToken
        ) async throws -> SubagentResult {
            tracker.enter()
            defer { tracker.exit() }
            // Rendezvous on ARRIVALS (monotonic), not the live count — the
            // sibling may already have exited by the time this run polls.
            let deadline = Date().addingTimeInterval(2)
            while tracker.totalRuns < 2, Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            return SubagentResult(payload: ["kind": "scripted", "summary": "done"])
        }
    }

    @Test("two concurrent remote runs overlap through the host (parallel fan-out)")
    func remoteRunsFanOutThroughSession() async {
        let tracker = OverlapTracker()
        let a = RemoteKind(tracker: tracker)
        let b = RemoteKind(tracker: tracker)
        async let first = SubagentSession.run(a, tool: "remote-scripted")
        async let second = SubagentSession.run(b, tool: "remote-scripted")
        let envelopes = await [first, second]
        #expect(envelopes.allSatisfy { ToolEnvelope.isSuccess($0) })
        #expect(tracker.maxConcurrent == 2)
        #expect(tracker.totalRuns == 2)
    }
}

// MARK: - Test helpers

private final class WaitFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

private final class OverlapTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var _maxConcurrent = 0
    private var _totalRuns = 0

    var currentActive: Int {
        lock.lock()
        defer { lock.unlock() }
        return active
    }
    var maxConcurrent: Int {
        lock.lock()
        defer { lock.unlock() }
        return _maxConcurrent
    }
    var totalRuns: Int {
        lock.lock()
        defer { lock.unlock() }
        return _totalRuns
    }

    func enter() {
        lock.lock()
        active += 1
        _maxConcurrent = max(_maxConcurrent, active)
        _totalRuns += 1
        lock.unlock()
    }
    func exit() {
        lock.lock()
        active -= 1
        lock.unlock()
    }
}
