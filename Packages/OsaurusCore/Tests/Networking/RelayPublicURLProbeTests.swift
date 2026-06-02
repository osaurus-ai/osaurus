//
//  RelayPublicURLProbeTests.swift
//  OsaurusCoreTests
//
//  The relay auth WebSocket can succeed while the public HTTPS hostname still
//  closes before TLS or fails to proxy. These tests pin the cheap health probe
//  that prevents the UI from showing a green relay URL until `/health` works
//  through the public route.
//

import Foundation
import Testing

@testable import OsaurusCore

struct RelayPublicURLProbeTests {
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
