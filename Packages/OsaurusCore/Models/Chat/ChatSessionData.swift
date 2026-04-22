//
//  ChatSessionData.swift
//  osaurus
//
//  Persistable chat session model
//

import Foundation

/// Codable session data for persistence
public struct ChatSessionData: Codable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var selectedModel: String?
    public var turns: [ChatTurnData]
    /// The agent this session belongs to. nil = Default agent
    public var agentId: UUID?

    /// Where this session originated. Defaults to `.chat` for legacy rows.
    public var source: SessionSource
    /// Plugin identifier when `source == .plugin`, otherwise nil.
    public var sourcePluginId: String?
    /// Stable external key (e.g. Telegram chat id, HTTP `X-Session-Id`) used
    /// to group multi-call conversations into a single session row.
    public var externalSessionKey: String?
    /// For `.plugin` / `.http` / `.schedule` / `.watcher` sessions that came
    /// in via `BackgroundTaskManager.dispatchChat`, this is the dispatch
    /// task UUID. Equal to `id` once `ExecutionContext` is taught to align
    /// the two (Phase 2 of the chat-sessions refactor).
    public var dispatchTaskId: UUID?

    public init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        selectedModel: String? = nil,
        turns: [ChatTurnData] = [],
        agentId: UUID? = nil,
        source: SessionSource = .chat,
        sourcePluginId: String? = nil,
        externalSessionKey: String? = nil,
        dispatchTaskId: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.selectedModel = selectedModel
        self.turns = turns
        self.agentId = agentId
        self.source = source
        self.sourcePluginId = sourcePluginId
        self.externalSessionKey = externalSessionKey
        self.dispatchTaskId = dispatchTaskId
    }

    // Custom decoder for backward compatibility with old sessions
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        selectedModel = try container.decodeIfPresent(String.self, forKey: .selectedModel)
        turns = try container.decode([ChatTurnData].self, forKey: .turns)
        agentId =
            try container.decodeIfPresent(UUID.self, forKey: .agentId)
            ?? container.decodeIfPresent(UUID.self, forKey: .personaId)
        source = try container.decodeIfPresent(SessionSource.self, forKey: .source) ?? .chat
        sourcePluginId = try container.decodeIfPresent(String.self, forKey: .sourcePluginId)
        externalSessionKey = try container.decodeIfPresent(String.self, forKey: .externalSessionKey)
        dispatchTaskId = try container.decodeIfPresent(UUID.self, forKey: .dispatchTaskId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(selectedModel, forKey: .selectedModel)
        try container.encode(turns, forKey: .turns)
        try container.encodeIfPresent(agentId, forKey: .agentId)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(sourcePluginId, forKey: .sourcePluginId)
        try container.encodeIfPresent(externalSessionKey, forKey: .externalSessionKey)
        try container.encodeIfPresent(dispatchTaskId, forKey: .dispatchTaskId)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, selectedModel, turns, agentId
        case personaId  // legacy key for migration
        case source, sourcePluginId, externalSessionKey, dispatchTaskId
    }

    /// Generate a title from the first user message
    public static func generateTitle(from turns: [ChatTurnData]) -> String {
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
