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

    public init() {}

    public var isInterrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _interrupted
    }

    public func interrupt() {
        lock.lock()
        _interrupted = true
        lock.unlock()
    }
}
