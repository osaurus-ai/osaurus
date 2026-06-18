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
