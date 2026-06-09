//
//  AgentLoopEvaluator.swift
//  osaurus
//
//  Public facade that drives the canonical `AgentToolLoop` for the
//  OsaurusEvals `agent_loop` domain. Unlike `CapabilityClaimsEvaluator`
//  (which probes capability *claims* with `executionMode: .none`), this
//  evaluator seeds a real host-folder workspace, composes with
//  `executionMode: .hostFolder(...)`, and drives the SAME loop driver the
//  chat/HTTP/plugin surfaces use — `AgentTaskState` dedupe, next-step
//  bias, iteration budget notices, and budget-managed compaction included
//  — so eval cases exercise the production harness end to end.
//

import Foundation

// MARK: - Public transcript

/// Decode-friendly record of one agent-loop eval run.
public struct AgentLoopTranscript: Sendable, Codable {
    /// One processed tool call, in model order across all iterations.
    public struct ToolInvocation: Sendable, Codable {
        public let name: String
        public let arguments: String
        /// First 300 chars of the result envelope — forensics, not scoring.
        public let resultPreview: String
        /// True when the loop's dedupe replayed a held result instead of
        /// re-executing (the duplicate-call-avoidance signal).
        public let wasDeduped: Bool

        public init(name: String, arguments: String, resultPreview: String, wasDeduped: Bool) {
            self.name = name
            self.arguments = arguments
            self.resultPreview = resultPreview
            self.wasDeduped = wasDeduped
        }
    }

    public let toolCalls: [ToolInvocation]
    /// The model's final assistant text (what rubric grading reads).
    public let finalText: String
    /// Iterations charged against the loop budget.
    public let iterations: Int
    /// `AgentToolLoop.Exit` as a string: `finalResponse`,
    /// `iterationCapReached`, `toolRejected`, `cancelled`, `endedBySurface`.
    public let exit: String
    /// First-turn system prompt (post-compose) for forensics.
    public let systemPrompt: String
    /// Names of the tool schemas sent to the model on the first
    /// iteration — forensics for "did the model even see this tool".
    public let toolSchemaNames: [String]
    /// Non-nil when the loop aborted (engine threw, model unroutable).
    public let error: String?

    public init(
        toolCalls: [ToolInvocation],
        finalText: String,
        iterations: Int,
        exit: String,
        systemPrompt: String,
        toolSchemaNames: [String],
        error: String?
    ) {
        self.toolCalls = toolCalls
        self.finalText = finalText
        self.iterations = iterations
        self.exit = exit
        self.systemPrompt = systemPrompt
        self.toolSchemaNames = toolSchemaNames
        self.error = error
    }
}

// MARK: - Evaluator

/// Entry point for the `agent_loop` behaviour evals. Main-actor-bound
/// because prompt composition, the tool registry, and folder tool
/// registration are.
@MainActor
public enum AgentLoopEvaluator {

