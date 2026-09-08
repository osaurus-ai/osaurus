//
//  HTTPAuthGateTests.swift
//  OsaurusCoreTests
//
//  HTTP-level tests for the access key authentication gate.
//  Each test boots a real NIO server and makes URLSession requests
//  to verify the auth behavior end-to-end.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

struct HTTPAuthGateTests {

    // MARK: - Public Paths Bypass Auth

    @Test func publicPath_root_returns200_withoutToken() async throws {
        let server = try await startAuthTestServer(validator: .empty)
        defer { Task { await server.shutdown() } }

        let (_, resp) = try await URLSession.shared.data(
            from: URL(string: "http://\(server.host):\(server.port)/")!
        )
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test func publicPath_health_returns200_withoutToken() async throws {
        let server = try await startAuthTestServer(validator: .empty)
        defer { Task { await server.shutdown() } }

        let (data, resp) = try await URLSession.shared.data(
            from: URL(string: "http://\(server.host):\(server.port)/health")!
        )
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
        let body = String(decoding: data, as: UTF8.self)
        #expect(body.contains("healthy"))
    }

    // MARK: - No Token → 401

    @Test func protectedPath_noToken_noKeys_returns401() async throws {
        let server = try await startAuthTestServer(validator: .empty)
        defer { Task { await server.shutdown() } }

        let (data, resp) = try await URLSession.shared.data(
            from: URL(string: "http://\(server.host):\(server.port)/v1/models")!
        )
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 401)
        #expect(body.contains("No access keys configured"))
    }

