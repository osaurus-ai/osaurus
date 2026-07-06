//
//  MCPFeatureGapRemediationTests.swift
//  OsaurusCoreTests
//
//  Regression coverage for MCP feature-gap audit remediations.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("MCP feature gap remediation", .serialized)
struct MCPFeatureGapRemediationTests {
    @Test func permanentAuthFailureDetectsInvalidGrant() {
        let error = MCPOAuthError.tokenRequestFailed(400, #"{"error":"invalid_grant"}"#)
        #expect(MCPOAuthService.isPermanentAuthFailure(error))
    }

    @Test func permanentAuthFailureIgnoresTransientErrors() {
        let error = MCPOAuthError.tokenRequestFailed(503, "service unavailable")
        #expect(!MCPOAuthService.isPermanentAuthFailure(error))
    }

    @Test func oauthRefreshSingleFlightCoalescesConcurrentCalls() async throws {
        let providerId = UUID()
        var refreshCount = 0
        MCPOAuthService.tokenRequestOverride = { _, _ in
            refreshCount += 1
            try await Task.sleep(nanoseconds: 100_000_000)
            return MCPOAuthService.ParsedTokenResponse(
                accessToken: "AT-\(refreshCount)",
                refreshToken: "RT",
                expiresAt: Date().addingTimeInterval(3600),
                scope: nil
            )
        }
        defer { MCPOAuthService.tokenRequestOverride = nil }

        let provider = MCPProvider(
            id: providerId,
            name: "p",
            url: "https://mcp.example.com/mcp",
            authType: .oauth,
            oauth: MCPOAuthConfig(
                clientId: "client",
                tokenEndpoint: "https://auth.example.com/token"
            )
        )
        let tokens = MCPOAuthTokens(
            accessToken: "old",
            refreshToken: "RT",
            expiresAt: Date().addingTimeInterval(-10),
            scope: nil
        )

        async let first = MCPOAuthService.refresh(provider: provider, tokens: tokens, persist: false)
        async let second = MCPOAuthService.refresh(provider: provider, tokens: tokens, persist: false)
        let (a, b) = try await (first, second)

        #expect(refreshCount == 1)
        #expect(a.accessToken == b.accessToken)
    }

    @Test @MainActor func externalMCPDeniesAskPolicyTool() async {
        let tool = AskGapTool()
        ToolRegistry.shared.register(tool)
        ToolRegistry.shared.setEnabled(true, for: tool.name)
        defer { ToolRegistry.shared.unregister(names: [tool.name]) }

        await #expect(throws: (any Error).self) {
            _ = try await MCPServerManager.executeToolAsExternalMCP(
                name: tool.name,
                argumentsJSON: "{}"
            )
        }
    }

    @Test @MainActor func externalMCPRejectsDisabledToolBeforeExecution() async {
        let tool = EchoGapTool()
        ToolRegistry.shared.register(tool)
        ToolRegistry.shared.setEnabled(false, for: tool.name)
        defer { ToolRegistry.shared.unregister(names: [tool.name]) }

        await #expect(throws: (any Error).self) {
            _ = try await MCPServerManager.executeToolAsExternalMCP(
                name: tool.name,
                argumentsJSON: #"{"text":"hi"}"#
            )
        }
    }

    @Test func stderrCaptureKeepsTail() {
        let capture = MCPStdioStderrCapture(lineLimit: 4)
        capture.append(Data("line one\nline two\n".utf8))
        capture.append(Data("line three\n".utf8))
        let tail = capture.tail(maxLength: 100)
        #expect(tail.contains("line one"))
        #expect(tail.contains("line three"))
    }
}

private struct EchoGapTool: OsaurusTool {
    static let nameStatic = "echo_gap_tool"
    let name = EchoGapTool.nameStatic
    let description = "Echo for gap tests"
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object(["text": .object(["type": .string("string")])]),
        "required": .array([.string("text")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        argumentsJSON
    }
}

private final class AskGapTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    let name = "ask_gap_tool"
    let description = "Ask-policy probe"
    let parameters: JSONValue? = nil
    let requirements: [String] = []
    let defaultPermissionPolicy: ToolPermissionPolicy = .ask

    func execute(argumentsJSON: String) async throws -> String {
        "ran"
    }
}
