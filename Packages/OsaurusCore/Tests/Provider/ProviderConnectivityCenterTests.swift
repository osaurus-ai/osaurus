//
//  ProviderConnectivityCenterTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Provider connectivity center")
struct ProviderConnectivityCenterTests {
    @Test func snapshotClassifiesRowsAndBuildsSanitizedReport() {
        let connected = RemoteProvider(
            id: UUID(),
            name: "OpenAI",
            host: "api.openai.com",
            authType: .apiKey,
            providerType: .openResponses
        )
        let failed = RemoteProvider(
            id: UUID(),
            name: "Lemonade",
            host: "127.0.0.1",
            providerProtocol: .http,
            port: 8000,
            basePath: "/api/v1",
            authType: .none,
            providerType: .openaiLegacy,
            manualModelIds: ["local-chat"]
        )
        var disabled = RemoteProvider(
            id: UUID(),
            name: "Azure",
            host: "example.openai.azure.com",
            authType: .apiKey,
            providerType: .azureOpenAI,
            enabled: false,
            manualModelIds: ["prod-chat"]
        )
        disabled.enabled = false

        var connectedState = RemoteProviderState(providerId: connected.id)
        connectedState.isConnected = true
        connectedState.discoveredModels = ["gpt-5.5", "gpt-5.5-mini"]

        var failedState = RemoteProviderState(providerId: failed.id)
        failedState.lastError = #"HTTP 401: {"access_token":"secret-token"}"#

        let snapshot = ProviderConnectivityCenter.snapshot(
            providers: [connected, failed, disabled],
            states: [
                connected.id: connectedState,
                failed.id: failedState,
            ],
            proxy: .active("https://proxy.example.com:8443"),
            credentialsByProvider: [
                connected.id: RemoteProviderCredentialPresence(apiKeyPresent: true),
                disabled.id: RemoteProviderCredentialPresence(apiKeyPresent: false),
            ]
        )

        #expect(snapshot.totalCount == 3)
        #expect(snapshot.connectedCount == 1)
        #expect(snapshot.modelCount == 2)
        #expect(snapshot.manualModelProviderCount == 2)
        #expect(snapshot.filtered(by: .connected).map(\.provider.name) == ["OpenAI"])
        #expect(snapshot.filtered(by: .disabled).map(\.provider.name) == ["Azure"])
        #expect(snapshot.filtered(by: .attention).contains { $0.provider.name == "Lemonade" })
        #expect(snapshot.filtered(by: .attention).contains { $0.provider.name == "Azure" })
        #expect(snapshot.pasteboardText.contains("Provider connectivity diagnostics"))
        #expect(snapshot.pasteboardText.contains("https://proxy.example.com:8443"))
        #expect(!snapshot.pasteboardText.contains("secret-token"))
    }

    @Test func attentionFilterIncludesManualModelFallbackWarnings() {
        let provider = RemoteProvider(
            name: "Azure",
            host: "example.openai.azure.com",
            authType: .apiKey,
            providerType: .azureOpenAI,
            manualModelIds: []
        )

        let report = ProviderConnectivityCenter.providerReport(
            provider: provider,
            state: nil,
            proxy: .disabled,
            credentialPresence: RemoteProviderCredentialPresence(apiKeyPresent: true)
        )

        #expect(report.status == .needsAttention)
        #expect(report.highestSeverity == .warning)
        #expect(report.summary.contains("Model discovery"))
        #expect(report.recommendedAction?.contains("deployment") == true)
    }
}

@Suite(.serialized)
@MainActor
struct RemoteProviderManagerConnectivityCenterTests {
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

    @Test func testConnectionStillFailsWithoutManualModelsOnServerError() async throws {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            defer {
                manager.testConnectionTransportOverride = nil
                manager._testRemoveProviders(ids: [])
            }

            manager.testConnectionTransportOverride = { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (Data(#"{"error":{"message":"boom"}}"#.utf8), response)
            }

            do {
                _ = try await manager.testConnection(
                    host: "api.example.test",
                    providerProtocol: .https,
                    port: nil,
                    basePath: "/v1",
                    authType: .none,
                    providerType: .openaiLegacy,
                    apiKey: nil,
                    headers: [:],
                    manualModelIds: ["local-chat"]
                )
                Issue.record("Expected server error to fail instead of falling back to manual models.")
            } catch let error as RemoteProviderServiceError {
                guard case .requestFailedWithDiagnostics(let message, let diagnostics) = error else {
                    Issue.record("Expected replay diagnostics, got \(error).")
                    return
                }
                #expect(message.contains("boom"))
                #expect(diagnostics.phase == "test_model_discovery")
                #expect(diagnostics.response?.statusCode == 500)
            } catch {
                Issue.record("Expected RemoteProviderServiceError, got \(error).")
            }
        }
    }
}
