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
        // Never park the main thread waiting on a key rotation. Opening chat
        // history isn't launch-critical (`loadAllMetadata` returns [] until the
        // DB is open), and blocking here on a launch/rotation race tripped the
        // app-hang watchdog. Defer when a rotation is in flight on the main
        // thread; `ChatSessionsManager` reloads on the rotation-complete
        // notification. Off-main callers still block as before.
        if Thread.isMainThread, StorageMutationGate.isRotationInFlight {
            print("[ChatSessionStore] Deferring chat-history open: key rotation in flight")
            return
        }
        // `isStorageReadyForWrites` is policy-based and clears for a plaintext
        // posture, but the on-disk file can still be encrypted when the launch
        // migration that converges it hasn't landed yet. Opening it then routes
        // through `currentKey()`'s synchronous Keychain read on the main thread
        // and trips the app-hang watchdog. Defer when the open would need a key
        // we don't already hold; convergence + `ChatSessionsManager`'s reload
        // bring sessions in once the file is plaintext or the key is resident.
        if Thread.isMainThread,
            OsaurusStorageOpener.wouldBlockOnUncachedKey(
                for: OsaurusPaths.chatHistoryDatabaseFile().path
            )
        {
            print("[ChatSessionStore] Deferring chat-history open: storage key not yet resident")
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
