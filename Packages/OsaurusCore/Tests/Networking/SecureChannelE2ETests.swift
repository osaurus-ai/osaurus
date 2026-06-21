//
//  SecureChannelE2ETests.swift
//  OsaurusCoreTests
//
//  End-to-end tests for the Osaurus Secure Channel against a real NIO
//  server: encrypted calls through `/secure/call` (buffered and SSE), the
//  426 hard-require gate on agent run/dispatch, replay rejection, and
//  unknown-session handling.
//
//  The handshake endpoint itself needs a Keychain-backed agent identity, so
//  these tests establish the session pair directly via `SecureChannel`
//  (already covered by `SecureChannelTests`) and register the server half in
//  `SecureSessionStore.shared` — exactly what `/secure/session` does after
//  signing.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

struct SecureChannelE2ETests {

    // MARK: - Helpers

    private var agentKey: Data { AgentKey.derive(masterKey: TestKeys.alicePrivateKey, index: 0) }
    private var agentAddress: String {
        try! AgentKey.deriveAddress(masterKey: TestKeys.alicePrivateKey, index: 0)
    }

    /// Establish a client/server session pair and register the server half,
    /// mirroring what a successful `/secure/session` handshake produces.
    private func establishSession() throws -> SecureChannelSession {
        let (clientKey, hello) = SecureChannel.makeClientHello(agentAddress: agentAddress)
        let (serverSession, serverHello) = try SecureChannel.establishServerSession(hello: hello) {
            try signSecureChannelPayload($0, privateKey: agentKey)
        }
        SecureSessionStore.shared.register(serverSession)
        return try SecureChannel.establishClientSession(
            hello: hello,
            ephemeralKey: clientKey,
            serverHello: serverHello,
            expectedAgentAddress: agentAddress
        )
    }

    private func secureCallRequest(
        server: SecureTestServer,
        call: SecureChannel.CallRequest,
        accept: String = "application/json"
    ) throws -> URLRequest {
        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/secure/call")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(call)
        return request
    }

    // MARK: - Encrypted Buffered Call

    @Test func secureCall_models_decryptsBufferedResponse() async throws {
        let server = try await startSecureTestServer()
        defer { Task { await server.shutdown() } }
        let session = try establishSession()

        let inner = SecureChannel.InnerRequest(
            method: "GET",
            path: "/models",
            authorization: "Bearer \(TestAuth.bearerToken)",
            accept: "application/json"
        )
        let (call, requestSeq) = try session.sealCall(innerRequest: JSONEncoder().encode(inner))
        let request = try secureCallRequest(server: server, call: call)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let http = resp as? HTTPURLResponse
        #expect(http?.statusCode == 200)
        #expect(http?.value(forHTTPHeaderField: SecureChannelResponseEncryptor.markerHeaderName) == "1")
        // The raw body must be an encrypted frame, not the models JSON.
        #expect(!String(decoding: data, as: UTF8.self).contains("\"object\""))

        let opener = session.makeResponseOpener(requestSeq: requestSeq)
        let innerResponse = try SecureChannelClient.openBufferedResponse(data, opener: opener)
        #expect(innerResponse.status == 200)
        let body = innerResponse.body.flatMap { Data(base64urlEncoded: $0) } ?? Data()
        #expect(String(decoding: body, as: UTF8.self).contains("\"object\""))
    }

    // MARK: - Encrypted SSE Stream

    @Test func secureCall_chatStream_decryptsSSEWithFin() async throws {
        let server = try await startSecureTestServer(
            engine: MockChatEngine(deltas: ["alpha", "beta"], completeText: "", model: "fake")
        )
        defer { Task { await server.shutdown() } }
        let session = try establishSession()

        let chatBody = try JSONEncoder().encode(
            ChatCompletionRequest(
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
        )
        let inner = SecureChannel.InnerRequest(
            method: "POST",
            path: "/chat/completions",
            authorization: "Bearer \(TestAuth.bearerToken)",
            accept: "text/event-stream",
            contentType: "application/json",
            headers: ["X-Persist": "false"],
            body: chatBody.base64urlEncoded
        )
        let (call, requestSeq) = try session.sealCall(innerRequest: JSONEncoder().encode(inner))
        let request = try secureCallRequest(server: server, call: call, accept: "text/event-stream")

        let (data, resp) = try await URLSession.shared.data(for: request)
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)

        // Raw wire bytes must not leak the deltas.
        let rawBody = String(decoding: data, as: UTF8.self)
        #expect(!rawBody.contains("alpha"))
        #expect(!rawBody.contains("[DONE]"))

        let decoder = SecureFrameStreamDecoder(
            opener: session.makeResponseOpener(requestSeq: requestSeq)
        )
        let plaintext = try decoder.feed(data)
        try decoder.verifyCompleted()

        let sse = String(decoding: plaintext, as: UTF8.self)
        #expect(sse.contains("\"role\":\"assistant\""))
        #expect(sse.contains("alpha"))
        #expect(sse.contains("beta"))
        #expect(sse.contains("data: [DONE]"))
    }

