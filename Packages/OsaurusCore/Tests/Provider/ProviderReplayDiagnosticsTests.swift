//
//  ProviderReplayDiagnosticsTests.swift
//  osaurusTests
//
//  Security coverage for provider request/response replay diagnostics.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Provider replay diagnostics")
struct ProviderReplayDiagnosticsTests {
    @Test func bundleRedactsRequestAndResponseSecrets() throws {
        let url = try #require(
            URL(
                string:
                    "https://user:password@api.example.test/v1/models?api_key=sk-query-secret-12345&token=query-token&safe=1"
            )
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("Bearer sk-request-header-12345", forHTTPHeaderField: "Authorization")
        request.setValue("visible", forHTTPHeaderField: "X-Debug")
        request.setValue("custom-secret", forHTTPHeaderField: "X-Custom-Provider-Secret")
        request.httpBody = Data(
            #"{"api_key":"sk-body-secret-12345","access_token":"body-access","messages":[{"content":"hello"}]}"#.utf8
        )

        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 401,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/json",
                    "Set-Cookie": "session=response-cookie-secret",
                ]
            )
        )
        let body = Data(
            #"{"error":{"message":"bad key sk-response-secret-12345","refresh_token":"response-refresh","token":"response-token"}}"#
                .utf8
        )

        let bundle = ProviderReplayDiagnosticBundle(
            phase: "model_discovery",
            request: request,
            response: response,
            responseData: body,
            configuredSecretHeaderKeys: ["X-Custom-Provider-Secret"]
        )
        let copied = bundle.pasteboardText

        #expect(copied.contains("request: POST https://***:***@api.example.test/v1/models"))
        #expect(copied.contains("safe=1"))
        #expect(copied.contains("api_key=***"))
        #expect(copied.contains("token=***"))
        #expect(copied.contains("Authorization=***"))
        #expect(copied.contains("X-Custom-Provider-Secret=***"))
        #expect(copied.contains("X-Debug=visible"))
        #expect(copied.contains(#""api_key":"***""#))
        #expect(copied.contains(#""access_token":"***""#))
        #expect(copied.contains(#""refresh_token":"***""#))
        #expect(copied.contains(#""token":"***""#))
        #expect(copied.contains("sk-***"))
        #expect(copied.contains("Set-Cookie=***"))

        for secret in [
            "password",
            "sk-query-secret-12345",
            "query-token",
            "sk-request-header-12345",
            "custom-secret",
            "sk-body-secret-12345",
            "body-access",
            "response-cookie-secret",
            "sk-response-secret-12345",
            "response-refresh",
            "response-token",
        ] {
            #expect(!copied.contains(secret))
        }
    }

    @Test func providerDiagnosticsCopyIncludesRedactedReplayEvidence() throws {
        let provider = RemoteProvider(
            name: "Local API",
            host: "127.0.0.1",
            providerProtocol: .http,
            port: 8000,
            basePath: "/api/v1",
            authType: .apiKey,
            providerType: .openaiLegacy
        )
        let url = try #require(URL(string: "http://127.0.0.1:8000/api/v1/models?access_token=url-secret"))
        var request = URLRequest(url: url)
        request.setValue("Bearer sk-report-secret-12345", forHTTPHeaderField: "Authorization")
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )
        let diagnostics = ProviderReplayDiagnosticBundle(
            phase: "model_discovery",
            request: request,
            response: response,
            responseData: Data(#"{"error":{"message":"invalid api_key=sk-report-body-12345"}}"#.utf8)
        )
        var state = RemoteProviderState(providerId: provider.id)
        state.lastError = "HTTP 401 unauthorized"
        state.lastReplayDiagnostics = diagnostics

        let report = ProviderNetworkDiagnostics.remoteProviderReport(
            provider: provider,
            state: state,
            proxy: .disabled,
            apiKeyPresent: true,
            oauthTokensPresent: false
        )

        let row = try #require(report.rows.first { $0.id == "request-evidence" })
        let copied = report.pasteboardText
        #expect(row.severity == .warning)
        #expect(copied.contains("Provider request evidence:"))
        #expect(copied.contains("GET http://127.0.0.1:8000/api/v1/models?access_token=***"))
        #expect(!copied.contains("url-secret"))
        #expect(!copied.contains("sk-report-secret-12345"))
        #expect(!copied.contains("sk-report-body-12345"))
    }

    @Test func replayEvidenceKeepsBodyExcerptsOnOneLine() throws {
        let url = try #require(URL(string: "https://api.example.test/v1/models"))
        var request = URLRequest(url: url)
        request.httpBody = Data("line1\nAuthorization: Bearer sk-body-line-secret\nline3".utf8)
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )
        )

        let bundle = ProviderReplayDiagnosticBundle(
            phase: "model_discovery",
            request: request,
            response: response,
            responseData: Data("error\nrequest_headers: Authorization=Bearer sk-response-line-secret".utf8)
        )

        let copied = bundle.pasteboardText
        #expect(copied.contains("request_body: line1 Authorization=*** line3"))
        #expect(copied.contains("response_body: error request_headers: Authorization=***"))
        #expect(!copied.contains("sk-body-line-secret"))
        #expect(!copied.contains("sk-response-line-secret"))
        #expect(!copied.contains("\nAuthorization:"))
        let lines = copied.split(separator: "\n").map(String.init)
        #expect(lines.filter { $0.hasPrefix("request_headers:") }.count == 1)
        #expect(lines.filter { $0.hasPrefix("response_body:") }.count == 1)
    }
}
