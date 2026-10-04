//
//  InterruptToken.swift
//  OsaurusCore — Subagent framework
//
//  A cheap, thread-safe "stop now" flag the inner loop polls at every
//  boundary. Two paths can trip it:
//    - The parent chat run's Stop/Terminate cancels the tool `Task`; the
//      loop also honors `Task.isCancelled` directly (the BackgroundTaskManager
//      path).
//    - The subagent activity-feed pane's stop button flips this token via
//      `SubagentInterruptCenter`, so a user can halt a run without tearing
//      down the whole chat turn.
//
//  Shared by every subagent kind (spawn / image / computer_use) through
//  `SubagentSession`; the process-wide registry that
//  maps a run's tool-call id to its token is `SubagentInterruptCenter`.
//

import Foundation

/// Thread-safe one-shot interrupt flag.
public final class InterruptToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _interrupted = false
    private var observers: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    public var isInterrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _interrupted
    }

    public func interrupt() {
        lock.lock()
        guard !_interrupted else { lock.unlock(); return }
        _interrupted = true
        let callbacks = Array(observers.values)
        observers.removeAll()
        lock.unlock()
        for callback in callbacks { callback() }
    }

    /// Job-scoped observer. Callbacks always run outside the lock, once per
    /// registration, including immediate delivery after interruption.
    func observeInterrupt(_ callback: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        let alreadyInterrupted = _interrupted
        if !alreadyInterrupted { observers[id] = callback }
        lock.unlock()
        if alreadyInterrupted { callback() }
        return id
    }

    /// Removal cannot retract a callback already captured by interrupt().
    /// Callers must make such a late callback harmless to other jobs.
    func removeInterruptObserver(_ id: UUID) {
        lock.lock()
        observers.removeValue(forKey: id)
        lock.unlock()
    }
}
