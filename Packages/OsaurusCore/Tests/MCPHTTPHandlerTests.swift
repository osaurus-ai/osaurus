//
//  MCPHTTPHandlerTests.swift
//  OsaurusCoreTests
//
//  Verifies MCP endpoints mounted on the same port: /mcp/health, /mcp/tools, /mcp/call
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

struct MCPHTTPHandlerTests {

    @Test func mcp_health_returns_ok() async throws {
        let server = try await startTestServer()
        defer { Task { await server.shutdown() } }

        let (data, resp) = try await URLSession.shared.data(
            from: URL(string: "http://\(server.host):\(server.port)/mcp/health")!
        )
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 200)
        #expect(body.contains(#""status":"ok"#))
    }

    @Test func mcp_tools_lists_only_enabled_tools() async throws {
        // Use a temp config directory so enablement doesn't leak
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        await MainActor.run {
            ToolConfigurationStore.overrideDirectory = tempDir
        }
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Register and enable a test tool
        await ToolRegistry.shared.register(EchoTool())
        await ToolRegistry.shared.setEnabled(true, for: EchoTool.nameStatic)

        let server = try await startTestServer()
        defer { Task { await server.shutdown() } }

        let (data, resp) = try await URLSession.shared.data(
            from: URL(string: "http://\(server.host):\(server.port)/mcp/tools")!
        )
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        #expect(status == 200)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tools = (json?["tools"] as? [[String: Any]]) ?? []
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names.contains(EchoTool.nameStatic))
        if let echo = tools.first(where: { ($0["name"] as? String) == EchoTool.nameStatic }) {
            let inputSchema = echo["inputSchema"] as? [String: Any]
            #expect(inputSchema != nil)
        }
    }

    @Test func mcp_call_executes_enabled_tool_and_returns_text_content() async throws {
        // Use a temp config directory so enablement doesn't leak
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        await MainActor.run {
            ToolConfigurationStore.overrideDirectory = tempDir
        }
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Register and enable a test tool
        await ToolRegistry.shared.register(EchoTool())
        await ToolRegistry.shared.setEnabled(true, for: EchoTool.nameStatic)

        let server = try await startTestServer()
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/mcp/call")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bodyObj: [String: Any] = [
            "name": EchoTool.nameStatic,
            "arguments": ["text": "hello"],
        ]
        let body = try JSONSerialization.data(withJSONObject: bodyObj)
        request.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        #expect(status == 200)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let isError = (json?["isError"] as? Bool) ?? true
        #expect(isError == false)
        let content = (json?["content"] as? [[String: Any]]) ?? []
        let text = content.first?["text"] as? String
        #expect(text == #"{"text":"hello"}"#)
    }

    @Test func mcp_call_with_missing_required_arg_returns_error() async throws {
        // Use a temp config directory so enablement doesn't leak
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        await MainActor.run {
            ToolConfigurationStore.overrideDirectory = tempDir
        }
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Register and enable a test tool
        await ToolRegistry.shared.register(EchoTool())
        await ToolRegistry.shared.setEnabled(true, for: EchoTool.nameStatic)

        let server = try await startTestServer()
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/mcp/call")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bodyObj: [String: Any] = [
            "name": EchoTool.nameStatic,
            "arguments": [:],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyObj)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        #expect(status == 200)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let isError = (json?["isError"] as? Bool) ?? false
        #expect(isError == true)
    }
}

// MARK: - Test tool

private struct EchoTool: OsaurusTool {
    static let nameStatic: String = "echo"
    let name: String = EchoTool.nameStatic
    let description: String = "Echo back the input JSON arguments"
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object(["text": .object(["type": .string("string")])]),
        "required": .array([.string("text")]),
    ])
    func execute(argumentsJSON: String) async throws -> String {
        return argumentsJSON
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
private func startTestServer() async throws -> TestServer {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let bootstrap = ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: 256)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap {
                channel.pipeline.addHandler(
                    HTTPHandler(configuration: .default, eventLoop: channel.eventLoop)
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
