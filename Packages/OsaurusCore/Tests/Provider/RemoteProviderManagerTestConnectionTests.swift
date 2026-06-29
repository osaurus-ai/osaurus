//
//  RemoteProviderManagerTestConnectionTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct RemoteProviderManagerTestConnectionTests {
    @Test func testConnectionUsesManualModelsWhenModelsEndpointIsMissing() async throws {
        try await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            defer {
                manager.testConnectionTransportOverride = nil
                manager._testRemoveProviders(ids: [])
            }

            manager.testConnectionTransportOverride = { request in
                #expect(request.url?.absoluteString == "https://api.example.test/v1/models")
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (Data(#"{"error":{"message":"not found"}}"#.utf8), response)
            }

            let models = try await manager.testConnection(
                host: "api.example.test",
                providerProtocol: .https,
                port: nil,
                basePath: "/v1",
                authType: .none,
                providerType: .openaiLegacy,
                apiKey: nil,
                headers: [:],
                manualModelIds: [" direct-chat ", "DIRECT-CHAT", ""]
            )

            #expect(models == ["direct-chat"])
        }
    }

    @Test func testConnectionFailureCarriesRedactedReplayDiagnostics() async throws {
        try await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            defer {
                manager.testConnectionTransportOverride = nil
                manager._testRemoveProviders(ids: [])
            }

            manager.testConnectionTransportOverride = { request in
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-request-secret-12345")
                #expect(request.value(forHTTPHeaderField: "X-Provider-Token") == "request-token-secret")
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "application/json",
                        "Set-Cookie": "session=response-cookie-secret",
                    ]
                )!
                return (
                    Data(
                        #"{"error":{"message":"invalid api key sk-response-secret-12345","access_token":"response-access-token"}}"#
                            .utf8
                    ),
                    response
                )
            }

            do {
                _ = try await manager.testConnection(
                    host: "api.example.test",
                    providerProtocol: .https,
                    port: nil,
                    basePath: "/v1",
                    authType: .apiKey,
                    providerType: .openaiLegacy,
                    apiKey: "sk-test-request-secret-12345",
                    headers: ["X-Provider-Token": "request-token-secret"],
                    manualModelIds: []
                )
                Issue.record("Expected test connection to fail.")
            } catch let error as RemoteProviderServiceError {
                let diagnostics = try #require(error.replayDiagnostics)
                let copied = diagnostics.pasteboardText

                #expect(copied.contains("Provider request evidence:"))
                #expect(copied.contains("request: GET https://api.example.test/v1/models"))
                #expect(copied.contains("response: HTTP 401 https://api.example.test/v1/models"))
                #expect(copied.contains("Authorization=***"))
                #expect(copied.contains("X-Provider-Token=***"))
                #expect(copied.contains("Set-Cookie=***"))
                #expect(copied.contains(#""access_token":"***""#))
                #expect(copied.contains("sk-***"))

                for secret in [
                    "sk-test-request-secret-12345",
                    "request-token-secret",
                    "response-cookie-secret",
                    "sk-response-secret-12345",
                    "response-access-token",
                ] {
                    #expect(!copied.contains(secret))
                    #expect(!error.localizedDescription.contains(secret))
                }
            } catch {
                Issue.record("Expected RemoteProviderServiceError, got \(error).")
            }
        }
    }
}
