//
//  MCPServerHub.swift
//  OsaurusCore
//
//  Aggregates MCP provider health for the Management provider dashboard.
//

import Foundation

public struct MCPProviderCredentialPresence: Sendable, Equatable {
    public var bearerTokenPresent: Bool
    public var oauthTokensPresent: Bool

    public init(bearerTokenPresent: Bool = false, oauthTokensPresent: Bool = false) {
        self.bearerTokenPresent = bearerTokenPresent
        self.oauthTokensPresent = oauthTokensPresent
    }
}

public enum MCPServerHubStatus: String, Sendable, Equatable, CaseIterable {
    case connected
    case connecting
    case needsAttention
    case disabled
    case idle

    public var displayName: String {
        switch self {
        case .connected: return L("Connected")
        case .connecting: return L("Connecting")
        case .needsAttention: return L("Needs attention")
        case .disabled: return L("Disabled")
        case .idle: return L("Ready")
        }
    }
}

public enum MCPServerHubFilter: String, Sendable, Equatable, CaseIterable {
    case all
    case attention
    case connected
    case stdio
    case http
    case disabled

    public var displayName: String {
        switch self {
        case .all: return L("All")
        case .attention: return L("Attention")
        case .connected: return L("Connected")
        case .stdio: return L("Stdio")
        case .http: return L("HTTP")
        case .disabled: return L("Disabled")
        }
    }

    public func includes(_ report: MCPServerHubProviderReport) -> Bool {
        switch self {
        case .all:
            return true
        case .attention:
            return report.hasAttention
        case .connected:
            return report.status == .connected
        case .stdio:
            return report.provider.transport == .stdio
        case .http:
            return report.provider.transport == .http
        case .disabled:
            return report.status == .disabled
        }
    }
}

public struct MCPServerHubProviderReport: Identifiable, Sendable {
    public let id: UUID
    public let provider: MCPProvider
    public let state: MCPProviderState?
    public let diagnostics: ProviderDiagnosticReport
    public let healthSnapshot: MCPProviderHealthSnapshot?
    public let status: MCPServerHubStatus
    public let highestSeverity: ProviderDiagnosticSeverity
    public let summary: String
    public let recommendedAction: String?
    public let toolCount: Int

    public var hasAttention: Bool {
        status == .needsAttention
            || (provider.enabled && (highestSeverity == .blocked || highestSeverity == .warning))
    }
}

public struct MCPServerHubSnapshot: Sendable {
    public let reports: [MCPServerHubProviderReport]
    public let proxy: GlobalProxyDiagnosticState

    public var totalCount: Int { reports.count }
    public var enabledCount: Int { reports.filter { $0.provider.enabled }.count }
    public var connectedCount: Int { reports.filter { $0.status == .connected }.count }
    public var connectingCount: Int { reports.filter { $0.status == .connecting }.count }
    public var attentionCount: Int { reports.filter(\.hasAttention).count }
    public var disabledCount: Int { reports.filter { $0.status == .disabled }.count }
    public var httpCount: Int { reports.filter { $0.provider.transport == .http }.count }
    public var stdioCount: Int { reports.filter { $0.provider.transport == .stdio }.count }
    public var hostStdioCount: Int {
        reports.filter { $0.provider.transport == .stdio && $0.provider.executionHost == .host }.count
    }
    public var sandboxStdioCount: Int {
        reports.filter { $0.provider.transport == .stdio && $0.provider.executionHost == .sandbox }.count
    }
    public var toolCount: Int { reports.reduce(0) { $0 + $1.toolCount } }

    public var highestSeverity: ProviderDiagnosticSeverity {
        let actionableReports = reports.filter(\.hasAttention)
        guard !actionableReports.isEmpty else {
            return connectedCount > 0 ? .ok : .info
        }
        return actionableReports.map(\.highestSeverity).max(by: mcpSeverityLessThan) ?? .info
    }

    public func filtered(by filter: MCPServerHubFilter) -> [MCPServerHubProviderReport] {
        reports.filter { filter.includes($0) }
    }

    public var pasteboardText: String {
        var lines = [
            L("MCP Server Hub diagnostics"),
            L(
                "\(connectedCount)/\(totalCount) connected, \(attentionCount) attention, \(toolCount) tools, \(stdioCount) stdio provider(s)"
            ),
            L("Global proxy: \(proxy.summaryText)"),
        ]

        for report in reports {
            lines.append("")
            lines.append(report.diagnostics.pasteboardText)
            if let probe = report.healthSnapshot?.lastProbe {
                lines.append("")
                lines.append(probe.pasteboardText)
            }
        }
        return lines.joined(separator: "\n")
    }
}

