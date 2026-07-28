//
//  SpawnPermissionGate.swift
//  OsaurusCore
//
//  One permission owner for spawn_agent, spawn_model, and spawn_batch.
//  Spawn policies live in SubagentConfiguration / AgentSettings, so "Always
//  Allow" must persist there rather than in ToolRegistry's generic tool map.
//

import Foundation

enum SpawnPermissionGate {
    enum PromptChoice: Sendable, Equatable {
        case deny
        case allowOnce
        case alwaysAllow
    }

    struct PromptRequest: Sendable, Equatable {
        let toolName: String
        let description: String
        let argumentsJSON: String
        let launchingAgentId: UUID
    }

    /// Deterministic model-free seam. Production never binds this value; tests
    /// can count prompts, choose allow/deny/always, or suspend until cancelled
    /// without presenting an AppKit panel.
    @TaskLocal
    static var promptOverride:
        (@Sendable (PromptRequest) async throws -> PromptChoice)?

    /// Deterministic eval seam. Production never binds this value; scripted
    /// SpawnBatchTool evaluations still execute the real single batch gate,
    /// but cannot inherit a developer machine's persisted Deny setting.
    @TaskLocal
    static var policyOverrideForTests: SubagentPermissionPolicy?

    static func effectivePolicy(
        for scope: SubagentScope
    ) async -> SubagentPermissionPolicy {
        if let policyOverrideForTests {
            return policyOverrideForTests
        }
        let config = SubagentConfigurationStore.snapshot()
        let isDefault = scope.agentId == Agent.defaultId
        let settings = await MainActor.run {
            AgentManager.shared.agent(for: scope.agentId)?.settings
        }
        return SubagentToolVisibility.effectivePermission(
            capabilityId: SubagentCapabilityRegistry.spawn.id,
            isDefault: isDefault,
            config: config,
            settings: settings
        )
    }

    /// Resolve one spawn policy decision before admission/model loading.
    ///
    /// `cancellationRequested` is the visible subagent Stop token for direct
    /// spawn and spawn_batch. The prompt operation is owned and drained, so a
    /// cancelled panel/test seam cannot outlive the rejected tool call.
    static func authorize(
        scope: SubagentScope,
        policy: SubagentPermissionPolicy,
        toolName: String,
        description: String,
        argumentsJSON: String,
        cancellationRequested: @escaping @Sendable () -> Bool = { false }
    ) async -> SubagentDecision {
        switch policy {
        case .deny:
            return .denied(
                "Spawning is denied by this agent's permission settings."
            )
        case .alwaysAllow:
            return .allow
        case .ask:
            break
        }

        // Eval/headless lanes deliberately opt into one-run approval. This
        // never mutates the persisted policy.
        if ChatExecutionContext.autoApproveToolPrompts {
            return .allow
        }
        if ChatExecutionContext.denyUnapprovedToolPrompts {
            return .userDenied("Spawn permission was not approved.")
        }
        if cancellationRequested() || Task.isCancelled {
            return .userDenied("Spawn permission was cancelled.")
        }

        let request = PromptRequest(
            toolName: toolName,
            description: description,
            argumentsJSON: argumentsJSON,
            launchingAgentId: scope.agentId
        )
        let operation = OwnedSubagentOperation<PromptChoice> {
            if let promptOverride {
                return try await promptOverride(request)
            }
            let outcome = await ToolPermissionPromptService.requestPolicyApproval(
                toolName: request.toolName,
                description: request.description,
                argumentsJSON: request.argumentsJSON
            )
            switch outcome {
            case .denied: return .deny
            case .allowOnce: return .allowOnce
            case .alwaysAllow: return .alwaysAllow
            }
        }

        let choice: PromptChoice
        do {
            choice = try await operation.value(
                cancellationRequested: cancellationRequested
            )
        } catch {
            return .userDenied("Spawn permission was cancelled.")
        }
        if cancellationRequested() || Task.isCancelled {
            return .userDenied("Spawn permission was cancelled.")
        }

        switch choice {
        case .deny:
            return .userDenied("User denied spawning subagents.")
        case .allowOnce:
            return .allow
        case .alwaysAllow:
            let persisted = await persistAlwaysAllow(
                launchingAgentId: scope.agentId
            )
            if !persisted {
                // The current click still grants this run. A missing launching
                // agent is not silently represented as persisted.
                print(
                    "[Osaurus] Could not persist spawn Always Allow for agent "
                        + scope.agentId.uuidString
                )
            }
            return .allow
        }
    }

    /// Persist into the policy source actually read by the launching agent:
    /// Default/main chat → SubagentConfigurationStore; custom agent → its
    /// AgentSettings. Never writes ToolRegistry's unrelated generic policy.
    @discardableResult
    static func persistAlwaysAllow(
        launchingAgentId: UUID
    ) async -> Bool {
        if launchingAgentId == Agent.defaultId {
            SubagentConfigurationStore.mutate { config in
                config.permissionDefaults.setPolicy(
                    .alwaysAllow,
                    for: SubagentCapabilityRegistry.spawn.id
                )
            }
            return true
        }

        return await MainActor.run {
            guard var agent = AgentManager.shared.agent(for: launchingAgentId),
                !agent.isBuiltIn
            else {
                return false
            }
            agent.settings.subagentPermissions.setPolicy(
                .alwaysAllow,
                for: SubagentCapabilityRegistry.spawn.id
            )
            AgentManager.shared.update(agent)
            return true
        }
    }
}
