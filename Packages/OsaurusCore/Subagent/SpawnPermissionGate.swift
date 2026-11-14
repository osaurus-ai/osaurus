//
//  SpawnPermissionGate.swift
//  OsaurusCore
//
//  One permission owner for `spawn_agent` (local and workspace targets).
//  Spawn policies live in SubagentConfiguration / AgentSettings, so "Always
//  Allow" must persist there rather than in ToolRegistry's generic tool map.
//  Two permission kinds share this gate: `spawn` (local agents, default
//  Always Allow) and `spawn_workspace` (teammates' shared agents, default
//  Ask). A mixed wave shows ONE card covering the kinds that are on Ask;
//  "Always Allow" on that card persists exactly those kinds.
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
    /// delegation evaluations still execute the real gate, but cannot inherit
    /// a developer machine's persisted Deny setting.
    @TaskLocal
    static var policyOverrideForTests: SubagentPermissionPolicy?

    /// The launcher's policy for one permission kind: `spawn` (local
    /// agents, default Always Allow) or `spawn_workspace` (teammates'
    /// shared agents, default Ask — the run leaves this Mac and spends the
    /// workspace pool).
    static func effectivePolicy(
        for scope: SubagentScope,
        kindId: String = SubagentCapabilityRegistry.spawn.id
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
            capabilityId: kindId,
            isDefault: isDefault,
            config: config,
            settings: settings
        )
    }

    /// The strictest policy across several kinds (a mixed local + workspace
    /// wave): Deny wins, then Ask, then Always Allow.
    static func combinedPolicy(_ policies: [SubagentPermissionPolicy]) -> SubagentPermissionPolicy {
        if policies.contains(.deny) { return .deny }
        if policies.contains(.ask) { return .ask }
        return .alwaysAllow
    }

    /// Resolve one spawn policy decision before admission/model loading.
    ///
    /// `cancellationRequested` is the visible subagent Stop token. The prompt
    /// operation is owned and drained, so a cancelled panel/test seam cannot
    /// outlive the rejected tool call.
    ///
    /// `waveMember` marks a `spawn_agent` call that may belong to a sibling
    /// wave (several spawn calls in one model message). Members rendezvous in
    /// `SpawnWaveGate` for one shared card and one fan-out limit check; the
    /// wave's own card passes nil.
    static func authorize(
        scope: SubagentScope,
        policy: SubagentPermissionPolicy,
        toolName: String,
        description: String,
        argumentsJSON: String,
        cancellationRequested: @escaping @Sendable () -> Bool = { false },
        waveMember: SpawnWaveGate.Member? = nil,
        permissionKindIds: Set<String> = [SubagentCapabilityRegistry.spawn.id]
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
                SpawnFanOutPolicy.effectiveFanOutLimits(scope: scope)
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
            Self.silentResolution(for: await effectivePolicy(for: scope, kindIds: permissionKindIds))
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
            if await effectivePolicy(for: scope, kindIds: permissionKindIds) == .alwaysAllow {
                return .allow
            }
            let persisted = await persistAlwaysAllow(
                launchingAgentId: scope.agentId,
                kindIds: permissionKindIds
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

    /// Combined policy across every kind the card covers.
    static func effectivePolicy(
        for scope: SubagentScope,
        kindIds: Set<String>
    ) async -> SubagentPermissionPolicy {
        var policies: [SubagentPermissionPolicy] = []
        for kind in kindIds.sorted() {
            policies.append(await effectivePolicy(for: scope, kindId: kind))
        }
        return combinedPolicy(policies)
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
        launchingAgentId: UUID,
        kindIds: Set<String> = [SubagentCapabilityRegistry.spawn.id]
    ) async -> Bool {
        let kinds = kindIds.sorted()
        if launchingAgentId == Agent.defaultId {
            SubagentConfigurationStore.mutate { config in
                for kind in kinds {
                    config.permissionDefaults.setPolicy(.alwaysAllow, for: kind)
                }
            }
            return true
        }

        return await MainActor.run {
            guard var agent = AgentManager.shared.agent(for: launchingAgentId),
                !agent.isBuiltIn
            else {
                return false
            }
            for kind in kinds {
                agent.settings.subagentPermissions.setPolicy(.alwaysAllow, for: kind)
            }
            AgentManager.shared.update(agent)
            return true
        }
    }
}
