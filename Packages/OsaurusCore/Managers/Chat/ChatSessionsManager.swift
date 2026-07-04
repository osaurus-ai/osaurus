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
        ChatSessionStore.save(session)
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

    /// Delete a session by ID
    func delete(id: UUID) {
        ChatSessionStore.delete(id: id)
        if currentSessionId == id {
            currentSessionId = nil
        }
        sessions.removeAll { $0.id == id }
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
        ChatSessionStore.save(session)
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
        ChatSessionStore.save(session)
        upsertInMemory(session)
    }

    /// Get a session by ID
    func session(for id: UUID) -> ChatSessionData? {
        sessions.first { $0.id == id }
    }

    // MARK: - Private

    /// Insert or replace a session in the in-memory array, maintaining updatedAt descending order.
    private func upsertInMemory(_ session: ChatSessionData) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions.remove(at: index)
        }
        // Insert at the correct position to maintain updatedAt descending order
        let insertIndex = sessions.firstIndex(where: { $0.updatedAt < session.updatedAt }) ?? sessions.endIndex
        sessions.insert(session, at: insertIndex)
    }
}
