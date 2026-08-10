//
//  MCPAuthFailureProbeTests.swift
//  osaurusTests
//
//  Regression coverage for auth-failure classification of remote MCP
//  endpoints, including token-only servers that answer 401 without a
//  `WWW-Authenticate` header and OAuth-capable servers (runalyze.com) that
//  send a Bearer challenge even though they also accept a static API token.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("MCP auth failure probe")
struct MCPAuthFailureProbeTests {
    private func response(
        status: Int,
        headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com/mcp")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    @Test func evaluateIgnoresNonAuthStatuses() {
        #expect(MCPAuthFailureProbe.evaluate(response: response(status: 200), body: nil, sentAuthorization: true) == nil)
        #expect(MCPAuthFailureProbe.evaluate(response: response(status: 500), body: nil, sentAuthorization: true) == nil)
        #expect(MCPAuthFailureProbe.evaluate(response: response(status: 404), body: nil, sentAuthorization: false) == nil)
    }

    @Test func evaluateClassifiesBare401WithoutChallengeHeader() {
        let result = MCPAuthFailureProbe.evaluate(
            response: response(status: 401),
            body: nil,
            sentAuthorization: false
        )
        #expect(result != nil)
        #expect(result?.statusCode == 401)
        #expect(result?.challenge == nil)
        #expect(result?.serverMessage == nil)
    }

    @Test func evaluateParsesRunalyzeStyleChallengeAndBody() {
        let body = Data(
            #"{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Missing authentication token."}}"#
                .utf8
        )
        let result = MCPAuthFailureProbe.evaluate(
            response: response(
                status: 401,
                headers: [
                    "WWW-Authenticate":
                        #"Bearer resource_metadata="https://runalyze.com/.well-known/oauth-protected-resource", scope="mcp.read""#
                ]
            ),
            body: body,
            sentAuthorization: true
        )
        #expect(result?.challenge?.scope == "mcp.read")
        #expect(
            result?.challenge?.resourceMetadataURL?.absoluteString
                == "https://runalyze.com/.well-known/oauth-protected-resource"
        )
        #expect(result?.serverMessage == "Missing authentication token.")
    }

    @Test func jsonRPCErrorMessageHandlesCommonShapes() {
        let nested = Data(#"{"error":{"code":-32001,"message":"nope"}}"#.utf8)
        let flat = Data(#"{"error":"denied"}"#.utf8)
        let plain = Data(#"{"message":"expired"}"#.utf8)
        let junk = Data("not json".utf8)
        let empty = Data(#"{"error":{"message":""}}"#.utf8)
        #expect(MCPAuthFailureProbe.jsonRPCErrorMessage(from: nested) == "nope")
        #expect(MCPAuthFailureProbe.jsonRPCErrorMessage(from: flat) == "denied")
        #expect(MCPAuthFailureProbe.jsonRPCErrorMessage(from: plain) == "expired")
        #expect(MCPAuthFailureProbe.jsonRPCErrorMessage(from: junk) == nil)
        #expect(MCPAuthFailureProbe.jsonRPCErrorMessage(from: empty) == nil)
    }

    @Test func failureDescriptionForBearerTokenNeverAsksToSignIn() {
        let rejected = MCPAuthFailureProbe.failureDescription(
            authType: .bearerToken,
            probe: MCPAuthFailureProbeResult(
                statusCode: 401,
                challenge: MCPBearerChallenge(scope: "mcp.read"),
                serverMessage: "Missing authentication token.",
                sentAuthorization: true
            )
        )
        #expect(rejected.contains("rejected the saved API token"))
        #expect(rejected.contains("401"))
        #expect(rejected.contains("Missing authentication token."))
        #expect(!rejected.localizedCaseInsensitiveContains("sign in"))

        let missing = MCPAuthFailureProbe.failureDescription(
            authType: .bearerToken,
            probe: MCPAuthFailureProbeResult(
                statusCode: 401,
                challenge: nil,
                serverMessage: nil,
                sentAuthorization: false
            )
        )
        #expect(missing.contains("requires an API token"))
    }

    @Test func failureDescriptionForOAuthPrefersChallengeDetail() {
        let withDetail = MCPAuthFailureProbe.failureDescription(
            authType: .oauth,
            probe: MCPAuthFailureProbeResult(
                statusCode: 401,
                challenge: MCPBearerChallenge(error: "invalid_token", errorDescription: "Token expired"),
                serverMessage: nil,
                sentAuthorization: true
            )
        )
        #expect(withDetail == "Token expired")

        let bare = MCPAuthFailureProbe.failureDescription(
            authType: .oauth,
            probe: MCPAuthFailureProbeResult(
                statusCode: 401,
                challenge: nil,
                serverMessage: nil,
                sentAuthorization: false
            )
        )
        #expect(bare == "Server requires sign in")
    }

    @Test func handshakeBodyIsSpecCompleteInitialize() throws {
        let object = try JSONSerialization.jsonObject(with: MCPAuthFailureProbe.handshakeBody()) as? [String: Any]
        let params = object?["params"] as? [String: Any]
        #expect(object?["method"] as? String == "initialize")
        #expect(params?["protocolVersion"] as? String != nil)
        #expect(params?["clientInfo"] != nil)
        #expect(params?["capabilities"] != nil)
    }
}
