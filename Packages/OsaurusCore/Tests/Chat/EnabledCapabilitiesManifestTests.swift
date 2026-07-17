//
//  EnabledCapabilitiesManifestTests.swift
//
//  Pins `SystemPromptTemplates.enabledCapabilitiesManifest` — the
//  "do you have X" grounding block that stops small models from denying
//  an enabled-but-unloaded capability. Tests the pure renderer (grouping,
//  skill-before-tools ordering, the token cap collapse, compact mode)
//  against synthetic groups; derivation from the live registry is
//  exercised by the composer path and the off-CI `capability_claims`
//  eval domain.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct EnabledCapabilitiesManifestTests {

    private typealias Cap = SystemPromptTemplates.ManifestCapability
    private typealias Group = SystemPromptTemplates.ManifestPluginGroup

    @Test("empty groups render nothing")
    func emptyGroupsReturnNil() {
        #expect(SystemPromptTemplates.enabledCapabilitiesManifest(groups: []) == nil)
    }

    @Test("renders tools grouped by plugin with the intro + load instruction")
    func rendersGroupedToolsWithIntro() throws {
        let groups = [
            Group(
                pluginDisplay: "Osaurus Mail",
                skills: [],
                tools: [
                    Cap(name: "list_messages", description: "List inbox messages"),
                    Cap(name: "send_message", description: "Send an email"),
                ]
            )
        ]
        let rendered = try #require(
            SystemPromptTemplates.enabledCapabilitiesManifest(groups: groups)
        )

        #expect(rendered.contains("## Enabled capabilities"))
        #expect(!rendered.contains("not yet loaded"))
        #expect(rendered.contains("capabilities_load"))
        #expect(rendered.contains("Worked example"))
        #expect(rendered.contains("<plugin: Osaurus Mail>"))
        #expect(rendered.contains("  tool/list_messages — List inbox messages"))
        #expect(rendered.contains("  tool/send_message — Send an email"))
    }

    @Test("enabled plugin skill renders before its sibling tools")
    func skillRendersBeforeTools() throws {
        let groups = [
            Group(
                pluginDisplay: "Osaurus Browser",
                skills: [Cap(name: "Osaurus Browser", description: "Drive the browser")],
                tools: [Cap(name: "browser_navigate", description: "Open a URL")]
            )
        ]
        let rendered = try #require(
            SystemPromptTemplates.enabledCapabilitiesManifest(groups: groups)
        )
        #expect(!rendered.contains("(skill)"))
        let skillIndex = try #require(rendered.range(of: "skill/Osaurus Browser"))
        let toolIndex = try #require(rendered.range(of: "tool/browser_navigate —"))
        #expect(skillIndex.lowerBound < toolIndex.lowerBound)
    }

    @Test("skill governance is emitted only for verbose mixed groups")
    func skillGovernanceGateMatchesManifestShape() throws {
        let mixed = try #require(
            SystemPromptTemplates.enabledCapabilitiesManifest(
                groups: [
                    Group(
                        groupId: "browser",
                        pluginDisplay: "Browser",
                        skills: [Cap(name: "Browser Guide", description: "Use browser tools")],
                        tools: [Cap(name: "browser_open", description: "Open a page")]
                    )
                ]
            )
        )
        let toolsOnly = try #require(
            SystemPromptTemplates.enabledCapabilitiesManifest(
                groups: [
                    Group(
                        pluginDisplay: "Channels",
                        skills: [],
                        tools: [Cap(name: "list_channels", description: "List channels")]
                    )
                ]
            )
        )
        let skillsOnly = try #require(
            SystemPromptTemplates.enabledCapabilitiesManifest(
                groups: [
                    Group(
                        pluginDisplay: "Standalone skills",
                        skills: [Cap(name: "review", description: "Review code")],
                        tools: []
                    )
                ]
            )
        )
        let compactMixed = try #require(
            SystemPromptTemplates.enabledCapabilitiesManifest(
                groups: [
                    Group(
                        groupId: "browser",
                        pluginDisplay: "Browser",
                        skills: [Cap(name: "Browser Guide", description: "Use browser tools")],
                        tools: [Cap(name: "browser_open", description: "Open a page")]
                    )
                ],
                compact: true
            )
        )
        let skillCap = SystemPromptTemplates.enabledManifestSkillCap
        let overflowGoverned = try #require(
            SystemPromptTemplates.enabledCapabilitiesManifest(
                groups: [
                    Group(
                        pluginDisplay: "Earlier skills",
                        skills: (0 ..< skillCap).map {
                            Cap(name: "earlier_\($0)", description: "Earlier skill")
                        },
                        tools: []
                    ),
                    Group(
                        pluginDisplay: "Overflow Browser",
                        skills: [Cap(name: "Hidden Guide", description: "Use browser tools")],
                        tools: [Cap(name: "browser_open", description: "Open a page")]
                    ),
                ]
            )
        )

        #expect(SystemPromptTemplates.enabledManifestNeedsSkillGovernance(mixed, compact: false))
        #expect(!SystemPromptTemplates.enabledManifestNeedsSkillGovernance(toolsOnly, compact: false))
        #expect(!SystemPromptTemplates.enabledManifestNeedsSkillGovernance(skillsOnly, compact: false))
        #expect(!SystemPromptTemplates.enabledManifestNeedsSkillGovernance(compactMixed, compact: true))
        #expect(
            SystemPromptTemplates.enabledManifestNeedsSkillGovernance(
                overflowGoverned,
                compact: false
            )
        )
    }

    @Test("standalone skills render as a skills-only group with the loader intro")
    func standaloneSkillsGroupRenders() throws {
        // The composer enumerates every enabled non-plugin skill into a
        // trailing `Skills (no plugin)` group (tools empty). This is what
        // closes the denial hole for standalone skills, so the renderer
        // must surface each skill name under the grounding intro even with
        // no sibling tools.
        let groups = [
            Group(
                pluginDisplay: "Skills (no plugin)",
                skills: [
                    Cap(name: "data-viz", description: "Render charts inline"),
                    Cap(name: "code-review", description: "Catch obvious smells"),
                ],
                tools: []
            )
        ]
        let rendered = try #require(
            SystemPromptTemplates.enabledCapabilitiesManifest(groups: groups)
        )
        #expect(rendered.contains("## Enabled capabilities"))
        #expect(rendered.contains("capabilities_load"))
        #expect(rendered.contains("<plugin: Skills (no plugin)>"))
        #expect(rendered.contains("  skill/data-viz — Render charts inline"))
        #expect(rendered.contains("  skill/code-review — Catch obvious smells"))
    }

    @Test("compact mode renders one plugin/<id> line per plugin, not per tool")
    func compactTiersToPluginLines() throws {
        // A real plugin (groupId set) collapses to a single loadable
        // `plugin/<id>` line regardless of how many tools it owns — this is
        // the cold-prefill saving. Per-tool ids must NOT appear.
        let groups = [
            Group(
                groupId: "osaurus-mail",
                pluginDisplay: "Osaurus Mail",
                skills: [Cap(name: "Mail Helper", description: "Email skill")],
                tools: [
                    Cap(name: "list_messages", description: "List inbox messages"),
                    Cap(name: "send_message", description: "Send an email"),
                ]
            )
        ]
        let rendered = try #require(
            SystemPromptTemplates.enabledCapabilitiesManifest(groups: groups, compact: true)
        )
        #expect(rendered.contains("plugin/osaurus-mail — Osaurus Mail"))
        // Skill-governed plugins are flagged so the model expects the skill.
        #expect(rendered.contains("skill-governed"))
        // The whole point: no per-tool / per-skill id enumeration.
        #expect(!rendered.contains("tool/list_messages"))
        #expect(!rendered.contains("tool/send_message"))
        #expect(!rendered.contains("skill/Mail Helper"))
        // Compact intro teaches plugin loading and drops the worked example.
        #expect(rendered.contains("## Enabled capabilities"))
        #expect(rendered.contains("plugin/<id>"))
        #expect(rendered.contains("capabilities_load"))
        #expect(!rendered.contains("Worked example"))
    }

    @Test("compact mode lists synthetic (no group id) capabilities inline")
    func compactSyntheticGroupListsIdsInline() throws {
        // Groups with no loadable group id (built-in image tools, standalone
        // skills) have no `plugin/<id>` to expand, so their directly-loadable
        // ids are listed inline even in compact mode — dropping descriptions.
        let groups = [
            Group(
                pluginDisplay: "Built-in tools",
                skills: [],
                tools: [
                    Cap(name: "image", description: "Make or edit an image"),
                    Cap(name: "render_chart", description: "Render a chart"),
                ]
            )
        ]
        let rendered = try #require(
            SystemPromptTemplates.enabledCapabilitiesManifest(groups: groups, compact: true)
        )
        #expect(rendered.contains("  tool/image"))
        #expect(rendered.contains("  tool/render_chart"))
        #expect(!rendered.contains("image — Make or edit an image"))
        // The group has no loadable id, so it must NOT be collapsed into a
        // `plugin/<id> — Built-in tools` tier line. (The intro itself
        // references `plugin/<id>`/`plugin/calendar`, so a blanket
        // `!contains("plugin/")` would be wrong — assert on the display name.)
        #expect(!rendered.contains("— Built-in tools"))
    }

    @Test("skill cap collapses the universal-library overflow to a pointer line")
    func skillCapCollapsesOverflow() throws {
        // With the universal library, every installed skill is a manifest
        // candidate — the render must stay bounded no matter how many the
        // user imports. Past `enabledManifestSkillCap`, skills collapse to
        // a +N pointer that routes through capabilities_discover.
        let cap = SystemPromptTemplates.enabledManifestSkillCap
        let skills = (0 ..< cap + 3).map { Cap(name: "skill_\($0)", description: "d") }
        let groups = [
            Group(pluginDisplay: "Skills (no plugin)", skills: skills, tools: [])
        ]
        let rendered = try #require(
            SystemPromptTemplates.enabledCapabilitiesManifest(groups: groups)
        )
        #expect(rendered.contains("  skill/skill_0 — d"))
        #expect(rendered.contains("  skill/skill_\(cap - 1) — d"))
        #expect(!rendered.contains("skill/skill_\(cap) — d"))
        #expect(rendered.contains("+3 more skill(s) — call capabilities_discover to list them."))
    }

    @Test("compact mode also caps the inline standalone-skills list")
    func compactSkillCapCollapsesOverflow() throws {
        // The standalone-skills bucket is the one unbounded inline list in
        // compact mode (real plugins collapse to plugin/<id> lines), so it
        // takes the same cap — small-context models are exactly where an
        // unbounded skill menu hurts most.
        let cap = SystemPromptTemplates.enabledManifestSkillCap
        let skills = (0 ..< cap + 2).map { Cap(name: "skill_\($0)", description: "d") }
        let groups = [
            Group(pluginDisplay: "Skills (no plugin)", skills: skills, tools: [])
        ]
        let rendered = try #require(
            SystemPromptTemplates.enabledCapabilitiesManifest(groups: groups, compact: true)
        )
        #expect(rendered.contains("  skill/skill_0"))
        #expect(rendered.contains("  skill/skill_\(cap - 1)"))
        #expect(!rendered.contains("skill/skill_\(cap)\n"))
        #expect(rendered.contains("+2 more skill(s) — capabilities_discover lists them."))
    }

    @Test("intro warns that the frozen list may miss later installs")
    func introCarriesStalenessHint() throws {
        // The manifest is frozen at session start; skills installed
        // mid-session are searchable but unlisted. Without this hint the
        // model would deny them on the list's authority.
        let groups = [
            Group(pluginDisplay: "P", skills: [Cap(name: "s", description: "d")], tools: [])
        ]
        let verbose = try #require(
            SystemPromptTemplates.enabledCapabilitiesManifest(groups: groups)
        )
        #expect(verbose.contains("frozen at session start"))
        let compact = try #require(
            SystemPromptTemplates.enabledCapabilitiesManifest(groups: groups, compact: true)
        )
        #expect(compact.contains("frozen at session start"))
    }

    @Test("token cap collapses overflow plugins to a pointer line")
    func capCollapsesOverflow() throws {
        let cap = SystemPromptTemplates.enabledManifestToolCap
        let bigTools = (0 ..< cap).map { Cap(name: "tool_\($0)", description: "d") }
        let overflowTools = [
            Cap(name: "late_tool_a", description: "d"),
            Cap(name: "late_tool_b", description: "d"),
            Cap(name: "late_tool_c", description: "d"),
        ]
        let groups = [
            Group(pluginDisplay: "BigPlugin", skills: [], tools: bigTools),
            Group(pluginDisplay: "LatePlugin", skills: [], tools: overflowTools),
        ]
        let rendered = try #require(
            SystemPromptTemplates.enabledCapabilitiesManifest(groups: groups)
        )
        // The cap-filling plugin renders its tools; the overflow plugin
        // collapses to a +N pointer instead of per-tool lines.
        #expect(rendered.contains("  tool/tool_0 — d"))
        #expect(rendered.contains("<plugin: LatePlugin>"))
        #expect(rendered.contains("+3 more tool(s) — call capabilities_discover to list them."))
        #expect(!rendered.contains("late_tool_a — d"))
    }
}
