//
//  DefaultAgentConfiguration.swift
//  osaurus
//
//  Settings that apply specifically to the built-in Default agent
//  (`Agent.defaultId`). Historically these lived on `ChatConfiguration`
//  alongside truly global chat fields (hotkey, core-model selection,
//  etc.), which:
//    1. blurred the trust boundary for Phase A's external-surface
//       lockdown (every reach into `ChatConfiguration` had to know
//       which fields meant "global" vs "default-agent only"); and
//    2. made the Settings UI dishonest — default-agent tweaks
//       were stored in `chat.json` next to "Global Chat" knobs.
//
//  The Default agent is in-memory only and never serialized to disk
//  as an `Agent.json`, so its settings live here in their own file.
//

import Foundation

/// Settings for the built-in Default agent. The Default agent is
/// user-editable via Settings → Chat and is
/// never mutated through chat tools — `osaurus_*` write tools refuse
/// to target it. See `AgentManager.effective*` for the routing of
/// these values into the runtime.
public struct DefaultAgentConfiguration: Codable, Equatable, Sendable {
    /// System prompt prepended to every turn with the Default agent.
    /// The configure-agent prompt addendum (rendered by
    /// `DefaultAgentSystemPromptBuilder`) is prepended at compose time
    /// when this field is set — the user's value still wins for tone.
    public var systemPrompt: String

    /// Model id used by the Default agent when the user hasn't
    /// overridden it per-turn. `nil` falls back to the first available
    /// installed local model (same fallback used by custom agents).
    public var defaultModel: String?

    /// Per-turn temperature override for the Default agent. `nil`
    /// defers to the global chat default.
    public var temperature: Float?

    /// Per-turn max-tokens cap for the Default agent. `nil` defers to
    /// the model's `generation_config.json` default and never imposes
    /// a synthetic Osaurus cap.
    public var maxTokens: Int?

    /// When true, no tools or preflight context are sent to the model
    /// for Default-agent turns. Negative-polarity counterpart to a custom
    /// agent's `Agent.toolsEnabled` (the Default agent persists its tools
    /// switch here rather than on the `Agent`). Used by chat consumers
    /// running Osaurus as a plain LLM backend without the agent-loop
    /// machinery.
    public var disableTools: Bool

    /// Autonomous-exec policy for the Default agent's sandbox.
    /// `nil` keeps autonomous off.
    public var autonomousExec: AutonomousExecConfig?

    /// Tool selection mode (auto / manual). `nil` defaults to `.auto`.
    public var toolSelectionMode: ToolSelectionMode?

    /// Tool name allowlist used in manual mode (and as the seeded
    /// enabled set in auto mode after the user has visited the
    /// capability picker). `nil` means "no allowlist persisted yet"
    /// and the runtime falls back to the live registry.
    public var manualToolNames: [String]?

    /// Skill name allowlist for the Default agent. Mirrors
    /// `manualToolNames` for skills.
    public var manualSkillNames: [String]?

    public init(
        systemPrompt: String = "",
        defaultModel: String? = nil,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        disableTools: Bool = false,
        autonomousExec: AutonomousExecConfig? = nil,
        toolSelectionMode: ToolSelectionMode? = nil,
        manualToolNames: [String]? = nil,
        manualSkillNames: [String]? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.defaultModel = defaultModel
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.disableTools = disableTools
        self.autonomousExec = autonomousExec
        self.toolSelectionMode = toolSelectionMode
        self.manualToolNames = manualToolNames
        self.manualSkillNames = manualSkillNames
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        temperature = try c.decodeIfPresent(Float.self, forKey: .temperature)
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
        disableTools = try c.decodeIfPresent(Bool.self, forKey: .disableTools) ?? false
        autonomousExec = try c.decodeIfPresent(AutonomousExecConfig.self, forKey: .autonomousExec)
        toolSelectionMode = try c.decodeIfPresent(ToolSelectionMode.self, forKey: .toolSelectionMode)
        manualToolNames = try c.decodeIfPresent([String].self, forKey: .manualToolNames)
        manualSkillNames = try c.decodeIfPresent([String].self, forKey: .manualSkillNames)
    }

    public static var `default`: DefaultAgentConfiguration {
        DefaultAgentConfiguration()
    }
}
