//
//  RelayPublicURLProbeTests.swift
//  OsaurusCoreTests
//
//  The relay auth WebSocket can succeed while the public HTTPS hostname still
//  closes before TLS or fails to proxy. These tests pin the cheap health probe
//  that prevents the UI from showing a green relay URL until `/health` works
//  through the public route.
//

import CFNetwork
import Foundation
import Testing

@testable import OsaurusCore

struct RelayPublicURLProbeTests {
    @Test func liveHealthCheckSessionUsesGlobalProxySetting() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-relay-health-proxy-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
            }

            try OsaurusPaths.ensureExists(OsaurusPaths.config())
            var configuration = ServerConfiguration.default
            configuration.globalProxyURL = "https://proxy.example.com:8443"
            try JSONEncoder().encode(configuration).write(to: OsaurusPaths.serverConfigFile(), options: .atomic)

            let session = RelayPublicURLProbe.makeHealthCheckSession()
            defer { session.invalidateAndCancel() }

            let dictionary = session.configuration.connectionProxyDictionary
            #expect(dictionary?[proxyKey(kCFNetworkProxiesHTTPSEnable)] as? Int == 1)
            #expect(dictionary?[proxyKey(kCFNetworkProxiesHTTPSProxy)] as? String == "proxy.example.com")
            #expect(dictionary?[proxyKey(kCFNetworkProxiesHTTPSPort)] as? Int == 8443)
            #expect(session.configuration.waitsForConnectivity == false)
            #expect(session.configuration.timeoutIntervalForRequest == 8)
            #expect(session.configuration.timeoutIntervalForResource == 8)
        }
    }

    @Test func websocketSessionUsesGlobalProxySetting() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-relay-websocket-proxy-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
            }

            try OsaurusPaths.ensureExists(OsaurusPaths.config())
            var configuration = ServerConfiguration.default
            configuration.globalProxyURL = "socks5://proxy.example.com:1080"
            try JSONEncoder().encode(configuration).write(to: OsaurusPaths.serverConfigFile(), options: .atomic)

            let session = RelayTunnelManager.makeWebSocketSession()
            defer { session.invalidateAndCancel() }

            let dictionary = session.configuration.connectionProxyDictionary
            #expect(dictionary?[proxyKey(kCFNetworkProxiesSOCKSEnable)] as? Int == 1)
            #expect(dictionary?[proxyKey(kCFNetworkProxiesSOCKSProxy)] as? String == "proxy.example.com")
            #expect(dictionary?[proxyKey(kCFNetworkProxiesSOCKSPort)] as? Int == 1080)
        }
    }

    @Test func healthRequestTargetsPublicHealthEndpoint() throws {
        let request = try #require(
            RelayPublicURLProbe.makeHealthRequest(baseURL: "https://0xabc.agent.osaurus.ai")
        )

        #expect(request.url?.absoluteString == "https://0xabc.agent.osaurus.ai/health")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "OsaurusRelayHealthCheck/1")
    }

    @Test func healthRequestHandlesTrailingSlash() throws {
        let request = try #require(
            RelayPublicURLProbe.makeHealthRequest(baseURL: "https://0xabc.agent.osaurus.ai/")
        )

        #expect(request.url?.absoluteString == "https://0xabc.agent.osaurus.ai/health")
    }

    @Test func checkTreatsHTTP200HealthAsReachable() async throws {
        let probe = RelayPublicURLProbe { request in
            #expect(request.url?.path == "/health")
            return (Data(#"{"status":"ok"}"#.utf8), Self.response(for: request, statusCode: 200))
        }

        let result = await probe.check(
            baseURL: "https://0xabc.agent.osaurus.ai",
            attempts: 1,
            retryDelayNanoseconds: 0
        )

        #expect(result.reachable)
        #expect(result.statusCode == 200)
        #expect(result.failureDescription == nil)
    }

    @Test func checkReportsHTTPFailureInsteadOfMarkingReachable() async {
        let probe = RelayPublicURLProbe { request in
            (Data(#"{"error":"not ready"}"#.utf8), Self.response(for: request, statusCode: 503))
        }

        let result = await probe.check(
            baseURL: "https://0xabc.agent.osaurus.ai",
            attempts: 1,
            retryDelayNanoseconds: 0
        )

        #expect(!result.reachable)
        #expect(result.statusCode == 503)
        #expect(result.failureDescription == "Public link health check returned HTTP 503.")
    }

    @Test func checkReportsTransportFailureForClosedTLS() async {
        let probe = RelayPublicURLProbe { _ in
            throw NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorNetworkConnectionLost,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Client network socket disconnected before secure TLS connection was established"
                ]
            )
        }

        let result = await probe.check(
            baseURL: "https://0xabc.agent.osaurus.ai",
            attempts: 1,
            retryDelayNanoseconds: 0
        )

        #expect(!result.reachable)
        #expect(result.statusCode == nil)
        #expect(
            result.failureDescription?
                .contains("Client network socket disconnected before secure TLS connection was established")
                == true
        )
    }

    @Test func malformedBaseURLReturnsActionableFailure() async {
        let probe = RelayPublicURLProbe { _ in
            Issue.record("Malformed URLs must not hit the transport")
            return (Data(), URLResponse())
        }

        let result = await probe.check(
            baseURL: "not a url",
            attempts: 1,
            retryDelayNanoseconds: 0
        )

        #expect(!result.reachable)
        #expect(result.statusCode == nil)
        #expect(result.failureDescription == "Public link URL is invalid.")
    }

    private static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://0xabc.agent.osaurus.ai/health")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}

private func proxyKey(_ value: CFString) -> AnyHashable {
    AnyHashable(value as String)
}
