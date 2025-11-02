//
//  ChatEngineTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import osaurus

struct ChatEngineTests {

  @Test func streamChat_yields_deltas_success() async throws {
    let svc = FakeThrowingStreamingService(deltas: ["a", "b", "c"])
    let engine = ChatEngine(services: [svc], installedModelsProvider: { [] })
    let req = ChatCompletionRequest(
      model: "fake",
      messages: [ChatMessage(role: "user", content: "hi")],
      temperature: 0.5,
      max_tokens: 16,
      stream: true,
      top_p: nil,
      frequency_penalty: nil,
      presence_penalty: nil,
      stop: nil,
      n: nil,
      tools: nil,
      tool_choice: nil,
      session_id: nil
    )
    let stream = try await engine.streamChat(request: req)
    var out = ""
    for try await d in stream { out += d }
    #expect(out == "abc")
  }

  @Test func completeChat_returns_choice_success() async throws {
    let svc = FakeThrowingStreamingService(deltas: ["he", "llo"])
    let engine = ChatEngine(services: [svc], installedModelsProvider: { [] })
    let req = ChatCompletionRequest(
      model: "fake",
      messages: [ChatMessage(role: "user", content: "hi")],
      temperature: 0.5,
      max_tokens: 32,
      stream: false,
      top_p: nil,
      frequency_penalty: nil,
      presence_penalty: nil,
      stop: nil,
      n: nil,
      tools: nil,
      tool_choice: nil,
      session_id: nil
    )
    let resp = try await engine.completeChat(request: req)
    #expect(resp.id.hasPrefix("chatcmpl-"))
    #expect(resp.model == "fake")
    #expect(resp.choices.count == 1)
    #expect(resp.choices.first?.finish_reason == "stop")
    #expect(resp.choices.first?.message.content == "hello")
  }

  @Test func streamChat_throws_when_no_route() async throws {
    let engine = ChatEngine(services: [], installedModelsProvider: { [] })
    let req = ChatCompletionRequest(
      model: "unknown",
      messages: [ChatMessage(role: "user", content: "hi")],
      temperature: nil,
      max_tokens: nil,
      stream: true,
      top_p: nil,
      frequency_penalty: nil,
      presence_penalty: nil,
      stop: nil,
      n: nil,
      tools: nil,
      tool_choice: nil,
      session_id: nil
    )
    var threw = false
    do { _ = try await engine.streamChat(request: req) } catch { threw = true }
    #expect(threw)
  }

  @Test func completeChat_throws_when_no_route() async throws {
    let engine = ChatEngine(services: [], installedModelsProvider: { [] })
    let req = ChatCompletionRequest(
      model: "unknown",
      messages: [ChatMessage(role: "user", content: "hi")],
      temperature: nil,
      max_tokens: nil,
      stream: false,
      top_p: nil,
      frequency_penalty: nil,
      presence_penalty: nil,
      stop: nil,
      n: nil,
      tools: nil,
      tool_choice: nil,
      session_id: nil
    )
    var threw = false
    do { _ = try await engine.completeChat(request: req) } catch { threw = true }
    #expect(threw)
  }

  @Test func streamChat_throws_when_service_not_throwing_streaming() async throws {
    let svc = FakeNonThrowingService()
    let engine = ChatEngine(services: [svc], installedModelsProvider: { [] })
    let req = ChatCompletionRequest(
      model: "plain",
      messages: [ChatMessage(role: "user", content: "hi")],
      temperature: nil,
      max_tokens: nil,
      stream: true,
      top_p: nil,
      frequency_penalty: nil,
      presence_penalty: nil,
      stop: nil,
      n: nil,
      tools: nil,
      tool_choice: nil,
      session_id: nil
    )
    var threw = false
    do { _ = try await engine.streamChat(request: req) } catch { threw = true }
    #expect(threw)
  }
}
