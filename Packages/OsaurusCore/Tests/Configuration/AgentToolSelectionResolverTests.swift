//
//  AgentToolSelectionResolverTests.swift
//  OsaurusCoreTests
//
//  Pins the portable tool-selection mapping used by the declarative
//  `agents[].tools` / `mcp_servers` / `plugins` keys: grouped tools travel
//  by group NAME, ungrouped tools by tool name, and applying a document
//  from another machine degrades to notes instead of failing.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentToolSelectionResolverTests {

    private let groups: [PortableToolGroup: [String]] = [
        .mcpServer("Linear"): ["linear_create_issue", "linear_search"],
        .mcpServer("Notion"): ["notion_read_page"],
        .plugin("osaurus.notes"): ["notes_create", "notes_list"],
    ]

    @Test
    func export_splitsUngroupedToolsFromGroups() {
        let exported = AgentToolSelectionResolver.export(
            manualToolNames: ["fetch", "linear_search", "notes_create", "time", "fetch"],
            groups: groups)
        #expect(exported.toolNames == ["fetch", "time"])
        #expect(exported.enabledMCPServers == ["Linear"])
        #expect(exported.disabledMCPServers == ["Notion"])
        #expect(exported.enabledPlugins == ["osaurus.notes"])
        #expect(exported.disabledPlugins.isEmpty)
    }

    @Test
    func export_partialGroupSelectionCountsAsEnabled() {
        let exported = AgentToolSelectionResolver.export(
            manualToolNames: ["linear_search"], groups: groups)
        #expect(exported.enabledMCPServers == ["Linear"])
    }

    @Test
    func apply_enabledGroupAddsEveryLocalTool() {
        let applied = AgentToolSelectionResolver.apply(
            current: ["fetch"],
            baseToolNames: nil,
            enabledGroups: [.mcpServer("Linear")],
            disabledGroups: [],
            registered: ["fetch", "time"],
            groups: groups)
        #expect(applied.manualToolNames == ["fetch", "linear_create_issue", "linear_search"])
        #expect(applied.missingTools.isEmpty)
        #expect(applied.missingGroups.isEmpty)
    }

    @Test
    func apply_disabledGroupRemovesItsTools() {
        let applied = AgentToolSelectionResolver.apply(
            current: ["fetch", "notes_create", "notes_list"],
            baseToolNames: nil,
            enabledGroups: [],
            disabledGroups: [.plugin("osaurus.notes")],
            registered: ["fetch"],
            groups: groups)
        #expect(applied.manualToolNames == ["fetch"])
    }

    @Test
    func apply_baseListReplacesUngroupedButKeepsGroupedSelections() {
        let applied = AgentToolSelectionResolver.apply(
            current: ["fetch", "time", "linear_search"],
            baseToolNames: ["web_search"],
            enabledGroups: [],
            disabledGroups: [],
            registered: ["fetch", "time", "web_search"],
            groups: groups)
        #expect(applied.manualToolNames == ["linear_search", "web_search"])
    }

    @Test
    func apply_reportsMissingToolsAndGroupsWithoutFailing() {
        let applied = AgentToolSelectionResolver.apply(
            current: [],
            baseToolNames: ["fetch", "vision"],
            enabledGroups: [.mcpServer("Jira")],
            disabledGroups: [.mcpServer("Ghost")],
            registered: ["fetch"],
            groups: groups)
        #expect(applied.manualToolNames == ["fetch"])
        #expect(applied.missingTools == ["vision"])
        #expect(applied.missingGroups == ["Jira"])
    }

    @Test
    func roundTrip_exportThenApplyIsStable() {
        let original = ["fetch", "time", "linear_create_issue", "linear_search", "notes_create", "notes_list"]
        let exported = AgentToolSelectionResolver.export(manualToolNames: original, groups: groups)
        let applied = AgentToolSelectionResolver.apply(
            current: [],
            baseToolNames: exported.toolNames,
            enabledGroups: exported.enabledMCPServers.map { .mcpServer($0) }
                + exported.enabledPlugins.map { .plugin($0) },
            disabledGroups: exported.disabledMCPServers.map { .mcpServer($0) }
                + exported.disabledPlugins.map { .plugin($0) },
            registered: Set(original),
            groups: groups)
        #expect(Set(applied.manualToolNames) == Set(original))
    }
}
