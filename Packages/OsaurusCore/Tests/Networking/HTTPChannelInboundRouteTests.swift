//
//  HTTPChannelInboundRouteTests.swift
//  OsaurusCoreTests
//
//  End-to-end coverage for the Agent Channel webhook routes on the real NIO
//  server: `POST /channels/{kind}/{id}/inbound` and
//  `GET /channels/{kind}/{id}/tasks/{task_id}`. The server is booted with
//  `trustLoopback: false` (what expose-to-network does) so 127.0.0.1 is
//  auth-gated like any remote caller, proving the routes are bearer-exempt
//  while every other protected route still hits the access-key gate — and
//  that the remote-transport policy still recognises physical loopback.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct HTTPChannelInboundRouteTests {
    private static let secret = "route-test-secret-0123456789"
    private static let agentId = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

    private struct FixedSecretResolver: AgentChannelSecretResolving {
        func secret(named name: String, keychainId: String, connection: AgentChannelConnection) -> String? {
            HTTPChannelInboundRouteTests.secret
        }
    }

    private static func connection(id: String, policy: AgentChannelN8nRemoteTransportPolicy) -> AgentChannelConnection {
        AgentChannelConnection(
            id: id,
            name: "n8n \(id)",
            kind: .n8n,
            supportedActions: [.diagnostics],
            spaceAllowlist: [AgentChannelN8nConfiguration.spaceId],
            inboundAuthorization: AgentChannelInboundAuthorizationPolicy(
                senderAllowlist: ["user-1"],
                roomAllowlist: ["conv-1"]
            ),
            n8n: AgentChannelN8nConfiguration(
                inboundVerification: AgentChannelN8nInboundVerification(method: .sharedSecretHeader),
                inboundDispatch: AgentChannelInboundDispatchConfiguration(enabled: true, targetAgentId: agentId),
                remoteTransportPolicy: policy
            )
        )
    }

    private static func envelope(eventId: String) -> Data {
        try! JSONSerialization.data(
            withJSONObject: [
                "v": 1,
                "event_id": eventId,
                "conversation_id": "conv-1",
                "sender": ["id": "user-1", "display": "Ada"],
                "content": "hello from n8n",
            ] as [String: Any]
        )
    }

    private func withRouteFixture(
        rateLimiter: PairingRateLimiter = PairingRateLimiter(window: 60, maxPerWindow: 1_000, denialCooldown: 0),
        _ body: @Sendable (TestServer) async throws -> Void
    ) async throws {
        try await AgentChannelConfigurationTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-n8n-route-\(UUID().uuidString)", isDirectory: true)
            let previousDirectory = AgentChannelConfigurationStore.overrideDirectory
            let previousIngress = AgentChannelWebhookIngress.shared
            AgentChannelConfigurationStore.overrideDirectory = root
            defer {
                AgentChannelConfigurationStore.overrideDirectory = previousDirectory
                AgentChannelWebhookIngress.shared = previousIngress
                try? FileManager.default.removeItem(at: root)
            }
            try AgentChannelConfigurationStore.save(
                AgentChannelConfiguration(connections: [
                    Self.connection(id: "n8n-plain", policy: .plaintextAllowed),
                    Self.connection(id: "n8n-secure", policy: .secureChannelRequired),
                ])
            )
            let store = AgentChannelMessageStore()
            try store.openInMemory()
            AgentChannelWebhookIngress.shared = AgentChannelWebhookIngress(
                secretResolver: FixedSecretResolver(),
                messageStore: store,
                activityCenter: AgentChannelInboundActivityCenter(),
                transportHealth: AgentChannelTransportHealthCenter(),
                relaySubmit: { _ in .dispatched(agentId: Self.agentId, rule: "default") },
                taskLookup: { _ in
                    AgentChannelWebhookTaskSnapshot(
                        status: .running,
                        output: nil,
                        summary: nil,
                        externalSessionKey: nil,
                        isChannelSource: true
                    )
                },
                rateLimiter: rateLimiter
            )
            let server = try await startServer()
            do {
                try await body(server)
            } catch {
                await server.shutdown()
                throw error
            }
            await server.shutdown()
        }
    }

    private func send(
        _ server: TestServer,
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)\(path)")!)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    private static func errorCode(_ json: [String: Any]) -> String? {
        (json["error"] as? [String: Any])?["code"] as? String
    }

    @Test func channelRoutesAreBearerExemptWhileOtherRoutesStayGated() async throws {
        try await withRouteFixture { server in
            // Control: a protected route from a non-loopback-trusted caller is gated.
            let (gatedStatus, _) = try await send(server, method: "GET", path: "/agents")
            #expect(gatedStatus == 401)

            let (status, json) = try await send(
                server,
                method: "POST",
                path: "/channels/n8n/n8n-plain/inbound",
                headers: ["X-Osaurus-Channel-Secret": Self.secret, "Content-Type": "application/json"],
                body: Self.envelope(eventId: "route-1")
            )
            #expect(status == 202)
            #expect(json["status"] as? String == "accepted")
            #expect(json["dispatch"] as? String == "dispatched")
            let taskId = try #require(json["task_id"] as? String)
            #expect(json["poll_url"] as? String == "/channels/n8n/n8n-plain/tasks/\(taskId)")

            let (pollStatus, pollJSON) = try await send(
                server,
                method: "GET",
                path: "/channels/n8n/n8n-plain/tasks/\(taskId)",
                headers: ["X-Osaurus-Channel-Secret": Self.secret]
            )
            #expect(pollStatus == 200)
            #expect(pollJSON["status"] as? String == "running")
            #expect(pollJSON["task_id"] as? String == taskId)

            let (dupStatus, dupJSON) = try await send(
                server,
                method: "POST",
                path: "/channels/n8n/n8n-plain/inbound",
                headers: ["X-Osaurus-Channel-Secret": Self.secret],
                body: Self.envelope(eventId: "route-1")
            )
            #expect(dupStatus == 200)
            #expect(dupJSON["status"] as? String == "duplicate")
        }
    }

    @Test func pingRouteIsBearerExemptSecretVerifiedAndPolicyGated() async throws {
        try await withRouteFixture { server in
            let (ok, okJSON) = try await send(
                server,
                method: "GET",
                path: "/channels/n8n/n8n-plain/ping",
                headers: ["X-Osaurus-Channel-Secret": Self.secret]
            )
            #expect(ok == 200)
            #expect(okJSON["status"] as? String == "ok")
            #expect(okJSON["connection_id"] as? String == "n8n-plain")
            #expect(okJSON["verification"] as? String == "shared_secret_header")
            #expect(okJSON["transport"] as? String == "loopback")

            let (bad, badJSON) = try await send(
                server,
                method: "GET",
                path: "/channels/n8n/n8n-plain/ping",
                headers: ["X-Osaurus-Channel-Secret": "wrong"]
            )
            #expect(bad == 401)
            #expect(Self.errorCode(badJSON) == "unauthorized")

            // Relay-origin plaintext against the default policy: 426, same as inbound.
            let (relayed, relayedJSON) = try await send(
                server,
                method: "GET",
                path: "/channels/n8n/n8n-secure/ping",
                headers: ["X-Osaurus-Channel-Secret": Self.secret, HTTPHandler.relayOriginHeaderName: "1"]
            )
            #expect(relayed == 426)
            #expect(Self.errorCode(relayedJSON) == "secure_channel_required")

            let (wrongMethod, _) = try await send(
                server,
                method: "POST",
                path: "/channels/n8n/n8n-plain/ping",
                headers: ["X-Osaurus-Channel-Secret": Self.secret],
                body: Data()
            )
            #expect(wrongMethod == 405)
        }
    }

    @Test func badSecretUnknownConnectionAndSecurePolicyAreRefusedOnTheWire() async throws {
        try await withRouteFixture { server in
            let (badSecret, badJSON) = try await send(
                server,
                method: "POST",
                path: "/channels/n8n/n8n-plain/inbound",
                headers: ["X-Osaurus-Channel-Secret": "wrong"],
                body: Self.envelope(eventId: "route-2")
            )
            #expect(badSecret == 401)
            #expect(Self.errorCode(badJSON) == "unauthorized")

            let (unknown, unknownJSON) = try await send(
                server,
                method: "POST",
                path: "/channels/n8n/missing/inbound",
                headers: ["X-Osaurus-Channel-Secret": Self.secret],
                body: Self.envelope(eventId: "route-3")
            )
            #expect(unknown == 404)
            #expect(Self.errorCode(unknownJSON) == "connection_not_found")

            // The transport policy keys off the *physical* transport, not the
            // `trustLoopback` auth flag: this server runs with
            // `trustLoopback: false` (what expose-to-network does), yet a real
            // 127.0.0.1 caller is still the same Mac and must not be 426'd.
            let (localPlain, localJSON) = try await send(
                server,
                method: "POST",
                path: "/channels/n8n/n8n-secure/inbound",
                headers: ["X-Osaurus-Channel-Secret": Self.secret],
                body: Self.envelope(eventId: "route-4-local")
            )
            #expect(localPlain == 202)
            #expect(localJSON["status"] as? String == "accepted")

            // Relay-tunnelled traffic arrives over loopback but is remote in
            // origin; plaintext against the default policy: 426.
            let (secure, secureJSON) = try await send(
                server,
                method: "POST",
                path: "/channels/n8n/n8n-secure/inbound",
                headers: [
                    "X-Osaurus-Channel-Secret": Self.secret,
                    HTTPHandler.relayOriginHeaderName: "1",
                ],
                body: Self.envelope(eventId: "route-4")
            )
            #expect(secure == 426)
            #expect(Self.errorCode(secureJSON) == "secure_channel_required")

            let (wrongMethod, wrongJSON) = try await send(
                server,
                method: "GET",
                path: "/channels/n8n/n8n-plain/inbound",
                headers: ["X-Osaurus-Channel-Secret": Self.secret]
            )
            #expect(wrongMethod == 405)
            #expect(Self.errorCode(wrongJSON) == "method_not_allowed")

            let (foreignPoll, _) = try await send(
                server,
                method: "GET",
                path: "/channels/n8n/n8n-plain/tasks/\(UUID().uuidString)",
                headers: ["X-Osaurus-Channel-Secret": Self.secret]
            )
            #expect(foreignPoll == 404)
        }
    }

    @Test func dedicatedRateLimiterReturns429OnTheWire() async throws {
        try await withRouteFixture(
            rateLimiter: PairingRateLimiter(window: 60, maxPerWindow: 2, denialCooldown: 60)
        ) { server in
            var statuses: [Int] = []
            for index in 0 ..< 3 {
                let (status, _) = try await send(
                    server,
                    method: "POST",
                    path: "/channels/n8n/n8n-plain/inbound",
                    headers: ["X-Osaurus-Channel-Secret": Self.secret],
                    body: Self.envelope(eventId: "rate-\(index)")
                )
                statuses.append(status)
            }
            #expect(statuses == [202, 202, 429])
        }
    }

    // MARK: - Server bootstrap

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

    private func startServer() async throws -> TestServer {
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
                                trustLoopback: false
                            )
                        )
                    }
                }
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)

            let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            let port = ch.localAddress?.port ?? 0
            return TestServer(group: group, channel: ch, lease: lease, host: "127.0.0.1", port: port)
        } catch {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                group.shutdownGracefully { _ in cont.resume() }
            }
            await lease.release()
            throw error
        }
    }
}
