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
    /// Per-session tool overrides. nil = use global config, otherwise map of tool name -> enabled
    var enabledToolOverrides: [String: Bool]?

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        selectedModel: String? = nil,
        turns: [ChatTurnData] = [],
        enabledToolOverrides: [String: Bool]? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.selectedModel = selectedModel
        self.turns = turns
        self.enabledToolOverrides = enabledToolOverrides
    }

    // Custom decoder for backward compatibility with sessions saved before enabledToolOverrides was added
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        selectedModel = try container.decodeIfPresent(String.self, forKey: .selectedModel)
        turns = try container.decode([ChatTurnData].self, forKey: .turns)
        enabledToolOverrides = try container.decodeIfPresent([String: Bool].self, forKey: .enabledToolOverrides)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, selectedModel, turns, enabledToolOverrides
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
