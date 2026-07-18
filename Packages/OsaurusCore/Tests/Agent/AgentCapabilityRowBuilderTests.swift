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
import MCP
import Testing

@testable import OsaurusCore

// Serialized: the count-semantics test registers tools in the shared
// `ToolRegistry` under a redirected `ToolConfigurationStore` directory,
// which is process-global state.
@Suite(.serialized)
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
            case .groupHeader(let id, _, _, _, _, _):
                #expect(id != "src:builtin", "Informational built-in group leaked into rows")
            case .tool(let id, _, _, _, _, _, _, _):
                #expect(
                    !id.hasPrefix("src:builtin::"),
                    "Tool \(id) under the hidden built-in group leaked into rows"
                )
            }
        }
    }

    // MARK: - Count semantics

    /// Group header counts must reflect the FULL group, not the
    /// search/filter-reduced subset — the master checkbox acts on the whole
    /// group via `childrenOf` (registry-based), so a badge computed from the
    /// rendered subset would disagree with what the checkbox toggles.
    @Test func groupCountsIgnoreSearchAndAssignedFilter() {
        withTempToolConfig {
            let registry = ToolRegistry.shared
            let suffix = UUID().uuidString.prefix(8)
            let provider = MCPProvider(
                name: "count_probe_\(suffix)",
                url: "https://example.invalid/mcp"
            )
            let mcpTools = [
                MCP.Tool(name: "alpha_\(suffix)", description: "test", inputSchema: ["type": "object"]),
                MCP.Tool(name: "beta_\(suffix)", description: "test", inputSchema: ["type": "object"]),
            ]
            let registered = MCPProviderManager.shared.registerDiscoveredTools(
                mcpTools,
                for: provider.id,
                provider: provider
            )
            let alpha = registered[0].name
            let beta = registered[1].name
            defer { registry.unregister(names: [alpha, beta]) }

            let visibleTools = [makeToolEntry(name: alpha), makeToolEntry(name: beta)]

            // Search matches only `alpha`; only `beta` is assigned. The
            // header must still report 1 of 2 — the full group.
            let input = CapabilityRowBuilder.Input(
                visibleTools: visibleTools,
                plugins: [],
                enabledToolNames: [beta],
                toolMode: .auto,
                searchQuery: "alpha",
                filter: .all,
                expandedGroups: []
            )
            let rows = CapabilityRowBuilder.build(input)

            let header = rows.compactMap { row -> (enabled: Int, total: Int)? in
                guard case .groupHeader(_, _, _, let enabledCount, let totalCount, _) = row else {
                    return nil
                }
                return (enabledCount, totalCount)
            }.first
            #expect(header?.enabled == 1, "Enabled count should cover the full group")
            #expect(header?.total == 2, "Total count should cover the full group")

            // Only the matching tool row is emitted, though.
            let toolRowIds = rows.compactMap { row -> String? in
                guard case .tool(let id, _, _, _, _, _, _, _) = row else { return nil }
                return id
            }
            #expect(toolRowIds.count == 1)
            #expect(toolRowIds.first?.hasSuffix("::tool::\(alpha)") == true)

            // Assigned filter: same full-group counts, only `beta` emitted.
            let assignedInput = CapabilityRowBuilder.Input(
                visibleTools: visibleTools,
                plugins: [],
                enabledToolNames: [beta],
                toolMode: .auto,
                searchQuery: "",
                filter: .assigned,
                expandedGroups: []
            )
            let assignedRows = CapabilityRowBuilder.build(assignedInput)
            for row in assignedRows {
                if case .groupHeader(_, _, _, let enabledCount, let totalCount, _) = row {
                    #expect(enabledCount == 1)
                    #expect(totalCount == 2)
                }
            }
        }
    }

    // MARK: - Fixtures

    /// Redirect tool-config persistence to a throwaway directory so tool
    /// registration in tests never touches the user's real `tools.json`.
    private func withTempToolConfig<T>(_ body: () throws -> T) rethrows -> T {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-capability-rowbuilder-\(UUID().uuidString)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let previous = ToolConfigurationStore.overrideDirectory
        ToolConfigurationStore.overrideDirectory = tmp
        defer {
            ToolConfigurationStore.overrideDirectory = previous
            try? FileManager.default.removeItem(at: tmp)
        }
        return try body()
    }

    private func makeToolEntry(name: String) -> ToolRegistry.ToolEntry {
        ToolRegistry.ToolEntry(
            name: name,
            description: "fixture",
            enabled: true,
            parameters: nil
        )
    }
}
