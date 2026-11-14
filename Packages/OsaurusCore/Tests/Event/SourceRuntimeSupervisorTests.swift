//
//  SourceRuntimeSupervisorTests.swift
//  osaurusTests
//
//  The poll / stream runtime: immediate first tick, interval and backoff
//  waits, submit-before-commit ordering, catch-up policy, pause on
//  unregister, Poll now, stream reconnect, forced reconnect and heartbeat
//  timeout. A manual sleeper stands in for time.
//

import Foundation
import Testing

@testable import OsaurusCore

/// Sleeps until the test releases sleeps of a given duration.
actor ManualSleeper: AgentChannelTransportSleeping {
    private(set) var requested: [TimeInterval] = []
    private var waiters: [(id: UUID, duration: TimeInterval, continuation: CheckedContinuation<Void, Error>)] = []
    private var cancelled: Set<UUID> = []

    func sleep(for duration: TimeInterval) async throws {
        let id = UUID()
        requested.append(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelled.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, duration, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        } else {
            cancelled.insert(id)
        }
    }

    var pending: [TimeInterval] { waiters.map(\.duration) }

    /// Ends every pending sleep of `duration` (any, when nil).
    func release(_ duration: TimeInterval? = nil) {
        let matching = waiters.filter { duration == nil || abs($0.duration - duration!) < 0.001 }
        waiters.removeAll { entry in matching.contains { $0.id == entry.id } }
        for entry in matching { entry.continuation.resume() }
    }
}

actor RuntimeLog {
    var entries: [String] = []
    var submitted: [EventOccurrence] = []
    var states: [String: JSONValue] = [:]

    func append(_ entry: String) { entries.append(entry) }
    func submit(_ occurrences: [EventOccurrence]) {
        submitted.append(contentsOf: occurrences)
        entries.append("submit:\(occurrences.count)")
    }
    func save(_ state: JSONValue, _ scope: String) {
        states[scope] = state
        entries.append("save")
    }
    func load(_ scope: String) -> JSONValue? { states[scope] }
    func seed(_ state: JSONValue, _ scope: String) { states[scope] = state }

    nonisolated var host: SourceRuntimeHost {
        SourceRuntimeHost(
            loadState: { await self.load($0) },
            saveState: { await self.save($0, $1) },
            submit: { await self.submit($0) })
    }
}

actor FakeRuntimeDriver: SourceRuntimeDriver {
    var ticks = 0
    var contexts: [SourceTickContext] = []
    var reports: [SourceRuntimeReport] = []
    var connects = 0
    var failTicks = false
    var tickOccurrences = 0
    /// Streams: throw on these connect numbers (1-based); else wait for cancellation.
    var failingConnects: Set<Int> = []

    func setFailTicks(_ value: Bool) { failTicks = value }
    func setTickOccurrences(_ count: Int) { tickOccurrences = count }
    func setFailingConnects(_ value: Set<Int>) { failingConnects = value }

    func tick(_ context: SourceTickContext) async throws -> SourceTickResult {
        ticks += 1
        contexts.append(context)
        if failTicks { throw URLError(.timedOut) }
        let occurrences = (0 ..< tickOccurrences).map { index in
            EventOccurrence(eventId: UUID(), payload: .object(["n": .number(Double(index))]))
        }
        return SourceTickResult(occurrences: occurrences, state: .object(["tick": .number(Double(ticks))]))
    }

    func stream(_ context: SourceStreamContext) async throws {
        connects += 1
        if failingConnects.contains(connects) { throw URLError(.networkConnectionLost) }
        while !Task.isCancelled { try await Task.sleep(nanoseconds: 5_000_000) }
        throw CancellationError()
    }

    func report(_ report: SourceRuntimeReport, scope: String) async {
        reports.append(report)
    }
}

/// A clock the test moves.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0 ..< 600 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

@Suite(.serialized)
struct SourceRuntimeSupervisorTests {
    private func make(_ log: RuntimeLog, _ sleeper: ManualSleeper, clock: TestClock = TestClock())
        -> SourceRuntimeSupervisor
    {
        SourceRuntimeSupervisor(host: log.host, sleeper: sleeper, now: { clock.now }, jitter: { 0 })
    }

    @Test func pollTicksAtOnceThenEveryInterval() async throws {
        let log = RuntimeLog()
        let sleeper = ManualSleeper()
        let driver = FakeRuntimeDriver()
        let supervisor = make(log, sleeper)
        await supervisor.register([SourceRuntimeScope(key: "t:a", mode: .poll(interval: 60), driver: driver)], owner: "t:")

        #expect(await eventually { await driver.ticks == 1 })
        #expect(await eventually { await sleeper.pending == [60] })
        await sleeper.release(60)
        #expect(await eventually { await driver.ticks == 2 })
        let contexts = await driver.contexts
        #expect(contexts.map(\.isFirstTick) == [true, false])
        await supervisor.stopAll()
    }

