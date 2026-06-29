//
//  SkillCapabilityPolicyDiagnostic.swift
//  osaurus
//
//  Typed diagnostics for explaining skill availability in capability discovery.
//

import Foundation

struct SkillSearchIndexSnapshot: Equatable, Sendable {
    let vectorIndexInitialized: Bool
    let vectorIndexAvailable: Bool
    /// Skill ids known to the search index mapping. This is intentionally not
    /// called "indexed": VecturaKit does not currently expose document listing.
    let knownSkillIds: Set<UUID>

    var knownSkillCount: Int { knownSkillIds.count }
    var usesLexicalFallback: Bool { !vectorIndexAvailable }

    static let unavailable = SkillSearchIndexSnapshot(
        vectorIndexInitialized: false,
        vectorIndexAvailable: false,
        knownSkillIds: []
    )
}

enum SkillCapabilitySource: String, Codable, CaseIterable, Sendable {
    case builtIn = "built_in"
    case standalone
    case plugin

    var displayLabel: String {
        switch self {
        case .builtIn:
            return "Built-in"
        case .standalone:
            return "Standalone"
        case .plugin:
            return "Plugin"
        }
    }
}

enum SkillCapabilityState: String, Codable, CaseIterable, Sendable {
    case loadable
    case hidden
    case disabled
    case unavailable

    var displayLabel: String {
        switch self {
        case .loadable:
            return "Loadable"
        case .hidden:
            return "Hidden"
        case .disabled:
            return "Disabled"
        case .unavailable:
            return "Unavailable"
        }
    }
}

enum SkillCapabilityPolicyReasonCode: String, Codable, CaseIterable, Sendable {
    case loadableViaCapabilitiesLoad = "loadable_via_capabilities_load"
    case globallyDisabled = "globally_disabled"
    case allowedByAgentScope = "allowed_by_agent_scope"
    case hiddenByAgentScope = "hidden_by_agent_scope"
    case unscopedLegacyAgent = "unscoped_legacy_agent"
    case configurationAgentUnsupported = "configuration_agent_unsupported"
    case agentNotFound = "agent_not_found"
}

enum SkillCapabilitySearchReasonCode: String, Codable, CaseIterable, Sendable {
    case searchable
    case knownToSearchIndex = "known_to_search_index"
    case lexicalFallback = "lexical_fallback"
    case vectorIndexUnavailable = "vector_index_unavailable"
    case notKnownToSearchIndex = "not_known_to_search_index"
    case globallyDisabled = "globally_disabled"
    case hiddenByAgentScope = "hidden_by_agent_scope"
    case configurationAgentUnsupported = "configuration_agent_unsupported"
    case agentNotFound = "agent_not_found"
}

struct SkillCapabilityPolicyDiagnostic: Equatable, Sendable {
    struct Row: Equatable, Identifiable, Sendable {
        var id: UUID { skillId }

        let skillId: UUID
        let skillName: String
        let description: String
        let source: SkillCapabilitySource
        let state: SkillCapabilityState
        let loadId: String
        let pluginId: String?
        let globallyEnabled: Bool
        let agentAllowed: Bool
        let agentScoped: Bool
        let knownToSearchIndex: Bool
        let searchableByCapabilitiesDiscover: Bool
        let policyReasonCodes: [SkillCapabilityPolicyReasonCode]
        let searchReasonCodes: [SkillCapabilitySearchReasonCode]
        let instructionCharacters: Int

        var compactSummary: String {
            let policy = policyReasonCodes.map(\.rawValue).joined(separator: ",")
            let search = searchReasonCodes.map(\.rawValue).joined(separator: ",")
            return
                "source=\(source.rawValue); state=\(state.rawValue); policy=\(policy); known_to_search_index=\(knownToSearchIndex); searchable=\(searchableByCapabilitiesDiscover); search=\(search)"
        }
    }

    let agentId: UUID
    let agentName: String
    let toolMode: ToolSelectionMode
    let agentScoped: Bool
    let vectorIndexInitialized: Bool
    let vectorIndexAvailable: Bool
    let usingLexicalFallback: Bool
    let knownSkillCount: Int
    let totalSkillCount: Int
    let rows: [Row]

    var enabledSkillCount: Int {
        rows.filter(\.globallyEnabled).count
    }

