//
//  ContextBudgetPreviewTests.swift
//  osaurusTests
//
//  Pin the welcome-screen Context Budget popover contract:
//  `SystemPromptComposer.composePreviewContext` must list every section
//  the next `composeChatContext(query: "")` will produce. Under Design C the
//  schema is a fixed hot set and the enabled-capabilities manifest is
//  query-independent, so the preview prices the static prefix exactly — there
//  is no longer a per-turn preflight/skill-search delta the UI must omit.
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
        computerUseEnabled: Bool = false,
        body: @MainActor @Sendable (UUID) async -> Void
    ) async {
        await SandboxTestLock.runWithStoragePaths {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-context-budget-preview-\(UUID().uuidString)",
                isDirectory: true
            )
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            let previousChatConfig = ChatConfigurationStore.load()
            var isolatedChatConfig = previousChatConfig
            isolatedChatConfig.defaultModel = nil
            ChatConfigurationStore.save(isolatedChatConfig)
            MemoryConfigurationStore.invalidateCache()
            // Phase B split the Default agent's model out of
            // ChatConfiguration. `effectiveModel` now consults
            // DefaultAgentConfigurationStore first, so isolating only
            // the legacy store leaves a stale model id (from a prior
            // test run on this machine) leaking into `snapshot.model`
            // and accidentally enabling family-specific guidance.
            // Drop the in-memory cache so the next `load()` re-reads
            // from the overridden root, which contains no config file
            // and therefore yields a clean default.
            DefaultAgentConfigurationStore.resetCacheForTests()
            var memoryConfig = MemoryConfiguration.default
            memoryConfig.enabled = true
            MemoryConfigurationStore.save(memoryConfig)
            AgentManager.shared.refresh()
            defer {
                ChatConfigurationStore.save(previousChatConfig)
                MemoryConfigurationStore.invalidateCache()
                DefaultAgentConfigurationStore.resetCacheForTests()
                OsaurusPaths.overrideRoot = previousRoot
                AgentManager.shared.refresh()
                try? FileManager.default.removeItem(at: root)
            }

            var settings = AgentSettings.defaultDisabled
            settings.computerUseEnabled = computerUseEnabled
            let agent = Agent(
                name: "PreviewTestAgent-\(UUID().uuidString.prefix(6))",
                systemPrompt: "Test identity",
                agentAddress: "test-preview-\(UUID().uuidString)",
                autonomousExec: autonomous ? AutonomousExecConfig(enabled: true) : nil,
                toolSelectionMode: toolSelectionMode,
                manualToolNames: manualToolNames,
                toolsEnabled: !toolsDisabled,
                memoryEnabled: !memoryDisabled,
                settings: settings
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
    @Test("preview: tools off + memory off → only platform + persona sections")
    func toolsOff_memoryOff_isJustBase() async {
        await withAgent(toolsDisabled: true, memoryDisabled: true) { agentId in
            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none
            )
            #expect(sectionIds(preview) == ["platform", "persona"])
            #expect(preview.tools.isEmpty)
            #expect(preview.toolTokens == 0)
            #expect(preview.memorySection == nil)
        }
    }

    /// `Memory` doesn't ride on `composePreviewContext` — the chat view
    /// surfaces it through `cachedMemoryTokens` so the preview manifest
    /// stays byte-stable. Memory-on with tools-off therefore still has
    /// a two-section manifest: the popover row comes from the separate
    /// `memoryTokens` plumb in `ContextBreakdown.from`.
    @Test("preview: tools off + memory on → manifest still only has platform + persona")
    func toolsOff_memoryOn_manifestStaysMinimal() async {
        await withAgent(toolsDisabled: true, memoryDisabled: false) { agentId in
            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none
            )
            #expect(sectionIds(preview) == ["platform", "persona"])
        }
    }

    // MARK: - Tools on (auto)

    /// Auto-mode with tools on hits the always-loaded baseline and prices
    /// capability discovery ahead of time. The agent-loop cheat sheet is
    /// schema-gated: loop tools are in the always-loaded baseline, so the
    /// preview prices it from turn 1 (it never flips mid-session).
    @Test("preview: tools on (auto) surfaces capability discovery and agent loop")
    func toolsOn_auto_includesCapabilityNudgeOnly() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none
            )
            let ids = sectionIds(preview)
            #expect(ids.contains("platform"))
            #expect(ids.contains("persona"))
            #expect(ids.contains("agentLoopGuidance"))
            #expect(ids.contains("capabilityNudge"))
            // No model-family hint without a model id, no skills configured.
            #expect(ids.contains("modelFamilyGuidance") == false)
            #expect(ids.contains("skills") == false)
            // Tools row is non-zero (always-loaded baseline JSON schemas).
            #expect(preview.toolTokens > 0)
            #expect(preview.tools.contains { $0.function.name == "todo" })
            #expect(preview.tools.contains { $0.function.name == "capabilities_discover" })
        }
    }

    /// Manual mode still includes the capability discovery tools in the
    /// schema. The prompt
    /// must explain those tools whenever they are callable; otherwise the
    /// model sees an opaque `capabilities_discover` function and #789-style
    /// "search is enabled but never found" failures are hard to diagnose.
    /// Loop guidance is schema-gated: present exactly when a loop tool
    /// resolves into the manual schema.
    @Test("preview: manual mode keeps capability nudge; loop guidance tracks schema")
    func toolsOn_manual_keepsCapabilityNudge() async {
        await withAgent(
            toolSelectionMode: .manual,
            manualToolNames: ["render_chart"]
        ) { agentId in
            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none
            )
            let ids = sectionIds(preview)
            let loopNames: Set<String> = ["todo", "complete", "clarify", "share_artifact"]
            let hasLoopTool = preview.tools.contains { loopNames.contains($0.function.name) }
            #expect(ids.contains("agentLoopGuidance") == hasLoopTool)
            #expect(ids.contains("capabilityNudge"))
            #expect(preview.tools.contains { $0.function.name == "render_chart" })
        }
    }

    /// The prompt-bloat fix prices the actual compact bootstrap schema, not
    /// the registry's full tool definitions. Loading a tool by name upgrades
    /// that compact placeholder back to the full schema for subsequent tool
    /// iterations.
    @Test("preview: always-loaded tools use compact bootstrap schemas")
    func toolsOn_auto_usesCompactBootstrapSchemas() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none
            )
            let fullBaseline = ToolRegistry.shared.alwaysLoadedSpecs(mode: .none)
            let fullBaselineTokens = ToolRegistry.shared.totalEstimatedTokens(for: fullBaseline)
            #expect(preview.toolTokens < fullBaselineTokens)

            let compactTodo = preview.tools.first { $0.function.name == "todo" }
            let fullTodo = TodoTool().asOpenAITool()
            #expect(compactTodo?.function.description != fullTodo.function.description)
            #expect(
                (compactTodo?.function.description?.count ?? 0)
                    < (fullTodo.function.description?.count ?? 0)
            )

            let upgraded = SystemPromptComposer.resolveTools(
                agentId: agentId,
                executionMode: .none,
                additionalToolNames: ["todo"]
            )
            let upgradedTodo = upgraded.first { $0.function.name == "todo" }
            #expect(upgradedTodo?.function.description == fullTodo.function.description)
            #expect(upgradedTodo?.function.parameters == fullTodo.function.parameters)
        }
    }

    /// A greeting should not carry dynamic discovery prompt text or enter
    /// the local tool-template path. Keep the always-loaded baseline frozen
    /// separately so turn 2 can grow into real work.
    @Test("compose: trivial greeting suppresses tool schema and dynamic prompt sections")
    func trivialGreeting_suppressesToolSchemaAndDynamicPromptSections() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            let context = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                query: "hi!"
            )
            let ids = sectionIds(context)
            #expect(SystemPromptComposer.isTrivialUserQuery("hi!"))
            #expect(ids.contains("capabilityNudge") == false)
            #expect(ids.contains("pluginCreator") == false)
            #expect(ids.contains("agentLoopGuidance") == false)
            #expect(context.tools.isEmpty)
            #expect(context.toolTokens == 0)
            #expect(context.alwaysLoadedNames.contains("capabilities_load"))
        }
    }

    /// The greeting-only fast path must not poison the session freeze. After
    /// a trivial first turn, a real request still gets the bootstrap catalog
    /// needed to load/discover capabilities.
    @Test("compose: real task after greeting restores bootstrap tools")
    func realTaskAfterGreeting_restoresBootstrapTools() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            let greeting = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                query: "hi!"
            )
            let followUp = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                query: "summarize this project",
                frozenAlwaysLoadedNames: greeting.alwaysLoadedNames
            )

            #expect(greeting.tools.isEmpty)
            #expect(greeting.alwaysLoadedNames.contains("capabilities_load"))
            #expect(followUp.tools.contains { $0.function.name == "capabilities_load" })
            #expect(followUp.tools.contains { $0.function.name == "capabilities_discover" })
            #expect(followUp.toolTokens > 0)
        }
    }

    /// "ok" is only harmless on a clean first turn. Once the session has
    /// cached tool state or prior task history, an acknowledgement can be the
    /// user's confirmation for a `clarify`/loop step and must keep schemas.
    @Test("compose: trivial continuation with cached state keeps bootstrap tools")
    func trivialContinuationWithCachedState_keepsBootstrapTools() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            let frozen = LoadedTools(
                ToolRegistry.shared.alwaysLoadedSpecs(mode: .none).map(\.function.name)
            )
            let context = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                query: "ok",
                messages: [ChatMessage(role: "user", content: "summarize this project")],
                frozenAlwaysLoadedNames: frozen
            )

            #expect(SystemPromptComposer.isTrivialUserQuery("ok"))
            #expect(context.tools.contains { $0.function.name == "capabilities_load" })
            #expect(context.tools.contains { $0.function.name == "capabilities_discover" })
            #expect(context.toolTokens > 0)
        }
    }

    /// The loop cheat-sheet is schema-gated: it renders from the FIRST
    /// real turn whenever loop tools resolve into the schema, so the model
    /// sees the "when to call which" guide on its first multi-step task
    /// and the section never flips mid-session (KV-prefix stable).
    @Test("compose: loop tools in schema enable agent loop guidance on turn 1")
    func loopToolsInSchema_enableAgentLoopGuidance() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            let context = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                query: "refactor the parser and add tests"
            )
            #expect(context.tools.contains { $0.function.name == "todo" })
            #expect(sectionIds(context).contains("agentLoopGuidance"))
        }
    }

    // MARK: - Computer Use

    /// The reported gap: enabling Computer Use injected the `computer_use`
    /// tool (folded into the aggregate `Tools` line) but added no prompt
    /// section, so the budget popover showed nothing labelled "Computer Use".
    /// Now an enabled custom agent surfaces a dedicated `computerUse` section
    /// AND the tool, so the capability is visible in the context list.
    @Test("preview: computer use enabled surfaces computerUse section + tool")
    func computerUseEnabled_surfacesSectionAndTool() async {
        await withAgent(toolSelectionMode: .auto, computerUseEnabled: true) { agentId in
            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none
            )
            #expect(sectionIds(preview).contains("computerUse"))
            #expect(preview.tools.contains { $0.function.name == ComputerUseTool.toolName })
        }
    }

    /// Default (disabled) custom agent: no `computer_use` tool, no section —
    /// the prompt never advertises a capability the agent hasn't opted into.
    @Test("preview: computer use disabled omits computerUse section + tool")
    func computerUseDisabled_omitsSectionAndTool() async {
        await withAgent(toolSelectionMode: .auto, computerUseEnabled: false) { agentId in
            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none
            )
            #expect(sectionIds(preview).contains("computerUse") == false)
            #expect(preview.tools.contains { $0.function.name == ComputerUseTool.toolName } == false)
        }
    }

    /// Parity: the section the welcome-screen preview prices is the exact
    /// one the next real send emits, so the popover can't drift on the
    /// Computer Use row.
    @Test("parity: computerUse section matches between preview and composeChatContext")
    func computerUse_previewMatchesCompose() async {
        await withAgent(
            memoryDisabled: true,
            toolSelectionMode: .auto,
            computerUseEnabled: true
        ) { agentId in
            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none,
                model: "gpt-5"
            )
            let real = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                model: "gpt-5",
                query: ""
            )
            #expect(sectionIds(preview) == real.manifest.sections.map(\.id))
            #expect(sectionIds(preview).contains("computerUse"))
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

    @Test("preview: DSV4 model triggers act-now Model Family Guidance row")
    func toolsOn_dsv4Model_includesModelFamilyGuidance() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none,
                model: "JANGQ/DeepSeek-V4-Flash-JANGTQ2"
            )
            let ids = sectionIds(preview)
            #expect(ids.contains("modelFamilyGuidance"))
            #expect(preview.prompt.contains("Do not say you will do it and then stop."))
        }
    }

    /// Unrecognised families (a generic llama finetune, Apple Foundation,
    /// etc.) now get the minimal *default* obedience block rather than
    /// nothing. Leaving them unguided paired them with the always-on
    /// prohibition sections and read as refusal-prone — the regression this
    /// fix targets. The block is the one for `.other`, kept short so it
    /// doesn't bias the prompt the way a full universal addendum would.
    @Test("preview: unknown model family → default obedience guidance row")
    func toolsOn_unknownModelFamily_usesDefaultGuidance() async {
        await withAgent(toolSelectionMode: .auto) { agentId in
            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none,
                model: "mystery/llama-finetune-x"
            )
            #expect(sectionIds(preview).contains("modelFamilyGuidance"))
            #expect(preview.prompt.contains(ModelFamilyGuidance.defaultGuidance))
        }
    }

    // MARK: - Skills are load-on-demand only

    /// Regression for the 55k-token Skills bloat: skills MUST be
    /// discovered via `capabilities_discover` and pulled in via
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
                query: ""
            )

            #expect(sectionIds(preview).contains("skills") == false)
            #expect(real.manifest.sections.map(\.id).contains("skills") == false)
        }
    }

    // MARK: - Parity with composeChatContext(query: "")

    /// The single most important guarantee: a sync preview compose
    /// matches an async send-time compose with an empty query, so the
    /// welcome-screen popover never lies
    /// about what the model will actually see on the next send. Under
    /// Design C the manifest is query-independent, so the only remaining
    /// gap is `memorySection` body (the send path may attach memory text;
    /// the preview surfaces tokens through `cachedMemoryTokens` instead),
    /// which is not part of either path's section list anyway.
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
                query: ""
            )

            let previewIds = sectionIds(preview)
            let realIds = real.manifest.sections.map(\.id)
            #expect(previewIds == realIds)

            // Tools row matches too — both go through the same
            // `resolveTools` baseline (hot set, no manual picks).
            #expect(preview.toolTokens == real.toolTokens)
            #expect(
                preview.tools.map(\.function.name).sorted()
                    == real.tools.map(\.function.name).sorted()
            )
        }
    }

    /// Parity holds in tools-off mode too: both paths collapse to a
    /// platform + persona manifest, regardless of which entry point the
    /// caller used. Catches any future drift where `composeChatContext`
    /// adds a tools-off-only section that `composePreviewContext`
    /// forgets to mirror.
    @Test("parity: tools off, both paths return only platform + persona")
    func parity_toolsOff_bothCollapseToBase() async {
        await withAgent(toolsDisabled: true, memoryDisabled: true) { agentId in
            let preview = SystemPromptComposer.composePreviewContext(
                agentId: agentId,
                executionMode: .none
            )
            let real = await SystemPromptComposer.composeChatContext(
                agentId: agentId,
                executionMode: .none,
                query: ""
            )

            #expect(sectionIds(preview) == ["platform", "persona"])
            #expect(real.manifest.sections.map(\.id) == ["platform", "persona"])
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
            // sections too, so only platform + persona survive.
            #expect(preview.tools.isEmpty)
            #expect(preview.toolTokens == 0)
            #expect(sectionIds(preview) == ["platform", "persona"])

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
                query: ""
            )
            #expect(preview.contextDisable == real.contextDisable)
        }
    }
}

