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

struct HTTPHandlerChatStreamingTests {

    @Test func sse_path_writes_role_content_finish_done() async throws {
        let server = try await startTestServer(
            with: MockChatEngine(deltas: ["a", "b", "c"], completeText: "", model: "fake")
        )
        defer { Task { await server.shutdown() } }

        // Build request to SSE endpoint
        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/chat/completions")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
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
}

// MARK: - Test server bootstrap

private struct TestServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let host: String
    let port: Int

    func shutdown() async {
        _ = try? await channel.close()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
    }
}

@discardableResult
private func startTestServer(with engine: ChatEngineProtocol) async throws -> TestServer {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let bootstrap = ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: 256)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap {
                channel.pipeline.addHandler(
                    HTTPHandler(configuration: .default, eventLoop: channel.eventLoop, chatEngine: engine)
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
    return TestServer(group: group, channel: ch, host: "127.0.0.1", port: port)
}
