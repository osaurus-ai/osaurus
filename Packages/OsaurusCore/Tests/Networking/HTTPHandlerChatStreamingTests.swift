//
//  HTTPHandlerChatStreamingTests.swift
//  osaurusTests
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

fileprivate extension URLRequest {
    mutating func disablePersistenceForTests() {
        setValue("false", forHTTPHeaderField: "X-Persist")
    }
}

struct HTTPHandlerChatStreamingTests {

    @Test func requestTaskRegistryCancelsTaskInsertedAfterChannelCancellation() async throws {
        actor Probe {
            private(set) var cancelled = false

            func markCancelled() {
                cancelled = true
            }
        }

        let registry = HTTPHandler.HTTPRequestTaskRegistry()
        let probe = Probe()
        let task = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            await probe.markCancelled()
        }
        defer { task.cancel() }

        registry.cancelAll()
        registry.insert(id: UUID(), task: task)

        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await probe.cancelled)
    }

    @Test func chatCompletions_agentHeaderDoesNotInjectAgentContext() async throws {
        actor Capture {
            var request: ChatCompletionRequest?
            func record(_ request: ChatCompletionRequest) { self.request = request }
        }

        struct CaptureEngine: ChatEngineProtocol {
            let capture: Capture

            func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
                fatalError("not used")
            }

            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                await capture.record(request)
                let choice = ChatChoice(
                    index: 0,
                    message: ChatMessage(role: "assistant", content: "ok"),
                    finish_reason: "stop"
                )
                return ChatCompletionResponse(
                    id: "chatcmpl-test",
                    created: 0,
                    model: request.model,
                    choices: [choice],
                    usage: Usage(prompt_tokens: 0, completion_tokens: 0, total_tokens: 0),
                    system_fingerprint: nil
                )
            }
        }

        try await SandboxTestLock.runWithStoragePaths {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-http-strict-context-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            AgentManager.shared.refresh()
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                AgentManager.shared.refresh()
                try? FileManager.default.removeItem(at: root)
            }

            let agent = Agent(
                name: "HTTPStrictContext-\(UUID().uuidString.prefix(6))",
                systemPrompt: "DO-NOT-INJECT-HTTP-CONTEXT",
                agentAddress: "http-strict-\(UUID().uuidString)",
                manualToolNames: ["capabilities_discover"]
            )
            AgentManager.shared.add(agent)

            let capture = Capture()
            let server = try await startTestServer(with: CaptureEngine(capture: capture))
            defer { Task { await server.shutdown() } }

            let clientTool = Tool(
                type: "function",
                function: ToolFunction(
                    name: "client_only_tool",
                    description: "Client supplied tool",
                    parameters: .object(["type": .string("object")])
                )
            )
            var request = URLRequest(
                url: URL(string: "http://\(server.host):\(server.port)/chat/completions")!
            )
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(agent.id.uuidString, forHTTPHeaderField: "X-Osaurus-Agent-Id")
            request.authenticate()
            request.disablePersistenceForTests()
            let reqBody = ChatCompletionRequest(
                model: "fake",
                messages: [ChatMessage(role: "user", content: "plain API request")],
                temperature: 0.5,
                max_tokens: 16,
                stream: false,
                top_p: nil,
                frequency_penalty: nil,
                presence_penalty: nil,
                stop: nil,
                n: nil,
                tools: [clientTool],
                tool_choice: nil,
                session_id: nil
            )
            request.httpBody = try JSONEncoder().encode(reqBody)

            let (_, resp) = try await URLSession.shared.data(for: request)
            #expect((resp as? HTTPURLResponse)?.statusCode == 200)

            let captured = await capture.request
            #expect(captured?.messages.count == 1)
            #expect(captured?.messages.first?.role == "user")
            #expect(captured?.messages.first?.content == "plain API request")
            #expect(captured?.messages.contains { $0.role == "system" } == false)
            #expect(captured?.messages.first?.content?.contains("[Memory]") == false)
            #expect(captured?.messages.first?.content?.contains("DO-NOT-INJECT-HTTP-CONTEXT") == false)
            #expect(captured?.tools?.map(\.function.name) == ["client_only_tool"])
            #expect(captured?.tool_choice == nil)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test func nonStreamingChatCompletions_preservesTokensPerSecondInUsage() async throws {
        struct StatsEngine: ChatEngineProtocol {
            func streamChat(request _: ChatCompletionRequest) async throws -> AsyncThrowingStream<
                String, Error
            > {
                fatalError("not used")
            }

            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                ChatCompletionResponse(
                    id: "chatcmpl-test",
                    created: 0,
                    model: request.model,
                    choices: [
                        ChatChoice(
                            index: 0,
                            message: ChatMessage(role: "assistant", content: "ok"),
                            finish_reason: "stop"
                        )
                    ],
                    usage: Usage(
                        prompt_tokens: 3,
                        completion_tokens: 4,
                        total_tokens: 7,
                        tokens_per_second: 88.25
                    ),
                    system_fingerprint: nil
                )
            }
        }

        let server = try await startTestServer(with: StatsEngine())
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/chat/completions")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.authenticate()
        request.disablePersistenceForTests()
        request.httpBody = #"""
            {"model":"fake","stream":false,"messages":[{"role":"user","content":"hi"}]}
            """#.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let body = String(decoding: data, as: UTF8.self)
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
        #expect(body.contains("\"tokens_per_second\":88.25"))
    }

    @Test func sse_path_writes_role_content_finish_done() async throws {
        let server = try await startTestServer(
            with: MockChatEngine(deltas: ["a", "b", "c"], completeText: "", model: "fake")
        )
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/chat/completions")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.authenticate()
        request.disablePersistenceForTests()
        let reqBody = ChatCompletionRequest(
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
        request.httpBody = try JSONEncoder().encode(reqBody)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 200)
        #expect(body.contains("\"role\":\"assistant\""))
        #expect(body.contains("data: [DONE]"))
        #expect(body.contains("a"))
        #expect(body.contains("b"))
        #expect(body.contains("c"))
    }

    @Test func ndjson_path_writes_content_and_done_when_streaming() async throws {
        let server = try await startTestServer(
            with: MockChatEngine(deltas: ["x", "y"], completeText: "", model: "fake")
        )
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/chat")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.authenticate()
        request.disablePersistenceForTests()
        let reqBody = ChatCompletionRequest(
            model: "fake",
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: 0.2,
            max_tokens: 8,
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
        request.httpBody = try JSONEncoder().encode(reqBody)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 200)
        #expect(body.contains("\"content\":\"x\""))
        #expect(body.contains("\"content\":\"y\""))
        #expect(body.contains("\"done\":true") || body.contains("\"done\": true"))
    }

    @Test func ollama_chat_non_streaming_returns_single_message_object() async throws {
        let server = try await startTestServer(
            with: MockChatEngine(deltas: [], completeText: "hello", model: "fake")
        )
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/api/chat")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.authenticate()
        request.disablePersistenceForTests()
        let reqBody = ChatCompletionRequest(
            model: "fake",
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: 0.2,
            max_tokens: 8,
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
        request.httpBody = try JSONEncoder().encode(reqBody)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let http = resp as? HTTPURLResponse
        let body = String(decoding: data, as: UTF8.self)
        #expect(http?.statusCode == 200)
        #expect(http?.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true)
        #expect(body.contains("\"message\""))
        #expect(body.contains("\"content\":\"hello\""))
        #expect(body.contains("\"done\":true") || body.contains("\"done\": true"))
        #expect(body.split(separator: "\n").count <= 1)
    }

    @Test func ollama_generate_streaming_writes_response_chunks_and_done() async throws {
        let server = try await startTestServer(
            with: MockChatEngine(deltas: ["x", "y"], completeText: "", model: "fake")
        )
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/api/generate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.authenticate()
        request.disablePersistenceForTests()
        request.httpBody = """
            {"model":"fake","prompt":"hi","stream":true,"options":{"num_predict":8}}
            """.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 200)
        #expect(body.contains("\"response\":\"x\""))
        #expect(body.contains("\"response\":\"y\""))
        #expect(body.contains("\"done\":true") || body.contains("\"done\": true"))
        #expect(!body.contains("\"message\""))
    }

    @Test func ollama_generate_non_streaming_returns_single_response_object() async throws {
        let server = try await startTestServer(
            with: MockChatEngine(deltas: [], completeText: "hello", model: "fake")
        )
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/api/generate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.authenticate()
        request.disablePersistenceForTests()
        request.httpBody = """
            {"model":"fake","prompt":"hi","stream":false,"options":{"num_predict":8}}
            """.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let http = resp as? HTTPURLResponse
        let body = String(decoding: data, as: UTF8.self)
        #expect(http?.statusCode == 200)
        #expect(http?.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true)
        #expect(body.contains("\"response\":\"hello\""))
        #expect(body.contains("\"done\":true") || body.contains("\"done\": true"))
        #expect(body.split(separator: "\n").count <= 1)
    }

    @Test func ollama_chat_drops_reasoning_sentinel_from_plaintext_ndjson() async throws {
        let server = try await startTestServer(
            with: MockChatEngine(
                deltas: [StreamingReasoningHint.encode("private reasoning"), "visible"],
                completeText: "",
                model: "fake"
            )
        )
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/api/chat")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.authenticate()
        request.disablePersistenceForTests()
        let reqBody = ChatCompletionRequest(
            model: "fake",
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: 0.2,
            max_tokens: 8,
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
        request.httpBody = try JSONEncoder().encode(reqBody)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 200)
        #expect(body.contains("visible"))
        #expect(!body.contains("private reasoning"))
        #expect(!body.contains("\u{FFFE}"))
    }

    @Test func ndjson_api_chat_emits_ollama_tool_calls() async throws {
        struct ToolCallEngine: ChatEngineProtocol {
            func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { continuation in
                    continuation.finish(
                        throwing: ServiceToolInvocation(
                            toolName: "get_weather",
                            jsonArguments: "{\"city\":\"SF\",\"count\":\"7\"}"
                        )
                    )
                }
            }
            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                fatalError("not used")
            }
        }

        let server = try await startTestServer(with: ToolCallEngine())
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/api/chat")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.authenticate()
        request.disablePersistenceForTests()
        let reqBody = ChatCompletionRequest(
            model: "fake",
            messages: [ChatMessage(role: "user", content: "weather?")],
            temperature: 0.2,
            max_tokens: 8,
            stream: true,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: [
                Tool(
                    type: "function",
                    function: ToolFunction(
                        name: "get_weather",
                        description: nil,
                        parameters: .object([
                            "type": .string("object"),
                            "properties": .object([
                                "city": .object(["type": .string("string")]),
                                "count": .object(["type": .string("integer")]),
                            ]),
                            "required": .array([.string("city"), .string("count")]),
                        ])
                    )
                )
            ],
            tool_choice: .auto,
            session_id: nil
        )
        request.httpBody = try JSONEncoder().encode(reqBody)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 200)
        #expect(!body.contains("internal_error"))
        #expect(!body.contains("ServiceToolInvocation"))
        #expect(body.contains("\"tool_calls\""))
        #expect(body.contains("\"name\":\"get_weather\""))
        #expect(body.contains("\"city\":\"SF\""))
        #expect(body.contains("\"done\":true") || body.contains("\"done\": true"))
    }

    @Test func sse_path_emits_tool_calls_deltas() async throws {
        // Engine that immediately requests a tool call via throwing stream
        struct MockToolCallEngine: ChatEngineProtocol {
            func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<
                String, Error
            > {
                AsyncThrowingStream { continuation in
                    continuation.finish(
                        throwing: ServiceToolInvocation(
                            toolName: "get_weather",
                            jsonArguments: "{\"city\":\"SF\",\"count\":\"7\"}"
                        )
                    )
                }
            }
            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                fatalError("not used")
            }
        }

        let server = try await startTestServer(with: MockToolCallEngine())
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/chat/completions")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.authenticate()
        request.disablePersistenceForTests()
        let reqBody = ChatCompletionRequest(
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
            tools: [
                Tool(
                    type: "function",
                    function: ToolFunction(
                        name: "get_weather",
                        description: nil,
                        parameters: .object([
                            "type": .string("object"),
                            "properties": .object([
                                "city": .object(["type": .string("string")]),
                                "count": .object(["type": .string("integer")]),
                            ]),
                            "required": .array([.string("city"), .string("count")]),
                        ])
                    )
                )
            ],
            tool_choice: .auto,
            session_id: nil
        )
        request.httpBody = try JSONEncoder().encode(reqBody)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 200)
        #expect(body.contains("\"tool_calls\""))
        #expect(body.contains("\"function\":{\"name\":\"get_weather\""))
        #expect(body.contains("\\\"count\\\":7"))
        #expect(!body.contains("\\\"count\\\":\\\"7\\\""))
        #expect(body.contains("\"finish_reason\":\"tool_calls\""))
    }
    @Test func sse_path_emits_reasoning_content_field() async throws {
        // Engine that yields a reasoning sentinel followed by a content
        // chunk. The HTTP SSE handler must decode the sentinel BEFORE
        // the generic `StreamingToolHint.isSentinel` filter, otherwise
        // the reasoning silently disappears.
        struct ReasoningEngine: ChatEngineProtocol {
            func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<
                String, Error
            > {
                AsyncThrowingStream { continuation in
                    continuation.yield(StreamingReasoningHint.encode("thinking..."))
                    continuation.yield("hello")
                    continuation.finish()
                }
            }
            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                fatalError("not used")
            }
        }

        let server = try await startTestServer(with: ReasoningEngine())
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/chat/completions")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.authenticate()
        request.disablePersistenceForTests()
        let reqBody = ChatCompletionRequest(
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
        request.httpBody = try JSONEncoder().encode(reqBody)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 200)
        // Reasoning text appears on the OpenAI extended `reasoning_content`
        // field, not on the regular `content` field.
        #expect(body.contains("\"reasoning_content\":\"thinking...\""))
        // The follow-up content chunk still rides on `content`.
        #expect(body.contains("\"content\":\"hello\""))
        // The sentinel itself never makes it onto the wire.
        #expect(!body.contains("\u{FFFE}"))
    }

    @Test func sse_path_uses_engine_stats_for_usage_chunk() async throws {
        struct StatsEngine: ChatEngineProtocol {
            func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<
                String, Error
            > {
                AsyncThrowingStream { continuation in
                    continuation.yield("hello")
                    continuation.yield(
                        StreamingStatsHint.encode(
                            tokenCount: 77,
                            tokensPerSecond: 12.5,
                            stopReason: "length"
                        )
                    )
                    continuation.finish()
                }
            }
            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                fatalError("not used")
            }
        }

        let server = try await startTestServer(with: StatsEngine())
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/chat/completions")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.authenticate()
        request.disablePersistenceForTests()
        request.httpBody = #"""
            {"model":"fake","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"user","content":"hi"}]}
            """#.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 200)
        #expect(body.contains("\"content\":\"hello\""))
        #expect(body.contains("\"completion_tokens\":77"))
        #expect(body.contains("\"tokens_per_second\":12.5"))
        #expect(body.contains("\"finish_reason\":\"length\""))
        #expect(!body.contains("\u{FFFE}"))
    }

    @Test func sse_path_emits_prefill_progress_diagnostic_chunks() async throws {
        struct PrefillEngine: ChatEngineProtocol {
            func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<
                String, Error
            > {
                AsyncThrowingStream { continuation in
                    continuation.yield(
                        StreamingPrefillProgressHint.encode(
                            PrefillProgressState(
                                stage: .prefill,
                                completedUnitCount: 128,
                                totalUnitCount: 512,
                                detail: "model.prepare"
                            )
                        )
                    )
                    continuation.yield("answer")
                    continuation.finish()
                }
            }
            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                fatalError("not used")
            }
        }

        let server = try await startTestServer(with: PrefillEngine())
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/chat/completions")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.authenticate()
        request.disablePersistenceForTests()
        request.httpBody = #"""
            {"model":"fake","stream":true,"messages":[{"role":"user","content":"hi"}]}
            """#.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 200)
        #expect(body.contains("\"osaurus_prefill\""))
        #expect(body.contains("\"stage\":\"prefill\""))
        #expect(body.contains("\"completedUnitCount\":128"))
        #expect(body.contains("\"totalUnitCount\":512"))
        #expect(body.contains("\"content\":\"answer\""))
        #expect(!body.contains("\u{FFFE}"))
    }

    @Test func sse_path_emits_multi_tool_batch_deltas() async throws {
        // Engine that throws ServiceToolInvocations carrying two
        // invocations. The HTTP SSE handler must emit one `tool_calls`
        // delta per invocation followed by a single shared
        // `finish_reason: "tool_calls"`.
        struct MultiToolEngine: ChatEngineProtocol {
            func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<
                String, Error
            > {
                AsyncThrowingStream { continuation in
                    continuation.finish(
                        throwing: ServiceToolInvocations(
                            invocations: [
                                ServiceToolInvocation(
                                    toolName: "get_weather",
                                    jsonArguments: "{\"city\":\"SF\"}"
                                ),
                                ServiceToolInvocation(
                                    toolName: "get_time",
                                    jsonArguments: "{\"tz\":\"PT\"}"
                                ),
                            ]
                        )
                    )
                }
            }
            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                fatalError("not used")
            }
        }

        let server = try await startTestServer(with: MultiToolEngine())
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/chat/completions")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.authenticate()
        request.disablePersistenceForTests()
        let reqBody = ChatCompletionRequest(
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
            tools: [
                Tool(
                    type: "function",
                    function: ToolFunction(
                        name: "get_weather",
                        description: nil,
                        parameters: .object(["city": .string("")])
                    )
                ),
                Tool(
                    type: "function",
                    function: ToolFunction(
                        name: "get_time",
                        description: nil,
                        parameters: .object(["tz": .string("")])
                    )
                ),
            ],
            tool_choice: .auto,
            session_id: nil
        )
        request.httpBody = try JSONEncoder().encode(reqBody)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 200)
        // Both function names must surface, on different `tool_calls.index` slots.
        #expect(body.contains("\"function\":{\"name\":\"get_weather\""))
        #expect(body.contains("\"function\":{\"name\":\"get_time\""))
        #expect(body.contains("\"index\":0"))
        #expect(body.contains("\"index\":1"))
        // A single shared finish_reason closes the response.
        #expect(body.contains("\"finish_reason\":\"tool_calls\""))
        let finishCount = body.components(separatedBy: "\"finish_reason\":\"tool_calls\"").count - 1
        #expect(finishCount == 1)
    }

    @Test func agent_run_executes_tool_without_streaming_internal_sentinels() async throws {
        actor AgentToolLoopEngine: ChatEngineProtocol {
            private var calls = 0
            private(set) var sawToolMessage = false

            func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
                calls += 1
                if calls == 1 {
                    return AsyncThrowingStream { continuation in
                        continuation.finish(
                            throwing: ServiceToolInvocation(
                                toolName: "complete",
                                jsonArguments: #"{"summary":"agent-run sentinel test"}"#
                            )
                        )
                    }
                }

                sawToolMessage = request.messages.contains { $0.role == "tool" && ($0.content?.isEmpty == false) }
                return AsyncThrowingStream { continuation in
                    continuation.yield("TOOLLOOP-FINAL")
                    continuation.finish()
                }
            }

            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                fatalError("not used")
            }
        }

        // Isolate the throwaway custom agent to a temp storage root so it
        // never lands in the live `~/.osaurus/agents` store and is torn down
        // with the directory (mirrors the strict-context test above).
        try await SandboxTestLock.runWithStoragePaths {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-http-agent-run-sentinel-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            AgentManager.shared.refresh()
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                AgentManager.shared.refresh()
                try? FileManager.default.removeItem(at: root)
            }

            let engine = AgentToolLoopEngine()
            // Loopback-trusted: remote plaintext `/agents/{id}/run` is now
            // refused with 426 (Secure Channel hard-require); this test is
            // about tool-loop sentinel scrubbing, not transport security.
            let server = try await startTestServer(with: engine, trustLoopback: true)
            defer { Task { await server.shutdown() } }

            // The built-in Default agent UUID is locked to in-app surfaces
            // (`Agent.rejectBuiltInForExternalSurface`), so `/agents/<defaultId>/run`
            // returns a `built_in_agent_not_exposable` envelope. Use a custom
            // agent so the tool-loop sentinel scrubbing path is what we're
            // actually exercising.
            let scopedAgent = Agent(
                name: "HTTPAgentRunSentinel-\(UUID().uuidString.prefix(6))",
                systemPrompt: "Test identity",
                agentAddress: "http-agent-run-\(UUID().uuidString)"
            )
            AgentManager.shared.add(scopedAgent)

            var request = URLRequest(
                url: URL(
                    string:
                        "http://\(server.host):\(server.port)/agents/\(scopedAgent.id.uuidString)/run"
                )!
            )
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.authenticate()
            request.disablePersistenceForTests()
            let reqBody = ChatCompletionRequest(
                model: "fake",
                messages: [ChatMessage(role: "user", content: "call complete then answer")],
                temperature: 0,
                max_tokens: 64,
                stream: true,
                top_p: 1,
                frequency_penalty: nil,
                presence_penalty: nil,
                stop: nil,
                n: nil,
                tools: [
                    Tool(
                        type: "function",
                        function: ToolFunction(
                            name: "complete",
                            description: "Mark the agent task complete.",
                            parameters: .object(["summary": .string("")])
                        )
                    )
                ],
                tool_choice: .function(
                    ToolChoiceOption.FunctionName(
                        type: "function",
                        function: ToolChoiceOption.Name(name: "complete")
                    )
                ),
                session_id: nil
            )
            request.httpBody = try JSONEncoder().encode(reqBody)

            let (data, resp) = try await URLSession.shared.data(for: request)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(decoding: data, as: UTF8.self)
            #expect(status == 200)
            #expect(body.contains("TOOLLOOP-FINAL"))
            #expect(await engine.sawToolMessage)
            #expect(body.contains("\"osaurus_agent_tool\""))
            #expect(body.contains("\"choices\":[]"))
            #expect(body.contains("\"phase\":\"started\""))
            #expect(body.contains("\"phase\":\"completed\""))
            #expect(body.contains("\"name\":\"complete\""))
            #expect(!body.contains("X-Osaurus-Debug-Agent-Tools"))
            #expect(!body.contains("\u{FFFE}tool:"))
            #expect(!body.contains("\u{FFFE}args:"))
            #expect(!body.contains("\u{FFFE}done:"))
            #expect(!body.contains("agent-run sentinel test"))
        }
    }

    @Test func agentRun_gemmaQATPostToolFinalizationKeepsToolsVisibleForCacheStability() async throws {
        actor GemmaQATToolChoiceEngine: ChatEngineProtocol {
            private var calls = 0
            private(set) var requests: [ChatCompletionRequest] = []

            func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<
                String, Error
            > {
                calls += 1
                requests.append(request)
                if calls == 1 {
                    return AsyncThrowingStream { continuation in
                        continuation.finish(
                            throwing: ServiceToolInvocation(
                                toolName: "osaurus_status",
                                jsonArguments: "{}"
                            )
                        )
                    }
                }

                return AsyncThrowingStream { continuation in
                    continuation.yield("The current model id is osaurusai--gemma-4-12b-it-qat-jang_4m.")
                    continuation.finish()
                }
            }

            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                fatalError("not used")
            }
        }

        try await SandboxTestLock.runWithStoragePaths {
            ConfigurationDomainBootstrap.registerBuiltIns()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-http-gemma-qat-post-tool-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            AgentManager.shared.refresh()
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                AgentManager.shared.refresh()
                try? FileManager.default.removeItem(at: root)
            }

            let engine = GemmaQATToolChoiceEngine()
            let server = try await startTestServer(with: engine, trustLoopback: true)
            defer { Task { await server.shutdown() } }

            var request = URLRequest(
                url: URL(string: "http://\(server.host):\(server.port)/agents/default/run")!
            )
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.disablePersistenceForTests()
            let reqBody = ChatCompletionRequest(
                model: "osaurusai--gemma-4-12b-it-qat-jang_4m",
                messages: [ChatMessage(role: "user", content: "Use osaurus_status, then answer.")],
                temperature: 0,
                max_tokens: 64,
                stream: true,
                top_p: 1,
                frequency_penalty: nil,
                presence_penalty: nil,
                stop: nil,
                n: nil,
                tools: nil,
                tool_choice: .auto,
                session_id: nil
            )
            request.httpBody = try JSONEncoder().encode(reqBody)

            let (data, resp) = try await URLSession.shared.data(for: request)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(decoding: data, as: UTF8.self)
            #expect(status == 200)
            #expect(body.contains("The current model id is osaurusai--gemma-4-12b-it-qat-jang_4m."))

            let requests = await engine.requests
            #expect(requests.count == 2)
            if case .some(.auto) = requests[0].tool_choice {
                // Expected first iteration still allows the model to call tools.
            } else {
                Issue.record("Expected first Gemma QAT agent request to use tool_choice auto.")
            }
            // The post-tool finalization step must keep the SAME tool_choice
            // (and therefore the rendered `<tools>` block) so the prompt stays a
            // strict extension of the calling step. Downgrading to `.none` used
            // to strip the tools block, shrinking the prompt below the prefix and
            // forcing a full KV re-prefill; the prose corruption that motivated
            // that workaround is fixed upstream.
            if case .some(.auto) = requests[1].tool_choice {
                // Expected: tools stay visible on the finalization step.
            } else {
                Issue.record("Expected Gemma QAT post-tool request to keep tool_choice auto for KV prefix stability.")
            }
            #expect(requests[1].messages.last?.role == "tool")
            #expect(requests[1].tools?.isEmpty == false)
        }
    }

    @Test func agentRun_streamsStartedAndCompletedForNonInterceptToolBatch() async throws {
        actor StatusToolEngine: ChatEngineProtocol {
            private var calls = 0

            func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<
                String, Error
            > {
                calls += 1
                if calls == 1 {
                    return AsyncThrowingStream { continuation in
                        continuation.finish(
                            throwing: ServiceToolInvocation(
                                toolName: "osaurus_status",
                                jsonArguments: "{}"
                            )
                        )
                    }
                }

                return AsyncThrowingStream { continuation in
                    continuation.yield("status tool finished")
                    continuation.finish()
                }
            }

            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                fatalError("not used")
            }
        }

        try await SandboxTestLock.runWithStoragePaths {
            ConfigurationDomainBootstrap.registerBuiltIns()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-http-agent-run-non-intercept-trace-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            AgentManager.shared.refresh()
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                AgentManager.shared.refresh()
                try? FileManager.default.removeItem(at: root)
            }

            let server = try await startTestServer(with: StatusToolEngine(), trustLoopback: true)
            defer { Task { await server.shutdown() } }

            var request = URLRequest(
                url: URL(string: "http://\(server.host):\(server.port)/agents/default/run")!
            )
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.disablePersistenceForTests()
            request.httpBody = #"""
                {"model":"fake","stream":true,"tool_choice":"auto","messages":[{"role":"user","content":"use osaurus_status"}]}
                """#.data(using: .utf8)

            let (data, resp) = try await URLSession.shared.data(for: request)
            let body = String(decoding: data, as: UTF8.self)
            #expect((resp as? HTTPURLResponse)?.statusCode == 200)
            #expect(body.contains("\"osaurus_agent_tool\""))
            #expect(body.contains("\"phase\":\"started\""))
            #expect(body.contains("\"phase\":\"completed\""))
            #expect(body.contains("\"name\":\"osaurus_status\""))
            #expect(body.contains("status tool finished"))
        }
    }

    // MARK: - Built-in agent loopback exposure (App Intents surface)

    /// `/agents/{id}/run` must use the same composer-resolved tool surface it
    /// renders into the agent prompt. The strict OpenAI `/chat/completions`
    /// path intentionally stays bare/stateless, but an agent run needs
    /// per-agent gates: the Default agent gets its fixed configure baseline,
    /// while custom agents must not see Default-agent-only `osaurus_*` tools.
    @Test func agentRun_usesComposerResolvedToolSurface() async throws {
        actor CaptureEngine: ChatEngineProtocol {
            private(set) var requests: [ChatCompletionRequest] = []

            func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<
                String, Error
            > {
                requests.append(request)
                return AsyncThrowingStream { continuation in
                    continuation.yield("OK")
                    continuation.finish()
                }
            }

            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                fatalError("not used")
            }
        }

        try await SandboxTestLock.runWithStoragePaths {
            ConfigurationDomainBootstrap.registerBuiltIns()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-http-agent-run-tools-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            AgentManager.shared.refresh()
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                AgentManager.shared.refresh()
                try? FileManager.default.removeItem(at: root)
            }

            let custom = Agent(
                name: "HTTPAgentRunTools-\(UUID().uuidString.prefix(6))",
                systemPrompt: "Test identity",
                agentAddress: "http-agent-run-tools-\(UUID().uuidString)"
            )
            AgentManager.shared.add(custom)

            let engine = CaptureEngine()
            let server = try await startTestServer(with: engine, trustLoopback: true)
            defer { Task { await server.shutdown() } }

            func postRun(agentId: UUID, authenticate: Bool) async throws -> String {
                var request = URLRequest(
                    url: URL(
                        string: "http://\(server.host):\(server.port)/agents/\(agentId.uuidString)/run"
                    )!
                )
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                if authenticate { request.authenticate() }
                request.disablePersistenceForTests()
                request.httpBody = #"""
                    {"model":"fake","stream":true,"messages":[{"role":"user","content":"hi"}]}
                    """#.data(using: .utf8)
                let (data, resp) = try await URLSession.shared.data(for: request)
                #expect((resp as? HTTPURLResponse)?.statusCode == 200)
                return String(decoding: data, as: UTF8.self)
            }

            let defaultBody = try await postRun(agentId: Agent.defaultId, authenticate: false)
            let customBody = try await postRun(agentId: custom.id, authenticate: true)
            #expect(!defaultBody.contains("\"osaurus_agent_tool\""))
            #expect(!customBody.contains("\"osaurus_agent_tool\""))

            let requests = await engine.requests
            #expect(requests.count == 2)
            let defaultNames = Set(requests[0].tools?.map(\.function.name) ?? [])
            #expect(defaultNames == ToolRegistry.defaultAgentAllowedToolNames)

            let customNames = Set(requests[1].tools?.map(\.function.name) ?? [])
            for configure in ToolRegistry.configureToolNames {
                #expect(
                    !customNames.contains(configure),
                    "configure tool \(configure) leaked into custom-agent run schema"
                )
            }
            _ = await AgentManager.shared.delete(id: custom.id)
        }
    }

    /// Loopback callers (no auth, same machine) may reach the built-in Default
    /// agent via `/agents/{id}/run` so the App Intents "Ask Osaurus" surface
    /// can drive it. The request must pass the built-in guard rather than
    /// returning a `built_in_agent_not_exposable` envelope.
    @Test func builtInAgentRun_overLoopback_bypassesGuard() async throws {
        struct EchoEngine: ChatEngineProtocol {
            func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<
                String, Error
            > {
                AsyncThrowingStream { continuation in
                    continuation.yield("OK-BUILTIN")
                    continuation.finish()
                }
            }
            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                fatalError("not used")
            }
        }

        let server = try await startTestServer(with: EchoEngine(), trustLoopback: true)
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(
                string:
                    "http://\(server.host):\(server.port)/agents/\(Agent.defaultId.uuidString)/run"
            )!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.disablePersistenceForTests()
        request.httpBody = #"""
            {"model":"fake","stream":true,"messages":[{"role":"user","content":"hi"}]}
            """#.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        // Headers are flushed as 200 once the guard is cleared and streaming
        // begins, so a passing guard yields 200 (never the 403 envelope).
        #expect(status == 200)
        #expect(!body.contains("built_in_agent_not_exposable"))
    }

    @Test func builtInAgentRun_defaultAlias_overLoopback_bypassesGuard() async throws {
        struct EchoEngine: ChatEngineProtocol {
            func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<
                String, Error
            > {
                AsyncThrowingStream { continuation in
                    continuation.yield("OK-BUILTIN-DEFAULT-ALIAS")
                    continuation.finish()
                }
            }
            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                fatalError("not used")
            }
        }

        let server = try await startTestServer(with: EchoEngine(), trustLoopback: true)
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/agents/default/run")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.disablePersistenceForTests()
        request.httpBody = #"""
            {"model":"fake","stream":true,"messages":[{"role":"user","content":"hi"}]}
            """#.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 200)
        #expect(body.contains("OK-BUILTIN-DEFAULT-ALIAS"))
        #expect(!body.contains("invalid_agent_id"))
        #expect(!body.contains("built_in_agent_not_exposable"))
    }

    /// Non-loopback (remote) callers remain blocked from the built-in agent
    /// even with a valid API key. With the Secure Channel hard-require in
    /// place, remote plaintext is stopped even earlier: at the 426 gate,
    /// before the built-in guard runs. (The guard itself is exercised for
    /// encrypted remote callers in `SecureChannelE2ETests`.)
    @Test func builtInAgentRun_remote_isRejected() async throws {
        struct UnusedEngine: ChatEngineProtocol {
            func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<
                String, Error
            > { fatalError("not used") }
            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                fatalError("not used")
            }
        }

        // trustLoopback: false makes `isLoopbackConnection` return false, so the
        // 127.0.0.1 test client is treated as a remote caller.
        let server = try await startTestServer(with: UnusedEngine(), trustLoopback: false)
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(
                string:
                    "http://\(server.host):\(server.port)/agents/\(Agent.defaultId.uuidString)/run"
            )!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.authenticate()
        request.disablePersistenceForTests()
        request.httpBody = #"""
            {"model":"fake","stream":true,"messages":[{"role":"user","content":"hi"}]}
            """#.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 426)
        #expect(body.contains("secure_channel_required"))
    }

    // MARK: - Anthropic streaming (`/messages?stream=true`)

    @Test func anthropic_sse_emits_thinking_delta_for_reasoning_sentinel() async throws {
        struct ReasoningEngine: ChatEngineProtocol {
            func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<
                String, Error
            > {
                AsyncThrowingStream { continuation in
                    continuation.yield(StreamingReasoningHint.encode("hi"))
                    continuation.yield("answer")
                    continuation.finish()
                }
            }
            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                fatalError("not used")
            }
        }
        let server = try await startTestServer(with: ReasoningEngine())
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.authenticate()
        request.disablePersistenceForTests()
        let bodyJSON = #"""
            {"model":"fake","max_tokens":16,"stream":true,"messages":[{"role":"user","content":"hi"}]}
            """#
        request.httpBody = bodyJSON.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 200)
        #expect(body.contains("\"type\":\"thinking_delta\""))
        #expect(body.contains("\"thinking\":\"hi\""))
        #expect(body.contains("\"type\":\"text_delta\""))
        #expect(body.contains("\"text\":\"answer\""))
        #expect(!body.contains("\u{FFFE}"))
    }

    @Test func anthropic_sse_uses_engine_stats_for_output_tokens() async throws {
        struct StatsEngine: ChatEngineProtocol {
            func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<
                String, Error
            > {
                AsyncThrowingStream { continuation in
                    continuation.yield("answer")
                    continuation.yield(StreamingStatsHint.encode(tokenCount: 77, tokensPerSecond: 12.5))
                    continuation.finish()
                }
            }
            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                fatalError("not used")
            }
        }
        let server = try await startTestServer(with: StatsEngine())
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.authenticate()
        request.disablePersistenceForTests()
        request.httpBody = #"""
            {"model":"fake","max_tokens":16,"stream":true,"messages":[{"role":"user","content":"hi"}]}
            """#.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 200)
        #expect(body.contains("\"type\":\"message_delta\""))
        #expect(body.contains("\"output_tokens\":77"))
        #expect(!body.contains("\u{FFFE}"))
    }

    @Test func anthropic_sse_emits_multi_tool_batch() async throws {
        struct MultiToolEngine: ChatEngineProtocol {
            func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<
                String, Error
            > {
                AsyncThrowingStream { continuation in
                    continuation.finish(
                        throwing: ServiceToolInvocations(
                            invocations: [
                                ServiceToolInvocation(
                                    toolName: "get_weather",
                                    jsonArguments: "{\"city\":\"SF\"}"
                                ),
                                ServiceToolInvocation(
                                    toolName: "get_time",
                                    jsonArguments: "{\"tz\":\"PT\"}"
                                ),
                            ]
                        )
                    )
                }
            }
            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                fatalError("not used")
            }
        }
        let server = try await startTestServer(with: MultiToolEngine())
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.authenticate()
        request.disablePersistenceForTests()
        let bodyJSON = #"""
            {"model":"fake","max_tokens":16,"stream":true,"messages":[{"role":"user","content":"hi"}]}
            """#
        request.httpBody = bodyJSON.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 200)
        // Both tool_use blocks are emitted, with one shared tool_use stop.
        #expect(body.contains("\"name\":\"get_weather\""))
        #expect(body.contains("\"name\":\"get_time\""))
        let stopCount = body.components(separatedBy: "\"stop_reason\":\"tool_use\"").count - 1
        #expect(stopCount == 1)
    }

    // MARK: - OpenResponses context + streaming (`/responses`)

    @Test func openresponses_previous_response_id_prepends_stored_context() async throws {
        final class ContextEchoEngine: ChatEngineProtocol, @unchecked Sendable {
            private let lock = NSLock()
            private var callCount = 0
            private let codeword = "PR1173-PREVCTX-UNIT"

            func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<
                String, Error
            > {
                fatalError("not used")
            }

            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                let output: String = lock.withLock {
                    defer { callCount += 1 }
                    if callCount == 0 {
                        return "ACK"
                    }
                    let joined = request.messages.compactMap(\.content).joined(separator: "\n")
                    return joined.contains(codeword) ? codeword : "NO_CONTEXT"
                }
                let choice = ChatChoice(
                    index: 0,
                    message: ChatMessage(role: "assistant", content: output),
                    finish_reason: "stop"
                )
                return ChatCompletionResponse(
                    id: "chatcmpl-test",
                    created: 1,
                    model: "fake",
                    choices: [choice],
                    usage: Usage(prompt_tokens: 1, completion_tokens: 1, total_tokens: 2),
                    system_fingerprint: nil
                )
            }
        }

        let server = try await startTestServer(with: ContextEchoEngine())
        defer { Task { await server.shutdown() } }

        func post(_ json: String) async throws -> OpenResponsesResponse {
            var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/responses")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.authenticate()
            request.disablePersistenceForTests()
            request.httpBody = json.data(using: .utf8)
            let (data, resp) = try await URLSession.shared.data(for: request)
            #expect((resp as? HTTPURLResponse)?.statusCode == 200)
            return try JSONDecoder().decode(OpenResponsesResponse.self, from: data)
        }

        let first = try await post(
            #"""
            {"model":"fake","input":"Remember PR1173-PREVCTX-UNIT. Reply ACK.","stream":false}
            """#
        )
        #expect(first.output_text == "ACK")

        let second = try await post(
            """
            {"model":"fake","previous_response_id":"\(first.id)","input":"What was the codeword?","stream":false}
            """
        )
        #expect(second.output_text == "PR1173-PREVCTX-UNIT")
    }

    // MARK: - OpenResponses streaming (`/responses?stream=true`)

    @Test func openresponses_sse_emits_reasoning_summary_text_events() async throws {
        struct ReasoningThenTextEngine: ChatEngineProtocol {
            func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<
                String, Error
            > {
                AsyncThrowingStream { continuation in
                    continuation.yield(StreamingReasoningHint.encode("considering..."))
                    continuation.yield("answer")
                    continuation.finish()
                }
            }
            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                fatalError("not used")
            }
        }
        let server = try await startTestServer(with: ReasoningThenTextEngine())
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/responses")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.authenticate()
        request.disablePersistenceForTests()
        let bodyJSON = #"""
            {"model":"fake","stream":true,"input":"hi"}
            """#
        request.httpBody = bodyJSON.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 200)
        // Reasoning summary delta + done events fire, and the message
        // item still gets its text delta.
        #expect(body.contains("\"type\":\"response.reasoning_summary_text.delta\""))
        #expect(body.contains("\"delta\":\"considering...\""))
        #expect(body.contains("\"type\":\"response.reasoning_summary_text.done\""))
        #expect(body.contains("\"type\":\"response.output_text.delta\""))
        #expect(body.contains("\"delta\":\"answer\""))
    }

    @Test func openresponses_sse_uses_engine_stats_for_output_tokens() async throws {
        struct StatsEngine: ChatEngineProtocol {
            func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<
                String, Error
            > {
                AsyncThrowingStream { continuation in
                    continuation.yield("answer")
                    continuation.yield(StreamingStatsHint.encode(tokenCount: 77, tokensPerSecond: 12.5))
                    continuation.finish()
                }
            }
            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                fatalError("not used")
            }
        }
        let server = try await startTestServer(with: StatsEngine())
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/responses")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.authenticate()
        request.disablePersistenceForTests()
        request.httpBody = #"""
            {"model":"fake","stream":true,"input":"hi"}
            """#.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 200)
        #expect(body.contains("\"type\":\"response.completed\""))
        #expect(body.contains("\"output_tokens\":77"))
        #expect(!body.contains("\u{FFFE}"))
    }

    @Test func openresponses_sse_does_not_open_message_item_when_only_reasoning() async throws {
        struct OnlyReasoningEngine: ChatEngineProtocol {
            func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<
                String, Error
            > {
                AsyncThrowingStream { continuation in
                    continuation.yield(StreamingReasoningHint.encode("thinking only"))
                    continuation.finish()
                }
            }
            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                fatalError("not used")
            }
        }
        let server = try await startTestServer(with: OnlyReasoningEngine())
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/responses")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.authenticate()
        request.disablePersistenceForTests()
        let bodyJSON = #"""
            {"model":"fake","stream":true,"input":"hi"}
            """#
        request.httpBody = bodyJSON.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 200)
        // Reasoning item opens and closes; no message item is added.
        #expect(body.contains("\"type\":\"response.reasoning_summary_text.delta\""))
        #expect(!body.contains("\"type\":\"response.output_text.delta\""))
        #expect(!body.contains("\"item\":{\"type\":\"message\""))
        #expect(body.contains("\"type\":\"response.completed\""))
    }

    @Test func openresponses_sse_emits_multi_tool_batch() async throws {
        struct MultiToolEngine: ChatEngineProtocol {
            func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<
                String, Error
            > {
                AsyncThrowingStream { continuation in
                    continuation.finish(
                        throwing: ServiceToolInvocations(
                            invocations: [
                                ServiceToolInvocation(
                                    toolName: "get_weather",
                                    jsonArguments: "{\"city\":\"SF\"}"
                                ),
                                ServiceToolInvocation(
                                    toolName: "get_time",
                                    jsonArguments: "{\"tz\":\"PT\"}"
                                ),
                            ]
                        )
                    )
                }
            }
            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                fatalError("not used")
            }
        }
        let server = try await startTestServer(with: MultiToolEngine())
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/responses")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.authenticate()
        request.disablePersistenceForTests()
        let bodyJSON = #"""
            {"model":"fake","stream":true,"input":"hi"}
            """#
        request.httpBody = bodyJSON.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 200)
        // Two function_call items must surface; one final response.completed.
        #expect(body.contains("\"name\":\"get_weather\""))
        #expect(body.contains("\"name\":\"get_time\""))
        let completedCount = body.components(separatedBy: "\"type\":\"response.completed\"").count - 1
        #expect(completedCount == 1)
    }

    @Test func shutdown_during_active_stream_does_not_crash() async throws {
        struct SlowStreamEngine: ChatEngineProtocol {
            func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<
                String, Error
            > {
                AsyncThrowingStream { continuation in
                    Task {
                        for i in 0 ..< 20 {
                            try? await Task.sleep(nanoseconds: 50_000_000)
                            continuation.yield("chunk-\(i)")
                        }
                        continuation.finish()
                    }
                }
            }
            func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
                fatalError("not used")
            }
        }

        let server = try await startTestServer(with: SlowStreamEngine())

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/chat/completions")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.authenticate()
        request.disablePersistenceForTests()
        let reqBody = ChatCompletionRequest(
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
        request.httpBody = try JSONEncoder().encode(reqBody)

        let streamTask = Task {
            try? await URLSession.shared.data(for: request)
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        await server.shutdown()

        streamTask.cancel()
    }
}

// MARK: - Test server bootstrap

private struct TestServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let lease: HTTPServerTestLease
    let host: String
    let port: Int

    func shutdown() async {
        _ = try? await channel.close()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
    }
}

@discardableResult
private func startTestServer(
    with engine: ChatEngineProtocol,
    trustLoopback: Bool = false
) async throws -> TestServer {
    let lease = await HTTPServerTestLock.shared.acquire()
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPHandler(
                            configuration: .default,
                            apiKeyValidator: TestAuth.validator,
                            eventLoop: channel.eventLoop,
                            chatEngine: engine,
                            trustLoopback: trustLoopback
                        )
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        let addr = ch.localAddress
        let port = addr?.port ?? 0
        return TestServer(group: group, channel: ch, lease: lease, host: "127.0.0.1", port: port)
    } catch {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
        throw error
    }
}
