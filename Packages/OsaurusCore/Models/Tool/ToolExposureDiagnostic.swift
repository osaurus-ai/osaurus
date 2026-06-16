//
//  ToolExposureDiagnostic.swift
//  osaurus
//
//  Typed diagnostics for explaining why a named tool is or is not surfaced by
//  capability discovery.
//

import Foundation

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
    struct Row: Equatable, Sendable {
        let toolName: String
        let availability: ToolAvailability
        let registered: Bool
        let globallyEnabled: Bool
        let indexedForSearch: Bool
        let searchableByCapabilitiesDiscover: Bool
        let searchReasonCodes: [ToolExposureSearchReasonCode]

        var compactSummary: String {
            let searchCodes = searchReasonCodes.map(\.rawValue).joined(separator: ",")
            return
                "availability=\(availability.compactSummary); indexed=\(indexedForSearch); searchable=\(searchableByCapabilitiesDiscover); search=\(searchCodes)"
        }
    }

    let registeredToolCount: Int
    let indexedToolCount: Int
    let rows: [Row]

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
}
