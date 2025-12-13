//
//  ChatTurnData.swift
//  osaurus
//
//  Codable representation of ChatTurn for persistence
//

import Foundation

/// Codable version of ChatTurn for session persistence
struct ChatTurnData: Codable, Identifiable, Sendable {
    let id: UUID
    let role: MessageRole
    var content: String
    var attachedImages: [Data]
    var toolCalls: [ToolCall]?
    var toolCallId: String?
    var toolResults: [String: String]
    var thinking: String

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        attachedImages: [Data] = [],
        toolCalls: [ToolCall]? = nil,
        toolCallId: String? = nil,
        toolResults: [String: String] = [:],
        thinking: String = ""
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.attachedImages = attachedImages
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolResults = toolResults
        self.thinking = thinking
    }

    // Custom decoder for backward compatibility with sessions saved before thinking was added
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(MessageRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        attachedImages = try container.decodeIfPresent([Data].self, forKey: .attachedImages) ?? []
        toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
        toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId)
        toolResults = try container.decodeIfPresent([String: String].self, forKey: .toolResults) ?? [:]
        thinking = try container.decodeIfPresent(String.self, forKey: .thinking) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, attachedImages, toolCalls, toolCallId, toolResults, thinking
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
        self.attachedImages = turn.attachedImages
        self.toolCalls = turn.toolCalls
        self.toolCallId = turn.toolCallId
        self.toolResults = turn.toolResults
        self.thinking = turn.thinking
    }
}

extension ChatTurn {
    /// Create a ChatTurn from persisted data
    convenience init(from data: ChatTurnData) {
        self.init(role: data.role, content: data.content, images: data.attachedImages)
        self.toolCalls = data.toolCalls
        self.toolCallId = data.toolCallId
        self.toolResults = data.toolResults
        self.thinking = data.thinking
    }
}
