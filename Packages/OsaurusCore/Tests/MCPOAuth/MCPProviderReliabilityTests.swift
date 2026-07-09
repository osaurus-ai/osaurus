//
//  MCPProviderReliabilityTests.swift
//  osaurusTests
//
//  Regression coverage for remote MCP HTTP transport construction and
//  stale-session recovery classification. Guards the fixes for:
//  - session-wide URLSession timeouts killing long tool calls and the
//    long-lived SSE GET stream,
//  - Authorization being routed through `httpAdditionalHeaders` (Apple
//    documents that as unsupported for auth headers),
//  - "Connected" providers whose every tool call fails after the remote
//    server expires the Mcp-Session-Id or the OAuth access token.
//

import Foundation
import MCP
import Testing

@testable import OsaurusCore

@Suite("Remote MCP provider reliability")
struct MCPProviderReliabilityTests {

    // MARK: - URLSession configuration

    @Test func sessionRequestTimeoutCoversBothLogicalTimeouts() {
        let configuration = MCPHTTPTransportBuilder.sessionConfiguration(
            discoveryTimeout: 20,
            toolCallTimeout: 45
        )
        // A tool call is allowed 45s at the MCP layer; the session-level
        // idle timeout must not undercut it (it used to be 20s).
        #expect(configuration.timeoutIntervalForRequest >= 45)
    }

    @Test func sessionRequestTimeoutHasFloorForTinyLogicalTimeouts() {
        let configuration = MCPHTTPTransportBuilder.sessionConfiguration(
            discoveryTimeout: 5,
            toolCallTimeout: 5
        )
        #expect(
            configuration.timeoutIntervalForRequest
                >= MCPHTTPTransportBuilder.minimumRequestTimeout
        )
    }

    @Test func sessionResourceTimeoutDoesNotKillLongLivedSSEStreams() {
        let configuration = MCPHTTPTransportBuilder.sessionConfiguration(
            discoveryTimeout: 20,
            toolCallTimeout: 45
        )
        // The old code capped the total lifetime of EVERY request in the
        // session at max(discovery, toolCall) = 45s, which force-closed the
        // streaming GET SSE connection every 45 seconds. The resource
        // timeout must stay at (or near) the URLSession default of 7 days.
        #expect(configuration.timeoutIntervalForResource >= 86_400)
    }

    // MARK: - Per-request headers

    @Test func requestModifierInjectsAuthorizationAndCustomHeaders() {
        let modifier = MCPHTTPTransportBuilder.requestModifier(headers: [
            "Authorization": "Bearer test-token",
            "X-Account-Id": "acct-42",
        ])
        let request = URLRequest(url: URL(string: "https://mcp.example.com/mcp")!)

        let modified = modifier(request)

        #expect(modified.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(modified.value(forHTTPHeaderField: "X-Account-Id") == "acct-42")
    }

    @Test func requestModifierNeverOverwritesHeadersSetByTheSDK() {
        // The SDK sets Accept / Content-Type / Mcp-Session-Id on each
        // request; a colliding custom header must not clobber them
        // (matching httpAdditionalHeaders semantics).
        let modifier = MCPHTTPTransportBuilder.requestModifier(headers: [
            "Accept": "text/plain"
        ])
        var request = URLRequest(url: URL(string: "https://mcp.example.com/mcp")!)
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")

        let modified = modifier(request)

        #expect(
            modified.value(forHTTPHeaderField: "Accept") == "application/json, text/event-stream"
        )
    }

    @Test func requestModifierWithNoHeadersIsIdentity() {
        let modifier = MCPHTTPTransportBuilder.requestModifier(headers: [:])
        var request = URLRequest(url: URL(string: "https://mcp.example.com/mcp")!)
        request.setValue("value", forHTTPHeaderField: "X-Existing")

        let modified = modifier(request)

        #expect(modified == request)
    }

    // MARK: - Stale-session recovery classification

    @Test func sessionExpiryAndAuthFailuresAreRecoverable() {
        // Exact strings produced by HTTPClientTransport in the MCP SDK.
        #expect(
            MCPProviderManager.isRecoverableSessionError(
                MCPError.internalError("Session expired")
            )
        )
        #expect(
            MCPProviderManager.isRecoverableSessionError(
                MCPError.internalError("Authentication required")
            )
        )
        #expect(
            MCPProviderManager.isRecoverableSessionError(
                MCPError.internalError("Access forbidden")
            )
        )
        #expect(
            MCPProviderManager.isRecoverableSessionError(
                MCPError.internalError("Transport not connected")
            )
        )
        #expect(
            MCPProviderManager.isRecoverableSessionError(MCPError.connectionClosed)
        )
    }

    @Test func timeoutsAndToolFailuresAreNotRetried() {
        // A timed-out tool call may have executed server-side; retrying
        // risks double execution.
        #expect(!MCPProviderManager.isRecoverableSessionError(MCPProviderError.timeout))
        #expect(
            !MCPProviderManager.isRecoverableSessionError(
                MCPProviderError.toolExecutionFailed("boom")
            )
        )
        #expect(
            !MCPProviderManager.isRecoverableSessionError(
                MCPError.internalError("Server error: 500")
            )
        )
        #expect(
            !MCPProviderManager.isRecoverableSessionError(
                MCPError.internalError(nil)
            )
        )
        #expect(
            !MCPProviderManager.isRecoverableSessionError(
                NSError(domain: "test", code: 1)
            )
        )
    }
}