    /// Run the canonical agent loop against a seeded `workspace` folder
    /// and return the transcript. Folder tools (`file_read`,
    /// `file_write`, `file_search`, `shell_run`, …) are registered for
    /// the workspace for the duration of the run and unregistered after.
    ///
    /// - Parameters:
    ///   - task: the user message seeding the run.
    ///   - workspace: host folder the agent operates on (fixture-seeded
    ///     temp directory in eval runs).
    ///   - maxIterations: loop budget (model steps).
    ///   - model: model id; defaults to the runner's `ModelOverride`.
    ///   - contextWindowOverride: when set, the budget manager is built
    ///     against this window instead of the model's real one — the
    ///     compaction-stress lever ("long tool outputs on a small window").
    public static func run(
        task: String,
        workspace: URL,
        agentId: UUID? = nil,
        maxIterations: Int = 10,
        model: String? = nil,
        contextWindowOverride: Int? = nil
    ) async -> AgentLoopTranscript {
        // The Default agent's schema is hard-restricted to the 8-tool
        // configure baseline (folder write tools enter only via
        // `capabilities_load`), which is not the surface these agentic
        // folder evals exercise. When the active agent is the Default
        // agent, run under an ephemeral non-default agent id so the
        // composed schema matches a regular chat agent working in a
        // folder (folder tools in, configure tools stripped).
        let activeId = AgentManager.shared.activeAgent.id
        let resolvedAgentId = agentId ?? (activeId == Agent.defaultId ? UUID() : activeId)
        let resolvedModel =
            model
            ?? ChatConfigurationStore.load().coreModelIdentifier
            ?? "foundation"
        let engine = ChatEngine()

        // Workspace context + folder tools, mirroring the chat path's
        // host-folder mode. Unregistered after the run so eval cases
        // can't leak tools into each other.
        let folderContext = await FolderContextService.shared.buildContext(from: workspace)
        FolderToolManager.shared.registerFolderTools(for: folderContext)
        defer { FolderToolManager.shared.unregisterFolderTools() }

        var history: [ChatMessage] = [ChatMessage(role: "user", content: task)]
        let composed = await SystemPromptComposer.composeChatContext(
            agentId: resolvedAgentId,
            executionMode: .hostFolder(folderContext),
            model: resolvedModel,
            query: task,
            messages: history,
            additionalToolNames: []
        )
        let systemPrompt = composed.prompt
        var toolSpecs = composed.tools

        // Shared loop budget wiring (same as chat/HTTP/plugin) with a
        // run-scoped sticky watermark.
        let contextWindow: Int
        if let contextWindowOverride {
            contextWindow = contextWindowOverride
        } else {
            contextWindow = await AgentLoopBudget.resolveContextWindow(modelId: resolvedModel)
        }
        let budgetManager = AgentLoopBudget.makeBudgetManager(
            contextWindow: contextWindow,
            systemPromptChars: systemPrompt.count,
            toolTokens: composed.toolTokens,
            maxResponseTokens: 2048
        )
        let watermark = CompactionWatermark()

        let sessionId = "agent-loop-eval-\(UUID().uuidString)"
        let state = AgentTaskState()
        var transcriptCalls: [AgentLoopTranscript.ToolInvocation] = []
        var finalText = ""
        // Set when a successful `complete` intercept ends the run; the
        // summary becomes the final answer (mirrors the chat surface,
        // where the summary renders as the completion banner).
        var completedViaTool = false

        let hooks = AgentLoopHooks(
            buildMessages: { notices in
                var msgs: [ChatMessage] = [ChatMessage(role: "system", content: systemPrompt)]
                msgs.append(contentsOf: history)
                for notice in notices {
                    msgs.append(ChatMessage(role: "user", content: notice))
                }
                return AgentLoopBudget.trimPreservingSystemPrefix(
                    msgs,
                    with: budgetManager,
                    watermark: watermark
                )
            },
            modelStep: { effective, _ in
                let request = ChatCompletionRequest(
                    model: resolvedModel,
                    messages: effective,
                    temperature: 0.0,
                    max_tokens: 2048,
                    stream: false,
                    top_p: nil,
                    frequency_penalty: nil,
                    presence_penalty: nil,
                    stop: nil,
                    n: nil,
                    tools: toolSpecs.isEmpty ? nil : toolSpecs,
                    tool_choice: toolSpecs.isEmpty ? nil : .auto,
                    session_id: nil
                )
                let response = try await engine.completeChat(request: request)
                guard let choice = response.choices.first else {
                    return .finalResponse
                }
                if let content = choice.message.content, !content.isEmpty {
                    finalText = content
                }
                guard let calls = choice.message.tool_calls, !calls.isEmpty else {
                    return .finalResponse
                }
                history.append(
                    ChatMessage(
                        role: "assistant",
                        content: choice.message.content,
                        tool_calls: calls,
                        tool_call_id: nil
                    )
                )
                return .toolCalls(
                    calls.map {
                        ServiceToolInvocation(
                            toolName: $0.function.name,
                            jsonArguments: $0.function.arguments,
                            toolCallId: $0.id
                        )
                    }
                )
            },
            onDedupedResult: { inv, callId, held in
                history.append(
                    ChatMessage(role: "tool", content: held, tool_calls: nil, tool_call_id: callId)
                )
                transcriptCalls.append(
                    .init(
                        name: inv.toolName,
                        arguments: inv.jsonArguments,
                        resultPreview: String(held.prefix(300)),
                        wasDeduped: true
                    )
                )
            },
            executeTool: { inv, callId in
                let result: String
                do {
                    // Auto-approve `.ask`-gated tools (e.g. `shell_run`):
                    // eval runs are headless against isolated temp
                    // workspaces, so the approval NSPanel would hang the
                    // run on a card nobody can click.
                    result = try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
                        try await ChatExecutionContext.$autoApproveToolPrompts.withValue(true) {
                            try await ToolRegistry.shared.execute(
                                name: inv.toolName,
                                argumentsJSON: inv.jsonArguments
                            )
                        }
                    }
                } catch {
                    result = ToolEnvelope.fromError(error, tool: inv.toolName)
                }
                history.append(
                    ChatMessage(role: "tool", content: result, tool_calls: nil, tool_call_id: callId)
                )
                transcriptCalls.append(
                    .init(
                        name: inv.toolName,
                        arguments: inv.jsonArguments,
                        resultPreview: String(result.prefix(300)),
                        wasDeduped: false
                    )
                )
                // Hot-load capability tools mid-run, like the chat loop.
                if inv.toolName == "capabilities_load" {
                    let drained = await CapabilityLoadBuffer.shared.drain()
                    for spec in drained
                    where !toolSpecs.contains(where: { $0.function.name == spec.function.name }) {
                        toolSpecs.append(spec)
                    }
                }
                // Agent-loop intercepts, mirroring the chat surface: a
                // successful `complete` ends the run and its summary is the
                // final answer; a successful `clarify` ends the run awaiting
                // user input (headless: no answer ever arrives). Error
                // envelopes fall through so the model can retry.
                if inv.toolName == "complete", !ToolEnvelope.isError(result) {
                    completedViaTool = true
                    if let summary = CompleteTool.parseSummary(from: inv.jsonArguments) {
                        finalText = summary
                    }
                    return AgentLoopToolExecution(result: result, endRun: true)
                }
                if inv.toolName == "clarify", !ToolEnvelope.isError(result) {
                    return AgentLoopToolExecution(result: result, endRun: true)
                }
                return AgentLoopToolExecution(
                    result: result,
                    isError: ToolEnvelope.isError(result)
                )
            }
        )

