//
//  ChatEngineProtocol.swift
//  osaurus
//

import Foundation

protocol ResponsesEngineProtocol: Sendable {
    func streamResponses(request: ResponsesInferenceRequest) async throws
        -> AsyncThrowingStream<ResponsesGenerationEvent, Error>
}

protocol ChatEngineProtocol: ResponsesEngineProtocol {
    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error>
    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse
}

extension ChatEngineProtocol {
    /// Compatibility for older injected engines. The production ChatEngine
    /// supplies its own native typed implementation with shared dispatch/logging.
    func streamResponses(request: ResponsesInferenceRequest) async throws
        -> AsyncThrowingStream<ResponsesGenerationEvent, Error>
    {
        let stream = try await streamChat(request: request.chatCompletionsCompatibilityRequest())
        return ResponsesGenerationStream.compatibility(stream)
    }
}
