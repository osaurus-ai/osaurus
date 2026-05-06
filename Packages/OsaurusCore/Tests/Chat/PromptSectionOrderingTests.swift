//
//  PromptSectionOrderingTests.swift
//
//  Pin the section ID sequence emitted by `composeChatContext` /
//  `composePreviewContext` so the order doesn't silently drift.
//
//  Order matters because `PromptManifest.staticPrefixContent` walks the
//  list and stops at the first dynamic section — every static section
//  ahead of that break joins the cached KV-cache reuse window. Putting
//  cross-cutting rules (operational directives, agent loop) in front of
//  mode-specific capability (sandbox/folder) and recovery (capability
//  nudge) maximises the cached prefix and biases the model toward
//  general behaviour before mode-specific action.
//
//  Target order documented on `appendGatedSections`:
//
//    1. platform                  (forChat)
//    2. persona                   (forChat)
//    3. modelFamilyGuidance       static, gated on family match
//    4. codeStyle                 static, gated on file-mutation tools
//    5. riskAware                 static, gated on file-mutation tools
//    6. agentLoopGuidance         static, gated on loop tools
//    7. sandbox / folderContext   static, mode-specific
//    8. capabilityNudge           static, gated on capabilities_search
//    9. sandboxUnavailable        dynamic
//   10. pluginCompanions          dynamic
//   11. skillSuggestions          dynamic
//   12. pluginCreator             dynamic
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

    /// Plain chat with auto-mode tools: cross-cutting rules (gemma family
    /// guidance) come before agent loop, then capability nudge. No
    /// sandbox / folder section in this mode.
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
                    "agentLoopGuidance",
                    "capabilityNudge",
                ],
                inside: sectionIds(ctx)
            )
        }
    }

    // MARK: - Sandbox mode

    /// Sandbox mode: file-mutation tools fire, so codeStyle + riskAware
    /// land between modelFamilyGuidance and agentLoopGuidance. Sandbox
    /// section sits between agent loop and capability nudge.
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
                executionMode: .sandbox,
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
                    "agentLoopGuidance",
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
                    "agentLoopGuidance",
                    "folderContext",
                    "capabilityNudge",
                ],
                inside: sectionIds(ctx)
            )

            _ = await AgentManager.shared.delete(id: agent.id)
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