    // MARK: - Replay / Session Errors

    @Test func secureCall_replayedEnvelope_rejected() async throws {
        let server = try await startSecureTestServer()
        defer { Task { await server.shutdown() } }
        let session = try establishSession()

        let inner = SecureChannel.InnerRequest(
            method: "GET",
            path: "/models",
            authorization: "Bearer \(TestAuth.bearerToken)"
        )
        let (call, _) = try session.sealCall(innerRequest: JSONEncoder().encode(inner))
        let request = try secureCallRequest(server: server, call: call)

        let (_, first) = try await URLSession.shared.data(for: request)
        #expect((first as? HTTPURLResponse)?.statusCode == 200)

        // Captured-and-replayed envelope: the anti-replay window must refuse
        // to re-execute the call.
        let (replayData, replay) = try await URLSession.shared.data(for: request)
        #expect((replay as? HTTPURLResponse)?.statusCode == 409)
        #expect(String(decoding: replayData, as: UTF8.self).contains("secure_replay"))
    }

    @Test func secureCall_unknownSession_401WithRehandshakeCode() async throws {
        let server = try await startSecureTestServer()
        defer { Task { await server.shutdown() } }
        let session = try establishSession()

        let inner = SecureChannel.InnerRequest(method: "GET", path: "/models", authorization: nil)
        let (call, _) = try session.sealCall(innerRequest: JSONEncoder().encode(inner))
        let forged = SecureChannel.CallRequest(v: call.v, sid: "bogus-sid", seq: call.seq, ct: call.ct)
        let request = try secureCallRequest(server: server, call: forged)

        let (data, resp) = try await URLSession.shared.data(for: request)
        #expect((resp as? HTTPURLResponse)?.statusCode == 401)
        #expect(String(decoding: data, as: UTF8.self).contains("secure_session_unknown"))
    }

    // MARK: - 426 Hard-Require Gate

    @Test func plaintextRun_relayOrigin_returns426() async throws {
        let server = try await startSecureTestServer(trustLoopback: true)
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/agents/\(UUID().uuidString)/run")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: HTTPHandler.relayOriginHeaderName)
        request.authenticate()
        request.httpBody = Data("{}".utf8)

        let (data, resp) = try await URLSession.shared.data(for: request)
        #expect((resp as? HTTPURLResponse)?.statusCode == 426)
        let body = String(decoding: data, as: UTF8.self)
        #expect(body.contains("secure_channel_required"))
        #expect(body.contains("end-to-end encryption"))
    }

    @Test func plaintextDispatch_relayOrigin_returns426() async throws {
        let server = try await startSecureTestServer(trustLoopback: true)
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(
                string: "http://\(server.host):\(server.port)/agents/\(UUID().uuidString)/dispatch"
            )!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: HTTPHandler.relayOriginHeaderName)
        request.authenticate()
        request.httpBody = Data(#"{"task":"hello"}"#.utf8)

        let (data, resp) = try await URLSession.shared.data(for: request)
        #expect((resp as? HTTPURLResponse)?.statusCode == 426)
        #expect(String(decoding: data, as: UTF8.self).contains("secure_channel_required"))
    }

