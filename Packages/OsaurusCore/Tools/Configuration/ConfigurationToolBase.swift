//
//  ConfigurationToolBase.swift
//  osaurus
//
//  Shared primitives for every `osaurus_*` configure tool:
//  the `configure_osaurus` capability identifier, the default
//  `.ask` policy, and the runtime default-agent gate.
//

import Foundation

public enum ConfigurationToolBase {
    /// Capability passed in `PermissionedTool.requirements`. Granted
    /// once from the Tool Permissions UI; unlocks every configure
    /// write.
    public static let requirement = "configure_osaurus"

    /// Default policy for every configure write tool. Internal because
    /// `ToolPermissionPolicy` is module-internal.
    static let defaultPolicy: ToolPermissionPolicy = .ask

    /// Read-only tools an external harness may call for its own agent with
    /// a live agent token. They never emit secrets; `osaurus_config` stays
    /// Default-agent only.
    static let harnessReadableTools: Set<String> = ["osaurus_inspect", "osaurus_help"]

    /// Returns a ready-to-serve `ToolEnvelope.failure` when the call
    /// site is anything other than a default-agent chat turn; `nil`
    /// when the call is allowed. Complementary to the composer's
    /// allowlist — this is the last-line runtime defense.
    public static func defaultAgentGateFailure(tool: String) -> String? {
        guard let agentId = ChatExecutionContext.currentAgentId else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message:
                    "Configuration tools require a chat session context. "
                    + "They are only available from the Default agent inside Osaurus.",
                tool: tool,
                retryable: false
            )
        }
        // The Configurator owns these tools. The Default agent reaches them
        // only through its own external harness (Claude Code over the MCP
        // bridge, live Default-agent token); its chat turns hand off with
        // `configurator_handoff` instead.
        let harnessAgentId = ChatExecutionContext.harnessTokenAgentId
        switch agentId {
        case Agent.configuratorId:
            return nil
        case Agent.defaultId:
            if harnessAgentId == Agent.defaultId { return nil }
            return ToolEnvelope.failure(
                kind: .unavailable,
                message:
                    "Osaurus settings belong to the Configurator. "
                    + "Call configurator_handoff with the user's request instead.",
                tool: tool,
                retryable: false
            )
        default:
            if harnessReadableTools.contains(tool), harnessAgentId == agentId { return nil }
            return ToolEnvelope.failure(
                kind: .unavailable,
                message:
                    "Configuration tools are only available to the Default agent. "
                    + "Switch to the Default agent in the sidebar to configure Osaurus.",
                tool: tool,
                retryable: false
            )
        }
    }

    /// The read-only gate for `osaurus_inspect`: the Default agent and The
    /// Architect, which reads models, MCP servers, and plugins while it
    /// designs a workflow.
    public static func readGateFailure(tool: String) -> String? {
        if ChatExecutionContext.currentAgentId == Agent.architectId { return nil }
        return defaultAgentGateFailure(tool: tool)
    }
}
