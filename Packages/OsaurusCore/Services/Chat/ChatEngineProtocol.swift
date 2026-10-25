//
//  ChatEngineProtocol.swift
//  osaurus
//

import Foundation

protocol ResponsesEngineProtocol: Sendable {
    func streamResponses(request: ResponsesInferenceRequest) async throws
        -> AsyncThrowingStream<ResponsesGenerationEvent, Error>
}

protocol ChatEngineProtocol: Sendable {
    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error>
    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse
}
