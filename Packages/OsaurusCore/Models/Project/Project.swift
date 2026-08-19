//
//  Project.swift
//  osaurus
//
//  A user-facing container that groups chat sessions around a topic.
//  Orthogonal to agents: a project can hold conversations from any agent.
//

import Foundation

/// A named grouping of chat sessions with optional shared context.
public struct Project: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    /// Free-form instructions prepended to the system prompt of every chat
    /// in this project. Empty string means no extra context.
    public var instructions: String
    /// Knowledge collections shared by all chats in this project. Merged
    /// with the agent's own `knowledgeCollectionIds` at request time.
    public var knowledgeCollectionIds: [UUID]
    /// Agent that new chats started from this project's page use. nil (or a
    /// since-deleted agent) → the window's current agent, as before. A
    /// nudge toward one-agent projects, never a restriction: chats from any
    /// agent can still be moved in.
    public var defaultAgentId: UUID?
    /// Security-scoped bookmark of the folder new chats in this project open
    /// with, nil when no project folder is set. Applied to a fresh project
    /// chat that has no folder of its own; never overrides a folder the user
    /// picked in that chat. A default, not a lock (like `defaultAgentId`).
    public var folderBookmark: Data?
    /// Non-sensitive display path of the project folder. Kept alongside the
    /// bookmark so the UI can show where the folder lived even when the
    /// bookmark has gone stale (folder moved/deleted), mirroring
    /// `ChatSessionData`.
    public var folderPath: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        instructions: String = "",
        knowledgeCollectionIds: [UUID] = [],
        defaultAgentId: UUID? = nil,
        folderBookmark: Data? = nil,
        folderPath: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.knowledgeCollectionIds = knowledgeCollectionIds
        self.defaultAgentId = defaultAgentId
        self.folderBookmark = folderBookmark
        self.folderPath = folderPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        knowledgeCollectionIds =
            try c.decodeIfPresent([UUID].self, forKey: .knowledgeCollectionIds) ?? []
        defaultAgentId = try c.decodeIfPresent(UUID.self, forKey: .defaultAgentId)
        folderBookmark = try c.decodeIfPresent(Data.self, forKey: .folderBookmark)
        folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, instructions, knowledgeCollectionIds, defaultAgentId
        case folderBookmark, folderPath
        case createdAt, updatedAt
    }
}
