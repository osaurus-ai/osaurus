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

    @Test func ndjson_path_writes_content_and_done() async throws {
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
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 200)
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
                            jsonArguments: "{\"city\":\"SF\"}"
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
                        parameters: .object(["city": .string("")])
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
private func startTestServer(with engine: ChatEngineProtocol) async throws -> TestServer {
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
                            trustLoopback: false
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
