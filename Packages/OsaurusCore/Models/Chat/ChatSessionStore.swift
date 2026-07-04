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
        guard let session = ChatHistoryDatabase.shared.loadSession(id: id) else { return nil }
        let recovered = recoverTranscriptTurnsIfNeeded(session)
        // When turns were re-derived from the Memory transcript (the #1737
        // orphaned-conversation case), persist them back once so later
        // loads/exports read full rows instead of re-deriving every time.
        // Best-effort and only when the DB is already open — never force a
        // Keychain touch on the load path.
        if session.turns.isEmpty, !recovered.turns.isEmpty, didOpen {
            do {
                try ChatHistoryDatabase.shared.saveSession(recovered)
            } catch {
                print("[ChatSessionStore] Failed to heal recovered turns for \(id): \(error)")
            }
        }
        return recovered
    }

    /// Save a session (creates or updates)
    static func save(_ session: ChatSessionData) {
        guard !pendingDeletes.contains(session.id) else { return }
        ensureOpen()
        // When the chat-history DB is deferred (storage key not yet resident or
        // a key rotation is in flight), `ensureOpen()` leaves `didOpen` false.
        // Writing now throws `.notOpen` and silently drops the turns — the
        // #1737 regression where finished conversations couldn't be continued or
        // exported. Queue instead and re-flush once storage becomes ready.
        guard didOpen else {
            pendingSaves[session.id] = session
            return
        }
        do {
            try ChatHistoryDatabase.shared.saveSession(session)
        } catch {
            print("[ChatSessionStore] Failed to save session \(session.id): \(error)")
        }
    }

    /// Sessions whose writes were deferred because the chat-history DB wasn't
    /// open yet. Keyed by id so repeated saves of the same session collapse to
    /// the latest snapshot. Drained by `flushPendingSaves()`.
    private static var pendingSaves: [UUID: ChatSessionData] = [:]
    private static var pendingDeletes: Set<UUID> = []

    /// Re-attempt any saves that were deferred while the chat-history DB was
    /// closed. Call when storage becomes ready (e.g. on the rotation-complete
    /// notification). No-op when nothing is pending or the DB is still deferred.
    static func flushPendingSaves() {
        guard !pendingSaves.isEmpty || !pendingDeletes.isEmpty else { return }
        ensureOpen()
        guard didOpen else { return }
        flushPendingDeletes()
        guard !pendingSaves.isEmpty else { return }
        let drained = pendingSaves
        pendingSaves.removeAll()
        for (id, session) in drained {
            guard !pendingDeletes.contains(id) else { continue }
            do {
                try ChatHistoryDatabase.shared.saveSession(session)
            } catch {
                print("[ChatSessionStore] Failed to flush deferred save \(id): \(error)")
                // Keep it queued for the next readiness signal.
                pendingSaves[id] = session
            }
        }
    }

    /// Delete a session by ID. Also removes the session's artifacts dir
    /// on disk (best-effort) so old shared artifacts don't accumulate.
    static func delete(id: UUID) {
        pendingSaves.removeValue(forKey: id)
        ensureOpen()
        guard didOpen else {
            pendingDeletes.insert(id)
            removeArtifacts(for: id)
            return
        }
        do {
            try ChatHistoryDatabase.shared.deleteSession(id: id)
            pendingDeletes.remove(id)
        } catch {
            pendingDeletes.insert(id)
            print("[ChatSessionStore] Failed to delete session \(id): \(error)")
        }
        removeArtifacts(for: id)
    }

    private static func flushPendingDeletes() {
        guard !pendingDeletes.isEmpty else { return }
        let drained = pendingDeletes
        pendingDeletes.removeAll()
        for id in drained {
            do {
                try ChatHistoryDatabase.shared.deleteSession(id: id)
            } catch {
                pendingDeletes.insert(id)
                print("[ChatSessionStore] Failed to flush deferred delete \(id): \(error)")
                continue
            }
            removeArtifacts(for: id)
        }
    }

    private static func removeArtifacts(for id: UUID) {
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

    static func recoverTranscriptTurnsIfNeeded(
        _ session: ChatSessionData,
        memoryDatabase: MemoryDatabase = .shared
    ) -> ChatSessionData {
        guard session.turns.isEmpty else { return session }
        // Keep launch/load paths non-invasive: transcript fallback never opens
        // Memory on behalf of chat history, because that may touch Keychain.
        guard memoryDatabase.isOpen else { return session }

        do {
            let transcript = try memoryDatabase.loadTranscriptForConversation(
                conversationId: session.id.uuidString
            )
            let recoveredTurns = transcript.compactMap(chatTurnData(from:))
            guard !recoveredTurns.isEmpty else { return session }

            var recovered = session
            // Pure transform — write-back is the caller's job (`load` heals the
            // chat-history row once when the DB is open) so this stays usable
            // from read-only/non-open contexts without mutating storage.
            recovered.turns = recoveredTurns
            return recovered
        } catch {
            print("[ChatSessionStore] Transcript recovery failed for session \(session.id): \(error)")
            return session
        }
    }

    private static func chatTurnData(from transcriptTurn: TranscriptTurn) -> ChatTurnData? {
        let trimmedContent = transcriptTurn.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return nil }
        guard let role = MessageRole(rawValue: transcriptTurn.role) else { return nil }

        return ChatTurnData(
            role: role,
            content: transcriptTurn.content,
            createdAt: transcriptDate(from: transcriptTurn.createdAt)
        )
    }

    private static func transcriptDate(from raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }

        let iso8601Formatter = ISO8601DateFormatter()
        if let date = iso8601Formatter.date(from: raw) {
            return date
        }
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso8601Formatter.date(from: raw) {
            return date
        }

        let sqliteFormatter = DateFormatter()
        sqliteFormatter.locale = Locale(identifier: "en_US_POSIX")
        sqliteFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        sqliteFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return sqliteFormatter.date(from: raw)
    }

    #if DEBUG
        static func _resetForTesting() {
            didOpen = false
            pendingSaves.removeAll()
            pendingDeletes.removeAll()
            ChatHistoryDatabase.shared.close()
        }

        /// Mark the store as already open so save/load skip `ensureOpen()`'s
        /// Keychain-gated path. Pair with `ChatHistoryDatabase.shared.openInMemory()`.
        static func _markStorageOpenForTesting() { didOpen = true }

        /// Seed the deferred-save queue as if a save had been dropped while the
        /// DB was closed, so `flushPendingSaves()` can be exercised directly.
        static func _enqueuePendingSaveForTesting(_ session: ChatSessionData) {
            pendingSaves[session.id] = session
        }

        static func _enqueuePendingDeleteForTesting(_ id: UUID) {
            pendingSaves.removeValue(forKey: id)
            pendingDeletes.insert(id)
        }

        static var _pendingSaveCountForTesting: Int { pendingSaves.count }
        static var _pendingDeleteCountForTesting: Int { pendingDeletes.count }
    #endif
}
