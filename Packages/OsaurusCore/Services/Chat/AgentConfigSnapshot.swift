//
//  AgentConfigSnapshot.swift
//  osaurus
//
//  One-shot capture of every `AgentManager.shared.effective*` field that
//  the prompt composer reads while assembling a chat context. Captured on
//  the MainActor at the start of compose and threaded down through helpers
//  so the rest of the pipeline never re-queries `AgentManager.shared`.
//
//  Why a snapshot: each `effective*` accessor is a MainActor hop that
//  reads `AgentManager` plus (in some cases) `ChatConfigurationStore` /
//  `MemoryConfigurationStore`. The composer used to make 6–7 of them per
//  compose, and a sibling MainActor task (test setup, plugin install,
//  skill toggle) could mutate state mid-fan-out. The race window comment
//  on `PluginCreatorGate.Inputs` exists because of this. Capturing once
//  closes the window structurally — every gate sees the same view of
//  the world.
//

import Foundation

public struct AgentConfigSnapshot: Sendable, Equatable {

    /// Agent id this snapshot was captured for. Used by gates that
    /// depend on default-vs-custom routing (e.g. the Phase-C
    /// default-agent allowlist filter / configure-tool strip).
    public let agentId: UUID

    /// OR of the request-scoped `toolsDisabled` flag and the agent's
    /// `effectiveToolsDisabled`. NOTE: the global
    /// `ChatConfiguration.disableTools` switch is NOT read by
    /// `effectiveToolsDisabled`; callers fold it in by passing it as
    /// `requestToolsDisabled` to `capture(...)` (e.g. `ChatView`).
    public let toolsDisabled: Bool

    /// The session-global `ChatConfiguration.disableTools` switch in
    /// isolation (the `requestToolsDisabled` the caller folded in), kept
    /// separable from the per-agent Tools toggle. This is an absolute
    /// kill-switch: unlike the per-agent toggle, sandbox mode does NOT
    /// override it (see `SystemPromptComposer.resolveEffectiveToolsOff`).
    public let globalToolsDisabled: Bool

    /// Mirrors `AgentManager.effectiveMemoryDisabled` (folds in the
    /// global `MemoryConfiguration.enabled` switch).
    public let memoryDisabled: Bool

    /// Resolved autonomous-execution config, or nil when not configured.
    public let autonomousConfig: AutonomousExecConfig?

    /// True when autonomous execution is enabled.
    public var autonomousEnabled: Bool { autonomousConfig?.enabled == true }

    /// True when autonomous execution is enabled AND plugin creation is
    /// permitted on that config — same boolean the plugin-creator gate
    /// consumes.
    public var canCreatePlugins: Bool {
        autonomousConfig.map { $0.enabled && $0.pluginCreate } ?? false
    }

    /// Resolved tool-selection mode (auto vs manual).
    public let toolMode: ToolSelectionMode

    /// Resolved model id used for the request, or nil when no model has
    /// been picked yet.
    public let model: String?

    /// User-selected manual tool names, or nil when not in manual mode.
    public let manualToolNames: [String]?

    /// User-customised persona string, or "" when blank. Use
    /// `SystemPromptTemplates.effectivePersona(systemPrompt)` to fold in
    /// the default fallback.
    public let systemPrompt: String

    /// Whether the Agent DB feature (spec §5.5) is enabled for this agent.
    /// Drives both tool gating (the `db_*` tools are filtered out when
    /// false) and prompt injection (the onboarding block + schema
    /// snapshot are omitted).
    public let dbEnabled: Bool

    /// Per-agent opt-in for the `render_chart` tool. When false the tool
    /// is stripped from the model-visible schema (it stays registered in
    /// `ToolRegistry` for direct execution / ChatView interception).
    public let renderChartEnabled: Bool

    /// Per-agent opt-in for the `speak` (voice output) tool.
    public let speakEnabled: Bool

    /// Per-agent opt-in for the `search_memory` recall tool. Independent
    /// of `memoryDisabled` (which gates injection + recording); this only
    /// controls whether the model can recall memory mid-session.
    public let searchMemoryEnabled: Bool

    /// Per-agent opt-in for the self-scheduling tools (`schedule_next_run` /
    /// `cancel_next_run` / `notify`). Decoupled from the schedule-mode picker
    /// (which only sets host-enforced bounds); when false those tools are
    /// stripped from the model-visible schema.
    public let selfSchedulingEnabled: Bool

