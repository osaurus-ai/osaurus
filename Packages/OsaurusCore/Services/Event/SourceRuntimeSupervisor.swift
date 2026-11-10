//
//  SourceRuntimeSupervisor.swift
//  osaurus
//
//  Runs the long-lived side of pull and connection sources so each adapter
//  only says what to do once per scope (a connection + mailbox, a feed
//  URL, a broker topic). Three modes:
//
//  - poll: tick now, then every interval with jitter; exponential backoff
//    on failure (capped at 15 minutes); catch-up policy on the first tick
//    after launch. The supervisor submits a tick's occurrences, then
//    commits its state, so a cursor never moves past an item that was not
//    ledgered.
//  - stream: a connection the driver owns (IMAP IDLE, SSE, MQTT). The
//    supervisor reconnects with backoff, forces a periodic reconnect, and
//    drops a connection that misses its heartbeat.
//  - maintenance: periodic upkeep (subscription renewal), no catch-up.
//
//  A scope that is no longer registered stops: an adapter pauses a scope
//  by not registering it.
//

import Foundation
import os

enum SourceRuntimeMode: Equatable, Sendable {
    case poll(interval: TimeInterval)
    case stream(forcedReconnect: TimeInterval?, heartbeatTimeout: TimeInterval?)
    case maintenance(interval: TimeInterval)
}

/// What the first poll after launch does with items that arrived while
/// the app was closed.
public enum SourceCatchUpPolicy: String, Codable, CaseIterable, Sendable {
    /// Everything after the saved cursor.
    case sinceCursor = "since_cursor"
    /// Only the newest one.
    case latestOnly = "latest_only"
    /// None; the cursor moves to now.
    case skip

    public var displayName: String {
        switch self {
        case .sinceCursor: L("Everything since last check")
        case .latestOnly: L("Only the newest")
        case .skip: L("Skip what arrived while closed")
        }
    }
}

struct SourceTickContext: Sendable {
    var scope: String
    /// What the last committed tick returned; nil on a scope's first ever tick.
    var state: JSONValue?
    /// First tick since the supervisor started this scope.
    var isFirstTick: Bool
}

struct SourceTickResult: Sendable {
    /// Oldest first.
    var occurrences: [EventOccurrence]
    /// Committed after `occurrences` are submitted; nil keeps the old state.
    var state: JSONValue?

    init(occurrences: [EventOccurrence] = [], state: JSONValue? = nil) {
        self.occurrences = occurrences
        self.state = state
    }
}

struct SourceStreamContext: Sendable {
    var scope: String
    var state: JSONValue?
    /// Submits items, then commits `state` (nil keeps it).
    var emit: @Sendable (_ occurrences: [EventOccurrence], _ state: JSONValue?) async -> Void
    /// Proof of life; a stream with a heartbeat timeout must call it.
    var heartbeat: @Sendable () -> Void
}

/// What the supervisor reports about a scope.
enum SourceRuntimeReport: Equatable, Sendable {
    case ticking
    case ticked(at: Date, next: Date?)
    case failed(at: Date, error: String, next: Date?)
    case connecting
    case connected
    case disconnected(error: String?, retryAt: Date?)
    case stopped
}

enum SourceRuntimeError: LocalizedError, Equatable {
    case unsupported
    case heartbeatTimeout

    var errorDescription: String? {
        switch self {
        case .unsupported: L("This source does not support that mode.")
        case .heartbeatTimeout: L("The connection stopped responding.")
        }
    }
}

/// The adapter side of a scope.
protocol SourceRuntimeDriver: Sendable {
    func tick(_ context: SourceTickContext) async throws -> SourceTickResult
    func stream(_ context: SourceStreamContext) async throws
    func report(_ report: SourceRuntimeReport, scope: String) async
}

extension SourceRuntimeDriver {
    func tick(_ context: SourceTickContext) async throws -> SourceTickResult { throw SourceRuntimeError.unsupported }
    func stream(_ context: SourceStreamContext) async throws { throw SourceRuntimeError.unsupported }
    func report(_ report: SourceRuntimeReport, scope: String) async {}
}

struct SourceRuntimeScope: Sendable {
    var key: String
    var mode: SourceRuntimeMode
    var catchUp: SourceCatchUpPolicy = .sinceCursor
    var driver: any SourceRuntimeDriver
}

/// Where scope state lives and where occurrences go.
struct SourceRuntimeHost: Sendable {
    var loadState: @Sendable (_ scope: String) async -> JSONValue?
    var saveState: @Sendable (_ state: JSONValue, _ scope: String) async -> Void
    var submit: @Sendable (_ occurrences: [EventOccurrence]) async -> Void