    var sourceCounts: [SkillCapabilitySource: Int] {
        Dictionary(grouping: rows, by: \.source).mapValues(\.count)
    }

    var stateCounts: [SkillCapabilityState: Int] {
        Dictionary(grouping: rows, by: \.state).mapValues(\.count)
    }

    func filteredRows(
        query rawQuery: String = "",
        source: SkillCapabilitySource? = nil,
        state: SkillCapabilityState? = nil
    ) -> [Row] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows.filter { row in
            if let source, row.source != source { return false }
            if let state, row.state != state { return false }
            guard !query.isEmpty else { return true }
            let haystack = [
                row.skillName,
                row.description,
                row.source.displayLabel,
                row.state.displayLabel,
                row.loadId,
                row.pluginId ?? "",
                row.policyReasonCodes.map(\.rawValue).joined(separator: " "),
                row.searchReasonCodes.map(\.rawValue).joined(separator: " "),
            ].joined(separator: " ").lowercased()
            return haystack.contains(query)
        }
    }

    var textBlock: String {
        guard !rows.isEmpty else { return "" }
        var lines = [
            "Skill policy diagnostics:",
            "agent: \(agentName) (\(agentId.uuidString))",
            "skills: \(enabledSkillCount) enabled / \(totalSkillCount) total, known_search_index_skills: \(knownSkillCount), vector_index_available: \(vectorIndexAvailable), vector_index_initialized: \(vectorIndexInitialized)",
        ]
        for row in rows {
            lines.append("- \(row.loadId): \(row.compactSummary)")
        }
        return lines.joined(separator: "\n")
    }

    func reporterSafeMarkdown(generatedAt: Date = Date(), rows selectedRows: [Row]? = nil) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let reportRows = (selectedRows ?? rows)
            .sorted { lhs, rhs in
                if lhs.source.rawValue == rhs.source.rawValue {
                    return lhs.skillName.localizedCaseInsensitiveCompare(rhs.skillName) == .orderedAscending
                }
                return lhs.source.rawValue < rhs.source.rawValue
            }
        let reportStateCounts = Dictionary(grouping: reportRows, by: \.state).mapValues(\.count)
        let reportSourceCounts = Dictionary(grouping: reportRows, by: \.source).mapValues(\.count)

        var lines: [String] = [
            "# Skill Policy Report",
            "",
            "- Generated: \(formatter.string(from: generatedAt))",
            "- Agent: \(Self.escapeMarkdown(agentName)) (\(agentId.uuidString))",
            "- Tool mode: \(toolMode.rawValue)",
            "- Agent scope seeded: \(agentScoped)",
            "- Skills: \(enabledSkillCount) enabled / \(totalSkillCount) total",
            "- Known to search index: \(knownSkillCount)",
            "- Vector index available: \(vectorIndexAvailable)",
            "- Vector index initialized: \(vectorIndexInitialized)",
            "- Rows in report: \(reportRows.count)",
            "- Reporter-safe fields only: no instructions, references, assets, secrets, manifest paths, or runtime paths.",
            "",
            "## State Counts",
        ]

        for state in SkillCapabilityState.allCases {
            lines.append("- \(state.displayLabel): \(reportStateCounts[state, default: 0])")
        }

        lines.append(contentsOf: [
            "",
            "## Source Counts",
        ])

        for source in SkillCapabilitySource.allCases {
            let count = reportSourceCounts[source, default: 0]
            if count > 0 {
                lines.append("- \(source.displayLabel): \(count)")
            }
        }

        lines.append(contentsOf: [
            "",
            "## Rows",
            "",
            "| Skill | Source | State | Load ID | Policy reasons | Search reasons | Enabled | Agent allowed | Known to search index | Searchable | Instruction chars |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | ---: |",
        ])

        for row in reportRows {
            lines.append(
                "| \(Self.escapeMarkdown(row.skillName)) | \(row.source.rawValue) | \(row.state.rawValue) | \(Self.escapeMarkdown(row.loadId)) | \(Self.joinCodes(row.policyReasonCodes.map(\.rawValue))) | \(Self.joinCodes(row.searchReasonCodes.map(\.rawValue))) | \(row.globallyEnabled) | \(row.agentAllowed) | \(row.knownToSearchIndex) | \(row.searchableByCapabilitiesDiscover) | \(row.instructionCharacters) |"
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