// MARK: - Bar Segment Widths

/// Unit tests for `computeContextBudgetSegmentWidths`, the helper that
/// drives the stacked Context Budget bar at the top of the popover.
/// Locks the contract that prevents the original "broken when no ceiling"
/// bug: tiny entries with a hard 3pt floor would inflate combined widths
/// past the GeometryReader, so the orange Tools segment visibly shrank
/// even though the legend showed 81%.
@Suite
struct ContextBudgetSegmentWidthsTests {

    private let available: CGFloat = 216

    /// The screenshot's exact bucket counts (Platform/Persona/Agent DB/
    /// Agent Loop/Capability Discovery/Memory/Tools) with `breakdown.total`
    /// as the scale — the "no ceiling" case. Bars must fill the entire
    /// track, no slack on the right.
    @Test("no ceiling: widths fill the entire track")
    func noCeiling_fillsTrack() {
        let tokens = [16, 10, 681, 324, 116, 21, 5200]
        let total = tokens.reduce(0, +)

        let widths = computeContextBudgetSegmentWidths(
            tokens: tokens,
            totalTokens: total,
            available: available,
            fillsTrack: true
        )

        #expect(widths.count == tokens.count)
        let sum = widths.reduce(0, +)
        #expect(abs(sum - available) < 0.5)
    }

