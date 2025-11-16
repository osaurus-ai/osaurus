//
//  ChatEngineTestDoubles.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - ChatEngineProtocol mock

struct MockChatEngine: ChatEngineProtocol {
    var deltas: [String] = []
    var completeText: String = ""
    var model: String = "mock"

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for d in deltas { continuation.yield(d) }
            continuation.finish()
        }
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        let created = Int(Date().timeIntervalSince1970)
        let responseId =
            "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
        let choice = ChatChoice(
            index: 0,
            message: ChatMessage(
                role: "assistant",
                content: completeText,
                tool_calls: nil,
                tool_call_id: nil
            ),
            finish_reason: "stop"
        )
        let usage = Usage(prompt_tokens: 0, completion_tokens: 0, total_tokens: 0)
        return ChatCompletionResponse(
            id: responseId,
            created: created,
            model: model,
            choices: [choice],
            usage: usage,
            system_fingerprint: nil
        )
    }
}

// MARK: - ModelService fake

struct FakeModelService: ModelService {
    var id: String { "fake" }

    var available: Bool = true
    var supportedModel: String = "fake"
    var deltas: [String] = []
    var completeText: String = "hello"

    func isAvailable() -> Bool { available }

    func handles(requestedModel: String?) -> Bool {
        let t = (requestedModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t == supportedModel
    }

    func generateOneShot(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?
    ) async throws -> String {
        return completeText
    }

    func streamDeltas(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?,
        stopSequences: [String]
    ) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for d in deltas { continuation.yield(d) }
            continuation.finish()
        }
    }
}