    /// Ledger-backed host on `EventManager`.
    @MainActor static func manager(_ manager: EventManager) -> SourceRuntimeHost {
        SourceRuntimeHost(
            loadState: { [weak manager] scope in await manager?.sourceState(scope: scope) },
            saveState: { [weak manager] state, scope in await manager?.setSourceState(state, scope: scope) },
            submit: { [weak manager] occurrences in
                await MainActor.run {
                    for occurrence in occurrences { manager?.submit(occurrence) }
                }
            })
    }
}

actor SourceRuntimeSupervisor {
    static let maxBackoff: TimeInterval = 900
    static let minInterval: TimeInterval = 5
    /// ± fraction of the delay.
    static let jitterFraction = 0.1

    private struct Running {
        var scope: SourceRuntimeScope
        var task: Task<Void, Never>
        var generation: Int
    }

    private let host: SourceRuntimeHost
    private let sleeper: any AgentChannelTransportSleeping
    private let now: @Sendable () -> Date
    private let jitter: @Sendable () -> Double
    private struct Waiter {
        var token: UUID
        var continuation: CheckedContinuation<Void, Never>
        var timer: Task<Void, Never>

        func resume() {
            timer.cancel()
            continuation.resume()
        }
    }

    private var running: [String: Running] = [:]
    private var generation = 0
    /// Scopes sleeping until their next tick.
    private var wakeups: [String: Waiter] = [:]

    init(
        host: SourceRuntimeHost,
        sleeper: any AgentChannelTransportSleeping = AgentChannelTransportTaskSleeper(),
        now: @escaping @Sendable () -> Date = { Date() },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: -1 ... 1) }
    ) {
        self.host = host
        self.sleeper = sleeper
        self.now = now
        self.jitter = jitter
    }

    var scopeKeys: Set<String> { Set(running.keys) }

    func mode(of key: String) -> SourceRuntimeMode? { running[key]?.scope.mode }

    /// Makes `scopes` the running set for `owner`'s prefix: new scopes start
    /// (and tick at once), changed modes restart, missing ones stop. An
    /// unchanged scope keeps its schedule and picks up the new driver.
    func register(_ scopes: [SourceRuntimeScope], owner prefix: String) {
        let wanted = Dictionary(scopes.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        for key in running.keys where key.hasPrefix(prefix) && wanted[key] == nil {
            stop(key)
        }
        for (key, scope) in wanted {
            if var existing = running[key], existing.scope.mode == scope.mode, existing.scope.catchUp == scope.catchUp {
                existing.scope = scope
                running[key] = existing
                continue
            }
            if running[key] != nil { stop(key) }
            start(scope)
        }
    }

    func stopAll() {
        for key in Array(running.keys) { stop(key) }
    }

    /// Ends the wait before a scope's next tick.
    func tickNow(_ key: String) {
        wakeups.removeValue(forKey: key)?.resume()
    }

    // MARK: - Lifecycle

    private func start(_ scope: SourceRuntimeScope) {
        generation += 1
        let gen = generation
        let task = Task { [weak self] in
            guard let self else { return }
            switch scope.mode {
            case .poll(let interval), .maintenance(let interval):
                await self.runTicks(key: scope.key, interval: interval, generation: gen)
            case .stream(let forced, let heartbeat):
                await self.runStream(key: scope.key, forcedReconnect: forced, heartbeatTimeout: heartbeat, generation: gen)
            }
        }
        running[scope.key] = Running(scope: scope, task: task, generation: gen)
    }

    private func stop(_ key: String) {
        guard let entry = running.removeValue(forKey: key) else { return }
        entry.task.cancel()
        wakeups.removeValue(forKey: key)?.resume()
        let driver = entry.scope.driver
        Task { await driver.report(.stopped, scope: key) }
    }

    private func current(_ key: String, _ generation: Int) -> SourceRuntimeScope? {
        guard let entry = running[key], entry.generation == generation, !Task.isCancelled else { return nil }
        return entry.scope
    }

    // MARK: - Poll / maintenance

    private func runTicks(key: String, interval: TimeInterval, generation: Int) async {
        let base = max(interval, Self.minInterval)
        var failures = 0
        var isFirst = true
        while let scope = current(key, generation) {
            await scope.driver.report(.ticking, scope: key)
            let state = await host.loadState(key)
            let delay: TimeInterval
            do {
                let result = try await scope.driver.tick(
                    SourceTickContext(scope: key, state: state, isFirstTick: isFirst))
                guard current(key, generation) != nil else { return }
                let occurrences: [EventOccurrence]
                if case .poll = scope.mode, isFirst, state != nil {
                    occurrences = Self.applyCatchUp(scope.catchUp, to: result.occurrences)
                } else {
                    occurrences = result.occurrences
                }
                if !occurrences.isEmpty { await host.submit(occurrences) }
                if let next = result.state { await host.saveState(next, key) }
                failures = 0
                delay = jittered(base)
                await scope.driver.report(.ticked(at: now(), next: now().addingTimeInterval(delay)), scope: key)
            } catch {
                guard current(key, generation) != nil else { return }
                failures += 1
                delay = jittered(Self.backoff(base: base, failures: failures))
                await scope.driver.report(
                    .failed(at: now(), error: error.localizedDescription, next: now().addingTimeInterval(delay)),
                    scope: key)
            }
            isFirst = false
            await wait(delay, key: key, generation: generation)
        }
    }

    nonisolated static func applyCatchUp(_ policy: SourceCatchUpPolicy, to occurrences: [EventOccurrence])
        -> [EventOccurrence]
    {
        switch policy {
        case .sinceCursor: occurrences
        case .latestOnly: occurrences.last.map { [$0] } ?? []
        case .skip: []
        }
    }

    nonisolated static func backoff(base: TimeInterval, failures: Int) -> TimeInterval {
        guard failures > 0 else { return base }
        let exponent = Double(min(failures, 16))
        return min(base * pow(2, exponent), maxBackoff)
    }

    private func jittered(_ delay: TimeInterval) -> TimeInterval {
        max(Self.minInterval / 2, delay * (1 + Self.jitterFraction * jitter()))
    }

    /// Sleeps `delay` unless `tickNow` or `stop` ends the wait first.
    private func wait(_ delay: TimeInterval, key: String, generation: Int) async {
        guard current(key, generation) != nil else { return }
        let sleeper = self.sleeper
        let token = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let timer = Task { [weak self] in
                try? await sleeper.sleep(for: delay)
                await self?.wake(key, token: token)
            }
            wakeups[key] = Waiter(token: token, continuation: continuation, timer: timer)
        }
    }

    /// The timer's wake-up; a no-op when `tickNow` or `stop` got there first.
    private func wake(_ key: String, token: UUID) {
        guard wakeups[key]?.token == token else { return }
        wakeups.removeValue(forKey: key)?.resume()
    }

    // MARK: - Stream

    private func runStream(
        key: String, forcedReconnect: TimeInterval?, heartbeatTimeout: TimeInterval?, generation: Int
    ) async {
        var failures = 0
        while let scope = current(key, generation) {
            await scope.driver.report(.connecting, scope: key)
            let state = await host.loadState(key)
            let host = self.host
            let beat = OSAllocatedUnfairLock(initialState: now())
            let clock = now
            let context = SourceStreamContext(
                scope: key, state: state,
                emit: { occurrences, next in
                    if !occurrences.isEmpty { await host.submit(occurrences) }
                    if let next { await host.saveState(next, key) }
                },
                heartbeat: { beat.withLock { $0 = clock() } })
            await scope.driver.report(.connected, scope: key)
            var streamError: Error?
            do {
                try await Self.superviseStream(
                    driver: scope.driver, context: context, forcedReconnect: forcedReconnect,
                    heartbeatTimeout: heartbeatTimeout, lastBeat: beat, now: clock, sleeper: sleeper)
            } catch {
                streamError = error
            }
            guard current(key, generation) != nil else { return }
            let delay: TimeInterval
            if let streamError, !(streamError is CancellationError) {
                failures += 1
                delay = jittered(Self.backoff(base: Self.minInterval, failures: failures))
                await scope.driver.report(
                    .disconnected(error: streamError.localizedDescription, retryAt: now().addingTimeInterval(delay)),
                    scope: key)
            } else {
                // A clean end or a forced reconnect: reconnect promptly.
                failures = 0
                delay = 0
                await scope.driver.report(.disconnected(error: nil, retryAt: now()), scope: key)
            }
            if delay > 0 { await wait(delay, key: key, generation: generation) }
        }
    }

    /// Runs one connection until it ends, the forced-reconnect timer fires
    /// (a clean return) or the heartbeat lapses (throws).
    private nonisolated static func superviseStream(
        driver: any SourceRuntimeDriver, context: SourceStreamContext, forcedReconnect: TimeInterval?,
        heartbeatTimeout: TimeInterval?, lastBeat: OSAllocatedUnfairLock<Date>, now: @escaping @Sendable () -> Date,
        sleeper: any AgentChannelTransportSleeping
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await driver.stream(context) }
            if let forcedReconnect, forcedReconnect > 0 {
                group.addTask { try await sleeper.sleep(for: forcedReconnect) }
            }
            if let heartbeatTimeout, heartbeatTimeout > 0 {
                group.addTask {
                    while true {
                        try await sleeper.sleep(for: heartbeatTimeout / 2)
                        try Task.checkCancellation()
                        let last = lastBeat.withLock { $0 }
                        if now().timeIntervalSince(last) > heartbeatTimeout {
                            throw SourceRuntimeError.heartbeatTimeout
                        }
                    }
                }
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}
