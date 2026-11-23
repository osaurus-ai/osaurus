//
//  HarnessToolSurface.swift
//  osaurus
//
//  The Osaurus tools an agent's harness process gets over the MCP bridge:
//  the same per-agent gates the built-in loop applies, less what only
//  Osaurus's own loop can run or show.
//

import Foundation

@MainActor
enum HarnessToolSurface {
    /// Tools a harness turn can call but never show: their result becomes a
    /// chat card only when Osaurus's own loop post-processes it.
    nonisolated static let chatRenderedToolNames: Set<String> = [
        "share_artifact", "image", "video", "render_chart",
    ]

    /// Run a sub-loop on the agent's built-in model, which a harness agent
    /// does not have.
    nonisolated static let handoffToolNames: Set<String> = [
        ConfiguratorHandoffTool.toolName, ArchitectHandoffTool.toolName,
    ]

    /// Every name a harness token for `agentId` may call. Empty when the
    /// agent's tools are off.
    static func names(agentId: UUID, allowsConfigWrites: Bool) -> Set<String> {
        let manager = AgentManager.shared
        guard manager.effectiveCapabilities(for: agentId).toolsEnabled else { return [] }
        let resolved = SystemPromptComposer.resolveTools(agentId: agentId, executionMode: .none)
            .map(\.function.name)
        var names = Set(resolved)
        names.formUnion(ToolRegistry.shared.toolGrantSnapshot(agentId: agentId).enabledDynamicNames)
        names.formUnion(ClaudeCodeConfiguration.osaurusReadOnlyTools)
        if allowsConfigWrites { names.insert(HarnessGrantStore.configWriteToolName) }
        return filtered(names)
    }

    /// What no harness token may list, whatever the agent's settings say.
    nonisolated static func filtered(_ names: Set<String>) -> Set<String> {
        names
            .subtracting(HarnessGrantStore.deniedToolNames)
            .subtracting(HarnessGrantStore.builtInLoopToolNames)
            .subtracting(HarnessGrantStore.architectOnlyToolNames)
            .subtracting(ToolRegistry.externallyDeniedToolNames)
            .subtracting(ToolRegistry.capabilityToolNames)
            .subtracting(handoffToolNames)
            .subtracting(chatRenderedToolNames)
    }
}
