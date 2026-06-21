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

/// Why a storage open failed, classified for actionable recovery UI.
public enum StorageOpenIssueKind: String, Sendable {
    /// Encrypted store whose key is unavailable (Keychain miss, re-sign, or
    /// Mac migration). Recoverable: restore the key or reset the store.
    case locked
    /// File is not a valid database for the attempted format (corruption or
    /// a key/HMAC mismatch). Recoverable only by reset/restore.
    case corrupt
    /// Schema migration failed (e.g. forward-version or a broken migration).
    case migration
    /// Anything else.
    case unknown

    /// Best-effort classification from a thrown open/migration error.
    public static func classify(_ error: Error) -> StorageOpenIssueKind {
        if error is StorageKeyError { return .locked }
        let msg = error.localizedDescription.lowercased()
        if msg.contains("migration") || msg.contains("schema v") { return .migration }
        if msg.contains("key verification") || msg.contains("hmac") { return .locked }
        if msg.contains("not a database") || msg.contains("notadb")
            || msg.contains("malformed") || msg.contains("encrypted or is not a database")
        {
            return .corrupt
        }
        return .unknown
    }
}

/// A per-store open failure with enough context for the recovery UI.
public struct StorageStoreIssue: Sendable {
    public let store: String
    public let kind: StorageOpenIssueKind
    public let message: String
    public let path: String?
    public let at: Date
}

public final class PersistenceHealth: @unchecked Sendable {
    public static let shared = PersistenceHealth()

    private struct Counters {
        var chatEncodeFailures = 0
        var chatDecodeFailures = 0
        /// Subsystem name → number of times its database failed to open at
        /// launch (so search/index for that subsystem is degraded/disabled).
        var databaseOpenFailures: [String: Int] = [:]
        /// Subsystem name → its most recent classified open issue. Cleared on
        /// successful recovery so the diagnostics/settings UI stays accurate.
        var storeIssues: [String: StorageStoreIssue] = [:]
        /// Informational (NON-degraded) notes keyed by topic, e.g. the storage
        /// posture decision or the last convergence summary. Surfaced in the
        /// `/health` snapshot for fleet observability but never flips
        /// `isDegraded`, so a normal "kept encrypted" launch isn't reported as
        /// a problem.
        var infoNotes: [String: String] = [:]
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
    /// "method", "tool"). Surfaces the degraded subsystem in `/health` and
    /// classifies the cause for the recovery UI.
    public func recordDatabaseOpenFailure(subsystem: String, error: Error, path: String? = nil) {
        let kind = StorageOpenIssueKind.classify(error)
        state.withLock {
            $0.databaseOpenFailures[subsystem, default: 0] += 1
            $0.storeIssues[subsystem] = StorageStoreIssue(
                store: subsystem,
                kind: kind,
                message: error.localizedDescription,
                path: path,
                at: Date()
            )
            $0.lastMessage = "\(subsystem)-db-open: \(error.localizedDescription)"
            $0.lastEventAt = Date()
        }
        Self.logger.error(
            "\(subsystem, privacy: .public) database failed to open (\(kind.rawValue, privacy: .public)) — subsystem degraded: \(error.localizedDescription, privacy: .public)"
        )
    }

    /// Record a classified store issue directly (e.g. a "locked" store found
    /// during convergence, before any `open()` was attempted).
    public func recordStoreIssue(
        store: String,
        kind: StorageOpenIssueKind,
        message: String,
        path: String? = nil
    ) {
        state.withLock {
            $0.storeIssues[store] = StorageStoreIssue(
                store: store,
                kind: kind,
                message: message,
                path: path,
                at: Date()
            )
            $0.lastMessage = "\(store): \(kind.rawValue): \(message)"
            $0.lastEventAt = Date()
        }
        Self.logger.error(
            "storage store \(store, privacy: .public) issue (\(kind.rawValue, privacy: .public)): \(message, privacy: .public)"
        )
    }

    /// Clear a store's recorded issue after a successful recovery/reopen.
    public func clearStoreIssue(store: String) {
        state.withLock { _ = $0.storeIssues.removeValue(forKey: store) }
    }

    /// Record an informational, non-degraded note (e.g. the resolved storage
    /// posture or the last launch convergence summary). Overwrites any prior
    /// note for `key`. Does NOT affect `isDegraded`; purely for `/health`
    /// observability across the fleet.
    public func recordInfo(key: String, message: String) {
        state.withLock {
            $0.infoNotes[key] = message
        }
        Self.logger.info(
            "storage info \(key, privacy: .public): \(message, privacy: .public)"
        )
    }

    /// The current informational notes (for diagnostics/tests).
    public func infoNotes() -> [String: String] {
        state.withLock { $0.infoNotes }
    }

    // MARK: - Observe

    /// True when any persistence failure has been recorded this session.
    public var isDegraded: Bool {
        state.withLock {
            $0.chatEncodeFailures > 0
                || $0.chatDecodeFailures > 0
                || !$0.databaseOpenFailures.isEmpty
                || !$0.storeIssues.isEmpty
        }
    }

    /// Every currently-unresolved per-store issue.
    public func storeIssues() -> [StorageStoreIssue] {
        state.withLock { Array($0.storeIssues.values) }
    }

    /// The current issue for `store`, if any.
    public func storeIssue(for store: String) -> StorageStoreIssue? {
        state.withLock { $0.storeIssues[store] }
    }

    /// JSON-friendly snapshot for `/health`.
    public func snapshot() -> [String: Any] {
        let c = state.withLock { $0 }
        var obj: [String: Any] = [
            "degraded": c.chatEncodeFailures > 0
                || c.chatDecodeFailures > 0
                || !c.databaseOpenFailures.isEmpty
                || !c.storeIssues.isEmpty,
            "chat_encode_failures": c.chatEncodeFailures,
            "chat_decode_failures": c.chatDecodeFailures,
            "database_open_failures": c.databaseOpenFailures,
        ]
        if !c.storeIssues.isEmpty {
            obj["store_issues"] = c.storeIssues.mapValues { issue in
                ["kind": issue.kind.rawValue, "message": issue.message]
            }
        }
        if !c.infoNotes.isEmpty {
            obj["info"] = c.infoNotes
        }
        obj["last_message"] = c.lastMessage as Any? ?? NSNull()
        obj["last_event_at"] = c.lastEventAt?.ISO8601Format() as Any? ?? NSNull()
        return obj
    }
}