    @Test func failuresBackOffExponentiallyUpToTheCap() async throws {
        #expect(SourceRuntimeSupervisor.backoff(base: 60, failures: 1) == 120)
        #expect(SourceRuntimeSupervisor.backoff(base: 60, failures: 3) == 480)
        #expect(SourceRuntimeSupervisor.backoff(base: 60, failures: 4) == 900)
        #expect(SourceRuntimeSupervisor.backoff(base: 60, failures: 40) == 900)

        let log = RuntimeLog()
        let sleeper = ManualSleeper()
        let driver = FakeRuntimeDriver()
        await driver.setFailTicks(true)
        let supervisor = make(log, sleeper)
        await supervisor.register([SourceRuntimeScope(key: "t:a", mode: .poll(interval: 60), driver: driver)], owner: "t:")
        #expect(await eventually { await sleeper.pending == [120] })
        await sleeper.release()
        #expect(await eventually { await sleeper.pending == [240] })
        let reports = await driver.reports
        #expect(reports.contains { if case .failed = $0 { true } else { false } })

        // A success resets the wait to the interval.
        await driver.setFailTicks(false)
        await sleeper.release()
        #expect(await eventually { await sleeper.pending == [60] })
        #expect(await log.entries.isEmpty == false)
        await supervisor.stopAll()
    }

    @Test func occurrencesAreSubmittedBeforeTheStateCommits() async throws {
        let log = RuntimeLog()
        let sleeper = ManualSleeper()
        let driver = FakeRuntimeDriver()
        await driver.setTickOccurrences(2)
        let supervisor = make(log, sleeper)
        await supervisor.register([SourceRuntimeScope(key: "t:a", mode: .poll(interval: 60), driver: driver)], owner: "t:")
        #expect(await eventually { await log.entries == ["submit:2", "save"] })
        #expect(await log.states["t:a"] == .object(["tick": .number(1)]))
        await supervisor.stopAll()
    }

    @Test func catchUpPolicyAppliesToTheFirstTickWithSavedState() async throws {
        for (policy, expected) in [(SourceCatchUpPolicy.sinceCursor, 3), (.latestOnly, 1), (.skip, 0)] {
            let log = RuntimeLog()
            await log.seed(.object(["tick": .number(0)]), "t:a")
            let sleeper = ManualSleeper()
            let driver = FakeRuntimeDriver()
            await driver.setTickOccurrences(3)
            let supervisor = make(log, sleeper)
            await supervisor.register(
                [SourceRuntimeScope(key: "t:a", mode: .poll(interval: 60), catchUp: policy, driver: driver)],
                owner: "t:")
            #expect(await eventually { await log.entries.contains("save") })
            #expect(await log.submitted.count == expected, "policy \(policy)")
            // Later ticks are never trimmed.
            await sleeper.release(60)
            #expect(await eventually { await driver.ticks == 2 })
            #expect(await eventually { await log.submitted.count == expected + 3 }, "policy \(policy)")
            await supervisor.stopAll()
        }
    }

    @Test func aScopeWithoutSavedStateIsNotTrimmed() async throws {
        let log = RuntimeLog()
        let sleeper = ManualSleeper()
        let driver = FakeRuntimeDriver()
        await driver.setTickOccurrences(2)
        let supervisor = make(log, sleeper)
        await supervisor.register(
            [SourceRuntimeScope(key: "t:a", mode: .poll(interval: 60), catchUp: .skip, driver: driver)], owner: "t:")
        #expect(await eventually { await log.submitted.count == 2 })
        await supervisor.stopAll()
    }

