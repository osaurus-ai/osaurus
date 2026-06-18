//
//  MCPServerHubTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("MCP Server Hub")
struct MCPServerHubTests {
    @Test func snapshotClassifiesProvidersAndBuildsSanitizedReport() {
        let connected = MCPProvider(
            id: UUID(),
            name: "Linear",
            url: "https://mcp.linear.app/mcp",
            authType: .oauth,
            transport: .http
        )
        let failed = MCPProvider(
            id: UUID(),
            name: "Filesystem",
            url: "",
            authType: .none,
            transport: .stdio,
            executionHost: .host,
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-filesystem"]
        )
        var disabled = MCPProvider(
            id: UUID(),
            name: "Zapier",
            url: "https://mcp.zapier.com/api/mcp/mcp",
            authType: .bearerToken,
            transport: .http
        )
        disabled.enabled = false

        var connectedState = MCPProviderState(providerId: connected.id)
        connectedState.isConnected = true
        connectedState.discoveredToolCount = 2
        connectedState.discoveredToolNames = ["linear_search", "linear_issue"]

        var failedState = MCPProviderState(providerId: failed.id)
        failedState.lastError = #"process failed with {"access_token":"secret-token"}"#

        let failedProbe = MCPProviderProbeResult.failure(
            provider: failed,
            startedAt: Date(timeIntervalSince1970: 10),
            stage: .spawn,
            reasonCode: .commandNotFound,
            message: #"spawn failed with client_secret=secret-code"#,
            action: "Use a full executable path."
        )
        let failedSnapshot = MCPProviderHealthSnapshot(
            providerId: failed.id,
            providerName: failed.name,
            transportSummary: "stdio host npx -y @modelcontextprotocol/server-filesystem",
            lastProbe: failedProbe,
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        let snapshot = MCPServerHub.snapshot(
            providers: [connected, failed, disabled],
            states: [
                connected.id: connectedState,
                failed.id: failedState,
            ],
            proxy: .active("https://proxy.example.com:8443"),
            credentialsByProvider: [
                connected.id: MCPProviderCredentialPresence(oauthTokensPresent: true),
                disabled.id: MCPProviderCredentialPresence(bearerTokenPresent: false),
            ],
            healthSnapshots: [
                failed.id: failedSnapshot
            ]
        )

        #expect(snapshot.totalCount == 3)
        #expect(snapshot.connectedCount == 1)
        #expect(snapshot.attentionCount == 1)
        #expect(snapshot.disabledCount == 1)
        #expect(snapshot.httpCount == 2)
        #expect(snapshot.stdioCount == 1)
        #expect(snapshot.hostStdioCount == 1)
        #expect(snapshot.toolCount == 2)
        #expect(snapshot.filtered(by: .connected).map(\.provider.name) == ["Linear"])
        #expect(snapshot.filtered(by: .stdio).map(\.provider.name) == ["Filesystem"])
        #expect(snapshot.filtered(by: .disabled).map(\.provider.name) == ["Zapier"])
        #expect(snapshot.filtered(by: .attention).map(\.provider.name) == ["Filesystem"])
        #expect(snapshot.pasteboardText.contains("MCP Server Hub diagnostics"))
        #expect(snapshot.pasteboardText.contains("https://proxy.example.com:8443"))
        #expect(snapshot.pasteboardText.contains("commandNotFound"))
        #expect(!snapshot.pasteboardText.contains("secret-token"))
        #expect(!snapshot.pasteboardText.contains("secret-code"))
    }

    @Test func failedProbeMakesEnabledProviderNeedAttention() {
        let provider = MCPProvider(
            id: UUID(),
            name: "Local Search",
            url: "",
            authType: .none,
            transport: .stdio,
            executionHost: .sandbox,
            command: "uvx",
            args: ["local-search-mcp"]
        )
        let probe = MCPProviderProbeResult.failure(
            provider: provider,
            startedAt: Date(),
            stage: .connect,
            reasonCode: .protocolError,
            message: "not MCP JSON-RPC",
            action: "Verify the process speaks MCP JSON-RPC on stdin/stdout."
        )
        let health = MCPProviderHealthSnapshot(
            providerId: provider.id,
            providerName: provider.name,
            transportSummary: "stdio sandbox uvx local-search-mcp",
            lastProbe: probe
        )

        let report = MCPServerHub.providerReport(
            provider: provider,
            state: nil,
            proxy: .disabled,
            credentialPresence: MCPProviderCredentialPresence(),
            healthSnapshot: health
        )

        #expect(report.status == .needsAttention)
        #expect(report.hasAttention)
        #expect(report.summary.contains("Last probe"))
        #expect(report.recommendedAction?.contains("JSON-RPC") == true)
    }

    @Test func disabledProviderDoesNotDriveHubAttentionSeverity() {
        var provider = MCPProvider(
            id: UUID(),
            name: "Disabled Token Provider",
            url: "https://mcp.example.com/mcp",
            authType: .bearerToken,
            transport: .http
        )
        provider.enabled = false

        let snapshot = MCPServerHub.snapshot(
            providers: [provider],
            states: [:],
            proxy: .disabled,
            credentialsByProvider: [:],
            healthSnapshots: [:]
        )

        #expect(snapshot.attentionCount == 0)
        #expect(snapshot.highestSeverity == .info)
        #expect(snapshot.filtered(by: .attention).isEmpty)
    }
}
