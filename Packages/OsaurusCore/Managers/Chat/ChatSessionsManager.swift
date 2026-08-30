//
//  ChatSessionsManager.swift
//  osaurus
//
//  Manages chat session list and persistence
//

import Combine
import Foundation
import SwiftUI

/// Manages all chat sessions and their persistence
@MainActor
final class ChatSessionsManager: ObservableObject {
    static let shared = ChatSessionsManager()

    /// All sessions sorted by updatedAt (most recent first)
    @Published private(set) var sessions: [ChatSessionData] = []

    /// Currently selected session ID
    @Published var currentSessionId: UUID?

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        // Load synchronously so the first reader (ChatWindowState.init)
        // sees populated sessions. Deferring this via Task caused the
        // sidebar to render empty on first open until something else
        // (New Chat, agent switch) triggered a manual refresh.
        sessions = ChatSessionStore.loadAll()

        // Production-only launch-race recovery: if the initial load raced a
        // key rotation, `ChatSessionStore` deferred the DB open rather than
        // parking the launch main thread, leaving `sessions` empty. Reload
        // once the rotation settles. Armed only when the initial load came
        // back empty, and never under tests — a rotation in an unrelated suite
        // must not trigger a stray cross-suite DB reload on the main actor (see
        // RuntimeEnvironment.isUnderTests for the prior contactsd
        // main-actor-stall incident).
        //
        // The same rotation-complete signal also drains any turn writes that
        // `ChatSessionStore` had to defer while the DB was closed (#1737), so
        // arm the observer whenever the initial open could have been deferred —
        // not only when the list came back empty. Still never under tests, to
        // avoid a stray cross-suite DB reload on the main actor.
        if !RuntimeEnvironment.isUnderTests {
            NotificationCenter.default.publisher(for: StorageMutationGate.didFinishMutatingNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    ChatSessionStore.flushPendingSaves()
                    self?.refresh()
                }
                .store(in: &cancellables)

            // The initial load can also be deferred because the background
            // prewarm was still mid-open (ChatSessionStore.ensureOpen no
            // longer waits behind an in-flight open on the main thread).
            // Reload once the database reports open.
            NotificationCenter.default.publisher(for: ChatHistoryDatabase.didOpenNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    ChatSessionStore.flushPendingSaves()
                    self?.refresh()
                }
                .store(in: &cancellables)
        }
    }

    // MARK: - Public API

    /// Full reload from disk — prefer `save()`/`delete()` for single-session mutations.
    func refresh() {
        sessions = ChatSessionStore.loadAll()
    }

    /// Create a new session and return its ID
    @discardableResult
    func createNew(selectedModel: String? = nil, agentId: UUID? = nil) -> UUID {
        let session = ChatSessionData(
            id: UUID(),
            title: "New Chat",
            createdAt: Date(),
            updatedAt: Date(),
            selectedModel: selectedModel,
            turns: [],
            agentId: agentId
        )
        // Async write is safe for a brand-new session: `turns` is genuinely
        // empty (nothing to delete) and the in-memory upsert keeps the
        // sidebar correct immediately.
        ChatSessionStore.saveAsync(session)
        upsertInMemory(session)
        return session.id
    }

    /// Get sessions filtered by agent
    /// - Parameter agentId: The agent ID to filter by.
    ///   When Default agent (or nil) is selected, returns ALL sessions from all agents.
    ///   Otherwise returns only sessions belonging to the specified agent.
    func sessions(for agentId: UUID?) -> [ChatSessionData] {
        // When Default agent is selected, show ALL sessions
        if agentId == nil || agentId == Agent.defaultId {
            return sessions
        }
        // Otherwise filter by agent
        return sessions.filter { $0.agentId == agentId }
    }

    /// Save a session (updates the in-memory list without full disk reload)
    func save(_ session: ChatSessionData) {
        ChatSessionStore.save(session)
        upsertInMemory(session)
    }

    /// Non-blocking save. Updates the in-memory list synchronously (so the
    /// recent-sessions UI is correct immediately) but hands the disk write to
    /// the database's serial queue. Use from main-actor hot paths like run
    /// cleanup where a synchronous encode + DB transaction on a large
    /// conversation can trip the app-hang watchdog.
    func saveAsync(_ session: ChatSessionData) {
        ChatSessionStore.saveAsync(session)
        upsertInMemory(session)
    }

    /// Delete a session by ID
    func delete(id: UUID) {
        ChatSessionStore.delete(id: id)
        if currentSessionId == id {
            currentSessionId = nil
        }
        sessions.removeAll { $0.id == id }
        // Drop the session's tracked sandbox changes + baseline snapshot
        // (the DB rows cascade in deleteSession; this clears the in-memory
        // cache, pending background-job records, and baseline clone).
        Task { await SandboxWorkspaceChangeTracker.shared.purgeSession(id.uuidString) }
    }

    /// Delete every session owned by an agent. Strict ownership match, unlike
    /// `sessions(for:)`: the Default agent's "show everything" view must not
    /// turn a per-agent wipe into an all-agents wipe, so only sessions whose
    /// `agentId` matches (or is nil, for the Default agent's own chats) are
    /// removed.
    ///
    /// The in-memory list and selection update synchronously (the UI must
    /// reflect the wipe immediately); the database rows, artifact
    /// directories, and sandbox change records are removed on background
    /// queues — a large history deleted through per-session `delete(id:)`
    /// calls would park the main thread behind N synchronous transactions.
    /// Returns once the database batch has finished.
    func deleteAll(for agentId: UUID) async {
        let owned = sessions.filter { session in
            session.agentId == agentId
                || (agentId == Agent.defaultId && session.agentId == nil)
        }
        guard !owned.isEmpty else { return }
        let ids = owned.map(\.id)
        let idSet = Set(ids)
        if let current = currentSessionId, idSet.contains(current) {
            currentSessionId = nil
        }
        sessions.removeAll { idSet.contains($0.id) }
        for id in ids {
            Task { await SandboxWorkspaceChangeTracker.shared.purgeSession(id.uuidString) }
        }
        await withCheckedContinuation { continuation in
            ChatSessionStore.deleteBatch(ids: ids) {
                continuation.resume()
            }
        }
    }

    /// Rename a session.
    ///
    /// Pulls from the in-memory list first because new sessions are only
    /// discoverable there until the pre-stream first-turn save reaches
    /// `ChatSessionStore`; otherwise an early rename could be dropped.
    func rename(id: UUID, title: String) {
        guard
            var session = sessions.first(where: { $0.id == id })
                ?? ChatSessionStore.load(id: id)
        else { return }
        session.title = title
        session.updatedAt = Date()
        // Targeted title update, not a full save: the in-memory copy is
        // metadata-only (from `loadAllMetadata`), and a full `saveSession`
        // would treat its empty `turns` as truth and delete every turn row.
        // Also keeps the DB write off the main thread.
        ChatSessionStore.renameTitleAsync(id: id, title: title, updatedAt: session.updatedAt)
        // A registry-shared live instance saves itself in full
        // on turn finalize; sync its title or that save clobbers the rename.
        // (The window-attached case is synced by the sidebar callback; this
        // covers a live session no window is viewing.)
        LiveChatSessionRegistry.shared.registeredSession(for: id)?.title = title
        upsertInMemory(session)
    }

    /// Rename a session without bumping `updatedAt`, persisting off the
    /// main thread. Used by the auto-title generator: a background rename
    /// must not reorder the sidebar out from under the user, and it runs on
    /// the main actor right after a completed turn — a synchronous DB
    /// transaction here could trip the app-hang watchdog. Same
    /// in-memory-first lookup as `rename`.
    func renameQuietly(id: UUID, title: String) {
        guard
            var session = sessions.first(where: { $0.id == id })
                ?? ChatSessionStore.load(id: id)
        else { return }
        guard session.title != title else { return }
        session.title = title
        // Title-only DB update: the in-memory copy may be metadata-only
        // (empty turns), and a full save would delete the conversation's
        // turn rows. See `ChatSessionStore.renameTitleAsync`.
        ChatSessionStore.renameTitleAsync(id: id, title: title)
        // Same live-instance sync as `rename` — see the note there.
        LiveChatSessionRegistry.shared.registeredSession(for: id)?.title = title
        upsertInMemory(session)
    }

    /// Toggle a session's archive flag. Same in-memory-first lookup as
    /// `rename` because a freshly created chat may not be in the store yet.
    /// Does not touch `updatedAt` so an archive doesn't bubble the row to
    /// the top of the recent list and confuse the user.
    func setArchived(id: UUID, archived: Bool) {
        guard
            var session = sessions.first(where: { $0.id == id })
                ?? ChatSessionStore.load(id: id)
        else { return }
        guard session.archived != archived else { return }
        session.archived = archived
        // Flag-only update for the same reason as `rename`: the in-memory
        // copy is metadata-only and a full save would delete turn rows.
        ChatSessionStore.setArchivedAsync(id: id, archived: archived)
        // Same live-instance sync as `rename` — see the note there.
        LiveChatSessionRegistry.shared.registeredSession(for: id)?.archived = archived
        upsertInMemory(session)
    }

    /// Toggle a session's pin flag. Like `setArchived`, this does not touch
    /// `updatedAt`: pinning is a display-ordering concern handled by the
    /// sidebar and must not bubble the row up the recency list.
    func setPinned(id: UUID, pinned: Bool) {
        guard
            var session = sessions.first(where: { $0.id == id })
                ?? ChatSessionStore.load(id: id)
        else { return }
        guard session.pinned != pinned else { return }
        session.pinned = pinned
        // Flag-only update; see `setArchived`.
        ChatSessionStore.setPinnedAsync(id: id, pinned: pinned)
        // Same live-instance sync as `rename` — see the note there.
        LiveChatSessionRegistry.shared.registeredSession(for: id)?.pinned = pinned
        upsertInMemory(session)
    }

    /// Move a session into a project (or out, with nil). Same
    /// in-memory-first lookup as `rename`; persists via a targeted async
    /// column update so a metadata-only copy can never clobber turn rows
    /// and the main actor never blocks on the DB transaction. Does not
    /// touch `updatedAt`: grouping is a display concern.
    func setProject(id: UUID, projectId: UUID?) {
        guard
            var session = sessions.first(where: { $0.id == id })
                ?? ChatSessionStore.load(id: id)
        else { return }
        guard session.projectId != projectId else { return }
        session.projectId = projectId
        ChatSessionStore.setProjectAsync(id: id, projectId: projectId)
        upsertInMemory(session)
        // A live ChatSession for this id (an open chat window) holds its own
        // projectId copy that the NEXT compose reads — without this it keeps
        // injecting the old project's instructions/knowledge.
        NotificationCenter.default.post(
            name: .chatSessionProjectDidChange,
            object: nil,
            userInfo: ["sessionId": id, "projectId": projectId as Any]
        )
    }

    /// Detach all sessions from a deleted project and drop the project
    /// record. Call this instead of `ProjectManager.delete` directly.
    func deleteProject(id: UUID) {
        ChatSessionStore.clearProjectAsync(projectId: id)
        var updated = sessions
        for index in updated.indices where updated[index].projectId == id {
            updated[index].projectId = nil
        }
        sessions = updated
        ProjectManager.shared.delete(id: id)
        // Drop the project's shared memory namespace: DB rows, vector
        // index (memory + disk), and any cached assembler block. Off the
        // main actor and best-effort — a failure leaves orphan rows that
        // the namespace simply never reads again.
        let namespaceKey = MemoryNamespace.project(id).key
        Task.detached(priority: .utility) {
            try? MemoryDatabase.shared.deleteNamespaceData(agentId: namespaceKey)
            await MemorySearchService.shared.purgeNamespaceStorage(agentId: namespaceKey)
            await MemoryContextAssembler.shared.invalidateCache(agentId: namespaceKey)
        }
        // Live ChatSessions in other windows may still point at the dead
        // project; tell them to drop it (see setProject).
        NotificationCenter.default.post(
            name: .chatSessionProjectDidChange,
            object: nil,
            userInfo: ["clearedProjectId": id]
        )
    }

    /// Get a session by ID
    func session(for id: UUID) -> ChatSessionData? {
        sessions.first { $0.id == id }
    }

    // MARK: - Private

    /// Insert or replace a session in the in-memory array, maintaining updatedAt descending order.
    ///
    /// Built as one assignment (not remove-then-insert) so `$sessions`
    /// observers see a single emission per upsert and never a transient
    /// state with the session absent — subscribers that race the mutation
    /// (the willSet-timing hazard documented on
    /// `ChatWindowState.observeSessionsManager`) otherwise capture the gap.
    private func upsertInMemory(_ session: ChatSessionData) {
        var updated = sessions
        if let index = updated.firstIndex(where: { $0.id == session.id }) {
            updated.remove(at: index)
        }
        // Insert at the correct position to maintain updatedAt descending order
        let insertIndex = updated.firstIndex(where: { $0.updatedAt < session.updatedAt }) ?? updated.endIndex
        updated.insert(session, at: insertIndex)
        sessions = updated
    }
}
