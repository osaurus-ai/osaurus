//
//  ProviderNetworkDiagnosticsTests.swift
//  osaurusTests
//
//  Regression coverage for copyable provider/auth/network diagnostics.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Provider network diagnostics")
struct ProviderNetworkDiagnosticsTests {
    @Test func codexOAuthReportFlagsMissingTokensWithoutLeakingSecrets() {
        let provider = OpenAICodexOAuthService.makeProvider(id: UUID())
        var state = RemoteProviderState(providerId: provider.id)
        state.lastError = #"HTTP 401: {"access_token":"secret-token"}"#

        let report = ProviderNetworkDiagnostics.remoteProviderReport(
            provider: provider,
            state: state,
            proxy: .disabled,
            apiKeyPresent: false,
            oauthTokensPresent: false
        )

        let auth = row("auth", in: report)
        #expect(auth.severity == .blocked)
        #expect(auth.value == L("ChatGPT sign-in required"))
        #expect(report.pasteboardText.contains(L("ChatGPT sign-in required")))

        let oauth = row("oauth-context", in: report)
        #expect(oauth.severity == .warning)
        #expect(oauth.value == L("Codex subscription"))
        #expect(oauth.detail?.contains("providerType=openAICodex") == true)
        #expect(oauth.detail?.contains("authType=openAICodexOAuth") == true)
        #expect(oauth.detail?.contains("redirectURI=http://localhost:1455/auth/callback") == true)
        #expect(oauth.detail?.contains("callbackPort=1455") == true)
        #expect(oauth.detail?.contains("tokens=missing") == true)
        #expect(!report.pasteboardText.contains("secret-token"))
    }

    @Test func codexOAuthReportShowsSignedInContextWithoutSecrets() {
        let provider = OpenAICodexOAuthService.makeProvider(id: UUID())
        var state = RemoteProviderState(providerId: provider.id)
        state.lastError = #"previous callback code=secret-code"#

        let report = ProviderNetworkDiagnostics.remoteProviderReport(
            provider: provider,
            state: state,
            proxy: .disabled,
            apiKeyPresent: false,
            oauthTokensPresent: true
        )

        let oauth = row("oauth-context", in: report)
        #expect(oauth.severity == .info)
        #expect(oauth.detail?.contains("tokens=present") == true)
        #expect(oauth.detail?.contains("lastError=previous callback code=***") == true)
        #expect(!report.pasteboardText.contains("secret-code"))
    }

    @Test func codexModelDiscoveryDetailDocumentsFallbackBeforeFirstLiveFetch() {
        let detail = ProviderNetworkDiagnostics.codexModelDiscoveryDetail(summary: nil)

        #expect(detail.contains("static Codex fallback"))
    }

    @Test func codexModelDiscoveryDetailAttributesFilteredSlugs() {
        let summary = OpenAICodexOAuthService.ModelDiscoverySummary(
            rawEntryCount: 15,
            compatibleCount: 2,
            filteredModels: [
                .init(slug: "gpt-5-4-thinking", reason: .shellToolDisabled),
                .init(slug: "gpt-4o", reason: .nonCodexSlug),
                .init(slug: "gpt-5.5-internal", reason: .hiddenVisibility),
            ],
            fetchedAt: Date()
        )

        let detail = ProviderNetworkDiagnostics.codexModelDiscoveryDetail(summary: summary)

        #expect(detail.contains("15"))
        #expect(detail.contains("2"))
        #expect(detail.contains("gpt-5-4-thinking (\(L("shell tool disabled")))"))
        #expect(detail.contains("gpt-4o (\(L("chat-only slug")))"))
        #expect(detail.contains("gpt-5.5-internal (\(L("hidden from picker")))"))
    }

    @Test func codexModelDiscoveryDetailCapsLongFilteredLists() {
        let filtered = (1 ... 15).map {
            OpenAICodexOAuthService.ModelDiscoverySummary.FilteredModel(
                slug: "gpt-chat-\($0)",
                reason: .nonCodexSlug
            )
        }
        let summary = OpenAICodexOAuthService.ModelDiscoverySummary(
            rawEntryCount: 17,
            compatibleCount: 2,
            filteredModels: filtered,
            fetchedAt: Date()
        )

        let detail = ProviderNetworkDiagnostics.codexModelDiscoveryDetail(summary: summary)

        #expect(detail.contains("gpt-chat-12"))
        #expect(!detail.contains("gpt-chat-13"))
        #expect(detail.contains("+3"))
    }

