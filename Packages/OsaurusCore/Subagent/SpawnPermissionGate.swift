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
    ///
    /// `waveMember` marks a single `spawn_agent` / `spawn_model` call that may
    /// belong to a sibling wave (several spawn calls in one model message).
    /// Members rendezvous in `SpawnWaveGate` for one shared card and one
    /// fan-out limit check; the batch tool and the wave's own card pass nil.
    static func authorize(
        scope: SubagentScope,
        policy: SubagentPermissionPolicy,
        toolName: String,
        description: String,
        argumentsJSON: String,
        cancellationRequested: @escaping @Sendable () -> Bool = { false },
        waveMember: SpawnWaveGate.Member? = nil
    ) async -> SubagentDecision {
        if case .deny = policy {
            return .denied(
                "Spawning is denied by this agent's permission settings."
            )
        }

        // Sibling wave: one approval and one limit check for the whole set.
        // Always Allow still joins, so the fan-out limit applies to the wave
        // rather than letting N unprompted calls each pass on their own.
        if let waveMember,
            let wave = ChatExecutionContext.spawnWave,
            wave.expectedCallIds.contains(waveMember.callId)
        {
            let limits = await MainActor.run {
                SpawnBatchTool.effectiveFanOutLimits(scope: scope)
            }
            let rendezvous = OwnedSubagentOperation<SubagentDecision?> {
                await SpawnWaveGate.shared.join(waveMember, wave: wave, limits: limits)
            }
            do {
                if let decision = try await rendezvous.value(
                    cancellationRequested: cancellationRequested
                ) {
                    return decision
                }
            } catch {
                return .userDenied("Spawn permission was cancelled.")
            }
            if cancellationRequested() || Task.isCancelled {
                return .userDenied("Spawn permission was cancelled.")
            }
            // Not a member after all (late arrival): fall through to the
            // per-call path with the policy as it stands now.
        }

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
        // The prompt may wait in the shared approval queue behind a sibling
        // spawn prompt. If that sibling's "Always Allow" (or a settings edit)
        // changed the effective policy meanwhile, settle silently instead of
        // asking the user the same question twice.
        let revalidate: @Sendable () async -> ToolPermissionPromptService.PolicyApprovalOutcome? = {
            Self.silentResolution(for: await effectivePolicy(for: scope))
        }
        let operation = OwnedSubagentOperation<PromptChoice> {
            if let promptOverride {
                if let early = await revalidate() {
                    return Self.promptChoice(for: early)
                }
                return try await promptOverride(request)
            }
            let outcome = await ToolPermissionPromptService.requestPolicyApproval(
                toolName: request.toolName,
                description: request.description,
                argumentsJSON: request.argumentsJSON,
                revalidate: revalidate
            )
            return Self.promptChoice(for: outcome)
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
            // A sibling prompt in the same wave may already have persisted
            // Always Allow. Writing it again would advance the launcher's
            // permission revision a second time and trip the ABA check in
            // `TextSubagentKind.revalidateAfterPermission` for this sibling.
            if await effectivePolicy(for: scope) == .alwaysAllow {
                return .allow
            }
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

    /// Policy re-read for a queued prompt: a persisted Always Allow or Deny
    /// settles the request without a panel; Ask means the card is still owed.
    static func silentResolution(
        for policy: SubagentPermissionPolicy
    ) -> ToolPermissionPromptService.PolicyApprovalOutcome? {
        switch policy {
        case .alwaysAllow: return .allowOnce
        case .deny: return .denied
        case .ask: return nil
        }
    }

    static func promptChoice(
        for outcome: ToolPermissionPromptService.PolicyApprovalOutcome
    ) -> PromptChoice {
        switch outcome {
        case .denied: return .deny
        case .allowOnce: return .allowOnce
        case .alwaysAllow: return .alwaysAllow
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
