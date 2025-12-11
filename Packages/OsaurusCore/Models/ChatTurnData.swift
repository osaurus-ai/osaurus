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

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        attachedImages: [Data] = [],
        toolCalls: [ToolCall]? = nil,
        toolCallId: String? = nil,
        toolResults: [String: String] = [:]
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.attachedImages = attachedImages
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolResults = toolResults
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
    }
}

extension ChatTurn {
    /// Create a ChatTurn from persisted data
    convenience init(from data: ChatTurnData) {
        self.init(role: data.role, content: data.content, images: data.attachedImages)
        self.toolCalls = data.toolCalls
        self.toolCallId = data.toolCallId
        self.toolResults = data.toolResults
    }
}
