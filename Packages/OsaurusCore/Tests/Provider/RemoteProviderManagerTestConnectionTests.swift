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

    @Test func testConnectionFireworksMergesServerlessCatalogAcrossPages() async throws {
        try await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            defer {
                manager.testConnectionTransportOverride = nil
                manager._testRemoveProviders(ids: [])
            }

            manager.testConnectionTransportOverride = { request in
                let url = request.url!.absoluteString
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                if url == "https://api.fireworks.ai/inference/v1/models" {
                    return (
                        Data(
                            #"{"object":"list","data":[{"id":"accounts/fireworks/models/llama-v3p1-70b-instruct","object":"model","created":0,"owned_by":"fireworks"}]}"#
                                .utf8
                        ),
                        response
                    )
                }
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fw-test-key")
                if url.contains("pageToken=page-2") {
                    return (
                        Data(
                            #"{"models":[{"name":"accounts/fireworks/models/qwen3-235b","state":"READY","supportsServerless":true,"conversationConfig":{}}]}"#
                                .utf8
                        ),
                        response
                    )
                }
                #expect(url == "https://api.fireworks.ai/v1/accounts/fireworks/models?pageSize=200")
                return (
                    Data(
                        #"""
                        {"models":[
                          {"name":"accounts/fireworks/models/LLAMA-V3P1-70B-INSTRUCT","state":"READY","supportsServerless":true,"conversationConfig":{}},
                          {"name":"accounts/fireworks/models/deepseek-v3","state":"READY","supportsServerless":true,"conversationConfig":{}},
                          {"name":"accounts/fireworks/models/an-embedding","state":"READY","supportsServerless":true}
                        ],"nextPageToken":"page-2"}
                        """#.utf8
                    ),
                    response
                )
            }

            let models = try await manager.testConnection(
                host: "api.fireworks.ai",
                providerProtocol: .https,
                port: nil,
                basePath: "/inference/v1",
                authType: .apiKey,
                providerType: .openaiLegacy,
                apiKey: "fw-test-key",
                headers: [:]
            )

            // /models first, then catalog pages; the case-different catalog
            // duplicate of the /models entry and the chat-incapable embedding
            // are both dropped.
            #expect(
                models == [
                    "accounts/fireworks/models/llama-v3p1-70b-instruct",
                    "accounts/fireworks/models/deepseek-v3",
                    "accounts/fireworks/models/qwen3-235b",
                ]
            )
        }
    }

    @Test func testConnectionCodexWithoutStoredTokensReturnsStaticFallback() async throws {
        try await RemoteProviderTestLock.shared.run {
            // No OAuth tokens exist for a fresh provider id, so the Codex
            // branch must fall back to the static catalog without touching
            // the network (there is no transport override to answer it).
            let models = try await RemoteProviderManager.shared.testConnection(
                host: "chatgpt.com",
                providerProtocol: .https,
                port: nil,
                basePath: "/backend-api",
                authType: .openAICodexOAuth,
                providerType: .openAICodex,
                apiKey: nil,
                headers: [:],
                manualModelIds: [],
                providerId: UUID()
            )

            #expect(models == OpenAICodexOAuthService.supportedModels)
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