    @Test func xaiOAuthReportFlagsMissingTokensWithoutLeakingSecrets() {
        let provider = XAIOAuthService.makeProvider(id: UUID())
        var state = RemoteProviderState(providerId: provider.id)
        state.lastError = #"HTTP 401: {"access_token":"secret-token"}"#

        let report = ProviderNetworkDiagnostics.remoteProviderReport(
            provider: provider,
            state: state,
            proxy: .disabled,
            apiKeyPresent: false,
            oauthTokensPresent: false
        )

        let auth = row("auth", in: report)
        #expect(auth.severity == .blocked)
        #expect(auth.value == L("xAI sign-in required"))
        #expect(report.pasteboardText.contains(L("xAI sign-in required")))
        #expect(!report.pasteboardText.contains("secret-token"))
    }

    @Test func openAICompatibleReportExplainsManualModelFallbackAndRequestValidation() {
        let provider = RemoteProvider(
            name: "Lemonade",
            host: "127.0.0.1",
            providerProtocol: .http,
            port: 8000,
            basePath: "/api/v1",
            authType: .none,
            providerType: .openaiLegacy,
            manualModelIds: ["local-chat"]
        )

        let report = ProviderNetworkDiagnostics.remoteProviderReport(
            provider: provider,
            state: nil,
            proxy: .disabled,
            apiKeyPresent: false,
            oauthTokensPresent: false
        )

        #expect(row("models", in: report).value == L("Fallback available"))
        // "/models" appears in the detail text across all localizations.
        #expect(row("models", in: report).detail?.contains("/models") == true)
        #expect(row("format", in: report).detail?.contains("response_format=json_schema") == true)
    }

    @Test func proxyDiagnosticDistinguishesInvalidConfiguredProxy() {
        var configuration = ServerConfiguration.default
        configuration.globalProxyURL = "http://localhost:8080"

        let diagnostic = GlobalProxySettings.diagnostic(from: configuration)

        #expect(diagnostic == .invalid("Proxy host 'localhost' is reserved for local networking."))

        let provider = RemoteProvider(
            name: "Remote",
            host: "api.example.com",
            authType: .none
        )
        let report = ProviderNetworkDiagnostics.remoteProviderReport(
            provider: provider,
            state: nil,
            proxy: diagnostic,
            apiKeyPresent: false,
            oauthTokensPresent: false
        )

        #expect(row("proxy", in: report).value == L("Ignored"))
        #expect(row("proxy", in: report).severity == .warning)
    }

    @Test func mcpStdioReportShowsExecutionHostAndProbeGuidance() {
        let provider = MCPProvider(
            name: "Local MCP",
            url: "",
            authType: .none,
            transport: .stdio,
            executionHost: .host,
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-filesystem"]
        )

        let report = ProviderNetworkDiagnostics.mcpProviderReport(
            provider: provider,
            state: nil,
            proxy: .active("socks://proxy.example.com:1080"),
            bearerTokenPresent: false,
            oauthTokensPresent: false
        )

        #expect(row("transport", in: report).value == "Stdio host")
        #expect(row("transport", in: report).severity == .warning)
        #expect(row("proxy", in: report).value == L("Not used for stdio"))
        #expect(row("repro", in: report).detail?.contains("listTools") == true)
    }

    @Test func mcpHTTPReportShowsProxyAppliesToDiscovery() {
        let provider = MCPProvider(
            name: "Linear",
            url: "https://mcp.linear.app/mcp",
            streamingEnabled: true,
            authType: .oauth,
            transport: .http
        )

        let report = ProviderNetworkDiagnostics.mcpProviderReport(
            provider: provider,
            state: nil,
            proxy: .active("https://proxy.example.com:8443"),
            bearerTokenPresent: false,
            oauthTokensPresent: true
        )

        #expect(row("transport", in: report).value == "HTTP/SSE")
        #expect(row("proxy", in: report).value == "https://proxy.example.com:8443")
        #expect(row("proxy", in: report).detail?.contains("MCP HTTP/SSE") == true)
        #expect(row("auth", in: report).severity == .ok)
    }

    private func row(_ id: String, in report: ProviderDiagnosticReport) -> ProviderDiagnosticRow {
        guard let found = report.rows.first(where: { $0.id == id }) else {
            Issue.record("Missing diagnostics row \(id)")
            return ProviderDiagnosticRow(id: id, title: "missing", value: "missing", severity: .blocked)
        }
        return found
    }
}
