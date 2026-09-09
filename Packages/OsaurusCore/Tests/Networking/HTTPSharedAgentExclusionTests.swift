//
//  HTTPSharedAgentExclusionTests.swift
//  OsaurusCoreTests
//
//  The local HTTP API exposes only agents THIS instance hosts. A teammate's
//  shared workspace agent — reachable in-app via spawn tools, schedules,
//  watchers and channels — must be absent from `GET /agents` and refused by
//  `POST /agents/{address}/dispatch` and `/run` exactly like an unknown id:
//  a proxied run would be wallet-signed and pool-billed as this user while
//  the real caller is whoever holds a local API key.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct HTTPSharedAgentExclusionTests {

    private static let sharedAddress = "0xaaaa000000000000000000000000000000000077"

    private static func rosterAgent(address: String, name: String) throws -> OsaurusRouterWorkspaceAgent {
        let body = """
            {"agent_address": "\(address)", "display_name": "\(name)",
             "owner": {"account_id": "acct-1", "wallet_address": "0xowner", "display_name": "Alice"},
             "relay_url": "wss://relay.example", "online": true, "last_seen": null,
             "shared_at": "2026-01-01T00:00:00Z"}
            """
        return try JSONDecoder().decode(OsaurusRouterWorkspaceAgent.self, from: Data(body.utf8))
    }

    private static func workspace(id: String, name: String) throws -> OsaurusRouterWorkspaceSummary {
        let body = """
            {"id": "\(id)", "name": "\(name)", "role": "member", "source": "subscription", "active": true,
             "members_active": 2, "agents_shared": 1, "created_at": "2026-01-01T00:00:00Z"}
            """
        return try JSONDecoder().decode(OsaurusRouterWorkspaceSummary.self, from: Data(body.utf8))
    }

    @MainActor
    private static func seedRoster() throws {
        let roster = WorkspaceRosterStore.WorkspaceRoster(
            workspace: try workspace(id: "ws-http", name: "Acme"),
            agents: [try rosterAgent(address: sharedAddress, name: "Research Agent")]
        )
        WorkspaceRosterStore.shared.apply(rosters: [roster])
    }

    private static func send(
        _ method: String, _ path: String, server: ExclusionTestServer, body: Data? = nil
    ) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)\(path)")!)
        request.httpMethod = method
        if let body, method != "GET" {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: request)
        return ((resp as? HTTPURLResponse)?.statusCode ?? -1, String(decoding: data, as: UTF8.self))
    }

    @Test func sharedWorkspaceAgent_isAbsentFromAgentsListAndRefusedByDispatchAndRun() async throws {
        try await WorkspaceRosterTestLock.shared.run {
            try Self.seedRoster()

            // Precondition: the in-app resolver DOES know the shared agent, so
            // an absence below is the API's exclusion, not a missing fixture.
            let resolvable = AgentTargetResolver.resolve(Self.sharedAddress, scope: .localAndWorkspace)
            #expect(
                resolvable == .success(.workspace(.init(workspaceId: "ws-http", agentAddress: Self.sharedAddress)))
            )
            #expect(AgentTargetResolver.resolve(Self.sharedAddress, scope: .localOnly) == .failure(.notFound))
            #expect(AgentManager.shared.resolveAgentId(Self.sharedAddress) == nil)

            // Loopback with no keys configured: the auth gate lets same-machine
            // callers through, so the handlers themselves decide.
            let server = try await startExclusionTestServer()
            defer { Task { await server.shutdown() } }

            let list = try await Self.send("GET", "/agents", server: server)
            #expect(list.status == 200, "\(list.body)")
            #expect(!list.body.lowercased().contains(Self.sharedAddress), "GET /agents advertised a shared agent")
            #expect(!list.body.contains("Research Agent"), "GET /agents advertised a shared agent by name")

            let detail = try await Self.send("GET", "/agents/\(Self.sharedAddress)", server: server)
            #expect(detail.status != 200, "GET /agents/{address} resolved a shared agent: \(detail.body)")

            let dispatch = try await Self.send(
                "POST", "/agents/\(Self.sharedAddress)/dispatch", server: server,
                body: Data(#"{"prompt":"hi"}"#.utf8)
            )
            #expect(dispatch.status == 404, "dispatch returned \(dispatch.status): \(dispatch.body)")
            #expect(dispatch.body.contains("agent_not_found"), "\(dispatch.body)")

            // Same body shape as an unknown identifier: `/run` looks the
            // address up in the local identity registry and rejects the rest.
            let run = try await Self.send(
                "POST", "/agents/\(Self.sharedAddress)/run", server: server,
                body: Data(#"{"messages":[{"role":"user","content":"hi"}]}"#.utf8)
            )
            #expect(run.status == 400 || run.status == 404, "run returned \(run.status): \(run.body)")
            #expect(run.body.contains("invalid_agent_id") || run.body.contains("agent_not_found"), "\(run.body)")
        }
    }
}

// MARK: - Server harness (loopback, no access keys)

private struct ExclusionTestServer {
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

private func startExclusionTestServer() async throws -> ExclusionTestServer {
    let config = ServerConfiguration.default
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
                            configuration: config,
                            apiKeyValidator: .empty,
                            eventLoop: channel.eventLoop,
                            trustLoopback: true
                        )
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)

        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        let port = ch.localAddress?.port ?? 0
        return ExclusionTestServer(group: group, channel: ch, lease: lease, host: "127.0.0.1", port: port)
    } catch {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
        throw error
    }
}
