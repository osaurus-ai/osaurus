//
//  ProviderSetupRecoveryTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct ProviderSetupRecoveryTests {
    @Test func replayFailureUsesExistingAuthClassification() throws {
        let url = try #require(URL(string: "https://private.internal.example/tenant/models?token=sk-supersecret123"))
        let request = URLRequest(url: url)
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Authorization": "Bearer sk-supersecret123"]
            )
        )
        let replay = ProviderReplayDiagnosticBundle(
            phase: "models",
            request: request,
            response: response,
            responseData: Data("{\"error\":\"invalid_api_key sk-supersecret123\"}".utf8)
        )
        let error = RemoteProviderServiceError.requestFailedWithDiagnostics(
            "request rejected sk-supersecret123",
            replay
        )

        let failure = ProviderFailureClassifier.classifySetupFailure(
            provider: Self.provider(),
            error: error,
            proxy: .disabled,
            apiKeyPresent: true,
            oauthTokensPresent: false
        )

        #expect(failure.classification.bucket == .authRejected)
        #expect(failure.userMessage.contains(failure.classification.action))
        #expect(!failure.pasteboardText.contains("sk-supersecret123"))
        #expect(!failure.pasteboardText.contains("private.internal.example"))
        #expect(!failure.pasteboardText.contains("/tenant/models"))
        #expect(failure.pasteboardText.contains("detail="))
        #expect(failure.pasteboardText.contains("method=GET"))
        #expect(failure.pasteboardText.contains("status=401"))
        #expect(failure.pasteboardText.contains("endpoint=[redacted-endpoint]"))
        #expect(failure.pasteboardText.contains("api-key-present=true"))
    }

    @Test func oauthFailuresPreserveCuratedSignInRecovery() {
        let failure = ProviderFailureClassifier.classifySetupFailure(
            provider: Self.provider(authType: .openAICodexOAuth),
            error: NSError(
                domain: "OAuthLoopback",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "The browser callback timed out"]
            ),
            proxy: .disabled,
            apiKeyPresent: false,
            oauthTokensPresent: false,
            diagnosticMessage: "ChatGPT/Codex sign-in callback timed out"
        )

        #expect(failure.classification.bucket == .oauthTokenMissing)
        #expect(failure.classification.detail.contains("ChatGPT/Codex sign-in"))
        #expect(failure.recoveryDetail == "ChatGPT/Codex sign-in callback timed out")
        #expect(failure.detailForDisplay == failure.recoveryDetail)
        #expect(failure.userMessage.contains("callback timed out"))
        #expect(failure.userMessage.contains("Sign in again"))
        #expect(failure.pasteboardText.contains("detail=ChatGPT/Codex sign-in callback timed out"))
    }

    @Test func recoveryDetailRedactsCredentialHeaderAndLocalPathCanaries() throws {
        let secret = "sk-private-recovery-123456789"
        let localPath = "/Users/mmeding/Secrets/provider.json"
        let bearer = "private-bearer-token-123456789"
        let failure = ProviderFailureClassifier.classifySetupFailure(
            provider: Self.provider(authType: .openAICodexOAuth),
            error: NSError(
                domain: "ProviderSetupRecoveryTests",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "OAuth failed"]
            ),
            proxy: .disabled,
            apiKeyPresent: false,
            oauthTokensPresent: false,
            diagnosticMessage: "OAuth failed for \(secret) at \(localPath); Authorization: Bearer \(bearer)"
        )

        let recoveryDetail = try #require(failure.recoveryDetail)
        for projection in [recoveryDetail, failure.detailForDisplay, failure.userMessage, failure.pasteboardText] {
            #expect(!projection.contains(secret))
            #expect(!projection.contains(localPath))
            #expect(!projection.contains(bearer))
        }
        #expect(recoveryDetail.contains("sk-***"))
        #expect(recoveryDetail.contains("/[redacted-local-path]"))
        #expect(recoveryDetail.contains("Authorization=***"))
    }

    @Test func oauthFailureWithStoredTokensDoesNotClaimTokensAreMissing() {
        let failure = ProviderFailureClassifier.classifySetupFailure(
            provider: Self.provider(authType: .openAICodexOAuth),
            error: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorTimedOut,
                userInfo: [NSLocalizedDescriptionKey: "The request timed out"]
            ),
            proxy: .disabled,
            apiKeyPresent: false,
            oauthTokensPresent: true,
            diagnosticMessage: "ChatGPT/Codex sign-in failed: The request timed out"
        )

        #expect(failure.classification.bucket == .timeout)
        #expect(failure.classification.bucket != .oauthTokenMissing)
    }

    @Test func oauthTokenFailuresBeatGenericAuthenticationRejection() {
        let messages = [
            "Access token expired",
            "HTTP 401: invalid OAuth token",
        ]

        for message in messages {
            let failure = ProviderFailureClassifier.classifySetupFailure(
                provider: Self.provider(authType: .openAICodexOAuth),
                error: NSError(
                    domain: "ProviderSetupRecoveryTests",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: message]
                ),
                proxy: .disabled,
                apiKeyPresent: false,
                oauthTokensPresent: true
            )

            #expect(failure.classification.bucket == .oauthTokenMissing)
            #expect(failure.detailForDisplay == failure.classification.detail)
        }
    }

    @Test func apiKeyTokenFailureRemainsAuthenticationRejection() {
        let failure = ProviderFailureClassifier.classifySetupFailure(
            provider: Self.provider(),
            error: NSError(
                domain: "ProviderSetupRecoveryTests",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "HTTP 401: invalid token"]
            ),
            proxy: .disabled,
            apiKeyPresent: true,
            oauthTokensPresent: false
        )

        #expect(failure.classification.bucket == .authRejected)
    }

    @Test func oauthReplayTokenExpiryBeatsHTTP401() throws {
        let url = try #require(URL(string: "https://api.example.test/v1/models"))
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )
        )
        let replay = ProviderReplayDiagnosticBundle(
            phase: "model_discovery",
            request: URLRequest(url: url),
            response: response,
            responseData: Data(#"{"error":"access token expired"}"#.utf8)
        )
        let failure = ProviderFailureClassifier.classifySetupFailure(
            provider: Self.provider(authType: .xaiOAuth),
            error: RemoteProviderServiceError.requestFailedWithDiagnostics("HTTP 401", replay),
            proxy: .disabled,
            apiKeyPresent: false,
            oauthTokensPresent: true
        )

        #expect(failure.classification.bucket == .oauthTokenMissing)
    }

    @Test func stringFailuresMapToTypedRecoveryBuckets() {
        let cases: [(String, ProviderFailureBucket)] = [
            ("The request timed out", .timeout),
            ("TLS certificate validation failed", .tlsFailure),
            ("Could not find host", .endpointUnreachable),
            ("No models available from provider", .modelsSchemaMismatch),
            ("HTTP 404", .badResponse),
            ("HTTP 405", .badResponse),
            ("HTTP 501", .badResponse),
            ("HTTP 404 from /models", .modelsEndpointUnavailable),
            ("HTTP 405 from the models endpoint", .modelsEndpointUnavailable),
            ("HTTP 501 during model discovery", .modelsEndpointUnavailable),
            ("invalid request: unsupported field", .requestRejected),
            ("unexpected provider failure", .unknown),
        ]

        for (message, expected) in cases {
            let failure = ProviderFailureClassifier.classifySetupFailure(
                provider: Self.provider(),
                error: NSError(
                    domain: "ProviderSetupRecoveryTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message]
                ),
                proxy: .disabled,
                apiKeyPresent: true,
                oauthTokensPresent: false
            )
            #expect(failure.classification.bucket == expected)
        }
    }

    @Test func modelDiscoveryReplayStillClassifiesMissingEndpoint() throws {
        let url = try #require(URL(string: "https://api.example.test/v1/models"))
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )
        )
        let replay = ProviderReplayDiagnosticBundle(
            phase: "model_discovery",
            request: URLRequest(url: url),
            response: response
        )
        let failure = ProviderFailureClassifier.classifySetupFailure(
            provider: Self.provider(),
            error: RemoteProviderServiceError.requestFailedWithDiagnostics("HTTP 404", replay),
            proxy: .disabled,
            apiKeyPresent: true,
            oauthTokensPresent: false
        )

        #expect(failure.classification.bucket == .modelsEndpointUnavailable)
    }

    @Test func nativeProviderModelDiscoveryFailuresDoNotSuggestOpenAIManualModelWorkaround() {
        let providerTypes: [RemoteProviderType] = [.anthropic, .gemini, .openAICodex]
        let statuses = [404, 405, 501]

        for providerType in providerTypes {
            for status in statuses {
                let failure = ProviderFailureClassifier.classifySetupFailure(
                    provider: Self.provider(providerType: providerType),
                    error: NSError(
                        domain: "ProviderSetupRecoveryTests",
                        code: status,
                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(status) from /models"]
                    ),
                    proxy: .disabled,
                    apiKeyPresent: true,
                    oauthTokensPresent: false
                )

                #expect(failure.classification.bucket == .modelsEndpointUnavailable)
                #expect(!failure.classification.action.localizedCaseInsensitiveContains("manual model"))
                #expect(!failure.classification.action.localizedCaseInsensitiveContains("openai-compatible"))
            }
        }
    }

    @Test func manualModelGuidanceRequiresCompatibleProviderAndExposedFlow() {
        let error = NSError(
            domain: "ProviderSetupRecoveryTests",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "HTTP 404 from /models"]
        )
        let openAIWithEditor = ProviderFailureClassifier.classifySetupFailure(
            provider: Self.provider(providerType: .openaiLegacy),
            error: error,
            proxy: .disabled,
            apiKeyPresent: true,
            oauthTokensPresent: false,
            manualModelRecovery: .openAICompatibleModelIDs
        )
        let openAIWithoutEditor = ProviderFailureClassifier.classifySetupFailure(
            provider: Self.provider(providerType: .openaiLegacy),
            error: error,
            proxy: .disabled,
            apiKeyPresent: true,
            oauthTokensPresent: false,
            manualModelRecovery: .unavailable
        )
        let anthropicWithWrongCapability = ProviderFailureClassifier.classifySetupFailure(
            provider: Self.provider(providerType: .anthropic),
            error: error,
            proxy: .disabled,
            apiKeyPresent: true,
            oauthTokensPresent: false,
            manualModelRecovery: .openAICompatibleModelIDs
        )
        let azureWithDeployments = ProviderFailureClassifier.classifySetupFailure(
            provider: Self.provider(providerType: .azureOpenAI),
            error: error,
            proxy: .disabled,
            apiKeyPresent: true,
            oauthTokensPresent: false,
            manualModelRecovery: .azureDeploymentIDs
        )

        #expect(openAIWithEditor.classification.action.localizedCaseInsensitiveContains("manual model"))
        #expect(!openAIWithoutEditor.classification.action.localizedCaseInsensitiveContains("manual model"))
        #expect(!anthropicWithWrongCapability.classification.action.localizedCaseInsensitiveContains("manual model"))
        #expect(azureWithDeployments.classification.action.localizedCaseInsensitiveContains("deployment/model"))
        #expect(!azureWithDeployments.classification.action.localizedCaseInsensitiveContains("openai-compatible"))
    }

    @Test func onboardingContextNeverOffersManualModelRecovery() {
        let providerTypes: [RemoteProviderType] = [.openaiLegacy, .openResponses, .anthropic, .gemini, .openAICodex]

        for providerType in providerTypes {
            let failure = ProviderFailureClassifier.classifySetupFailure(
                provider: Self.provider(providerType: providerType),
                error: NSError(
                    domain: "ProviderSetupRecoveryTests",
                    code: 501,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP 501 during model discovery"]
                ),
                proxy: .disabled,
                apiKeyPresent: true,
                oauthTokensPresent: false,
                manualModelRecovery: .unavailable
            )

            #expect(failure.classification.bucket == .modelsEndpointUnavailable)
            #expect(!failure.classification.action.localizedCaseInsensitiveContains("manual model"))
            #expect(!failure.classification.action.localizedCaseInsensitiveContains("deployment/model"))
        }
    }

    @Test func ongoingNativeProviderDiagnosticsDoNotSuggestManualModelRecovery() throws {
        for providerType in [RemoteProviderType.anthropic, .gemini, .openAICodex] {
            let provider = Self.provider(providerType: providerType)
            var state = RemoteProviderState(providerId: provider.id)
            state.lastError = "HTTP 405 from the models endpoint"

            let classification = try #require(
                ProviderFailureClassifier.classify(
                    provider: provider,
                    state: state,
                    proxy: .disabled,
                    apiKeyPresent: true,
                    oauthTokensPresent: false
                )
            )

            #expect(classification.bucket == .modelsEndpointUnavailable)
            #expect(!classification.action.localizedCaseInsensitiveContains("manual model"))
            #expect(!classification.action.localizedCaseInsensitiveContains("openai-compatible"))
        }
    }

    @Test func proxyFailureStaysDistinctFromOriginFailure() {
        let failure = ProviderFailureClassifier.classifySetupFailure(
            provider: Self.provider(),
            error: NSError(
                domain: "ProviderSetupRecoveryTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "proxy connection refused"]
            ),
            proxy: .active("socks5://proxy.example:1080"),
            apiKeyPresent: true,
            oauthTokensPresent: false
        )

        #expect(failure.classification.bucket == .proxyConnectFailed)
        #expect(failure.proxyState == "active")
        #expect(!failure.pasteboardText.contains("proxy.example"))
    }

    @Test func setupEvidenceIsAllowlistedAndContainsNoEndpointOrCredentialValues() {
        let provider = Self.provider(
            host: "private.internal.example",
            basePath: "/tenant/secret-path",
            manualModelIds: ["private-model"]
        )
        let failure = ProviderFailureClassifier.classifySetupFailure(
            provider: provider,
            error: NSError(
                domain: "ProviderSetupRecoveryTests",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "API key sk-private-123 was rejected by api.internal.corp:8443/v2/models while reading /Users/mmeding/Secrets/provider.json"
                ]
            ),
            proxy: .invalid("password secret-proxy-value"),
            apiKeyPresent: true,
            oauthTokensPresent: false
        )

        #expect(!failure.pasteboardText.contains("private.internal.example"))
        #expect(!failure.pasteboardText.contains("secret-path"))
        #expect(!failure.pasteboardText.contains("private-model"))
        #expect(!failure.pasteboardText.contains("sk-private-123"))
        #expect(!failure.pasteboardText.contains("api.internal.corp"))
        #expect(!failure.pasteboardText.contains("/v2/models"))
        #expect(!failure.pasteboardText.contains("/Users/mmeding"))
        #expect(!failure.pasteboardText.contains("provider.json"))
        #expect(!failure.pasteboardText.contains("secret-proxy-value"))
        #expect(failure.pasteboardText.contains("sk-***"))
        #expect(failure.pasteboardText.contains("[redacted-endpoint]"))
        #expect(failure.pasteboardText.contains("[redacted-local-path]"))
        #expect(failure.pasteboardText.contains("manual-model-count=1"))
    }

    private static func provider(
        host: String = "api.example.com",
        basePath: String = "/v1",
        manualModelIds: [String] = [],
        authType: RemoteProviderAuthType = .apiKey,
        providerType: RemoteProviderType = .openaiLegacy
    ) -> RemoteProvider {
        RemoteProvider(
            name: "Example",
            host: host,
            providerProtocol: .https,
            basePath: basePath,
            authType: authType,
            providerType: providerType,
            manualModelIds: manualModelIds
        )
    }
}
