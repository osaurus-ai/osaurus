//
//  AgentAbilityContextPreview.swift
//  osaurus
//
//  Prices an agent's DRAFT capability state for the Abilities overview:
//  the editor's local toggle values are folded into an `AgentConfigSnapshot`
//  (before the debounced save lands) and run through the exact same
//  `composePreviewContext` pipeline the chat Context Budget popover uses,
//  so the overview can never disagree with the next real send's gates.
//
//  The headline number is "estimated startup context" — the static system
//  prompt + resolved tool schema a fresh chat would ship — NOT the model's
//  context window and NOT a tokenizer-accurate count (everything rides on
//  the shared chars/4 heuristic in `TokenEstimator`). Memory is a per-turn,
//  query-dependent injection, so it is surfaced as an upper bound
//  (`memoryUpperTokens`, the user's configured memory budget) that widens
//  the estimate into a range instead of pretending to a single number.
//

import Foundation

/// Result of pricing a draft capability state. Equatable so views can use
/// it as an animation/`task(id:)` anchor.
struct AgentAbilityContextPreview: Equatable {

    /// The editor's local toggle values — the fields a user can flip on the
    /// Abilities overview. Everything else (tool mode, manual picks, spawn
    /// pools, subagent flags, system prompt) is inherited from the persisted
    /// agent at compute time.
    struct Draft: Equatable, Hashable {
        var toolsEnabled: Bool
        var memoryEnabled: Bool
        var dbEnabled: Bool
        var renderChartEnabled: Bool
        var speakEnabled: Bool
        var searchMemoryEnabled: Bool
        var webSearchEnabled: Bool
        var selfSchedulingEnabled: Bool
        /// Knowledge retrieval tools plus the grant manifest section.
        var knowledgeEnabled: Bool
        /// Curator role — prices the proposal/ticket tools. Folded with
        /// `knowledgeEnabled` at compute time like the real send path.
        var knowledgeCuratorEnabled: Bool
        /// Autonomous (sandbox) execution — the Code Execution master switch.
        var codeExecutionEnabled: Bool
        /// The editor's local model selection (nil = inherit global default).
        var model: String?
    }

    /// Full per-section breakdown (same shape the chat popover renders).
    let breakdown: ContextBreakdown
    /// Static prefix cost: system prompt sections + tool schema tokens.
    let staticTokens: Int
    /// Upper bound for the per-turn memory injection (0 when memory is
    /// effectively off). Query-dependent at runtime, so this is the
    /// configured `memoryBudgetTokens` cap, not a prediction.
    let memoryUpperTokens: Int
    /// The resolved model's nominal context window, when known.
    let contextWindow: Int?
    /// Size-class auto-disable info (tiny/small windows), when it fired.
    let disable: ContextDisableInfo?

    /// Best-case startup tokens (no memory injected this turn).
    var lowTokens: Int { staticTokens }
    /// Worst-case startup tokens (memory budget fully used).
    var highTokens: Int { staticTokens + memoryUpperTokens }
    /// Whether the estimate is a range rather than a single value.
    var isRange: Bool { memoryUpperTokens > 0 }

    /// Share of the model window the worst-case startup context occupies,
    /// or nil when the window is unknown (cloud models without metadata).
    var windowFraction: Double? {
        guard let contextWindow, contextWindow > 0 else { return nil }
        return min(1.0, Double(highTokens) / Double(contextWindow))
    }

    /// Compact "2.1K"-style token formatting shared by the hero and the
    /// delta ticker.
    static func format(tokens: Int) -> String {
        if tokens >= 1000 {
            let value = Double(tokens) / 1000.0
            return value >= 10
                ? "\(Int(value.rounded()))K"
                : String(format: "%.1fK", value)
        }
        return "\(tokens)"
    }

