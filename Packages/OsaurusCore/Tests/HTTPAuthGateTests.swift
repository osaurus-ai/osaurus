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
        let tampered = "osk-v2.\(parts[1]).\(String(sigChars))"

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

    // MARK: - requireAPIKey=false Bypasses Gate

    @Test func requireAPIKeyFalse_protectedPath_noToken_returns200() async throws {
        let server = try await startAuthTestServer(
            validator: .empty,
            requireAPIKey: false
        )
        defer { Task { await server.shutdown() } }

        let (_, resp) = try await URLSession.shared.data(
            from: URL(string: "http://\(server.host):\(server.port)/v1/models")!
        )
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
    }
}

// MARK: - Test Server Bootstrap

private struct AuthTestServer {
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

private func startAuthTestServer(
    validator: APIKeyValidator,
    requireAPIKey: Bool = true
) async throws -> AuthTestServer {
    var config = ServerConfiguration.default
    config.requireAPIKey = requireAPIKey

    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let bootstrap = ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: 256)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap {
                channel.pipeline.addHandler(
                    HTTPHandler(
                        configuration: config,
                        apiKeyValidator: validator,
                        eventLoop: channel.eventLoop
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
    return AuthTestServer(group: group, channel: ch, host: "127.0.0.1", port: port)
}