    /// With a ceiling far above `breakdown.total`, the bar should show
    /// real headroom: segments sum to `total/cap * available`, well below
    /// the full track. The HStack's trailing `Spacer` paints the rest.
    @Test("with ceiling: widths leave headroom proportional to budget cap")
    func withCeiling_leavesHeadroom() {
        let tokens = [681, 324, 116, 5200]
        let total = tokens.reduce(0, +)
        let cap = total * 10

        let widths = computeContextBudgetSegmentWidths(
            tokens: tokens,
            totalTokens: cap,
            available: available,
            fillsTrack: false
        )

        let sum = widths.reduce(0, +)
        let expectedSum = available * CGFloat(total) / CGFloat(cap)
        #expect(abs(sum - expectedSum) < 1.0)
        #expect(sum < available)
    }

    /// Pathological: 30 nearly-zero entries with a single dominant one.
    /// Old code would push the rendered HStack ~30pt past the track
    /// because every tiny entry got bumped to 3pt. The helper must cap
    /// the total at exactly `available` regardless of entry count.
    @Test("tiny entries do not overflow the available width")
    func manyTinyEntries_doNotOverflow() {
        var tokens = Array(repeating: 1, count: 30)
        tokens.append(5000)
        let total = tokens.reduce(0, +)

        let widths = computeContextBudgetSegmentWidths(
            tokens: tokens,
            totalTokens: total,
            available: available,
            fillsTrack: true
        )

        let sum = widths.reduce(0, +)
        #expect(sum <= available + 0.5)
        // Dominant entry should still be the largest segment.
        let maxIdx = widths.indices.max { widths[$0] < widths[$1] }
        #expect(maxIdx == tokens.count - 1)
    }