    /// Price `draft` against the persisted agent. MainActor because the
    /// compose pipeline reads `AgentManager` / `ToolRegistry`. Call this
    /// from state-change reactions (`.task(id:)`), never from a view body —
    /// compose can touch the agent DB.
    @MainActor
    static func compute(agentId: UUID, draft: Draft) -> AgentAbilityContextPreview {
        // Start from the persisted snapshot so non-draft fields (tool mode,
        // manual names, spawn pools, subagent gates, prompt) match the real
        // send path, then overlay the editor's local toggle values.
        let base = AgentConfigSnapshot.capture(agentId: agentId, modelOverride: draft.model)

        // The global memory switch is folded into `capture`'s memoryDisabled;
        // re-fold it against the draft value so a locally-flipped Memory
        // toggle can't claim injection the global switch forbids.
        let globalMemoryOn = MemoryConfigurationStore.load().enabled

        var autonomous = base.autonomousConfig ?? .default
        autonomous.enabled = draft.codeExecutionEnabled

        let snapshot = AgentConfigSnapshot(
            agentId: agentId,
            toolsDisabled: !draft.toolsEnabled,
            globalToolsDisabled: base.globalToolsDisabled,
            memoryDisabled: !(draft.memoryEnabled && globalMemoryOn),
            autonomousConfig: autonomous,
            toolMode: base.toolMode,
            model: base.model,
            manualToolNames: base.manualToolNames,
            systemPrompt: base.systemPrompt,
            dbEnabled: draft.dbEnabled,
            renderChartEnabled: draft.renderChartEnabled,
            speakEnabled: draft.speakEnabled,
            searchMemoryEnabled: draft.searchMemoryEnabled,
            webSearchEnabled: draft.webSearchEnabled,
            selfSchedulingEnabled: draft.selfSchedulingEnabled,
            computerUseEnabled: base.computerUseEnabled,
            spawnDelegationEnabled: base.spawnDelegationEnabled,
            imageEnabled: base.imageEnabled,
            appleScriptEnabled: base.appleScriptEnabled,
            spawnableAgentNames: base.spawnableAgentNames,
            spawnableModelNames: base.spawnableModelNames,
            spawnableModelNotes: base.spawnableModelNotes,
            // Fold the draft flags with the persisted grant list the way
            // `capture` pre-folds them: no grants means no knowledge tools
            // or manifest regardless of the toggle.
            knowledgeEnabled: draft.knowledgeEnabled && !base.knowledgeCollections.isEmpty,
            knowledgeCuratorEnabled: draft.knowledgeEnabled
                && draft.knowledgeCuratorEnabled
                && !base.knowledgeCollections.isEmpty,
            knowledgeCollections: draft.knowledgeEnabled ? base.knowledgeCollections : []
        )

        // Mirror ChatView's optimistic execution-mode estimate: autonomous-on
        // reports sandbox mode even before the container registers tools, so
        // the estimate matches what the next send will most likely produce.
        let resolvedMode = ToolRegistry.shared.resolveExecutionMode(
            folderContext: nil,
            autonomousEnabled: autonomous.enabled
        )
        let executionMode: ExecutionMode =
            (autonomous.enabled && !resolvedMode.usesSandboxTools)
            ? .sandbox(hostRead: nil)
            : resolvedMode

        let context = SystemPromptComposer.composePreviewContext(
            snapshot: snapshot,
            executionMode: executionMode
        )
        let breakdown = ContextBreakdown.from(context: context)

        // Memory upper bound: only when the draft has it on, the global
        // switch allows it, AND the size-class auto-disable didn't kill it.
        let memoryAutoDisabled = context.contextDisable?.disabledMemory ?? false
        let memoryEffectivelyOn = draft.memoryEnabled && globalMemoryOn && !memoryAutoDisabled
        let memoryUpper =
            memoryEffectivelyOn
            ? MemoryConfigurationStore.load().validated().memoryBudgetTokens
            : 0

        let window = ContextSizeResolver.resolve(modelId: snapshot.model).contextLength

        return AgentAbilityContextPreview(
            breakdown: breakdown,
            staticTokens: breakdown.total,
            memoryUpperTokens: memoryUpper,
            contextWindow: window,
            disable: context.contextDisable
        )
    }
}
