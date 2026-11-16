//
//  ConversationStore.swift
//  osaurus
//
//  The storage contract behind `ChatSessionStore` and the headless writers.
//  `SyncConversationStore` implements it. The pre-sync `ChatHistoryDatabase`
//  is a read-only import source and doesn't.
//

import Foundation

protocol ConversationStore: AnyObject, Sendable {
    /// Opens the store. Idempotent; blocks, so main-thread callers defer.
    func open() throws
    /// True when `open()` has finished, without waiting for one in flight.
    var isOpenNonBlocking: Bool { get }

    func saveSession(_ session: ChatSessionData) throws
    /// `onSaved` or `onDropped` fires on a background queue once the write
    /// finished or found the store closed.
    func saveSessionAsync(
        _ session: ChatSessionData,
        onSaved: (@Sendable () -> Void)?,
        onDropped: (@Sendable (ChatSessionData) -> Void)?
    )
    /// Saves again a snapshot whose save failed, as of when it was first
    /// handed over: turns stored since then came from elsewhere and stay.
    func retrySessionSaveAsync(
        _ session: ChatSessionData,
        onSaved: (@Sendable () -> Void)?,
        onDropped: (@Sendable (ChatSessionData) -> Void)?
    )
    func updateSessionTitleAsync(id: UUID, title: String, updatedAt: Date?)
    func updateSessionProjectAsync(id: UUID, projectId: UUID?)
    func clearProjectAsync(projectId: UUID)
    func updateSessionArchivedAsync(id: UUID, archived: Bool)
    func updateSessionPinnedAsync(id: UUID, pinned: Bool)

    func loadSession(id: UUID) -> ChatSessionData?
    /// Every session without turns, most recently updated first.
    func loadAllMetadata() -> [ChatSessionData]
    func loadMetadata(forAgent agentId: UUID?, source: SessionSource?) -> [ChatSessionData]
    func loadMetadata(ids: [UUID]) -> [ChatSessionData]
    func turnCounts(forAgent agentId: UUID?) -> [UUID: Int]
    func sessionIds(withContentContaining text: String) -> Set<UUID>
    func findSession(source: SessionSource, externalKey: String, agentId: UUID?) -> ChatSessionData?
    func findSession(pluginId: String, externalKey: String, agentId: UUID?) -> ChatSessionData?

    func deleteSession(id: UUID) throws
    /// `onDropped` and `completion` fire on a background queue.
    func deleteSessionsAsync(
        ids: [UUID],
        onDropped: (@Sendable ([UUID]) -> Void)?,
        completion: (@Sendable () -> Void)?
    )
}

/// The process's conversation store. Readable from any thread.
enum ConversationStores {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _current: ConversationStore = SyncConversationStore.shared

    static var current: ConversationStore {
        lock.withLock { _current }
    }

    #if DEBUG
        /// Swaps the store for a test; returns the previous one.
        @discardableResult
        static func _setForTesting(_ store: ConversationStore) -> ConversationStore {
            lock.withLock {
                let previous = _current
                _current = store
                return previous
            }
        }
    #endif
}

extension ConversationStore {
    /// Stores without a sync history to compare against save it as usual.
    func retrySessionSaveAsync(
        _ session: ChatSessionData,
        onSaved: (@Sendable () -> Void)?,
        onDropped: (@Sendable (ChatSessionData) -> Void)?
    ) {
        saveSessionAsync(session, onSaved: onSaved, onDropped: onDropped)
    }
}
