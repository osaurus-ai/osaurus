//
//  ProviderConnectivityCenter.swift
//  OsaurusCore
//
//  Aggregates remote-provider health for the Settings provider dashboard.
//

import Foundation

public struct RemoteProviderCredentialPresence: Sendable, Equatable {
    public var apiKeyPresent: Bool
    public var oauthTokensPresent: Bool

    public init(apiKeyPresent: Bool = false, oauthTokensPresent: Bool = false) {
        self.apiKeyPresent = apiKeyPresent
        self.oauthTokensPresent = oauthTokensPresent
    }
}

public enum ProviderConnectivityStatus: String, Sendable, Equatable, CaseIterable {
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

public enum ProviderConnectivityFilter: String, Sendable, Equatable, CaseIterable {
    case all
    case attention
    case connected
    case disabled

    public var displayName: String {
        switch self {
        case .all: return L("All")
        case .attention: return L("Attention")
        case .connected: return L("Connected")
        case .disabled: return L("Disabled")
        }
    }

    public func includes(_ report: ProviderConnectivityProviderReport) -> Bool {
        switch self {
        case .all:
            return true
        case .attention:
            return report.status == .needsAttention
                || report.highestSeverity == .blocked
                || report.highestSeverity == .warning
        case .connected:
            return report.status == .connected
        case .disabled:
            return report.status == .disabled
        }
    }
}

public struct ProviderConnectivityProviderReport: Identifiable, Sendable {
    public let id: UUID
    public let provider: RemoteProvider
    public let state: RemoteProviderState?
    public let diagnostics: ProviderDiagnosticReport
    public let status: ProviderConnectivityStatus
    public let highestSeverity: ProviderDiagnosticSeverity
    public let summary: String
    public let recommendedAction: String?
    public let modelCount: Int
    public let manualModelCount: Int

    public var hasAttention: Bool {
        status == .needsAttention || highestSeverity == .blocked || highestSeverity == .warning
    }
}

public struct ProviderConnectivitySnapshot: Sendable {
    public let reports: [ProviderConnectivityProviderReport]
    public let proxy: GlobalProxyDiagnosticState

    public var totalCount: Int { reports.count }
    public var enabledCount: Int { reports.filter { $0.provider.enabled }.count }
    public var connectedCount: Int { reports.filter { $0.status == .connected }.count }
    public var connectingCount: Int { reports.filter { $0.status == .connecting }.count }
    public var attentionCount: Int { reports.filter(\.hasAttention).count }
    public var disabledCount: Int { reports.filter { $0.status == .disabled }.count }
    public var manualModelProviderCount: Int { reports.filter { $0.manualModelCount > 0 }.count }
    public var modelCount: Int { reports.reduce(0) { $0 + $1.modelCount } }

    public var highestSeverity: ProviderDiagnosticSeverity {
        reports.map(\.highestSeverity).max(by: severityLessThan) ?? .info
    }

    public func filtered(by filter: ProviderConnectivityFilter) -> [ProviderConnectivityProviderReport] {
        reports.filter { filter.includes($0) }
    }

    public var pasteboardText: String {
        var lines = [
            L("Provider connectivity diagnostics"),
            L(
                "\(connectedCount)/\(totalCount) connected, \(attentionCount) attention, \(modelCount) models, \(manualModelProviderCount) manual-model provider(s)"
            ),
            L("Global proxy: \(proxy.summaryText)"),
        ]
        for report in reports {
            lines.append("")
            lines.append(report.diagnostics.pasteboardText)
        }
        return lines.joined(separator: "\n")
    }
}

public enum ProviderConnectivityCenter {
    public static func snapshot(
        providers: [RemoteProvider],
        states: [UUID: RemoteProviderState],
        proxy: GlobalProxyDiagnosticState,
        credentialsByProvider: [UUID: RemoteProviderCredentialPresence]
    ) -> ProviderConnectivitySnapshot {
        let reports = providers.map { provider in
            providerReport(
                provider: provider,
                state: states[provider.id],
                proxy: proxy,
                credentialPresence: credentialsByProvider[provider.id] ?? RemoteProviderCredentialPresence()
            )
        }
        return ProviderConnectivitySnapshot(reports: reports, proxy: proxy)
    }

    public static func providerReport(
        provider: RemoteProvider,
        state: RemoteProviderState?,
        proxy: GlobalProxyDiagnosticState,
        credentialPresence: RemoteProviderCredentialPresence
    ) -> ProviderConnectivityProviderReport {
        let diagnostics = ProviderNetworkDiagnostics.remoteProviderReport(
            provider: provider,
            state: state,
            proxy: proxy,
            apiKeyPresent: credentialPresence.apiKeyPresent,
            oauthTokensPresent: credentialPresence.oauthTokensPresent
        )
        let severity = diagnostics.rows.map(\.severity).max(by: severityLessThan) ?? .info
        let status = status(for: provider, state: state, highestSeverity: severity)
        let firstActionableRow =
            diagnostics.rows.first { $0.severity == .blocked }
            ?? diagnostics.rows.first { $0.severity == .warning }
        let summaryRow = firstActionableRow ?? diagnostics.rows.first { $0.id == "connection" }

        return ProviderConnectivityProviderReport(
            id: provider.id,
            provider: provider,
            state: state,
            diagnostics: diagnostics,
            status: status,
            highestSeverity: severity,
            summary: summary(for: summaryRow, fallback: status.displayName),
            recommendedAction: firstActionableRow?.action,
            modelCount: state?.modelCount ?? 0,
            manualModelCount: provider.manualModelIds.count
        )
    }

    private static func status(
        for provider: RemoteProvider,
        state: RemoteProviderState?,
        highestSeverity: ProviderDiagnosticSeverity
    ) -> ProviderConnectivityStatus {
        guard provider.enabled else { return .disabled }
        if state?.isConnecting == true { return .connecting }
        if state?.isConnected == true { return .connected }
        if state?.lastError?.isEmpty == false || highestSeverity == .blocked || highestSeverity == .warning {
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

private func severityLessThan(_ lhs: ProviderDiagnosticSeverity, _ rhs: ProviderDiagnosticSeverity) -> Bool {
    severityRank(lhs) < severityRank(rhs)
}

private func severityRank(_ severity: ProviderDiagnosticSeverity) -> Int {
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
