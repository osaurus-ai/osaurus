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
            return report.isAttentionWorthy
        case .connected:
            return report.status == .connected
        case .disabled:
            return report.status == .disabled
        }
    }
}

public struct ProviderConnectivityIssueKind: Sendable, Equatable, Hashable, Identifiable {
    public let id: String

    public var displayName: String {
        if self == .authentication { return L("Authentication") }
        if self == .connection { return L("Connection") }
        if self == .oauthContext { return L("OAuth") }
        if self == .requestEvidence { return L("Request evidence") }
        if self == .models { return L("Models") }
        if self == .format { return L("Request format") }
        if self == .proxy { return L("Global proxy") }
        if self == .transport { return L("Transport") }
        if self == .repro { return L("Repro path") }
        if self == .uncategorized || isUnknown { return L("Unknown") }
        return id
    }
    public var isUnknown: Bool { id.hasPrefix(Self.unknownPrefix) }

    public static let authentication = ProviderConnectivityIssueKind(id: "auth")
    public static let connection = ProviderConnectivityIssueKind(id: "connection")
    public static let oauthContext = ProviderConnectivityIssueKind(id: "oauth-context")
    public static let requestEvidence = ProviderConnectivityIssueKind(id: "request-evidence")
    public static let models = ProviderConnectivityIssueKind(id: "models")
    public static let format = ProviderConnectivityIssueKind(id: "format")
    public static let proxy = ProviderConnectivityIssueKind(id: "proxy")
    public static let transport = ProviderConnectivityIssueKind(id: "transport")
    public static let repro = ProviderConnectivityIssueKind(id: "repro")
    public static let uncategorized = ProviderConnectivityIssueKind(id: "unknown:unclassified")

    public init(id: String) {
        self.id = id
    }

    public static func kind(forDiagnosticRowID rowID: String) -> ProviderConnectivityIssueKind {
        knownByRowID[rowID] ?? ProviderConnectivityIssueKind(id: "\(unknownPrefix)\(rowID)")
    }

    private static let unknownPrefix = "unknown:"

    private static let knownByRowID: [String: ProviderConnectivityIssueKind] = [
        authentication.id: .authentication,
        connection.id: .connection,
        oauthContext.id: .oauthContext,
        requestEvidence.id: .requestEvidence,
        models.id: .models,
        format.id: .format,
        proxy.id: .proxy,
        transport.id: .transport,
        repro.id: .repro,
    ]

    fileprivate var sortKey: (Int, String) {
        if self == .authentication { return (0, id) }
        if self == .connection { return (1, id) }
        if self == .oauthContext { return (2, id) }
        if self == .requestEvidence { return (3, id) }
        if self == .models { return (4, id) }
        if self == .format { return (5, id) }
        if self == .proxy { return (6, id) }
        if self == .transport { return (7, id) }
        if self == .repro { return (8, id) }
        return (1_000, id)
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
    public let issueKinds: [ProviderConnectivityIssueKind]
    public let primaryIssueKind: ProviderConnectivityIssueKind?

    public var hasAttention: Bool {
        status == .needsAttention || highestSeverity == .blocked || highestSeverity == .warning
    }

    public var isAttentionWorthy: Bool {
        provider.enabled && hasAttention
    }
}

public struct ProviderConnectivitySnapshot: Sendable {
    public let reports: [ProviderConnectivityProviderReport]
    public let proxy: GlobalProxyDiagnosticState

    public var totalCount: Int { reports.count }
    public var enabledCount: Int { reports.filter { $0.provider.enabled }.count }
    public var connectedCount: Int { reports.filter { $0.status == .connected }.count }
    public var connectingCount: Int { reports.filter { $0.status == .connecting }.count }
    public var attentionCount: Int { attentionReports.count }
    public var disabledCount: Int { reports.filter { $0.status == .disabled }.count }
    public var manualModelProviderCount: Int { reports.filter { $0.manualModelCount > 0 }.count }
    public var modelCount: Int { reports.reduce(0) { $0 + $1.modelCount } }
    public var attentionReports: [ProviderConnectivityProviderReport] {
        reports.filter(\.isAttentionWorthy)
    }

    public var issueKindCounts: [ProviderConnectivityIssueKind: Int] {
        countsByIssueKind(for: attentionReports)
    }

    public var sortedIssueKinds: [ProviderConnectivityIssueKind] {
        issueKindCounts.keys.sorted(by: issueKindLessThan)
    }

    public var groupedReportsByPrimaryIssueKind: [ProviderConnectivityIssueKind: [ProviderConnectivityProviderReport]] {
        Dictionary(grouping: attentionReports) { report in
            bucketedIssueKind(for: report)
        }
    }

    public var highestSeverity: ProviderDiagnosticSeverity {
        reports.map(\.highestSeverity).max(by: severityLessThan) ?? .info
    }

    public func filtered(by filter: ProviderConnectivityFilter) -> [ProviderConnectivityProviderReport] {
        reports.filter { filter.includes($0) }
    }