    @Test func plaintextRun_loopbackTrusted_bypassesGate() async throws {
        let server = try await startSecureTestServer(trustLoopback: true)
        defer { Task { await server.shutdown() } }

        // Loopback callers (CLI, App Intents) stay plaintext: the gate must
        // not fire. (The request still fails later — invalid body — but with
        // a non-426 status.)
        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/agents/\(UUID().uuidString)/run")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("not-json".utf8)

        let (_, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        #expect(status != 426)
    }

    @Test func secureRun_relayOrigin_passes426Gate() async throws {
        let server = try await startSecureTestServer(trustLoopback: true)
        defer { Task { await server.shutdown() } }
        let session = try establishSession()

        // The same relay-origin run that 426s in plaintext sails through the
        // gate when it arrives through the channel (and then fails on its
        // invalid body with an encrypted 400 — proving the route ran).
        let inner = SecureChannel.InnerRequest(
            method: "POST",
            path: "/agents/\(UUID().uuidString)/run",
            authorization: "Bearer \(TestAuth.bearerToken)",
            contentType: "application/json",
            body: Data("not-json".utf8).base64urlEncoded
        )
        let (call, requestSeq) = try session.sealCall(innerRequest: JSONEncoder().encode(inner))
        var request = try secureCallRequest(server: server, call: call)
        request.setValue("1", forHTTPHeaderField: HTTPHandler.relayOriginHeaderName)

        let (data, resp) = try await URLSession.shared.data(for: request)
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)

        let opener = session.makeResponseOpener(requestSeq: requestSeq)
        let innerResponse = try SecureChannelClient.openBufferedResponse(data, opener: opener)
        #expect(innerResponse.status == 400)
        #expect(innerResponse.status != 426)
    }

    @Test func secureRun_builtInAgent_stillRejectedInsideChannel() async throws {
        let server = try await startSecureTestServer(trustLoopback: true)
        defer { Task { await server.shutdown() } }
        let session = try establishSession()

        // The channel satisfies the 426 gate, but the built-in Default agent
        // remains locked to in-app surfaces: a remote (relay-origin) caller
        // must still get the 403 guard envelope — now encrypted.
        let chatBody = Data(
            #"{"model":"fake","stream":true,"messages":[{"role":"user","content":"hi"}]}"#.utf8
        )
        let inner = SecureChannel.InnerRequest(
            method: "POST",
            path: "/agents/\(Agent.defaultId.uuidString)/run",
            authorization: "Bearer \(TestAuth.bearerToken)",
            contentType: "application/json",
            body: chatBody.base64urlEncoded
        )
        let (call, requestSeq) = try session.sealCall(innerRequest: JSONEncoder().encode(inner))
        var request = try secureCallRequest(server: server, call: call)
        request.setValue("1", forHTTPHeaderField: HTTPHandler.relayOriginHeaderName)

        let (data, resp) = try await URLSession.shared.data(for: request)
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)

