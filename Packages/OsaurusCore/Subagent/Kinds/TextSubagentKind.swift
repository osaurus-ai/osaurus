//
//  TextSubagentKind.swift
//  OsaurusCore — Subagent framework
//
//  The text/coding/analysis sub-agent kind behind the spawn family. It serves
//  BOTH spawn tools through one bounded text loop:
//
//   • `spawn_agent` → `.agent(name:)`: resolve a user-configured spawnable
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

final class TextSubagentKind: SubagentKind, @unchecked Sendable {
    let capability = SubagentCapabilityRegistry.spawn

    /// What this spawn delegates to. The two tools map onto exactly one case
    /// each — there is no agent+model combination, so the contract stays a single
    /// required target per tool.
    enum Target: Sendable {
        /// `spawn_agent`: a spawnable agent by name (its prompt + model).
        case agent(name: String)
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

    /// Cap on the digest handed back to the parent.
    private static let digestMaxChars = 8_000

    // Resolved up front in `resolveModel`, read by permission/handoff/run.
    private var resolvedAgentName: String = ""
    private var resolvedAgentId: UUID?
    private var systemPrompt: String = ""
    private var budgets = SubagentBudgets()
    /// The residency plan resolved at `resolveModel` time (reject-before-evict),
    /// consumed by `makeHandoff()`. `.none` when no swap is needed.
    private var residencyPlan: ResidencyPlan = .none

    /// `spawn_agent` entry point (agent context). The optional `modelOverride`
    /// is the eval seam.
    init(agentName: String, input: String, modelOverride: String? = nil) {
        self.target = .agent(name: agentName)
        self.input = input
        self.modelOverride = modelOverride
    }

    /// `spawn_model` entry point (bare model, no agent). The optional
    /// `modelOverride` is the eval seam (forces the run model + residency
    /// passthrough); production passes nil so the real residency decision runs.
    init(model: String, input: String, modelOverride: String? = nil) {
        self.target = .model(id: model)
        self.input = input
        self.modelOverride = modelOverride
    }

    /// Human label of the spawn target for error/result copy: the resolved
    /// agent name (or the requested name pre-resolve) in agent mode, the model
    /// id in model mode.
    private var targetLabel: String {
        switch target {
        case .agent(let name): return resolvedAgentName.isEmpty ? name : resolvedAgentName
        case .model(let id): return id
        }
    }

    var feedTitle: String {
        switch target {
        case .agent(let name): return "spawn → \(name)"
        case .model(let id): return "spawn → \(id)"
        }
    }

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        let config = SubagentConfigurationStore.snapshot()
        // Per-agent allow-lists: the Default / main chat uses its own pools
        // (edited in the main chat's Sub-agents tab); a custom agent uses its own
        // lists (its Sub-agents tab), resolved from the launching agent (`scope`).
        // There is no global master switch.
        let isDefault = scope.agentId == Agent.defaultId
        // One launching-agent lookup feeds the per-agent spawn allow-lists,
        // permission, and budgets (Default / main chat → global config).
        let settings = await MainActor.run {
            AgentManager.shared.agent(for: scope.agentId)?.settings
        }

        // Permission gate is shared across both tools (one `spawn` capability).
        if SubagentToolVisibility.effectivePermission(
            capabilityId: capability.id,
            isDefault: isDefault,
            config: config,
            settings: settings
        ) == .deny {
            throw SubagentError.denied(
                "Spawning is denied by this agent's permission settings."
            )
        }

        self.budgets = SubagentToolVisibility.effectiveBudgets(
            isDefault: isDefault,
            config: config,
            settings: settings
        )

