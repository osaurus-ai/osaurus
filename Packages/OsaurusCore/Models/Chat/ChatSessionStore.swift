//
//  ChatSessionStore.swift
//  osaurus
//
//  Persistence facade for `ChatSessionData`. Delegates to the SQLite-backed
//  `ChatHistoryDatabase`.
//

import Foundation

@MainActor
enum ChatSessionStore {
    // MARK: - Public API

    /// Load all sessions sorted by updatedAt (most recent first).
    /// Only metadata is loaded (turns are empty). Use `load(id:)` for full session data.
    static func loadAll() -> [ChatSessionData] {
        ensureOpen()
        return ChatHistoryDatabase.shared.loadAllMetadata()
    }

    /// Load a specific session by ID
    static func load(id: UUID) -> ChatSessionData? {
        ensureOpen()
        return ChatHistoryDatabase.shared.loadSession(id: id)
    }

    /// Save a session (creates or updates)
    static func save(_ session: ChatSessionData) {
        ensureOpen()
        do {
            try ChatHistoryDatabase.shared.saveSession(session)
        } catch {
            print("[ChatSessionStore] Failed to save session \(session.id): \(error)")
        }
    }

    /// Delete a session by ID. Also removes the session's artifacts dir
    /// on disk (best-effort) so old shared artifacts don't accumulate.
    static func delete(id: UUID) {
        ensureOpen()
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

    /// Open the database (idempotent) on first call. Safe to invoke from any
    /// session-touching code path.
    ///
    /// Gates on `StorageMutationGate.blockingAwaitNotMutating()` so
    /// SQLCipher never tries to open a half-rekeyed file while a key
    /// rotation is in flight. Normally a no-op fast path.
    private static func ensureOpen() {
        guard !didOpen else { return }
        // Do not synchronously prewarm here. This runs on MainActor, and
        // Sentry APPLE-MACOS-40/41/42 showed Keychain decrypt/read can hang
        // the UI when a cold cache reaches this path. In plaintext mode
        // (the default) no key is required, so readiness is always true.
        guard StorageKeyManager.shared.isStorageReadyForWrites else {
            print("[ChatSessionStore] Chat history unavailable: storage key is not already unlocked")
            return
        }
        StorageMutationGate.blockingAwaitNotMutating()
        didOpen = true
        do {
            try ChatHistoryDatabase.shared.open()
        } catch {
            print("[ChatSessionStore] Failed to open chat-history database: \(error)")
            return
        }
    }

    #if DEBUG
        static func _resetForTesting() {
            didOpen = false
            ChatHistoryDatabase.shared.close()
        }
    #endif
}
