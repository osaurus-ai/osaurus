//
//  HTTPHandlerEndpointTests.swift
//  OsaurusCoreTests
//
//  Handler-level coverage relocated from the (now-deleted) `Router.swift`
//  unit tests. The legacy `Router` was a dead reference dispatcher; the
//  production HTTP path is fully owned by `HTTPHandler`. These tests boot a
//  real NIO server (loopback-trusted, so the protected routes pass the auth
//  gate without a token) and assert the same endpoint behavior the old
//  `router_*` tests covered: `/health`, `/`, `/models`, `/v1/models`, and a
//  404 for an unknown path.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

struct HTTPHandlerEndpointTests {

    @Test func health_endpoint_returns_healthy_json() async throws {
        let server = try await startServer()
        defer { Task { await server.shutdown() } }

        let (data, resp) = try await URLSession.shared.data(
            from: URL(string: "http://\(server.host):\(server.port)/health")!
        )
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["status"] as? String == "healthy")
    }

    @Test func root_endpoint_returns_banner() async throws {
        let server = try await startServer()
        defer { Task { await server.shutdown() } }

        let (data, resp) = try await URLSession.shared.data(
            from: URL(string: "http://\(server.host):\(server.port)/")!
        )
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("Osaurus Server is running"))
    }

    @Test func models_endpoint_returns_list() async throws {
        let server = try await startServer()
        defer { Task { await server.shutdown() } }

        let (data, resp) = try await URLSession.shared.data(
            from: URL(string: "http://\(server.host):\(server.port)/models")!
        )
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
        let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
        #expect(modelsResponse.object == "list")
        #expect(modelsResponse.data.count >= 0)

        // OpenAI-compatible alias.
        let (_, resp2) = try await URLSession.shared.data(
            from: URL(string: "http://\(server.host):\(server.port)/v1/models")!
        )
        #expect((resp2 as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test func unknown_path_returns_404() async throws {
        let server = try await startServer()
        defer { Task { await server.shutdown() } }

        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/unknown")!)
        request.httpMethod = "POST"
        let (_, resp) = try await URLSession.shared.data(for: request)
        #expect((resp as? HTTPURLResponse)?.statusCode == 404)
    }

    // MARK: - Test Server Bootstrap

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
                                trustLoopback: true
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
