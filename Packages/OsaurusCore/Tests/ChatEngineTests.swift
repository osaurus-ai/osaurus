//
//  ChatEngineTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct ChatEngineTests {

    @Test func streamChat_yields_deltas_success() async throws {
        let svc = FakeModelService(deltas: ["a", "b", "c"])
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
        let svc = FakeModelService()
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

    @Test func completeChat_returns_tool_calls_when_tool_invoked() async throws {
        // Tool-capable fake that throws ServiceToolInvocation when tools are present
        struct FakeToolService: ToolCapableService {
            var id: String { "fake" }
            func isAvailable() -> Bool { true }
            func handles(requestedModel: String?) -> Bool { (requestedModel ?? "") == "fake" }
            func streamDeltas(
                messages: [ChatMessage],
                parameters: GenerationParameters,
                requestedModel: String?,
                stopSequences: [String]
            ) async throws -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
            func generateOneShot(
                messages: [ChatMessage],
                parameters: GenerationParameters,
                requestedModel: String?
            ) async throws -> String { "" }
            func respondWithTools(
                messages: [ChatMessage],
                parameters: GenerationParameters,
                stopSequences: [String],
                tools: [Tool],
                toolChoice: ToolChoiceOption?,
                requestedModel: String?
            ) async throws -> String {
                throw ServiceToolInvocation(toolName: "get_weather", jsonArguments: "{\"city\":\"SF\"}")
            }
            func streamWithTools(
                messages: [ChatMessage],
                parameters: GenerationParameters,
                stopSequences: [String],
                tools: [Tool],
                toolChoice: ToolChoiceOption?,
                requestedModel: String?
            ) async throws -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
        }

        let engine = ChatEngine(services: [FakeToolService()], installedModelsProvider: { [] })
        let req = ChatCompletionRequest(
            model: "fake",
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: 0.5,
            max_tokens: 16,
            stream: false,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: [
                Tool(
                    type: "function",
                    function: ToolFunction(name: "get_weather", description: nil, parameters: .object([:]))
                )
            ],
            tool_choice: .auto,
            session_id: nil
        )
        let resp = try await engine.completeChat(request: req)
        #expect(resp.choices.first?.finish_reason == "tool_calls")
        let toolCalls = resp.choices.first?.message.tool_calls
        #expect(toolCalls?.first?.function.name == "get_weather")
        #expect((toolCalls?.first?.id ?? "").hasPrefix("call_"))
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
        let svc = FakeModelService()
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
