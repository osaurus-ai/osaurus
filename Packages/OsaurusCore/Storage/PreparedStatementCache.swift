//
//  PreparedStatementCache.swift
//  osaurus
//
//  LRU cache of prepared SQLite3 statements keyed by SQL text. Replaces
//  the unused `cachedStatements: [String: OpaquePointer]` field that
//  every Osaurus `*Database` class had but never populated. Saves a
//  prepare+finalize for every repeated query — the chat-history /
//  memory paths run hundreds of identical statements per session.
//
//  Usage pattern (inside a serial DB queue):
//      let stmt = try cache.statement(for: SQL, on: db)
//      sqlite3_bind_*(stmt, ...)
//      sqlite3_step(stmt)
//      // DO NOT finalize. The cache owns the statement.
//
//  All cached statements are finalized in `clear()` (called from
//  `close()`). The cache is **not** threadsafe on its own — callers
//  must serialize access (typically through their existing dispatch
//  queue or actor).
//

import Foundation
import OsaurusSQLCipher

public final class PreparedStatementCache {
    private struct Entry {
        let statement: OpaquePointer
        var lastUsed: UInt64
    }

    private var entries: [String: Entry] = [:]
    private var tick: UInt64 = 0
    private let capacity: Int

    public init(capacity: Int = 64) {
        self.capacity = capacity
    }

    deinit { clear() }

    /// Return a (cached or freshly prepared) statement bound to `db`.
    /// The returned statement is **reset and rebound-clear** so the
    /// caller can start binding from index 1 immediately.
    public func statement(for sql: String, on db: OpaquePointer) throws -> OpaquePointer {
        tick &+= 1

        if var hit = entries[sql] {
            hit.lastUsed = tick
            entries[sql] = hit
            sqlite3_reset(hit.statement)
            sqlite3_clear_bindings(hit.statement)
            return hit.statement
        }

        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let prepared = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(
                domain: "PreparedStatementCache",
                code: Int(rc),
                userInfo: [NSLocalizedDescriptionKey: "prepare failed: \(msg)"]
            )
        }

        if entries.count >= capacity {
            evictOldest()
        }
        entries[sql] = Entry(statement: prepared, lastUsed: tick)
        return prepared
    }

    /// Drop every cached statement. Safe to call multiple times.
    public func clear() {
        for (_, entry) in entries {
            sqlite3_finalize(entry.statement)
        }
        entries.removeAll(keepingCapacity: false)
    }

    /// Drop the cached statement for `sql` if any. Used by callers that
    /// know a DDL change just happened (rare in our codebase — schema
    /// migrations run before the cache fills).
    public func evict(_ sql: String) {
        guard let entry = entries.removeValue(forKey: sql) else { return }
        sqlite3_finalize(entry.statement)
    }

    public var count: Int { entries.count }

    // MARK: - Private

    private func evictOldest() {
        guard let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed }) else { return }
        sqlite3_finalize(oldest.value.statement)
        entries.removeValue(forKey: oldest.key)
    }
}
