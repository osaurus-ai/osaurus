//
//  ToolExposureDiagnostic.swift
//  osaurus
//
//  Typed diagnostics for explaining why a named tool is or is not surfaced by
//  capability discovery.
//

import Foundation

enum ToolExposureSource: String, Codable, CaseIterable, Sendable {
    case builtIn = "built_in"
    case runtime
    case plugin
    case mcpProvider = "mcp_provider"
    case sandboxPlugin = "sandbox_plugin"
    case native
    case unknown

    var displayLabel: String {
        switch self {
        case .builtIn:
            return "Built-in"
        case .runtime:
            return "Runtime"
        case .plugin:
            return "Plugin"
        case .mcpProvider:
            return "MCP"
        case .sandboxPlugin:
            return "Sandbox"
        case .native:
            return "Native"
        case .unknown:
            return "Unknown"
        }
    }
}

enum ToolExposureState: String, Codable, CaseIterable, Sendable {
    case exposed
    case loadable
    case hidden
    case disabled
    case blocked
    case unavailable

    var displayLabel: String {
        switch self {
        case .exposed:
            return "Exposed"
        case .loadable:
            return "Loadable"
        case .hidden:
            return "Hidden"
        case .disabled:
            return "Disabled"
        case .blocked:
            return "Blocked"
        case .unavailable:
            return "Unavailable"
        }
    }
}

enum ToolExposureSearchReasonCode: String, Codable, CaseIterable, Sendable {
    case searchable
    case indexed
    case databaseClosedRegistryFallback = "database_closed_registry_fallback"
    case excludedCapabilityInfrastructure = "excluded_capability_infrastructure"
    case runtimeManaged = "runtime_managed"
    case globallyDisabled = "globally_disabled"
    case hiddenByAgentScope = "hidden_by_agent_scope"
    case hiddenByExecutionMode = "hidden_by_execution_mode"
    case notIndexed = "not_indexed"
    case notRegistered = "not_registered"
}

struct ToolExposureDiagnostic: Equatable, Sendable {
    struct Row: Equatable, Identifiable, Sendable {
        var id: String { toolName }

        let toolName: String
        let description: String
        let source: ToolExposureSource
        let state: ToolExposureState
        let availability: ToolAvailability
        let registered: Bool
        let globallyEnabled: Bool
        let indexedForSearch: Bool
        let searchableByCapabilitiesDiscover: Bool
        let searchReasonCodes: [ToolExposureSearchReasonCode]
        let tokenEstimate: Int

        var allowsGlobalEnablementChange: Bool {
            registered && source != .builtIn && source != .runtime
        }

        var compactSummary: String {
            let searchCodes = searchReasonCodes.map(\.rawValue).joined(separator: ",")
            return
                "source=\(source.rawValue); state=\(state.rawValue); availability=\(availability.compactSummary); indexed=\(indexedForSearch); searchable=\(searchableByCapabilitiesDiscover); search=\(searchCodes)"
        }
    }

    let registeredToolCount: Int
    let indexedToolCount: Int
    let rows: [Row]

    var sourceCounts: [ToolExposureSource: Int] {
        Dictionary(grouping: rows, by: \.source).mapValues(\.count)
    }

    var stateCounts: [ToolExposureState: Int] {
        Dictionary(grouping: rows, by: \.state).mapValues(\.count)
    }

    func filteredRows(
        query rawQuery: String = "",
        source: ToolExposureSource? = nil,
        state: ToolExposureState? = nil
    ) -> [Row] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows.filter { row in
            if let source, row.source != source { return false }
            if let state, row.state != state { return false }
            guard !query.isEmpty else { return true }
            let haystack = [
                row.toolName,
                row.description,
                row.source.displayLabel,
                row.state.displayLabel,
                row.availability.displayDetail,
                row.availability.reasonCodes.map(\.rawValue).joined(separator: " "),
                row.searchReasonCodes.map(\.rawValue).joined(separator: " "),
            ].joined(separator: " ").lowercased()
            return haystack.contains(query)
        }
    }

    var textBlock: String {
        guard !rows.isEmpty else { return "" }
        var lines = [
            "Tool exposure diagnostics:",
            "registered_tools: \(registeredToolCount), indexed_tools: \(indexedToolCount)",
        ]
        for row in rows {
            lines.append("- tool/\(row.toolName): \(row.compactSummary)")
        }
        return lines.joined(separator: "\n")
    }

    func reporterSafeMarkdown(generatedAt: Date = Date(), rows selectedRows: [Row]? = nil) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let reportRows = (selectedRows ?? rows)
            .sorted { lhs, rhs in
                if lhs.source.rawValue == rhs.source.rawValue {
                    return lhs.toolName.localizedCaseInsensitiveCompare(rhs.toolName) == .orderedAscending
                }
                return lhs.source.rawValue < rhs.source.rawValue
            }
        let reportStateCounts = Dictionary(grouping: reportRows, by: \.state).mapValues(\.count)
        let reportSourceCounts = Dictionary(grouping: reportRows, by: \.source).mapValues(\.count)

        var lines: [String] = [
            "# Tool Exposure Report",
            "",
            "- Generated: \(formatter.string(from: generatedAt))",
            "- Registered tools: \(registeredToolCount)",
            "- Indexed tools: \(indexedToolCount)",
            "- Rows in report: \(reportRows.count)",
            "- Reporter-safe fields only: no schemas, arguments, secrets, provider URLs, manifest paths, or runtime paths.",
            "",
            "## State Counts",
        ]

        for state in ToolExposureState.allCases {
            lines.append("- \(state.displayLabel): \(reportStateCounts[state, default: 0])")
        }

        lines.append(contentsOf: [
            "",
            "## Source Counts",
        ])

        for source in ToolExposureSource.allCases {
            let count = reportSourceCounts[source, default: 0]
            if count > 0 {
                lines.append("- \(source.displayLabel): \(count)")
            }
        }

        lines.append(contentsOf: [
            "",
            "## Rows",
            "",
            "| Tool | Source | State | Availability reasons | Capability search reasons | Enabled | Indexed | Searchable | Tokens |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | ---: |",
        ])

        for row in reportRows {
            lines.append(
                "| \(Self.escapeMarkdown(row.toolName)) | \(row.source.rawValue) | \(row.state.rawValue) | \(Self.joinCodes(row.availability.reasonCodes.map(\.rawValue))) | \(Self.joinCodes(row.searchReasonCodes.map(\.rawValue))) | \(row.globallyEnabled) | \(row.indexedForSearch) | \(row.searchableByCapabilitiesDiscover) | \(row.tokenEstimate) |"
            )
        }

        return lines.joined(separator: "\n")
    }

    private static func joinCodes(_ codes: [String]) -> String {
        guard !codes.isEmpty else { return "-" }
        return escapeMarkdown(codes.joined(separator: ", "))
    }

    private static func escapeMarkdown(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
