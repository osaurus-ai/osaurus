//
//  AgentSubagentRunner.swift
//  osaurus
//
//  Shared bounded runner for the text/coding subagent KIND of `spawn`: a
//  context-isolated `AgentToolLoop` on a chosen model that returns a compact
//  digest only (the orchestrator never sees the transcript). Text-only — no
//  nested tool execution in v1. Both the `spawn` tool (over Agent personas) and
//  the `local_delegate` tool drive this same runner.
//

import Foundation

struct AgentSubagentRunResult: Sendable {
    var digest: String?
    var exit: AgentToolLoop.Exit
    var iterations: Int
}

enum AgentSubagentRunner {
    /// Run a bounded text subagent. The caller owns model resolution, permission,
    /// and the residency handoff; this owns only the loop + digest.
    static func run(
        modelName: String,
        seedMessages: [ChatMessage],
        maxTokens: Int,
        maxIterations: Int,
        deadline: Date,
        sessionId: String
    ) async throws -> AgentSubagentRunResult {
        var messages = seedMessages
        var finalDigest: String?

        let contextWindow = await AgentLoopBudget.resolveContextWindow(modelId: modelName)
        let budgetManager = AgentLoopBudget.makeBudgetManager(
            contextWindow: contextWindow,
            systemPromptChars: messages.first?.content?.count ?? 0,
            toolTokens: 0,
            maxResponseTokens: maxTokens
        )
        let watermark = CompactionWatermark()
        let engine = ChatEngine(source: .chatUI)

        let hooks = AgentLoopHooks(
            isCancelled: {
                Task.isCancelled || Date() >= deadline
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
                    tools: nil,
                    tool_choice: nil,
                    session_id: sessionId
                )
                request.samplingParametersAreImplicit = true
                request.isAgentRequest = true
                let response = try await LocalTextDelegateContext.$isActive.withValue(true) {
                    try await engine.completeChat(request: request)
                }
                guard let choice = response.choices.first else {
                    return .emptyResponse
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
            executeTool: { invocation, callId in
                let envelope = ToolEnvelope.failure(
                    kind: .rejected,
                    message:
                        "Tool '\(invocation.toolName)' is not available inside a spawned subagent. "
                        + "Subagent jobs are text-only.",
                    tool: invocation.toolName,
                    retryable: false
                )
                messages.append(ChatMessage(role: "tool", content: envelope, tool_calls: nil, tool_call_id: callId))
                return AgentLoopToolExecution(result: envelope, isError: true)
            }
        )

        let runResult = try await AgentToolLoop.run(
            policy: AgentLoopPolicy(
                maxIterations: maxIterations,
                stopOnToolRejection: true,
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
