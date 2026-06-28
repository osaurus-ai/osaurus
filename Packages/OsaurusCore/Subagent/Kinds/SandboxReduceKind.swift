//
//  SandboxReduceKind.swift
//  OsaurusCore — Subagent framework
//
//  The reduction sub-agent kind that serves `sandbox_reduce`: a
//  context-isolated child loop with a read/search/exec-only allowlist that
//  hands back ONLY a short digest (raw tool output never crosses into the
//  parent context). Runs on the SAME shared runner (`AgentSubagentRunner`) and
//  host (`SubagentSession`) as `spawn`, so the recursion guard, live feed, and
//  compact-result contract are shared. `modelSource = .inheritsParent` is the
//  DEFAULT source (the parent agent's model); a per-agent `sandbox_reduce` model
//  override (the standard model-pick axis) supersedes it. When the resolved
//  model is a DIFFERENT local bundle than the resident chat model, `makeHandoff()`
//  vends a `ResidencyHandoff` via the shared `SubagentResidency` layer; otherwise
//  it stays passthrough.
//
//  Guardrails preserved from the standalone tool: the read/search/exec
//  allowlist (enforced in the executor as defense in depth), the child loop's
//  own iteration + wall-clock budgets, exec calls billed to the SAME agent
//  budget, fresh minimal seed (system + task) with an ephemeral child session
//  id, and cooperative cancellation via the host interrupt + `Task.isCancelled`.
//

import Foundation

final class SandboxReduceKind: SubagentKind, @unchecked Sendable {
    let capability = SubagentCapabilityRegistry.sandboxReduce

    private let agentId: String
    private let task: String
    private let paths: [String]
    private let iterations: Int
    /// Eval seam (nil in production): force the run model so the lane varies
    /// across the local-vs-frontier matrix. Production inherits the parent
    /// agent's model via `AgentManager.effectiveModel`.
    private let modelOverride: String?

    /// The child tool allow-list resolved in `resolveModel`, read by `run`.
    private var toolSpecs: [Tool] = []
    /// Residency plan resolved in `resolveModel` (reject-before-evict), run by
    /// `makeHandoff()`. `.none` when no swap is needed.
    private var residencyPlan: ResidencyPlan = .none

    init(
        agentId: String,
        task: String,
        paths: [String],
        iterations: Int,
        modelOverride: String? = nil
    ) {
        self.agentId = agentId
        self.task = task
        self.paths = paths
        self.iterations = iterations
        self.modelOverride = modelOverride
    }

    var feedTitle: String {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
    }

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        let agentUUID = UUID(uuidString: agentId)
        // Resolve the child tool allow-list before touching the model so an
        // infra gap (container still starting) fails fast, before any residency
        // planning.
        let specs: [Tool] = await MainActor.run {
            ToolRegistry.shared.specs(forTools: SandboxReduceTool.childToolAllowlist)
        }
        guard !specs.isEmpty else {
            throw SubagentError.executionFailed(
                message:
                    "Sandbox read tools aren't registered yet (container still starting?). "
                    + "Try again in a moment.",
                retryable: true
            )
        }
        self.toolSpecs = specs