    public func filtered(
        by filter: ProviderConnectivityFilter,
        issueKind: ProviderConnectivityIssueKind?
    ) -> [ProviderConnectivityProviderReport] {
        let statusFiltered = filtered(by: filter)
        guard filter.allowsIssueFiltering else {
            return statusFiltered
        }
        guard let issueKind else { return statusFiltered }
        guard issueKindCounts(for: filter)[issueKind, default: 0] > 0 else { return [] }
        return statusFiltered.filter {
            $0.isAttentionWorthy && bucketedIssueKinds(for: $0).contains(issueKind)
        }
    }

    public func issueReportCount(for filter: ProviderConnectivityFilter) -> Int {
        issueReports(for: filter).count
    }

    public func issueKindCounts(for filter: ProviderConnectivityFilter) -> [ProviderConnectivityIssueKind: Int] {
        countsByIssueKind(for: issueReports(for: filter))
    }

    public func sortedIssueKinds(for filter: ProviderConnectivityFilter) -> [ProviderConnectivityIssueKind] {
        issueKindCounts(for: filter).keys.sorted(by: issueKindLessThan)
    }

    public var pasteboardText: String {
        let modelLabel = modelCount == 1 ? L("1 model") : L("\(modelCount) models")
        let providerLabel =
            manualModelProviderCount == 1
            ? L("1 manual-model provider")
            : L("\(manualModelProviderCount) manual-model providers")
        var lines = [
            L("Provider connectivity diagnostics"),
            L(
                "\(connectedCount)/\(totalCount) connected, \(attentionCount) attention, \(modelLabel), \(providerLabel)"
            ),
            L("Global proxy: \(proxy.summaryText)"),
        ]
        for report in reports {
            lines.append("")
            lines.append(report.diagnostics.pasteboardText)
        }
        return lines.joined(separator: "\n")
    }

    public func groupedPasteboardText(issueKind: ProviderConnectivityIssueKind?) -> String {
        let normalizedIssueKind = issueKind.flatMap {
            issueKindCounts[$0, default: 0] > 0 ? $0 : nil
        }
        let groupedReports: [(ProviderConnectivityIssueKind, [ProviderConnectivityProviderReport])]
        if let normalizedIssueKind {
            groupedReports = [
                (
                    normalizedIssueKind,
                    attentionReports.filter { bucketedIssueKinds(for: $0).contains(normalizedIssueKind) }
                ),
            ]
        } else {
            groupedReports = sortedIssueKinds.map { kind in
                (kind, attentionReports.filter { bucketedIssueKinds(for: $0).contains(kind) })
            }
        }

        var lines = [
            "provider-connectivity-issue-diagnostics",
            "attention-providers=\(attentionCount) issue-buckets=\(groupedReports.count)",
            "global-proxy: \(proxy.summaryText)",
        ]
        for (kind, reports) in groupedReports where !reports.isEmpty {
            lines.append("")
            lines.append("\(kind.displayName) (\(reports.count))")
            for report in reports {
                lines.append("")
                lines.append(report.diagnostics.pasteboardText)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func issueReports(for filter: ProviderConnectivityFilter) -> [ProviderConnectivityProviderReport] {
        filtered(by: filter).filter(\.isAttentionWorthy)
    }

    private func bucketedIssueKind(
        for report: ProviderConnectivityProviderReport
    ) -> ProviderConnectivityIssueKind {
        report.primaryIssueKind ?? .uncategorized
    }

    private func bucketedIssueKinds(
        for report: ProviderConnectivityProviderReport
    ) -> [ProviderConnectivityIssueKind] {
        if !report.issueKinds.isEmpty {
            return report.issueKinds
        }
        return [bucketedIssueKind(for: report)]
    }

    private func countsByIssueKind(
        for reports: [ProviderConnectivityProviderReport]
    ) -> [ProviderConnectivityIssueKind: Int] {
        reports.reduce(into: [:]) { counts, report in
            for kind in bucketedIssueKinds(for: report) {
                counts[kind, default: 0] += 1
            }
        }
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
        let issueKinds = actionableIssueKinds(from: diagnostics.rows)
        let primaryIssueKind = firstActionableRow.map {
            ProviderConnectivityIssueKind.kind(forDiagnosticRowID: $0.id)
        }

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
            manualModelCount: provider.manualModelIds.count,
            issueKinds: issueKinds,
            primaryIssueKind: primaryIssueKind
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

    private static func actionableIssueKinds(from rows: [ProviderDiagnosticRow]) -> [ProviderConnectivityIssueKind] {
        var seen: Set<ProviderConnectivityIssueKind> = []
        var kinds: [ProviderConnectivityIssueKind] = []
        for row in rows where row.severity == .blocked || row.severity == .warning {
            let kind = ProviderConnectivityIssueKind.kind(forDiagnosticRowID: row.id)
            guard !seen.contains(kind) else {
                continue
            }
            seen.insert(kind)
            kinds.append(kind)
        }
        return kinds.sorted(by: issueKindLessThan)
    }
}

private func issueKindLessThan(
    _ lhs: ProviderConnectivityIssueKind,
    _ rhs: ProviderConnectivityIssueKind
) -> Bool {
    if lhs.sortKey.0 != rhs.sortKey.0 {
        return lhs.sortKey.0 < rhs.sortKey.0
    }
    return lhs.sortKey.1 < rhs.sortKey.1
}

private extension ProviderConnectivityFilter {
    var allowsIssueFiltering: Bool {
        switch self {
        case .all, .attention:
            return true
        case .connected, .disabled:
            return false
        }
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