    /// Larger token counts must produce equal-or-wider segments at the
    /// no-ceiling fillsTrack call site. Catches future regressions where
    /// the floor or rounding step flips the ordering.
    @Test("segment widths are monotonic with token counts")
    func widths_areMonotonicWithTokens() {
        let tokens = [10, 100, 500, 1000, 5000]
        let total = tokens.reduce(0, +)

        let widths = computeContextBudgetSegmentWidths(
            tokens: tokens,
            totalTokens: total,
            available: available,
            fillsTrack: true
        )

        for i in 1 ..< widths.count {
            #expect(widths[i] >= widths[i - 1])
        }
    }

    /// Degenerate inputs collapse to zeros rather than crashing or
    /// producing NaN: the popover may render the bar before any tokens
    /// have been counted (empty conversation, model swap mid-stream).
    @Test("degenerate inputs return zero widths")
    func degenerateInputs_returnZeros() {
        #expect(
            computeContextBudgetSegmentWidths(
                tokens: [],
                totalTokens: 0,
                available: available,
                fillsTrack: true
            ).isEmpty
        )

        let zeroAvailable = computeContextBudgetSegmentWidths(
            tokens: [100, 200],
            totalTokens: 300,
            available: 0,
            fillsTrack: true
        )
        #expect(zeroAvailable == [0, 0])

