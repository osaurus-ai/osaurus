//
//  AgentDatabaseStore.swift
//  osaurus
//
//  Lifecycle registry for `AgentDatabase` instances. Each agent that
//  has opted in to the Agent DB feature (spec §5.5) gets one
//  connection here, opened lazily on first access and held until the
//  agent is deleted or the host shuts down.
//
//  The store is intentionally minimal — it owns the map, not the
//  policy. Policy (when a connection is opened, who's allowed to
//  write, what the actor is) lives in `LocalAgentBridge`.
//

import CryptoKit
import Foundation
import OsaurusSQLCipher

public final class AgentDatabaseStore: @unchecked Sendable {
    public static let shared = AgentDatabaseStore()

    private let lock = NSLock()
    private var connections: [UUID: AgentDatabase] = [:]

    init() {}

    /// Return the open `AgentDatabase` for `agentId`, opening it if
    /// necessary. The caller is responsible for first verifying that
    /// the agent has `settings.dbEnabled == true`; this store does
    /// not consult `Agent.settings` itself so it can be reused for
    /// tooling that operates regardless of the toggle (e.g. the
    /// migrator, the export bundle, the "Delete agent data" action).
    public func database(for agentId: UUID) throws -> AgentDatabase {
        if let existing = lockedGet(agentId), existing.isOpen {
            return existing
        }

        // Slow path: build a new connection.
        let candidate = AgentDatabase(agentId: agentId)
        try candidate.open()
        // The candidate keeps its default storageBytesLimit (100 MB)
        // until `AgentManager` calls `setStorageLimit(for:bytes:)` with
        // the agent's specific limit. We can't read `Agent.settings`
        // from here without hopping to MainActor and that would
        // deadlock callers already on a serial queue, so the safer
        // policy is "default applies until pushed".

        lock.lock()
        defer { lock.unlock() }
        // Lost the race? Use the winner's connection and discard ours.
        if let winner = connections[agentId], winner.isOpen {
            candidate.close()
            return winner
        }
        connections[agentId] = candidate
        return candidate
    }

    /// Push a fresh storage limit into the (already-cached) connection
    /// for `agentId`. Called by `AgentManager` whenever the user edits
    /// `Agent.settings.limits.storageBytesLimit`, so the next mutation
    /// uses the new value without needing a reconnect.
    public func setStorageLimit(for agentId: UUID, bytes: Int) {
        guard let conn = lockedGet(agentId) else { return }
        conn.setStorageBytesLimit(bytes)
    }

    /// Push a fresh soft-warn percent into the (already-cached)
    /// connection. Same lifecycle as `setStorageLimit`; the DB layer
    /// reads this on its next post-commit quota check (spec §11.2).
    public func setStorageWarnPercent(for agentId: UUID, percent: Int) {
        guard let conn = lockedGet(agentId) else { return }
        conn.setStorageWarnPercent(percent)
    }

    /// Read the cached storage limit for `agentId`. Returns 0 (the
    /// `disabled` sentinel) when the agent has no open connection.
    public func storageLimit(for agentId: UUID) -> Int {
        lockedGet(agentId)?.currentStorageBytesLimit() ?? 0
    }

    /// Read the on-disk file size for the agent's DB. Convenience for
    /// settings UIs ("X MB of Y MB used") without forcing the caller
    /// to open the DB themselves.
    public func storageUsage(for agentId: UUID) -> Int {
        if let conn = lockedGet(agentId) {
            return conn.storageUsedBytes()
        }
        let path = OsaurusPaths.agentDatabaseFile(for: agentId).path
        let fm = FileManager.default
        let main = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        let walPath = path + "-wal"
        let wal = (try? fm.attributesOfItem(atPath: walPath)[.size] as? NSNumber)?.intValue ?? 0
        return main + wal
    }
    private func _readStorageLimitPlaceholder() -> Int? { nil }

    /// Open the DB without returning a reference. Useful at app
    /// launch for agents already opted-in so the WAL files exist.
    public func ensureOpen(for agentId: UUID) throws {
        _ = try database(for: agentId)
    }

    /// Close and forget the cached connection for `agentId`. Safe to
    /// call when there is no cached connection.
    public func close(_ agentId: UUID) {
        lock.lock()
        let conn = connections.removeValue(forKey: agentId)
        lock.unlock()
        conn?.close()
    }

    /// Close every cached connection. Called from host shutdown.
    public func closeAll() {
        lock.lock()
        let snapshot = connections
        connections.removeAll(keepingCapacity: false)
        lock.unlock()
        for (_, conn) in snapshot { conn.close() }
    }

    /// Delete the entire per-agent directory on disk
    /// (`~/.osaurus/agents/<id>/`). Used by the "Delete agent data"
    /// destructive action (spec §5.5.1) and by `AgentStore.delete`
    /// when the whole agent goes away.
    ///
    /// Closes the cached connection first so SQLCipher can release
    /// its locks before we `rm -rf` the WAL files.
    public func deleteOnDisk(for agentId: UUID) throws {
        close(agentId)
        let dir = OsaurusPaths.agentDirectory(for: agentId)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    /// Rotate the per-agent SQLCipher key from `oldKey` to `newKey`
    /// (spec §11.2, Phase 4). Used by:
    ///
    ///  - The bundle import path (rekey from bundle-local key to host
    ///    storage key) — though that flow inlines its own rekey since
    ///    the agent isn't yet registered with this store.
    ///  - A future "set agent passphrase" UI affordance — the same
    ///    helper handles "host key → passphrase-derived key" without
    ///    duplicating the SQLCipher dance.
    ///
    /// The cached connection (if any) is closed before the rekey and
    /// reopened after, so the caller's next `database(for:)` call gets
    /// a fresh handle on the rekeyed file.
    public func rotateKey(
        agentId: UUID,
        from oldKey: SymmetricKey,
        to newKey: SymmetricKey
    ) throws {
        close(agentId)
        let path = OsaurusPaths.agentDatabaseFile(for: agentId).path
        guard FileManager.default.fileExists(atPath: path) else { return }
        let conn = try EncryptedSQLiteOpener.open(
            path: path,
            key: oldKey,
            applyPerfPragmas: false,
            applyForeignKeys: false
        )
        defer { sqlite3_close(conn) }
        try EncryptedSQLiteOpener.rekey(connection: conn, newKey: newKey)
    }

    /// Snapshot of every currently-cached connection (for tests +
    /// diagnostics).
    public func openAgentIds() -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return Array(connections.keys)
    }

    private func lockedGet(_ agentId: UUID) -> AgentDatabase? {
        lock.lock()
        defer { lock.unlock() }
        return connections[agentId]
    }
}
