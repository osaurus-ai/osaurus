//
//  TextSubagentKind.swift
//  OsaurusCore — Subagent framework
//
//  The text/coding/analysis subagent kind behind the spawn family. It serves
//  BOTH spawn tools through one bounded text loop:
//
//   • `spawn_agent` → `.agent(id:)`: resolve a user-configured spawnable
//     Agent and run on ITS system prompt + model.
//   • `spawn_model` → `.model(id:)`: run on a bare spawnable model id with NO
//     agent/system prompt attached.
//
//  Either way it runs through the shared host (`SubagentSession`), so the
//  recursion guard, live feed, and the optional residency handoff are shared,
//  and hands back only a compact digest (`AgentSubagentRunner`).
//
//  `modelSource = .agent`: when the resolved run model is local and a
//  DIFFERENT chat model is resident, `makeHandoff()` vends a `ResidencyHandoff`
//  that unloads the orchestrator (single GPU residency) and reloads it after the
//  run. This holds in every direction — local→local evicts, local→remote and
//  remote→anything do not — because the shared `SubagentModelResolution.resolve`
//  runs the live residency decision for both targets. The reject-before-evict
//  policy gates (not spawnable, permission denied, handoff disabled) are resolved
//  up front so nothing is evicted before we know the run can proceed.
//

import Foundation

