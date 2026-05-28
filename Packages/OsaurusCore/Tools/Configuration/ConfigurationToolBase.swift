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
        if agentId != Agent.defaultId {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message:
                    "Configuration tools are only available to the Default agent. "
                    + "Switch to the Default agent in the sidebar to configure Osaurus.",
                tool: tool,
                retryable: false
            )
        }
        return nil
    }
}
