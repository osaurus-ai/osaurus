//
//  ChatTurnData.swift
//  osaurus
//
//  Codable representation of ChatTurn for persistence
//

import Foundation

/// Codable version of ChatTurn for session persistence
public struct ChatTurnData: Codable, Identifiable, Sendable {
    public let id: UUID
    public let role: MessageRole
    public var content: String
    public var attachments: [Attachment]
    public var toolCalls: [ToolCall]?
    public var toolCallId: String?
    public var toolResults: [String: String]
    public var thinking: String

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        attachments: [Attachment] = [],
        toolCalls: [ToolCall]? = nil,
        toolCallId: String? = nil,
        toolResults: [String: String] = [:],
        thinking: String = ""
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolResults = toolResults
        self.thinking = thinking
    }

    // Backward-compatible decoder: migrates old `attachedImages` into unified `attachments`
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(MessageRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
        toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId)
        toolResults = try container.decodeIfPresent([String: String].self, forKey: .toolResults) ?? [:]
        thinking = try container.decodeIfPresent(String.self, forKey: .thinking) ?? ""

        if let unified = try container.decodeIfPresent([Attachment].self, forKey: .attachments) {
            attachments = unified
        } else {
            let legacyImages = try container.decodeIfPresent([Data].self, forKey: .attachedImages) ?? []
            attachments = legacyImages.map { .image($0) }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallId, forKey: .toolCallId)
        try container.encode(toolResults, forKey: .toolResults)
        try container.encode(thinking, forKey: .thinking)
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, attachments
        case attachedImages  // legacy key for reading old sessions
        case toolCalls, toolCallId, toolResults, thinking
    }
}

// MARK: - Conversion Extensions

extension ChatTurnData {
    /// Convert from a ChatTurn instance
    @MainActor
    init(from turn: ChatTurn) {
        self.id = turn.id
        self.role = turn.role
        self.content = turn.content
        self.attachments = turn.attachments
        self.toolCalls = turn.toolCalls
        self.toolCallId = turn.toolCallId
        self.toolResults = turn.toolResults
        self.thinking = turn.thinking
    }
}

extension ChatTurn {
    /// Create a ChatTurn from persisted data (preserves original UUID for stable block IDs)
    convenience init(from data: ChatTurnData) {
        self.init(role: data.role, content: data.content, attachments: data.attachments, id: data.id)
        self.toolCalls = data.toolCalls
        self.toolCallId = data.toolCallId
        self.toolResults = data.toolResults
        self.thinking = data.thinking
    }
}