public enum MCPServerHub {
    public static func snapshot(
        providers: [MCPProvider],
        states: [UUID: MCPProviderState],
        proxy: GlobalProxyDiagnosticState,
        credentialsByProvider: [UUID: MCPProviderCredentialPresence],
        healthSnapshots: [UUID: MCPProviderHealthSnapshot]
    ) -> MCPServerHubSnapshot {
        let reports = providers.map { provider in
            providerReport(
                provider: provider,
                state: states[provider.id],
                proxy: proxy,
                credentialPresence: credentialsByProvider[provider.id] ?? MCPProviderCredentialPresence(),
                healthSnapshot: healthSnapshots[provider.id]
            )
        }
        return MCPServerHubSnapshot(reports: reports, proxy: proxy)
    }

    public static func providerReport(
        provider: MCPProvider,
        state: MCPProviderState?,
        proxy: GlobalProxyDiagnosticState,
        credentialPresence: MCPProviderCredentialPresence,
        healthSnapshot: MCPProviderHealthSnapshot?
    ) -> MCPServerHubProviderReport {
        let baseReport = ProviderNetworkDiagnostics.mcpProviderReport(
            provider: provider,
            state: state,
            proxy: proxy,
            bearerTokenPresent: credentialPresence.bearerTokenPresent,
            oauthTokensPresent: credentialPresence.oauthTokensPresent
        )
        let diagnostics = MCPLocalProviderDiagnostics.augment(
            report: baseReport,
            provider: provider,
            healthSnapshot: healthSnapshot
        )
        let severity = diagnostics.rows.map(\.severity).max(by: mcpSeverityLessThan) ?? .info
        let status = status(for: provider, state: state, highestSeverity: severity)
        let firstActionableRow =
            diagnostics.rows.first { $0.severity == .blocked }
            ?? diagnostics.rows.first { provider.enabled && $0.severity == .warning }
        let summaryRow =
            firstActionableRow
            ?? diagnostics.rows.first { $0.id == "local-health" }
            ?? diagnostics.rows.first { $0.id == "connection" }

        return MCPServerHubProviderReport(
            id: provider.id,
            provider: provider,
            state: state,
            diagnostics: diagnostics,
            healthSnapshot: healthSnapshot,
            status: status,
            highestSeverity: severity,
            summary: summary(for: summaryRow, fallback: status.displayName),
            recommendedAction: firstActionableRow?.action,
            toolCount: state?.discoveredToolCount ?? healthSnapshot?.lastProbe.toolCount ?? 0
        )
    }

    private static func status(
        for provider: MCPProvider,
        state: MCPProviderState?,
        highestSeverity: ProviderDiagnosticSeverity
    ) -> MCPServerHubStatus {
        guard provider.enabled else { return .disabled }
        if state?.isConnecting == true { return .connecting }
        if state?.isConnected == true { return .connected }
        if state?.requiresAuth == true
            || state?.lastError?.isEmpty == false
            || highestSeverity == .blocked
            || highestSeverity == .warning
        {
            return .needsAttention
        }
        return .idle
    }

    private static func summary(for row: ProviderDiagnosticRow?, fallback: String) -> String {
        guard let row else { return fallback }
        if let detail = row.detail, !detail.isEmpty {
            return "\(row.title): \(row.value) - \(detail)"
        }
        return "\(row.title): \(row.value)"
    }
}

private func mcpSeverityLessThan(_ lhs: ProviderDiagnosticSeverity, _ rhs: ProviderDiagnosticSeverity) -> Bool {
    mcpSeverityRank(lhs) < mcpSeverityRank(rhs)
}

private func mcpSeverityRank(_ severity: ProviderDiagnosticSeverity) -> Int {
    switch severity {
    case .ok:
        return 0
    case .info:
        return 1
    case .warning:
        return 2
    case .blocked:
        return 3
    }
}

private extension GlobalProxyDiagnosticState {
    var summaryText: String {
        switch self {
        case .disabled:
            return L("Disabled")
        case .active(let url):
            return url
        case .invalid(let reason):
            return L("Ignored - \(reason)")
        }
    }
}