    @Test func unregisteringAScopeStopsItAndReportsStopped() async throws {
        let log = RuntimeLog()
        let sleeper = ManualSleeper()
        let driver = FakeRuntimeDriver()
        let other = FakeRuntimeDriver()
        let supervisor = make(log, sleeper)
        await supervisor.register(
            [
                SourceRuntimeScope(key: "t:a", mode: .poll(interval: 60), driver: driver),
                SourceRuntimeScope(key: "t:b", mode: .poll(interval: 60), driver: other),
            ], owner: "t:")
        await supervisor.register([SourceRuntimeScope(key: "u:c", mode: .poll(interval: 60), driver: other)], owner: "u:")
        #expect(await eventually { await driver.ticks == 1 })

        await supervisor.register([SourceRuntimeScope(key: "t:b", mode: .poll(interval: 60), driver: other)], owner: "t:")
        #expect(await supervisor.scopeKeys == ["t:b", "u:c"])
        #expect(await eventually { await driver.reports.last == .stopped })
        await sleeper.release()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await driver.ticks == 1)
        await supervisor.stopAll()
    }

    @Test func reRegisteringAnUnchangedScopeKeepsItsSchedule() async throws {
        let log = RuntimeLog()
        let sleeper = ManualSleeper()
        let driver = FakeRuntimeDriver()
        let supervisor = make(log, sleeper)
        let scope = SourceRuntimeScope(key: "t:a", mode: .poll(interval: 60), driver: driver)
        await supervisor.register([scope], owner: "t:")
        #expect(await eventually { await sleeper.pending == [60] })
        await supervisor.register([scope], owner: "t:")
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(await driver.ticks == 1)

        // A new interval restarts the scope, which ticks at once.
        await supervisor.register(
            [SourceRuntimeScope(key: "t:a", mode: .poll(interval: 120), driver: driver)], owner: "t:")
        #expect(await eventually { await driver.ticks == 2 })
        #expect(await supervisor.mode(of: "t:a") == .poll(interval: 120))
        await supervisor.stopAll()
    }

    @Test func tickNowEndsTheWait() async throws {
        let log = RuntimeLog()
        let sleeper = ManualSleeper()
        let driver = FakeRuntimeDriver()
        let supervisor = make(log, sleeper)
        await supervisor.register([SourceRuntimeScope(key: "t:a", mode: .poll(interval: 600), driver: driver)], owner: "t:")
        #expect(await eventually { await sleeper.pending == [600] })
        await supervisor.tickNow("t:a")
        #expect(await eventually { await driver.ticks == 2 })
        await supervisor.stopAll()
    }

    @Test func aFailedStreamReconnectsWithBackoff() async throws {
        let log = RuntimeLog()
        let sleeper = ManualSleeper()
        let driver = FakeRuntimeDriver()
        await driver.setFailingConnects([1])
        let supervisor = make(log, sleeper)
        await supervisor.register(
            [SourceRuntimeScope(key: "t:s", mode: .stream(forcedReconnect: nil, heartbeatTimeout: nil), driver: driver)],
            owner: "t:")
        let firstBackoff = SourceRuntimeSupervisor.backoff(base: SourceRuntimeSupervisor.minInterval, failures: 1)
        #expect(await eventually { await sleeper.pending == [firstBackoff] })
        let reports = await driver.reports
        #expect(reports.contains { if case .disconnected(let error?, _) = $0 { !error.isEmpty } else { false } })
        await sleeper.release(firstBackoff)
        #expect(await eventually { await driver.connects == 2 })
        #expect(await eventually { await driver.reports.last == .connected })
        await supervisor.stopAll()
    }

    @Test func aStreamIsForcedToReconnectPeriodically() async throws {
        let log = RuntimeLog()
        let sleeper = ManualSleeper()
        let driver = FakeRuntimeDriver()
        let supervisor = make(log, sleeper)
        await supervisor.register(
            [SourceRuntimeScope(key: "t:s", mode: .stream(forcedReconnect: 300, heartbeatTimeout: nil), driver: driver)],
            owner: "t:")
        #expect(await eventually { await sleeper.pending == [300] })
        #expect(await driver.connects == 1)
        await sleeper.release(300)
        #expect(await eventually { await driver.connects == 2 })
        #expect(await driver.reports.contains(.disconnected(error: nil, retryAt: TestClock().now)))
        await supervisor.stopAll()
    }

    @Test func maintenanceTicksOnItsIntervalAndNeverTrimsCatchUp() async throws {
        let log = RuntimeLog()
        await log.seed(.object(["tick": .number(0)]), "t:m")
        let sleeper = ManualSleeper()
        let driver = FakeRuntimeDriver()
        await driver.setTickOccurrences(2)
        let supervisor = make(log, sleeper)
        await supervisor.register(
            [SourceRuntimeScope(key: "t:m", mode: .maintenance(interval: 3600), catchUp: .skip, driver: driver)],
            owner: "t:")
        #expect(await eventually { await driver.ticks == 1 })
        #expect(await eventually { await sleeper.pending == [3600] })
        #expect(await log.submitted.count == 2)
        await sleeper.release(3600)
        #expect(await eventually { await driver.ticks == 2 })
        #expect(await supervisor.mode(of: "t:m") == .maintenance(interval: 3600))
        await supervisor.stopAll()
    }

    @Test func aStreamThatMissesItsHeartbeatIsDropped() async throws {
        let log = RuntimeLog()
        let sleeper = ManualSleeper()
        let clock = TestClock()
        let driver = FakeRuntimeDriver()
        let supervisor = make(log, sleeper, clock: clock)
        await supervisor.register(
            [SourceRuntimeScope(key: "t:s", mode: .stream(forcedReconnect: nil, heartbeatTimeout: 10), driver: driver)],
            owner: "t:")
        #expect(await eventually { await sleeper.pending == [5] })
        clock.advance(11)
        await sleeper.release(5)
        #expect(
            await eventually {
                await driver.reports.contains {
                    if case .disconnected(let error?, _) = $0 {
                        error == SourceRuntimeError.heartbeatTimeout.localizedDescription
                    } else {
                        false
                    }
                }
            })
        await supervisor.stopAll()
    }
}
