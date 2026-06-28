//
//  TextSubagentKind.swift
//  OsaurusCore — Subagent framework
//
//  The text/coding/analysis sub-agent kind that serves `spawn`: resolve a
//  user-configured spawnable Agent persona, run a bounded text-only subagent on
//  its model (`AgentSubagentRunner`), and hand back a compact digest. Runs
//  through the shared host (`SubagentSession`), so the recursion guard, live
//  feed, and the optional residency handoff are all shared.
//
//  `modelSource = .persona`: when the persona's model is local and a DIFFERENT
//  chat model is resident, `makeHandoff()` vends a `ResidencyHandoff` that
//  unloads the orchestrator (single GPU residency) and reloads it after the
//  run. The reject-before-evict policy gates (not spawnable, permission denied,
//  handoff disabled) are resolved up front so nothing is evicted before we know
//  the run can proceed.
//

import Foundation

final class TextSubagentKind: SubagentKind, @unchecked Sendable {
    let capability = SubagentCapabilityRegistry.spawn

    private let agentName: String
    private let input: String
    /// Eval seam (nil in production): run the spawned persona on this model
    /// instead of its own configured model, so `spawn` becomes a real
    /// cross-model column in the local-vs-frontier matrix. The persona must
    /// still exist and be spawnable — only the effective model is overridden.
    private let modelOverride: String?

    /// Cap on the digest handed back to the parent.
    private static let digestMaxChars = 8_000

    // Resolved up front in `resolveModel`, read by permission/handoff/run.
    private var personaName: String = ""
    private var personaId: UUID?
    private var systemPrompt: String = ""
    private var budgets = SubagentBudgets()
    /// The residency plan resolved at `resolveModel` time (reject-before-evict),
    /// consumed by `makeHandoff()`. `.none` when no swap is needed.
    private var residencyPlan: ResidencyPlan = .none

    init(agentName: String, input: String, modelOverride: String? = nil) {
        self.agentName = agentName
        self.input = input
        self.modelOverride = modelOverride
    }

    var feedTitle: String { "spawn → \(agentName)" }

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        let config = SubagentConfigurationStore.snapshot()
        // Per-agent spawnable allow-list: the Default / main chat uses its own
        // pool (edited in the main chat's Sub-agents tab); a custom agent uses
        // its own list (its Sub-agents tab), resolved from the launching agent
        // (`scope`). There is no global master switch.
        let isDefault = scope.agentId == Agent.defaultId
        // One launching-agent lookup feeds the per-agent spawn allow-list,
        // permission, and budgets (Default / main chat → global config).
        let settings = await MainActor.run {
            AgentManager.shared.agent(for: scope.agentId)?.settings
        }
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
                isDefault
                    ? "Agent '\(agentName)' is not spawnable. Add it in the main chat's Sub-agents tab."
                    : "Agent '\(agentName)' is not spawnable from this agent. Add it in the agent's Sub-agents tab."
            )
        }
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

        let persona = await MainActor.run {
            AgentManager.shared.agents.first {
                $0.name.caseInsensitiveCompare(agentName) == .orderedSame
            }
        }
        guard let persona else {
            throw SubagentError.unavailable("Agent '\(agentName)' not found.")
        }

        self.personaName = persona.name
        self.personaId = persona.id
        self.systemPrompt = persona.systemPrompt
        self.budgets = SubagentToolVisibility.effectiveBudgets(
            isDefault: isDefault,
            config: config,
            settings: settings
        )

        // One shared path for precedence (eval seam → per-agent `spawn` override
        // → the persona's own model), the availability fallback, and the live
        // residency decision (reject-before-evict). The override is read from
        // the LAUNCHING agent (`scope.agentId`); the default is the persona's
        // configured model.
        let personaId = persona.id
        let resolved = try await SubagentModelResolution.resolve(
            capabilityId: capability.id,
            agentId: scope.agentId,
            evalModel: modelOverride,
            idleWaitSeconds: self.budgets.maxElapsedSeconds,
            deniedMessage:
                "Spawning a different local agent requires \"Local Orchestrator Handoff\" enabled "
                + "in Settings → Sub-agents (so the chat model can unload to make room).",
            unavailableMessage: "Agent '\(agentName)' has no model configured.",
            defaultModel: { AgentManager.shared.effectiveModel(for: personaId) }
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
        let sessionId = "spawn-\((personaId ?? UUID()).uuidString)-\(UUID().uuidString)"

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
                    message: "Subagent '\(agentName)' finished without producing a result.",
                    retryable: true
                )
            }
            let capped =
                digest.count > Self.digestMaxChars
                ? String(digest.prefix(Self.digestMaxChars)) + "\n[digest truncated]"
                : digest
            return SubagentResult(
                payload: [
                    "kind": "spawn_result",
                    "agent": personaName,
                    "model": resolved.name,
                    "summary": capped,
                    "iterations": result.iterations,
                    "elapsed_seconds": elapsed,
                    "handoff": residencyPlan.shouldUnload,
                ] as [String: Any],
                summary: capped
            )
        case .cancelled:
            throw SubagentError.timedOut(
                "Subagent '\(agentName)' hit its \(budgets.maxElapsedSeconds)s time budget."
            )
        case .iterationCapReached:
            throw SubagentError.iterationCap(
                "Subagent '\(agentName)' used all \(budgets.maxDelegateTurns) turns without a result."
            )
        case .toolRejected:
            throw SubagentError.toolRejected(
                "Subagent '\(agentName)' attempted unavailable child tool use."
            )
        case .overBudget:
            throw SubagentError.overBudget(
                "Subagent '\(agentName)' exceeded its context budget. Pass shorter input."
            )
        case .emptyResponseExhausted:
            throw SubagentError.emptyExhausted(
                "Subagent '\(agentName)' returned empty output after tool execution; the task may be incomplete."
            )
        }
    }

    private func seedMessages(systemPrompt: String, input: String) -> [ChatMessage] {
        var msgs: [ChatMessage] = []
        let sys = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty { msgs.append(ChatMessage(role: "system", content: sys)) }
        msgs.append(ChatMessage(role: "user", content: input))
        return msgs
    }
}
