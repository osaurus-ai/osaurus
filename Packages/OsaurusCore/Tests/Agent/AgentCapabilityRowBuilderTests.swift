//
//  AgentCapabilityRowBuilderTests.swift
//  osaurus
//
//  Regression coverage for the Capabilities picker row builder, with a
//  specific focus on the `source(forTool:)` / `source(forSkill:)` helpers
//  used by `AgentCapabilityManagerView.childrenOf(groupId:)`.
//
//  Background: #1003 — clicking the master checkbox on a *collapsed* group
//  was a no-op because the previous `childrenOf` walked the rendered rows,
//  which omit children for collapsed groups. The fix routes `childrenOf`
//  through the new classifier helpers on `CapabilityRowBuilder`, which
//  bucket directly off the live registries. These tests pin the helpers'
//  classification rules and (most importantly) verify they stay in lockstep
//  with the inline bucketing inside `CapabilityRowBuilder.build` — if the
//  two ever diverge again, `build` and `childrenOf` would silently drop
//  capabilities and the bug regresses.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct AgentCapabilityRowBuilderTests {

    // MARK: - Skill classifier

    @Test func standaloneSkillBucketsToStandaloneGroup() {
        let skill = makeSkill(name: "standalone", pluginId: nil)
        let source = CapabilityRowBuilder.source(forSkill: skill, pluginNameById: [:])

        #expect(source == .standaloneSkills)
        #expect(source.groupId == "src:standalone-skills")
        #expect(source.isInformational == false)
    }

    @Test func pluginSkillBucketsToPluginGroupWithDisplayName() {
        let skill = makeSkill(name: "plugin-skill", pluginId: "com.example.plugin")
        let source = CapabilityRowBuilder.source(
            forSkill: skill,
            pluginNameById: ["com.example.plugin": "Example Plugin"]
        )

        #expect(source == .plugin(pluginId: "com.example.plugin", displayName: "Example Plugin"))
        #expect(source.groupId == "src:plugin:com.example.plugin")
    }

    @Test func pluginSkillFallsBackToPluginIdWhenNameLookupMisses() {
        let skill = makeSkill(name: "plugin-skill", pluginId: "com.example.unknown")
        let source = CapabilityRowBuilder.source(forSkill: skill, pluginNameById: [:])

        #expect(source == .plugin(pluginId: "com.example.unknown", displayName: "com.example.unknown"))
        #expect(source.groupId == "src:plugin:com.example.unknown")
    }

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
        // `capabilities_search` is registered as a built-in by
        // `ToolRegistry.registerBuiltInTools()` at singleton init.
        // It's also referenced from `CapabilityToolsTests`, so its name
        // is an established test fixture.
        let tool = makeToolEntry(name: "capabilities_search")
        let source = CapabilityRowBuilder.source(forTool: tool, pluginNameById: [:])

        #expect(source == .builtIn)
        #expect(source.groupId == "src:builtin")
        #expect(source.isInformational == true)
    }

    // MARK: - Builder / classifier consistency (regression seam for #1003)

    /// The bug in #1003 was caused by a divergence between `build` and
    /// `childrenOf`: the former emitted child rows under `groupId`, the
    /// latter walked rendered rows and missed collapsed groups. The
    /// post-fix invariant is: every child row `build` emits has a
    /// `groupId` that `source(forTool:)` / `source(forSkill:)` would
    /// independently agree on. If this ever fails again, bulk toggle is
    /// regressing — even if the visible UI still looks correct for an
    /// expanded group.
    @Test func sourceHelpersAgreeWithRowBuilderGroupIds() {
        let standaloneSkill = makeSkill(name: "standalone", pluginId: nil)
        let pluginSkill = makeSkill(name: "plugin-skill", pluginId: "com.example.plugin")

        let pluginNameById = ["com.example.plugin": "Example Plugin"]

        let input = CapabilityRowBuilder.Input(
            // Skills (not tools) drive this consistency check because the
            // only synthesizable non-informational tool sources are MCP /
            // sandbox / plugin, and registering one would mutate the
            // shared `ToolRegistry.shared` and bleed into other tests.
            // Skill plugin association is plain data, so we can exercise
            // both buckets without touching global state.
            visibleTools: [],
            visibleSkills: [standaloneSkill, pluginSkill],
            plugins: [],
            enabledToolNames: [],
            enabledSkillNames: [],
            searchQuery: "",
            filter: .all,
            // Force every group to expand so build emits child rows we can
            // diff against the classifier.
            expandedGroups: ["src:standalone-skills", "src:plugin:com.example.plugin"]
        )

        let rows = CapabilityRowBuilder.build(input)

        // For every emitted child row, the prefix in its row id must match
        // what `source(forSkill:)` would return for the same skill. This
        // is exactly the invariant `childrenOf(groupId:)` now relies on.
        // Row id encoding is `"<groupId>::skill::<uuid>"` — mirrors the
        // production decode in `CapabilityRowBuilder.decode(rowId:)`.
        for row in rows {
            guard case .skill(let id, _, _, _, _, _, _) = row else { continue }

            let parts = id.components(separatedBy: "::")
            #expect(parts.count == 3, "Malformed skill row id: \(id)")
            guard parts.count == 3, let uuid = UUID(uuidString: parts[2]) else { continue }

            let groupIdFromRow = parts[0]
            let skill = [standaloneSkill, pluginSkill].first { $0.id == uuid }
            #expect(skill != nil, "Row \(id) references unknown skill UUID \(uuid)")
            guard let skill else { continue }

            let classified = CapabilityRowBuilder.source(
                forSkill: skill,
                pluginNameById: pluginNameById
            )
            #expect(
                groupIdFromRow == classified.groupId,
                "build() emitted skill \(skill.name) under \(groupIdFromRow) but source(forSkill:) classifies it as \(classified.groupId)"
            )
        }
    }

    /// Smoke test the cross-cutting promise that motivated the fix:
    /// classifier-derived groupIds for our actionable fixtures must equal
    /// the set of buckets that `build` emits as group headers. If a group
    /// ever shows up in `build` that no classifier produces (or vice
    /// versa), a collapsed-group bulk toggle would silently miss it.
    @Test func classifierGroupIdsCoverEveryBuilderGroup() {
        let standaloneSkill = makeSkill(name: "standalone", pluginId: nil)
        let pluginSkill = makeSkill(name: "plugin-skill", pluginId: "com.example.plugin")

        let pluginNameById = ["com.example.plugin": "Example Plugin"]

        let input = CapabilityRowBuilder.Input(
            visibleTools: [],
            visibleSkills: [standaloneSkill, pluginSkill],
            plugins: [],
            enabledToolNames: [],
            enabledSkillNames: [],
            searchQuery: "",
            filter: .all,
            expandedGroups: []
        )

        let headerGroupIds = Set(
            CapabilityRowBuilder.build(input).compactMap { row -> String? in
                guard case .groupHeader(let id, _, _, _, _, _, _, _, _) = row else { return nil }
                return id
            }
        )

        let classifierGroupIds: Set<String> = [
            CapabilityRowBuilder.source(forSkill: standaloneSkill, pluginNameById: pluginNameById).groupId,
            CapabilityRowBuilder.source(forSkill: pluginSkill, pluginNameById: pluginNameById).groupId,
        ]

        #expect(
            headerGroupIds == classifierGroupIds,
            "build() emitted headers \(headerGroupIds) but classifiers produced \(classifierGroupIds)"
        )
    }

    /// Built-in / runtime-managed tools are surfaced in the picker only as
    /// data — `build` must not emit a header or any rows for them, since
    /// their per-row toggles are disabled and the master checkbox is a
    /// no-op (informational sources are skipped by `childrenOf`). Showing
    /// the group anyway just creates the misleading "looks toggleable but
    /// isn't" state that motivated hiding it.
    @Test func informationalGroupIsHiddenFromRows() {
        let builtInTool = makeToolEntry(name: "capabilities_search")
        let unclassifiedTool = makeToolEntry(name: "agent_capability_tests_unclassified_xyz")

        let input = CapabilityRowBuilder.Input(
            visibleTools: [builtInTool, unclassifiedTool],
            visibleSkills: [],
            plugins: [],
            enabledToolNames: [],
            enabledSkillNames: [],
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
            case .groupHeader(let id, _, _, _, _, _, _, _, _):
                #expect(id != "src:builtin", "Informational built-in group leaked into rows")
            case .tool(let id, _, _, _, _, _, _):
                #expect(
                    !id.hasPrefix("src:builtin::"),
                    "Tool \(id) under the hidden built-in group leaked into rows"
                )
            case .skill:
                continue
            }
        }
    }

    // MARK: - Fixtures

    private func makeSkill(name: String, pluginId: String?) -> Skill {
        Skill(
            id: UUID(),
            name: name,
            description: "fixture",
            version: "1.0.0",
            keywords: [],
            enabled: true,
            instructions: "fixture",
            isBuiltIn: false,
            pluginId: pluginId
        )
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
