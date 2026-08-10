//
//  RemoteProviderMCPDetectionTests.swift
//  osaurusTests
//
//  Coverage for classifying an MCP server pasted into the API provider form
//  (issue: runalyze.com/mcp added as a custom API provider fails with a bare
//  "Not Found" from `<base>/models`).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Remote provider MCP detection")
struct RemoteProviderMCPDetectionTests {
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

    @Test func detectsJSONRPCErrorBody() {
        // Runalyze answers an unauthenticated initialize like this.
        let body = Data(
            #"{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Missing authentication token."}}"#
                .utf8
        )
        #expect(
            RemoteProviderMCPDetection.looksLikeMCPServer(
                response: response(status: 401),
                body: body
            )
        )
    }

    @Test func detectsJSONRPCSuccessBody() {
        let body = Data(
            #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{}}}"#
                .utf8
        )
        #expect(
            RemoteProviderMCPDetection.looksLikeMCPServer(
                response: response(status: 200),
                body: body
            )
        )
    }

    @Test func detectsSSEInitializeResponse() {
        let body = Data(
            "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n".utf8
        )
        #expect(
            RemoteProviderMCPDetection.looksLikeMCPServer(
                response: response(
                    status: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                body: body
            )
        )
    }

    @Test func detectsBearerChallengeWithResourceMetadata() {
        #expect(
            RemoteProviderMCPDetection.looksLikeMCPServer(
                response: response(
                    status: 401,
                    headers: [
                        "WWW-Authenticate":
                            #"Bearer resource_metadata="https://runalyze.com/.well-known/oauth-protected-resource", scope="mcp.read""#
                    ]
                ),
                body: nil
            )
        )
    }

    @Test func ignoresChatAPIStyleErrors() {
        // OpenAI-style error envelope — not JSON-RPC.
        let openAIError = Data(
            #"{"error":{"message":"Invalid URL (POST /v1)","type":"invalid_request_error"}}"#.utf8
        )
        #expect(
            !RemoteProviderMCPDetection.looksLikeMCPServer(
                response: response(status: 404),
                body: openAIError
            )
        )
        // HTML 404 page.
        let html = Data("<html><body>Not Found</body></html>".utf8)
        #expect(
            !RemoteProviderMCPDetection.looksLikeMCPServer(
                response: response(status: 404, headers: ["Content-Type": "text/html"]),
                body: html
            )
        )
        // Bare 401 without resource metadata is just auth, not evidence of MCP.
        #expect(
            !RemoteProviderMCPDetection.looksLikeMCPServer(
                response: response(status: 401, headers: ["WWW-Authenticate": "Bearer realm=\"api\""]),
                body: nil
            )
        )
        // Empty body, plain status.
        #expect(
            !RemoteProviderMCPDetection.looksLikeMCPServer(
                response: response(status: 404),
                body: Data()
            )
        )
    }

    @Test func sseDetectionRequiresEventStreamContentType() {
        let body = Data("data: {\"jsonrpc\":\"2.0\"}\n\n".utf8)
        #expect(
            !RemoteProviderMCPDetection.looksLikeMCPServer(
                response: response(status: 200, headers: ["Content-Type": "text/plain"]),
                body: body
            )
        )
    }

    @Test func guidanceMentionsConnections() {
        let message = RemoteProviderMCPDetection.guidance()
        #expect(message.contains("MCP server"))
        #expect(message.contains("Connections"))
    }
}
