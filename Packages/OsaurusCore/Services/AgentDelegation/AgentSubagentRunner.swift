//
//  AgentSubagentRunner.swift
//  osaurus
//
//  Shared bounded runner for the text subagent KINDs: a context-isolated
//  `AgentToolLoop` on a chosen model that returns a compact digest only (the
//  orchestrator never sees the transcript). Serves `spawn` (optionally with a
//  curated child toolset — see `AgentSubagentToolset`). The host
//  (`SubagentSession`) owns the recursion guard, feed, permission, and
//  residency handoff; this owns only the loop + digest.
//
//  The model step STREAMS (`ChatEngine.streamChat`) instead of buffering a
//  completion, which buys three things at once:
//    - live token progress for the subagent feed (`onProgress`),
//    - chunk-granular cancellation (user interrupt / deadline / parent task
//      cancel take effect mid-generation, not at iteration boundaries), and
//    - authoritative usage capture from the terminal stats sentinel
//      (`StreamingStatsHint`) with an estimator fallback for remote providers.
//
//  A watchdog task races the stream so the silent phases (prefill, remote
//  first-token waits) are also interruptible; cancelling the consumer tears
//  the producer down through `AsyncThrowingStream.onTermination`, which
//  propagates into `ModelRuntime`'s generation cancel (and vmlx's
//  `finishSlot` GPU drain), so a cancelled run never leaves work on the GPU.
//

import Foundation

/// Why a subagent run stopped before finishing. Threaded out of the runner so
/// the kind can map each cause to honest user-facing copy instead of blaming
/// every cancellation on the time budget.
enum SubagentCancelCause: String, Sendable {
    /// The user pressed the subagent row's stop button (`InterruptToken`).
    case userInterrupt = "user_interrupt"
    /// The run hit its own `maxElapsedSeconds` wall-clock budget.
    case deadline
    /// The surrounding task (parent chat turn / HTTP request) was cancelled.
    case parentTask = "parent_task"
}

/// Aggregated model usage across every iteration of one subagent run.
struct AgentSubagentUsage: Sendable {
    /// Prompt tokens of the LAST model step (the largest composed prompt —
    /// what the run actually cost to re-prefill on its final iteration).
    var promptTokens: Int = 0
    /// Completion tokens summed across steps. Authoritative (stats sentinel)
    /// when the runtime reports them, estimator fallback otherwise.
    var completionTokens: Int = 0
    /// Decode speed of the last step that reported one (tok/s).
    var tokensPerSecond: Double?
}

struct AgentSubagentRunResult: Sendable {
    var digest: String?
    var exit: AgentToolLoop.Exit
    var iterations: Int
    /// Set when `exit == .cancelled` (nil otherwise) so the kind can map an
    /// honest message per cause.
    var cancelCause: SubagentCancelCause?
    var usage: AgentSubagentUsage = AgentSubagentUsage()
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
    /// Throttled live-progress callback: cumulative completion tokens for the
    /// current step and the last reported decode speed (nil until the runtime
    /// reports one).
    typealias Progress = @Sendable (_ completionTokens: Int, _ tokensPerSecond: Double?) -> Void

    /// Internal cancel signal carrying its cause. Thrown out of the stream
    /// consumption (or its watchdog) and converted to a `.cancelled` exit at
    /// the runner boundary — never escapes `run`.
    private struct RunCancelled: Error {
        let cause: SubagentCancelCause
    }

    /// What one streamed model step produced.
    private struct StepOutcome {
        var text = ""
        var reasoning = ""
        var toolCalls: [ServiceToolInvocation] = []
        /// Authoritative completion-token count from the stats sentinel, or
        /// a character-based estimate when the provider never reported one.
        var completionTokens = 0
        var tokensPerSecond: Double?
    }

