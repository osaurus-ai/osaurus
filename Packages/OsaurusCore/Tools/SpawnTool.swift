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

        // Decide the residency handoff from ACTUAL GPU residency, not from a
        // best-effort name lookup of the orchestrator. Running a second local
        // model's GPU work (weight load/convert/generate) while ANOTHER chat
        // model is still resident races on MLX's shared Metal command stream —
        // the resident model's KV-cache disk store (`save_safetensors`) vs the
        // subagent load's compute encoder — and SIGABRTs ("A command encoder is
        // already encoding to this command buffer"). That is the model-churn
        // disk-store edge. The old `parentChatModel()` name lookup returned nil
        // on the `/agents/{id}/run` path (no active-agent default model), so
        // `needsHandoff` was false and the subagent loaded concurrently with the
        // still-resident orchestrator → crash. Gate on residency instead: if the
        // subagent is local and ANY other chat model is resident, unload it first
        // (single-residency handoff) so only one model touches the GPU at a time.
        var lease = ChatResidencyLease.empty
        let residentChatModels = await ModelRuntime.shared.cachedModelSummaries().map(\.name)
        let otherResidentModels = residentChatModels.filter {
            $0.caseInsensitiveCompare(modelName) != .orderedSame
        }
        let needsHandoff = isLocalModel && !otherResidentModels.isEmpty
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
                // RAM-safety preflight: refuse before evicting the orchestrator if
                // the spawned agent's model would not fit once it is freed.
                try await ChatResidencyHandoff.memoryPreflight(
                    requiredBytes: ChatResidencyHandoff.estimatedChatModelBytes(named: modelName),
                    enabled: config.ramSafetyPreflightEnabled)
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
            await ChatResidencyHandoff.restoreBestEffort(lease)
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Subagent '\(agentName)' failed: \(error.localizedDescription)",
                tool: name,
                retryable: true
            )
        }
        // Best-effort (logs on failure) rather than a bare `try?` so a reload
        // failure on the success path can't silently strand the chat model
        // unloaded with no diagnostic.
        _ = await ChatResidencyHandoff.restoreBestEffort(lease)
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
        case .emptyResponseExhausted:
            return ToolEnvelope.failure(
                kind: .executionError,
                message:
                    "Subagent '\(agentName)' returned empty output after tool execution; the task may be incomplete.",
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
}
