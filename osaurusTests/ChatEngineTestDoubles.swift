//
//  ChatEngineTestDoubles.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import osaurus

// MARK: - ChatEngineProtocol mock

struct MockChatEngine: ChatEngineProtocol {
  var deltas: [String] = []
  var completeText: String = ""
  var model: String = "mock"

  func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error>
  {
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
        role: "assistant", content: completeText, tool_calls: nil, tool_call_id: nil),
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

// MARK: - ModelService fakes

struct FakeThrowingStreamingService: ThrowingStreamingService {
  var id: String = "fake"
  var handledModelName: String = "fake"
  var available: Bool = true
  var deltas: [String] = ["a", "b", "c"]

  func isAvailable() -> Bool { available }

  func handles(requestedModel: String?) -> Bool {
    let trimmed = (requestedModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed == handledModelName
  }

  func streamDeltas(
    prompt: String,
    parameters: GenerationParameters,
    requestedModel: String?
  ) async throws -> AsyncStream<String> {
    let (stream, cont) = AsyncStream<String>.makeStream()
    Task {
      for d in deltas { cont.yield(d) }
      cont.finish()
    }
    return stream
  }

  func streamDeltasThrowing(
    prompt: String,
    parameters: GenerationParameters,
    requestedModel: String?,
    stopSequences: [String]
  ) async throws -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      for d in deltas { continuation.yield(d) }
      continuation.finish()
    }
  }

  func generateOneShot(
    prompt: String,
    parameters: GenerationParameters,
    requestedModel: String?
  ) async throws -> String {
    deltas.joined()
  }
}

struct FakeNonThrowingService: ModelService {
  var id: String = "plain"
  var handledModelName: String = "plain"
  var available: Bool = true

  func isAvailable() -> Bool { available }

  func handles(requestedModel: String?) -> Bool {
    let trimmed = (requestedModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed == handledModelName
  }

  func streamDeltas(
    prompt: String,
    parameters: GenerationParameters,
    requestedModel: String?
  ) async throws -> AsyncStream<String> {
    let (stream, cont) = AsyncStream<String>.makeStream()
    Task {
      cont.yield("x")
      cont.finish()
    }
    return stream
  }

  func generateOneShot(
    prompt: String,
    parameters: GenerationParameters,
    requestedModel: String?
  ) async throws -> String {
    "x"
  }
}
