//
//  ContextBudgetPreviewTests.swift
//  osaurusTests
//
//  Pin the welcome-screen Context Budget popover contract:
//  `SystemPromptComposer.composePreviewContext` must list every section
//  the next `composeChatContext(query: "")` will produce, except for the
//  two query-dependent ones (preflight tool delta + plugin companions)
//  which the budget UI explicitly cannot price ahead of time.
//
//  Why this matters: before this preview parity, the popover hid 6+
//  sections (`Agent Loop`, `Capability Discovery`, `Skills`,
//  `Model Family Guidance`, …) until the user hit send, making the
//  pre-send `Tools: 2.1k / Base Prompt: 10` reading look misleading
//  on chats that actually shipped multi-kilobyte prompts.
//
//  The tests cover the toggle matrix (tools on/off × memory on/off ×
//  tool mode auto/manual × model family) plus a parity check against
//  `composeChatContext` so the preview can never silently drift.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ContextBudgetPreviewTests {

    // MARK: - Helpers

    /// Run a body with a custom agent registered + cleaned up. Holds
    /// both the storage and sandbox locks because composePreviewContext
    /// reads `AgentManager.shared` and `ToolRegistry.shared`. The body
    /// is async so parity tests can await `composeChatContext`.
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
                name: "PreviewTestAgent-\(UUID().uuidString.prefix(6))",
                systemPrompt: "Test identity",
                agentAddress: "test-preview-\(UUID().uuidString)",
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

    // MARK: - Tools off + memory off

    /// The misleading-default fix. With both knobs off and no execution
    /// mode, the popover collapses to just the agent identity — no
    /// Agent Loop, no Capability Discovery, no Skills, no Tools.
    @Test("preview: tools off + memory off → only base section")
    func toolsOff_memoryOff_isJustBase() async {
        await withAgent(toolsDisabled: true, memoryDisabled: true) { agentId in
            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none
            )
            #expect(sectionIds(preview) == ["base"])
            #expect(preview.tools.isEmpty)
            #expect(preview.toolTokens == 0)
            #expect(preview.memorySection == nil)
            #expect(preview.preflightItems.isEmpty)
        }
    }

    /// `Memory` doesn't ride on `composePreviewContext` — the chat view
    /// surfaces it through `cachedMemoryTokens` so the preview manifest
    /// stays byte-stable. Memory-on with tools-off therefore still has
    /// a one-section manifest: the popover row comes from the separate
    /// `memoryTokens` plumb in `ContextBreakdown.from`.
    @Test("preview: tools off + memory on → manifest still only has base")
    func toolsOff_memoryOn_manifestStaysMinimal() async {
        await withAgent(toolsDisabled: true, memoryDisabled: false) { agentId in
            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none
            )
            #expect(sectionIds(preview) == ["base"])
        }
    }

    // MARK: - Tools on (auto)

    /// Auto-mode with tools on hits the always-loaded baseline → which
    /// trips the agent loop + capability discovery gates. This is the
    /// previously-hidden surface the welcome screen used to under-report.
    @Test("preview: tools on (auto) surfaces agent loop + capability discovery")
    func toolsOn_auto_includesLoopAndCapabilityNudge() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none
            )
            let ids = sectionIds(preview)
            #expect(ids.contains("base"))
            #expect(ids.contains("agentLoopGuidance"))
            #expect(ids.contains("capabilityNudge"))
            // No model-family hint without a model id, no skills configured.
            #expect(ids.contains("modelFamilyGuidance") == false)
            #expect(ids.contains("skills") == false)
            // Tools row is non-zero (always-loaded baseline JSON schemas).
            #expect(preview.toolTokens > 0)
            #expect(preview.tools.contains { $0.function.name == "todo" })
            #expect(preview.tools.contains { $0.function.name == "capabilities_search" })
        }
    }

    /// Manual mode opts out of preflight, which also opts out of the
    /// capability-discovery nudge (the nudge is gated on auto mode so
    /// manual agents don't see "go grow your tool list" guidance they
    /// can't act on). Loop guidance still fires because `todo`/etc.
    /// are always-loaded built-ins regardless of mode.
    @Test("preview: manual mode keeps agent loop, drops capability nudge")
    func toolsOn_manual_dropsCapabilityNudge() async {
        await withAgent(
            toolSelectionMode: .manual,
            manualToolNames: ["render_chart"]
        ) { agentId in
            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none
            )
            let ids = sectionIds(preview)
            #expect(ids.contains("agentLoopGuidance"))
            #expect(ids.contains("capabilityNudge") == false)
            #expect(preview.tools.contains { $0.function.name == "render_chart" })
        }
    }

    // MARK: - Model family guidance

    /// Family hints fire when the model id matches a known family
    /// substring. Pricing them ahead of time matters because some
    /// blocks (Gemma in particular) are several hundred tokens.
    @Test("preview: gemma model triggers Model Family Guidance row")
    func toolsOn_gemmaModel_includesModelFamilyGuidance() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none,
                model: "google/gemma-3-12b-it"
            )
            let ids = sectionIds(preview)
            #expect(ids.contains("modelFamilyGuidance"))
        }
    }

    /// Negative path: a model with no family marker (e.g. a generic
    /// llama finetune) should not get a guidance block. Locks the
    /// "silence is the default" rule so future entries to
    /// `ModelFamilyGuidance` don't accidentally bias every chat.
    @Test("preview: unknown model family → no Model Family Guidance row")
    func toolsOn_unknownModelFamily_skipsGuidance() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none,
                model: "mystery/llama-finetune-x"
            )
            #expect(sectionIds(preview).contains("modelFamilyGuidance") == false)
        }
    }

    // MARK: - Skills are load-on-demand only

    /// Regression for the 55k-token Skills bloat: skills MUST be
    /// discovered via `capabilities_search` and pulled in via
    /// `capabilities_load`, never auto-injected into the system prompt
    /// at compose time. Both compose paths must omit the `skills`
    /// section regardless of the agent's enabled-skills allowlist.
    @Test("compose: no `skills` section, even when the agent has skills enabled")
    func bagOfSkills_neverInjected() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            // Simulate the "all skills enabled" allowlist that the
            // capability seeder used to write — exactly the state that
            // produced the 55k Skills row in the original screenshot.
            AgentManager.shared.updateEnabledSkillNames(
                SkillManager.shared.skills.map(\.name),
                for: agentId
            )

            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none
            )
            let real = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                query: "",
                cachedPreflight: .empty
            )

            #expect(sectionIds(preview).contains("skills") == false)
            #expect(real.manifest.sections.map(\.id).contains("skills") == false)
        }
    }

    // MARK: - Parity with composeChatContext(query: "")

    /// The single most important guarantee: a sync preview compose
    /// matches an async send-time compose with an empty query +
    /// empty preflight, so the welcome-screen popover never lies
    /// about what the model will actually see on the next send.
    /// Differences are limited to:
    ///   - `pluginCompanions`: query-dependent, never present here
    ///     (preflight is empty).
    ///   - `memorySection` body: send path may attach memory text;
    ///     the preview surfaces tokens through `cachedMemoryTokens`
    ///     instead, so we compare manifests with `memory` filtered
    ///     out (not present in either path's section list anyway).
    @Test("parity: composePreviewContext == composeChatContext(query: '') sections")
    func parity_previewMatchesEmptyQueryCompose() async {
        await withAgent(memoryDisabled: true, toolSelectionMode: .auto) { agentId in
            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none,
                model: "gpt-5"
            )
            let real = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                model: "gpt-5",
                query: "",
                cachedPreflight: .empty
            )

            let previewIds = sectionIds(preview).filter { $0 != "pluginCompanions" }
            let realIds = real.manifest.sections.map(\.id).filter { $0 != "pluginCompanions" }
            #expect(previewIds == realIds)

            // Tools row matches too — both go through the same
            // `resolveTools` baseline (no preflight, no manual picks).
            #expect(preview.toolTokens == real.toolTokens)
            #expect(
                preview.tools.map(\.function.name).sorted()
                    == real.tools.map(\.function.name).sorted()
            )
        }
    }

    /// Parity holds in tools-off mode too: both paths collapse to a
    /// single-section manifest, regardless of which entry point the
    /// caller used. Catches any future drift where `composeChatContext`
    /// adds a tools-off-only section that `composePreviewContext`
    /// forgets to mirror.
    @Test("parity: tools off, both paths return only the base section")
    func parity_toolsOff_bothCollapseToBase() async {
        await withAgent(toolsDisabled: true, memoryDisabled: true) { agentId in
            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none
            )
            let real = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                query: "",
                cachedPreflight: .empty
            )

            #expect(sectionIds(preview) == ["base"])
            #expect(real.manifest.sections.map(\.id) == ["base"])
        }
    }

    // MARK: - Small-context auto-disable

    /// The original screenshot regression: Foundation (~4k context)
    /// got the full feature set and blew past its budget. The
    /// resolver-driven auto-disable must collapse tools to zero and
    /// flag the popover with `.tiny` so the user sees why.
    @Test("preview: foundation model auto-disables tools + memory and emits disable info")
    func tinyModel_disablesToolsAndMemory_andEmitsDisableInfo() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none,
                model: "foundation"
            )
            // Tools are gone — tools-off cascades to all the gated
            // sections too, so only `base` survives.
            #expect(preview.tools.isEmpty)
            #expect(preview.toolTokens == 0)
            #expect(sectionIds(preview) == ["base"])

            // Disable info is populated and reports both axes.
            guard let info = preview.contextDisable else {
                Issue.record("contextDisable missing for foundation model")
                return
            }
            #expect(info.sizeClass == .tiny)
            #expect(info.modelId == "foundation")
            #expect(info.disabledTools)
            #expect(info.disabledMemory)
        }
    }

    /// `.normal`-class models must NOT carry a disable info — that's
    /// what suppresses the popover notice for the common case. A
    /// regression here would dim every chat with a misleading "auto-
    /// disabled" line.
    @Test("preview: normal-context model has no disable info")
    func normalModel_noOverride() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none,
                model: "gpt-5"
            )
            #expect(preview.contextDisable == nil)
        }
    }

    /// When the agent itself already disabled tools, the auto-disable
    /// must not double-report: `disabledTools = false` means "I would
    /// have done it but the agent already did". Keeps the popover
    /// notice honest for users who disabled tools deliberately.
    @Test("preview: tiny model + agent-tools-off marks tools-disable as caused by agent")
    func tinyModel_withAgentToolsOff_doesNotDoubleClaim() async {
        await withAgent(toolsDisabled: true) { agentId in
            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none,
                model: "foundation"
            )
            // Disable info still fires (memory got auto-disabled), but
            // tools is reported as agent-driven, not size-class-driven.
            guard let info = preview.contextDisable else {
                Issue.record("contextDisable missing for foundation model")
                return
            }
            #expect(info.sizeClass == .tiny)
            #expect(info.disabledTools == false)
        }
    }

    /// Parity extension: the disable info matches across preview and
    /// send paths so the popover never lies about what the next send
    /// will actually do.
    @Test("parity: disable info matches between preview and composeChatContext")
    func parity_disableInfoMatches() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none,
                model: "foundation"
            )
            let real = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                model: "foundation",
                query: "",
                cachedPreflight: .empty
            )
            #expect(preview.contextDisable == real.contextDisable)
        }
    }
}