    @Test func protectedPath_noToken_hasKeys_returns401() async throws {
        let validator = APIKeyValidator.forAlice(hasKeys: true)
        let server = try await startAuthTestServer(validator: validator)
        defer { Task { await server.shutdown() } }

        let (data, resp) = try await URLSession.shared.data(
            from: URL(string: "http://\(server.host):\(server.port)/v1/models")!
        )
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 401)
        #expect(body.contains("Invalid access key"))
    }

    // MARK: - Valid Token → Passthrough

    @Test func protectedPath_validBearerToken_returns200() async throws {
        let validator = APIKeyValidator.forAlice()
        let server = try await startAuthTestServer(validator: validator)
        defer { Task { await server.shutdown() } }

        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress
        )

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/v1/models")!
        )
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, resp) = try await URLSession.shared.data(for: request)
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
    }

    // MARK: - Inbound Attribution (host-side Remote Connections)

    /// A valid inbound request must stamp the matched access key's nonce +
    /// audience + transport onto its `RequestLog`, so the host's Remote
    /// Connections view can attribute `.httpAPI` traffic to a specific paired
    /// peer. Drives a real authed `GET /v1/models` and asserts the resulting
    /// Insights log carries the attribution. The token nonce is unique per run
    /// so we can find our own row in the shared ring buffer.
    @Test func validInboundRequest_stampsAccessKeyAndAudienceOntoLog() async throws {
        let validator = APIKeyValidator.forAlice()
        let server = try await startAuthTestServer(validator: validator)
        defer { Task { await server.shutdown() } }

        let nonce = "inbound-attribution-\(UUID().uuidString)"
        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress,
            nonce: nonce
        )

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/v1/models")!
        )
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, resp) = try await URLSession.shared.data(for: request)
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)

        // The request log is appended via an async main-actor hop, so poll the
        // shared buffer briefly for our uniquely-nonced row.
        let log = await Self.findInboundLog(accessKeyId: nonce)
        let found = try #require(
            log,
            "inbound request did not stamp accessKeyId=\(nonce) onto a RequestLog"
        )
        #expect(found.source == .httpAPI)
        #expect(found.connection?.accessKeyId == nonce)
        #expect(found.connection?.audience == TestKeys.aliceAddress.lowercased())
        // Plain HTTP (no Secure Channel handshake) is attributed as direct.
        #expect(found.connection?.transport == .direct)
    }

    /// Polls `InsightsService` (main-actor) for an inbound log stamped with the
    /// given access-key nonce. Returns nil if it never appears within ~1s.
    private static func findInboundLog(accessKeyId: String) async -> RequestLog? {
        for _ in 0 ..< 40 {
            let match = await MainActor.run {
                InsightsService.shared.logs.first {
                    $0.connection?.accessKeyId == accessKeyId
                }
            }
            if let match { return match }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return nil
    }

    // MARK: - Expired Token → 401

    @Test func protectedPath_expiredToken_returns401() async throws {
        let validator = APIKeyValidator.forAlice()
        let server = try await startAuthTestServer(validator: validator)
        defer { Task { await server.shutdown() } }

        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress,
            exp: Int(Date().timeIntervalSince1970) - 3600
        )

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/v1/models")!
        )
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 401)
        #expect(body.contains("expired"))
    }

    // MARK: - Revoked Token → 401

    @Test func protectedPath_revokedToken_returns401() async throws {
        let nonce = "http_revoked_nonce"
        let revokedKey = RevocationSnapshot.revocationKey(address: TestKeys.aliceAddress, nonce: nonce)
        let snapshot = RevocationSnapshot(revokedKeys: [revokedKey], counterThresholds: [:])
        let validator = APIKeyValidator.forAlice(revocations: snapshot)
        let server = try await startAuthTestServer(validator: validator)
        defer { Task { await server.shutdown() } }

        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress,
            nonce: nonce
        )

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/v1/models")!
        )
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 401)
        #expect(body.contains("revoked"))
    }

    // MARK: - Tampered Token → 401

    @Test func protectedPath_tamperedToken_returns401() async throws {
        let validator = APIKeyValidator.forAlice()
        let server = try await startAuthTestServer(validator: validator)
        defer { Task { await server.shutdown() } }

        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey,
            iss: TestKeys.aliceAddress,
            aud: TestKeys.aliceAddress
        )
        let parts = token.split(separator: ".", maxSplits: 2)
        var sigChars = Array(String(parts[2]))
        sigChars[10] = sigChars[10] == "a" ? "b" : "a"
        let tampered = "osk-v1.\(parts[1]).\(String(sigChars))"

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/v1/models")!
        )
        request.setValue("Bearer \(tampered)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 401)
        #expect(body.contains("Invalid access key"))
    }

    // MARK: - Relay Loopback Bypass Regression

    /// Baseline: with loopback trust enabled, a plain local request needs no token.
    @Test func loopbackTrusted_noToken_returns200() async throws {
        let server = try await startAuthTestServer(validator: .empty, trustLoopback: true)
        defer { Task { await server.shutdown() } }

        let (_, resp) = try await URLSession.shared.data(
            from: URL(string: "http://\(server.host):\(server.port)/v1/models")!
        )
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
    }

    /// Regression for the relay loopback auth bypass: traffic proxied by
    /// `RelayTunnelManager` arrives over 127.0.0.1 but carries the relay-origin
    /// marker, so it must NOT inherit loopback trust — a request without a
    /// Bearer token has to 401 even when `trustLoopback` is on.
    @Test func relayOriginHeader_disablesLoopbackTrust_returns401() async throws {
        let server = try await startAuthTestServer(validator: .empty, trustLoopback: true)
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/v1/models")!
        )
        request.setValue("1", forHTTPHeaderField: HTTPHandler.relayOriginHeaderName)

        let (_, resp) = try await URLSession.shared.data(for: request)
        #expect((resp as? HTTPURLResponse)?.statusCode == 401)
    }

    /// Relayed traffic with a valid Bearer token still passes the gate.
    @Test func relayOriginHeader_withValidToken_returns200() async throws {
        let server = try await startAuthTestServer(validator: .forAlice(), trustLoopback: true)
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/v1/models")!
        )
        request.setValue("1", forHTTPHeaderField: HTTPHandler.relayOriginHeaderName)
        request.authenticate()

        let (_, resp) = try await URLSession.shared.data(for: request)
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
    }

    // MARK: - Agent-Scoped Key Confinement (by key origin)

    /// Builds a validator that knows Alice's master + one derived agent, and an
    /// agent-scoped token for that agent. With `workspaceMinted`, the token's
    /// nonce is registered in the host's workspace-key index (what the
    /// Workspaces redeem does) so the gate applies the strict allowlist;
    /// otherwise it is classified as a legacy `/pair` / invite key.
    private static func agentScopedFixture(
        workspaceMinted: Bool = false
    ) throws -> (validator: APIKeyValidator, token: String, agent: String, nonce: String) {
        let agent = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 3)
        let agentKey = AgentKey.derive(masterKey: TestKeys.alicePrivateKey, index: 3)
        let validator = APIKeyValidator(
            agentAddresses: [agent],
            masterAddress: TestKeys.aliceAddress,
            effectiveWhitelist: [TestKeys.aliceAddress.lowercased(), agent.lowercased()],
            revocationSnapshot: RevocationSnapshot(revokedKeys: [], counterThresholds: [:]),
            hasKeys: true
        )
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let token = try TokenBuilder.build(privateKey: agentKey, iss: agent, aud: agent, nonce: nonce)
        if workspaceMinted {
            WorkspaceAgentAccessHost.shared.nonceIndex.insert(nonce)
        }
        return (validator, token, agent, nonce)
    }

    private static func send(
        _ method: String, _ path: String, token: String, server: AuthTestServer, body: Data? = nil
    ) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // URLSession refuses a GET/DELETE carrying a body (-1103), so only
        // attach it to methods that actually send one.
        if let body, method != "GET", method != "DELETE" {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: request)
        return ((resp as? HTTPURLResponse)?.statusCode ?? -1, String(decoding: data, as: UTF8.self))
    }

    /// A workspace-minted agent-scoped key used to reach every Bearer-gated
    /// route. The gate confines it: enumeration, raw inference, memory writes,
    /// tool execution, media, and server administration all 403 before any
    /// handler runs; the teammate client's `/models` probe still works.
    @Test func workspaceKey_isConfinedToItsAgentSurface() async throws {
        let fixture = try Self.agentScopedFixture(workspaceMinted: true)
        defer { WorkspaceAgentAccessHost.shared.nonceIndex.remove(fixture.nonce) }
        let server = try await startAuthTestServer(validator: fixture.validator)
        defer { Task { await server.shutdown() } }

        let allowed = try await Self.send("GET", "/v1/models", token: fixture.token, server: server)
        #expect(allowed.status == 200)

        let denied: [(String, String)] = [
            ("GET", "/agents"),
            ("GET", "/v1/agents"),
            ("POST", "/v1/chat/completions"),
            ("POST", "/v1/embeddings"),
            ("POST", "/memory/ingest"),
            ("POST", "/mcp/call"),
            ("GET", "/mcp/tools"),
            ("POST", "/v1/images/generations"),
            ("GET", "/admin/runtime-settings"),
            ("PUT", "/admin/runtime-settings"),
            ("GET", "/admin/cache-stats"),
            ("GET", "/v1/tasks/not-a-task"),
        ]
        for (method, path) in denied {
            let result = try await Self.send(
                method, path, token: fixture.token, server: server, body: Data("{}".utf8)
            )
            #expect(result.status == 403, "\(method) \(path) returned \(result.status)")
            #expect(result.body.contains("agent_scope_denied"), "\(method) \(path): \(result.body)")
        }
    }

    /// Backwards compatibility: a legacy `/pair` / invite key (not in the
    /// workspace-key index) keeps reaching the routes existing paired peers
    /// use — including raw `/chat/completions` (Mode 1) — and is never handed
    /// an `agent_scope_denied` at the gate. Only `/admin/*` is newly closed.
    @Test func legacyPairingKey_keepsItsSurfaceExceptServerAdministration() async throws {
        let fixture = try Self.agentScopedFixture(workspaceMinted: false)
        let server = try await startAuthTestServer(validator: fixture.validator)
        defer { Task { await server.shutdown() } }

        // Reaches the handler (whatever the handler says about an empty
        // body, it is not the gate's 403).
        let stillOpen: [(String, String)] = [
            ("GET", "/v1/models"),
            ("GET", "/agents"),
            ("POST", "/v1/chat/completions"),
            ("POST", "/v1/embeddings"),
            ("GET", "/mcp/tools"),
        ]
        for (method, path) in stillOpen {
            let result = try await Self.send(
                method, path, token: fixture.token, server: server, body: Data("{}".utf8)
            )
            #expect(
                !(result.status == 403 && result.body.contains("agent_scope_denied")),
                "\(method) \(path) must not be gate-denied for a legacy key: \(result.status) \(result.body)"
            )
        }

        for (method, path) in [("GET", "/admin/runtime-settings"), ("PUT", "/admin/runtime-settings"), ("GET", "/admin/cache-stats"),
        ] {
            let result = try await Self.send(
                method, path, token: fixture.token, server: server, body: Data("{}".utf8)
            )
            #expect(result.status == 403, "\(method) \(path) returned \(result.status)")
            #expect(result.body.contains("agent_scope_denied"), "\(method) \(path): \(result.body)")
        }
    }

    /// The same routes stay open to a master-scoped key (unchanged contract),
    /// including `PUT /admin/runtime-settings` from a relayed (non-loopback)
    /// origin — remote automation with the owner's key is not disrupted.
    @Test func masterScopedKey_isNotConfinedByRoutePolicy() async throws {
        let server = try await startAuthTestServer(validator: .forAlice(), trustLoopback: true)
        defer { Task { await server.shutdown() } }
        let token = try TokenBuilder.build(
            privateKey: TestKeys.alicePrivateKey, iss: TestKeys.aliceAddress, aud: TestKeys.aliceAddress
        )
        let agents = try await Self.send("GET", "/agents", token: token, server: server)
        #expect(agents.status == 200)
        let settings = try await Self.send("GET", "/admin/runtime-settings", token: token, server: server)
        #expect(settings.status == 200)

        var relayedPut = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/admin/runtime-settings")!)
        relayedPut.httpMethod = "PUT"
        relayedPut.httpBody = Data("{}".utf8)
        relayedPut.setValue("application/json", forHTTPHeaderField: "Content-Type")
        relayedPut.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        relayedPut.setValue("1", forHTTPHeaderField: HTTPHandler.relayOriginHeaderName)
        let (putData, putResp) = try await URLSession.shared.data(for: relayedPut)
        let putStatus = (putResp as? HTTPURLResponse)?.statusCode ?? -1
        // The handler decides what to do with `{}` (validation), but the gate
        // must not turn the owner away.
        #expect(putStatus != 403 && putStatus != 401, "\(putStatus) \(String(decoding: putData, as: UTF8.self))")
    }

    /// `X-Osaurus-Agent-Id` naming an agent other than the key's own is refused
    /// at the gate for every agent-scoped key, so a paired peer can't persist
    /// into (or act as) another agent through `/chat/completions`, `/memory/*`
    /// or `/mcp/call`. Naming its own agent passes through.
    @Test func agentScopedKey_cannotNameAnotherAgentInHeader() async throws {
        let fixture = try Self.agentScopedFixture(workspaceMinted: false)
        let server = try await startAuthTestServer(validator: fixture.validator)
        defer { Task { await server.shutdown() } }

        let mine = UUID()
        let theirs = UUID()
        let theirAddress = try AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 4)
        AgentIdentityRegistry.shared.update(
            addresses: [fixture.agent, theirAddress], indices: [3, 4],
            addressByAgentId: [mine: fixture.agent, theirs: theirAddress]
        )
        defer { AgentIdentityRegistry.shared.update(addresses: [], indices: [], addressByAgentId: [:]) }

        func send(agentHeader: String) async throws -> (status: Int, body: String) {
            var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(fixture.token)", forHTTPHeaderField: "Authorization")
            request.setValue(agentHeader, forHTTPHeaderField: "X-Osaurus-Agent-Id")
            let (data, resp) = try await URLSession.shared.data(for: request)
            return ((resp as? HTTPURLResponse)?.statusCode ?? -1, String(decoding: data, as: UTF8.self))
        }

        let foreign = try await send(agentHeader: theirs.uuidString)
        #expect(foreign.status == 403, "\(foreign.status) \(foreign.body)")
        #expect(foreign.body.contains("X-Osaurus-Agent-Id"), "\(foreign.body)")

        let own = try await send(agentHeader: mine.uuidString)
        #expect(!(own.status == 403 && own.body.contains("agent_scope_denied")), "\(own.status) \(own.body)")
    }

    /// `/tasks/{id}` is reachable, but only for the task's creator: an
    /// agent-scoped key (either origin) that did not dispatch the task is
    /// refused.
    @Test func agentScopedKey_cannotTouchForeignTasks() async throws {
        let fixture = try Self.agentScopedFixture(workspaceMinted: false)
        defer { WorkspaceAgentAccessHost.shared.nonceIndex.remove(fixture.nonce) }
        let server = try await startAuthTestServer(validator: fixture.validator)
        defer { Task { await server.shutdown() } }

        let foreign = UUID()
        HTTPHandler.DispatchTaskOwnership.shared.record(taskId: foreign, audience: "0x000000000000000000000000000000000000beef",
            keyNonce: "other")
        defer { HTTPHandler.DispatchTaskOwnership.shared.removeAll() }

        for (method, suffix) in [("GET", ""), ("DELETE", ""), ("POST", "/clarify")] {
            let result = try await Self.send(
                method, "/v1/tasks/\(foreign.uuidString)\(suffix)", token: fixture.token, server: server,
                body: Data(#"{"response":"x"}"#.utf8)
            )
            #expect(result.status == 403, "\(method) tasks\(suffix) returned \(result.status)")
            #expect(result.body.contains("did not create"), "\(result.body)")
        }

        // A task it created itself is reachable (404: nothing is actually running).
        let own = UUID()
        HTTPHandler.DispatchTaskOwnership.shared.record(taskId: own, audience: fixture.agent, keyNonce: fixture.nonce)
        let ownResult = try await Self.send("GET", "/v1/tasks/\(own.uuidString)", token: fixture.token, server: server)
        #expect(ownResult.status == 404)
    }
}

// MARK: - Test Server Bootstrap

private struct AuthTestServer {
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

private func startAuthTestServer(
    validator: APIKeyValidator,
    trustLoopback: Bool = false
) async throws -> AuthTestServer {
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
                            apiKeyValidator: validator,
                            eventLoop: channel.eventLoop,
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
        let port = ch.localAddress?.port ?? 0
        return AuthTestServer(group: group, channel: ch, lease: lease, host: "127.0.0.1", port: port)
    } catch {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
        throw error
    }
}
