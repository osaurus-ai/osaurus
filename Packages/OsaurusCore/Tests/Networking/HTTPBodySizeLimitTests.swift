//
//  HTTPBodySizeLimitTests.swift
//  OsaurusCoreTests
//
//  End-to-end checks that the public NIO server rejects oversized request
//  bodies with `413 Payload Too Large` *before* the auth gate runs. Without
//  this, an unauthenticated client could exhaust host memory.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

@Suite("HTTPHandler body-size limits")
struct HTTPBodySizeLimitTests {

    // MARK: - Generic body limit

    @Test
    func contentLengthOverLimit_returns413() async throws {
        // Tight limit so the test stays fast and the assertion is unambiguous.
        var config = ServerConfiguration.default
        config.maxRequestBodyBytes = 1024
        let server = try await startBodyLimitServer(config: config)
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/v1/models")!)
        request.httpMethod = "POST"
        request.httpBody = Data(repeating: 0x41, count: 4096)
        // Ask for a real Content-Length so the server can short-circuit at .head.
        request.setValue("\(request.httpBody!.count)", forHTTPHeaderField: "Content-Length")

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 413)
        #expect(body.contains("payload_too_large"))
    }

    @Test
    func contentLengthAtLimit_isAccepted() async throws {
        var config = ServerConfiguration.default
        config.maxRequestBodyBytes = 1024
        let server = try await startBodyLimitServer(config: config)
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/v1/models")!)
        request.httpMethod = "POST"
        // Exactly at the limit, so the size guard must let it through.
        // Routing may then return 401 or 405; we only assert it isn't 413.
        request.httpBody = Data(repeating: 0x41, count: 1024)
        request.setValue("1024", forHTTPHeaderField: "Content-Length")

        let (_, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        #expect(status != 413)
    }

    // MARK: - Tighter pairing limit

    @Test
    func pairInviteOverPairingLimit_returns413_evenWhenUnderGenericLimit() async throws {
        var config = ServerConfiguration.default
        config.maxRequestBodyBytes = 32 * 1024 * 1024
        config.maxPairingBodyBytes = 256
        let server = try await startBodyLimitServer(config: config)
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/pair-invite")!)
        request.httpMethod = "POST"
        // 1 KiB body — well under the 32 MiB generic cap, but well over the
        // 256-byte pairing cap.
        request.httpBody = Data(repeating: 0x42, count: 1024)
        request.setValue("1024", forHTTPHeaderField: "Content-Length")

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 413)
        #expect(body.contains("payload_too_large"))
    }
}

@Suite("Retired LAN pairing routes")
struct RetiredPairRoutesTests {
    private func response(_ method: String, _ path: String, body: Data? = nil, on server: BodyLimitTestServer)
        async throws -> (status: Int, body: String)
    {
        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)\(path)")!)
        request.httpMethod = method
        request.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: request)
        return ((resp as? HTTPURLResponse)?.statusCode ?? -1, String(decoding: data, as: UTF8.self))
    }

    private func status(_ method: String, _ path: String, body: Data? = nil, on server: BodyLimitTestServer)
        async throws -> Int
    {
        try await response(method, path, body: body, on: server).status
    }

    @Test
    func theAgentPairingRoutesAreGone() async throws {
        let server = try await startBodyLimitServer(config: .default, trustLoopback: true)
        defer { Task { await server.shutdown() } }

        #expect(try await status("GET", "/pair/challenge", on: server) == 404)
        #expect(try await status("POST", "/pair", body: Data("{}".utf8), on: server) == 404)
    }

    /// Once an iPhone joined Sync, an older iPhone app calling them without a
    /// key is told to update, before the auth gate.
    @Test
    func olderIPhoneAppsAreToldToUpdateOnceRetired() async throws {
        let server = try await startBodyLimitServer(config: .default, trustLoopback: false, pairingRetired: true)
        defer { Task { await server.shutdown() } }

        for (method, path) in [("GET", "/pair/hello"), ("POST", "/pair/code"), ("POST", "/pair/confirm"), ("POST", "/pair/unpair")] {
            let reply = try await response(method, path, body: method == "POST" ? Data("{}".utf8) : nil, on: server)
            #expect(reply.status == 410, "\(path)")
            #expect(reply.body.contains(#""error":"update_required""#), "\(path)")
        }
    }

    /// Until then the 6-digit pairing works as on upstream main: the pairing
    /// steps are public and unpairing needs the phone's key.
    @Test
    func theSixDigitPairingAnswersUntilRetired() async throws {
        let server = try await startBodyLimitServer(config: .default, trustLoopback: false, pairingRetired: false)
        defer { Task { await server.shutdown() } }

        for path in ["/pair/code", "/pair/confirm"] {
            let reply = try await response("POST", path, body: Data("{}".utf8), on: server)
            #expect(reply.status != 410 && reply.status != 401 && reply.status != 404, "\(path): \(reply.status)")
        }
        #expect(try await status("POST", "/pair/unpair", body: Data("{}".utf8), on: server) == 401)
    }
}

// MARK: - Bootstrap

private struct BodyLimitTestServer {
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

private func startBodyLimitServer(
    config: ServerConfiguration,
    trustLoopback: Bool = false,
    pairingRetired: Bool = true
) async throws -> BodyLimitTestServer {
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
                            // trustLoopback false so the auth gate would normally
                            // run — proves the size guard fires *before* it.
                            trustLoopback: trustLoopback,
                            pairingRetiredProvider: { pairingRetired }
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
        return BodyLimitTestServer(group: group, channel: ch, lease: lease, host: "127.0.0.1", port: port)
    } catch {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
        throw error
    }
}
