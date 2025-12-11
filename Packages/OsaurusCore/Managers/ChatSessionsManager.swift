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

    /// Reload sessions from disk
    func refresh() {
        sessions = ChatSessionStore.loadAll()
    }

    /// Create a new session and return its ID
    @discardableResult
    func createNew(selectedModel: String? = nil) -> UUID {
        let session = ChatSessionData(
            id: UUID(),
            title: "New Chat",
            createdAt: Date(),
            updatedAt: Date(),
            selectedModel: selectedModel,
            turns: []
        )
        ChatSessionStore.save(session)
        refresh()
        return session.id
    }

    /// Save a session (updates the list)
    func save(_ session: ChatSessionData) {
        ChatSessionStore.save(session)
        refresh()
    }

    /// Delete a session by ID
    func delete(id: UUID) {
        ChatSessionStore.delete(id: id)
        if currentSessionId == id {
            currentSessionId = nil
        }
        refresh()
    }

    /// Rename a session
    func rename(id: UUID, title: String) {
        guard var session = ChatSessionStore.load(id: id) else { return }
        session.title = title
        session.updatedAt = Date()
        ChatSessionStore.save(session)
        refresh()
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
        refresh()
    }
}
