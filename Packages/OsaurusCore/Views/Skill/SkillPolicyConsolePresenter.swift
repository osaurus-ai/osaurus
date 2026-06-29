//
//  SkillPolicyConsolePresenter.swift
//  osaurus
//
//  Pure view transforms for the Skills policy console.
//

import Foundation

enum SkillPolicySourceFilter: String, CaseIterable, Identifiable {
    case all
    case builtIn
    case standalone
    case plugin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All Sources"
        case .builtIn:
            return "Built-in"
        case .standalone:
            return "Standalone"
        case .plugin:
            return "Plugin"
        }
    }

    var source: SkillCapabilitySource? {
        switch self {
        case .all:
            return nil
        case .builtIn:
            return .builtIn
        case .standalone:
            return .standalone
        case .plugin:
            return .plugin
        }
    }
}

enum SkillPolicyStateFilter: String, CaseIterable, Identifiable {
    case all
    case loadable
    case hidden
    case disabled
    case unavailable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All States"
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

    var state: SkillCapabilityState? {
        switch self {
        case .all:
            return nil
        case .loadable:
            return .loadable
        case .hidden:
            return .hidden
        case .disabled:
            return .disabled
        case .unavailable:
            return .unavailable
        }
    }

    static func filter(for state: SkillCapabilityState) -> SkillPolicyStateFilter {
        switch state {
        case .loadable:
            return .loadable
        case .hidden:
            return .hidden
        case .disabled:
            return .disabled
        case .unavailable:
            return .unavailable
        }
    }
}

enum SkillPolicyConsolePresenter {
    struct Group: Identifiable, Equatable {
        let source: SkillCapabilitySource
        let rows: [SkillCapabilityPolicyDiagnostic.Row]

        var id: SkillCapabilitySource { source }
    }

    static func filteredRows(
        diagnostic: SkillCapabilityPolicyDiagnostic,
        query: String,
        sourceFilter: SkillPolicySourceFilter,
        stateFilter: SkillPolicyStateFilter
    ) -> [SkillCapabilityPolicyDiagnostic.Row] {
        diagnostic.filteredRows(
            query: query,
            source: sourceFilter.source,
            state: stateFilter.state
        )
    }

    static func groups(
        rows: [SkillCapabilityPolicyDiagnostic.Row]
    ) -> [Group] {
        let grouped = Dictionary(grouping: rows, by: \.source)
        return SkillCapabilitySource.allCases.compactMap { source in
            guard let sourceRows = grouped[source], !sourceRows.isEmpty else { return nil }
            return Group(
                source: source,
                rows: sourceRows.sorted {
                    $0.skillName.localizedCaseInsensitiveCompare($1.skillName) == .orderedAscending
                }
            )
        }
    }

    static func stateCount(
        _ state: SkillCapabilityState,
        diagnostic: SkillCapabilityPolicyDiagnostic
    ) -> Int {
        diagnostic.stateCounts[state, default: 0]
    }
}
