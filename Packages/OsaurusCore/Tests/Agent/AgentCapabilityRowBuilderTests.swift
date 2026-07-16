//
//  AgentCapabilityRowBuilderTests.swift
//  osaurus
//
//  Regression coverage for the Tools picker row builder, with a specific
//  focus on the `source(forTool:)` helper used by
//  `AgentCapabilityManagerView.childrenOf(groupId:)`.
//
//  Background: #1003 — clicking the master checkbox on a *collapsed* group
//  was a no-op because the previous `childrenOf` walked the rendered rows,
//  which omit children for collapsed groups. The fix routes `childrenOf`
//  through the classifier helper on `CapabilityRowBuilder`, which buckets
//  directly off the live registries. These tests pin the helper's
//  classification rules and verify informational groups stay hidden — if
//  `build` and `childrenOf` ever diverge again, bulk toggle would silently
//  drop tools and the bug regresses.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct AgentCapabilityRowBuilderTests {

    // MARK: - Tool classifier

    @Test func unclassifiedToolFallsBackToBuiltInGroup() {
        // Synthetic tool name that isn't registered in any bucket. The
        // classifier should hit the same `.builtIn` fallback that
        // `CapabilityRowBuilder.build` uses for unrecognized tools so a
        // bulk toggle on a "miscellaneous" group still acts on them.
        let tool = makeToolEntry(name: "agent_capability_tests_unclassified_xyz")
        let source = CapabilityRowBuilder.source(forTool: tool, pluginNameById: [:])

        #expect(source == .builtIn)
        #expect(source.groupId == "src:builtin")
        #expect(source.isInformational == true)
    }

    @Test func builtInToolBucketsToBuiltInGroup() {
        // `capabilities_discover` is registered as a built-in by
        // `ToolRegistry.registerBuiltInTools()` at singleton init.
        // It's also referenced from `CapabilityToolsTests`, so its name
        // is an established test fixture.
        let tool = makeToolEntry(name: "capabilities_discover")
        let source = CapabilityRowBuilder.source(forTool: tool, pluginNameById: [:])

        #expect(source == .builtIn)
        #expect(source.groupId == "src:builtin")
        #expect(source.isInformational == true)
    }

    // MARK: - Informational groups stay hidden

    /// Built-in / runtime-managed tools are surfaced in the picker only as
    /// data — `build` must not emit a header or any rows for them, since
    /// their per-row toggles are disabled and the master checkbox is a
    /// no-op (informational sources are skipped by `childrenOf`). Showing
    /// the group anyway just creates the misleading "looks toggleable but
    /// isn't" state that motivated hiding it.
    @Test func informationalGroupIsHiddenFromRows() {
        let builtInTool = makeToolEntry(name: "capabilities_discover")
        let unclassifiedTool = makeToolEntry(name: "agent_capability_tests_unclassified_xyz")

        let input = CapabilityRowBuilder.Input(
            visibleTools: [builtInTool, unclassifiedTool],
            plugins: [],
            enabledToolNames: [],
            toolMode: .auto,
            searchQuery: "",
            filter: .all,
            // Even with the group force-expanded, the row builder must
            // still drop it — informational sources are filtered before
            // expansion is consulted.
            expandedGroups: ["src:builtin"]
        )

        let rows = CapabilityRowBuilder.build(input)

        for row in rows {
            switch row {
            case .groupHeader(let id, _, _, _, _, _, _):
                #expect(id != "src:builtin", "Informational built-in group leaked into rows")
            case .tool(let id, _, _, _, _, _, _, _):
                #expect(
                    !id.hasPrefix("src:builtin::"),
                    "Tool \(id) under the hidden built-in group leaked into rows"
                )
            }
        }
    }

    // MARK: - Fixtures

    private func makeToolEntry(name: String) -> ToolRegistry.ToolEntry {
        ToolRegistry.ToolEntry(
            name: name,
            description: "fixture",
            enabled: true,
            parameters: nil
        )
    }
}
