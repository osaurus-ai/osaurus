//
//  PersistenceHealth.swift
//  osaurus
//
//  Process-wide, observable degraded-state surface for the persistence
//  layer. Previously, chat-history JSON encode/decode failures were
//  swallowed by `try?` (silently nulling tool_calls / attachments) and
//  launch DB opens used `try?` (silently disabling search). Both failure
//  classes were invisible until a user noticed missing data.
//
//  This store records each such event (count + last message), logs it,
//  and exposes a snapshot that `/health` surfaces so degraded persistence
//  is observable without scraping logs. Thread-safe via
//  `OSAllocatedUnfairLock`; safe to touch from any executor / NIO loop.
//

import Foundation
import os

public final class PersistenceHealth: @unchecked Sendable {
    public static let shared = PersistenceHealth()

    private struct Counters {
        var chatEncodeFailures = 0
        var chatDecodeFailures = 0
        /// Subsystem name → number of times its database failed to open at
        /// launch (so search/index for that subsystem is degraded/disabled).
        var databaseOpenFailures: [String: Int] = [:]
        var lastMessage: String?
        var lastEventAt: Date?
    }

    private let state = OSAllocatedUnfairLock(initialState: Counters())
    private static let logger = Logger(subsystem: "ai.osaurus", category: "PersistenceHealth")

    private init() {}

    // MARK: - Record

    public func recordChatEncodeFailure(_ context: String) {
        state.withLock {
            $0.chatEncodeFailures += 1
            $0.lastMessage = "chat-encode: \(context)"
            $0.lastEventAt = Date()
        }
        Self.logger.error("Chat-history encode failed — persisting null: \(context, privacy: .public)")
    }

    public func recordChatDecodeFailure(_ context: String) {
        state.withLock {
            $0.chatDecodeFailures += 1
            $0.lastMessage = "chat-decode: \(context)"
            $0.lastEventAt = Date()
        }
        Self.logger.error("Chat-history decode failed — dropping field: \(context, privacy: .public)")
    }

    /// Record a launch-time database open failure for `subsystem` (e.g.
    /// "method", "tool"). Surfaces the degraded subsystem in `/health`.
    public func recordDatabaseOpenFailure(subsystem: String, error: Error) {
        state.withLock {
            $0.databaseOpenFailures[subsystem, default: 0] += 1
            $0.lastMessage = "\(subsystem)-db-open: \(error.localizedDescription)"
            $0.lastEventAt = Date()
        }
        Self.logger.error(
            "\(subsystem, privacy: .public) database failed to open — subsystem degraded: \(error.localizedDescription, privacy: .public)"
        )
    }

    // MARK: - Observe

    /// True when any persistence failure has been recorded this session.
    public var isDegraded: Bool {
        state.withLock {
            $0.chatEncodeFailures > 0
                || $0.chatDecodeFailures > 0
                || !$0.databaseOpenFailures.isEmpty
        }
    }

    /// JSON-friendly snapshot for `/health`.
    public func snapshot() -> [String: Any] {
        let c = state.withLock { $0 }
        var obj: [String: Any] = [
            "degraded": c.chatEncodeFailures > 0
                || c.chatDecodeFailures > 0
                || !c.databaseOpenFailures.isEmpty,
            "chat_encode_failures": c.chatEncodeFailures,
            "chat_decode_failures": c.chatDecodeFailures,
            "database_open_failures": c.databaseOpenFailures,
        ]
        obj["last_message"] = c.lastMessage as Any? ?? NSNull()
        obj["last_event_at"] = c.lastEventAt?.ISO8601Format() as Any? ?? NSNull()
        return obj
    }
}