    /// Per-agent opt-in for the Computer Use feature. Unlike the lean-by-
    /// default built-in gates above, this is enforced authoritatively in
    /// `resolveTools` — `computer_use` is stripped in BOTH auto and manual
    /// mode unless the agent has opted in.
    public let computerUseEnabled: Bool
    /// Per-agent opt-in for `spawn`. Enforced authoritatively in `resolveTools`
    /// — stripped unless the agent has opted in AND has at least one spawnable
    /// agent (`spawnableAgentNames`), ANDed with the global master gate. The
    /// Default agent is governed by the global pool instead.
    public let spawnDelegationEnabled: Bool
    /// Per-agent opt-in for `image`. Enforced in `resolveTools` — stripped
    /// unless the agent opted in (custom agents) / the global image switch is on
    /// (Default agent).
    public let imageEnabled: Bool
    /// Per-agent opt-in for `applescript`. Enforced in `resolveTools` — stripped
    /// unless the agent opted in (custom agents) / the global AppleScript switch
    /// is on (Default agent), AND a curated AppleScript model is installed.
    public let appleScriptEnabled: Bool
    /// Agents this agent may launch via `spawn_agent`. Drives the "is there
    /// anything to spawn?" half of the `spawn_agent` visibility gate for custom
    /// agents.
    public let spawnableAgentNames: [String]
    /// Raw model ids this agent may hand a task to via `spawn_model`. Drives the
    /// "is there anything to spawn?" half of the `spawn_model` visibility gate
    /// for custom agents.
    public let spawnableModelNames: [String]
    /// Optional "when/how to use" note per spawnable model id, surfaced in the
    /// spawn guidance descriptor (gate stays on `spawnableModelNames`).
    public let spawnableModelNotes: [String: String]

    public init(
        agentId: UUID,
        toolsDisabled: Bool,
        globalToolsDisabled: Bool = false,
        memoryDisabled: Bool,
        autonomousConfig: AutonomousExecConfig?,
        toolMode: ToolSelectionMode,
        model: String?,
        manualToolNames: [String]?,
        systemPrompt: String,
        dbEnabled: Bool,
        renderChartEnabled: Bool = false,
        speakEnabled: Bool = false,
        searchMemoryEnabled: Bool = false,
        selfSchedulingEnabled: Bool = false,
        computerUseEnabled: Bool = false,
        spawnDelegationEnabled: Bool = false,
        imageEnabled: Bool = false,
        appleScriptEnabled: Bool = false,
        spawnableAgentNames: [String] = [],
        spawnableModelNames: [String] = [],
        spawnableModelNotes: [String: String] = [:]
    ) {
        self.agentId = agentId
        self.toolsDisabled = toolsDisabled
        self.globalToolsDisabled = globalToolsDisabled
        self.memoryDisabled = memoryDisabled
        self.autonomousConfig = autonomousConfig
        self.toolMode = toolMode
        self.model = model
        self.manualToolNames = manualToolNames
        self.systemPrompt = systemPrompt
        self.dbEnabled = dbEnabled
        self.renderChartEnabled = renderChartEnabled
        self.speakEnabled = speakEnabled
        self.searchMemoryEnabled = searchMemoryEnabled
        self.selfSchedulingEnabled = selfSchedulingEnabled
        self.computerUseEnabled = computerUseEnabled
        self.spawnDelegationEnabled = spawnDelegationEnabled
        self.imageEnabled = imageEnabled
        self.appleScriptEnabled = appleScriptEnabled
        self.spawnableAgentNames = spawnableAgentNames
        self.spawnableModelNames = spawnableModelNames
        self.spawnableModelNotes = spawnableModelNotes
    }

    /// Read every `effective*` field in one MainActor batch.
    ///
    /// `requestToolsDisabled` is the per-request override the caller
    /// passes through. This is where the global
    /// `ChatConfiguration.disableTools` switch is folded in — it is NOT
    /// read by `effectiveToolsDisabled`, so any caller that wants the
    /// global switch honored (app chat AND the HTTP path) must pass it.
    /// `modelOverride` lets the caller pin a specific model id (e.g. an
    /// HTTP request that named a model the agent doesn't default to);
    /// when nil, the agent's effective model is used.
    @MainActor
    public static func capture(
        agentId: UUID,
        requestToolsDisabled: Bool = false,
        modelOverride: String? = nil
    ) -> AgentConfigSnapshot {
        let mgr = AgentManager.shared
        // One resolve services every capability gate (positive polarity),
        // closing the mid-fan-out race the old per-field calls risked.
        let caps = mgr.effectiveCapabilities(for: agentId)
        return AgentConfigSnapshot(
            agentId: agentId,
            toolsDisabled: requestToolsDisabled || !caps.toolsEnabled,
            globalToolsDisabled: requestToolsDisabled,
            memoryDisabled: !caps.memoryEnabled,
            autonomousConfig: mgr.effectiveAutonomousExec(for: agentId),
            toolMode: mgr.effectiveToolSelectionMode(for: agentId),
            model: modelOverride ?? mgr.effectiveModel(for: agentId),
            manualToolNames: mgr.effectiveManualToolNames(for: agentId),
            systemPrompt: mgr.effectiveSystemPrompt(for: agentId),
            dbEnabled: caps.dbEnabled,
            renderChartEnabled: caps.renderChartEnabled,
            speakEnabled: caps.speakEnabled,
            searchMemoryEnabled: caps.searchMemoryEnabled,
            selfSchedulingEnabled: caps.selfSchedulingEnabled,
            computerUseEnabled: caps.computerUseEnabled,
            spawnDelegationEnabled: caps.spawnDelegationEnabled,
            imageEnabled: caps.imageEnabled,
            appleScriptEnabled: caps.appleScriptEnabled,
            spawnableAgentNames: caps.spawnableAgentNames,
            spawnableModelNames: caps.spawnableModelNames,
            spawnableModelNotes: caps.spawnableModelNotes
        )
    }
}
