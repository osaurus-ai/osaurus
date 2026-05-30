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
//    9. capabilityNudge           static, gated on capabilities_search
//   10. sandboxUnavailable        dynamic
//   11. pluginCompanions          dynamic
//   12. skillSuggestions          dynamic
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
                disableTools: toolsDisabled ? true : nil,
                disableMemory: memoryDisabled ? true : nil
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
                model: "google/gemma-3-12b-it",
                cachedPreflight: .empty
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
                model: "gpt-5",
                cachedPreflight: .empty
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
                model: "gpt-5",
                cachedPreflight: .empty
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
                messages: messages,
                cachedPreflight: .empty
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
                model: "google/gemma-3-12b-it",
                cachedPreflight: .empty
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
                executionMode: .none,
                cachedPreflight: .empty
            )
            let ids = sectionIds(ctx)
            #expect(ids.contains("codeStyle") == false)
            #expect(ids.contains("riskAware") == false)
        }
    }
}