        let opener = session.makeResponseOpener(requestSeq: requestSeq)
        let innerResponse = try SecureChannelClient.openBufferedResponse(data, opener: opener)
        #expect(innerResponse.status == 403)
        let body = innerResponse.body.flatMap { Data(base64urlEncoded: $0) } ?? Data()
        #expect(String(decoding: body, as: UTF8.self).contains("built_in_agent_not_exposable"))
    }

    // MARK: - Agent Run Addressed By Crypto Address

    /// The regression that broke share+accept streaming: a paired peer
    /// addresses the remote agent by its **crypto address** — the only
    /// identity the invite carries, since the peer never learns the
    /// host-local UUID — authenticated by an **agent-scoped** key. The host's
    /// `/agents/{id}/run` must resolve that address to its local agent and let
    /// the matching agent-scoped key through, then stream encrypted SSE
    /// deltas. Before the fix the address failed `UUID(uuidString:)`, the
    /// agent-scope check failed closed with `403 agent_scope_denied`, and the
    /// streaming client surfaced a misleading `streamTruncated`.
    @Test func secureRun_byCryptoAddress_agentScopedKey_streamsSSE() async throws {
        // The host-local UUID the peer never sees; it only holds `agentAddress`.
        let hostAgentId = UUID()

        // Agent-scoped key (iss == aud == the agent address, signed by the
        // agent child key): NOT master-scoped, so the route's agent-scope
        // check actually runs instead of being waved through.
        let scopedKey = try TokenBuilder.build(
            privateKey: agentKey,
            iss: agentAddress,
            aud: agentAddress
        )
        let validator = APIKeyValidator.forAlice(
            agentAddress: agentAddress,
            extraWhitelist: [agentAddress]
        )

        let server = try await startSecureTestServer(
            engine: MockChatEngine(deltas: ["alpha", "beta"], completeText: "", model: "fake"),
            trustLoopback: true,
            validator: validator
        )
        defer { Task { await server.shutdown() } }

        // Publish the host's address→UUID mapping while the server-test lease
        // is held (it serializes with the other registry-mutating tests), so
        // the run endpoint resolves the crypto address to this local agent.
        AgentIdentityRegistry.shared.update(
            addresses: [agentAddress],
            indices: [0],
            addressByAgentId: [hostAgentId: agentAddress]
        )

        let session = try establishSession()

        let chatBody = Data(
            #"{"model":"fake","stream":true,"messages":[{"role":"user","content":"hi"}]}"#.utf8
        )
        let inner = SecureChannel.InnerRequest(
            method: "POST",
            path: "/agents/\(agentAddress)/run",
            authorization: "Bearer \(scopedKey)",
            accept: "text/event-stream",
            contentType: "application/json",
            headers: ["X-Persist": "false"],
            body: chatBody.base64urlEncoded
        )
        let (call, requestSeq) = try session.sealCall(innerRequest: JSONEncoder().encode(inner))
        var request = try secureCallRequest(server: server, call: call, accept: "text/event-stream")
        // Arrive as a relayed (remote) caller, exactly like a paired peer does.
        request.setValue("1", forHTTPHeaderField: HTTPHandler.relayOriginHeaderName)

        let (data, resp) = try await URLSession.shared.data(for: request)
        let http = resp as? HTTPURLResponse
        #expect(http?.statusCode == 200)
        // Resolution + agent-scope both passed, so the route entered streaming
        // mode: the outer envelope is SSE, not a buffered error frame.
        #expect(
            http?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true
        )

        // The wire stays opaque; deltas appear only after authenticated decrypt.
        let rawBody = String(decoding: data, as: UTF8.self)
        #expect(!rawBody.contains("alpha"))
        #expect(!rawBody.contains("agent_scope_denied"))

        let decoder = SecureFrameStreamDecoder(
            opener: session.makeResponseOpener(requestSeq: requestSeq)
        )
        let plaintext = try decoder.feed(data)
        try decoder.verifyCompleted()
        let sse = String(decoding: plaintext, as: UTF8.self)
        #expect(sse.contains("alpha"))
        #expect(sse.contains("beta"))
    }

    /// `GET /agents/{id}` must enforce the same per-agent scope as
    /// `/agents/{id}/run`: an agent-scoped key (agent A) must NOT read a
    /// DIFFERENT agent's (agent B) metadata — name, description,
    /// `effective_model`. Before the fix the run route was scoped but the
    /// metadata route was not, so a paired peer could enumerate every agent.
    @Test func secureGetAgent_crossAgentScopedKey_returns403() async throws {
        // Caller is agent A (index 0 == `agentAddress`); the GET targets a
        // different agent B (index 1) the caller's key is not scoped to.
        let callerAgentId = UUID()
        let otherAgentId = UUID()
        let otherAgentAddress = try AgentKey.deriveAddress(
            masterKey: TestKeys.alicePrivateKey,
            index: 1
        )

        // Agent-scoped key (iss == aud == agent A): NOT master-scoped, so the
        // route's agent-scope check actually runs instead of being waved through.
        let scopedKey = try TokenBuilder.build(
            privateKey: agentKey,
            iss: agentAddress,
            aud: agentAddress
        )
        let validator = APIKeyValidator.forAlice(
            agentAddress: agentAddress,
            extraWhitelist: [agentAddress]
        )

        let server = try await startSecureTestServer(
            trustLoopback: true,
            validator: validator
        )
        defer { Task { await server.shutdown() } }

        // Both addresses resolve via the registry (held under the server-test
        // lease, which serializes registry mutation). The GET target (B) must
        // resolve to a UUID so the scope gate runs before any existence check.
        AgentIdentityRegistry.shared.update(
            addresses: [agentAddress, otherAgentAddress],
            indices: [0, 1],
            addressByAgentId: [callerAgentId: agentAddress, otherAgentId: otherAgentAddress]
        )
        defer {
            AgentIdentityRegistry.shared.update(addresses: [], indices: [], addressByAgentId: [:])
        }

        let session = try establishSession()

        let inner = SecureChannel.InnerRequest(
            method: "GET",
            path: "/agents/\(otherAgentAddress)",
            authorization: "Bearer \(scopedKey)",
            accept: "application/json"
        )
        let (call, requestSeq) = try session.sealCall(innerRequest: JSONEncoder().encode(inner))
        var request = try secureCallRequest(server: server, call: call)
        // Arrive as a relayed (remote) caller so the Bearer audience — not
        // loopback trust — drives the scope check, exactly like a paired peer.
        request.setValue("1", forHTTPHeaderField: HTTPHandler.relayOriginHeaderName)

        let (data, resp) = try await URLSession.shared.data(for: request)
        // Outer secure envelope is 200; the rejection rides INSIDE the ciphertext.
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
        #expect(!String(decoding: data, as: UTF8.self).contains("agent_scope_denied"))

        let opener = session.makeResponseOpener(requestSeq: requestSeq)
        let innerResponse = try SecureChannelClient.openBufferedResponse(data, opener: opener)
        #expect(innerResponse.status == 403)
        let body = innerResponse.body.flatMap { Data(base64urlEncoded: $0) } ?? Data()
        #expect(String(decoding: body, as: UTF8.self).contains("agent_scope_denied"))
    }

    // MARK: - Inner Auth Still Enforced

    @Test func secureCall_missingInnerBearer_401Inside() async throws {
        let server = try await startSecureTestServer()
        defer { Task { await server.shutdown() } }
        let session = try establishSession()

        // The channel encrypts but does not authenticate the caller — the
        // inner request must still carry a valid Bearer for protected routes.
        let inner = SecureChannel.InnerRequest(method: "GET", path: "/models", authorization: nil)
        let (call, requestSeq) = try session.sealCall(innerRequest: JSONEncoder().encode(inner))
        let request = try secureCallRequest(server: server, call: call)

        let (data, resp) = try await URLSession.shared.data(for: request)
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)

        let opener = session.makeResponseOpener(requestSeq: requestSeq)
        let innerResponse = try SecureChannelClient.openBufferedResponse(data, opener: opener)
        #expect(innerResponse.status == 401)
    }

    @Test func secureCall_cannotTargetSecureRoutes() async throws {
        let server = try await startSecureTestServer()
        defer { Task { await server.shutdown() } }
        let session = try establishSession()

        // No nesting: an inner request pointing back at /secure/* is malformed.
        let inner = SecureChannel.InnerRequest(
            method: "POST",
            path: "/secure/call",
            authorization: nil
        )
        let (call, _) = try session.sealCall(innerRequest: JSONEncoder().encode(inner))
        let request = try secureCallRequest(server: server, call: call)

        let (data, resp) = try await URLSession.shared.data(for: request)
        #expect((resp as? HTTPURLResponse)?.statusCode == 400)
        #expect(String(decoding: data, as: UTF8.self).contains("secure_malformed"))
    }
}

// MARK: - Test Server Bootstrap

private struct SecureTestServer {
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

/// Boots a server with the production pipeline shape: HTTP codec →
/// `SecureChannelResponseEncryptor` → `HTTPHandler` (armed encryptor wiring).
private func startSecureTestServer(
    engine: ChatEngineProtocol = MockChatEngine(),
    trustLoopback: Bool = false,
    validator: APIKeyValidator = TestAuth.validator
) async throws -> SecureTestServer {
    let lease = await HTTPServerTestLock.shared.acquire()
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    let encryptor = SecureChannelResponseEncryptor()
                    return channel.pipeline.addHandlers([
                        encryptor,
                        HTTPHandler(
                            configuration: .default,
                            apiKeyValidator: validator,
                            eventLoop: channel.eventLoop,
                            chatEngine: engine,
                            trustLoopback: trustLoopback,
                            responseEncryptor: encryptor
                        ),
                    ])
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        let port = ch.localAddress?.port ?? 0
        return SecureTestServer(group: group, channel: ch, lease: lease, host: "127.0.0.1", port: port)
    } catch {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
        throw error
    }
}
