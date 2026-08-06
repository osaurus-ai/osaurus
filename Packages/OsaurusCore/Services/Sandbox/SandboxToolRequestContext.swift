//
//  SandboxToolRequestContext.swift
//  osaurus
//
//  Resolves sandbox control-plane calls against the request's agent instead
//  of the agent that happened to register the process-wide tool object.
//

import Foundation

enum SandboxControlCapability: Sendable {
    case autonomous
    case backgroundProcess
    case pluginCreate
}

struct SandboxToolRequestContext: Sendable {
    let agentUUID: UUID?
    let agentId: String
    let agentName: String
    let home: String
    let config: AutonomousExecConfig?
    let isRequestBound: Bool

    static func resolve(
        fallbackAgentId: String,
        fallbackAgentName: String? = nil,
        fallbackConfig: AutonomousExecConfig? = nil
    ) async -> SandboxToolRequestContext {
        if let requestAgentId = ChatExecutionContext.currentAgentId {
            let (config, name) = await MainActor.run {
                (
                    AgentManager.shared.effectiveAutonomousExec(for: requestAgentId),
                    SandboxAgentProvisioner.linuxName(for: requestAgentId.uuidString)
                )
            }
            return SandboxToolRequestContext(
                agentUUID: requestAgentId,
                agentId: requestAgentId.uuidString,
                agentName: name,
                home: OsaurusPaths.inContainerAgentHome(name),
                config: config,
                isRequestBound: true
            )
        }

        let fallbackUUID = UUID(uuidString: fallbackAgentId)
        let (resolvedConfig, defaultName): (AutonomousExecConfig?, String?)
        if let fallbackUUID {
            (resolvedConfig, defaultName) = await MainActor.run {
                let name = SandboxAgentProvisioner.linuxName(for: fallbackUUID.uuidString)
                guard AgentManager.shared.agent(for: fallbackUUID) != nil else {
                    return (fallbackConfig, name)
                }
                return (
                    AgentManager.shared.effectiveAutonomousExec(for: fallbackUUID),
                    name
                )
            }
        } else {
            (resolvedConfig, defaultName) = (fallbackConfig, nil)
        }
        let name =
            fallbackAgentName
            ?? defaultName
            ?? fallbackAgentId
        return SandboxToolRequestContext(
            agentUUID: fallbackUUID,
            agentId: fallbackAgentId,
            agentName: name,
            home: OsaurusPaths.inContainerAgentHome(name),
            config: resolvedConfig,
            isRequestBound: false
        )
    }

    func rejection(
        for capability: SandboxControlCapability,
        tool: String
    ) -> String? {
        // Legacy direct/test calls can lack a persisted agent config. Tool
        // execution inside Chat/Work is always request-bound and therefore
        // must have an enabled config or fail closed.
        guard let config else {
            guard isRequestBound else { return nil }
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "Sandbox execution is not configured for the current agent.",
                tool: tool,
                retryable: false
            )
        }

        guard config.enabled else {
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "Sandbox execution is disabled for the current agent.",
                tool: tool,
                retryable: false
            )
        }

        switch capability {
        case .autonomous:
            return nil
        case .backgroundProcess where !config.backgroundProcessEnabled:
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "Background processes are disabled for the current agent.",
                tool: tool,
                retryable: false
            )
        case .pluginCreate where !config.pluginCreate:
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "Plugin creation is disabled for the current agent.",
                tool: tool,
                retryable: false
            )
        default:
            return nil
        }
    }
}
