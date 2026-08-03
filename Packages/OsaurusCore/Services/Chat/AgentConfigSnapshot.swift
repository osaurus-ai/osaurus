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

/// Effective spawn settings frozen with the rest of one chat turn.
///
/// The Default agent reads these values from `SubagentConfiguration`; custom
/// agents read their own `AgentSettings`. Capturing the resolved values here
/// keeps prompt guidance and JSON schemas on one immutable view even when the
/// settings editor saves while context composition is suspended.
public struct AgentSpawnConfigSnapshot: Sendable, Equatable {
    let agentIDs: [UUID]
    let modelNames: [String]
    let modelNotes: [String: String]
    let budgets: SubagentBudgets
    let toolAccess: SpawnToolAccess
    let launcherModelOverride: String?
}

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

    /// Canonical local-bundle `config.json.model_type` captured alongside the
    /// selected model. This keeps family guidance architecture-derived and
    /// session-deterministic instead of re-reading a changing scan cache.
    public let modelType: String?

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

    /// Per-agent gate for the native `web_search` tool and its dynamic
    /// sibling `search_and_extract`. Default ON (free providers work with
    /// zero config); when false both tools are stripped from the schema.
    public let webSearchEnabled: Bool

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
    /// Per-agent opt-in for Browser Use. Enforced authoritatively in
    /// `resolveTools` like `computer_use` — `browser_use` is stripped in BOTH
    /// auto and manual mode unless the custom agent has opted in. The built-in
    /// Default agent is hard-off for Browser Use.
    public let browserUseEnabled: Bool
    /// Per-agent opt-in for `spawn`. Enforced authoritatively in `resolveTools`
    /// — stripped unless the agent has opted in AND has at least one spawnable
    /// agent or model. There is no global master gate; the Default agent is
    /// governed by its own global pool instead.
    public let spawnDelegationEnabled: Bool
    /// Per-agent opt-in for `image`. Enforced in `resolveTools` — stripped
    /// unless the agent opted in (custom agents) / the global image switch is on
    /// (Default agent).
    public let imageEnabled: Bool
    /// Per-agent opt-in for billable remote `video`.
    public let videoEnabled: Bool
    /// Per-agent opt-in for `applescript`. Enforced in `resolveTools` — stripped
    /// unless the agent opted in (custom agents) / the global AppleScript switch
    /// is on (Default agent), AND a curated AppleScript model is installed.
    public let appleScriptEnabled: Bool
    /// Stable IDs of agents this agent may launch via `spawn_agent`. Drives the "is there
    /// anything to spawn?" half of the `spawn_agent` visibility gate for custom
    /// agents.
    public let spawnableAgentIDs: [UUID]
    /// Transitional legacy payload. It must be resolved uniquely against the
    /// live descriptor catalog before use and is never itself an auth key.
    let legacySpawnableAgentNames: [String]
    /// Raw model ids this agent may hand a task to via `spawn_model`. Drives the
    /// "is there anything to spawn?" half of the `spawn_model` visibility gate
    /// for custom agents.
    public let spawnableModelNames: [String]
    /// Optional "when/how to use" note per spawnable model id, surfaced in the
    /// spawn guidance descriptor (gate stays on `spawnableModelNames`).
    public let spawnableModelNotes: [String: String]
    /// Effective Default-vs-custom spawn settings captured with this turn. Nil
    /// exists only for source-compatible hand-built test snapshots;
    /// production `capture(...)` always supplies it.
    let spawnConfiguration: AgentSpawnConfigSnapshot?
    /// Per-agent opt-in for the knowledge tools, pre-folded with "has at
    /// least one granted collection" — false strips `search_knowledge` /
    /// `read_knowledge` / `list_knowledge` from the model-visible schema.
    /// Execution-time scoping happens in the tools themselves.
    public let knowledgeEnabled: Bool
    /// Curator role, pre-folded like `knowledgeEnabled` — false strips
    /// `propose_knowledge_update` from the model-visible schema. The tool
    /// re-checks the role at execution time.
    public let knowledgeCuratorEnabled: Bool
    /// Granted collections resolved to enabled ones at capture time
    /// (name + summary only). Feeds the `## Knowledge` prompt section —
    /// `knowledgeEnabled` alone only gates the tools into the schema; this
    /// is what tells the model WHAT the granted corpora contain.
    public let knowledgeCollections: [KnowledgeGrantDescriptor]

    /// True when this agent owns at least one usable proactive channel
    /// destination binding (enabled, outbound mode != off). Gates the
    /// narrow `agent_channel_publish` tool into the schema; the broad
    /// `agent_channel_*` catalog stays deferred behind `capabilities_load`.
    public let hasChannelPublishDestinations: Bool

    public init(
        agentId: UUID,
        toolsDisabled: Bool,
        globalToolsDisabled: Bool = false,
        memoryDisabled: Bool,
        autonomousConfig: AutonomousExecConfig?,
        toolMode: ToolSelectionMode,
        model: String?,
        modelType: String? = nil,
        manualToolNames: [String]?,
        systemPrompt: String,
        dbEnabled: Bool,
        renderChartEnabled: Bool = false,
        speakEnabled: Bool = false,
        searchMemoryEnabled: Bool = false,
        webSearchEnabled: Bool = true,
        selfSchedulingEnabled: Bool = false,
        computerUseEnabled: Bool = false,
        browserUseEnabled: Bool = false,
        spawnDelegationEnabled: Bool = false,
        imageEnabled: Bool = false,
        videoEnabled: Bool = false,
        appleScriptEnabled: Bool = false,
        spawnableAgentIDs: [UUID] = [],
        spawnableAgentNames: [String] = [],
        spawnableModelNames: [String] = [],
        spawnableModelNotes: [String: String] = [:],
        spawnConfiguration: AgentSpawnConfigSnapshot? = nil,
        knowledgeEnabled: Bool = false,
        knowledgeCuratorEnabled: Bool = false,
        knowledgeCollections: [KnowledgeGrantDescriptor] = [],
        hasChannelPublishDestinations: Bool = false
    ) {
        self.agentId = agentId
        self.toolsDisabled = toolsDisabled
        self.globalToolsDisabled = globalToolsDisabled
        self.memoryDisabled = memoryDisabled
        self.autonomousConfig = autonomousConfig
        self.toolMode = toolMode
        self.model = model
        self.modelType = modelType
        self.manualToolNames = manualToolNames
        self.systemPrompt = systemPrompt
        self.dbEnabled = dbEnabled
        self.renderChartEnabled = renderChartEnabled
        self.speakEnabled = speakEnabled
        self.searchMemoryEnabled = searchMemoryEnabled
        self.webSearchEnabled = webSearchEnabled
        self.selfSchedulingEnabled = selfSchedulingEnabled
        self.computerUseEnabled = computerUseEnabled
        self.browserUseEnabled = browserUseEnabled
        self.spawnDelegationEnabled = spawnDelegationEnabled
        self.imageEnabled = imageEnabled
        self.videoEnabled = videoEnabled
        self.appleScriptEnabled = appleScriptEnabled
        self.spawnableAgentIDs = SpawnableAgentIdentity.normalizedIDs(spawnableAgentIDs)
        self.legacySpawnableAgentNames = spawnableAgentNames
        self.spawnableModelNames = spawnableModelNames
        self.spawnableModelNotes = spawnableModelNotes
        self.spawnConfiguration = spawnConfiguration
        self.knowledgeEnabled = knowledgeEnabled
        self.knowledgeCuratorEnabled = knowledgeCuratorEnabled
        self.knowledgeCollections = knowledgeCollections
        self.hasChannelPublishDestinations = hasChannelPublishDestinations
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
        modelOverride: String? = nil,
        modelTypeOverride: String? = nil
    ) -> AgentConfigSnapshot {
        let mgr = AgentManager.shared
        // One resolve services every capability gate (positive polarity),
        // closing the mid-fan-out race the old per-field calls risked.
        let caps = mgr.effectiveCapabilities(for: agentId)
        let subagentConfig = SubagentConfigurationStore.snapshot()
        let isDefault = agentId == Agent.defaultId
        let settings = mgr.agent(for: agentId)?.settings
        let sharedParallelLimit =
            SpawnBatchConcurrencyContract.configuredLimit(
                for: ServerRuntimeSettingsStore.snapshot()
            )
        let spawnConfiguration = AgentSpawnConfigSnapshot(
            agentIDs: SubagentToolVisibility.effectiveSpawnableAgents(
                isDefault: isDefault,
                config: subagentConfig,
                perAgentEnabled: caps.spawnDelegationEnabled,
                perAgentTargets: caps.spawnableAgentIDs
            ).filter { $0 != agentId },
            modelNames: SubagentToolVisibility.effectiveSpawnableModels(
                isDefault: isDefault,
                config: subagentConfig,
                perAgentEnabled: caps.spawnDelegationEnabled,
                perAgentModelTargets: caps.spawnableModelNames
            ),
            modelNotes:
                isDefault
                ? subagentConfig.spawnableModelNotes
                : caps.spawnableModelNotes,
            budgets: SubagentToolVisibility.effectiveBudgets(
                isDefault: isDefault,
                config: subagentConfig,
                settings: settings,
                sharedParallelLimit: sharedParallelLimit
            ),
            toolAccess: SubagentToolVisibility.effectiveSpawnToolAccess(
                isDefault: isDefault,
                config: subagentConfig,
                settings: settings
            ),
            launcherModelOverride: SubagentToolVisibility.effectiveSubagentModel(
                capabilityId: SubagentCapabilityRegistry.spawn.id,
                isDefault: isDefault,
                config: subagentConfig,
                settings: settings
            )
        )
        return AgentConfigSnapshot(
            agentId: agentId,
            toolsDisabled: requestToolsDisabled || !caps.toolsEnabled,
            globalToolsDisabled: requestToolsDisabled,
            memoryDisabled: !caps.memoryEnabled,
            autonomousConfig: mgr.effectiveAutonomousExec(for: agentId),
            toolMode: mgr.effectiveToolSelectionMode(for: agentId),
            model: modelOverride ?? mgr.effectiveModel(for: agentId),
            modelType: modelTypeOverride,
            manualToolNames: mgr.effectiveManualToolNames(for: agentId),
            systemPrompt: mgr.effectiveSystemPrompt(for: agentId),
            dbEnabled: caps.dbEnabled,
            renderChartEnabled: caps.renderChartEnabled,
            speakEnabled: caps.speakEnabled,
            searchMemoryEnabled: caps.searchMemoryEnabled,
            webSearchEnabled: caps.webSearchEnabled,
            selfSchedulingEnabled: caps.selfSchedulingEnabled,
            computerUseEnabled: caps.computerUseEnabled,
            browserUseEnabled: caps.browserUseEnabled,
            spawnDelegationEnabled: caps.spawnDelegationEnabled,
            imageEnabled: caps.imageEnabled,
            videoEnabled: caps.videoEnabled,
            appleScriptEnabled: caps.appleScriptEnabled,
            spawnableAgentIDs: caps.spawnableAgentIDs,
            spawnableAgentNames: caps.legacySpawnableAgentNames,
            spawnableModelNames: caps.spawnableModelNames,
            spawnableModelNotes: caps.spawnableModelNotes,
            spawnConfiguration: spawnConfiguration,
            // Pre-fold the "anything to search?" half of the gate, like the
            // spawn tools: enabled with zero grants keeps the tools hidden.
            knowledgeEnabled: caps.knowledgeEnabled && !caps.knowledgeCollectionIds.isEmpty,
            knowledgeCuratorEnabled: caps.knowledgeCuratorEnabled
                && !caps.knowledgeCollectionIds.isEmpty,
            // Same grant resolution the tools use at execution time
            // (`effectiveKnowledgeCollections`), captured here so the
            // prompt section can't race a mid-compose grant edit.
            knowledgeCollections: mgr.effectiveKnowledgeCollections(for: agentId)
                .map(\.grantDescriptor),
            // Usable = enabled with outbound mode != off, including
            // automatic destinations derived from the channel setup the
            // user already completed. Captured per compose so a binding
            // (or a newly writable room) surfaces the publish tool on the
            // next turn.
            hasChannelPublishDestinations: !AgentChannelAutoDestinationResolver
                .effectiveConfiguration()
                .usableBindings(agentId: agentId)
                .isEmpty
        )
    }
}
