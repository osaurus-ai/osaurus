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
//    3. soul                      static, sandbox-only, gated on SOUL.md non-empty
//    4. modelFamilyGuidance       static, gated on family match
//    5. codeStyle                 static, gated on file-mutation tools
//    6. riskAware                 static, gated on file-mutation tools
//    7. agentLoopGuidance         static, gated on prior loop-tool use
//    8. sandbox / folderContext   static, mode-specific
//    9. capabilityNudge           static, gated on capabilities_discover
//   10. enabledManifest           static, frozen (all enabled tools +
//                                  plugin skills + standalone skills)
//   11. skillsGovern              static (paired with enabledManifest)
//   12. sandboxUnavailable        dynamic
//   13. pluginCreator             dynamic
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
                    "modelFamilyGuidance",
                    "codeStyle",
                    "riskAware",
                    "sandbox",
                    "capabilityNudge",
                ],
                inside: sectionIds(ctx)
            )

            ToolRegistry.shared.unregisterAllSandboxTools()
            _ = await AgentManager.shared.delete(id: agent.id)
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

    /// Once a loop tool is in history, the continuation guide joins the
    /// static prefix in its original order slot: after model-family guidance
    /// and before capability discovery.
    @Test("ordering: prior loop use places agent loop before capability nudge")
    func ordering_priorLoopUse() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            let messages = [
                ChatMessage(
                    role: "assistant",
                    content: nil,
                    tool_calls: [
                        ToolCall(
                            id: "call_todo",
                            type: "function",
                            function: ToolCallFunction(name: "todo", arguments: #"{"markdown":"- [ ] one"}"#)
                        )
                    ],
                    tool_call_id: nil
                )
            ]
            let ctx = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                model: "google/gemma-3-12b-it",
                messages: messages
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

    /// KV-cache safety: the new always-on sections (grounding,
    /// modelFamilyGuidance-for-every-family) must be present on BOTH the
    /// first turn and a turn after the model has entered the loop, so they
    /// never appear/disappear mid-session and bust the cached prefix. The
    /// ONLY legitimate mid-session section delta is `agentLoopGuidance`,
    /// which (for non-small-context models) intentionally joins once the
    /// session enters the loop — that pre-existing flip is unchanged here.
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
            // Only the loop cheat-sheet may be added on the later turn.
            #expect(s2.subtracting(s1) == ["agentLoopGuidance"])
            // Nothing disappears mid-session.
            #expect(s1.subtracting(s2).isEmpty)
            // The new always-on sections are on BOTH turns.
            for id in ["grounding", "modelFamilyGuidance"] {
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
}
