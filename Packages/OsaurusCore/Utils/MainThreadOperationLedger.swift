//
//  MainThreadOperationLedger.swift
//  osaurus
//
//  Atomic ledger of potentially-blocking operations currently executing on
//  the main thread. When `MainThreadWatchdog` detects a stall it snapshots
//  this ledger, so the diagnostic names the operation that was in flight
//  ("keychain read", "chat-history loadSession") instead of the previous
//  generic "main thread blocked" line that Sentry triage could do nothing
//  with — and unrelated hangs stop collapsing into one omnibus issue group.
//
//  Entries are privacy-safe by contract: subsystem + operation identifiers
//  only, never user content, paths, account names, or secrets.
//
//  Overhead: one lock acquisition and a dictionary insert/remove per
//  instrumented call, paid ONLY on the main thread (callers should check
//  `Thread.isMainThread` first or use `withMainThreadOperation`, which
//  bypasses the ledger entirely off-main).
//

import Foundation
import os

public final class MainThreadOperationLedger: @unchecked Sendable {
    public static let shared = MainThreadOperationLedger()

    /// One in-flight (or breached) main-thread operation.
    public struct Entry: Sendable, Codable {
        public let id: UInt64
        public let subsystem: String
        public let operation: String
        public let startedAt: Date

        public func ageSeconds(now: Date = Date()) -> TimeInterval {
            max(0, now.timeIntervalSince(startedAt))
        }
    }

    /// Opaque handle returned by `begin`; pass to `end`.
    public struct Token: Sendable {
        fileprivate let id: UInt64
    }

    private let lock = NSLock()
    private var active: [UInt64: Entry] = [:]
    private var nextID: UInt64 = 1

    private static let signposter = OSSignposter(
        subsystem: "com.dinoki.osaurus", category: "MainThreadOperation"
    )
    private var signpostStates: [UInt64: OSSignpostIntervalState] = [:]

    init() {}

    // MARK: - Recording

    /// Record the start of a potentially-blocking main-thread operation.
    /// `subsystem`/`operation` must be static, privacy-safe identifiers.
    public func begin(subsystem: String, operation: String) -> Token {
        lock.lock()
        let id = nextID
        nextID &+= 1
        active[id] = Entry(id: id, subsystem: subsystem, operation: operation, startedAt: Date())
        lock.unlock()

        let state = Self.signposter.beginInterval(
            "op", id: Self.signposter.makeSignpostID(),
            "\(subsystem, privacy: .public).\(operation, privacy: .public)"
        )
        lock.lock()
        signpostStates[id] = state
        lock.unlock()
        return Token(id: id)
    }

    public func end(_ token: Token) {
        lock.lock()
        active.removeValue(forKey: token.id)
        let state = signpostStates.removeValue(forKey: token.id)
        lock.unlock()
        if let state {
            Self.signposter.endInterval("op", state)
        }
    }

    /// Run `body` recorded in the ledger — but only when already on the main
    /// thread. Off-main callers pay nothing (blocking off-main is not a
    /// hang). This is the intended instrumentation point for shared code
    /// like Keychain reads that legitimately runs on both.
    public func withMainThreadOperation<T>(
        subsystem: String, operation: String, _ body: () throws -> T
    ) rethrows -> T {
        guard Thread.isMainThread else { return try body() }
        let token = begin(subsystem: subsystem, operation: operation)
        defer { end(token) }
        return try body()
    }

    // MARK: - Inspection

    /// All in-flight entries, oldest first.
    public func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return active.values.sorted { $0.startedAt < $1.startedAt }
    }

    /// The longest-running in-flight entry, if any — the watchdog's primary
    /// suspect when the main thread breaches its budget.
    public func oldestActive() -> Entry? {
        snapshot().first
    }
}
