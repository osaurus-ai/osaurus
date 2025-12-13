//
//  ChatTurn.swift
//  osaurus
//
//  Reference-type chat turn for efficient UI updates
//

import Combine
import Foundation

final class ChatTurn: ObservableObject, Identifiable {
    let id = UUID()
    let role: MessageRole
    @Published var content: String
    /// Attached images for multimodal messages (stored as PNG data)
    @Published var attachedImages: [Data] = []
    /// Assistant-issued tool calls attached to this turn (OpenAI compatible)
    @Published var toolCalls: [ToolCall]? = nil
    /// For role==.tool messages, associates this result with the originating call id
    var toolCallId: String? = nil
    /// Convenience map for UI to show tool results grouped under the assistant turn
    @Published var toolResults: [String: String] = [:]
    /// Thinking/reasoning content from models that support extended thinking (e.g., DeepSeek, QwQ)
    @Published var thinking: String = ""

    init(role: MessageRole, content: String) {
        self.role = role
        self.content = content
    }

    init(role: MessageRole, content: String, images: [Data]) {
        self.role = role
        self.content = content
        self.attachedImages = images
    }

    /// Whether this turn has any attached images
    var hasImages: Bool {
        !attachedImages.isEmpty
    }

    /// Whether this turn has any thinking/reasoning content
    var hasThinking: Bool {
        !thinking.isEmpty
    }
}
