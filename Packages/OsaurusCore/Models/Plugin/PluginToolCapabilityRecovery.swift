//
//  PluginToolCapabilityRecovery.swift
//  osaurus
//
//  Read-only diagnostic models for explaining why plugin, tool, search,
//  MCP, and provider capabilities are not currently usable.
//

import Foundation

enum CapabilityRecoverySubjectKind: String, CaseIterable, Sendable {
    case tool
    case plugin
    case search
    case mcpProvider = "mcp_provider"
    case provider

    var displayLabel: String {
        switch self {
        case .tool: return "Tool"
        case .plugin: return "Plugin"
        case .search: return "Search"
        case .mcpProvider: return "MCP provider"
        case .provider: return "Provider"
        }
    }
}

struct CapabilityRecoverySubject: Equatable, Identifiable, Sendable {
    let kind: CapabilityRecoverySubjectKind
    let identifier: String
    let displayName: String

    var id: String { "\(kind.rawValue):\(identifier)" }

    init(kind: CapabilityRecoverySubjectKind, identifier: String, displayName: String? = nil) {
        self.kind = kind
        self.identifier = identifier
        self.displayName = displayName ?? identifier
    }
}

enum CapabilityRecoveryStatus: String, CaseIterable, Sendable {
    case available
    case loadable
    case hidden
    case disabled
    case blocked
    case unavailable
    case needsReview = "needs_review"

    var displayLabel: String {
        switch self {
        case .available: return "Available"
        case .loadable: return "Loadable"
        case .hidden: return "Hidden"
        case .disabled: return "Disabled"
        case .blocked: return "Blocked"
        case .unavailable: return "Unavailable"
        case .needsReview: return "Needs review"
        }
    }
}

enum CapabilityRecoveryReasonCode: String, CaseIterable, Sendable {
    case disabledTool = "disabled_tool"
    case disabledPlugin = "disabled_plugin"
    case disabledPermissionPolicy = "disabled_permission_policy"
    case missingSystemPermission = "missing_system_permission"
    case missingProvider = "missing_provider"
    case disabledProvider = "disabled_provider"
    case unavailableSearch = "unavailable_search"
    case staleSearchIndex = "stale_search_index"
    case staleManifest = "stale_manifest"
    case untrustedPlugin = "untrusted_plugin"
    case provenanceScopeMismatch = "provenance_scope_mismatch"
    case sandboxUnavailable = "sandbox_unavailable"
    case mcpAuthRequired = "mcp_auth_required"
    case mcpCommandMissing = "mcp_command_missing"
    case mcpCommandNotFound = "mcp_command_not_found"
    case mcpProbeFailed = "mcp_probe_failed"
    case providerAuthRequired = "provider_auth_required"
    case providerConnectivityFailed = "provider_connectivity_failed"
    case providerConfigurationInvalid = "provider_configuration_invalid"
    case pluginLoadFailed = "plugin_load_failed"
    case falseAvailablePrevented = "false_available_prevented"
}

enum CapabilityRecoveryActionKind: String, CaseIterable, Sendable {
    case inspect
    case rebuildSearchIndex = "rebuild_search_index"
    case refreshManifest = "refresh_manifest"
    case reviewTrust = "review_trust"
    case reviewScope = "review_scope"
    case reviewUserPolicy = "review_user_policy"
    case grantSystemPermission = "grant_system_permission"
    case configureProvider = "configure_provider"
    case authenticateProvider = "authenticate_provider"
    case runProbe = "run_probe"
    case startSandbox = "start_sandbox"
    case reinstallAfterReview = "reinstall_after_review"
}

enum CapabilityRecoverySafetyCheck: String, CaseIterable, Sendable {
    case trust
    case provenance
    case scope
    case userPolicy = "user_policy"
    case credentials
    case sandboxPolicy = "sandbox_policy"
}

struct CapabilityRecoverySuggestion: Equatable, Identifiable, Sendable {
    let title: String
    let detail: String
    let actionKind: CapabilityRecoveryActionKind
    let safetyChecks: [CapabilityRecoverySafetyCheck]
    let autoApplies: Bool

    var id: String {
        "\(actionKind.rawValue):\(title):\(detail)"
    }

    init(
        title: String,
        detail: String,
        actionKind: CapabilityRecoveryActionKind,
        safetyChecks: [CapabilityRecoverySafetyCheck] = [],
        autoApplies: Bool = false
    ) {
        self.title = title
        self.detail = detail
        self.actionKind = actionKind
        self.safetyChecks = safetyChecks
        self.autoApplies = autoApplies
    }
}

