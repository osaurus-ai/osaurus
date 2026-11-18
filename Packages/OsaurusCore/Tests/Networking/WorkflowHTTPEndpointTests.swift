//
//  WorkflowHTTPEndpointTests.swift
//  OsaurusCoreTests
//
//  The workflow routes on the HTTP port: pending dialogs and run status
//  are owner-only and need the Secure Channel off loopback; the MCP
//  bridge hides tools that need a chat agent from callers without one.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct WorkflowHTTPEndpointTests {
    // MARK: Secure channel (review #9)

    @Test func pendingDialogsAndRunStatusRequireTheSecureChannelOffLoopback() async throws {
        // `trustLoopback: false` is what expose-to-network does: the
        // connection no longer counts as the Mac's owner by virtue of
        // being local, so a master-scoped key is the owner proof and the
        // plaintext transport must be refused.
        let server = try await startWorkflowTestServer(trustLoopback: false)
        defer { Task { await server.shutdown() } }

        for path in ["/workflows/pending-dialogs", "/workflows/runs/\(UUID().uuidString)"] {
            var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)\(path)")!)
            request.authenticate()
            let (data, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 426, Comment(rawValue: path))
            #expect(String(decoding: data, as: UTF8.self).contains("secure_channel_required"), Comment(rawValue: path))
        }
    }

    // MARK: GET /workflows/runs/{id} (review #16)

    @Test func runStatusRouteReturnsTheRunOrNotFound() async throws {
        let server = try await startWorkflowTestServer(trustLoopback: true)
        defer { Task { await server.shutdown() } }

        var run = WorkflowRun(
            workflowID: UUID(), workflowName: "Status Probe", templateID: UUID(), templateVersion: 1,
            caller: WorkflowCaller(kind: .user), input: .object([:]), nodeIDs: ["a"])
        WorkflowRunStore.shared.record(run)

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/workflows/runs/\(run.id.uuidString)")!)
        request.authenticate()
        var (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["status"] as? String == "running", "a live run must not read as failed")
        #expect(json["run_status"] as? String == "running")
        #expect(json["workflow_name"] as? String == "Status Probe")
        #expect(json["run_id"] as? String == run.id.uuidString)

        run.status = .completed
        run.output = .object(["answer": .string("42")])
        run.finishedAt = Date()
        WorkflowRunStore.shared.record(run)
        (data, response) = try await URLSession.shared.data(for: request)
        json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["status"] as? String == "completed")
        #expect((json["output"] as? [String: Any])?["answer"] as? String == "42")
        #expect(json["pending_dialog"] == nil)

        var missing = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/workflows/runs/\(UUID().uuidString)")!)
        missing.authenticate()
        let (missingData, missingResponse) = try await URLSession.shared.data(for: missing)
        #expect((missingResponse as? HTTPURLResponse)?.statusCode == 404)
        #expect(String(decoding: missingData, as: UTF8.self).contains("run_not_found"))

        var malformed = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/workflows/runs/nope")!)
        malformed.authenticate()
        let (_, malformedResponse) = try await URLSession.shared.data(for: malformed)
        #expect((malformedResponse as? HTTPURLResponse)?.statusCode == 400)
    }

    // MARK: /mcp hides agent-bound tools (review #22)

    @Test func mcpHidesWorkflowToolsFromCallersWithoutAnAgent() async throws {
        try await DynamicCatalogTestLock.shared.run {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-tests-\(UUID().uuidString)", isDirectory: true)
            ToolConfigurationStore.overrideDirectory = tempDir
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let registry = ToolRegistry.shared
            let wasEnabled = registry.isGlobalEnabled(RunWorkflowTool.toolName)
            registry.setEnabled(true, for: RunWorkflowTool.toolName)
            defer { registry.setEnabled(wasEnabled, for: RunWorkflowTool.toolName) }
            #expect(registry.requiresAgentContext(RunWorkflowTool.toolName))
            for name in ToolRegistry.architectToolNames { #expect(registry.requiresAgentContext(name)) }
            #expect(!registry.requiresAgentContext("echo"))

            let server = try await startWorkflowTestServer(trustLoopback: false)
            defer { Task { await server.shutdown() } }

            // No agent bound: hidden from the listing, refused on call.
            var list = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/mcp/tools")!)
            list.authenticate()
            var (data, _) = try await URLSession.shared.data(for: list)
            var names = Set(
                ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["tools"] as? [[String: Any]] ?? [])
                    .compactMap { $0["name"] as? String })
            #expect(!names.contains(RunWorkflowTool.toolName))
            #expect(names.isDisjoint(with: ToolRegistry.architectToolNames))

            var call = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/mcp/call")!)
            call.httpMethod = "POST"
            call.setValue("application/json", forHTTPHeaderField: "Content-Type")
            call.authenticate()
            call.httpBody = try JSONSerialization.data(withJSONObject: [
                "name": RunWorkflowTool.toolName, "arguments": ["workflow": "x"],
            ])
            let (callData, callResponse) = try await URLSession.shared.data(for: call)
            #expect((callResponse as? HTTPURLResponse)?.statusCode == 200)
            let callJSON = try #require(JSONSerialization.jsonObject(with: callData) as? [String: Any])
            #expect(callJSON["isError"] as? Bool == true)
            let text = (callJSON["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
            #expect(text.contains("needs a chat agent"))

            // A live bridge grant binds an agent, so the listing shows them.
            let grant = HarnessGrantStore.shared.mint(agentId: UUID(), allowsConfigWrites: false)
            defer { HarnessGrantStore.shared.revoke(grant) }
            list.setValue(grant, forHTTPHeaderField: HarnessGrantStore.headerName)
            (data, _) = try await URLSession.shared.data(for: list)
            names = Set(
                ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["tools"] as? [[String: Any]] ?? [])
                    .compactMap { $0["name"] as? String })
            #expect(names.contains(RunWorkflowTool.toolName))
        }
    }

    // MARK: Tool-name collisions (review #10)

    @Test func syncSkipsWorkflowsWhoseToolNameIsHeldByAnotherTool() async {
        await DynamicCatalogTestLock.shared.run {
            let registry = ToolRegistry.shared
            let base = "Collide \(UUID().uuidString.prefix(8).lowercased())"
            let colliding = InstalledWorkflow(template: WF.template(WF.intake(), name: base), bindings: InstallBindings())
            let free = InstalledWorkflow(
                template: WF.template(WF.intake(), name: base + " free"), bindings: InstallBindings())
            registry.register(ProbeTool(name: colliding.toolName))
            defer { registry.unregister(names: [colliding.toolName]) }

            registry.syncWorkflowTools([colliding, free])
            defer { registry.syncWorkflowTools(InstalledWorkflowStore.shared.workflows) }

            #expect(!registry.workflowToolNames.contains(colliding.toolName))
            #expect(registry.workflowToolNames.contains(free.toolName))
            #expect(!registry.isWorkflowToolNameAvailable(colliding.toolName))
            #expect(registry.isWorkflowToolNameAvailable(free.toolName), "a workflow tool is replaceable")
            #expect(registry.isWorkflowToolNameAvailable("workflow_nobody_" + UUID().uuidString.lowercased()))
            // The foreign tool kept its registration and is not treated as
            // a workflow tool.
            #expect(registry.isRegistered(colliding.toolName))
            #expect(!registry.requiresAgentContext(colliding.toolName))
        }
    }

    @Test func installPicksANameWhoseToolIsFree() async throws {
        try await DynamicCatalogTestLock.shared.run {
            let registry = ToolRegistry.shared
            let base = "Shadow \(UUID().uuidString.prefix(8).lowercased())"
            let probe = InstalledWorkflow(template: WF.template(WF.intake(), name: base), bindings: InstallBindings())
            registry.register(ProbeTool(name: probe.toolName))
            defer { registry.unregister(names: [probe.toolName]) }

            let store = InstalledWorkflowStore.shared
            store.reload()
            let installed = try store.install(WF.template(WF.intake(), name: base), bindings: InstallBindings())
            defer { store.delete(id: installed.id) }

            #expect(installed.name == base + " 2")
            #expect(installed.toolName != probe.toolName)
            #expect(registry.workflowToolNames.contains(installed.toolName))
            #expect(!registry.workflowToolNames.contains(probe.toolName))
        }
    }
}

private struct ProbeTool: OsaurusTool {
    let name: String
    let description: String = "Occupies a tool name"
    let parameters: JSONValue? = nil
    func execute(argumentsJSON: String) async throws -> String { argumentsJSON }
}

// MARK: - Test server bootstrap

private struct WorkflowTestServer {
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

private func startWorkflowTestServer(trustLoopback: Bool) async throws -> WorkflowTestServer {
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
                            trustLoopback: trustLoopback
                        )
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)

        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        let port = ch.localAddress?.port ?? 0
        return WorkflowTestServer(group: group, channel: ch, lease: lease, host: "127.0.0.1", port: port)
    } catch {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
        throw error
    }
}
