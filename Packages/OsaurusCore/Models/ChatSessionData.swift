//
//  ChatSessionData.swift
//  osaurus
//
//  Persistable chat session model
//

import Foundation

/// Codable session data for persistence
struct ChatSessionData: Codable, Identifiable, Sendable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var selectedModel: String?
    var turns: [ChatTurnData]

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        selectedModel: String? = nil,
        turns: [ChatTurnData] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.selectedModel = selectedModel
        self.turns = turns
    }

    /// Generate a title from the first user message
    static func generateTitle(from turns: [ChatTurnData]) -> String {
        guard let firstUserTurn = turns.first(where: { $0.role == .user }) else {
            return "New Chat"
        }
        let content = firstUserTurn.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty {
            return "New Chat"
        }
        // Take first line and truncate to reasonable length
        let firstLine = content.components(separatedBy: .newlines).first ?? content
        if firstLine.count <= 50 {
            return firstLine
        }
        return String(firstLine.prefix(47)) + "..."
    }
}
