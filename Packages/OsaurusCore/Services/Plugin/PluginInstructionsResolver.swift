//
//  PluginInstructionsResolver.swift
//  osaurus
//
//  Single source of truth for "what plugin instructions should land in
//  the system prompt for this (plugin, agent) pair". Resolves the
//  agent-level per-plugin override first (set via the Agent detail's
//  "Instructions" card) and falls back to the plugin manifest's
//  `instructions` default.
//
//  Used by both plugin-driven inference paths so the same plugin sees
//  the same system prompt prefix regardless of whether it called
//  `host->complete` / `host->complete_stream` (synchronous, handled in
//  `PluginHostAPI.prepareInference`) or `host->dispatch` (background,
//  handled in `ChatView.send`).
//

import Foundation

@MainActor
enum PluginInstructionsResolver {
    /// Returns the plugin instructions that should be appended to the
    /// system prompt. Per-agent override wins when non-empty, otherwise
    /// the plugin manifest's `instructions` default is returned. `nil`
    /// when neither is present (or when the plugin isn't loaded).
    static func instructions(pluginId: String, agentId: UUID?) -> String? {
        if let agentId,
            let agent = AgentManager.shared.agent(for: agentId),
            let override = agent.pluginInstructions?[pluginId],
            !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return override
        }
        return PluginManager.shared.loadedPlugin(for: pluginId)?.plugin.manifest.instructions
    }
}