final class TextSubagentKind:
    SubagentKind, SubagentPostAdmissionResidencyPlanning, @unchecked Sendable
{
    let capability = SubagentCapabilityRegistry.spawn

    /// What this spawn delegates to. The two tools map onto exactly one case
    /// each — there is no agent+model combination, so the contract stays a single
    /// required target per tool.
    enum Target: Sendable {
        /// `spawn_agent`: a spawnable agent by stable UUID (its prompt + model).
        case agent(id: UUID)
        /// `spawn_model`: a bare spawnable model id (no agent).
        case model(id: String)
    }

    private let target: Target
    private let input: String
    /// Eval seam (nil in production): force the run model and keep residency
    /// passthrough, so a live spawn lane is a real cross-model column in the
    /// local-vs-frontier matrix without depending on GPU residency. In `.agent`
    /// mode the agent still resolves (only its effective model is overridden);
    /// in `.model` mode it forces the run model after the pool gate. The target
    /// must still exist and be spawnable — the allow-list gate runs first.
    private let modelOverride: String?
    /// Set only by spawn_batch after its single batch-level gate succeeds.
    /// Individual children still re-read and enforce a newly changed `.deny`
    /// policy during resolution, but do not present N duplicate panels.
    private let permissionPreauthorized: Bool

    /// Mutable spawn authority captured around the direct Ask boundary.
    ///
    /// The permission field itself is normalized out because choosing
    /// "Always Allow" legitimately persists that one field while the panel is
    /// open. Spawn-relevant launcher, target, and shared residency values stay
    /// in the semantic fingerprint. Scoped configuration revisions catch a
    /// relevant ABA save/restore without treating an unrelated Image or
    /// AppleScript editor save as a Spawn authority change.
    private struct AuthoritySnapshot: Sendable, Equatable {
        let configurationRevision: SpawnConfigurationAuthorityRevision
        let launcher: SpawnLauncherAuthority
        let target: SpawnTargetAuthority?
        let launcherAgentRevisions: SpawnAgentAuthorityRevisions
        let targetAgentRevision: UInt64?
        let isDefaultLauncher: Bool
        let effectivePermission: SubagentPermissionPolicy
    }

    private var approvalAuthority: AuthoritySnapshot?
    private var executionAuthority: AuthoritySnapshot?

    /// Cap on the digest handed back to the parent.
    private static let digestMaxChars = 8_000

    /// Curated read-only child toolset (host reads + sandbox reads).
    /// `specs(forTools:)` silently drops whichever aren't registered right
    /// now, so the child only ever sees live tools.
    static let readOnlyChildToolNames = [
        "file_read", "file_search",
        "sandbox_read_file", "sandbox_search_files",
    ]

    /// Tool-call cap applied when the launching agent grants `readOnly`
    /// access but its `maxToolCalls` budget is 0 (the "use default" marker) —
    /// so enabling tool access is never silently inert.
    static let defaultReadOnlyToolCallCap = 8

    // Resolved up front in `resolveModel`, read by permission/handoff/run.
    private var resolvedAgentName: String = ""
    private var resolvedAgentId: UUID?
    private var systemPrompt: String = ""
    private var budgets = SubagentBudgets()
    /// The launching agent's child-tool grant (`none` = no generic read-only
    /// file tools; a target agent may still receive the cancellation-audited
    /// subset of its own enabled tools — see `agentToolSpecs`).
    private var toolAccess: SpawnToolAccess = .none
    /// Agent mode: the cancellation-audited subset of the target agent's
    /// enabled tools, resolved at `resolveModel` time. Empty for `spawn_model`,
    /// for agents with no tools enabled, and when none of the enabled tools
    /// expose cooperative abort-and-drain ownership for spawned execution.
    private var agentToolSpecs: [Tool] = []
    /// The target agent's user-set temperature override (agent mode only;
    /// `nil` keeps the model bundle's own generation defaults).
    private var temperature: Float?
    /// The residency plan resolved at `resolveModel` time (reject-before-evict),
    /// consumed by `makeHandoff()`. `.none` when no swap is needed.
    private var residencyPlan: ResidencyPlan = .none
    /// Exact parent model captured from the launching turn. Batch preparation
    /// re-resolves residency after admission and must keep the same parent
    /// identity instead of falling back to every chat-owned process resident.
    private var invokingParentModelName: String?
    /// Snapshot resolved before model lookup. `.deny` is rejected immediately;
    /// `.ask` is handled by `permission` unless the enclosing batch already
    /// received one approval for all of its jobs.
    private var resolvedPermissionPolicy: SubagentPermissionPolicy = .ask

    /// Batch scheduler inspection after `resolveModel`: lets the outer
    /// reject-before-load phase aggregate RAM requirements and choose one
    /// shared handoff for a canonical local-model group. Internal only; the
    /// public spawn contract remains the resolved model + result envelope.
    var preparedResidencyPlan: ResidencyPlan { residencyPlan }

    /// Re-resolve the local residency decision after a batch has acquired its
    /// process-wide local scheduling lease. Preparation intentionally happens
    /// before that wait so every target can be rejected before the first
    /// unload, but resident models, RAM pressure, and the user's handoff/RAM
    /// settings can change while a batch is queued. The batch scheduler must
    /// therefore use this current decision for both capacity and the one
    /// group-owned handoff instead of replaying the preparation snapshot.
    func refreshedResidencyPlanAfterAdmission(
        for resolved: ResolvedModel
    ) async throws -> ResidencyPlan {
        guard resolved.isLocal else { return .none }

        // Eval runs deliberately bypass production residency. A production
        // local row never reaches this branch with a model override.
        if modelOverride != nil { return residencyPlan }

        let lookup = resolved.id ?? resolved.name
        guard
            let installed =
                ModelManager.findInstalledModel(named: lookup)
                ?? ModelManager.findInstalledModel(named: resolved.name)
        else {
            throw SubagentError.unavailable(
                "Local model '\(resolved.name)' is no longer installed."
            )
        }

        let decision = try await SubagentResidency.resolve(
            modelName: installed.id,
            config: SubagentConfigurationStore.snapshot(),
            idleWaitSeconds: budgets.normalized.maxElapsedSeconds,
            deniedMessage: residencyDeniedMessage,
            invokingParentModelName: invokingParentModelName
        )
        guard decision.isLocal else {
            throw SubagentError.unavailable(
                "Local model '\(resolved.name)' became unavailable while the batch was waiting."
            )
        }
        residencyPlan = decision.plan
        return decision.plan
    }

    /// `spawn_agent` entry point (agent context). The optional `modelOverride`
    /// is the eval seam.
    init(
        agentID: UUID,
        input: String,
        modelOverride: String? = nil,
        permissionPreauthorized: Bool = false
    ) {
        self.target = .agent(id: agentID)
        self.input = input
        self.modelOverride = modelOverride
        self.permissionPreauthorized = permissionPreauthorized
    }

    /// `spawn_model` entry point (bare model, no agent). The optional
    /// `modelOverride` is the eval seam (forces the run model + residency
    /// passthrough); production passes nil so the real residency decision runs.
    init(
        model: String,
        input: String,
        modelOverride: String? = nil,
        permissionPreauthorized: Bool = false
    ) {
        self.target = .model(id: model)
        self.input = input
        self.modelOverride = modelOverride
        self.permissionPreauthorized = permissionPreauthorized
    }

    /// Human label of the spawn target for error/result copy: the resolved
    /// agent name (or the requested name pre-resolve) in agent mode, the model
    /// id in model mode.
    private var targetLabel: String {
        switch target {
        case .agent(let id): return resolvedAgentName.isEmpty ? id.uuidString : resolvedAgentName
        case .model(let id): return id
        }
    }

    private var residencyDeniedMessage: String {
        switch target {
        case .agent:
            return
                "Spawning a different local agent requires \"Local Orchestrator Handoff\" enabled "
                + "in Settings → Subagents (so the chat model can unload to make room)."
        case .model:
            return
                "Spawning a local model requires \"Local Orchestrator Handoff\" enabled in "
                + "Settings → Subagents (so the chat model can unload to make room)."
        }
    }

    var feedTitle: String {
        switch target {
        case .agent(let id): return "spawn → \(resolvedAgentName.isEmpty ? id.uuidString : resolvedAgentName)"
        case .model(let id): return "spawn → \(id)"
        }
    }

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        let resolved = try await resolveCurrentModel(scope)
        if permissionPreauthorized {
            // The enclosing batch owns the one interactive permission gate,
            // but each prepared child still needs a current authority snapshot
            // for the post-admission execution boundary.
            executionAuthority = await authoritySnapshot(for: scope)
        } else if approvalAuthority == nil {
            approvalAuthority = await authoritySnapshot(for: scope)
        }
        return resolved
    }

    private func resolveCurrentModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        invokingParentModelName = scope.parentModelName
        let config = SubagentConfigurationStore.snapshot()
        // Per-agent allow-lists: the Default / main chat uses its own pools
        // (edited in Settings → Subagents); a custom agent uses its own
        // lists (its Subagents tab), resolved from the launching agent (`scope`).
        // There is no global master switch.
        let isDefault = scope.agentId == Agent.defaultId
        // One launching-agent lookup feeds the per-agent spawn allow-lists,
        // permission, and budgets (Default / main chat → global config).
        let settings = await MainActor.run {
            AgentManager.shared.agent(for: scope.agentId)?.settings
        }

        // Permission gate is shared across both tools (one `spawn` capability).
        // Deny is resolved before target/provider/model work. Ask remains a
        // real interactive gate in `permission` (or one enclosing batch gate).
        self.resolvedPermissionPolicy = SubagentToolVisibility.effectivePermission(
            capabilityId: capability.id,
            isDefault: isDefault,
            config: config,
            settings: settings
        )
        if resolvedPermissionPolicy == .deny {
            throw SubagentError.denied(
                "Spawning is denied by this agent's permission settings."
            )
        }

        self.budgets = SubagentToolVisibility.effectiveBudgets(
            isDefault: isDefault,
            config: config,
            settings: settings,
            sharedParallelLimit: SpawnBatchConcurrencyContract.configuredLimit(
                for: ServerRuntimeSettingsStore.snapshot()
            )
        )
        self.toolAccess = SubagentToolVisibility.effectiveSpawnToolAccess(
            isDefault: isDefault,
            config: config,
            settings: settings
        )

        switch target {
        case .agent(let agentID):
            return try await resolveAgentTarget(
                agentID,
                scope: scope,
                isDefault: isDefault,
                config: config,
                settings: settings
            )
        case .model(let modelId):
            return try await resolveModelTarget(
                modelId,
                scope: scope,
                isDefault: isDefault,
                config: config,
                settings: settings
            )
        }
    }

    /// `spawn_agent`: gate the agent allow-list, resolve the agent (its
    /// system prompt becomes the seed system message), and resolve its model
    /// through the shared precedence (eval seam → per-agent override → the
    /// target agent's own model) + live residency decision.
    private func resolveAgentTarget(
        _ agentID: UUID,
        scope: SubagentScope,
        isDefault: Bool,
        config: SubagentConfiguration,
        settings: AgentSettings?
    ) async throws -> ResolvedModel {
        guard agentID != scope.agentId else {
            throw SubagentError.denied(
                "An agent cannot spawn itself. Choose a different configured agent or a bare model."
            )
        }

        let perAgentTargets = settings?.spawnableAgentIDs ?? []
        let allowedAgentTargets =
            SubagentToolVisibility.effectiveSpawnableAgents(
                isDefault: isDefault,
                config: config,
                perAgentEnabled: settings?.spawnDelegationEnabled ?? false,
                perAgentTargets: perAgentTargets
            )
        guard
            SubagentToolVisibility.spawnTargetAllowed(
                agentID,
                isDefault: isDefault,
                config: config,
                perAgentTargets: allowedAgentTargets
            )
        else {
            throw SubagentError.denied(
                Self.notSpawnableMessage(
                    kind: "Agent",
                    name: agentID.uuidString,
                    isDefault: isDefault
                )
            )
        }

        let agent = await MainActor.run {
            AgentManager.shared.agent(for: agentID)
        }
        guard let agent else {
            throw SubagentError.unavailable("Agent '\(agentID.uuidString)' not found.")
        }

        self.resolvedAgentName = agent.name
        self.resolvedAgentId = agent.id
        self.systemPrompt = agent.systemPrompt
        // The persona's tool policy rides along with its prompt + model
        // (the design contract: a subagent IS the agent, bounded). Tool
        // EXECUTION still flows through `ToolRegistry.execute`, so per-tool
        // permission gates apply exactly as they do in a direct chat with
        // this agent.
        self.agentToolSpecs = await MainActor.run {
            Self.agentChildToolSpecs(agentId: agent.id)
        }
        // The target agent's own sampling override rides along (a user-set
        // value, consistent with "defaults come from the model bundle unless
        // the user explicitly overrides").
        self.temperature = await MainActor.run {
            AgentManager.shared.effectiveTemperature(for: agent.id)
        }

        // One shared path for precedence (eval seam → per-agent `spawn` override
        // → the target agent's own model), fail-closed override availability,
        // and the live residency decision (reject-before-evict). The override
        // is read from the LAUNCHING agent (`scope.agentId`); the default is
        // used only when no override is configured.
        let targetAgentId = agent.id
        let resolved = try await SubagentModelResolution.resolve(
            capabilityId: capability.id,
            agentId: scope.agentId,
            evalModel: modelOverride,
            invokingParentModelName: scope.parentModelName,
            idleWaitSeconds: self.budgets.maxElapsedSeconds,
            deniedMessage: residencyDeniedMessage,
            unavailableMessage: "Agent '\(agent.name)' has no available model configured.",
            defaultModel: { AgentManager.shared.effectiveModel(for: targetAgentId) }
        )
        self.residencyPlan = resolved.decision.plan
        return ResolvedModel(
            name: resolved.model,
            id: resolved.installedModelID,
            isLocal: resolved.decision.isLocal
        )
    }

    /// `spawn_model`: gate the model allow-list, then run with NO agent (empty
    /// system prompt). The requested id is the explicit run model — it ranks
    /// above any per-agent override and still flows through the live residency
    /// decision (local target evicts, remote does not).
    private func resolveModelTarget(
        _ modelId: String,
        scope: SubagentScope,
        isDefault: Bool,
        config: SubagentConfiguration,
        settings: AgentSettings?
    ) async throws -> ResolvedModel {
        let perAgentModelTargets = settings?.spawnableModelNames ?? []
        let allowedModelTargets = SubagentToolVisibility.effectiveSpawnableModels(
            isDefault: isDefault,
            config: config,
            perAgentEnabled: settings?.spawnDelegationEnabled ?? false,
            perAgentModelTargets: perAgentModelTargets
        )
        guard
            SubagentToolVisibility.spawnModelAllowed(
                modelId,
                isDefault: isDefault,
                config: config,
                perAgentModelTargets: allowedModelTargets
            )
        else {
            throw SubagentError.denied(
                Self.notSpawnableMessage(
                    kind: "Model",
                    name: modelId,
                    isDefault: isDefault,
                    allowedNames: allowedModelTargets
                )
            )
        }

        // No agent: the bare model runs the task with just the user input.
        self.systemPrompt = ""

        // Production: `modelOverride` is nil, so `requestedModel` is the explicit
        // target and the live residency decision runs (local evicts, remote does
        // not). Eval seam: `modelOverride` forces the run model with residency
        // passthrough — the pool gate above still applies either way.
        let resolved = try await SubagentModelResolution.resolve(
            capabilityId: capability.id,
            agentId: scope.agentId,
            evalModel: modelOverride,
            requestedModel: modelId,
            invokingParentModelName: scope.parentModelName,
            idleWaitSeconds: self.budgets.maxElapsedSeconds,
            deniedMessage: residencyDeniedMessage,
            unavailableMessage: "Model '\(modelId)' is not available.",
            defaultModel: { nil }
        )
        self.residencyPlan = resolved.decision.plan
        return ResolvedModel(
            name: resolved.model,
            id: resolved.installedModelID,
            isLocal: resolved.decision.isLocal
        )
    }

    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
        if permissionPreauthorized {
            return .allow
        }
        return await SpawnPermissionGate.authorize(
            scope: scope,
            policy: resolvedPermissionPolicy,
            toolName: toolName,
            description:
                "Allow this agent to spawn one bounded \(targetKindLabel) subagent?",
            argumentsJSON: approvalArgumentsJSON(resolvedModel: resolved.name)
        )
    }

    func revalidateAfterPermission(
        _ scope: SubagentScope,
        approved resolved: ResolvedModel
    ) async throws -> ResolvedModel {
        // spawn_batch owns one enclosing approval, re-prepares every child, and
        // performs its own ABA-safe batch fingerprint immediately before
        // execution. Do not add a duplicate child boundary there.
        guard !permissionPreauthorized else { return resolved }
        guard let approvedAuthority = approvalAuthority else {
            throw SubagentError.denied(
                "Spawn authorization state was not captured. No subagent was started."
            )
        }

        let afterPermission = await authoritySnapshot(for: scope)
        guard Self.matchesApprovedAuthority(
            approvedAuthority,
            current: afterPermission
        ) else {
            throw SubagentError.denied(
                "Spawn settings, launcher, or target agent changed while approval was open. "
                    + "No subagent was started; review the current Subagents settings and retry."
            )
        }

        let currentResolved = try await resolveCurrentModel(scope)
        let afterResolution = await authoritySnapshot(for: scope)
        guard afterResolution == afterPermission,
            currentResolved == resolved
        else {
            throw SubagentError.denied(
                "Spawn settings, target, or resolved model changed after approval. "
                    + "No subagent was started; review the current Subagents settings and retry."
            )
        }
        executionAuthority = afterResolution
        return currentResolved
    }

    func validateExecutionAuthority(
        _ scope: SubagentScope,
        resolved: ResolvedModel
    ) async throws {
        guard let approved = executionAuthority else {
            throw SubagentError.denied(
                "Spawn execution authority was not captured. No subagent was started."
            )
        }
        let current = await authoritySnapshot(for: scope)
        guard current == approved else {
            throw SubagentError.denied(
                "Spawn settings, launcher, or target agent changed before execution. "
                    + "No subagent was started; review the current Subagents settings and retry."
            )
        }
    }

    private func authoritySnapshot(
        for scope: SubagentScope
    ) async -> AuthoritySnapshot {
        // Capture configuration plus Spawn-scoped monotonic revisions in one
        // linearizable read. A cold load must not look like a mutation.
        let storeSnapshot =
            SubagentConfigurationStore
                .snapshotWithSpawnAuthorityRevisions()
        let configuration = storeSnapshot.configuration
        let isDefault = scope.agentId == Agent.defaultId
        let targetAgentID: UUID? = {
            guard case .agent(let id) = target else { return nil }
            return id
        }()
        let pair = await MainActor.run {
            let launcher = AgentManager.shared.spawnAuthoritySnapshot(
                for: scope.agentId
            )
            let target = targetAgentID.map {
                AgentManager.shared.spawnAuthoritySnapshot(for: $0)
            }
            return (
                launcher: launcher,
                target: target
            )
        }

        let effectivePermission = SubagentToolVisibility.effectivePermission(
            capabilityId: capability.id,
            isDefault: isDefault,
            config: configuration,
            settings: pair.launcher.agent?.settings
        )
        let sharedParallelLimit =
            SpawnBatchConcurrencyContract.configuredLimit(
                for: ServerRuntimeSettingsStore.snapshot()
            )

        return AuthoritySnapshot(
            configurationRevision: SpawnConfigurationAuthorityRevision(
                shared: storeSnapshot.spawnSharedRevision,
                defaultLauncher:
                    isDefault
                    ? storeSnapshot.spawnDefaultRevision
                    : nil
            ),
            launcher: SpawnLauncherAuthority(
                id: scope.agentId,
                isDefault: isDefault,
                configuration: configuration,
                agent: pair.launcher.agent,
                sharedParallelLimit: sharedParallelLimit
            ),
            target: pair.target?.agent.map(SpawnTargetAuthority.init),
            launcherAgentRevisions: pair.launcher.revisions,
            targetAgentRevision: pair.target?.revisions.target,
            isDefaultLauncher: isDefault,
            effectivePermission: effectivePermission
        )
    }

    private static func matchesApprovedAuthority(
        _ approved: AuthoritySnapshot,
        current: AuthoritySnapshot
    ) -> Bool {
        guard approved.launcher == current.launcher,
            approved.target == current.target,
            approved.launcherAgentRevisions.launcher
                == current.launcherAgentRevisions.launcher,
            approved.targetAgentRevision == current.targetAgentRevision,
            approved.isDefaultLauncher == current.isDefaultLauncher,
            approved.configurationRevision.shared
                == current.configurationRevision.shared
        else { return false }

        // Direct approval may legitimately persist Ask → Always Allow exactly
        // once. The Default launcher writes that policy to the shared store,
        // advancing only its scoped Spawn generation. A custom launcher writes
        // the policy to its own Agent; `SpawnLauncherAuthority` deliberately
        // excludes that permission field, so no shared-store generation moves.
        if approved.effectivePermission == .ask,
            current.effectivePermission == .alwaysAllow
        {
            if approved.isDefaultLauncher {
                guard let approvedDefault =
                    approved.configurationRevision.defaultLauncher,
                    let currentDefault =
                        current.configurationRevision.defaultLauncher
                else { return false }
                return approvedDefault < UInt64.max
                    && currentDefault == approvedDefault + 1
            }
            return current.configurationRevision.defaultLauncher
                == approved.configurationRevision.defaultLauncher
                && approved.launcherAgentRevisions.permission < UInt64.max
                && current.launcherAgentRevisions.permission
                    == approved.launcherAgentRevisions.permission + 1
        }
        return current.configurationRevision.defaultLauncher
            == approved.configurationRevision.defaultLauncher
            && current.launcherAgentRevisions.permission
                == approved.launcherAgentRevisions.permission
            && current.effectivePermission == approved.effectivePermission
    }

    private var toolName: String {
        switch target {
        case .agent: return SubagentCapabilityRegistry.spawnAgentToolName
        case .model: return SubagentCapabilityRegistry.spawnModelToolName
        }
    }

    private var targetKindLabel: String {
        switch target {
        case .agent: return "configured-agent"
        case .model: return "model"
        }
    }

    private func approvalArgumentsJSON(resolvedModel: String) -> String {
        let targetType: String
        let targetValue: String
        switch target {
        case .agent(let id):
            targetType = "agent"
            targetValue = id.uuidString
        case .model(let id):
            targetType = "model"
            targetValue = id
        }
        let payload: [String: Any] = [
            "target_type": targetType,
            "target": targetValue,
            "input": input,
            "resolved_model": resolvedModel,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            ),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }

    func makeHandoff() -> SubagentHandoff {
        SubagentResidency.handoff(for: residencyPlan)
    }

    func admissionClass(_ resolved: ResolvedModel) -> SubagentAdmissionClass {
        SubagentResidency.admissionClass(isLocal: resolved.isLocal, plan: residencyPlan)
    }

    func run(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel,
        feed: SubagentFeed,
        interrupt: InterruptToken
    ) async throws -> SubagentResult {
        feed.emitPhase("running", detail: resolved.name)
        let budgets = self.budgets.normalized
        let deadline = Date().addingTimeInterval(TimeInterval(budgets.maxElapsedSeconds))
        let started = Date()
        let seed = seedMessages(systemPrompt: systemPrompt, input: input)
        let sessionId = "spawn-\((resolvedAgentId ?? UUID()).uuidString)-\(UUID().uuidString)"
        let toolset = await Self.makeToolset(
            access: toolAccess,
            maxToolCalls: budgets.maxToolCalls,
            feed: feed,
            agentSpecs: agentToolSpecs,
            executionAgentId: Self.childToolExecutionAgentId(
                targetAgentId: resolvedAgentId,
                launcherAgentId: scope.agentId
            )
        )

        // Knowledge tools inside the child resolve grants + curator role against
        // the TARGET agent (isolation), not the launcher identity that owns the
        // surrounding model run, admission, handoff, and usage accounting.
        // `nil` for `spawn_model` (no agent, no knowledge tools) falls back to
        // the launcher's `currentAgentId`.
        let result = try await ChatExecutionContext.$knowledgeGrantAgentIdOverride
            .withValue(resolvedAgentId)
        {
            try await AgentSubagentRunner.run(
                modelName: resolved.name,
                seedMessages: seed,
                maxTokens: budgets.maxDelegateTokens,
                maxIterations: budgets.maxDelegateTurns,
                deadline: deadline,
                sessionId: sessionId,
                temperature: temperature,
                enableThinking: scope.enableThinking,
                isInterrupted: { interrupt.isInterrupted },
                toolset: toolset,
                onProgress: { [feed] tokens, tokensPerSecond in
                    // Live "generating" row: coalesced in place by the feed, so
                    // long generations show advancing tokens + tok/s.
                    var detail = "\(tokens) tokens"
                    if let tokensPerSecond {
                        detail += String(format: " · %.1f tok/s", tokensPerSecond)
                    }
                    feed.emitProgress("generating", step: tokens, detail: detail)
                },
                onChannelDelta: { [feed] delta in
                    switch delta {
                    case .reasoning(let fragment):
                        feed.emitStreamDelta(
                            kind: .reasoning,
                            title: "reasoning",
                            delta: fragment
                        )
                    case .content(let fragment):
                        feed.emitStreamDelta(
                            kind: .response,
                            title: "response",
                            delta: fragment
                        )
                    }
                }
            )
        }
        let elapsed = Date().timeIntervalSince(started)

        switch result.exit {
        case .finalResponse, .endedBySurface:
            let digest = (result.digest ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !digest.isEmpty else {
                throw SubagentError.executionFailed(
                    message: "Subagent '\(targetLabel)' finished without producing a result.",
                    retryable: true
                )
            }
            let capped =
                digest.count > Self.digestMaxChars
                ? String(digest.prefix(Self.digestMaxChars)) + "\n[digest truncated]"
                : digest
            // `agent` is only meaningful in agent mode; model-only spawns omit
            // it so the parent's envelope isn't littered with an empty field.
            var payload: [String: Any] = [
                "kind": "spawn_result",
                "model": resolved.name,
                "summary": capped,
                "iterations": result.iterations,
                "elapsed_seconds": elapsed,
                "handoff": residencyPlan.shouldUnload,
            ]
            if case .agent = target {
                payload["agent"] = resolvedAgentName
                payload["agent_id"] = resolvedAgentId?.uuidString ?? NSNull()
            }

            // Usage + context-saved accounting: what the worker consumed vs
            // what the digest costs the parent — the measurable "context
            // saved" per delegation.
            let usage = result.usage
            var usageDict: [String: Any] = [
                "prompt_tokens": usage.promptTokens,
                "completion_tokens": usage.completionTokens,
                "total_tokens": usage.promptTokens + usage.completionTokens,
            ]
            if let tps = usage.tokensPerSecond {
                usageDict["tokens_per_second"] = (tps * 10).rounded() / 10
            }
            payload["usage"] = usageDict
            let workerTokens = usage.promptTokens + usage.completionTokens
            let digestTokens = TokenEstimator.estimate(capped)
            payload["context"] = [
                "worker_tokens": workerTokens,
                "digest_tokens": digestTokens,
                "context_saved_tokens": max(0, workerTokens - digestTokens),
            ]
            return SubagentResult(payload: payload, summary: capped)
        case .cancelled:
            throw Self.cancelError(
                cause: result.cancelCause,
                label: targetLabel,
                maxElapsedSeconds: budgets.maxElapsedSeconds
            )
        case .iterationCapReached:
            throw SubagentError.iterationCap(
                "Subagent '\(targetLabel)' used all \(budgets.maxDelegateTurns) turns without a result."
            )
        case .toolRejected:
            throw SubagentError.toolRejected(
                "Subagent '\(targetLabel)' attempted unavailable child tool use."
            )
        case .overBudget:
            throw SubagentError.overBudget(
                "Subagent '\(targetLabel)' exceeded its context budget. Pass shorter input."
            )
        case .emptyResponseExhausted:
            throw SubagentError.emptyExhausted(
                "Subagent '\(targetLabel)' returned empty output after tool execution; the task may be incomplete."
            )
        case .lengthExhausted:
            throw SubagentError.executionFailed(
                message: "Subagent '\(targetLabel)' reached its output-token limit before producing a result.",
                retryable: false
            )
        case .oversizedToolCallExhausted:
            throw SubagentError.executionFailed(
                message:
                    "Subagent '\(targetLabel)' repeatedly produced an oversized tool call.",
                retryable: false
            )
        case .truncatedToolCallExhausted:
            throw SubagentError.executionFailed(
                message:
                    "Subagent '\(targetLabel)' repeatedly reached its output limit inside a tool call.",
                retryable: false
            )
        case .incompleteReasoningExhausted:
            throw SubagentError.executionFailed(
                message: "Subagent '\(targetLabel)' ended in reasoning without producing a visible result.",
                retryable: false
            )
        }
    }

    /// Honest exit mapping for a `.cancelled` runner exit: the three cancel
    /// causes get DISTINCT copy (a user stop is not a "time budget" failure).
    /// Pure — unit-testable without a live runner.
    static func cancelError(
        cause: SubagentCancelCause?,
        label: String,
        maxElapsedSeconds: Int
    ) -> SubagentError {
        switch cause {
        case .userInterrupt:
            return .userDenied("Subagent '\(label)' was stopped by the user.")
        case .parentTask:
            return .executionFailed(
                message: "Subagent '\(label)' was cancelled with the parent run.",
                retryable: false
            )
        case .deadline, .none:
            return .timedOut(
                "Subagent '\(label)' hit its \(maxElapsedSeconds)s time budget."
            )
        }
    }

    /// Tool names never exposed inside a spawned child, on top of the target
    /// agent's own policy:
    /// - every subagent-capability tool (`spawn_agent`, `spawn_model`,
    ///   `image`, computer-use, AppleScript): a bounded child must not fan out
    ///   further — the recursion guard would refuse at runtime, but keeping
    ///   the names out of the schema saves the wasted turns.
    /// - `clarify`: it asks the USER a question, and a spawned child has no
    ///   user surface — the question would strand the run until its deadline.
    static func isExcludedChildTool(_ name: String) -> Bool {
        if SubagentCapabilityRegistry.capability(forToolName: name) != nil { return true }
        return name == "clarify"
    }

    /// The target agent's cancellation-safe enabled tools, as the child's
    /// schema. Start with the same per-agent enabled-name source the direct-chat
    /// surface uses (`effectiveEnabledToolNames`), apply the exclusions above,
    /// then intersect it with tools that expose audited abort-and-drain
    /// ownership. A direct-chat tool without that ownership is deliberately
    /// absent rather than becoming an uninterruptible spawned operation.
    @MainActor
    static func agentChildToolSpecs(agentId: UUID) -> [Tool] {
        let caps = AgentManager.shared.effectiveCapabilities(for: agentId)
        let names = childToolNames(
            manual: AgentManager.shared.effectiveEnabledToolNames(for: agentId) ?? [],
            knowledgeEnabled: caps.knowledgeEnabled,
            knowledgeCuratorEnabled: caps.knowledgeCuratorEnabled
        )
        guard !names.isEmpty else { return [] }
        return ToolRegistry.shared.specsForSpawnedOperations(forTools: names)
    }

    /// The tool NAMES a spawned child carries: the target agent's manual
    /// allowlist plus the feature-gated knowledge/curator built-ins it has
    /// enabled. Those built-ins are controlled by the Knowledge / Curator
    /// toggles (not the tools list) so they never appear in `manualToolNames`;
    /// folding them here mirrors the chat resolver, otherwise a spawned
    /// knowledge/curator agent is silently tool-less. The grant boundary is
    /// unchanged — collections resolve per-agent via `currentAgentId` at
    /// execution, so the child sees only its OWN granted collections (and is
    /// denied when it has none). Pure, so it is unit-testable without the
    /// registry. Spawn-capability tools and `clarify` are dropped for children.
    static func childToolNames(
        manual: [String],
        knowledgeEnabled: Bool,
        knowledgeCuratorEnabled: Bool
    ) -> [String] {
        var names = manual
        if knowledgeEnabled {
            names.append(contentsOf: SystemPromptComposer.knowledgeToolNames)
            if knowledgeCuratorEnabled {
                names.append(contentsOf: SystemPromptComposer.knowledgeCuratorToolNames)
            }
        }
        return Array(Set(names.filter { !isExcludedChildTool($0) }))
    }

    /// Identity used only while a spawned child's tool body crosses the shared
    /// `ToolRegistry` boundary. A configured-agent spawn must execute with the
    /// selected target agent's UUID so its tool policy, secrets, database, and
    /// sandbox scope match the persona whose prompt/schema the model received.
    /// A bare-model spawn has no target persona and therefore keeps the
    /// launcher's UUID. The surrounding inference/admission/handoff lifecycle
    /// remains launcher-owned; this value is bound around each tool operation,
    /// not around `AgentSubagentRunner.run`.
    static func childToolExecutionAgentId(
        targetAgentId: UUID?,
        launcherAgentId: UUID
    ) -> UUID {
        targetAgentId ?? launcherAgentId
    }

    /// Build the child's toolset: the target agent's cancellation-audited tools
    /// (agent mode, `agentSpecs`) plus the curated read-only file set when the
    /// launching agent granted access; `nil` keeps the run text-only. The closure
    /// enforces the allowlist and the per-run tool-call cap, dispatches
    /// through the shared `ToolRegistry` (its permission gate + schema
    /// preflight included), and narrates each call to the live feed.
    ///
    /// `specs` / `dispatch` are injection seams for unit tests (production
    /// passes nil → live registry lookup + registry dispatch).
    static func makeToolset(
        access: SpawnToolAccess,
        maxToolCalls: Int,
        feed: SubagentFeed?,
        agentSpecs: [Tool] = [],
        specs specsOverride: [Tool]? = nil,
        executionAgentId: UUID? = nil,
        dispatch: (@Sendable (ServiceToolInvocation) async -> String)? = nil
    ) async -> AgentSubagentToolset? {
        let readOnlySpecs: [Tool]
        if access == .readOnly {
            if let specsOverride {
                readOnlySpecs = specsOverride
            } else {
                readOnlySpecs = await MainActor.run {
                    ToolRegistry.shared.specsForSpawnedOperations(
                        forTools: readOnlyChildToolNames
                    )
                }
            }
        } else if specsOverride != nil, agentSpecs.isEmpty {
            // Test seam parity: an explicit override with no grant still
            // yields nothing, exactly like the live registry path.
            return nil
        } else {
            readOnlySpecs = []
        }
        // Agent tools first (the persona's own contract), read-only extras
        // after; first spec wins on a name collision.
        var specs: [Tool] = []
        var seen = Set<String>()
        for spec in agentSpecs + readOnlySpecs where seen.insert(spec.function.name).inserted {
            specs.append(spec)
        }
        guard !specs.isEmpty else { return nil }
        let allowed = Set(specs.map { $0.function.name })
        // The parent chat publishes its own request scope. A spawned
        // agent executes inside that task, so leaving the TaskLocal inherited
        // makes the registry reject the child's legitimately exposed tools as
        // "not available in this conversation". Publish a distinct scope from
        // the child's exact schema for the lifetime of every child dispatch.
        // Keep one scope for the whole run so capabilities_load can grow it
        // additively, just like the direct chat loop.
        let childExecutionScope = ToolExecutionScope(exposed: specs)
        let cap = maxToolCalls > 0 ? maxToolCalls : defaultReadOnlyToolCallCap
        let counter = ToolCallCounter()
        let dispatchCall: @Sendable (ServiceToolInvocation) async -> String =
            dispatch
            ?? { invocation in
                do {
                    return try await ToolRegistry.shared.execute(
                        name: invocation.toolName,
                        argumentsJSON: invocation.jsonArguments,
                        ownsExecutionUntilTermination: true
                    )
                } catch {
                    return ToolEnvelope.fromError(error, tool: invocation.toolName)
                }
            }
        return AgentSubagentToolset(
            specs: specs,
            beginExecution: { [weak feed] invocation in
                guard allowed.contains(invocation.toolName) else {
                    return OwnedSubagentOperation {
                        ToolEnvelope.failure(
                            kind: .rejected,
                            message:
                                "Tool '\(invocation.toolName)' is not available inside this subagent. "
                                + "Available: \(allowed.sorted().joined(separator: ", ")).",
                            tool: invocation.toolName,
                            retryable: false
                        )
                    }
                }
                let used = counter.increment()
                guard used <= cap else {
                    return OwnedSubagentOperation {
                        ToolEnvelope.failure(
                            kind: .rejected,
                            message:
                                "Tool-call budget (\(cap)) exhausted for this subagent run. "
                                + "Produce your final answer from what you already have.",
                            tool: invocation.toolName,
                            retryable: false
                        )
                    }
                }
                feed?.emit(
                    SubagentActivityEvent(
                        step: used,
                        kind: .act,
                        title: invocation.toolName,
                        detail: Self.toolCallDetail(invocation)
                    )
                )
                return OwnedSubagentOperation {
                    let executeInChildScope: @Sendable () async -> String = {
                        await ChatExecutionContext.$toolExecutionScope.withValue(
                            childExecutionScope
                        ) {
                            await dispatchCall(invocation)
                        }
                    }
                    if let executionAgentId {
                        return await ChatExecutionContext.$currentAgentId.withValue(
                            executionAgentId
                        ) {
                            await executeInChildScope()
                        }
                    }
                    return await executeInChildScope()
                }
            }
        )
    }

    /// Compact one-line feed detail for a child tool call: the `path` /
    /// `query` argument when present, else nothing (never the raw JSON).
    private static func toolCallDetail(_ invocation: ServiceToolInvocation) -> String? {
        guard let data = invocation.jsonArguments.data(using: .utf8),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let value = (obj["path"] ?? obj["query"] ?? obj["pattern"]) as? String
        guard let value, !value.isEmpty else { return nil }
        return value.count > 80 ? String(value.prefix(80)) + "…" : value
    }

    /// Shared "not spawnable" denial copy for both targets, so the agent and
    /// model messages can't drift. `kind` is the capitalized noun ("Agent" /
    /// "Model"); the tab pointer differs for the main chat vs a custom agent.
    private static func notSpawnableMessage(
        kind: String,
        name: String,
        isDefault: Bool,
        allowedNames: [String] = []
    ) -> String {
        let base = isDefault
            ? "\(kind) '\(name)' is not spawnable. Add it in Settings → Subagents."
            : "\(kind) '\(name)' is not spawnable from this agent. Add it in the agent's Subagents tab."
        guard !allowedNames.isEmpty else { return base }
        let exact = allowedNames.map { "'\($0)'" }.joined(separator: ", ")
        return base + " Use exactly one configured id: \(exact)."
    }

    private func seedMessages(systemPrompt: String, input: String) -> [ChatMessage] {
        var msgs: [ChatMessage] = []
        let sys = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty { msgs.append(ChatMessage(role: "system", content: sys)) }
        msgs.append(ChatMessage(role: "user", content: input))
        return msgs
    }
}

/// Thread-safe per-run tool-call counter for the child toolset closure
/// (parallel batches may execute two child calls concurrently).
private final class ToolCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Increment and return the new total.
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
