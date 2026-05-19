//
//  ChatEngineTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct ChatEngineTests {

    @Test func chatCompletionRequest_decodesReasoningEffortAndEnableThinking() throws {
        let data = Data(
            """
            {
              "model": "JANGQ-AI/Hy3-preview-JANGTQ",
              "messages": [{"role":"user","content":"hi"}],
              "reasoning_effort": "high",
              "enable_thinking": true
            }
            """.utf8
        )

        let request = try JSONDecoder().decode(ChatCompletionRequest.self, from: data)
        #expect(request.reasoning_effort == "high")
        #expect(request.enable_thinking == true)
    }

    @Test func openResponsesRequest_threadsReasoningEffortIntoChatRequest() throws {
        let data = Data(
            """
            {
              "model": "JANGQ-AI/Hy3-preview-JANGTQ",
              "input": "hi",
              "reasoning": {"effort": "low"}
            }
            """.utf8
        )

        let request = try JSONDecoder().decode(OpenResponsesRequest.self, from: data)
        let chat = request.toChatCompletionRequest()

        #expect(chat.reasoning_effort == "low")
        #expect(chat.model == "JANGQ-AI/Hy3-preview-JANGTQ")
    }

    @Test func openResponsesRequest_preservesInputImageIntoChatRequest() throws {
        let image = "data:image/png;base64,AAAA"
        let data = Data(
            """
            {
              "model": "zaya1-vl-8b-mxfp4",
              "input": [
                {
                  "type": "message",
                  "role": "user",
                  "content": [
                    {"type": "input_text", "text": "Describe this image."},
                    {"type": "input_image", "image_url": "\(image)", "detail": "low"}
                  ]
                }
              ]
            }
            """.utf8
        )

        let request = try JSONDecoder().decode(OpenResponsesRequest.self, from: data)
        let chat = request.toChatCompletionRequest()

        #expect(chat.messages.count == 1)
        #expect(chat.messages[0].content == "Describe this image.")
        #expect(chat.messages[0].imageUrls == [image])
    }

    @Test func openResponsesRequest_preservesLiteralUTF8TextIntoChatRequest() throws {
        let data = Data(
            """
            {
              "model": "zaya1-8b-mxfp4",
              "input": [
                {
                  "type": "message",
                  "role": "user",
                  "content": "Write exactly this UTF-8 string and nothing else: café 東京 🚀"
                }
              ]
            }
            """.utf8
        )

        let request = try JSONDecoder().decode(OpenResponsesRequest.self, from: data)
        let chat = request.toChatCompletionRequest()

        #expect(chat.messages.count == 1)
        #expect(
            chat.messages[0].content
                == "Write exactly this UTF-8 string and nothing else: café 東京 🚀"
        )
    }

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

    @Test func completeChat_omittedMaxTokensPreservesModelDefaultContract() async throws {
        actor Capture {
            var params: GenerationParameters?
            func set(_ params: GenerationParameters) { self.params = params }
        }
        struct CaptureService: ModelService {
            let capture: Capture
            var id: String { "fake" }
            func isAvailable() -> Bool { true }
            func handles(requestedModel: String?) -> Bool { requestedModel == "fake" }
            func generateOneShot(
                messages: [ChatMessage],
                parameters: GenerationParameters,
                requestedModel: String?
            ) async throws -> String {
                await capture.set(parameters)
                return "ok"
            }
            func streamDeltas(
                messages: [ChatMessage],
                parameters: GenerationParameters,
                requestedModel: String?,
                stopSequences: [String]
            ) async throws -> AsyncThrowingStream<String, Error> {
                await capture.set(parameters)
                return AsyncThrowingStream { continuation in
                    continuation.yield("ok")
                    continuation.finish()
                }
            }
        }

        let capture = Capture()
        let engine = ChatEngine(services: [CaptureService(capture: capture)], installedModelsProvider: { [] })
        let req = ChatCompletionRequest(
            model: "fake",
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

        _ = try await engine.completeChat(request: req)
        let params = await capture.params
        #expect(params?.maxTokens == 16_384)
        #expect(params?.maxTokensExplicit == false)
    }

    @Test func completeChat_routesLocalModelWithoutFetchingRemoteServices() async throws {
        actor RemoteProbe {
            private(set) var called = false

            func services() -> [ModelService] {
                called = true
                return []
            }
        }

        let probe = RemoteProbe()
        let svc = FakeModelService()
        let engine = ChatEngine(
            services: [svc],
            installedModelsProvider: { [] },
            remoteServicesProvider: { await probe.services() }
        )
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

        #expect(resp.choices.first?.message.content == "hello")
        #expect(await probe.called == false)
    }

    @Test func completeChat_threadsOpenAIReasoningFieldsIntoModelOptions() async throws {
        actor Capture {
            var params: GenerationParameters?
            func set(_ params: GenerationParameters) { self.params = params }
        }
        struct CaptureService: ModelService {
            let capture: Capture
            var id: String { "hy3" }
            func isAvailable() -> Bool { true }
            func handles(requestedModel: String?) -> Bool { requestedModel == "hy3" }
            func generateOneShot(
                messages: [ChatMessage],
                parameters: GenerationParameters,
                requestedModel: String?
            ) async throws -> String {
                await capture.set(parameters)
                return "ok"
            }
            func streamDeltas(
                messages: [ChatMessage],
                parameters: GenerationParameters,
                requestedModel: String?,
                stopSequences: [String]
            ) async throws -> AsyncThrowingStream<String, Error> {
                await capture.set(parameters)
                return AsyncThrowingStream { continuation in
                    continuation.yield("ok")
                    continuation.finish()
                }
            }
        }

        let capture = Capture()
        let engine = ChatEngine(services: [CaptureService(capture: capture)], installedModelsProvider: { [] })
        var req = ChatCompletionRequest(
            model: "hy3",
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
        req.enable_thinking = true
        req.reasoning_effort = "high"

        _ = try await engine.completeChat(request: req)
        let params = await capture.params
        #expect(params?.modelOptions["reasoningEffort"]?.stringValue == "high")
        #expect(
            params?.modelOptions["disableThinking"] == nil,
            "Hy3 uses reasoningEffort; the generic disableThinking bool must not survive and create a second, contradictory cache-scope signal"
        )
    }

    @Test func completeChat_appliesModelProfileDefaultsForBareAPIRequests() async throws {
        actor Capture {
            var params: GenerationParameters?
            func set(_ params: GenerationParameters) { self.params = params }
        }
        struct CaptureService: ModelService {
            let capture: Capture
            var id: String { "qwen" }
            func isAvailable() -> Bool { true }
            func handles(requestedModel: String?) -> Bool {
                requestedModel == "qwen3.6-27b-mxfp4-mtp"
            }
            func generateOneShot(
                messages: [ChatMessage],
                parameters: GenerationParameters,
                requestedModel: String?
            ) async throws -> String {
                await capture.set(parameters)
                return "ok"
            }
            func streamDeltas(
                messages: [ChatMessage],
                parameters: GenerationParameters,
                requestedModel: String?,
                stopSequences: [String]
            ) async throws -> AsyncThrowingStream<String, Error> {
                await capture.set(parameters)
                return AsyncThrowingStream { continuation in
                    continuation.yield("ok")
                    continuation.finish()
                }
            }
        }

        let capture = Capture()
        let engine = ChatEngine(services: [CaptureService(capture: capture)], installedModelsProvider: { [] })
        let req = ChatCompletionRequest(
            model: "qwen3.6-27b-mxfp4-mtp",
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: nil,
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

        _ = try await engine.completeChat(request: req)
        let params = await capture.params
        #expect(
            params?.modelOptions["disableThinking"]?.boolValue == true,
            "Bare HTTP/API Qwen requests must receive the same profile default as Chat UI; otherwise omitted enable_thinking falls through to generic thinking-on and short non-streaming responses can return empty visible content."
        )

        var explicitThinking = req
        explicitThinking.enable_thinking = true
        _ = try await engine.completeChat(request: explicitThinking)
        let explicitParams = await capture.params
        #expect(
            explicitParams?.modelOptions["disableThinking"]?.boolValue == false,
            "Explicit API enable_thinking=true must override the profile default; the default is not a hidden thinking clamp."
        )
    }

    @Test func completeChat_mapsHy3LegacyThinkingBoolToReasoningEffort() async throws {
        actor Capture {
            var params: GenerationParameters?
            func set(_ params: GenerationParameters) { self.params = params }
        }
        struct CaptureService: ModelService {
            let capture: Capture
            var id: String { "hy3" }
            func isAvailable() -> Bool { true }
            func handles(requestedModel: String?) -> Bool { requestedModel == "hy3" }
            func generateOneShot(
                messages: [ChatMessage],
                parameters: GenerationParameters,
                requestedModel: String?
            ) async throws -> String {
                await capture.set(parameters)
                return "ok"
            }
            func streamDeltas(
                messages: [ChatMessage],
                parameters: GenerationParameters,
                requestedModel: String?,
                stopSequences: [String]
            ) async throws -> AsyncThrowingStream<String, Error> {
                await capture.set(parameters)
                return AsyncThrowingStream { continuation in
                    continuation.yield("ok")
                    continuation.finish()
                }
            }
        }

        let capture = Capture()
        let engine = ChatEngine(services: [CaptureService(capture: capture)], installedModelsProvider: { [] })
        var req = ChatCompletionRequest(
            model: "hy3",
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
        req.enable_thinking = false

        _ = try await engine.completeChat(request: req)
        let params = await capture.params
        #expect(params?.modelOptions["reasoningEffort"]?.stringValue == "no_think")
        #expect(params?.modelOptions["disableThinking"] == nil)
    }

    @Test func streamChat_threadsGenericReasoningFieldsAndStopsIntoModelService() async throws {
        actor Capture {
            var params: GenerationParameters?
            var stopSequences: [String]?
            func set(_ params: GenerationParameters, stopSequences: [String]) {
                self.params = params
                self.stopSequences = stopSequences
            }
        }
        struct CaptureService: ModelService {
            let capture: Capture
            var id: String { "fake" }
            func isAvailable() -> Bool { true }
            func handles(requestedModel: String?) -> Bool { requestedModel == "fake" }
            func generateOneShot(
                messages: [ChatMessage],
                parameters: GenerationParameters,
                requestedModel: String?
            ) async throws -> String {
                await capture.set(parameters, stopSequences: [])
                return "ok"
            }
            func streamDeltas(
                messages: [ChatMessage],
                parameters: GenerationParameters,
                requestedModel: String?,
                stopSequences: [String]
            ) async throws -> AsyncThrowingStream<String, Error> {
                await capture.set(parameters, stopSequences: stopSequences)
                return AsyncThrowingStream { continuation in
                    continuation.yield("ok")
                    continuation.finish()
                }
            }
        }

        let capture = Capture()
        let engine = ChatEngine(services: [CaptureService(capture: capture)], installedModelsProvider: { [] })
        var req = ChatCompletionRequest(
            model: "fake",
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: 0.2,
            max_tokens: 32,
            stream: true,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: ["</final>"],
            n: nil,
            tools: nil,
            tool_choice: nil,
            session_id: nil
        )
        req.enable_thinking = false
        req.reasoning_effort = "high"
        req.modelOptions = ["customFlag": .string("kept")]

        let stream = try await engine.streamChat(request: req)
        var text = ""
        for try await delta in stream { text += delta }

        let params = await capture.params
        let stopSequences = await capture.stopSequences
        #expect(text == "ok")
        #expect(stopSequences == ["</final>"])
        #expect(params?.modelOptions["disableThinking"]?.boolValue == true)
        #expect(params?.modelOptions["reasoningEffort"]?.stringValue == "high")
        #expect(params?.modelOptions["customFlag"]?.stringValue == "kept")
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
        let id = toolCalls?.first?.id ?? ""
        #expect(id.hasPrefix("call_"))
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
