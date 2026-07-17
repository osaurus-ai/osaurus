//
//  PluginToolCapabilityRecoveryCenter.swift
//  osaurus
//
//  Read-only recovery diagnostics for plugin/tool capability availability.
//

import Foundation

enum PluginToolCapabilityRecoveryCenter {
    static func diagnose(
        _ request: PluginToolCapabilityRecoveryRequest,
        generatedAt: Date = Date()
    ) -> PluginToolCapabilityRecoveryReport {
        let pluginById = Dictionary(
            request.plugins.map { ($0.pluginId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let requestedByTool = Dictionary(
            request.requestedTools.map { ($0.toolName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let rowsByName = Dictionary(
            (request.toolExposure?.rows ?? []).map { ($0.toolName, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var items: [CapabilityRecoveryItem] = []

        if let searchItem = makeSearchItem(
            request.search,
            includeHealthy: request.includeHealthyItems
        ) {
            items.append(searchItem)
        }

        for plugin in request.plugins {
            if let item = makePluginItem(plugin, includeHealthy: request.includeHealthyItems) {
                items.append(item)
            }
        }

        for mcp in request.mcpProviders {
            if let item = makeMCPProviderItem(mcp, includeHealthy: request.includeHealthyItems) {
                items.append(item)
            }
        }

        for provider in request.remoteProviders {
            if let item = makeRemoteProviderItem(provider, includeHealthy: request.includeHealthyItems) {
                items.append(item)
            }
        }

        for row in request.toolExposure?.rows ?? [] {
            let expectation = requestedByTool[row.toolName]
            if let item = makeToolItem(
                row,
                expectation: expectation,
                search: request.search,
                pluginById: pluginById,
                mcpProviders: request.mcpProviders,
                includeHealthy: request.includeHealthyItems || expectation != nil
            ) {
                items.append(item)
            }
        }

        for expectation in request.requestedTools where rowsByName[expectation.toolName] == nil {
            items.append(
                makeMissingRequestedToolItem(
                    expectation,
                    pluginById: pluginById,
                    mcpProviders: request.mcpProviders
                )
            )
        }

        return PluginToolCapabilityRecoveryReport(
            generatedAt: generatedAt,
            items: sortedDeduped(items)
        )
    }

    // MARK: - Search

    private static func makeSearchItem(
        _ search: CapabilityRecoverySearchSnapshot?,
        includeHealthy: Bool
    ) -> CapabilityRecoveryItem? {
        guard let search else { return nil }
        var reasons: [CapabilityRecoveryReasonCode] = []
        var evidence: [String] = []

        if !search.isAvailable {
            append(.unavailableSearch, to: &reasons)
        }
        if let health = search.health {
            evidence.append("registry_tools=\(health.registryToolCount)")
            evidence.append("indexed_tools=\(health.indexedToolCount)")
            if !health.missingFromIndex.isEmpty {
                append(.staleSearchIndex, to: &reasons)
                evidence.append("missing_from_index=\(health.missingFromIndex.joined(separator: ","))")
            }
            if !health.stale.isEmpty {
                append(.staleSearchIndex, to: &reasons)
                evidence.append("stale_index_entries=\(health.stale.joined(separator: ","))")
            }
            if health.diffSkippedDueToBudget {
                evidence.append("index_diff_skipped=true")
            }
        }
        if let message = search.failureMessage, !message.isEmpty {
            evidence.append(message)
        }

        guard !reasons.isEmpty || includeHealthy else { return nil }

        let status: CapabilityRecoveryStatus =
            if !search.isAvailable { .unavailable } else if reasons.isEmpty { .available } else { .needsReview }
        let summary =
            if search.isAvailable, reasons.isEmpty {
                "Capability search is available."
            } else if reasons.contains(.staleSearchIndex) {
                "Capability search index is stale or incomplete."
            } else {
                "Capability search is unavailable."
            }

        var suggestions: [CapabilityRecoverySuggestion] = []
        if reasons.contains(.unavailableSearch) || reasons.contains(.staleSearchIndex) {
            suggestions.append(
                CapabilityRecoverySuggestion(
                    title: "Rebuild capability search",
                    detail: "Refresh the registry/index snapshot, then re-run discovery before treating any recovered hit as callable.",
                    actionKind: .rebuildSearchIndex,
                    safetyChecks: [.trust, .provenance, .scope, .userPolicy]
                )
            )
        }

        return item(
            subject: .init(kind: .search, identifier: "capability_search", displayName: "Capability search"),
            status: status,
            reasons: reasons,
            summary: summary,
            detail: evidence.joined(separator: "; "),
            suggestions: suggestions,
            evidence: evidence
        )
    }

    // MARK: - Plugins

    private static func makePluginItem(
        _ plugin: PluginCapabilitySnapshot,
        includeHealthy: Bool
    ) -> CapabilityRecoveryItem? {
        var reasons: [CapabilityRecoveryReasonCode] = []
        var evidence: [String] = []

        if !plugin.enabled {
            append(.disabledPlugin, to: &reasons)
        }
        if plugin.trustState == .untrusted || plugin.trustState == .unknown
            || plugin.loadError?.hasPrefix(consentRequiredPrefix) == true {
            append(.untrustedPlugin, to: &reasons)
        }
        if plugin.manifestState == .stale || plugin.manifestState == .missing || plugin.hasStaleDeclaredArtifacts {
            append(.staleManifest, to: &reasons)
        }
        if let loadError = plugin.loadError, !loadError.isEmpty,
            !loadError.hasPrefix(consentRequiredPrefix) {
            append(.pluginLoadFailed, to: &reasons)
            evidence.append(loadError)
        }
        evidence.append("kind=\(plugin.kind.rawValue)")
        evidence.append("trust=\(plugin.trustState.rawValue)")
        evidence.append("manifest=\(plugin.manifestState.rawValue)")
        if let provenance = plugin.provenanceSummary, !provenance.isEmpty {
            evidence.append("provenance=\(provenance)")
        }
        if let scope = plugin.scopeSummary, !scope.isEmpty {
            evidence.append("scope=\(scope)")
        }
        if plugin.hasStaleDeclaredArtifacts {
            evidence.append(
                "declared_tools=\(plugin.declaredToolNames.count), loaded_tools=\(plugin.loadedToolNames.count), declared_mcp=\(plugin.declaredMCPProviderNames.count), loaded_mcp=\(plugin.loadedMCPProviderNames.count)"
            )
        }

        guard !reasons.isEmpty || includeHealthy else { return nil }

        let status: CapabilityRecoveryStatus =
            if reasons.contains(.untrustedPlugin) || reasons.contains(.pluginLoadFailed) {
                .blocked
            } else if reasons.contains(.disabledPlugin) {
                .disabled
            } else if reasons.contains(.staleManifest) {
                .needsReview
            } else {
                .available
            }

        return item(
            subject: .init(kind: .plugin, identifier: plugin.pluginId, displayName: plugin.displayName),
            status: status,
            reasons: reasons,
            summary: pluginSummary(status: status, reasons: reasons),
            detail: evidence.joined(separator: "; "),
            suggestions: suggestions(for: reasons, subject: plugin.displayName),
            evidence: evidence
        )
    }

    // MARK: - MCP Providers

    private static func makeMCPProviderItem(
        _ snapshot: MCPProviderCapabilitySnapshot,
        includeHealthy: Bool
    ) -> CapabilityRecoveryItem? {
        let provider = snapshot.provider
        var reasons: [CapabilityRecoveryReasonCode] = []
        var evidence: [String] = []

        if !provider.enabled {
            append(.disabledProvider, to: &reasons)
        }
        if provider.transport == .stdio,
            provider.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            append(.mcpCommandMissing, to: &reasons)
        }
        if snapshot.state?.requiresAuth == true {
            append(.mcpAuthRequired, to: &reasons)
        }
        if let error = snapshot.state?.lastError, !error.isEmpty {
            append(contentsOf: classifyProviderSymptom(error, mcp: true), to: &reasons)
            evidence.append(error)
        }
        if let probe = snapshot.healthSnapshot?.lastProbe, !probe.succeeded {
            append(contentsOf: classifyMCPProbe(probe), to: &reasons)
            evidence.append(probe.reasonCode.rawValue)
            evidence.append(probe.redactedMessage)
            if let action = probe.redactedAction {
                evidence.append(action)
            }
        }
        appendDiagnostics(snapshot.diagnostics, to: &reasons, evidence: &evidence, mcp: true)

        guard !reasons.isEmpty || includeHealthy else { return nil }

        let status = providerStatus(reasons: reasons, enabled: provider.enabled)
        return item(
            subject: .init(kind: .mcpProvider, identifier: provider.id.uuidString, displayName: provider.name),
            status: status,
            reasons: reasons,
            summary: providerSummary(status: status, providerName: provider.name),
            detail: evidence.joined(separator: "; "),
            suggestions: suggestions(for: reasons, subject: provider.name),
            evidence: evidence
        )
    }

    // MARK: - Remote Providers

    private static func makeRemoteProviderItem(
        _ snapshot: RemoteProviderCapabilitySnapshot,
        includeHealthy: Bool
    ) -> CapabilityRecoveryItem? {
        let provider = snapshot.provider
        var reasons: [CapabilityRecoveryReasonCode] = []
        var evidence: [String] = []

        if !provider.enabled {
            append(.disabledProvider, to: &reasons)
        }
        if let error = snapshot.state?.lastError, !error.isEmpty {
            append(contentsOf: classifyProviderSymptom(error, mcp: false), to: &reasons)
            evidence.append(error)
        }
        appendDiagnostics(snapshot.diagnostics, to: &reasons, evidence: &evidence, mcp: false)

        guard !reasons.isEmpty || includeHealthy else { return nil }

        let status = providerStatus(reasons: reasons, enabled: provider.enabled)
        return item(
            subject: .init(kind: .provider, identifier: provider.id.uuidString, displayName: provider.name),
            status: status,
            reasons: reasons,
            summary: providerSummary(status: status, providerName: provider.name),
            detail: evidence.joined(separator: "; "),
            suggestions: suggestions(for: reasons, subject: provider.name),
            evidence: evidence
        )
    }

    // MARK: - Tools

    private static func makeToolItem(
        _ row: ToolExposureDiagnostic.Row,
        expectation: RequestedToolCapability?,
        search: CapabilityRecoverySearchSnapshot?,
        pluginById: [String: PluginCapabilitySnapshot],
        mcpProviders: [MCPProviderCapabilitySnapshot],
        includeHealthy: Bool
    ) -> CapabilityRecoveryItem? {
        var reasons = reasons(for: row.availability.reasonCodes)
        var evidence = [
            "source=\(row.source.rawValue)",
            "state=\(row.state.rawValue)",
            "availability=\(row.availability.compactSummary)",
            "search=\(row.searchReasonCodes.map(\.rawValue).joined(separator: ","))",
        ]
        var status = status(for: row.state)

        if !row.searchableByCapabilitiesDiscover,
            row.searchReasonCodes.contains(.notIndexed) || search?.isAvailable == false {
            append(search?.isAvailable == false ? .unavailableSearch : .staleSearchIndex, to: &reasons)
        }

        if row.source == .mcpProvider,
            !mcpProviders.isEmpty,
            let group = row.availability.groupName,
            !mcpProviders.contains(where: { namesMatch($0.provider.name, group) }) {
            append(.missingProvider, to: &reasons)
        }

        if let plugin = owningPlugin(for: row, pluginById: pluginById) {
            if !plugin.enabled {
                append(.disabledPlugin, to: &reasons)
            }
            if plugin.trustState == .untrusted || plugin.trustState == .unknown
                || plugin.loadError?.hasPrefix(consentRequiredPrefix) == true {
                append(.untrustedPlugin, to: &reasons)
            }
            if let loadError = plugin.loadError, !loadError.isEmpty,
                !loadError.hasPrefix(consentRequiredPrefix) {
                append(.pluginLoadFailed, to: &reasons)
                evidence.append(loadError)
            }
            if plugin.manifestState == .stale || plugin.manifestState == .missing || plugin.hasStaleDeclaredArtifacts {
                append(.staleManifest, to: &reasons)
            }
            evidence.append("owner=\(plugin.pluginId)")
        }

        if let expectation {
            if let expectedSource = expectation.expectedSource, expectedSource != row.source {
                append(.provenanceScopeMismatch, to: &reasons)
            }
            if let expectedOwner = expectation.expectedOwner,
                !namesMatch(row.availability.groupName, expectedOwner) {
                append(.provenanceScopeMismatch, to: &reasons)
            }
            evidence.append(expectationEvidence(expectation))
        }

        let externallyUnsafe =
            reasons.contains(.untrustedPlugin)
            || reasons.contains(.provenanceScopeMismatch)
            || reasons.contains(.disabledPlugin)
            || reasons.contains(.pluginLoadFailed)
        if externallyUnsafe, row.availability.isCallableNow || row.availability.isLoadableViaCapabilitiesLoad {
            append(.falseAvailablePrevented, to: &reasons)
        }

        status = adjustedToolStatus(status, reasons: reasons)

        guard !reasons.isEmpty || includeHealthy else { return nil }

        return item(
            subject: .init(kind: .tool, identifier: row.toolName, displayName: row.toolName),
            status: status,
            reasons: reasons,
            summary: toolSummary(row: row, status: status, reasons: reasons),
            detail: evidence.joined(separator: "; "),
            suggestions: suggestions(for: reasons, subject: row.toolName),
            evidence: evidence
        )
    }

    private static func makeMissingRequestedToolItem(
        _ expectation: RequestedToolCapability,
        pluginById: [String: PluginCapabilitySnapshot],
        mcpProviders: [MCPProviderCapabilitySnapshot]
    ) -> CapabilityRecoveryItem {
        var reasons: [CapabilityRecoveryReasonCode] = []
        let evidence = [expectationEvidence(expectation), "tool is not registered"]

        if let expectedOwner = expectation.expectedOwner,
            let plugin = pluginById[expectedOwner] {
            if plugin.trustState == .untrusted {
                append(.untrustedPlugin, to: &reasons)
            }
            if !plugin.enabled {
                append(.disabledPlugin, to: &reasons)
            }
            if plugin.manifestState == .stale || plugin.manifestState == .missing || plugin.hasStaleDeclaredArtifacts {
                append(.staleManifest, to: &reasons)
            }
        } else if expectation.expectedSource == .mcpProvider,
            let expectedOwner = expectation.expectedOwner,
            !mcpProviders.isEmpty,
            mcpProviders.contains(where: { namesMatch($0.provider.name, expectedOwner) }) == false {
            append(.missingProvider, to: &reasons)
        }
        if reasons.isEmpty {
            append(.missingProvider, to: &reasons)
        }

        return item(
            subject: .init(kind: .tool, identifier: expectation.toolName, displayName: expectation.toolName),
            status: .unavailable,
            reasons: reasons,
            summary: "The requested tool is not registered in the current capability graph.",
            detail: evidence.joined(separator: "; "),
            suggestions: suggestions(for: reasons, subject: expectation.toolName),
            evidence: evidence
        )
    }

    // MARK: - Mapping

    private static func reasons(
        for availabilityCodes: [ToolAvailabilityReasonCode]
    ) -> [CapabilityRecoveryReasonCode] {
        var reasons: [CapabilityRecoveryReasonCode] = []
        for code in availabilityCodes {
            switch code {
            case .disabled:
                append(.disabledTool, to: &reasons)
            case .permissionBlocked:
                append(.disabledPermissionPolicy, to: &reasons)
            case .missingPermission:
                append(.missingSystemPermission, to: &reasons)
            case .notInstalled, .notRegistered:
                append(.missingProvider, to: &reasons)
            case .hiddenByAgentScope, .hiddenByExecutionMode, .notSelectedByPreflight:
                append(.provenanceScopeMismatch, to: &reasons)
            case .pluginConfigRequired:
                append(.providerConfigurationInvalid, to: &reasons)
            case .available, .alreadyLoaded, .loadableViaCapabilitiesLoad:
                break
            }
        }
        return reasons
    }

    private static func classifyMCPProbe(_ probe: MCPProviderProbeResult) -> [CapabilityRecoveryReasonCode] {
        switch probe.reasonCode {
        case .authRequired:
            return [.mcpAuthRequired]
        case .sandboxUnavailable:
            return [.sandboxUnavailable]
        case .missingCommand:
            return [.mcpCommandMissing]
        case .commandNotFound:
            return [.mcpCommandNotFound]
        case .invalidURL:
            return [.providerConfigurationInvalid]
        case .spawnFailed, .timeout, .protocolError, .connectionFailed, .unknownFailure:
            return [.mcpProbeFailed]
        case .succeeded:
            return []
        }
    }

    private static func classifyProviderSymptom(_ message: String, mcp: Bool) -> [CapabilityRecoveryReasonCode] {
        let lower = message.lowercased()
        if matchesAuthSymptom(lower) {
            return [mcp ? .mcpAuthRequired : .providerAuthRequired]
        }
        if lower.contains("missing command") {
            return [mcp ? .mcpCommandMissing : .providerConfigurationInvalid]
        }
        if lower.contains("invalid url") || lower.contains("malformed") {
            return [.providerConfigurationInvalid]
        }
        if lower.contains("sandbox") {
            return [.sandboxUnavailable]
        }
        return [mcp ? .mcpProbeFailed : .providerConnectivityFailed]
    }

    private static func appendDiagnostics(
        _ diagnostics: ProviderDiagnosticReport?,
        to reasons: inout [CapabilityRecoveryReasonCode],
        evidence: inout [String],
        mcp: Bool
    ) {
        guard let diagnostics else { return }
        for row in diagnostics.rows where row.severity == .blocked || row.severity == .warning {
            evidence.append("\(row.id)=\(row.value)")
            if let detail = row.detail {
                evidence.append(detail)
            }
            if let action = row.action {
                evidence.append(action)
            }

            let haystack = [row.id, row.title, row.value, row.detail ?? "", row.action ?? ""]
                .joined(separator: " ")
                .lowercased()
            if matchesAuthSymptom(haystack) || haystack.contains("sign-in") {
                append(mcp ? .mcpAuthRequired : .providerAuthRequired, to: &reasons)
            } else if haystack.contains("disabled") {
                append(.disabledProvider, to: &reasons)
            } else if haystack.contains("sandbox") {
                append(.sandboxUnavailable, to: &reasons)
            } else if matchesInvalidConfigurationSymptom(haystack) {
                append(.providerConfigurationInvalid, to: &reasons)
            } else {
                append(mcp ? .mcpProbeFailed : .providerConnectivityFailed, to: &reasons)
            }
        }
    }

    private static func status(for rowState: ToolExposureState) -> CapabilityRecoveryStatus {
        switch rowState {
        case .exposed: return .available
        case .loadable: return .loadable
        case .hidden: return .hidden
        case .disabled: return .disabled
        case .blocked: return .blocked
        case .unavailable: return .unavailable
        }
    }

    private static func adjustedToolStatus(
        _ base: CapabilityRecoveryStatus,
        reasons: [CapabilityRecoveryReasonCode]
    ) -> CapabilityRecoveryStatus {
        if reasons.contains(.untrustedPlugin)
            || reasons.contains(.provenanceScopeMismatch)
            || reasons.contains(.falseAvailablePrevented)
            || reasons.contains(.disabledPermissionPolicy)
            || reasons.contains(.pluginLoadFailed)
            || reasons.contains(.missingSystemPermission) {
            return .blocked
        }
        if reasons.contains(.disabledTool) || reasons.contains(.disabledPlugin) {
            return .disabled
        }
        if reasons.contains(.missingProvider) || reasons.contains(.unavailableSearch) {
            return .unavailable
        }
        if reasons.contains(.staleManifest) || reasons.contains(.staleSearchIndex) {
            return .needsReview
        }
        return base
    }

    private static func providerStatus(
        reasons: [CapabilityRecoveryReasonCode],
        enabled: Bool
    ) -> CapabilityRecoveryStatus {
        if !enabled || reasons.contains(.disabledProvider) {
            return .disabled
        }
        if reasons.contains(.providerConfigurationInvalid) {
            return .blocked
        }
        if reasons.contains(.mcpAuthRequired) || reasons.contains(.providerAuthRequired)
            || reasons.contains(.sandboxUnavailable) || reasons.contains(.mcpCommandMissing)
            || reasons.contains(.mcpCommandNotFound) {
            return .blocked
        }
        if reasons.contains(.mcpProbeFailed) || reasons.contains(.providerConnectivityFailed) {
            return .unavailable
        }
        return .available
    }

    // MARK: - Suggestions

    private static func suggestions(
        for reasons: [CapabilityRecoveryReasonCode],
        subject: String
    ) -> [CapabilityRecoverySuggestion] {
        var suggestions: [CapabilityRecoverySuggestion] = []

        if reasons.contains(.disabledTool) || reasons.contains(.disabledPlugin) {
            suggestions.append(
                CapabilityRecoverySuggestion(
                    title: "Review before enabling",
                    detail: "Re-check trust, provenance, agent scope, and the user's policy before enabling \(subject).",
                    actionKind: .reviewUserPolicy,
                    safetyChecks: guardedEnableChecks
                )
            )
        }
        if reasons.contains(.disabledPermissionPolicy) {
            suggestions.append(
                CapabilityRecoverySuggestion(
                    title: "Respect the deny policy",
                    detail: "Only change the tool policy after confirming the user intended this exact tool, owner, and scope.",
                    actionKind: .reviewUserPolicy,
                    safetyChecks: guardedEnableChecks
                )
            )
        }
        if reasons.contains(.missingSystemPermission) {
            suggestions.append(
                CapabilityRecoverySuggestion(
                    title: "Review OS permission",
                    detail: "Open the relevant macOS privacy pane, then grant only the named permission after verifying this tool's owner and requested action.",
                    actionKind: .grantSystemPermission,
                    safetyChecks: [.trust, .provenance, .scope, .userPolicy]
                )
            )
        }
        if reasons.contains(.untrustedPlugin) {
            suggestions.append(
                CapabilityRecoverySuggestion(
                    title: "Review plugin trust",
                    detail: "Verify the plugin receipt, source provenance, and requested scope before allowing it to load.",
                    actionKind: .reviewTrust,
                    safetyChecks: [.trust, .provenance, .scope, .userPolicy]
                )
            )
        }
        if reasons.contains(.staleManifest) {
            suggestions.append(
                CapabilityRecoverySuggestion(
                    title: "Refresh manifest after review",
                    detail: "Refresh or reinstall only after confirming the source still matches the trusted plugin provenance.",
                    actionKind: .refreshManifest,
                    safetyChecks: [.trust, .provenance, .scope, .userPolicy]
                )
            )
        }
        if reasons.contains(.provenanceScopeMismatch) || reasons.contains(.falseAvailablePrevented) {
            suggestions.append(
                CapabilityRecoverySuggestion(
                    title: "Re-check provenance and scope",
                    detail: "Do not use a same-named capability until the owner, provider, and agent scope match the request.",
                    actionKind: .reviewScope,
                    safetyChecks: [.trust, .provenance, .scope, .userPolicy]
                )
            )
        }
        if reasons.contains(.missingProvider) {
            suggestions.append(
                CapabilityRecoverySuggestion(
                    title: "Configure the missing owner",
                    detail: "Install or reconnect the owning plugin/provider, then re-run discovery and trust checks.",
                    actionKind: .configureProvider,
                    safetyChecks: guardedEnableChecks + [.credentials]
                )
            )
        }
        if reasons.contains(.unavailableSearch) || reasons.contains(.staleSearchIndex) {
            suggestions.append(
                CapabilityRecoverySuggestion(
                    title: "Rebuild search and rediscover",
                    detail: "Rebuild capability search, then verify the recovered hit still passes trust, provenance, scope, and policy gates.",
                    actionKind: .rebuildSearchIndex,
                    safetyChecks: guardedEnableChecks
                )
            )
        }
        if reasons.contains(.mcpAuthRequired) || reasons.contains(.providerAuthRequired) {
            suggestions.append(
                CapabilityRecoverySuggestion(
                    title: "Authenticate provider",
                    detail: "Sign in or save credentials for the expected provider, then test before exposing its tools.",
                    actionKind: .authenticateProvider,
                    safetyChecks: [.provenance, .scope, .userPolicy, .credentials]
                )
            )
        }
        if reasons.contains(.sandboxUnavailable) {
            suggestions.append(
                CapabilityRecoverySuggestion(
                    title: "Start or repair sandbox",
                    detail: "Start the sandbox only after confirming the provider is expected to run there.",
                    actionKind: .startSandbox,
                    safetyChecks: [.trust, .provenance, .scope, .sandboxPolicy]
                )
            )
        }
        if reasons.contains(.mcpCommandMissing) || reasons.contains(.mcpCommandNotFound)
            || reasons.contains(.mcpProbeFailed) {
            suggestions.append(
                CapabilityRecoverySuggestion(
                    title: "Run an MCP probe",
                    detail: "Test initialize/listTools and review the redacted probe result before exposing MCP tools.",
                    actionKind: .runProbe,
                    safetyChecks: [.trust, .provenance, .scope, .userPolicy]
                )
            )
        }
        if reasons.contains(.providerConnectivityFailed) || reasons.contains(.providerConfigurationInvalid) {
            suggestions.append(
                CapabilityRecoverySuggestion(
                    title: "Test provider configuration",
                    detail: "Use the provider test path and review redacted diagnostics before selecting its models or tools.",
                    actionKind: .configureProvider,
                    safetyChecks: [.provenance, .scope, .userPolicy, .credentials]
                )
            )
        }
        if reasons.contains(.pluginLoadFailed) {
            suggestions.append(
                CapabilityRecoverySuggestion(
                    title: "Inspect plugin load failure",
                    detail: "Fix the load error without bypassing receipt, signature, consent, or provenance checks.",
                    actionKind: .inspect,
                    safetyChecks: [.trust, .provenance, .scope, .userPolicy]
                )
            )
        }

        return dedupe(suggestions)
    }

    private static let guardedEnableChecks: [CapabilityRecoverySafetyCheck] = [
        .trust, .provenance, .scope, .userPolicy,
    ]
    private static let consentRequiredPrefix = "consent_required:"

    // MARK: - Summaries

    private static func toolSummary(
        row: ToolExposureDiagnostic.Row,
        status: CapabilityRecoveryStatus,
        reasons: [CapabilityRecoveryReasonCode]
    ) -> String {
        if reasons.contains(.falseAvailablePrevented) {
            return "The tool looked \(row.state.rawValue), but recovery blocked it because trust, provenance, or scope did not match."
        }
        if reasons.contains(.disabledPermissionPolicy) {
            return "The tool is blocked by the user's permission policy."
        }
        if reasons.contains(.missingSystemPermission) {
            return "The tool is missing required system permission."
        }
        if reasons.contains(.unavailableSearch) || reasons.contains(.staleSearchIndex) {
            return "The tool is not safely discoverable through capability search."
        }
        if reasons.contains(.missingProvider) {
            return "The tool's owning plugin or provider is missing from the current registry."
        }
        return "Tool recovery status is \(status.displayLabel.lowercased())."
    }

    private static func pluginSummary(
        status: CapabilityRecoveryStatus,
        reasons: [CapabilityRecoveryReasonCode]
    ) -> String {
        if reasons.contains(.untrustedPlugin) {
            return "Plugin loading is blocked until trust is reviewed."
        }
        if reasons.contains(.staleManifest) {
            return "Plugin manifest or imported artifact state is stale."
        }
        if reasons.contains(.disabledPlugin) {
            return "Plugin is disabled."
        }
        if reasons.contains(.pluginLoadFailed) {
            return "Plugin failed to load."
        }
        return "Plugin recovery status is \(status.displayLabel.lowercased())."
    }

    private static func providerSummary(
        status: CapabilityRecoveryStatus,
        providerName: String
    ) -> String {
        "Provider \(providerName) recovery status is \(status.displayLabel.lowercased())."
    }

    // MARK: - Helpers

    private static func owningPlugin(
        for row: ToolExposureDiagnostic.Row,
        pluginById: [String: PluginCapabilitySnapshot]
    ) -> PluginCapabilitySnapshot? {
        guard row.source == .plugin || row.source == .sandboxPlugin else { return nil }
        guard let group = row.availability.groupName else { return nil }
        return pluginById[group]
    }

    private static func expectationEvidence(_ expectation: RequestedToolCapability) -> String {
        var parts = ["expected_tool=\(expectation.toolName)"]
        if let source = expectation.expectedSource {
            parts.append("expected_source=\(source.rawValue)")
        }
        if let owner = expectation.expectedOwner {
            parts.append("expected_owner=\(owner)")
        }
        return parts.joined(separator: ",")
    }

    private static func item(
        subject: CapabilityRecoverySubject,
        status: CapabilityRecoveryStatus,
        reasons: [CapabilityRecoveryReasonCode],
        summary: String,
        detail: String,
        suggestions: [CapabilityRecoverySuggestion],
        evidence: [String]
    ) -> CapabilityRecoveryItem {
        let redactedSubject = CapabilityRecoverySubject(
            kind: subject.kind,
            identifier: subject.identifier,
            displayName: CapabilityRecoveryRedactor.safe(subject.displayName)
        )
        return CapabilityRecoveryItem(
            subject: redactedSubject,
            status: status,
            reasonCodes: dedupe(reasons),
            summary: CapabilityRecoveryRedactor.safe(summary),
            detail: CapabilityRecoveryRedactor.safe(detail),
            suggestions: dedupe(suggestions).map(redacted),
            evidence: evidence.map { CapabilityRecoveryRedactor.safe($0) }
        )
    }

    private static func redacted(_ suggestion: CapabilityRecoverySuggestion) -> CapabilityRecoverySuggestion {
        CapabilityRecoverySuggestion(
            title: CapabilityRecoveryRedactor.safe(suggestion.title),
            detail: CapabilityRecoveryRedactor.safe(suggestion.detail),
            actionKind: suggestion.actionKind,
            safetyChecks: suggestion.safetyChecks,
            autoApplies: suggestion.autoApplies
        )
    }

    private static func append(
        _ reason: CapabilityRecoveryReasonCode,
        to reasons: inout [CapabilityRecoveryReasonCode]
    ) {
        if !reasons.contains(reason) {
            reasons.append(reason)
        }
    }

    private static func append(
        contentsOf newReasons: [CapabilityRecoveryReasonCode],
        to reasons: inout [CapabilityRecoveryReasonCode]
    ) {
        for reason in newReasons {
            append(reason, to: &reasons)
        }
    }

    private static func dedupe<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func dedupe(_ suggestions: [CapabilityRecoverySuggestion]) -> [CapabilityRecoverySuggestion] {
        var seen = Set<String>()
        return suggestions.filter { seen.insert($0.id).inserted }
    }

    private static func sortedDeduped(_ items: [CapabilityRecoveryItem]) -> [CapabilityRecoveryItem] {
        var seen = Set<String>()
        return items
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if kindRank(lhs.subject.kind) == kindRank(rhs.subject.kind) {
                    return lhs.subject.displayName.localizedCaseInsensitiveCompare(rhs.subject.displayName)
                        == .orderedAscending
                }
                return kindRank(lhs.subject.kind) < kindRank(rhs.subject.kind)
            }
    }

    private static func kindRank(_ kind: CapabilityRecoverySubjectKind) -> Int {
        switch kind {
        case .search: return 0
        case .tool: return 1
        case .plugin: return 2
        case .mcpProvider: return 3
        case .provider: return 4
        }
    }

    private static func matchesAuthSymptom(_ lowercasedMessage: String) -> Bool {
        matches(
            lowercasedMessage,
            pattern: #"(?i)(^|[^A-Za-z0-9])(401|403|unauthorized|forbidden|auth|authentication|authorization|oauth|api[-_ ]?key|bearer|token expired|invalid token)([^A-Za-z0-9]|$)"#
        )
    }

    private static func matchesInvalidConfigurationSymptom(_ lowercasedMessage: String) -> Bool {
        matches(
            lowercasedMessage,
            pattern: #"(?i)(^|[^A-Za-z0-9])(invalid url|invalid configuration|malformed|missing command)([^A-Za-z0-9]|$)"#
        )
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    private static func namesMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        normalize(lhs) == normalize(rhs)
    }

    private static func normalize(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }
}

enum CapabilityRecoveryRedactor {
    static func safe(_ raw: String, maxLength: Int = 700) -> String {
        var value = raw
        let replacements: [(pattern: String, template: String)] = [
            (#"(?i)\b(authorization)\s*[:=]\s*(?:bearer\s+)?[^\s,;}]+\"?"#, "$1=***"),
            (#"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]+"#, "$1 ***"),
            (
                #"(?i)\"(access_token|refresh_token|code_verifier|code|verifier|client_secret|api_key|apikey|password|secret|token)\"\s*:\s*\"[^\"]*\""#,
                #""$1":"***""#
            ),
            (
                #"(?i)\b(access_token|refresh_token|code_verifier|code|verifier|client_secret|api_key|apikey|password|secret|token)\s*=\s*([^&\s,;}]+)"#,
                "$1=***"
            ),
            (#"(?i)\b(api[_-]?key|password|secret|token|client_secret)\s*:\s*([^\s,;}]+)"#, "$1=***"),
            (#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, "jwt=***"),
            (#"file://[^\s,;)]+\"?"#, "[path]"),
            (#"(^|[\s(=:\["'])/(Users|private|var|tmp|Volumes|Applications|opt|usr|etc)/[^\s,;)\"']+\"?"#, "$1[path]"),
            (#"(^|[\s(=:\["'])~/(?:[^\s,;)\"']+)"#, "$1[path]"),
            (#"\[path\]\s+Support/[^\s,;)\"']+"#, "[path]"),
            (#"https?://[^\s,;)]+\"?"#, "[url]"),
        ]

        for replacement in replacements {
            value = replaceMatches(
                in: value,
                pattern: replacement.pattern,
                template: replacement.template
            )
        }

        value = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while value.contains("  ") {
            value = value.replacingOccurrences(of: "  ", with: " ")
        }
        if value.count > maxLength {
            return String(value.prefix(maxLength)) + "..."
        }
        return value
    }

    private static func replaceMatches(
        in value: String,
        pattern: String,
        template: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }
}
