//
//  PluginToolCapabilityRecoveryCenterTests.swift
//  OsaurusCoreTests
//
//  Focused coverage for the read-only plugin/tool recovery diagnostics.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Plugin/tool capability recovery center")
struct PluginToolCapabilityRecoveryCenterTests {
    @Test func disabledPermissionPolicyRequiresUserPolicyReview() {
        let row = makeRow(
            name: "calendar_delete",
            source: .plugin,
            state: .blocked,
            availabilityReasons: [.permissionBlocked],
            detail: "permission policy is deny",
            groupName: "com.example.calendar"
        )

        let report = PluginToolCapabilityRecoveryCenter.diagnose(
            PluginToolCapabilityRecoveryRequest(
                toolExposure: exposure([row])
            )
        )

        let item = report.item(kind: .tool, identifier: "calendar_delete")
        #expect(item?.status == .blocked)
        #expect(item?.containsReason(.disabledPermissionPolicy) == true)
        #expect(item?.suggestions.contains { suggestion in
            suggestion.actionKind == .reviewUserPolicy
                && suggestion.safetyChecks.contains(.userPolicy)
                && suggestion.safetyChecks.contains(.trust)
                && !suggestion.autoApplies
        } == true)
    }

    @Test func unavailableSearchSurfacesSearchAndToolRecoveryWithoutEnabling() {
        let row = makeRow(
            name: "notion_search",
            source: .mcpProvider,
            state: .loadable,
            availabilityReasons: [.loadableViaCapabilitiesLoad],
            detail: "registered mcp tool",
            groupName: "Notion MCP",
            indexedForSearch: false,
            searchable: false,
            searchReasons: [.notIndexed]
        )
        let search = CapabilityRecoverySearchSnapshot(
            isAvailable: false,
            health: CapabilitySearchHealth(
                registryToolCount: 2,
                indexedToolCount: 0,
                missingFromIndex: ["notion_search"]
            ),
            failureMessage: "VecturaKit init failed"
        )

        let report = PluginToolCapabilityRecoveryCenter.diagnose(
            PluginToolCapabilityRecoveryRequest(
                toolExposure: exposure([row]),
                search: search
            )
        )

        let searchItem = report.item(kind: .search, identifier: "capability_search")
        #expect(searchItem?.status == .unavailable)
        #expect(searchItem?.containsReason(.unavailableSearch) == true)
        #expect(searchItem?.containsReason(.staleSearchIndex) == true)

        let toolItem = report.item(kind: .tool, identifier: "notion_search")
        #expect(toolItem?.containsReason(.unavailableSearch) == true)
        #expect(toolItem?.suggestions.allSatisfy { !$0.autoApplies } == true)
    }

    @Test func missingProviderExplainsRequestedToolAbsence() {
        let report = PluginToolCapabilityRecoveryCenter.diagnose(
            PluginToolCapabilityRecoveryRequest(
                requestedTools: [
                    RequestedToolCapability(
                        toolName: "hubspot_search",
                        expectedSource: .mcpProvider,
                        expectedOwner: "HubSpot"
                    )
                ]
            )
        )

        let item = report.item(kind: .tool, identifier: "hubspot_search")
        #expect(item?.status == .unavailable)
        #expect(item?.containsReason(.missingProvider) == true)
        #expect(item?.suggestions.contains { suggestion in
            suggestion.actionKind == .configureProvider
                && suggestion.safetyChecks.contains(.provenance)
                && suggestion.safetyChecks.contains(.scope)
                && !suggestion.autoApplies
        } == true)
    }

    @Test func untrustedPluginBlocksOtherwiseLoadableTool() {
        let plugin = PluginCapabilitySnapshot(
            pluginId: "com.example.weather",
            displayName: "Weather",
            kind: .native,
            trustState: .untrusted,
            manifestState: .current,
            declaredToolNames: ["weather_lookup"],
            loadedToolNames: ["weather_lookup"]
        )
        let row = makeRow(
            name: "weather_lookup",
            source: .plugin,
            state: .loadable,
            availabilityReasons: [.loadableViaCapabilitiesLoad],
            detail: "registered plugin tool",
            groupName: plugin.pluginId
        )

        let report = PluginToolCapabilityRecoveryCenter.diagnose(
            PluginToolCapabilityRecoveryRequest(
                toolExposure: exposure([row]),
                plugins: [plugin]
            )
        )

        let item = report.item(kind: .tool, identifier: "weather_lookup")
        #expect(item?.status == .blocked)
        #expect(item?.containsReason(.untrustedPlugin) == true)
        #expect(item?.containsReason(.falseAvailablePrevented) == true)
        #expect(item?.isUsableNow == false)
    }

    @Test func staleManifestUsesDeclaredVersusLoadedArtifacts() {
        let plugin = PluginCapabilitySnapshot(
            pluginId: "github:owner/repo/crm",
            displayName: "CRM",
            kind: .claude,
            trustState: .trusted,
            manifestState: .stale,
            declaredToolNames: ["crm_lookup", "crm_update"],
            loadedToolNames: ["crm_lookup"],
            declaredMCPProviderNames: ["CRM MCP"],
            loadedMCPProviderNames: []
        )

        let report = PluginToolCapabilityRecoveryCenter.diagnose(
            PluginToolCapabilityRecoveryRequest(plugins: [plugin])
        )

        let item = report.item(kind: .plugin, identifier: plugin.pluginId)
        #expect(item?.status == .needsReview)
        #expect(item?.containsReason(.staleManifest) == true)
        #expect(item?.suggestions.contains { suggestion in
            suggestion.actionKind == .refreshManifest
                && suggestion.safetyChecks.contains(.trust)
                && suggestion.safetyChecks.contains(.provenance)
                && !suggestion.autoApplies
        } == true)
    }

    @Test func provenanceMismatchPreventsFalseAvailableTool() {
        let row = makeRow(
            name: "hubspot_search",
            source: .mcpProvider,
            state: .exposed,
            availabilityReasons: [.alreadyLoaded],
            detail: "registered mcp tool",
            groupName: "Unexpected HubSpot"
        )

        let report = PluginToolCapabilityRecoveryCenter.diagnose(
            PluginToolCapabilityRecoveryRequest(
                requestedTools: [
                    RequestedToolCapability(
                        toolName: "hubspot_search",
                        expectedSource: .mcpProvider,
                        expectedOwner: "HubSpot"
                    )
                ],
                toolExposure: exposure([row])
            )
        )

        let item = report.item(kind: .tool, identifier: "hubspot_search")
        #expect(item?.status == .blocked)
        #expect(item?.containsReason(.provenanceScopeMismatch) == true)
        #expect(item?.containsReason(.falseAvailablePrevented) == true)
        #expect(item?.isUsableNow == false)
    }

    @Test func mcpToolWithoutProviderSnapshotDoesNotInventMissingProvider() {
        let row = makeRow(
            name: "notion_search",
            source: .mcpProvider,
            state: .exposed,
            availabilityReasons: [.alreadyLoaded],
            detail: "registered mcp tool",
            groupName: "Notion MCP"
        )

        let report = PluginToolCapabilityRecoveryCenter.diagnose(
            PluginToolCapabilityRecoveryRequest(
                requestedTools: [
                    RequestedToolCapability(
                        toolName: "notion_search",
                        expectedSource: .mcpProvider,
                        expectedOwner: "Notion MCP"
                    )
                ],
                toolExposure: exposure([row])
            )
        )

        let item = report.item(kind: .tool, identifier: "notion_search")
        #expect(item?.status == .available)
        #expect(item?.containsReason(.missingProvider) == false)
        #expect(item?.containsReason(.falseAvailablePrevented) == false)
        #expect(item?.isUsableNow == true)
    }

    @Test func providerAndMCPAuthSymptomsMapToRecoveryReasons() {
        let mcp = MCPProvider(
            id: UUID(),
            name: "Secure MCP",
            url: "https://mcp.example.test",
            authType: .oauth,
            transport: .http
        )
        var mcpState = MCPProviderState(providerId: mcp.id)
        mcpState.requiresAuth = true

        let remote = RemoteProvider(
            id: UUID(),
            name: "Remote API",
            host: "api.example.test",
            authType: .apiKey,
            providerType: .openResponses
        )
        var remoteState = RemoteProviderState(providerId: remote.id)
        remoteState.lastError = "HTTP 401 unauthorized"

        let report = PluginToolCapabilityRecoveryCenter.diagnose(
            PluginToolCapabilityRecoveryRequest(
                mcpProviders: [
                    MCPProviderCapabilitySnapshot(provider: mcp, state: mcpState)
                ],
                remoteProviders: [
                    RemoteProviderCapabilitySnapshot(provider: remote, state: remoteState)
                ]
            )
        )

        let mcpItem = report.item(kind: .mcpProvider, identifier: mcp.id.uuidString)
        #expect(mcpItem?.status == .blocked)
        #expect(mcpItem?.containsReason(.mcpAuthRequired) == true)

        let remoteItem = report.item(kind: .provider, identifier: remote.id.uuidString)
        #expect(remoteItem?.status == .blocked)
        #expect(remoteItem?.containsReason(.providerAuthRequired) == true)
    }

    @Test func providerSymptomClassifierAvoidsBroadAuthSubstringMatches() {
        let remote = RemoteProvider(
            id: UUID(),
            name: "Remote API",
            host: "api.example.test",
            authType: .apiKey,
            providerType: .openResponses
        )
        var remoteState = RemoteProviderState(providerId: remote.id)
        remoteState.lastError = "author cache failed with status 4012"

        let report = PluginToolCapabilityRecoveryCenter.diagnose(
            PluginToolCapabilityRecoveryRequest(
                remoteProviders: [
                    RemoteProviderCapabilitySnapshot(provider: remote, state: remoteState)
                ]
            )
        )

        let item = report.item(kind: .provider, identifier: remote.id.uuidString)
        #expect(item?.status == .unavailable)
        #expect(item?.containsReason(.providerConnectivityFailed) == true)
        #expect(item?.containsReason(.providerAuthRequired) == false)
    }

    @Test func diagnosticRowsUseBoundaryAwareAuthClassification() {
        let remote = RemoteProvider(
            id: UUID(),
            name: "Remote API",
            host: "api.example.test",
            authType: .apiKey,
            providerType: .openResponses
        )
        let diagnostics = ProviderDiagnosticReport(
            title: "Remote provider diagnostics",
            subtitle: "Remote API",
            rows: [
                ProviderDiagnosticRow(
                    id: "author_cache",
                    title: "Author cache",
                    value: "invalidate pending",
                    severity: .blocked,
                    detail: "author cache failed with status 4012"
                ),
            ]
        )

        let report = PluginToolCapabilityRecoveryCenter.diagnose(
            PluginToolCapabilityRecoveryRequest(
                remoteProviders: [
                    RemoteProviderCapabilitySnapshot(provider: remote, diagnostics: diagnostics)
                ]
            )
        )

        let item = report.item(kind: .provider, identifier: remote.id.uuidString)
        #expect(item?.status == .unavailable)
        #expect(item?.containsReason(.providerConnectivityFailed) == true)
        #expect(item?.containsReason(.providerAuthRequired) == false)
    }

    @Test func mcpProbeFailuresMapToSpecificRecoveryReasons() {
        let provider = MCPProvider(
            id: UUID(),
            name: "Local MCP",
            url: "",
            transport: .stdio,
            command: "missing-server"
        )
        let probe = MCPProviderProbeResult(
            providerId: provider.id,
            providerName: provider.name,
            transportSummary: "stdio",
            startedAt: Date(timeIntervalSince1970: 10),
            finishedAt: Date(timeIntervalSince1970: 11),
            succeeded: false,
            stage: .spawn,
            reasonCode: .commandNotFound,
            toolCount: 0,
            toolNames: [],
            message: "command not found",
            action: "install the missing command"
        )
        let health = MCPProviderHealthSnapshot(
            providerId: provider.id,
            providerName: provider.name,
            transportSummary: "stdio",
            lastProbe: probe,
            updatedAt: Date(timeIntervalSince1970: 12)
        )

        let report = PluginToolCapabilityRecoveryCenter.diagnose(
            PluginToolCapabilityRecoveryRequest(
                mcpProviders: [
                    MCPProviderCapabilitySnapshot(provider: provider, healthSnapshot: health)
                ]
            )
        )

        let item = report.item(kind: .mcpProvider, identifier: provider.id.uuidString)
        #expect(item?.status == .blocked)
        #expect(item?.containsReason(.mcpCommandNotFound) == true)
        #expect(item?.containsReason(.mcpProbeFailed) == false)
    }

    @Test func consentRequiredPluginLoadErrorMapsToTrustWithoutLoadFailure() {
        let plugin = PluginCapabilitySnapshot(
            pluginId: "com.example.consent",
            displayName: "Consent Plugin",
            kind: .claude,
            trustState: .unknown,
            manifestState: .current,
            loadError: "consent_required: user must approve plugin"
        )

        let report = PluginToolCapabilityRecoveryCenter.diagnose(
            PluginToolCapabilityRecoveryRequest(plugins: [plugin])
        )

        let item = report.item(kind: .plugin, identifier: plugin.pluginId)
        #expect(item?.status == .blocked)
        #expect(item?.containsReason(.untrustedPlugin) == true)
        #expect(item?.containsReason(.pluginLoadFailed) == false)
    }

    @Test func pluginToolLoadErrorPreventsFalseAvailableToolState() {
        let plugin = PluginCapabilitySnapshot(
            pluginId: "com.example.broken",
            displayName: "Broken Plugin",
            kind: .native,
            trustState: .unknown,
            manifestState: .current,
            declaredToolNames: ["broken_tool"],
            loadedToolNames: ["broken_tool"],
            loadError: "plugin crashed while loading"
        )
        let row = makeRow(
            name: "broken_tool",
            source: .plugin,
            state: .exposed,
            availabilityReasons: [.alreadyLoaded],
            detail: "already loaded",
            groupName: plugin.pluginId
        )

        let report = PluginToolCapabilityRecoveryCenter.diagnose(
            PluginToolCapabilityRecoveryRequest(
                toolExposure: exposure([row]),
                plugins: [plugin],
                includeHealthyItems: true
            )
        )

        let pluginItem = report.item(kind: .plugin, identifier: plugin.pluginId)
        #expect(pluginItem?.status == .blocked)
        #expect(pluginItem?.containsReason(.untrustedPlugin) == true)
        #expect(pluginItem?.containsReason(.pluginLoadFailed) == true)

        let toolItem = report.item(kind: .tool, identifier: "broken_tool")
        #expect(toolItem?.status == .blocked)
        #expect(toolItem?.isUsableNow == false)
        #expect(toolItem?.containsReason(.untrustedPlugin) == true)
        #expect(toolItem?.containsReason(.pluginLoadFailed) == true)
        #expect(toolItem?.containsReason(.falseAvailablePrevented) == true)
    }

    @Test func pluginEvidenceCarriesTrustProvenanceAndManifestState() {
        let plugin = PluginCapabilitySnapshot(
            pluginId: "github:owner/repo/slack",
            displayName: "Slack",
            kind: .claude,
            trustState: .trusted,
            manifestState: .stale,
            declaredToolNames: ["slack_search", "slack_send"],
            loadedToolNames: ["slack_search"],
            provenanceSummary: "github:owner/repo",
            scopeSummary: "plugins/slack"
        )

        let report = PluginToolCapabilityRecoveryCenter.diagnose(
            PluginToolCapabilityRecoveryRequest(plugins: [plugin])
        )

        let item = report.item(kind: .plugin, identifier: plugin.pluginId)
        #expect(item?.status == .needsReview)
        #expect(item?.evidence.contains("kind=claude") == true)
        #expect(item?.evidence.contains("trust=trusted") == true)
        #expect(item?.evidence.contains("manifest=stale") == true)
        #expect(item?.evidence.contains("provenance=github:owner/repo") == true)
        #expect(item?.evidence.contains("scope=plugins/slack") == true)
    }

    @Test func actionableItemsExcludeHealthyRowsButKeepSafeRecoveryActions() {
        let healthy = makeRow(
            name: "ready_tool",
            source: .plugin,
            state: .exposed,
            availabilityReasons: [.alreadyLoaded],
            detail: "ready",
            groupName: "com.example.ready"
        )
        let blocked = makeRow(
            name: "notes_create",
            source: .plugin,
            state: .blocked,
            availabilityReasons: [.missingPermission],
            detail: "missing system permission(s): Notes",
            groupName: "com.example.notes"
        )

        let report = PluginToolCapabilityRecoveryCenter.diagnose(
            PluginToolCapabilityRecoveryRequest(
                toolExposure: exposure([healthy, blocked]),
                includeHealthyItems: true
            )
        )

        #expect(report.item(kind: .tool, identifier: "ready_tool")?.isUsableNow == true)
        #expect(report.actionableItems.map(\.subject.identifier) == ["notes_create"])
        #expect(report.actionableCount == 1)
        let action = report.actionableItems.first?.suggestions.first
        #expect(action?.actionKind == .grantSystemPermission)
        #expect(action?.autoApplies == false)
    }

    @Test func includeHealthyItemsEmitsAvailableRows() {
        let plugin = PluginCapabilitySnapshot(
            pluginId: "com.example.ready",
            displayName: "Ready Plugin",
            kind: .native,
            trustState: .trusted,
            manifestState: .current,
            declaredToolNames: ["ready_tool"],
            loadedToolNames: ["ready_tool"]
        )
        let row = makeRow(
            name: "ready_tool",
            source: .plugin,
            state: .exposed,
            availabilityReasons: [.alreadyLoaded],
            detail: "ready",
            groupName: plugin.pluginId
        )

        let report = PluginToolCapabilityRecoveryCenter.diagnose(
            PluginToolCapabilityRecoveryRequest(
                toolExposure: exposure([row]),
                plugins: [plugin],
                includeHealthyItems: true
            )
        )

        let pluginItem = report.item(kind: .plugin, identifier: plugin.pluginId)
        #expect(pluginItem?.status == .available)
        #expect(pluginItem?.isUsableNow == true)

        let toolItem = report.item(kind: .tool, identifier: "ready_tool")
        #expect(toolItem?.status == .available)
        #expect(toolItem?.isUsableNow == true)
    }

    @Test func reporterSafeOutputRedactsSecretsPathsAndUrls() {
        let provider = RemoteProvider(
            id: UUID(),
            name: "Secret /Users/mmeding/.osaurus/plugins https://api.example.test/v1",
            host: "api.example.test",
            authType: .apiKey,
            providerType: .openResponses
        )
        var state = RemoteProviderState(providerId: provider.id)
        state.lastError =
            "HTTP 401 scope=/Users/mmeding/.osaurus/Tools/com.secret/manifest.json tmp=/private/tmp/secret.txt home=~/Library/Application Support/osaurus Authorization: Bearer raw-token password=hunter2 api_key=sk-test-token file:///private/tmp/secret.txt https://api.example.test/v1"

        let report = PluginToolCapabilityRecoveryCenter.diagnose(
            PluginToolCapabilityRecoveryRequest(
                remoteProviders: [
                    RemoteProviderCapabilitySnapshot(provider: provider, state: state)
                ]
            )
        )

        let item = report.item(kind: .provider, identifier: provider.id.uuidString)
        #expect(item != nil)
        let combined = [
            report.reporterSafeMarkdown,
            item?.summary ?? "",
            item?.subject.displayName ?? "",
            item?.detail ?? "",
            item?.evidence.joined(separator: " ") ?? "",
            item?.suggestions.map(\.detail).joined(separator: " ") ?? "",
        ].joined(separator: " ")

        #expect(!combined.contains("raw-token"))
        #expect(!combined.contains("hunter2"))
        #expect(!combined.contains("sk-test-token"))
        #expect(!combined.contains("/Users/mmeding"))
        #expect(!combined.contains("/private/tmp"))
        #expect(!combined.contains("~/Library"))
        #expect(!combined.contains("Support/osaurus"))
        #expect(!combined.contains("api.example.test/v1"))
        #expect(combined.contains("***"))
        #expect(combined.contains("[path]"))
        #expect(combined.contains("[url]"))
    }

    private func exposure(_ rows: [ToolExposureDiagnostic.Row]) -> ToolExposureDiagnostic {
        ToolExposureDiagnostic(
            registeredToolCount: rows.filter(\.registered).count,
            indexedToolCount: rows.filter(\.indexedForSearch).count,
            rows: rows
        )
    }

    private func makeRow(
        name: String,
        source: ToolExposureSource,
        state: ToolExposureState,
        availabilityReasons: [ToolAvailabilityReasonCode],
        detail: String,
        groupName: String? = nil,
        registered: Bool = true,
        globallyEnabled: Bool = true,
        indexedForSearch: Bool = true,
        searchable: Bool = true,
        searchReasons: [ToolExposureSearchReasonCode] = [.searchable, .indexed]
    ) -> ToolExposureDiagnostic.Row {
        ToolExposureDiagnostic.Row(
            toolName: name,
            description: "Test tool",
            source: source,
            state: state,
            availability: ToolAvailability(
                toolName: name,
                runtime: source.rawValue,
                groupName: groupName,
                reasonCodes: availabilityReasons,
                detail: detail
            ),
            registered: registered,
            globallyEnabled: globallyEnabled,
            indexedForSearch: indexedForSearch,
            searchableByCapabilitiesDiscover: searchable,
            searchReasonCodes: searchReasons,
            tokenEstimate: 8
        )
    }
}
