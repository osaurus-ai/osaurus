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

    // MARK: - Apple app groups

    /// Apple tools are registered as built-ins but must land in their own
    /// toggleable per-app group, ahead of the informational fallback.
    @Test func appleToolClassifiesToItsAppGroup() {
        let tool = makeToolEntry(name: "calendar_events")
        let source = CapabilityRowBuilder.source(forTool: tool, pluginNameById: [:])

        #expect(source == .appleApp(.calendar))
        #expect(source.groupId == "src:apple:calendar")
        #expect(source.isInformational == false)
        #expect(source.togglesAsGroup == true)
        #expect(CapabilitySource.appleApp(fromGroupId: source.groupId) == .calendar)
        #expect(CapabilitySource.appleApp(fromGroupId: "src:plugin:osaurus.calendar") == nil)
    }

    /// Hosts that exclude Apple apps (the Default agent) get no Apple rows
    /// at all — the tools fold into the hidden built-in bucket.
    @Test func appleGroupsHiddenWhenHostExcludesThem() {
        let input = CapabilityRowBuilder.Input(
            visibleTools: [makeToolEntry(name: "calendar_events"), makeToolEntry(name: "mail_list")],
            plugins: [],
            enabledToolNames: ["calendar_events"],
            toolMode: .auto,
            searchQuery: "",
            filter: .all,
            expandedGroups: ["src:apple:calendar"],
            includesAppleApps: false
        )
        #expect(CapabilityRowBuilder.build(input).isEmpty)
    }

    /// One header per app in catalog order, counts over the app's tools,
    /// every row badged as a group toggle, and a "Permission needed" status
    /// only on an enabled app with a missing grant.
    @Test func appleGroupsRenderPerAppWithStatus() {
        let tools = [
            makeToolEntry(name: "mail_list"),
            makeToolEntry(name: "calendar_events"),
            makeToolEntry(name: "calendar_list"),
        ]
        let input = CapabilityRowBuilder.Input(
            visibleTools: tools,
            plugins: [],
            enabledToolNames: AppleApp.toolNames(for: [.calendar]),
            toolMode: .auto,
            searchQuery: "",
            filter: .all,
            expandedGroups: ["src:apple:calendar"],
            includesAppleApps: true,
            appleAppMissingPermissions: [.calendar: [.calendar], .mail: [.automationMail]]
        )
        let rows = CapabilityRowBuilder.build(input)

        let headers = rows.compactMap { row -> (id: String, enabled: Int, total: Int, status: CapabilityGroupStatus?)? in
            guard case .groupHeader(let id, _, _, let enabled, let total, _, let status) = row else { return nil }
            return (id, enabled, total, status)
        }
        #expect(headers.map(\.id) == ["src:apple:calendar", "src:apple:mail"])
        #expect(headers[0].enabled == 2 && headers[0].total == 2)
        #expect(headers[0].status?.isWarning == true)
        #expect(headers[0].status?.isActionable == true)
        // Mail is off, so macOS has not been asked yet — no badge.
        #expect(headers[1].enabled == 0 && headers[1].total == 1)
        #expect(headers[1].status == nil)

        let toolRows = rows.compactMap { row -> (name: String, enabled: Bool, label: String?)? in
            guard case .tool(_, let name, _, let enabled, _, let label, _, _) = row else { return nil }
            return (name, enabled, label)
        }
        #expect(toolRows.map(\.name) == ["calendar_events", "calendar_list"])
        #expect(toolRows.allSatisfy { $0.enabled && $0.label == CapabilityRowBuilder.appleGroupToggleLabel })
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
                guard case .groupHeader(_, _, _, let enabledCount, let totalCount, _, _) = row else {
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
                if case .groupHeader(_, _, _, let enabledCount, let totalCount, _, _) = row {
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
