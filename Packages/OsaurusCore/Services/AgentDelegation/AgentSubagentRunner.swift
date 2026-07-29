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
/// runner dispatches allowed calls through an owned operation (the kind
/// enforces its own allowlist + error conversion inside the operation).
struct AgentSubagentToolset: Sendable {
    var specs: [Tool]
    var beginExecution:
        @Sendable (_ invocation: ServiceToolInvocation) -> OwnedSubagentOperation<String>

    init(
        specs: [Tool],
        beginExecution:
            @escaping @Sendable (ServiceToolInvocation) -> OwnedSubagentOperation<String>
    ) {
        self.specs = specs
        self.beginExecution = beginExecution
    }

    /// Compatibility initializer for private/injected dispatchers. The
    /// resulting task is still explicitly owned: cancellation requests abort
    /// and the runner drains it before the turn can finish.
    init(
        specs: [Tool],
        execute: @escaping @Sendable (ServiceToolInvocation) async -> String
    ) {
        self.init(
            specs: specs,
            beginExecution: { invocation in
                OwnedSubagentOperation {
                    await execute(invocation)
                }
            }
        )
    }

    func execute(_ invocation: ServiceToolInvocation) async -> String {
        let operation = beginExecution(invocation)
        do {
            return try await operation.value()
        } catch {
            return ToolEnvelope.fromError(error, tool: invocation.toolName)
        }
    }
}

enum AgentSubagentRunner {
    /// Throttled live-progress callback: cumulative completion tokens for the
    /// current step and the last reported decode speed (nil until the runtime
    /// reports one).
    typealias Progress = @Sendable (_ completionTokens: Int, _ tokensPerSecond: Double?) -> Void
    /// One real model-channel delta in producer order. Reasoning is emitted
    /// only when the runtime supplied `reasoning_content`; visible content is
    /// never folded into or out of that channel.
    enum ChannelDelta: Sendable, Equatable {
        case reasoning(String)
        case content(String)
    }
    typealias ChannelObserver = @Sendable (ChannelDelta) -> Void
    /// Injectable stream producer used by deterministic runner regressions.
    /// Production callers omit it and continue through `ChatEngine`.
    typealias StreamProvider =
        @Sendable (ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error>

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
        enableThinking: Bool? = nil,
        isAgentRequest: Bool = true,
        stopOnToolRejection: Bool = false,
        treatEmptyChoicesAsFinal: Bool = false,
        isInterrupted: @escaping @Sendable () -> Bool = { false },
        toolset: AgentSubagentToolset? = nil,
        onProgress: Progress? = nil,
        onChannelDelta: ChannelObserver? = nil,
        streamProvider: StreamProvider? = nil
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
                request.enable_thinking = enableThinking
                // A child is user-visible work, but its cold load must not
                // evict an unrelated resident owned by HTTP/plugin traffic.
                // The runtime's background intent is atomic: same-model cache
                // hits and empty/flexible slots proceed, conflicting strict or
                // over-budget loads fail honestly before eviction.
                request.backgroundModelLoad = true
                request.preserveExistingResidencyOwner = true

                let stepStarted = Date()
                let stream: AsyncThrowingStream<String, Error>
                if let streamProvider {
                    stream = try await streamProvider(request)
                } else {
                    stream = try await engine.streamChat(request: request)
                }
                let outcome = try await Self.consumeStream(
                    stream,
                    cancelCause: cancelCause,
                    onProgress: onProgress,
                    onChannelDelta: onChannelDelta
                )
                // A Stop can land after the producer's final delta but before
                // this model-step hook classifies the accumulated text. Never
                // promote that partial/terminal buffer to a successful digest.
                try Self.rejectTerminalCancellation(cancelCause)

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
                usage.tokensPerSecond = resolvedTokensPerSecond(
                    reported: outcome.tokensPerSecond,
                    completionTokens: stepCompletion,
                    elapsed: Date().timeIntervalSince(stepStarted)
                ) ?? usage.tokensPerSecond

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
                            tool_call_id: nil,
                            reasoning_content: outcome.reasoning.isEmpty
                                ? nil
                                : outcome.reasoning
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
                            "Tool '\(invocation.toolName)' is not available inside this spawned run — "
                            + "it has no tools. Answer from the information you already have, and say "
                            + "plainly when the task needs a tool you don't have.",
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
                // Ephemeral child session id. The surrounding run inherits the
                // launcher `currentAgentId`; a configured target toolset may
                // temporarily bind its target id inside the individual
                // operation so registry policy follows the child's persona.
                let operation = ChatExecutionContext.$currentSessionId.withValue(sessionId) {
                    toolset.beginExecution(invocation)
                }
                let result: String
                do {
                    result = try await operation.value(
                        cancellationRequested: { cancelCause() != nil }
                    )
                } catch is CancellationError {
                    // `OwnedSubagentOperation.value` has already requested
                    // abort and drained the child operation. The loop hook is
                    // non-throwing, so record the sticky cause and return one
                    // honest tool envelope; the loop's next cancellation
                    // boundary produces the canonical `.cancelled` exit.
                    let cause = cancelCause() ?? .parentTask
                    recordedCancelCause = cause
                    result = ToolEnvelope.failure(
                        kind: .executionError,
                        message: "Spawned tool operation was cancelled (\(cause.rawValue)).",
                        tool: invocation.toolName,
                        retryable: false
                    )
                } catch {
                    result = ToolEnvelope.fromError(error, tool: invocation.toolName)
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

    /// Prefer a provider/runtime decode rate when it is genuinely populated.
    /// Remote providers that report token counts but omit throughput currently
    /// encode `0` in the terminal stats hint; treat that sentinel value as
    /// unavailable and fall back to measured end-to-end model-step throughput.
    /// This is deliberately conservative (the elapsed interval includes TTFT)
    /// but remains real telemetry rather than a synthetic sampler default.
    static func resolvedTokensPerSecond(
        reported: Double?,
        completionTokens: Int,
        elapsed: TimeInterval
    ) -> Double? {
        if let reported, reported.isFinite, reported > 0 {
            return reported
        }
        guard completionTokens > 0, elapsed.isFinite, elapsed > 0 else {
            return nil
        }
        return Double(completionTokens) / elapsed
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
        onProgress: Progress?,
        onChannelDelta: ChannelObserver?
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
                            onChannelDelta?(.reasoning(reasoningDelta))
                        } else if StreamingToolHint.isSentinel(delta) {
                            // Other in-band hints (tool/args fragments, prefill
                            // progress, billing) — not visible text.
                            continue
                        } else {
                            outcome.text += delta
                            visibleChars += delta.count
                            if !delta.isEmpty {
                                onChannelDelta?(.content(delta))
                            }
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
                // The producer can FINISH (rather than throw) when its own
                // task is cancelled. Re-probe after every clean stream end:
                // buffered text/tool fragments are not proof the model
                // reached a valid terminal boundary, so Stop always wins.
                try Self.rejectTerminalCancellation(cancelCause)
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

    /// The shared post-stream cancellation boundary. Internal for a
    /// deterministic regression test: a stream that buffered visible text
    /// before Stop must still exit as cancelled, never as a final answer.
    static func rejectTerminalCancellation(
        _ cancelCause: @escaping @Sendable () -> SubagentCancelCause?
    ) throws {
        if let cause = cancelCause() {
            throw RunCancelled(cause: cause)
        }
    }
}
