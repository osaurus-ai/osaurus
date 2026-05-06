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

    /// OR of the request-scoped `toolsDisabled` flag and the agent's
    /// `effectiveToolsDisabled`. Already factors in the global
    /// `ChatConfiguration.disableTools` switch.
    public let toolsDisabled: Bool

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

    public init(
        toolsDisabled: Bool,
        memoryDisabled: Bool,
        autonomousConfig: AutonomousExecConfig?,
        toolMode: ToolSelectionMode,
        model: String?,
        manualToolNames: [String]?,
        systemPrompt: String
    ) {
        self.toolsDisabled = toolsDisabled
        self.memoryDisabled = memoryDisabled
        self.autonomousConfig = autonomousConfig
        self.toolMode = toolMode
        self.model = model
        self.manualToolNames = manualToolNames
        self.systemPrompt = systemPrompt
    }

    /// Read every `effective*` field in one MainActor batch.
    ///
    /// `requestToolsDisabled` is the per-request override the caller
    /// passes through (`ChatConfiguration.disableTools` already lives on
    /// the agent flag, so callers should only pass `true` when the
    /// caller itself wants to force tools off for a single compose).
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
        return AgentConfigSnapshot(
            toolsDisabled: requestToolsDisabled || mgr.effectiveToolsDisabled(for: agentId),
            memoryDisabled: mgr.effectiveMemoryDisabled(for: agentId),
            autonomousConfig: mgr.effectiveAutonomousExec(for: agentId),
            toolMode: mgr.effectiveToolSelectionMode(for: agentId),
            model: modelOverride ?? mgr.effectiveModel(for: agentId),
            manualToolNames: mgr.effectiveManualToolNames(for: agentId),
            systemPrompt: mgr.effectiveSystemPrompt(for: agentId)
        )
    }
}