    /// Run a bounded subagent loop. The caller (kind) owns model resolution,
    /// permission, the residency handoff, and result mapping; this owns the
    /// loop, message bookkeeping, digest capture, and cancellation.
    static func run(
        modelName: String,
        seedMessages: [ChatMessage],
        maxTokens: Int?,
        maxIterations: Int,
        deadline: Date,
        sessionId: String,
        temperature: Float? = nil,
        isAgentRequest: Bool = true,
        stopOnToolRejection: Bool = false,
        treatEmptyChoicesAsFinal: Bool = false,
        isInterrupted: @escaping @Sendable () -> Bool = { false },
        toolset: AgentSubagentToolset? = nil,
        onProgress: Progress? = nil
    ) async throws -> AgentSubagentRunResult {
        var messages = seedMessages
        var finalDigest: String?
        var usage = AgentSubagentUsage()
        var iterationsSeen = 0
        var recordedCancelCause: SubagentCancelCause?

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

        /// One probe for all three cancel sources, in specificity order: the
        /// subagent's own stop button first, then its wall-clock budget, then
        /// the surrounding task.
        @Sendable func cancelCause() -> SubagentCancelCause? {
            if isInterrupted() { return .userInterrupt }
            if Date() >= deadline { return .deadline }
            if Task.isCancelled { return .parentTask }
            return nil
        }

        let hooks = AgentLoopHooks(
            isCancelled: {
                if let cause = cancelCause() {
                    recordedCancelCause = cause
                    return true
                }
                return false
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
                iterationsSeen += 1
                var request = ChatCompletionRequest(
                    model: modelName,
                    messages: effective,
                    temperature: temperature,
                    max_tokens: maxTokens,
                    stream: true,
                    top_p: nil,
                    frequency_penalty: nil,
                    presence_penalty: nil,
                    stop: nil,
                    n: nil,
                    tools: toolset?.specs,
                    tool_choice: nil,
                    session_id: sessionId
                )
                // Same posture as the main chat surface: a per-agent
                // temperature override rides along, everything else stays on
                // the model bundle's own generation defaults.
                request.samplingParametersAreImplicit = true
                request.isAgentRequest = isAgentRequest

                let stepStarted = Date()
                let stream = try await engine.streamChat(request: request)
                let outcome = try await Self.consumeStream(
                    stream,
                    cancelCause: cancelCause,
                    onProgress: onProgress
                )

                // Usage: prompt of the last step (largest composed prompt),
                // completions summed. Estimator fallback for providers that
                // never emit the stats sentinel.
                usage.promptTokens = ContextBudgetManager.estimateTokens(for: effective)
                var stepCompletion = outcome.completionTokens
                if stepCompletion == 0 {
                    stepCompletion =
                        TokenEstimator.estimate(outcome.text)
                        + TokenEstimator.estimate(outcome.reasoning)
                }
                usage.completionTokens += stepCompletion
                if let tps = outcome.tokensPerSecond {
                    usage.tokensPerSecond = tps
                } else if stepCompletion > 0 {
                    let elapsed = Date().timeIntervalSince(stepStarted)
                    if elapsed > 0.5 {
                        usage.tokensPerSecond = Double(stepCompletion) / elapsed
                    }
                }

                if !outcome.toolCalls.isEmpty {
                    // Frame the assistant tool_calls message exactly as the
                    // non-streamed path did, so the child transcript stays
                    // OpenAI-shaped for the next iteration.
                    let calls = outcome.toolCalls.map { inv -> ToolCall in
                        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                        return ToolCall(
                            id: inv.toolCallId ?? "call_" + String(raw.prefix(24)),
                            type: "function",
                            function: ToolCallFunction(
                                name: inv.toolName,
                                arguments: inv.jsonArguments
                            ),
                            geminiThoughtSignature: inv.geminiThoughtSignature
                        )
                    }
                    messages.append(
                        ChatMessage(
                            role: "assistant",
                            content: nil,
                            tool_calls: calls,
                            tool_call_id: nil
                        )
                    )
                    return .toolCalls(
                        zip(outcome.toolCalls, calls).map { inv, call in
                            ServiceToolInvocation(
                                toolName: inv.toolName,
                                jsonArguments: inv.jsonArguments,
                                toolCallId: call.id,
                                geminiThoughtSignature: inv.geminiThoughtSignature
                            )
                        }
                    )
                }

                let text = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    return treatEmptyChoicesAsFinal ? .finalResponse : .emptyResponse
                }
                finalDigest = outcome.text
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

        do {
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
                iterations: runResult.iterations,
                cancelCause: runResult.exit == .cancelled ? (recordedCancelCause ?? cancelCause()) : nil,
                usage: usage
            )
        } catch let cancelled as RunCancelled {
            // Mid-generation cancellation (chunk checkpoint or watchdog):
            // convert to the same `.cancelled` exit the boundary checks
            // produce, with the recorded cause.
            return AgentSubagentRunResult(
                digest: nil,
                exit: .cancelled,
                iterations: iterationsSeen,
                cancelCause: cancelled.cause,
                usage: usage
            )
        }
    }

