//
//  SandboxInstallLockTests.swift
//  osaurusTests
//
//  Pins the per-agent serialization semantics of `SandboxInstallLock`.
//  Two install operations on the same agent must run sequentially —
//  that's what prevents npm/pip/apk from racing on the same
//  `node_modules/` / venv / apk db. Two operations on DIFFERENT agents
//  must still run concurrently.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct SandboxInstallLockTests {

    /// Two `serialize(agentName:)` calls on the same key run one after
    /// the other: the second body must not start before the first
    /// finishes. We assert that by recording the pre/post timestamps
    /// of each body and checking the second's start is ≥ the first's
    /// end.
    @Test
    func sameAgent_runsSequentially() async throws {
        let lock = SandboxInstallLock()
        let timeline = ActorTimeline()
        let agentName = "agent-A"

        // Kick off two operations concurrently. Both want the same lock.
        // The second one MUST wait for the first to finish.
        async let first: Void = lock.serialize(agentName: agentName) {
            await timeline.markStart("first")
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
            await timeline.markEnd("first")
        }
        async let second: Void = lock.serialize(agentName: agentName) {
            await timeline.markStart("second")
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
            await timeline.markEnd("second")
        }
        _ = try await (first, second)

        let firstEnd = try #require(await timeline.endOf("first"))
        let secondStart = try #require(await timeline.startOf("second"))
        #expect(
            secondStart >= firstEnd,
            "second op started before first finished — serialization broken"
        )
    }

    /// Two `serialize(agentName:)` calls on DIFFERENT keys must run
    /// concurrently. Wall-clock comparisons are flaky under CI load,
    /// so we instead observe overlap directly: each body increments a
    /// shared counter on entry and decrements on exit; if both bodies
    /// are inside the lock at the same moment the counter hits 2.
    /// A serialized lock would never let it climb above 1.
    @Test
    func differentAgents_runConcurrently() async throws {
        let lock = SandboxInstallLock()
        let observer = OverlapObserver()

        // Each body yields 50× so the cooperative scheduler interleaves
        // the two tasks reliably on every Apple Silicon Mac we've run
        // this on. The assumption is that `Task.yield()` always gives
        // the runtime a chance to pick another ready task — which is
        // the documented contract today. If a future Swift runtime
        // optimises `yield()` into a no-op when only one task is
        // ready (it currently doesn't), this test would need to swap
        // to an explicit two-way handshake (continuation each side
        // resumes after entering). Calling out the assumption here so
        // a future failure has the right context.
        async let a: Void = lock.serialize(agentName: "agent-A") {
            await observer.enter()
            for _ in 0 ..< 50 { await Task.yield() }
            await observer.exit()
        }
        async let b: Void = lock.serialize(agentName: "agent-B") {
            await observer.enter()
            for _ in 0 ..< 50 { await Task.yield() }
            await observer.exit()
        }
        _ = try await (a, b)

        let peak = await observer.peakConcurrent
        #expect(
            peak >= 2,
            "two different-agent ops never overlapped (peak=\(peak)) — serialization leaked across keys"
        )
    }

    /// Errors thrown by the body propagate to the caller, AND the lock
    /// queue advances so the next `serialize(agentName:)` call still
    /// runs. Without this, one failed install would wedge every
    /// subsequent install for the same agent.
    @Test
    func errorReleasesLock() async throws {
        struct Boom: Error {}
        let lock = SandboxInstallLock()

        // First op throws.
        do {
            try await lock.serialize(agentName: "agent-A") {
                throw Boom()
            }
            Issue.record("expected Boom to propagate")
        } catch is Boom {
            // ok
        }

        // Second op must still run.
        let didRun = ActorFlag()
        try await lock.serialize(agentName: "agent-A") {
            await didRun.set()
        }
        #expect(await didRun.value, "lock queue is wedged after a thrown body")
    }
}

// MARK: - Test helpers

/// Tiny actor that records start/end Dates for named operations. Lets
/// the sequential-ordering assertion above check the timeline without
/// fighting Sendable semantics on a mutable struct.
private actor ActorTimeline {
    private var starts: [String: Date] = [:]
    private var ends: [String: Date] = [:]

    func markStart(_ key: String) { starts[key] = Date() }
    func markEnd(_ key: String) { ends[key] = Date() }
    func startOf(_ key: String) -> Date? { starts[key] }
    func endOf(_ key: String) -> Date? { ends[key] }
}

/// One-shot Sendable bool flag. Lets a `@Sendable` closure mark
/// completion without tripping the captured-var concurrency checker.
private actor ActorFlag {
    private(set) var value: Bool = false
    func set() { value = true }
}

/// Tracks how many tasks are simultaneously inside an instrumented
/// section, recording the peak. The
/// `differentAgents_runConcurrently` test asserts the peak ≥ 2 to
/// prove the lock didn't serialize across keys.
private actor OverlapObserver {
    private(set) var peakConcurrent: Int = 0
    private var current: Int = 0

    func enter() {
        current += 1
        if current > peakConcurrent { peakConcurrent = current }
    }
    func exit() { current -= 1 }
}
