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
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        instructions: String = "",
        knowledgeCollectionIds: [UUID] = [],
        defaultAgentId: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.knowledgeCollectionIds = knowledgeCollectionIds
        self.defaultAgentId = defaultAgentId
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
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, instructions, knowledgeCollectionIds, defaultAgentId, createdAt, updatedAt
    }
}
