//
//  SpawnTool.swift
//  osaurus
//
//  `spawn(agent, input)` — the portable subagent primitive. Resolves a
//  user-configured, spawnable Agent persona, runs a bounded text subagent on its
//  model (with the local-orchestrator residency handoff when needed), and returns
//  only a compact digest. Default OFF; per-agent opt-in via AgentDelegation
//  settings (`spawnableAgentNames`). See docs/SUBAGENT_PORTABLE_DESIGN.md.
//

import Foundation

public final class SpawnTool: OsaurusTool, @unchecked Sendable {
    public let name = "spawn"
    public let description =
        "Spawn a bounded subagent: hand a task to a user-configured agent persona by name and get back "
        + "only a compact result. Use to offload bounded text/coding/analysis subtasks to a local or "
        + "remote model the user has marked spawnable. The subagent transcript is not returned."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "agent": .object([
                "type": .string("string"),
                "description": .string("Name of a spawnable agent persona (e.g. \"sparky\")."),
            ]),
            "input": .object([
                "type": .string("string"),
                "description": .string("The task/query for the subagent."),
            ]),
        ]),
        "required": .array([.string("agent"), .string("input")]),
    ])

    public var bypassRegistryTimeout: Bool { true }

    private static let digestMaxChars = 8_000

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        if LocalTextDelegateContext.isActive {
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "spawn cannot be called from inside a spawned subagent.",
                tool: name,
                retryable: false
            )
        }

        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let agentReq = requireString(args, "agent", expected: "a spawnable agent name", tool: name)
        guard case .value(let agentName) = agentReq else { return agentReq.failureEnvelope ?? "" }
        let inputReq = requireString(args, "input", expected: "the task for the subagent", tool: name)
        guard case .value(let input) = inputReq else { return inputReq.failureEnvelope ?? "" }

        let config = AgentDelegationConfigurationStore.snapshot()
        guard config.isAgentSpawnable(agentName) else {
            return ToolEnvelope.failure(
                kind: .rejected,
                message:
                    "Agent '\(agentName)' is not spawnable. Mark it spawnable in Agent Delegation settings.",
                tool: name,
                retryable: false
            )
        }
        if config.permissionDefaults.localTextDelegate == .deny {
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "Spawning is denied by Agent Delegation permission settings.",
                tool: name,
                retryable: false
            )
        }

        guard let persona = await MainActor.run(body: {
            AgentManager.shared.agents.first { $0.name.caseInsensitiveCompare(agentName) == .orderedSame }
        }) else {
            return ToolEnvelope.failure(
                kind: .unavailable, message: "Agent '\(agentName)' not found.", tool: name, retryable: false)
        }
        guard let modelName = await MainActor.run(body: {
            AgentManager.shared.effectiveModel(for: persona.id)
        }), !modelName.isEmpty else {
            return ToolEnvelope.failure(
                kind: .unavailable, message: "Agent '\(agentName)' has no model configured.", tool: name,
                retryable: false)
        }

        let isLocalModel = ModelManager.findInstalledModel(named: modelName) != nil
        let orchestratorModel = await parentChatModel()
        let orchestratorIsLocal =
            orchestratorModel.flatMap { ModelManager.findInstalledModel(named: $0) } != nil
        let sameAsOrchestrator =
            orchestratorModel?.caseInsensitiveCompare(modelName) == .orderedSame

        // Residency handoff: only when swapping between two DIFFERENT local models.
        var lease = ChatResidencyLease.empty
        let needsHandoff = isLocalModel && orchestratorIsLocal && !sameAsOrchestrator
        if needsHandoff {
            guard config.localOrchestratorTextHandoffActive else {
                return ToolEnvelope.failure(
                    kind: .rejected,
                    message:
                        "Spawning a different local agent requires \"Local Orchestrator Handoff\" enabled "
                        + "in Agent Delegation settings (so the chat model can unload to make room).",
                    tool: name,
                    retryable: false
                )
            }
            do {
                lease = try await ChatResidencyHandoff.unloadResidentChatModels(
                    maxElapsedSeconds: config.budgets.maxElapsedSeconds)
            } catch {
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: "Subagent memory handoff failed: \(error.localizedDescription)",
                    tool: name,
                    retryable: true
                )
            }
        }

        let budgets = config.budgets.normalized
        let deadline = Date().addingTimeInterval(TimeInterval(budgets.maxElapsedSeconds))
        let started = Date()
        let seed = seedMessages(systemPrompt: persona.systemPrompt, input: input)
        let sessionId = "spawn-\(persona.id.uuidString)-\(UUID().uuidString)"

        let result: AgentSubagentRunResult
        do {
            result = try await AgentSubagentRunner.run(
                modelName: modelName,
                seedMessages: seed,
                maxTokens: budgets.maxDelegateTokens,
                maxIterations: budgets.maxDelegateTurns,
                deadline: deadline,
                sessionId: sessionId
            )
        } catch {
            try? await ChatResidencyHandoff.restore(lease)
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Subagent '\(agentName)' failed: \(error.localizedDescription)",
                tool: name,
                retryable: true
            )
        }
        try? await ChatResidencyHandoff.restore(lease)
        let elapsed = Date().timeIntervalSince(started)

        switch result.exit {
        case .finalResponse, .endedBySurface:
            let digest = (result.digest ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !digest.isEmpty else {
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: "Subagent '\(agentName)' finished without producing a result.",
                    tool: name,
                    retryable: true
                )
            }
            let capped =
                digest.count > Self.digestMaxChars
                ? String(digest.prefix(Self.digestMaxChars)) + "\n[digest truncated]"
                : digest
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "kind": "spawn_result",
                    "agent": persona.name,
                    "model": modelName,
                    "summary": capped,
                    "iterations": result.iterations,
                    "elapsed_seconds": elapsed,
                    "handoff": needsHandoff,
                ] as [String: Any]
            )
        case .cancelled:
            return ToolEnvelope.failure(
                kind: .timeout,
                message: "Subagent '\(agentName)' hit its \(budgets.maxElapsedSeconds)s time budget.",
                tool: name,
                retryable: true
            )
        case .iterationCapReached:
            return ToolEnvelope.failure(
                kind: .executionError,
                message:
                    "Subagent '\(agentName)' used all \(budgets.maxDelegateTurns) turns without a result.",
                tool: name,
                retryable: true
            )
        case .toolRejected:
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "Subagent '\(agentName)' attempted unavailable child tool use.",
                tool: name,
                retryable: false
            )
        case .overBudget:
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Subagent '\(agentName)' exceeded its context budget. Pass shorter input.",
                tool: name,
                retryable: true
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

    private func parentChatModel() async -> String? {
        await MainActor.run {
            let agentId = AgentManager.shared.activeAgentId
            return AgentManager.shared.effectiveModel(for: agentId) ?? ChatConfigurationStore.load().defaultModel
        }
    }
}
