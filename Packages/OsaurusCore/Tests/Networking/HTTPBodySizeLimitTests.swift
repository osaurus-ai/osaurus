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

    // MARK: - Tighter /pair limit

    @Test
    func pairOverPairingLimit_returns413_evenWhenUnderGenericLimit() async throws {
        var config = ServerConfiguration.default
        config.maxRequestBodyBytes = 32 * 1024 * 1024
        config.maxPairingBodyBytes = 256
        let server = try await startBodyLimitServer(config: config)
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/pair")!)
        request.httpMethod = "POST"
        // 1 KiB body — well under the 32 MiB generic cap, but well over the
        // 256-byte /pair cap.
        request.httpBody = Data(repeating: 0x42, count: 1024)
        request.setValue("1024", forHTTPHeaderField: "Content-Length")

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(decoding: data, as: UTF8.self)
        #expect(status == 413)
        #expect(body.contains("payload_too_large"))
    }
}

// MARK: - Bootstrap

private struct BodyLimitTestServer {
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

private func startBodyLimitServer(config: ServerConfiguration) async throws -> BodyLimitTestServer {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
    let port = ch.localAddress?.port ?? 0
    return BodyLimitTestServer(group: group, channel: ch, host: "127.0.0.1", port: port)
}
