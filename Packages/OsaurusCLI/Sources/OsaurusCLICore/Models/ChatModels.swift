//
//  ChatModels.swift
//  osaurus
//
//  Data models for chat requests and streaming responses used by the CLI chat interface.
//

import Foundation

public struct ChatMessage: Encodable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct ChatRequest: Encodable {
    public let model: String
    public let messages: [ChatMessage]
    public let stream: Bool
    public let temperature: Float?
    public let max_tokens: Int?
    public let session_id: String?

    public init(
        model: String,
        messages: [ChatMessage],
        stream: Bool,
        temperature: Float?,
        max_tokens: Int?,
        session_id: String?
    ) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.temperature = temperature
        self.max_tokens = max_tokens
        self.session_id = session_id
    }
}

public struct NDJSONEvent: Decodable {
    public struct NDMessage: Decodable {
        public let role: String?
        public let content: String?
    }
    public let message: NDMessage?
    public let done: Bool?
}
