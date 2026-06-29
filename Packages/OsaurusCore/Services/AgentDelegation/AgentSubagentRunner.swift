//
//  AgentSubagentRunner.swift
//  osaurus
//
//  Shared bounded runner for the text subagent KINDs: a context-isolated
//  `AgentToolLoop` on a chosen model that returns a compact digest only (the
//  orchestrator never sees the transcript). Serves `spawn` (text-only, no child
//  tools); the optional child toolset hook remains for future tool-capable
//  kinds. The host (`SubagentSession`) owns the recursion guard, feed,
//  permission, and residency handoff; this owns only the loop + digest.
//

import Foundation

struct AgentSubagentRunResult: Sendable {
    var digest: String?
    var exit: AgentToolLoop.Exit
    var iterations: Int
}

/// Optional child toolset for a subagent run. When `nil`, the run is text-only
/// (every tool call is refused). When present, the child sees `specs` and the
/// runner dispatches allowed calls through `execute` (the kind enforces its own
/// allowlist + error conversion inside `execute`).
struct AgentSubagentToolset: Sendable {
    var specs: [Tool]
    /// Execute one child tool call and return the result envelope. The kind
    /// owns the allowlist check, dispatch, and error→envelope conversion; the
    /// runner owns message bookkeeping and child-session scoping.
    var execute: @Sendable (_ invocation: ServiceToolInvocation) async -> String
}

enum AgentSubagentRunner {
    /// Run a bounded subagent loop. The caller (kind) owns model resolution,
    /// permission, the residency handoff, and result mapping; this owns the
    /// loop, message bookkeeping, and digest capture.
    static func run(
        modelName: String,
        seedMessages: [ChatMessage],
        maxTokens: Int?,
        maxIterations: Int,
        deadline: Date,
        sessionId: String,
        isAgentRequest: Bool = true,
        stopOnToolRejection: Bool = true,
        treatEmptyChoicesAsFinal: Bool = false,
        isInterrupted: @escaping @Sendable () -> Bool = { false },
        toolset: AgentSubagentToolset? = nil
    ) async throws -> AgentSubagentRunResult {
        var messages = seedMessages
        var finalDigest: String?

        let contextWindow = await AgentLoopBudget.resolveContextWindow(modelId: modelName)
        let toolTokens: Int
        if let set = toolset {
            toolTokens = await MainActor.run { ToolRegistry.shared.totalEstimatedTokens(for: set.specs) }
        } else {
            toolTokens = 0
        }
        let budgetManager = AgentLoopBudget.makeBudgetManager(
            contextWindow: contextWindow,
            systemPromptChars: messages.first?.content?.count ?? 0,
            toolTokens: toolTokens,
            maxResponseTokens: maxTokens
        )
        let watermark = CompactionWatermark()
        let engine = ChatEngine(source: .chatUI)

        let hooks = AgentLoopHooks(
            isCancelled: {
                Task.isCancelled || Date() >= deadline || isInterrupted()
            },
            buildMessages: { notices in
                for notice in notices {
                    messages.append(ChatMessage(role: "user", content: notice))
                }
                return AgentLoopBudget.composeIterationMessages(
                    messages,
                    notices: [],
                    manager: budgetManager,
                    watermark: watermark
                )
            },
            modelStep: { effective, _ in
                var request = ChatCompletionRequest(
                    model: modelName,
                    messages: effective,
                    temperature: nil,
                    max_tokens: maxTokens,
                    stream: false,
                    top_p: nil,
                    frequency_penalty: nil,
                    presence_penalty: nil,
                    stop: nil,
                    n: nil,
                    tools: toolset?.specs,
                    tool_choice: nil,
                    session_id: sessionId
                )
                request.samplingParametersAreImplicit = true
                request.isAgentRequest = isAgentRequest
                let response = try await engine.completeChat(request: request)
                guard let choice = response.choices.first else {
                    return treatEmptyChoicesAsFinal ? .finalResponse : .emptyResponse
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
                // Only fires when a child tool call short-circuits (tool kinds);
                // text-only spawn never reaches here.
                messages.append(
                    ChatMessage(role: "tool", content: held, tool_calls: nil, tool_call_id: callId)
                )
            },
            executeTool: { invocation, callId in
                guard let toolset else {
                    // Text-only: every tool call is refused.
                    let envelope = ToolEnvelope.failure(
                        kind: .rejected,
                        message:
                            "Tool '\(invocation.toolName)' is not available inside a spawned subagent. "
                            + "Subagent jobs are text-only.",
                        tool: invocation.toolName,
                        retryable: false
                    )
                    messages.append(
                        ChatMessage(
                            role: "tool",
                            content: envelope,
                            tool_calls: nil,
                            tool_call_id: callId
                        )
                    )
                    return AgentLoopToolExecution(result: envelope, isError: true)
                }
                // Ephemeral child session id; `currentAgentId` stays inherited
                // from the parent so sandbox routing + the exec limiter hit the
                // same agent budget.
                let result = await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
                    await toolset.execute(invocation)
                }
                messages.append(
                    ChatMessage(
                        role: "tool",
                        content: result,
                        tool_calls: nil,
                        tool_call_id: callId
                    )
                )
                return AgentLoopToolExecution(
                    result: result,
                    isError: ToolEnvelope.isError(result)
                )
            }
        )

        let runResult = try await AgentToolLoop.run(
            policy: AgentLoopPolicy(
                maxIterations: maxIterations,
                stopOnToolRejection: stopOnToolRejection,
                dedupeNoticeEnabled: false
            ),
            state: AgentTaskState(),
            hooks: hooks
        )
        return AgentSubagentRunResult(
            digest: finalDigest,
            exit: runResult.exit,
            iterations: runResult.iterations
        )
    }
}
