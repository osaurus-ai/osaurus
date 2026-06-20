//
//  InterruptToken.swift
//  OsaurusCore — Computer Use
//
//  A cheap, thread-safe "stop now" flag the loop polls at every boundary.
//  Two paths can trip it:
//    - The parent chat run's Stop/Terminate cancels the tool `Task`; the
//      loop also honors `Task.isCancelled` directly (the BackgroundTaskManager
//      path).
//    - The activity-feed pane's stop button flips this token via
//      `ComputerUseInterruptCenter`, so a user can halt a run without
//      tearing down the whole chat turn.
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

/// Process-wide registry mapping a run's tool-call id to its interrupt
/// token, so the feed pane's stop button can reach the running loop. Mirrors
/// the lightweight singleton pattern used elsewhere (LiveExecRegistry).
public final class ComputerUseInterruptCenter: @unchecked Sendable {
    public static let shared = ComputerUseInterruptCenter()

    private let lock = NSLock()
    private var tokens: [String: InterruptToken] = [:]

    private init() {}

    public func register(_ token: InterruptToken, for toolCallId: String) {
        lock.lock()
        tokens[toolCallId] = token
        lock.unlock()
    }

    public func unregister(_ toolCallId: String) {
        lock.lock()
        tokens.removeValue(forKey: toolCallId)
        lock.unlock()
    }

    /// Trip the token for a run, if one is registered. Returns whether a
    /// token was found.
    @discardableResult
    public func interrupt(_ toolCallId: String) -> Bool {
        lock.lock()
        let token = tokens[toolCallId]
        lock.unlock()
        token?.interrupt()
        return token != nil
    }
}