        do {
            let runResult = try await ChatExecutionContext.$currentAgentId.withValue(resolvedAgentId) {
                try await AgentToolLoop.run(
                    policy: AgentLoopPolicy(
                        maxIterations: maxIterations,
                        stopOnToolRejection: false,
                        dedupeNoticeEnabled: true
                    ),
                    state: state,
                    hooks: hooks
                )
            }
            // A run ended by a successful `complete` intercept IS the
            // model's final response (the summary), not a surface
            // interruption — report it as the happy-path exit so cases
            // score tool-completion and text-completion identically.
            let exitLabel: String
            if case .endedBySurface = runResult.exit, completedViaTool {
                exitLabel = "finalResponse"
            } else {
                exitLabel = Self.describe(runResult.exit)
            }
            return AgentLoopTranscript(
                toolCalls: transcriptCalls,
                finalText: finalText,
                iterations: runResult.iterations,
                exit: exitLabel,
                systemPrompt: systemPrompt,
                toolSchemaNames: composed.tools.map { $0.function.name },
                error: nil
            )
        } catch {
            return AgentLoopTranscript(
                toolCalls: transcriptCalls,
                finalText: finalText,
                iterations: 0,
                exit: "errored",
                systemPrompt: systemPrompt,
                toolSchemaNames: composed.tools.map { $0.function.name },
                error: error.localizedDescription
            )
        }
    }

    private static func describe(_ exit: AgentToolLoop.Exit) -> String {
        switch exit {
        case .finalResponse: return "finalResponse"
        case .endedBySurface: return "endedBySurface"
        case .toolRejected: return "toolRejected"
        case .iterationCapReached: return "iterationCapReached"
        case .cancelled: return "cancelled"
        }
    }
}
