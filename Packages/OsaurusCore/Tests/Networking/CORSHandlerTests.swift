//
//  CORSHandlerTests.swift
//  OsaurusCoreTests
//
//  End-to-end CORS regression tests covering the user-reported scenario in
//  GitHub issue #952: an Obsidian plugin (Origin: app://obsidian.md) hitting
//  http://127.0.0.1:1337/api/tags receives "No 'Access-Control-Allow-Origin'
//  header" even with `*` configured.
//
//  These tests boot a real NIO server with `HTTPHandler` end-to-end so we
//  exercise the full path: `.head` → `computeCORSHeaders` →
//  `stateRef.value.corsHeaders` → response writer.
//
//  Two test families:
//  - "loopback_*" use `trustLoopback: true` (production default). They
//    cover the new auto-trust contract: any request whose connection
//    arrives via 127.0.0.1 / ::1 is treated as a trusted local caller
//    and gets `Access-Control-Allow-Origin: *` regardless of the
//    configured allowlist. Same posture as LM Studio / Ollama.
//  - "nonLoopback_*" use `trustLoopback: false` so the auto-trust
//    short-circuit doesn't fire even though the bind address is
//    loopback. They lock down the explicit-allowlist mode used by
//    `exposeToNetwork=true` / hardened deployments.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

@Suite("CORS handler")
struct CORSHandlerTests {

    // MARK: - Loopback auto-trust (production default)

    /// Reproduces the exact request shape from the Obsidian plugin: a simple
    /// `GET /api/tags` cross-origin request from `app://obsidian.md` against a
    /// server configured with the wildcard origin. Must return
    /// `Access-Control-Allow-Origin: *` so the browser does not block the
    /// response.
    @Test func wildcardOrigin_GET_apiTags_fromObsidian_returnsAllowOriginStar() async throws {
        var config = ServerConfiguration.default
        config.allowedOrigins = ["*"]
        let server = try await startCORSTestServer(config: config)
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/api/tags")!
        )
        request.httpMethod = "GET"
        request.setValue("app://obsidian.md", forHTTPHeaderField: "Origin")

        let (_, resp) = try await URLSession.shared.data(for: request)
        let http = resp as? HTTPURLResponse
        let acao = http?.value(forHTTPHeaderField: "Access-Control-Allow-Origin")

