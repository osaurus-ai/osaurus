//
//  ChatSessionStore.swift
//  osaurus
//
//  Persistence facade for `ChatSessionData`. Delegates to the SQLite-backed
//  `ChatHistoryDatabase`. The legacy per-session JSON files at
//  `~/.osaurus/sessions/*.json` are imported once on first launch via
//  `LegacySessionImporter` and archived under `~/.osaurus/sessions.archive/`.
//

import Foundation

@MainActor
enum ChatSessionStore {
    // MARK: - Public API

    /// Load all sessions sorted by updatedAt (most recent first).
    /// Only metadata is loaded (turns are empty). Use `load(id:)` for full session data.
    static func loadAll() -> [ChatSessionData] {
        ensureOpenAndImported()
        return ChatHistoryDatabase.shared.loadAllMetadata()
    }

    /// Load a specific session by ID
    static func load(id: UUID) -> ChatSessionData? {
        ensureOpenAndImported()
        return ChatHistoryDatabase.shared.loadSession(id: id)
    }

    /// Save a session (creates or updates)
    static func save(_ session: ChatSessionData) {
        ensureOpenAndImported()
        do {
            try ChatHistoryDatabase.shared.saveSession(session)
        } catch {
            print("[ChatSessionStore] Failed to save session \(session.id): \(error)")
        }
    }

    /// Delete a session by ID. Also removes the session's artifacts dir
    /// on disk (best-effort) so old shared artifacts don't accumulate.
    static func delete(id: UUID) {
        ensureOpenAndImported()
        do {
            try ChatHistoryDatabase.shared.deleteSession(id: id)
        } catch {
            print("[ChatSessionStore] Failed to delete session \(id): \(error)")
        }
        let artifactsDir = OsaurusPaths.contextArtifactsDir(contextId: id.uuidString)
        try? FileManager.default.removeItem(at: artifactsDir)
    }

    // MARK: - Lifecycle

    private static var didOpen = false

    /// Open the database (idempotent) and run the one-time JSON-to-SQLite
    /// import on first call. Safe to invoke from any session-touching code path.
    ///
    /// Gates on `StorageMigrationCoordinator.blockingAwaitReady()` so
    /// SQLCipher never tries to open a still-plaintext file with a key
    /// during the brief window between app launch and migration
    /// completion. Normally a no-op fast-path because the AppDelegate
    /// already awaited the migrator before any UI accepted clicks.
    private static func ensureOpenAndImported() {
        guard !didOpen else { return }
        StorageMigrationCoordinator.blockingAwaitReady()
        didOpen = true
        do {
            try ChatHistoryDatabase.shared.open()
        } catch {
            print("[ChatSessionStore] Failed to open chat-history database: \(error)")
            return
        }
        LegacySessionImporter.runIfNeeded()
    }

    #if DEBUG
        static func _resetForTesting() {
            didOpen = false
            ChatHistoryDatabase.shared.close()
        }
    #endif
}