struct CapabilityRecoveryItem: Equatable, Identifiable, Sendable {
    let subject: CapabilityRecoverySubject
    let status: CapabilityRecoveryStatus
    let reasonCodes: [CapabilityRecoveryReasonCode]
    let summary: String
    let detail: String
    let suggestions: [CapabilityRecoverySuggestion]
    let evidence: [String]

    var id: String { subject.id }

    var isUsableNow: Bool {
        status == .available || status == .loadable
    }

    var needsUserAction: Bool {
        !isUsableNow || !suggestions.isEmpty
    }

    func containsReason(_ reason: CapabilityRecoveryReasonCode) -> Bool {
        reasonCodes.contains(reason)
    }
}

struct PluginToolCapabilityRecoveryReport: Sendable {
    let generatedAt: Date
    let items: [CapabilityRecoveryItem]

    init(generatedAt: Date = Date(), items: [CapabilityRecoveryItem]) {
        self.generatedAt = generatedAt
        self.items = items
    }

    var blockingCount: Int {
        items.filter { $0.status == .blocked || $0.status == .unavailable }.count
    }

    var actionableItems: [CapabilityRecoveryItem] {
        items.filter(\.needsUserAction)
    }

    var actionableCount: Int {
        actionableItems.count
    }

    func items(containing reason: CapabilityRecoveryReasonCode) -> [CapabilityRecoveryItem] {
        items.filter { $0.reasonCodes.contains(reason) }
    }

    func item(kind: CapabilityRecoverySubjectKind, identifier: String) -> CapabilityRecoveryItem? {
        items.first { $0.subject.kind == kind && $0.subject.identifier == identifier }
    }

    var reporterSafeMarkdown: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var lines = [
            "# Plugin and Tool Capability Recovery Report",
            "",
            "- Generated: \(formatter.string(from: generatedAt))",
            "- Items: \(items.count)",
            "- Blocking: \(blockingCount)",
            "- Reporter-safe fields only: no raw secrets, provider URLs, manifest paths, runtime paths, or schema payloads.",
            "",
            "| Subject | Status | Reasons | Summary | Suggestions |",
            "| --- | --- | --- | --- | --- |",
        ]

        for item in items {
            let subject = "\(item.subject.kind.rawValue)/\(CapabilityRecoveryRedactor.safe(item.subject.displayName))"
            let reasons = item.reasonCodes.map(\.rawValue).joined(separator: ", ")
            let suggestions = item.suggestions.map(\.title).joined(separator: "; ")
            lines.append(
                "| \(Self.escape(subject)) | \(item.status.rawValue) | \(Self.escape(reasons)) | \(Self.escape(item.summary)) | \(Self.escape(suggestions)) |"
            )
        }

