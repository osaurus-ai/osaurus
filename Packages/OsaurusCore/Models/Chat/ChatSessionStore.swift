//
//  ChatSessionStore.swift
//  osaurus
//
//  Persistence facade for `ChatSessionData`. Delegates to
//  `ConversationStores.current`, the sync-backed `SyncConversationStore`.
//

import Combine
import Foundation

@MainActor
final class ChatPersistenceStatus: ObservableObject {
    static let shared = ChatPersistenceStatus()
    @Published var unsaved: Set<UUID> = []
}

@MainActor
enum ChatSessionStore {
    /// The store every call below goes to.
    private static var store: ConversationStore { ConversationStores.current }

    // MARK: - Public API

    /// Load all sessions sorted by updatedAt (most recent first).
    /// Only metadata is loaded (turns are empty). Use `load(id:)` for full session data.
    static func loadAll() -> [ChatSessionData] {
        ensureOpen()
        var sessions = store.loadAllMetadata()
        // Overlay writes still deferred behind a closed/rotating DB so a
        // notification-driven refresh can't drop a chat the user just
        // created: the disk snapshot doesn't have the row yet, but the
        // pending queue does. Sessions already on disk keep their pending
        // (newer) snapshot; brand-new ones are inserted in recency order.
        guard !pendingSaves.isEmpty else { return sessions }
        for (id, var pending) in pendingSaves {
            pending.turns = []
            if let index = sessions.firstIndex(where: { $0.id == id }) {
                sessions[index] = pending
            } else {
                sessions.append(pending)
            }
        }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Load a specific session by ID
    static func load(id: UUID) -> ChatSessionData? {
        ensureOpen()
        if let pending = pendingSaves[id] { return pending }
        return store.loadSession(id: id)
    }

    /// Metadata rows (turns empty) for the given ids, in one query. Writes
    /// still waiting for the store to open are overlaid so a chat saved
    /// moments ago is not reported missing. Ids with no row are absent.
    static func loadMetadata(ids: [UUID]) -> [ChatSessionData] {
        ensureOpen()
        var byId: [UUID: ChatSessionData] = [:]
        for row in store.loadMetadata(ids: ids) {
            byId[row.id] = row
        }
        for id in ids {
            if var pending = pendingSaves[id] {
                pending.turns = []
                byId[id] = pending
            }
        }
        return ids.compactMap { byId[$0] }
    }

    /// `load(id:)` with the store read off the main actor, for callers on
    /// the interactive path (waking a hibernated tab) that must not park the
    /// main thread behind the store's queue. Same pending-save overlay as the
    /// synchronous load.
    static func loadAsync(id: UUID) async -> ChatSessionData? {
        ensureOpen()
        if let pending = pendingSaves[id] { return pending }
        guard didOpen else { return nil }
        let db = store
        return await Task.detached(priority: .userInitiated, operation: { db.loadSession(id: id) }).value
    }

    /// Session ids whose message bodies contain `text` (case-insensitive
    /// substring). Backs the sidebar's full-text search; returns an empty set
    /// for a blank query or while the store isn't open. The scan itself runs
    /// off the main actor so typing in the search field never blocks on the
    /// store's serial queue.
    static func sessionIds(withContentContaining text: String) async -> Set<UUID> {
        ensureOpen()
        guard didOpen else { return [] }
        let db = store
        return await Task.detached(priority: .userInitiated) {
            db.sessionIds(withContentContaining: text)
        }.value
    }

    /// Save a session (creates or updates)
    static func save(_ session: ChatSessionData) {
        guard !pendingDeletes.contains(session.id) else { return }
        ensureOpen()
        // While the sync core is still opening off the main thread (or failed
        // to open), `ensureOpen()` leaves `didOpen` false. Writing now throws
        // `.notOpen` and silently drops the turns — the #1737 regression where
        // finished conversations couldn't be continued or exported. Queue
        // instead and re-flush once the store opens.
        guard didOpen else {
            pendingSaves[session.id] = session
            return
        }
        do {
            try store.saveSession(session)
        } catch {
            print("[ChatSessionStore] Failed to save session \(session.id): \(error)")
        }
    }

    /// Non-blocking variant of `save`. Hands the write to the store's serial
    /// queue and returns immediately so a main-actor caller never stalls on the
    /// encode and write. Falls back to the same deferred-save queue when the
    /// store isn't open yet, so no write is lost while it opens.
    private static var saveVersions: [UUID: UUID] = [:]
    private static var retryTask: Task<Void, Never>?

    /// `retrying`: the snapshot of a save that failed, tried again (`retryUnsaved`).
    static func saveAsync(_ session: ChatSessionData, retrying: Bool = false) {
        guard !pendingDeletes.contains(session.id) else { return }
        let version = UUID()
        saveVersions[session.id] = version
        pendingSaves[session.id] = session
        ensureOpen()
        guard didOpen else {
            ChatPersistenceStatus.shared.unsaved.insert(session.id)
            scheduleSaveRetry()
            return
        }
        let onSaved: @Sendable () -> Void = {
            Task { @MainActor in
                guard saveVersions[session.id] == version else { return }
                pendingSaves.removeValue(forKey: session.id)
                saveVersions.removeValue(forKey: session.id)
                ChatPersistenceStatus.shared.unsaved.remove(session.id)
            }
        }
        let onDropped: @Sendable (ChatSessionData) -> Void = { dropped in
            Task { @MainActor in
                guard saveVersions[session.id] == version else { return }
                requeueDroppedAsyncSave(dropped)
                ChatPersistenceStatus.shared.unsaved.insert(session.id)
                scheduleSaveRetry()
            }
        }
        if retrying {
            store.retrySessionSaveAsync(session, onSaved: onSaved, onDropped: onDropped)
        } else {
            store.saveSessionAsync(session, onSaved: onSaved, onDropped: onDropped)
        }
    }

    private static func scheduleSaveRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            retryTask = nil
            retryUnsaved()
        }
    }

    static func retryUnsaved() {
        // A failed `open()` must be retried before re-issuing writes —
        // otherwise Retry loops on `saveSessionAsync` against a nil
        // connection (#2736). Off-main / tests open synchronously; the
        // main-actor production path only kicks the background prewarm so
        // we never park the UI on Keychain + migrations. Pending snapshots
        // stay queued and `didOpenNotification` → `flushPendingSaves`.
        if !didOpen {
            if Thread.isMainThread, !RuntimeEnvironment.isUnderTests {
                preloadInBackground()
                return
            }
            ensureOpen()
        }
        guard didOpen else { return }
        for id in ChatPersistenceStatus.shared.unsaved {
            if let data = pendingSaves[id] {
                saveAsync(data, retrying: true)
            }
        }
    }

    /// Re-queue an async save whose write found the store closed at dequeue
    /// time. Skips ids deleted meanwhile and never clobbers a newer pending
    /// snapshot of the same session.
    private static func requeueDroppedAsyncSave(_ session: ChatSessionData) {
        guard !pendingDeletes.contains(session.id) else { return }
        if let existing = pendingSaves[session.id], existing.updatedAt > session.updatedAt {
            return
        }
        pendingSaves[session.id] = session
    }

    /// Title-only async update for the auto-title path. Never routes through
    /// `saveSession`, so a metadata-only session copy (empty `turns`) can't
    /// write its other, possibly stale, fields over the stored session.
    ///
    /// The pending snapshot (if any) is always retitled, not only while the
    /// store is closed: `saveAsync` keeps a session in `pendingSaves` until
    /// its write is acknowledged, and `load(id:)` serves that overlay first. A
    /// rename that only reached the store would otherwise read back stale
    /// until the acknowledgement lands — and a later retry of the stale
    /// snapshot would clobber the rename. While the store is closed and
    /// nothing is queued, the rename is dropped, matching `saveAsync`'s
    /// best-effort contract (the preview title simply stands).
    static func renameTitleAsync(id: UUID, title: String, updatedAt: Date? = nil) {
        guard !pendingDeletes.contains(id) else { return }
        pendingSaves[id]?.title = title
        if let updatedAt { pendingSaves[id]?.updatedAt = updatedAt }
        ensureOpen()
        guard didOpen else { return }
        store.updateSessionTitleAsync(
            id: id,
            title: title,
            updatedAt: updatedAt
        )
    }

    /// Flag-only async updates for the sidebar's archive/pin toggles. Same
    /// contract as `renameTitleAsync`: a targeted update that never touches
    /// messages, handed to the store's serial queue, with the in-flight
    /// pending snapshot patched to match.
    static func setArchivedAsync(id: UUID, archived: Bool) {
        guard !pendingDeletes.contains(id) else { return }
        pendingSaves[id]?.archived = archived
        ensureOpen()
        guard didOpen else { return }
        store.updateSessionArchivedAsync(id: id, archived: archived)
    }

    static func setPinnedAsync(id: UUID, pinned: Bool) {
        guard !pendingDeletes.contains(id) else { return }
        pendingSaves[id]?.pinned = pinned
        ensureOpen()
        guard didOpen else { return }
        store.updateSessionPinnedAsync(id: id, pinned: pinned)
    }

    /// Project-membership-only async update. Targeted (never `saveSession`)
    /// for the same metadata-only-copy reason as `renameTitleAsync`.
    static func setProjectAsync(id: UUID, projectId: UUID?) {
        guard !pendingDeletes.contains(id) else { return }
        pendingSaves[id]?.projectId = projectId
        ensureOpen()
        guard didOpen else { return }
        store.updateSessionProjectAsync(id: id, projectId: projectId)
    }

    /// Detach every session from a deleted project. Best-effort while the
    /// store is closed, matching `setProjectAsync`; pending snapshots are patched in place.
    static func clearProjectAsync(projectId: UUID) {
        for (id, session) in pendingSaves where session.projectId == projectId {
            pendingSaves[id]?.projectId = nil
        }
        ensureOpen()
        guard didOpen else { return }
        store.clearProjectAsync(projectId: projectId)
    }

    /// Sessions whose writes were deferred because the store wasn't open
    /// yet. Keyed by id so repeated saves of the same session collapse to
    /// the latest snapshot. Drained by `flushPendingSaves()`.
    private static var pendingSaves: [UUID: ChatSessionData] = [:]
    private static var pendingDeletes: Set<UUID> = []

    /// Re-attempt any saves that were deferred while the store was closed.
    /// Call once it opens (`SyncService.didOpenNotification`). No-op when
    /// nothing is pending or the store is still closed.
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
                try store.saveSession(session)
                saveVersions.removeValue(forKey: id)
                ChatPersistenceStatus.shared.unsaved.remove(id)
            } catch {
                ChatPersistenceStatus.shared.unsaved.insert(id)
                scheduleSaveRetry()
                print("[ChatSessionStore] Failed to flush deferred save \(id): \(error)")
                // Keep it queued for the next readiness signal.
                pendingSaves[id] = session
            }
        }
    }

    /// Delete a session by ID. Also removes the session's artifacts dir
    /// on disk (best-effort) so old shared artifacts don't accumulate.
    static func delete(id: UUID) {
        saveVersions.removeValue(forKey: id)
        ChatPersistenceStatus.shared.unsaved.remove(id)
        pendingSaves.removeValue(forKey: id)
        ensureOpen()
        guard didOpen else {
            pendingDeletes.insert(id)
            removeArtifacts(for: id)
            return
        }
        do {
            try store.deleteSession(id: id)
            pendingDeletes.remove(id)
        } catch {
            pendingDeletes.insert(id)
            print("[ChatSessionStore] Failed to delete session \(id): \(error)")
        }
        removeArtifacts(for: id)
    }

    /// Bulk delete for the per-agent wipe. Unlike `delete(id:)`, the
    /// conversations are removed behind one background hop on the store's
    /// queue and the artifact directories are removed off the main thread, so
    /// wiping a large history can't trip the app-hang watchdog. `completion`
    /// is invoked on the main actor once the batch has finished.
    static func deleteBatch(ids: [UUID], completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard !ids.isEmpty else {
            completion?()
            return
        }
        for id in ids {
            pendingSaves.removeValue(forKey: id)
        }
        Task.detached(priority: .utility) {
            for id in ids {
                let artifactsDir = OsaurusPaths.contextArtifactsDir(contextId: id.uuidString)
                try? FileManager.default.removeItem(at: artifactsDir)
            }
        }
        ensureOpen()
        guard didOpen else {
            pendingDeletes.formUnion(ids)
            completion?()
            return
        }
        store.deleteSessionsAsync(
            ids: ids,
            onDropped: { dropped in
                // Same launch-race recovery as `delete(id:)`: the store
                // closed between enqueue and dequeue (a reopen or sign-out),
                // so requeue the ids for the next open.
                Task { @MainActor in pendingDeletes.formUnion(dropped) }
            },
            completion: {
                Task { @MainActor in completion?() }
            }
        )
    }

    private static func flushPendingDeletes() {
        guard !pendingDeletes.isEmpty else { return }
        let drained = pendingDeletes
        pendingDeletes.removeAll()
        for id in drained {
            do {
                try store.deleteSession(id: id)
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

    /// Opens the sync core off the main thread so the first window's
    /// synchronous `loadAll()` finds it ready.
    nonisolated static func preloadInBackground() {
        SyncService.shared.openInBackground()
    }

    /// Opens the store on first use. The sync core opens off the main thread
    /// (Keychain and database work); `ChatSessionsManager` reloads on
    /// `SyncService.didOpenNotification`. Tests open synchronously.
    private static func ensureOpen() {
        guard !didOpen else { return }
        #if DEBUG
            if _forceNextOpenFailureForTesting {
                _forceNextOpenFailureForTesting = false
                return
            }
        #endif
        if store.isOpenNonBlocking {
            didOpen = true
            return
        }
        if Thread.isMainThread, !RuntimeEnvironment.isUnderTests {
            SyncService.shared.openInBackground()
            return
        }
        do {
            try store.open()
            didOpen = true
        } catch {
            print("[ChatSessionStore] Failed to open conversation store: \(error)")
        }
    }

    #if DEBUG
        static var _forceNextOpenFailureForTesting = false
        static var _didOpenForTesting: Bool { didOpen }

        static func _resetForTesting() {
            didOpen = false
            _forceNextOpenFailureForTesting = false
            retryTask?.cancel()
            retryTask = nil
            saveVersions.removeAll()
            ChatPersistenceStatus.shared.unsaved.removeAll()
            pendingSaves.removeAll()
            pendingDeletes.removeAll()
            ChatHistoryDatabase.shared.close()
            SyncConversationStore.shared._resetForTesting()
            SyncService.shared._resetForTesting()
        }

        /// Mark the store as already open so save/load skip `ensureOpen()`.
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
        static func _hasPendingSaveForTesting(_ id: UUID) -> Bool { pendingSaves[id] != nil }
        static var _pendingDeleteCountForTesting: Int { pendingDeletes.count }
    #endif
}