        // One shared path for precedence (eval seam → per-agent `sandbox_reduce`
        // override → the parent agent's model → the global chat default), the
        // availability fallback, and the live residency decision
        // (reject-before-evict; a remote override / the inherited model needs no
        // swap, the eval seam stays passthrough).
        let resolved = try await SubagentModelResolution.resolve(
            capabilityId: capability.id,
            agentId: agentUUID,
            evalModel: modelOverride,
            idleWaitSeconds: Int(SandboxReduceTool.wallClockSeconds),
            deniedMessage:
                "Running the reduction subagent on a different local model requires \"Local "
                + "Orchestrator Handoff\" enabled in Settings → Sub-agents (so the chat model "
                + "can unload to make room).",
            unavailableMessage:
                "No model is configured for this agent, so the reduction subagent cannot run.",
            defaultModel: {
                agentUUID.flatMap { AgentManager.shared.effectiveModel(for: $0) }
                    ?? ChatConfigurationStore.load().defaultModel
            }
        )
        self.residencyPlan = resolved.decision.plan
        return ResolvedModel(name: resolved.model, id: nil, isLocal: resolved.decision.isLocal)
    }

    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
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
        let systemPrompt =
            "You are a reduction subagent inside a sandboxed Linux container. "
            + "Your ONLY job: investigate using the available tools, then reply with a short, "
            + "information-dense digest answering the task. Rules: "
            + "1) Use tools to gather evidence; prefer `sandbox_search_files` and targeted "
            + "`sandbox_read_file` ranges over full-file reads. "
            + "2) NEVER paste large raw file contents into your reply — distill. "
            + "3) When you have enough evidence, reply with the digest as plain text "
            + "(no tool call). Include concrete specifics: paths, line numbers, counts, exact "
            + "error strings. "
            + "4) If the task cannot be completed, say exactly what you tried and what is missing. "
            + "Keep the final digest under ~300 words."
        var userTask = "Task: \(task)"
        if !paths.isEmpty {
            userTask += "\nScope: look in \(paths.joined(separator: ", "))"
        }
        let seed: [ChatMessage] = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userTask),
        ]

        let childSessionId = "reduce-\(UUID().uuidString)"
        let deadline = Date().addingTimeInterval(SandboxReduceTool.wallClockSeconds)
        let allowlist = Set(SandboxReduceTool.childToolAllowlist)
        let toolset = AgentSubagentToolset(specs: toolSpecs) { invocation in
            // Defense in depth: the child only SEES the allowlist, but a
            // hallucinated name must not reach the full registry either.
            guard allowlist.contains(invocation.toolName) else {
                return ToolEnvelope.failure(
                    kind: .rejected,
                    message:
                        "Tool '\(invocation.toolName)' is not available in this reduction subagent. "
                        + "Available: \(SandboxReduceTool.childToolAllowlist.joined(separator: ", ")).",
                    tool: invocation.toolName,
                    retryable: false
                )
            }
            do {
                return try await ToolRegistry.shared.execute(
                    name: invocation.toolName,
                    argumentsJSON: invocation.jsonArguments
                )
            } catch {
                return ToolEnvelope.fromError(error, tool: invocation.toolName)
            }
        }

        let result = try await AgentSubagentRunner.run(
            modelName: resolved.name,
            seedMessages: seed,
            maxTokens: nil,
            maxIterations: iterations,
            deadline: deadline,
            sessionId: childSessionId,
            isAgentRequest: false,
            stopOnToolRejection: false,
            treatEmptyChoicesAsFinal: true,
            isInterrupted: { interrupt.isInterrupted },
            toolset: toolset
        )

        switch result.exit {
        case .finalResponse, .endedBySurface:
            let digest = (result.digest ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !digest.isEmpty else {
                throw SubagentError.executionFailed(
                    message: "The reduction subagent finished without producing a digest.",
                    retryable: true
                )
            }
            let capped =
                digest.count > SandboxReduceTool.digestMaxChars
                ? String(digest.prefix(SandboxReduceTool.digestMaxChars)) + "\n[digest truncated]"
                : digest
            return SubagentResult(
                payload: [
                    "kind": "digest",
                    "model": resolved.name,
                    "digest": capped,
                    "iterations": result.iterations,
                ] as [String: Any],
                summary: capped
            )
        case .cancelled:
            if Date() >= deadline {
                throw SubagentError.timedOut(
                    "Reduction subagent hit its \(Int(SandboxReduceTool.wallClockSeconds))s wall-clock limit "
                        + "before finishing. Narrow the task or scope it with `paths`."
                )
            }
            throw SubagentError.executionFailed(
                message: "Reduction subagent was cancelled.",
                retryable: false
            )
        case .iterationCapReached:
            throw SubagentError.iterationCap(
                "Reduction subagent used all \(iterations) iterations without converging on a "
                    + "digest. Narrow the task or raise `max_iterations` (cap \(SandboxReduceTool.maxIterations))."
            )
        case .toolRejected:
            throw SubagentError.executionFailed(
                message: "Reduction subagent stopped after a tool failure.",
                retryable: true
            )
        case .overBudget:
            throw SubagentError.overBudget(
                "Reduction subagent overflowed its context window even after compaction. "
                    + "Narrow the task or scope it with `paths`."
            )
        case .emptyResponseExhausted:
            throw SubagentError.emptyExhausted(AgentToolLoop.emptyToolTaskFallback)
        }
    }
}
