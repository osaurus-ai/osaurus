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

@Suite(.serialized)
@MainActor
struct MCPHTTPHandlerTests {
    private static let agentChannelToolNames = [
        "agent_channel_list_connections",
        "agent_channel_diagnostics",
        "agent_channel_list_spaces",
        "agent_channel_list_rooms",
        "agent_channel_read_messages",
        "agent_channel_read_thread",
        "agent_channel_search_messages",
        "agent_channel_draft_message",
        "agent_channel_send_message",
        "agent_channel_reply_thread",
    ]

    @Test func mcp_health_returns_ok() async throws {
        let server = try await startTestServer()
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/mcp/health")!)
        request.authenticate()
        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 200)
        #expect(body.contains(#""status":"ok"#))
    }

    @Test func admin_cache_stats_returns_empty_snapshot_without_loading_model() async throws {
        let server = try await startTestServer()
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/admin/cache-stats")!)
        request.authenticate()
        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        #expect(status == 200)

        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["status"] as? String == "ok")
        let models = try #require(json["models"] as? [[String: Any]])
        #expect(models.isEmpty)
        let aggregate = try #require(json["aggregate"] as? [String: Any])
        #expect(aggregate["prefix_hits"] as? Int == 0)
        #expect(aggregate["paged_hits"] as? Int == 0)
        #expect(aggregate["disk_l2_hits"] as? Int == 0)
        #expect(aggregate["ssm_companion_hits"] as? Int == 0)
        #expect(json.keys.contains("batch_diagnostics"))
    }

    @Test func mcp_tools_lists_only_enabled_tools() async throws {
        // `EchoTool` is a dynamic tool registered into the process-wide
        // `ToolRegistry.shared`. Other suites that assert on the dynamic
        // catalog contents (e.g. `ToolSearchServiceTests`) would flake if
        // `EchoTool` were registered concurrently. Hold the cross-suite lock
        // across the whole register / assert / unregister window.
        try await DynamicCatalogTestLock.shared.run {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-tests-\(UUID().uuidString)",
                isDirectory: true
            )
            ToolConfigurationStore.overrideDirectory = tempDir
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            ToolRegistry.shared.register(EchoTool())
            ToolRegistry.shared.setEnabled(true, for: EchoTool.nameStatic)
            defer { ToolRegistry.shared.unregister(names: [EchoTool.nameStatic]) }

            let server = try await startTestServer()
            defer { Task { await server.shutdown() } }

            var toolsRequest = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/mcp/tools")!)
            toolsRequest.authenticate()
            let (data, resp) = try await URLSession.shared.data(for: toolsRequest)
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
    }

    @Test func mcp_call_executes_enabled_tool_and_returns_text_content() async throws {
        try await DynamicCatalogTestLock.shared.run {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-tests-\(UUID().uuidString)",
                isDirectory: true
            )
            ToolConfigurationStore.overrideDirectory = tempDir
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            ToolRegistry.shared.register(EchoTool())
            ToolRegistry.shared.setEnabled(true, for: EchoTool.nameStatic)
            defer { ToolRegistry.shared.unregister(names: [EchoTool.nameStatic]) }

            let server = try await startTestServer()
            defer { Task { await server.shutdown() } }

            var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/mcp/call")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.authenticate()
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
            // The registry boundary normalizes every tool result into a
            // ToolEnvelope; the raw echo payload rides inside `result.text`.
            let envelope =
                try JSONSerialization.jsonObject(
                    with: Data((text ?? "").utf8)
                ) as? [String: Any]
            #expect(envelope?["ok"] as? Bool == true)
            #expect(envelope?["tool"] as? String == EchoTool.nameStatic)
            let result = envelope?["result"] as? [String: Any]
            #expect(result?["text"] as? String == #"{"text":"hello"}"#)
        }
    }

    @Test func mcp_call_refuses_externally_denied_tools() async throws {
        let server = try await startTestServer()
        defer { Task { await server.shutdown() } }

        let externallyDeniedTools = ["file_write", "file_edit", "shell_run", "git_commit"]
            + Self.agentChannelToolNames
        for tool in externallyDeniedTools {
            var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/mcp/call")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.authenticate()
            let bodyObj: [String: Any] = ["name": tool, "arguments": [:]]
            request.httpBody = try JSONSerialization.data(withJSONObject: bodyObj)

            let (data, resp) = try await URLSession.shared.data(for: request)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(decoding: data, as: UTF8.self)
            #expect(status == 403, "expected 403 for \(tool), got \(status)")
            #expect(body.contains("tool_not_exposable"))
        }
    }

    @Test func externally_denied_tool_names_derive_from_agent_channel_family() {
        // Independent literal copy: if a new agent_channel_* tool ships
        // without updating `ToolRegistry.agentChannelToolNames`, this fails.
        #expect(ToolRegistry.agentChannelToolNames == Set(Self.agentChannelToolNames))
        // The external deny list is derived, so the channel family can never
        // drift out of it.
        #expect(ToolRegistry.agentChannelToolNames.isSubset(of: ToolRegistry.externallyDeniedToolNames))
        #expect(
            ToolRegistry.externallyDeniedToolNames
                == ToolRegistry.externallyDeniedHostToolNames.union(ToolRegistry.agentChannelToolNames)
        )
        // Every REGISTERED agent_channel_* tool must be in the deny family.
        let registeredChannelNames = Set(
            ToolRegistry.shared.listTools().map(\.name).filter { $0.hasPrefix("agent_channel_") }
        )
        #expect(registeredChannelNames.isSubset(of: ToolRegistry.externallyDeniedToolNames))
    }

    @Test func dispatcher_layer_rebinds_external_surface_from_request_metadata() async {
        // Non-loopback HTTP dispatch marks the request external; the
        // dispatcher-layer binding must deny agent-channel tools even
        // without the HTTP handler's own task-local wrapper.
        let external = DispatchRequest(prompt: "p", source: .http, externalSurface: true)
        let internalRequest = DispatchRequest(prompt: "p", source: .http, externalSurface: false)

        #expect(BackgroundTaskManager.resolvedExternalSurface(for: external))
        #expect(!BackgroundTaskManager.resolvedExternalSurface(for: internalRequest))

        let deniedViaDispatcher = ChatExecutionContext.$isExternalSurface.withValue(
            BackgroundTaskManager.resolvedExternalSurface(for: external)
        ) {
            ToolRegistry.isDeniedForCurrentSurface("agent_channel_send_message")
        }
        #expect(deniedViaDispatcher)

        // Widen-only: a trusted-looking request cannot clear an inherited
        // external execution context.
        let widened = ChatExecutionContext.$isExternalSurface.withValue(true) {
            BackgroundTaskManager.resolvedExternalSurface(for: internalRequest)
        }
        #expect(widened)

        // Propagates into the unstructured task the dispatched run starts.
        let inherited = await ChatExecutionContext.$isExternalSurface.withValue(
            BackgroundTaskManager.resolvedExternalSurface(for: external)
        ) {
            await Task {
                ToolRegistry.isDeniedForCurrentSurface("agent_channel_send_message")
            }.value
        }
        #expect(inherited)
    }

    @Test func remote_dispatch_surface_binding_denies_agent_channel_tools() {
        #expect(!HTTPHandler.shouldBindExternalSurfaceForDispatch(isLoopback: true))
        #expect(HTTPHandler.shouldBindExternalSurfaceForDispatch(isLoopback: false))

        for toolName in Self.agentChannelToolNames {
            let local = ChatExecutionContext.$isExternalSurface.withValue(
                HTTPHandler.shouldBindExternalSurfaceForDispatch(isLoopback: true)
            ) {
                ToolRegistry.isDeniedForCurrentSurface(toolName)
            }
            #expect(!local, "\(toolName) should remain app-usable on loopback dispatch")

            let remote = ChatExecutionContext.$isExternalSurface.withValue(
                HTTPHandler.shouldBindExternalSurfaceForDispatch(isLoopback: false)
            ) {
                ToolRegistry.isDeniedForCurrentSurface(toolName)
            }
            #expect(remote, "\(toolName) should be denied on non-loopback dispatch")
        }

        let remoteHostWrite = ChatExecutionContext.$isExternalSurface.withValue(
            HTTPHandler.shouldBindExternalSurfaceForDispatch(isLoopback: false)
        ) {
            ToolRegistry.isDeniedForCurrentSurface("file_write")
        }
        #expect(remoteHostWrite)
    }

    @Test func remote_dispatch_surface_binding_propagates_to_unstructured_tasks() async {
        for toolName in Self.agentChannelToolNames {
            let inherited = await ChatExecutionContext.$isExternalSurface.withValue(
                HTTPHandler.shouldBindExternalSurfaceForDispatch(isLoopback: false)
            ) {
                await Task {
                    ToolRegistry.isDeniedForCurrentSurface(toolName)
                }.value
            }
            #expect(inherited, "\(toolName) should keep external-surface denial across unstructured tasks")
        }
    }

    @Test func mcp_call_rejects_malformed_agent_header() async throws {
        let server = try await startTestServer()
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/mcp/call")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("not-a-uuid", forHTTPHeaderField: "X-Osaurus-Agent-Id")
        request.authenticate()
        let bodyObj: [String: Any] = ["name": "echo", "arguments": ["text": "hi"]]
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyObj)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 403)
        #expect(body.contains("invalid_agent"))
    }

    @Test func mcp_tools_hides_externally_denied_tools() async throws {
        try await DynamicCatalogTestLock.shared.run {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-tests-\(UUID().uuidString)",
                isDirectory: true
            )
            ToolConfigurationStore.overrideDirectory = tempDir
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            // Register a tool whose name is on the external deny list; it
            // must be filtered from the /mcp/tools listing.
            ToolRegistry.shared.register(NamedEchoTool(name: "shell_run"))
            ToolRegistry.shared.setEnabled(true, for: "shell_run")
            defer { ToolRegistry.shared.unregister(names: ["shell_run"]) }

            let server = try await startTestServer()
            defer { Task { await server.shutdown() } }

            var toolsRequest = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/mcp/tools")!)
            toolsRequest.authenticate()
            let (data, resp) = try await URLSession.shared.data(for: toolsRequest)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            #expect(status == 200)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let tools = (json?["tools"] as? [[String: Any]]) ?? []
            let names = Set(tools.compactMap { $0["name"] as? String })
            #expect(!names.contains("shell_run"))
        }
    }

    @Test func stdio_mcp_policy_hides_externally_denied_tools() {
        #expect(MCPServerManager.isToolVisibleToExternalMCP(name: EchoTool.nameStatic, enabled: true))
        #expect(!MCPServerManager.isToolVisibleToExternalMCP(name: EchoTool.nameStatic, enabled: false))

        for name in ["file_write", "shell_run"] + Self.agentChannelToolNames {
            #expect(!MCPServerManager.isToolVisibleToExternalMCP(name: name, enabled: true))
            let denial = MCPServerManager.externalMCPDenialMessage(for: name)
            #expect(denial?.contains("App-only tools") == true)
        }
    }

    @Test func stdio_mcp_execution_binds_external_surface() async throws {
        try await DynamicCatalogTestLock.shared.run {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-tests-\(UUID().uuidString)",
                isDirectory: true
            )
            ToolConfigurationStore.overrideDirectory = tempDir
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            ToolRegistry.shared.register(ExternalSurfaceProbeTool())
            ToolRegistry.shared.setEnabled(true, for: ExternalSurfaceProbeTool.nameStatic)
            defer { ToolRegistry.shared.unregister(names: [ExternalSurfaceProbeTool.nameStatic]) }

            let text = try await MCPServerManager.executeToolAsExternalMCP(
                name: ExternalSurfaceProbeTool.nameStatic,
                argumentsJSON: "{}"
            )
            let envelope =
                try JSONSerialization.jsonObject(
                    with: Data(text.utf8)
                ) as? [String: Any]
            #expect(envelope?["ok"] as? Bool == true)
            let result = envelope?["result"] as? [String: Any]
            #expect(result?["text"] as? String == "external")
        }
    }

    @Test func mcp_call_with_missing_required_arg_returns_error() async throws {
        try await DynamicCatalogTestLock.shared.run {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-tests-\(UUID().uuidString)",
                isDirectory: true
            )
            ToolConfigurationStore.overrideDirectory = tempDir
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            ToolRegistry.shared.register(EchoTool())
            ToolRegistry.shared.setEnabled(true, for: EchoTool.nameStatic)
            defer { ToolRegistry.shared.unregister(names: [EchoTool.nameStatic]) }

            let server = try await startTestServer()
            defer { Task { await server.shutdown() } }

            var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/mcp/call")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.authenticate()
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

/// Echo tool with an arbitrary registered name, for deny-list tests.
private struct NamedEchoTool: OsaurusTool {
    let name: String
    let description: String = "Echo back the input JSON arguments"
    let parameters: JSONValue? = nil
    func execute(argumentsJSON: String) async throws -> String {
        return argumentsJSON
    }
}

private struct ExternalSurfaceProbeTool: OsaurusTool {
    static let nameStatic: String = "external_surface_probe"
    let name: String = ExternalSurfaceProbeTool.nameStatic
    let description: String = "Reports whether the current execution surface is external"
    let parameters: JSONValue? = nil

    func execute(argumentsJSON: String) async throws -> String {
        ChatExecutionContext.isExternalSurface ? "external" : "internal"
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
private func startTestServer() async throws -> TestServer {
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
