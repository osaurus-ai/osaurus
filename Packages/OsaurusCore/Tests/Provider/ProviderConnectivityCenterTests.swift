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
        #expect(!snapshot.filtered(by: .attention).contains { $0.provider.name == "Azure" })
        #expect(snapshot.issueKindCounts[.connection] == 1)
        #expect(snapshot.groupedReportsByPrimaryIssueKind[.connection]?.map(\.provider.name) == ["Lemonade"])
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

    @Test func issueKindMappingUsesStableDiagnosticRowIDs() {
        #expect(ProviderConnectivityIssueKind.kind(forDiagnosticRowID: "connection") == .connection)
        #expect(ProviderConnectivityIssueKind.kind(forDiagnosticRowID: "auth") == .authentication)
        #expect(ProviderConnectivityIssueKind.kind(forDiagnosticRowID: "oauth-context") == .oauthContext)
        #expect(ProviderConnectivityIssueKind.kind(forDiagnosticRowID: "request-evidence") == .requestEvidence)
        #expect(ProviderConnectivityIssueKind.kind(forDiagnosticRowID: "models") == .models)
        #expect(ProviderConnectivityIssueKind.kind(forDiagnosticRowID: "format") == .format)
        #expect(ProviderConnectivityIssueKind.kind(forDiagnosticRowID: "proxy") == .proxy)
        #expect(ProviderConnectivityIssueKind.kind(forDiagnosticRowID: "transport") == .transport)
        #expect(ProviderConnectivityIssueKind.kind(forDiagnosticRowID: "repro") == .repro)

        let unknown = ProviderConnectivityIssueKind.kind(forDiagnosticRowID: "future-row")
        #expect(unknown.id == "unknown:future-row")
        #expect(unknown.isUnknown)
    }

    @Test func everyProviderNetworkDiagnosticRowIDHasAnIssueBucket() {
        let emittedIDs = [
            "auth",
            "connection",
            "format",
            "models",
            "oauth-context",
            "proxy",
            "repro",
            "request-evidence",
            "transport",
        ]

        for rowID in emittedIDs {
            #expect(!ProviderConnectivityIssueKind.kind(forDiagnosticRowID: rowID).isUnknown)
        }
    }

    @Test func unknownIssueBucketsKeepCountsReconciled() {
        let provider = RemoteProvider(
            id: UUID(),
            name: "Future provider",
            host: "api.future.test",
            authType: .none
        )
        let unknown = ProviderConnectivityIssueKind.kind(forDiagnosticRowID: "future-row")
        let report = ProviderConnectivityProviderReport(
            id: provider.id,
            provider: provider,
            state: nil,
            diagnostics: ProviderDiagnosticReport(
                title: "Remote provider diagnostics",
                subtitle: "Future provider | https://api.future.test",
                rows: [
                    ProviderDiagnosticRow(
                        id: "future-row",
                        title: "Future row",
                        value: "Warning",
                        severity: .warning
                    ),
                ]
            ),
            status: .needsAttention,
            highestSeverity: .warning,
            summary: "Future row: Warning",
            recommendedAction: nil,
            modelCount: 0,
            manualModelCount: 0,
            issueKinds: [unknown],
            primaryIssueKind: unknown
        )
        let snapshot = ProviderConnectivitySnapshot(reports: [report], proxy: .disabled)

        #expect(snapshot.issueKindCounts == [unknown: 1])
        #expect(snapshot.groupedReportsByPrimaryIssueKind[unknown]?.map(\.provider.name) == ["Future provider"])
        #expect(snapshot.issueKindCounts.values.reduce(0, +) == snapshot.attentionCount)
    }

    @Test func attentionReportWithoutPrimaryIssueUsesUnclassifiedBucket() {
        let provider = RemoteProvider(
            id: UUID(),
            name: "Unclassified provider",
            host: "api.unclassified.test",
            authType: .none
        )
        let report = ProviderConnectivityProviderReport(
            id: provider.id,
            provider: provider,
            state: nil,
            diagnostics: ProviderDiagnosticReport(
                title: "Remote provider diagnostics",
                subtitle: "Unclassified provider | https://api.unclassified.test",
                rows: []
            ),
            status: .needsAttention,
            highestSeverity: .info,
            summary: "Needs attention",
            recommendedAction: nil,
            modelCount: 0,
            manualModelCount: 0,
            issueKinds: [],
            primaryIssueKind: nil
        )
        let snapshot = ProviderConnectivitySnapshot(reports: [report], proxy: .disabled)

        #expect(snapshot.issueKindCounts == [.uncategorized: 1])
        #expect(snapshot.issueKindCounts.values.reduce(0, +) == snapshot.attentionCount)
    }

    @Test func primaryIssueKindMatchesTheActionableSummaryRow() {
        let provider = RemoteProvider(
            name: "Broken API",
            host: "api.example.test",
            authType: .apiKey
        )
        var state = RemoteProviderState(providerId: provider.id)
        state.lastError = "HTTP 401 unauthorized"

        let report = ProviderConnectivityCenter.providerReport(
            provider: provider,
            state: state,
            proxy: .invalid("Proxy host 'localhost' is reserved for local networking."),
            credentialPresence: RemoteProviderCredentialPresence(apiKeyPresent: false)
        )

        #expect(report.issueKinds == [.authentication, .connection, .proxy])
        #expect(report.primaryIssueKind == .connection)
        #expect(report.summary.contains("Connection"))
        #expect(report.recommendedAction?.contains("Test") == true)

        let snapshot = ProviderConnectivitySnapshot(reports: [report], proxy: .disabled)
        #expect(snapshot.issueKindCounts == [.authentication: 1, .connection: 1, .proxy: 1])
        #expect(snapshot.filtered(by: .attention, issueKind: .authentication).map(\.provider.name) == ["Broken API"])
        #expect(snapshot.filtered(by: .attention, issueKind: .connection).map(\.provider.name) == ["Broken API"])
        #expect(snapshot.filtered(by: .attention, issueKind: .proxy).map(\.provider.name) == ["Broken API"])
    }

    @Test func infoRowsDoNotBecomeReportIssues() {
        let provider = OpenAICodexOAuthService.makeProvider(id: UUID())

        let report = ProviderConnectivityCenter.providerReport(
            provider: provider,
            state: nil,
            proxy: .disabled,
            credentialPresence: RemoteProviderCredentialPresence(oauthTokensPresent: true)
        )

        #expect(report.issueKinds.isEmpty)
        #expect(report.primaryIssueKind == nil)
    }

    @Test func issueCountsGroupingFilteringAndDisabledExclusionUsePrimaryIssueBuckets() {
        let auth = RemoteProvider(
            id: UUID(),
            name: "Missing key",
            host: "api.example.test",
            authType: .apiKey
        )
        let proxy = RemoteProvider(
            id: UUID(),
            name: "Proxy warning",
            host: "api.proxy.test",
            authType: .none
        )
        let disabled = RemoteProvider(
            id: UUID(),
            name: "Disabled key",
            host: "api.disabled.test",
            authType: .apiKey,
            enabled: false
        )

        var proxyState = RemoteProviderState(providerId: proxy.id)
        proxyState.isConnected = true
        proxyState.discoveredModels = ["model-a"]

        let snapshot = ProviderConnectivityCenter.snapshot(
            providers: [auth, proxy, disabled],
            states: [proxy.id: proxyState],
            proxy: .invalid("Proxy host 'localhost' is reserved for local networking."),
            credentialsByProvider: [:]
        )

        #expect(snapshot.attentionCount == 2)
        #expect(snapshot.issueKindCounts == [.authentication: 1, .proxy: 2])
        #expect(snapshot.groupedReportsByPrimaryIssueKind[.authentication]?.map(\.provider.name) == ["Missing key"])
        #expect(snapshot.groupedReportsByPrimaryIssueKind[.proxy]?.map(\.provider.name) == ["Proxy warning"])
        #expect(!snapshot.groupedReportsByPrimaryIssueKind.values.flatMap { $0 }.contains { $0.provider.name == "Disabled key" })
        #expect(snapshot.filtered(by: .all, issueKind: .authentication).map(\.provider.name) == ["Missing key"])
        #expect(snapshot.filtered(by: .attention, issueKind: .authentication).map(\.provider.name) == ["Missing key"])
        #expect(snapshot.filtered(by: .attention, issueKind: .proxy).map(\.provider.name) == ["Missing key", "Proxy warning"])
        #expect(snapshot.filtered(by: .attention, issueKind: .requestEvidence).isEmpty)
        #expect(snapshot.filtered(by: .connected, issueKind: .proxy).map(\.provider.name) == ["Proxy warning"])
        #expect(snapshot.issueKindCounts(for: .attention) == [.authentication: 1, .proxy: 2])
    }

    @Test func groupedIssueExportReusesRedactedProviderDiagnostics() throws {
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
        state.lastError = #"HTTP 401: {"access_token":"state-secret"}"#
        state.lastReplayDiagnostics = diagnostics

        let snapshot = ProviderConnectivityCenter.snapshot(
            providers: [provider],
            states: [provider.id: state],
            proxy: .disabled,
            credentialsByProvider: [
                provider.id: RemoteProviderCredentialPresence(apiKeyPresent: true),
            ]
        )

        let copied = snapshot.groupedPasteboardText(issueKind: .connection)
        #expect(copied.contains("provider-connectivity-issue-diagnostics"))
        #expect(copied.contains("Local API"))
        #expect(copied.contains("Provider request evidence:"))
        #expect(!copied.contains("url-secret"))
        #expect(!copied.contains("sk-report-secret-12345"))
        #expect(!copied.contains("sk-report-body-12345"))
        #expect(!copied.contains("state-secret"))
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
