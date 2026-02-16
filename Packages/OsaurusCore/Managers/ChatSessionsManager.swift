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

    private init() {
        refresh()
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

    /// Rename a session
    func rename(id: UUID, title: String) {
        guard var session = ChatSessionStore.load(id: id) else { return }
        session.title = title
        session.updatedAt = Date()
        ChatSessionStore.save(session)
        upsertInMemory(session)
    }

    /// Get a session by ID
    func session(for id: UUID) -> ChatSessionData? {
        sessions.first { $0.id == id }
    }

    /// Update session with new turns and auto-generate title if needed
    func updateSession(id: UUID, turns: [ChatTurnData], selectedModel: String?) {
        guard var session = ChatSessionStore.load(id: id) else { return }

        // Auto-generate title from first user message if still default
        if session.title == "New Chat" && !turns.isEmpty {
            session.title = ChatSessionData.generateTitle(from: turns)
        }

        session.turns = turns
        session.selectedModel = selectedModel
        session.updatedAt = Date()
        ChatSessionStore.save(session)
        upsertInMemory(session)
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
