//
//  SandboxReduceTool.swift
//  osaurus
//
//  `sandbox_reduce` — the reduction subagent from docs/REDUCTION_SUBAGENT.md,
//  built on the shared `AgentToolLoop` primitive. "Read a lot, return a
//  little": the tool spawns a nested, context-isolated tool loop with a
//  read/search/exec-only allowlist and hands ONLY the child's final digest
//  back to the parent turn. Raw tool output never crosses into the parent
//  context, which is the whole point on small-window local models.
//
//  Guardrails:
//  - Allowlist: `sandbox_read_file`, `sandbox_search_files`, `sandbox_exec`.
//    Everything else — loop tools, `dispatch`, plugins/MCP, and
//    `sandbox_reduce` itself (no recursion) — is invisible to the child and
//    refused at execution time as defense in depth.
//  - Caps: own iteration budget (default 8, hard cap 12), wall-clock
//    deadline, and `sandbox_exec` calls count against the SAME
//    `SandboxExecLimiter` budget as the parent (same agent name), so a
//    child can't escape the per-turn command ceiling.
//  - Cancellation: the child loop probes `Task.isCancelled`, so a parent
//    [Stop]/[Terminate] that cancels the tool task stops the child at the
//    next boundary.
//  - Context isolation: fresh minimal seed (system + task) and an ephemeral
//    child session id — never the parent transcript.
//

import Foundation

// MARK: - Recursion guard

/// TaskLocal flag marking "we are inside a sandbox_reduce child loop".
/// Bound around every child tool execution; `SandboxReduceTool.execute`
/// refuses to start when it's set, so a child can never spawn another child.
enum SandboxReduceContext {
    @TaskLocal static var isActive: Bool = false
}

// MARK: - sandbox_reduce

struct SandboxReduceTool: OsaurusTool, @unchecked Sendable {
    let name = "sandbox_reduce"
    let description =
        "Delegate a read-heavy investigation to a context-isolated subagent and get back ONLY a "
        + "short digest. Use when the raw bytes would flood your context: scanning logs for the "
        + "few relevant errors, walking a directory tree to summarize structure, extracting one "
        + "fact from many files. The subagent can read files, search, and run shell commands in "
        + "the sandbox, then distills what it found; raw file contents never enter your context. "
        + "NOT for writes/edits — it is read-only by design. Example: `{\"task\": \"Scan logs/*.log "
        + "for ERROR lines from the last run and summarize the distinct failure causes\"}`."

    let agentId: String
    let agentName: String
    let home: String

    /// The nested loop runs multiple model + tool steps; the registry's
    /// per-tool wall clock would cut healthy reductions short. The tool
    /// enforces its own deadline instead (`wallClockSeconds`).
    var bypassRegistryTimeout: Bool { true }

    /// Child toolset: read/search/exec only. No loop tools, no dispatch,
    /// no plugins/MCP, no recursion.
    static let childToolAllowlist: [String] = [
        "sandbox_read_file", "sandbox_search_files", "sandbox_exec",
    ]

    /// Default and hard-cap iteration budgets for the child loop.
    static let defaultIterations = 8
    static let maxIterations = 12

    /// Wall-clock deadline for the whole reduction (checked at loop
    /// boundaries; individual `sandbox_exec` calls keep their own limits).
    static let wallClockSeconds: TimeInterval = 240

