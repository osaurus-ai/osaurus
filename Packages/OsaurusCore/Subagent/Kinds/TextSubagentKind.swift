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
//  `needsHandoff = true`: when the persona's model is local and a DIFFERENT
//  chat model is resident, the host's `ResidencyHandoff` unloads the
//  orchestrator (single GPU residency) and reloads it after the run. The
//  reject-before-evict policy gates (not spawnable, permission denied, handoff
//  disabled) are resolved up front so nothing is evicted before we know the run
//  can proceed.
//

import Foundation

final class TextSubagentKind: SubagentKind, @unchecked Sendable {
    let capability = AgentCapability(id: "spawn", toolNames: ["spawn"], guidance: nil)
    let needsHandoff = true

    private let agentName: String
    private let input: String

    /// Cap on the digest handed back to the parent.
    private static let digestMaxChars = 8_000

    // Resolved up front in `resolveModel`, read by permission/handoff/run.
    private var personaName: String = ""
    private var personaId: UUID?
    private var systemPrompt: String = ""
    private var budgets = SubagentBudgets()
    private var residencyShouldUnload = false
    private var residencyRequiredBytes: Int64 = 0
    private var ramSafetyEnabled = false
    private var handoffMaxElapsedSeconds = 120

    init(agentName: String, input: String) {
        self.agentName = agentName
        self.input = input
    }

    var feedTitle: String { "spawn → \(agentName)" }

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        let config = SubagentConfigurationStore.snapshot()
        guard config.isAgentSpawnable(agentName) else {
            throw SubagentError.denied(
                "Agent '\(agentName)' is not spawnable. Mark it spawnable in Agent Delegation settings."
            )
        }
        if config.permissionDefaults.spawn == .deny {
            throw SubagentError.denied(
                "Spawning is denied by Agent Delegation permission settings."
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
        let modelName = await MainActor.run {
            AgentManager.shared.effectiveModel(for: persona.id)
        }
        guard let modelName, !modelName.isEmpty else {
            throw SubagentError.unavailable("Agent '\(agentName)' has no model configured.")
        }

        self.personaName = persona.name
        self.personaId = persona.id
        self.systemPrompt = persona.systemPrompt
        self.budgets = config.budgets

        // Decide the residency handoff from ACTUAL GPU residency (not a
        // best-effort orchestrator name lookup): if the spawn model is local
        // and ANY other chat model is resident, unload it first so only one
        // model touches the GPU at a time (avoids the MLX shared-command-stream
        // SIGABRT). Reject-before-evict: require the handoff to be enabled here,
        // before anything is unloaded.
        let isLocalModel = ModelManager.findInstalledModel(named: modelName) != nil
        let residentChatModels = await ModelRuntime.shared.cachedModelSummaries().map(\.name)
        let otherResidentModels = residentChatModels.filter {
            $0.caseInsensitiveCompare(modelName) != .orderedSame
        }
        if isLocalModel && !otherResidentModels.isEmpty {
            guard config.localOrchestratorTextHandoffActive else {
                throw SubagentError.denied(
                    "Spawning a different local agent requires \"Local Orchestrator Handoff\" enabled "
                        + "in Agent Delegation settings (so the chat model can unload to make room)."
                )
            }
            self.residencyShouldUnload = true
            self.residencyRequiredBytes = ChatResidencyHandoff.estimatedChatModelBytes(named: modelName)
            self.ramSafetyEnabled = config.ramSafetyPreflightEnabled
            self.handoffMaxElapsedSeconds = config.budgets.maxElapsedSeconds
        }

        return ResolvedModel(name: modelName, id: nil, isLocal: isLocalModel)
    }

    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
        // All policy gates are resolved up front in `resolveModel`
        // (reject-before-evict); spawn has no interactive prompt.
        .allow
    }

    func makeHandoff() -> SubagentHandoff {
        guard residencyShouldUnload else { return PassthroughHandoff() }
        let plan = ResidencyPlan(
            shouldUnload: true,
            requiredBytes: residencyRequiredBytes,
            ramSafetyEnabled: ramSafetyEnabled,
            maxElapsedSeconds: handoffMaxElapsedSeconds
        )
        return ResidencyHandoff.production { _ in plan }
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
                    "handoff": residencyShouldUnload,
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