        let zeroTotal = computeContextBudgetSegmentWidths(
            tokens: [0, 0, 0],
            totalTokens: 0,
            available: available,
            fillsTrack: true
        )
        #expect(zeroTotal == [0, 0, 0])
    }
}

// MARK: - Screen Context budget row

/// The frozen `[Screen Context]` snapshot rides on the latest user message
/// (like Memory) and must surface as its own "Screen Context" budget row —
/// plumbed through `ContextBreakdown.from(..., screenContextTokens:)` and the
/// live `ContextBudgetTracker`, never silently folded into Conversation.
@Suite(.serialized)
@MainActor
struct ScreenContextBudgetRowTests {

    private func baseManifest() -> PromptManifest {
        PromptManifest(sections: [
            .static(id: "platform", label: "Platform", content: "identity")
        ])
    }

    @Test("breakdown: screen-context tokens surface as a dedicated context row")
    func breakdown_addsDedicatedRow() {
        let bd = ContextBreakdown.from(
            manifest: baseManifest(),
            screenContextTokens: 137
        )
        #expect(bd.allEntries.first { $0.id == "screenContext" }?.tokens == 137)
        // Grouped with the other system-context rows (Memory/Tools), not messages.
        #expect(bd.context.contains { $0.id == "screenContext" })
        #expect(bd.messages.contains { $0.id == "screenContext" } == false)
    }

    @Test("breakdown: zero screen-context tokens add no phantom row")
    func breakdown_zeroOmitsRow() {
        let bd = ContextBreakdown.from(
            manifest: baseManifest(),
            screenContextTokens: 0
        )
        #expect(bd.allEntries.contains { $0.id == "screenContext" } == false)
    }

    /// During streaming the tracker carries the screen-context block as its own
    /// row; conversation is measured before the prefix is injected, so the two
    /// never double-count.
    @Test("tracker: screen-context row stays separate from conversation")
    func tracker_separateFromConversation() {
        let tracker = ContextBudgetTracker()
        tracker.snapshot(manifest: baseManifest(), toolTokens: 0)
        tracker.updateScreenContext(tokens: 88)
        tracker.updateConversation(tokens: 200)

        let bd = tracker.activeBreakdown(isActive: true, outputTurn: nil)
        #expect(bd?.allEntries.first { $0.id == "screenContext" }?.tokens == 88)
        #expect(bd?.allEntries.first { $0.id == "conversation" }?.tokens == 200)
    }
}
