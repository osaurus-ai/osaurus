//
//  PromptSectionOrderingTests.swift
//
//  Pin the section ID sequence emitted by `composeChatContext` /
//  `composePreviewContext` so the order doesn't silently drift.
//
//  Order matters because `PromptManifest.staticPrefixContent` walks the
//  list and stops at the first dynamic section — every static section
//  ahead of that break joins the cached KV-cache reuse window. Putting
//  cross-cutting rules (operational directives, agent loop when a session
//  has actually entered it) in front of mode-specific capability
//  (sandbox/folder) and recovery (capability nudge) maximises the cached
//  prefix and biases the model toward general behaviour before mode-
//  specific action.
//
//  Target order documented on `appendGatedSections`:
//
//    1. platform                  (forChat)
//    2. persona                   (forChat)
//    3. soul                      static, sandbox-only, frozen per session
//    4. selfImprovement           static, sandbox-only (canCreatePlugins-aware)
//    5. agentDB                   static framing, gated on dbEnabled
//    6. modelFamilyGuidance       static, gated on family match
//    7. grounding                 static, gated on tools present
//    8. codeStyle                 static, gated on file-mutation tools
//    9. riskAware                 static, gated on file-mutation tools
//   10. secretHandling            static, sandbox-only
//   11. agentLoopGuidance         static, gated on loop tools in schema
//   12. sandbox / folderContext   static framing, mode-specific
//   13. capabilityNudge           static, gated on capabilities_discover
//   14. enabledManifest           static, frozen (all enabled tools +
//                                  plugin skills + standalone skills)
//   15. skillsGovern              static (paired with enabledManifest)
//   16. pluginCreator             static (session-constant gate)
//   17. agentDBSchema             dynamic, live schema snapshot
//   18. sandboxState              dynamic, installed packages + secrets
//   19. sandboxUnavailable        dynamic
//
//  Sections 4/9 carry only session-constant framing; their mutable state
//  (13/14) rides in the dynamic block so a schema change, package install,
//  or new secret mid-session stays fresh without busting the cached prefix.
//  SOUL (3) is frozen per session for the same reason.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct PromptSectionOrderingTests {

    // MARK: - Helpers

    private func withAgent(
        toolsDisabled: Bool = false,
        memoryDisabled: Bool = false,
        toolSelectionMode: ToolSelectionMode? = nil,
        manualToolNames: [String]? = nil,
        autonomous: Bool = false,
        body: @MainActor @Sendable (UUID) async -> Void
    ) async {
        await SandboxTestLock.runWithStoragePaths {
            let agent = Agent(
                name: "OrderingTestAgent-\(UUID().uuidString.prefix(6))",
                systemPrompt: "Test identity",
                agentAddress: "test-ordering-\(UUID().uuidString)",
                autonomousExec: autonomous ? AutonomousExecConfig(enabled: true) : nil,
                toolSelectionMode: toolSelectionMode,
                manualToolNames: manualToolNames,
                toolsEnabled: !toolsDisabled,
                memoryEnabled: !memoryDisabled
            )
            AgentManager.shared.add(agent)
            await body(agent.id)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    private func sectionIds(_ ctx: ComposedContext) -> [String] {
        ctx.manifest.sections.map(\.id)
    }

    /// Assert that `subset`'s elements appear in `ids` in the listed
    /// order, with no other elements between adjacent pairs other than
    /// elements that don't appear in `subset` at all. Lets the test pin
    /// "X must come before Y" without needing every section to fire.
    private func assertOrderedPrefix(_ subset: [String], inside ids: [String]) {
        var lastIndex = -1
        for id in subset {
            guard let idx = ids.firstIndex(of: id) else {
                Issue.record("Expected section `\(id)` in \(ids)")
                return
            }
            #expect(
                idx > lastIndex,
                "Section `\(id)` appeared at index \(idx); previous required section was at \(lastIndex). Full order: \(ids)"
            )
            lastIndex = idx
        }
    }

    // MARK: - Auto mode, no execution mode

    /// Plain first-turn chat with auto-mode tools: cross-cutting rules
    /// (gemma family guidance) come before capability nudge. Agent-loop
    /// guidance is intentionally absent until history contains a loop
    /// tool call.
    @Test("ordering: auto + gemma + no exec mode")
    func ordering_autoGemmaNoExecMode() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            let ctx = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                model: "google/gemma-3-12b-it"
            )
            assertOrderedPrefix(
                [
                    "platform",
                    "persona",
                    "modelFamilyGuidance",
                    "capabilityNudge",
                ],
                inside: sectionIds(ctx)
            )
        }
    }

    // MARK: - Sandbox mode

    /// Sandbox mode: file-mutation tools fire, so codeStyle + riskAware
    /// land between modelFamilyGuidance and sandbox. Agent-loop guidance
    /// is still absent on first turn; sandbox sits before capability nudge.
    @Test("ordering: auto + gpt + sandbox mode")
    func ordering_autoGptSandbox() async {
        await SandboxTestLock.runWithStoragePaths {
            let agent = Agent(
                name: "OrderingTestAgent-Sandbox",
                systemPrompt: "Test identity",
                agentAddress: "test-ordering-sandbox-\(UUID().uuidString)",
                autonomousExec: AutonomousExecConfig(enabled: true)
            )
            AgentManager.shared.add(agent)
            BuiltinSandboxTools.register(
                agentId: agent.id.uuidString,
                agentName: agent.name,
                config: AutonomousExecConfig(enabled: true)
            )

            let ctx = await SystemPromptComposer.composeChatContext(
                agentId: agent.id,
                executionMode: .sandbox(hostRead: nil),
                model: "gpt-5"
            )
            assertOrderedPrefix(
                [
                    "platform",
                    "persona",
                    "selfImprovement",
                    "modelFamilyGuidance",
                    "codeStyle",
                    "riskAware",
                    "secretHandling",
                    "sandbox",
                    "capabilityNudge",
                ],
                inside: sectionIds(ctx)
            )

            ToolRegistry.shared.unregisterAllSandboxTools()
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    // MARK: - Sandbox-only block gating (Secret handling / Self-improvement /
    //         capability build ladder)

    /// In sandbox mode with plugin creation enabled, the three sandbox-gated
    /// blocks appear and carry their plugin-build lines: Self-improvement
    /// names sandbox plugins, and the capability nudge ends in a build step
    /// (not denial). Secret handling is present regardless of plugin creation.
    @Test("sandbox blocks: present with plugin lines when canCreatePlugins")
    func sandboxBlocks_presentWithPluginLinesWhenCanCreate() async {
        await SandboxTestLock.runWithStoragePaths {
            let agent = Agent(
                name: "SandboxBlocks-PluginOn",
                systemPrompt: "Test identity",
                agentAddress: "test-sandbox-blocks-on-\(UUID().uuidString)",
                autonomousExec: AutonomousExecConfig(enabled: true, pluginCreate: true)
            )
            AgentManager.shared.add(agent)
            BuiltinSandboxTools.register(
                agentId: agent.id.uuidString,
                agentName: agent.name,
                config: AutonomousExecConfig(enabled: true, pluginCreate: true)
            )

            let ctx = await SystemPromptComposer.composeChatContext(
                agentId: agent.id,
                executionMode: .sandbox(hostRead: nil),
                model: "gpt-5"
            )
            let ids = sectionIds(ctx)
            #expect(ids.contains("secretHandling"))
            #expect(ids.contains("selfImprovement"))
            #expect(ctx.prompt.contains("## Secret handling"))
            #expect(ctx.prompt.contains("## Self-improvement"))
            // Plugin-build lines present when plugin creation is on.
            #expect(ctx.prompt.contains("Build or update a sandbox plugin"))
            #expect(ctx.prompt.contains("build a sandbox plugin (see Building"))
            // The capability ladder ends in a build step, not denial.
            #expect(ctx.prompt.contains("Only after these come up empty"))
            // The plugin-creator backstop joins the prompt as a STATIC
            // section — its gate is session-constant, so it belongs in the
            // cached KV prefix rather than the dynamic tail.
            #expect(ids.contains("pluginCreator"))
            let pluginCreatorSection = ctx.manifest.sections.first { $0.id == "pluginCreator" }
            #expect(pluginCreatorSection?.cacheability == .static)
            #expect(ctx.staticPrefix.contains("## Building new tools"))

            ToolRegistry.shared.unregisterAllSandboxTools()
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    /// In sandbox mode with plugin creation OFF, the sections still appear but
    /// every plugin-build line is stripped — no wasted context describing an
    /// unavailable path. The non-plugin guidance (workspace persistence,
    /// SOUL.md, secret handling) stays.
    @Test("sandbox blocks: plugin lines stripped when canCreatePlugins is off")
    func sandboxBlocks_pluginLinesStrippedWhenCannotCreate() async {
        await SandboxTestLock.runWithStoragePaths {
            let agent = Agent(
                name: "SandboxBlocks-PluginOff",
                systemPrompt: "Test identity",
                agentAddress: "test-sandbox-blocks-off-\(UUID().uuidString)",
                autonomousExec: AutonomousExecConfig(enabled: true, pluginCreate: false)
            )
            AgentManager.shared.add(agent)
            BuiltinSandboxTools.register(
                agentId: agent.id.uuidString,
                agentName: agent.name,
                config: AutonomousExecConfig(enabled: true, pluginCreate: false)
            )

            let ctx = await SystemPromptComposer.composeChatContext(
                agentId: agent.id,
                executionMode: .sandbox(hostRead: nil),
                model: "gpt-5"
            )
            let ids = sectionIds(ctx)
            // Sections themselves remain.
            #expect(ids.contains("secretHandling"))
            #expect(ids.contains("selfImprovement"))
            #expect(ctx.prompt.contains("## Self-improvement"))
            #expect(ctx.prompt.contains("Workspace files persist across messages"))
            // Every plugin-build line is gone.
            #expect(!ctx.prompt.contains("Build or update a sandbox plugin"))
            #expect(!ctx.prompt.contains("build a sandbox plugin (see Building"))
            // The pluginCreator backstop also stays out without plugin creation.
            #expect(ids.contains("pluginCreator") == false)

            ToolRegistry.shared.unregisterAllSandboxTools()
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    /// Outside sandbox mode, none of the sandbox-only blocks appear — the
    /// non-sandbox prompt keeps the original "Discovering more tools" terminus.
    @Test("sandbox blocks: absent outside sandbox mode")
    func sandboxBlocks_absentOutsideSandbox() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            let ctx = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                model: "gpt-5"
            )
            let ids = sectionIds(ctx)
            #expect(ids.contains("secretHandling") == false)
            #expect(ids.contains("selfImprovement") == false)
            #expect(!ctx.prompt.contains("## Secret handling"))
            #expect(!ctx.prompt.contains("## Self-improvement"))
            // No sandbox primitives leak into the non-sandbox ladder.
            #expect(!ctx.prompt.contains("Assemble it from sandbox primitives"))
        }
    }

    // MARK: - Folder mode

    /// Folder mode parallels sandbox mode structurally. File-mutation
    /// tools (file_write, file_edit, shell_run) are always-loaded for
    /// folder mounts, so codeStyle + riskAware fire here too.
    @Test("ordering: auto + gpt + folder mode")
    func ordering_autoGptFolder() async {
        await SandboxTestLock.runWithStoragePaths {
            let agent = Agent(
                name: "OrderingTestAgent-Folder",
                systemPrompt: "Test identity",
                agentAddress: "test-ordering-folder-\(UUID().uuidString)"
            )
            AgentManager.shared.add(agent)
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("osaurus-folder-order-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let folderCtx = FolderContext(
                rootPath: tmp,
                projectType: .swift,
                tree: "./\nREADME.md",
                manifest: nil,
                gitStatus: nil,
                isGitRepo: false
            )
            FolderToolManager.shared.registerFolderTools(for: folderCtx)
            defer { FolderToolManager.shared.unregisterFolderTools() }

            let ctx = await SystemPromptComposer.composeChatContext(
                agentId: agent.id,
                executionMode: .hostFolder(folderCtx),
                model: "gpt-5"
            )
            assertOrderedPrefix(
                [
                    "platform",
                    "persona",
                    "modelFamilyGuidance",
                    "codeStyle",
                    "riskAware",
                    "folderContext",
                    "capabilityNudge",
                ],
                inside: sectionIds(ctx)
            )

            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    /// The loop cheat-sheet renders whenever a loop tool is in the schema
    /// (turn 1 included), in its order slot: after model-family guidance
    /// and before capability discovery.
    @Test("ordering: loop guidance sits between family guidance and capability nudge")
    func ordering_loopGuidanceSlot() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            let ctx = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                model: "google/gemma-3-12b-it"
            )
            assertOrderedPrefix(
                [
                    "platform",
                    "persona",
                    "modelFamilyGuidance",
                    "agentLoopGuidance",
                    "capabilityNudge",
                ],
                inside: sectionIds(ctx)
            )
        }
    }

    // MARK: - Statics-before-dynamics invariant

    /// The cached prefix is everything ahead of the first dynamic section.
    /// Ensure no dynamic section ID appears before the last static one in
    /// the rendered manifest, otherwise the prefix collapses unnecessarily.
    @Test("invariant: every static section precedes every dynamic section")
    func invariant_staticsLeadDynamics() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            let ctx = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                model: "google/gemma-3-12b-it"
            )
            var seenDynamic = false
            for section in ctx.manifest.sections {
                switch section.cacheability {
                case .dynamic:
                    seenDynamic = true
                case .static:
                    #expect(
                        !seenDynamic,
                        "Static section `\(section.id)` appeared after a dynamic section. Move it ahead of the dynamic block in `appendGatedSections` so the cached prefix stays maximal."
                    )
                }
            }
        }
    }

    // MARK: - codeStyle / riskAware gating

    /// Plain chat (no sandbox / folder) does NOT fire the discipline
    /// extracts — there's no file-mutation tool in the schema.
    @Test("gate: codeStyle + riskAware skip when no mutation tools resolve")
    func gate_disciplineSkipsWithoutMutationTools() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            let ctx = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none
            )
            let ids = sectionIds(ctx)
            #expect(ids.contains("codeStyle") == false)
            #expect(ids.contains("riskAware") == false)
        }
    }

    // MARK: - Grounding gating

    /// The grounding (anti-fabrication) directive rides on tools being
    /// present: a normal-context tool-enabled chat gets it; a tiny model
    /// whose tools auto-disable does not (the persona handles the no-tools
    /// case, and the section would otherwise just burn the 4K budget).
    @Test("gate: grounding present with tools, absent when tools auto-disable")
    func gate_groundingTracksTools() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            let on = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                model: "gpt-5"
            )
            #expect(sectionIds(on).contains("grounding"))

            let tiny = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                model: "foundation"
            )
            #expect(sectionIds(tiny).contains("grounding") == false)
            // Tiny stays minimal — tools-off cascades to every gated section.
            #expect(sectionIds(tiny) == ["platform", "persona"])
        }
    }

    // MARK: - KV-cache prefix stability

    /// KV-cache safety: every section — including `agentLoopGuidance`,
    /// which is now schema-gated rather than history-gated — must be
    /// present on BOTH the first turn and a turn after the model has
    /// entered the loop, so nothing appears/disappears mid-session and
    /// busts the cached prefix.
    @Test("kv-safety: new sections do not flip between turn 1 and a post-loop turn")
    func kvSafety_newSectionsStableAcrossTurns() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            let turn1 = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                model: "gpt-5"
            )
            let loopMessages = [
                ChatMessage(
                    role: "assistant",
                    content: nil,
                    tool_calls: [
                        ToolCall(
                            id: "call_todo",
                            type: "function",
                            function: ToolCallFunction(
                                name: "todo",
                                arguments: #"{"markdown":"- [ ] one"}"#
                            )
                        )
                    ],
                    tool_call_id: nil
                )
            ]
            let turn2 = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                model: "gpt-5",
                messages: loopMessages
            )
            let s1 = Set(sectionIds(turn1))
            let s2 = Set(sectionIds(turn2))
            // Section sets are identical across the loop boundary — the
            // cheat-sheet is schema-gated, so it is on BOTH turns.
            #expect(s2.subtracting(s1).isEmpty)
            #expect(s1.subtracting(s2).isEmpty)
            // The always-on sections are on BOTH turns.
            for id in ["grounding", "modelFamilyGuidance", "agentLoopGuidance"] {
                #expect(s1.contains(id))
                #expect(s2.contains(id))
            }
        }
    }

    // MARK: - Byte-identical prefix across a mid-session capabilities_load

    /// Design C's core prefix-cache prerequisite: the static system prompt is
    /// byte-identical across turn 1 and a later turn within the same session,
    /// even when (a) the user query changes and (b) the agent has loaded a new
    /// tool mid-session via `capabilities_load`. The enabled-capabilities
    /// manifest is frozen at session start (threaded back via `frozenManifest`)
    /// so it no longer shrinks as tools load — keeping `staticPrefix` constant
    /// so vmlx can reuse the cached KV prefix.
    @Test("kv-safety: system prompt + static prefix byte-identical across a capabilities_load turn")
    func kvSafety_promptByteIdenticalAcrossLoad() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            let turn1 = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                model: "gpt-5",
                query: "summarize this project for me"
            )

            // Steady-state follow-up: same frozen baselines, no new tool.
            // Both the system prompt and the tools array must be byte-stable.
            let steady = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                model: "gpt-5",
                query: "now refactor the networking layer",
                frozenAlwaysLoadedNames: turn1.alwaysLoadedNames,
                frozenManifest: turn1.enabledManifest
            )
            #expect(steady.prompt == turn1.prompt)
            #expect(steady.staticPrefix == turn1.staticPrefix)
            #expect(steady.tools.map(\.function.name) == turn1.tools.map(\.function.name))

            // Post-`capabilities_load` turn: a tool the agent loaded
            // mid-session enters the schema. The tools array legitimately
            // grows, but the system prompt (and its static prefix) must NOT
            // change — the frozen manifest does not shrink.
            let afterLoad = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                model: "gpt-5",
                query: "and render a chart of the results",
                additionalToolNames: ["render_chart"],
                frozenAlwaysLoadedNames: turn1.alwaysLoadedNames,
                frozenManifest: turn1.enabledManifest
            )
            #expect(afterLoad.prompt == turn1.prompt)
            #expect(afterLoad.staticPrefix == turn1.staticPrefix)
            // The loaded tool joined the schema (proves the load is real, so
            // the byte-identical prompt above is a genuine freeze, not a no-op).
            #expect(afterLoad.tools.contains { $0.function.name == "render_chart" })
            let beforeNames = Set(turn1.tools.map(\.function.name))
            #expect(beforeNames.isSubset(of: Set(afterLoad.tools.map(\.function.name))))
        }
    }

    // MARK: - Mutation invariance (live static sources frozen / relocated)

    /// The session-freeze + relocation contract: when mid-session-mutable
    /// sources change between turns (SOUL.md edited, a package installed),
    /// the static prefix stays byte-identical (SOUL frozen; packages live in
    /// the dynamic `sandboxState` section) while the dynamic tail reflects the
    /// change. Without the freeze/relocation, re-reading these live sources
    /// each compose would silently rewrite the cached prefix mid-session and
    /// tank KV-cache reuse — the exact regression this guards.
    @Test("kv-safety: mutating live sources leaves the static prefix byte-identical")
    func kvSafety_mutatingLiveSourcesKeepsStaticPrefixStable() async {
        await SandboxTestLock.runWithStoragePaths {
            let agent = Agent(
                name: "OrderingTestAgent-Mutation",
                systemPrompt: "Test identity",
                agentAddress: "test-ordering-mutation-\(UUID().uuidString)",
                autonomousExec: AutonomousExecConfig(enabled: true)
            )
            AgentManager.shared.add(agent)
            BuiltinSandboxTools.register(
                agentId: agent.id.uuidString,
                agentName: agent.name,
                config: AutonomousExecConfig(enabled: true)
            )

            // Seed SOUL.md so turn 1 captures a frozen value.
            let linuxName = SandboxAgentProvisioner.linuxName(for: agent.id.uuidString)
            let home = OsaurusPaths.containerAgentDir(linuxName)
            try? FileManager.default.createDirectory(
                at: home,
                withIntermediateDirectories: true
            )
            let soulURL = home.appendingPathComponent("SOUL.md", isDirectory: false)
            try? "SOUL_MARKER_V1 prefer Postgres".write(
                to: soulURL,
                atomically: true,
                encoding: .utf8
            )

            let turn1 = await SystemPromptComposer.composeChatContext(
                agentId: agent.id,
                executionMode: .sandbox(hostRead: nil),
                model: "gpt-5",
                query: "set up the project"
            )
            // Baseline: SOUL v1 present, no flask yet.
            #expect(turn1.prompt.contains("SOUL_MARKER_V1"))
            #expect(!turn1.prompt.contains("flask"))

            // Mutate every live source the prefix used to read fresh:
            //  - install a package (was a static `sandbox` line; now the
            //    dynamic `sandboxState` section)
            SandboxPackageManifest.shared.record(
                agentId: agent.id.uuidString,
                manager: .pip,
                packages: ["flask"]
            )
            //  - edit SOUL.md (was re-read each compose; now frozen per session)
            try? "SOUL_MARKER_V2 totally different".write(
                to: soulURL,
                atomically: true,
                encoding: .utf8
            )

            // Steady follow-up echoing turn-1 frozen snapshots.
            let turn2 = await SystemPromptComposer.composeChatContext(
                agentId: agent.id,
                executionMode: .sandbox(hostRead: nil),
                model: "gpt-5",
                query: "now add a route",
                frozenAlwaysLoadedNames: turn1.alwaysLoadedNames,
                frozenManifest: turn1.enabledManifest,
                frozenSoul: turn1.soul
            )

            // The cached prefix is untouched by either mutation.
            #expect(turn2.staticPrefix == turn1.staticPrefix)
            // SOUL stays frozen at v1 (the edit "applies next session").
            #expect(turn2.prompt.contains("SOUL_MARKER_V1"))
            #expect(!turn2.prompt.contains("SOUL_MARKER_V2"))
            // The package install IS reflected — but only in the dynamic
            // tail, after the static prefix break.
            #expect(turn2.prompt.contains("flask"))
            #expect(!turn2.staticPrefix.contains("flask"))

            ToolRegistry.shared.unregisterAllSandboxTools()
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }
}