        return lines.joined(separator: "\n")
    }

    private static func escape(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

struct PluginToolCapabilityRecoveryRequest: Sendable {
    var requestedTools: [RequestedToolCapability]
    var toolExposure: ToolExposureDiagnostic?
    var search: CapabilityRecoverySearchSnapshot?
    var plugins: [PluginCapabilitySnapshot]
    var mcpProviders: [MCPProviderCapabilitySnapshot]
    var remoteProviders: [RemoteProviderCapabilitySnapshot]
    var includeHealthyItems: Bool

    init(
        requestedTools: [RequestedToolCapability] = [],
        toolExposure: ToolExposureDiagnostic? = nil,
        search: CapabilityRecoverySearchSnapshot? = nil,
        plugins: [PluginCapabilitySnapshot] = [],
        mcpProviders: [MCPProviderCapabilitySnapshot] = [],
        remoteProviders: [RemoteProviderCapabilitySnapshot] = [],
        includeHealthyItems: Bool = false
    ) {
        self.requestedTools = requestedTools
        self.toolExposure = toolExposure
        self.search = search
        self.plugins = plugins
        self.mcpProviders = mcpProviders
        self.remoteProviders = remoteProviders
        self.includeHealthyItems = includeHealthyItems
    }
}

struct RequestedToolCapability: Equatable, Sendable {
    let toolName: String
    let expectedSource: ToolExposureSource?
    let expectedOwner: String?

    init(
        toolName: String,
        expectedSource: ToolExposureSource? = nil,
        expectedOwner: String? = nil
    ) {
        self.toolName = toolName
        self.expectedSource = expectedSource
        self.expectedOwner = expectedOwner
    }
}

struct CapabilityRecoverySearchSnapshot: Sendable {
    let isAvailable: Bool
    let health: CapabilitySearchHealth?
    let failureMessage: String?

    init(
        isAvailable: Bool,
        health: CapabilitySearchHealth? = nil,
        failureMessage: String? = nil
    ) {
        self.isAvailable = isAvailable
        self.health = health
        self.failureMessage = failureMessage
    }
}

enum PluginCapabilityKind: String, CaseIterable, Sendable {
    case native
    case sandbox
    case claude
    case unknown
}

enum PluginTrustState: String, CaseIterable, Sendable {
    case trusted
    case untrusted
    case unknown
}

enum PluginManifestState: String, CaseIterable, Sendable {
    case current
    case stale
    case missing
    case unknown
}

struct PluginCapabilitySnapshot: Sendable {
    let pluginId: String
    let displayName: String
    let kind: PluginCapabilityKind
    let enabled: Bool
    let trustState: PluginTrustState
    let manifestState: PluginManifestState
    let declaredToolNames: [String]
    let loadedToolNames: [String]
    let declaredMCPProviderNames: [String]
    let loadedMCPProviderNames: [String]
    let loadError: String?
    let provenanceSummary: String?
    let scopeSummary: String?

    init(
        pluginId: String,
        displayName: String? = nil,
        kind: PluginCapabilityKind = .unknown,
        enabled: Bool = true,
        trustState: PluginTrustState = .unknown,
        manifestState: PluginManifestState = .unknown,
        declaredToolNames: [String] = [],
        loadedToolNames: [String] = [],
        declaredMCPProviderNames: [String] = [],
        loadedMCPProviderNames: [String] = [],
        loadError: String? = nil,
        provenanceSummary: String? = nil,
        scopeSummary: String? = nil
    ) {
        self.pluginId = pluginId
        self.displayName = displayName ?? pluginId
        self.kind = kind
        self.enabled = enabled
        self.trustState = trustState
        self.manifestState = manifestState
        self.declaredToolNames = declaredToolNames
        self.loadedToolNames = loadedToolNames
        self.declaredMCPProviderNames = declaredMCPProviderNames
        self.loadedMCPProviderNames = loadedMCPProviderNames
        self.loadError = loadError
        self.provenanceSummary = provenanceSummary
        self.scopeSummary = scopeSummary
    }

    init(
        snapshot: ClaudePluginManifestSnapshot,
        loadedMCPProviderNames: [String] = [],
        trustState: PluginTrustState = .unknown,
        manifestState: PluginManifestState = .current,
        loadError: String? = nil
    ) {
        self.init(
            pluginId: snapshot.pluginId,
            displayName: snapshot.displayName,
            kind: .claude,
            enabled: true,
            trustState: trustState,
            manifestState: manifestState,
            declaredMCPProviderNames: Array(repeating: "mcp", count: snapshot.declaredCounts.mcp),
            loadedMCPProviderNames: loadedMCPProviderNames,
            loadError: loadError,
            provenanceSummary: "\(snapshot.sourceOwner)/\(snapshot.sourceRepo)",
            scopeSummary: snapshot.sourcePath
        )
    }

    var hasStaleDeclaredArtifacts: Bool {
        Set(declaredToolNames).subtracting(loadedToolNames).isEmpty == false
            || declaredMCPProviderNames.count > loadedMCPProviderNames.count
    }
}

struct MCPProviderCapabilitySnapshot: Sendable {
    let provider: MCPProvider
    let state: MCPProviderState?
    let diagnostics: ProviderDiagnosticReport?
    let healthSnapshot: MCPProviderHealthSnapshot?

    init(
        provider: MCPProvider,
        state: MCPProviderState? = nil,
        diagnostics: ProviderDiagnosticReport? = nil,
        healthSnapshot: MCPProviderHealthSnapshot? = nil
    ) {
        self.provider = provider
        self.state = state
        self.diagnostics = diagnostics
        self.healthSnapshot = healthSnapshot
    }
}

struct RemoteProviderCapabilitySnapshot: Sendable {
    let provider: RemoteProvider
    let state: RemoteProviderState?
    let diagnostics: ProviderDiagnosticReport?

    init(
        provider: RemoteProvider,
        state: RemoteProviderState? = nil,
        diagnostics: ProviderDiagnosticReport? = nil
    ) {
        self.provider = provider
        self.state = state
        self.diagnostics = diagnostics
    }
}