    /// Cap on the digest handed back to the parent.
    static let digestMaxChars = 8_000

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "task": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Natural-language reduction goal. Be specific about what to find and what "
                            + "the digest should contain."
                    ),
                ]),
                "paths": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string(
                        "Optional file/directory paths (relative to agent home or absolute in the "
                            + "sandbox) scoping where the subagent should look."
                    ),
                ]),
                "max_iterations": .object([
                    "type": .string("integer"),
                    "description": .string(
                        "Optional child loop budget (model steps), default \(Self.defaultIterations), "
                            + "max \(Self.maxIterations)."
                    ),
                ]),
            ]),
            "required": .array([.string("task")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        // No recursion: a reduce child cannot spawn another reduce child.
        if SandboxReduceContext.isActive {
            return ToolEnvelope.failure(
                kind: .rejected,
                message:
                    "sandbox_reduce cannot be called from inside a sandbox_reduce subagent. "
                    + "Finish the current reduction and return your digest.",
                tool: name,
                retryable: false
            )
        }

        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let taskReq = requireString(
            args,
            "task",
            expected: "a natural-language reduction goal, e.g. \"summarize the errors in logs/\"",
            tool: name
        )
        guard case .value(let task) = taskReq else { return taskReq.failureEnvelope ?? "" }
        let paths = coerceStringArray(args["paths"]) ?? []
        let iterations = min(
            max(coerceInt(args["max_iterations"]) ?? Self.defaultIterations, 1),
            Self.maxIterations
        )

        // Resolve the parent's model + the child toolset on the MainActor.
        let agentUUID = UUID(uuidString: agentId)
        let (modelId, toolSpecs): (String?, [Tool]) = await MainActor.run {
            let model =
                agentUUID.flatMap { AgentManager.shared.effectiveModel(for: $0) }
                ?? ChatConfigurationStore.load().defaultModel
            let specs = ToolRegistry.shared.specs(forTools: Self.childToolAllowlist)
            return (model, specs)
        }
        guard let modelId, !modelId.isEmpty else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "No model is configured for this agent, so the reduction subagent cannot run.",
                tool: name,
                retryable: false
            )
        }
        guard !toolSpecs.isEmpty else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message:
                    "Sandbox read tools aren't registered yet (container still starting?). "
                    + "Try again in a moment.",
                tool: name,
                retryable: true
            )
        }

        // Fresh minimal seed: system + task. The parent transcript is
        // deliberately NOT included.
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
        var messages: [ChatMessage] = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userTask),
        ]

        // Shared budget plumbing: same window resolution + reservations as
        // every other loop surface, with a run-scoped sticky watermark.
        let contextWindow = await AgentLoopBudget.resolveContextWindow(modelId: modelId)
        let toolTokens = await MainActor.run {
            ToolRegistry.shared.totalEstimatedTokens(for: toolSpecs)
        }
        let budgetManager = AgentLoopBudget.makeBudgetManager(
            contextWindow: contextWindow,
            systemPromptChars: systemPrompt.count,
            toolTokens: toolTokens,
            maxResponseTokens: nil
        )
        let watermark = CompactionWatermark()

        let engine = ChatEngine(source: .chatUI)
        let childSessionId = "reduce-\(UUID().uuidString)"
        let deadline = Date().addingTimeInterval(Self.wallClockSeconds)
        let allowlist = Set(Self.childToolAllowlist)
        var finalDigest: String?

        let hooks = AgentLoopHooks(
            isCancelled: {
                // Parent Stop/Terminate cancels the tool task; the deadline
                // covers runaway children.
                Task.isCancelled || Date() >= deadline
            },
            buildMessages: { notices in
                for notice in notices {
                    messages.append(ChatMessage(role: "user", content: notice))
                }
                return AgentLoopBudget.trimPreservingSystemPrefix(
                    messages,
                    with: budgetManager,
                    watermark: watermark
                )
            },
            modelStep: { effective, _ in
                var req = ChatCompletionRequest(
                    model: modelId,
                    messages: effective,
                    temperature: nil,
                    max_tokens: nil,
                    stream: false,
                    top_p: nil,
                    frequency_penalty: nil,
                    presence_penalty: nil,
                    stop: nil,
                    n: nil,
                    tools: toolSpecs,
                    tool_choice: nil,
                    session_id: childSessionId
                )
                req.samplingParametersAreImplicit = true
                let response = try await engine.completeChat(request: req)
                guard let choice = response.choices.first else {
                    // No choices — treat as an empty final answer; the
                    // digest fallback below reports the failure.
                    return .finalResponse
                }
                if let calls = choice.message.tool_calls, !calls.isEmpty {
                    messages.append(choice.message)
                    return .toolCalls(
                        calls.map {
                            ServiceToolInvocation(
                                toolName: $0.function.name,
                                jsonArguments: $0.function.arguments,
                                toolCallId: $0.id
                            )
                        }
                    )
                }
                finalDigest = choice.message.content
                return .finalResponse
            },
            onDedupedResult: { _, callId, held in
                messages.append(
                    ChatMessage(role: "tool", content: held, tool_calls: nil, tool_call_id: callId)
                )
            },
            executeTool: { inv, callId in
                // Defense in depth: the child only SEES the allowlist, but a
                // hallucinated name must not reach the full registry either.
                guard allowlist.contains(inv.toolName) else {
                    let envelope = ToolEnvelope.failure(
                        kind: .rejected,
                        message:
                            "Tool '\(inv.toolName)' is not available in this reduction subagent. "
                            + "Available: \(Self.childToolAllowlist.joined(separator: ", ")).",
                        tool: inv.toolName,
                        retryable: false
                    )
                    messages.append(
                        ChatMessage(role: "tool", content: envelope, tool_calls: nil, tool_call_id: callId)
                    )
                    return AgentLoopToolExecution(result: envelope)
                }
                let result: String
                do {
                    // Ephemeral child session id; `currentAgentId` stays
                    // inherited from the parent so sandbox routing and the
                    // exec limiter hit the same agent budget.
                    result = try await SandboxReduceContext.$isActive.withValue(true) {
                        try await ChatExecutionContext.$currentSessionId.withValue(childSessionId) {
                            try await ToolRegistry.shared.execute(
                                name: inv.toolName,
                                argumentsJSON: inv.jsonArguments
                            )
                        }
                    }
                } catch {
                    result = ToolEnvelope.fromError(error, tool: inv.toolName)
                }
                messages.append(
                    ChatMessage(role: "tool", content: result, tool_calls: nil, tool_call_id: callId)
                )
                return AgentLoopToolExecution(result: result, isError: ToolEnvelope.isError(result))
            }
        )

        let runResult: AgentToolLoop.RunResult
        do {
            runResult = try await AgentToolLoop.run(
                policy: AgentLoopPolicy(
                    maxIterations: iterations,
                    stopOnToolRejection: false,
                    dedupeNoticeEnabled: false
                ),
                state: AgentTaskState(),
                hooks: hooks
            )
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Reduction subagent failed: \(error.localizedDescription)",
                tool: name,
                retryable: true
            )
        }

        switch runResult.exit {
        case .finalResponse, .endedBySurface:
            let digest = (finalDigest ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !digest.isEmpty else {
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: "The reduction subagent finished without producing a digest.",
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
                    "kind": "digest",
                    "digest": capped,
                    "iterations": runResult.iterations,
                ]
            )
        case .cancelled:
            if Date() >= deadline {
                return ToolEnvelope.failure(
                    kind: .timeout,
                    message:
                        "Reduction subagent hit its \(Int(Self.wallClockSeconds))s wall-clock limit "
                        + "before finishing. Narrow the task or scope it with `paths`.",
                    tool: name,
                    retryable: true
                )
            }
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Reduction subagent was cancelled.",
                tool: name,
                retryable: false
            )
        case .iterationCapReached:
            return ToolEnvelope.failure(
                kind: .executionError,
                message:
                    "Reduction subagent used all \(iterations) iterations without converging on a "
                    + "digest. Narrow the task or raise `max_iterations` (cap \(Self.maxIterations)).",
                tool: name,
                retryable: true
            )
        case .toolRejected:
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Reduction subagent stopped after a tool failure.",
                tool: name,
                retryable: true
            )
        }
    }
}