    // MARK: - Stream consumption

    /// Consume one model step's stream with chunk-granular cancellation and a
    /// watchdog covering the silent phases (prefill, remote first-token
    /// waits). Tool calls surface as thrown
    /// `ServiceToolInvocations`/`ServiceToolInvocation` from the stream and
    /// are captured into the outcome; a tripped cancel throws `RunCancelled`.
    private static func consumeStream(
        _ stream: AsyncThrowingStream<String, Error>,
        cancelCause: @escaping @Sendable () -> SubagentCancelCause?,
        onProgress: Progress?
    ) async throws -> StepOutcome {
        try await withThrowingTaskGroup(of: StepOutcome?.self) { group in
            group.addTask {
                var outcome = StepOutcome()
                // Cheap running counters so per-chunk progress stays O(1):
                // estimate = chars/4 until the authoritative stats sentinel
                // arrives (local runtimes emit it; remote providers may not).
                var visibleChars = 0
                var sawStats = false
                var lastProgressEmit = Date.distantPast
                do {
                    for try await delta in stream {
                        if let cause = cancelCause() { throw RunCancelled(cause: cause) }
                        if let stats = StreamingStatsHint.decode(delta) {
                            sawStats = true
                            outcome.completionTokens = stats.tokenCount
                            outcome.tokensPerSecond = stats.tokensPerSecond
                            onProgress?(stats.tokenCount, stats.tokensPerSecond)
                            continue
                        }
                        if let reasoningDelta = StreamingReasoningHint.decode(delta) {
                            outcome.reasoning += reasoningDelta
                            visibleChars += reasoningDelta.count
                        } else if StreamingToolHint.isSentinel(delta) {
                            // Other in-band hints (tool/args fragments, prefill
                            // progress, billing) — not visible text.
                            continue
                        } else {
                            outcome.text += delta
                            visibleChars += delta.count
                        }
                        if !sawStats {
                            outcome.completionTokens =
                                visibleChars / TokenEstimator.charsPerToken
                        }
                        // Throttle the feed callback to ~4 Hz.
                        if let onProgress, Date().timeIntervalSince(lastProgressEmit) >= 0.25 {
                            lastProgressEmit = Date()
                            onProgress(outcome.completionTokens, outcome.tokensPerSecond)
                        }
                    }
                } catch let batch as ServiceToolInvocations {
                    outcome.toolCalls = batch.invocations
                } catch let single as ServiceToolInvocation {
                    outcome.toolCalls = [single]
                }
                // The producer FINISHES (rather than throws) when its own task
                // is cancelled, so re-probe after a clean stream end: a stream
                // torn down by a cancel must not be mistaken for a complete
                // answer. If the step still produced usable output (tool calls
                // or non-empty text), keep it — the cancel landed at natural
                // completion and honesty favors the finished result.
                if outcome.toolCalls.isEmpty,
                    outcome.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    let cause = cancelCause()
                {
                    throw RunCancelled(cause: cause)
                }
                return outcome
            }
            group.addTask {
                // Watchdog: fires the cancel even when no deltas arrive
                // (prefill, remote waits). Never returns normally.
                while true {
                    if let cause = cancelCause() { throw RunCancelled(cause: cause) }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            do {
                // First finisher wins: the consumer is the only child that can
                // return a value; a watchdog trip (or consumer throw) lands
                // here as the thrown error.
                guard let first = try await group.next(), let outcome = first else {
                    throw RunCancelled(cause: cancelCause() ?? .parentTask)
                }
                group.cancelAll()
                return outcome
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }
}
