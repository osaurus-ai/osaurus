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
            ("HTTP 404 from /models", .modelsEndpointUnavailable),
            ("HTTP 405 from the models endpoint", .modelsEndpointUnavailable),
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
        authType: RemoteProviderAuthType = .apiKey
    ) -> RemoteProvider {
        RemoteProvider(
            name: "Example",
            host: host,
            providerProtocol: .https,
            basePath: basePath,
            authType: authType,
            providerType: .openaiLegacy,
            manualModelIds: manualModelIds
        )
    }
}