        switch target {
        case .agent(let agentName):
            return try await resolveAgentTarget(
                agentName,
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
        _ agentName: String,
        scope: SubagentScope,
        isDefault: Bool,
        config: SubagentConfiguration,
        settings: AgentSettings?
    ) async throws -> ResolvedModel {
        let perAgentTargets = settings?.spawnableAgentNames ?? []
        guard
            SubagentToolVisibility.spawnTargetAllowed(
                agentName,
                isDefault: isDefault,
                config: config,
                perAgentTargets: perAgentTargets
            )
        else {
            throw SubagentError.denied(
                Self.notSpawnableMessage(kind: "Agent", name: agentName, isDefault: isDefault)
            )
        }

        let agent = await MainActor.run {
            AgentManager.shared.agents.first {
                $0.name.caseInsensitiveCompare(agentName) == .orderedSame
            }
        }
        guard let agent else {
            throw SubagentError.unavailable("Agent '\(agentName)' not found.")
        }

        self.resolvedAgentName = agent.name
        self.resolvedAgentId = agent.id
        self.systemPrompt = agent.systemPrompt

        // One shared path for precedence (eval seam → per-agent `spawn` override
        // → the target agent's own model), the availability fallback, and the live
        // residency decision (reject-before-evict). The override is read from the
        // LAUNCHING agent (`scope.agentId`); the default is the target agent's model.
        let targetAgentId = agent.id
        let resolved = try await SubagentModelResolution.resolve(
            capabilityId: capability.id,
            agentId: scope.agentId,
            evalModel: modelOverride,
            idleWaitSeconds: self.budgets.maxElapsedSeconds,
            deniedMessage:
                "Spawning a different local agent requires \"Local Orchestrator Handoff\" enabled "
                + "in Settings → Sub-agents (so the chat model can unload to make room).",
            unavailableMessage: "Agent '\(agentName)' has no model configured.",
            defaultModel: { AgentManager.shared.effectiveModel(for: targetAgentId) }
        )
        self.residencyPlan = resolved.decision.plan
        return ResolvedModel(name: resolved.model, id: nil, isLocal: resolved.decision.isLocal)
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
        guard
            SubagentToolVisibility.spawnModelAllowed(
                modelId,
                isDefault: isDefault,
                config: config,
                perAgentModelTargets: perAgentModelTargets
            )
        else {
            throw SubagentError.denied(
                Self.notSpawnableMessage(kind: "Model", name: modelId, isDefault: isDefault)
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
            idleWaitSeconds: self.budgets.maxElapsedSeconds,
            deniedMessage:
                "Spawning a local model requires \"Local Orchestrator Handoff\" enabled in "
                + "Settings → Sub-agents (so the chat model can unload to make room).",
            unavailableMessage: "Model '\(modelId)' is not available.",
            defaultModel: { nil }
        )
        self.residencyPlan = resolved.decision.plan
        return ResolvedModel(name: resolved.model, id: nil, isLocal: resolved.decision.isLocal)
    }

    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
        // All policy gates are resolved up front in `resolveModel`
        // (reject-before-evict); spawn has no interactive prompt.
        .allow
    }

    func makeHandoff() -> SubagentHandoff {
        SubagentResidency.handoff(for: residencyPlan)
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

        let result = try await AgentSubagentRunner.run(
            modelName: resolved.name,
            seedMessages: seed,
            maxTokens: budgets.maxDelegateTokens,
            maxIterations: budgets.maxDelegateTurns,
            deadline: deadline,
            sessionId: sessionId,
            isInterrupted: { interrupt.isInterrupted }
        )
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
            if case .agent = target { payload["agent"] = resolvedAgentName }
            return SubagentResult(payload: payload, summary: capped)
        case .cancelled:
            throw SubagentError.timedOut(
                "Subagent '\(targetLabel)' hit its \(budgets.maxElapsedSeconds)s time budget."
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
        }
    }

    /// Shared "not spawnable" denial copy for both targets, so the agent and
    /// model messages can't drift. `kind` is the capitalized noun ("Agent" /
    /// "Model"); the tab pointer differs for the main chat vs a custom agent.
    private static func notSpawnableMessage(kind: String, name: String, isDefault: Bool) -> String {
        isDefault
            ? "\(kind) '\(name)' is not spawnable. Add it in the main chat's Sub-agents tab."
            : "\(kind) '\(name)' is not spawnable from this agent. Add it in the agent's Sub-agents tab."
    }

    private func seedMessages(systemPrompt: String, input: String) -> [ChatMessage] {
        var msgs: [ChatMessage] = []
        let sys = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty { msgs.append(ChatMessage(role: "system", content: sys)) }
        msgs.append(ChatMessage(role: "user", content: input))
        return msgs
    }
}
