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

    @Test func guidedFailureClassificationUsesStableBuckets() throws {
        let provider = RemoteProvider(
            name: "OpenAI Compatible",
            host: "api.example.test",
            authType: .none,
            providerType: .openaiLegacy
        )
        let keyedProvider = RemoteProvider(
            name: "Keyed",
            host: "api.example.test",
            authType: .apiKey,
            providerType: .openaiLegacy
        )
        let oauthProvider = XAIOAuthService.makeProvider(id: UUID())
        let url = try #require(URL(string: "https://api.example.test/v1/models"))

        let fixtures: [(String, RemoteProvider, RemoteProviderState?, GlobalProxyDiagnosticState, Bool, Bool, ProviderFailureBucket)] = [
            (
                "missing-key",
                keyedProvider,
                errorState(keyedProvider, message: "API key missing"),
                .disabled,
                false,
                false,
                .missingCredential
            ),
            (
                "oauth-missing",
                oauthProvider,
                errorState(oauthProvider, message: "OAuth token missing"),
                .disabled,
                false,
                false,
                .oauthTokenMissing
            ),
            (
                "dns",
                provider,
                replayState(provider, url: url, transportError: URLError(.cannotFindHost)),
                .disabled,
                false,
                false,
                .endpointUnreachable
            ),
            (
                "timeout",
                provider,
                replayState(provider, url: url, transportError: URLError(.timedOut)),
                .disabled,
                false,
                false,
                .timeout
            ),
            (
                "origin-timeout-with-invalid-proxy",
                provider,
                replayState(provider, url: url, transportError: URLError(.timedOut)),
                .invalid("bad proxy"),
                false,
                false,
                .timeout
            ),
            (
                "tls",
                provider,
                replayState(provider, url: url, transportError: URLError(.secureConnectionFailed)),
                .disabled,
                false,
                false,
                .tlsFailure
            ),
            (
                "proxy-connect",
                provider,
                replayState(
                    provider,
                    url: url,
                    transportError: NSError(
                        domain: "ProxyError",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Proxy CONNECT tunnel failed"]
                    )
                ),
                .active("https://proxy.example.com:8443"),
                false,
                false,
                .proxyConnectFailed
            ),
            (
                "origin-timeout-with-active-proxy",
                provider,
                replayState(provider, url: url, transportError: URLError(.timedOut)),
                .active("https://proxy.example.com:8443"),
                false,
                false,
                .timeout
            ),
            (
                "provider-tunnel-word-with-active-proxy",
                provider,
                replayState(
                    provider,
                    url: url,
                    transportError: NSError(
                        domain: "ProviderError",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Cloudflare Tunnel timed out"]
                    )
                ),
                .active("https://proxy.example.com:8443"),
                false,
                false,
                .timeout
            ),
            (
                "auth-rejected",
                provider,
                replayState(provider, url: url, statusCode: 401, body: #"{"error":"unauthorized"}"#),
                .disabled,
                false,
                false,
                .authRejected
            ),
            (
                "models-missing",
                provider,
                replayState(provider, url: url, statusCode: 404, body: #"{"error":"not found"}"#),
                .disabled,
                false,
                false,
                .modelsEndpointUnavailable
            ),
            (
                "models-does-not-exist",
                provider,
                replayState(provider, url: url, statusCode: 404, body: #"{"error":"resource does not exist"}"#),
                .disabled,
                false,
                false,
                .modelsEndpointUnavailable
            ),
            (
                "models-schema",
                provider,
                replayState(provider, url: url, statusCode: 200, body: #"{"schema":"expected data array"}"#),
                .disabled,
                false,
                false,
                .modelsSchemaMismatch
            ),
            (
                "request-shape",
                provider,
                replayState(provider, url: url, statusCode: 400, body: #"{"error":"unknown parameter tool_choice"}"#),
                .disabled,
                false,
                false,
                .requestRejected
            ),
            (
                "auth-rejected-on-400",
                provider,
                replayState(provider, url: url, statusCode: 400, body: #"{"error":"invalid_api_key"}"#),
                .disabled,
                false,
                false,
                .authRejected
            ),
            (
                "unsupported-model",
                provider,
                replayState(provider, url: url, statusCode: 400, body: #"{"error":"model_not_found"}"#),
                .disabled,
                false,
                false,
                .unsupportedModel
            ),
            (
                "unexpected-upstream-response",
                provider,
                replayState(provider, url: url, statusCode: 429, body: #"{"error":"unexpected upstream condition"}"#),
                .disabled,
                false,
                false,
                .badResponse
            ),
            (
                "unknown",
                provider,
                errorState(provider, message: "Provider returned an unexpected upstream condition."),
                .disabled,
                false,
                false,
                .unknown
            ),
        ]

        for (name, provider, state, proxy, apiKeyPresent, oauthTokensPresent, bucket) in fixtures {
            let classification = try #require(
                ProviderFailureClassifier.classify(
                    provider: provider,
                    state: state,
                    proxy: proxy,
                    apiKeyPresent: apiKeyPresent,
                    oauthTokensPresent: oauthTokensPresent
                ),
                "Missing classification for \(name)"
            )
            #expect(classification.bucket == bucket, "Wrong bucket for \(name)")
            #expect(!classification.action.isEmpty, "Missing action for \(name)")
        }

        let invalidProxyOnly = ProviderFailureClassifier.classify(
            provider: provider,
            state: nil,
            proxy: .invalid("bad proxy"),
            apiKeyPresent: false,
            oauthTokensPresent: false
        )
        #expect(invalidProxyOnly == nil)

        let missingKeyWithoutFailure = ProviderFailureClassifier.classify(
            provider: keyedProvider,
            state: nil,
            proxy: .disabled,
            apiKeyPresent: false,
            oauthTokensPresent: false
        )
        #expect(missingKeyWithoutFailure == nil)
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

    private func errorState(_ provider: RemoteProvider, message: String) -> RemoteProviderState {
        var state = RemoteProviderState(providerId: provider.id)
        state.lastError = message
        return state
    }

    private func replayState(
        _ provider: RemoteProvider,
        url: URL,
        statusCode: Int? = nil,
        body: String? = nil,
        transportError: Error? = nil
    ) -> RemoteProviderState {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let response = statusCode.map {
            HTTPURLResponse(
                url: url,
                statusCode: $0,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        }
        var state = RemoteProviderState(providerId: provider.id)
        state.lastError = transportError?.localizedDescription ?? "HTTP \(statusCode ?? 500)"
        state.lastReplayDiagnostics = ProviderReplayDiagnosticBundle(
            phase: "test_model_discovery",
            request: request,
            response: response,
            responseData: body.map { Data($0.utf8) },
            transportError: transportError
        )
        return state
    }
}
