//
//  SkillPolicyConsolePresenterTests.swift
//  osaurus
//
//  Tests for filtering and grouping in the Skills policy/status presenter.
//

import Foundation
import Testing

@testable import OsaurusCore

struct SkillPolicyConsolePresenterTests {

    @Test func filtersByQuerySourceAndState() {
        let diagnostic = makeDiagnostic(
            rows: [
                makeRow(name: "Research Helper", source: .standalone, state: .loadable),
                makeRow(name: "Plugin Planner", source: .plugin, state: .hidden),
                makeRow(name: "Built In Tutor", source: .builtIn, state: .disabled),
            ]
        )

        let queryRows = SkillPolicyConsolePresenter.filteredRows(
            diagnostic: diagnostic,
            query: "plugin",
            sourceFilter: .all,
            stateFilter: .all
        )
        #expect(queryRows.map(\.skillName) == ["Plugin Planner"])

        let pluginRows = SkillPolicyConsolePresenter.filteredRows(
            diagnostic: diagnostic,
            query: "",
            sourceFilter: .plugin,
            stateFilter: .all
        )
        #expect(pluginRows.map(\.skillName) == ["Plugin Planner"])

        let hiddenRows = SkillPolicyConsolePresenter.filteredRows(
            diagnostic: diagnostic,
            query: "",
            sourceFilter: .all,
            stateFilter: .hidden
        )
        #expect(hiddenRows.map(\.skillName) == ["Plugin Planner"])
    }

    @Test func groupsRowsByStableSourceOrderAndSortsNames() {
        let rows = [
            makeRow(name: "Zulu Plugin", source: .plugin, state: .loadable),
            makeRow(name: "Built In", source: .builtIn, state: .disabled),
            makeRow(name: "Alpha Plugin", source: .plugin, state: .hidden),
            makeRow(name: "Standalone", source: .standalone, state: .loadable),
        ]

        let groups = SkillPolicyConsolePresenter.groups(rows: rows)

        #expect(groups.map(\.source) == [.builtIn, .standalone, .plugin])
        #expect(groups[2].rows.map(\.skillName) == ["Alpha Plugin", "Zulu Plugin"])
    }

    @Test func stateCountUsesDiagnosticCounts() {
        let diagnostic = makeDiagnostic(
            rows: [
                makeRow(name: "A", source: .standalone, state: .loadable),
                makeRow(name: "B", source: .standalone, state: .loadable),
                makeRow(name: "C", source: .plugin, state: .hidden),
            ]
        )

        #expect(SkillPolicyConsolePresenter.stateCount(.loadable, diagnostic: diagnostic) == 2)
        #expect(SkillPolicyConsolePresenter.stateCount(.hidden, diagnostic: diagnostic) == 1)
        #expect(SkillPolicyConsolePresenter.stateCount(.disabled, diagnostic: diagnostic) == 0)
    }

    private func makeDiagnostic(
        rows: [SkillCapabilityPolicyDiagnostic.Row]
    ) -> SkillCapabilityPolicyDiagnostic {
        SkillCapabilityPolicyDiagnostic(
            agentId: UUID(),
            agentName: "Agent",
            toolMode: .auto,
            agentScoped: true,
            vectorIndexInitialized: true,
            vectorIndexAvailable: true,
            usingLexicalFallback: false,
            knownSkillCount: rows.filter(\.knownToSearchIndex).count,
            totalSkillCount: rows.count,
            rows: rows
        )
    }

    private func makeRow(
        name: String,
        source: SkillCapabilitySource,
        state: SkillCapabilityState
    ) -> SkillCapabilityPolicyDiagnostic.Row {
        SkillCapabilityPolicyDiagnostic.Row(
            skillId: UUID(),
            skillName: name,
            description: "\(name) description",
            source: source,
            state: state,
            loadId: "skill/\(name)",
            pluginId: source == .plugin ? "com.example.plugin" : nil,
            globallyEnabled: state != .disabled,
            agentAllowed: state == .loadable,
            agentScoped: true,
            knownToSearchIndex: true,
            searchableByCapabilitiesDiscover: state == .loadable,
            policyReasonCodes: state == .loadable ? [.loadableViaCapabilitiesLoad] : [.hiddenByAgentScope],
            searchReasonCodes: state == .loadable
                ? [.searchable, .knownToSearchIndex]
                : [.hiddenByAgentScope, .knownToSearchIndex],
            instructionCharacters: 12
        )
    }
}