        #expect(http?.statusCode == 200)
        #expect(acao == "*")
    }

    /// The CORS preflight that Chromium-based clients (including Electron and
    /// Obsidian) emit for non-simple cross-origin requests. Must return 204
    /// with the full set of preflight headers; the browser otherwise blocks
    /// the follow-up request.
    @Test func wildcardOrigin_OPTIONS_apiTags_returnsFullPreflight() async throws {
        var config = ServerConfiguration.default
        config.allowedOrigins = ["*"]
        let server = try await startCORSTestServer(config: config)
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/api/tags")!
        )
        request.httpMethod = "OPTIONS"
        request.setValue("app://obsidian.md", forHTTPHeaderField: "Origin")
        request.setValue("GET", forHTTPHeaderField: "Access-Control-Request-Method")
        request.setValue("Content-Type, Authorization", forHTTPHeaderField: "Access-Control-Request-Headers")

        let (_, resp) = try await URLSession.shared.data(for: request)
        let http = resp as? HTTPURLResponse

        #expect(http?.statusCode == 204)
        #expect(http?.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
        let allowMethods = http?.value(forHTTPHeaderField: "Access-Control-Allow-Methods") ?? ""
        #expect(allowMethods.contains("GET"))
        let allowHeaders = http?.value(forHTTPHeaderField: "Access-Control-Allow-Headers") ?? ""
        #expect(allowHeaders.lowercased().contains("content-type"))
        #expect(allowHeaders.lowercased().contains("authorization"))
        #expect(http?.value(forHTTPHeaderField: "Access-Control-Max-Age") == "600")
    }

    /// The actual fix for #952: with the default empty allowlist, a loopback
    /// caller still gets `Access-Control-Allow-Origin: *`. This is the
    /// zero-config UX win — Obsidian and any other local app integration
    /// works without the user having to find and configure CORS settings.
    @Test func loopback_emptyAllowlist_returnsAllowOriginStar() async throws {
        var config = ServerConfiguration.default
        config.allowedOrigins = []
        let server = try await startCORSTestServer(config: config)
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/api/tags")!
        )
        request.httpMethod = "GET"
        request.setValue("app://obsidian.md", forHTTPHeaderField: "Origin")

        let (_, resp) = try await URLSession.shared.data(for: request)
        let http = resp as? HTTPURLResponse

        #expect(http?.statusCode == 200)
        #expect(http?.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
    }

    /// Loopback overrides allowlist mismatch — the local-machine trust
    /// boundary applies regardless of what allowlist the user configured for
    /// non-loopback callers. A power user who set `["http://localhost:3000"]`
    /// for LAN apps still gets their own loopback callers (Obsidian, etc.)
    /// served zero-config.
    @Test func loopback_specificOriginMismatch_stillReturnsAllowOriginStar() async throws {
        var config = ServerConfiguration.default
        config.allowedOrigins = ["http://localhost:3000"]
        let server = try await startCORSTestServer(config: config)
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/api/tags")!
        )
        request.httpMethod = "GET"
        request.setValue("app://obsidian.md", forHTTPHeaderField: "Origin")

        let (_, resp) = try await URLSession.shared.data(for: request)
        let http = resp as? HTTPURLResponse

        #expect(http?.statusCode == 200)
        #expect(http?.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
    }

    /// Loopback preflight with empty allowlist still returns the full CORS
    /// preflight envelope. Without this, browsers would 200 OK the preflight
    /// but reject the follow-up GET because the preflight lacked the methods
    /// / headers / max-age headers.
    @Test func loopback_emptyAllowlist_OPTIONS_preflight_returnsFullEnvelope()
        async throws
    {
        var config = ServerConfiguration.default
        config.allowedOrigins = []
        let server = try await startCORSTestServer(config: config)
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/api/tags")!
        )
        request.httpMethod = "OPTIONS"
        request.setValue("app://obsidian.md", forHTTPHeaderField: "Origin")
        request.setValue("GET", forHTTPHeaderField: "Access-Control-Request-Method")
        request.setValue("Content-Type", forHTTPHeaderField: "Access-Control-Request-Headers")

        let (_, resp) = try await URLSession.shared.data(for: request)
        let http = resp as? HTTPURLResponse

        #expect(http?.statusCode == 204)
        #expect(http?.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
        let allowMethods = http?.value(forHTTPHeaderField: "Access-Control-Allow-Methods") ?? ""
        #expect(allowMethods.contains("GET"))
        #expect(http?.value(forHTTPHeaderField: "Access-Control-Max-Age") == "600")
    }

    /// Exact origin match must echo the origin (NOT `*`) and add `Vary: Origin`
    /// so caches don't poison cross-origin responses. Even when loopback
    /// auto-trust is active, the loopback path *does* short-circuit to `*`,
    /// so this test verifies the wire shape that production loopback callers
    /// see when they happen to also be in the allowlist (they get `*`,
    /// not the echo). The exact-echo + Vary path is covered by
    /// `nonLoopback_specificOrigin_match_*` below.
    @Test func loopback_specificOrigin_match_returnsAllowOriginStar() async throws {
        var config = ServerConfiguration.default
        config.allowedOrigins = ["http://localhost:3000"]
        let server = try await startCORSTestServer(config: config)
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/api/tags")!
        )
        request.httpMethod = "GET"
        request.setValue("http://localhost:3000", forHTTPHeaderField: "Origin")

        let (_, resp) = try await URLSession.shared.data(for: request)
        let http = resp as? HTTPURLResponse

        #expect(http?.statusCode == 200)
        // Loopback auto-trust short-circuits BEFORE the exact-origin echo
        // branch, so loopback callers always see "*" (not the echoed
        // origin + Vary). This is intentional: the wildcard branch is
        // strictly more permissive.
        #expect(http?.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
    }

    // MARK: - Non-loopback (explicit allowlist mode)

    /// Hardened-deployment posture: `trustLoopback: false` disables the
    /// auto-trust short-circuit. With an empty allowlist the server must
    /// not advertise CORS, so cross-origin browser callers get blocked.
    /// Locks down the explicit-allowlist contract for users who run
    /// Osaurus under reverse proxies / strict environments.
    @Test func nonLoopback_emptyAllowlist_returnsNoCORSHeaders() async throws {
        var config = ServerConfiguration.default
        config.allowedOrigins = []
        let server = try await startCORSTestServer(config: config, trustLoopback: false)
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/api/tags")!
        )
        request.httpMethod = "GET"
        request.setValue("app://obsidian.md", forHTTPHeaderField: "Origin")

        // /api/tags is not a public path; with trustLoopback off and no
        // access keys configured the auth gate returns 401. CORS headers
        // must still be omitted (the auth-failure response is not
        // cross-origin readable either way).
        let (_, resp) = try await URLSession.shared.data(for: request)
        let http = resp as? HTTPURLResponse

        #expect(http?.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == nil)
    }

    /// Non-loopback wildcard is the explicit "I want CORS open to anyone"
    /// opt-in (e.g. for LAN-shared Osaurus instances). Must still emit `*`.
    @Test func nonLoopback_wildcardAllowlist_returnsAllowOriginStar() async throws {
        var config = ServerConfiguration.default
        config.allowedOrigins = ["*"]
        let server = try await startCORSTestServer(config: config, trustLoopback: false)
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/api/tags")!
        )
        request.httpMethod = "GET"
        request.setValue("app://obsidian.md", forHTTPHeaderField: "Origin")

        let (_, resp) = try await URLSession.shared.data(for: request)
        let http = resp as? HTTPURLResponse

        #expect(http?.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
    }

    /// Exact origin match must echo the origin (NOT `*`) and add `Vary: Origin`
    /// so caches don't poison cross-origin responses. This is the
    /// allowlist-with-credentials shape, only reachable on the non-loopback
    /// path now that loopback auto-trusts to `*`.
    @Test func nonLoopback_specificOrigin_match_returnsAllowOriginAndVary() async throws {
        var config = ServerConfiguration.default
        config.allowedOrigins = ["http://localhost:3000"]
        let server = try await startCORSTestServer(config: config, trustLoopback: false)
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/api/tags")!
        )
        request.httpMethod = "GET"
        request.setValue("http://localhost:3000", forHTTPHeaderField: "Origin")

        let (_, resp) = try await URLSession.shared.data(for: request)
        let http = resp as? HTTPURLResponse

        #expect(http?.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "http://localhost:3000")
        let vary = http?.value(forHTTPHeaderField: "Vary") ?? ""
        #expect(vary.contains("Origin"))
    }
}

// MARK: - Bootstrap

private struct CORSTestServer {
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

/// Boots a NIO server bound to a random loopback port. `trustLoopback`
/// defaults to `true` (production default for local clients like Obsidian
/// and browser plugins, which exercise the new loopback auto-trust). Pass
/// `trustLoopback: false` to exercise the explicit-allowlist path even
/// though the connection still arrives via 127.0.0.1.
private func startCORSTestServer(
    config: ServerConfiguration,
    trustLoopback: Bool = true
) async throws -> CORSTestServer {
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
    return CORSTestServer(group: group, channel: ch, host: "127.0.0.1", port: port)
}
