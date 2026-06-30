//
//  AppleScriptLoop.swift
//  OsaurusCore — AppleScript Computer Use
//
//  The generate → gate → execute → feed-back controller for the `applescript`
//  subagent. Each step the AppleScript model emits ONE `run_applescript` call;
//  the loop gates it (confirm-each or auto-run-with-warning), runs it in-process
//  via `AppleScriptExecutor`, and feeds the real output / error back so the
//  model can iterate. Completion is the model's own signal: a plain-text reply
//  with NO tool call ends the task (honoring the bundle's native training rather
//  than forcing a tool call every turn).
//
//  Runs as a nested subagent inside `AppleScriptKind` on the shared
//  `SubagentSession` host, so its steps never leak into the parent transcript —
//  they surface only through the shared `SubagentFeed`. Mirrors
//  `ComputerUseLoop`'s model-step robustness (per-step timeout + bounded retry,
//  context-budget trimming) but is much simpler: one tool, one gate, no
//  perception/vision ladder.
//

import Foundation

/// How an AppleScript run ended, plus the measurements the kind folds into its
/// `SubagentResult` payload.
public struct AppleScriptRunResult: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// The model finished and returned a plain-text summary.
        case done(summary: String)
        /// The user stopped the run (interrupt / cancellation).
        case interrupted
        /// Hit the step cap before finishing.
        case stepCapReached
        /// Terminated on an error (timeout, inference failure, re-ask budget).
        case failed(reason: String)

        public var isSuccess: Bool { if case .done = self { return true } else { return false } }

        public var summary: String {
            switch self {
            case .done(let s): return s
            case .interrupted: return L("Stopped by user.")
            case .stepCapReached:
                return L("Stopped: reached the step limit before finishing.")
            case .failed(let r): return L("Failed: \(r)")
            }
        }
    }

    public let outcome: Outcome
    /// Number of scripts actually executed (approved + run).
    public let scriptsExecuted: Int
    /// Total model tokens spent across the run.
    public let modelTokens: Int
    /// The output of the last successful script, if any (handy for the payload).
    public let lastOutput: String?

    public init(outcome: Outcome, scriptsExecuted: Int, modelTokens: Int, lastOutput: String?) {
        self.outcome = outcome
        self.scriptsExecuted = scriptsExecuted
        self.modelTokens = modelTokens
        self.lastOutput = lastOutput
    }
}

/// Input handed to an injected step provider (tests/evals): the step index and
/// the most recent tool-result text the model would key off.
public struct AppleScriptStepInput: Sendable, Equatable {
    public let step: Int
    public let lastToolResult: String?

    public init(step: Int, lastToolResult: String?) {
        self.step = step
        self.lastToolResult = lastToolResult
    }
}

/// Injectable model step: returns the next `run_applescript` call, or `nil` to
/// signal completion (the model emitted no tool call). Reuses the Computer Use
/// `ModelActionCall` (id + raw arguments JSON).
public typealias AppleScriptStepProvider =
    @Sendable (_ input: AppleScriptStepInput) async throws -> ModelActionCall?

/// Injectable executor seam so tests drive the loop without touching the OS.
public typealias AppleScriptRunner =
    @Sendable (_ script: String) async -> AppleScriptExecutionResult

public enum AppleScriptLoop {

    /// Drive a natural-language task to completion by generating + running
    /// AppleScript. Pure orchestration over the injected confirm + execute
    /// seams, so it's fully testable without a live model or the desktop.
    public static func run(
        task: String,
        modelId: String,
        feed: SubagentFeed,
        interrupt: InterruptToken,
        executionMode: AppleScriptExecutionMode,
        confirm: @escaping @Sendable (ActionPreview) async -> Bool,
        limits: RunLimits = RunLimits(maxSteps: 12),
        sessionId: String,
        execute: AppleScriptRunner? = nil,
        nextScript: AppleScriptStepProvider? = nil
    ) async -> AppleScriptRunResult {
        let deadline = Date().addingTimeInterval(limits.wallClockSeconds)
        let engine: ChatEngine? = nextScript == nil ? ChatEngine(source: .chatUI) : nil
        // Default to the real in-process executor; tests inject their own. Kept
        // out of the (public) default argument because `AppleScriptExecutor` is
        // internal and a public default value can't reference an internal symbol.
        let runExecutor: AppleScriptRunner = execute ?? { await AppleScriptExecutor.run(source: $0) }

        var messages: [ChatMessage] = [
            ChatMessage(role: "system", content: systemPrompt())
        ]
        messages.append(ChatMessage(role: "user", content: "Task: \(task)"))

        let contextWindow = await AgentLoopBudget.resolveContextWindow(modelId: modelId)
        let systemChars = messages.first?.content?.count ?? 0
        let budgetManager = AgentLoopBudget.makeBudgetManager(
            contextWindow: contextWindow,
            systemPromptChars: systemChars,
            toolTokens: 400,
            maxResponseTokens: nil
        )
        let watermark = CompactionWatermark()

        var step = 0
        var scriptsExecuted = 0
        var modelTokens = 0
        var lastOutput: String? = nil
        var consecutiveInvalid = 0
        var lastToolResult: String? = nil

        func terminate(_ outcome: AppleScriptRunResult.Outcome) -> AppleScriptRunResult {
            feed.emit(
                SubagentActivityEvent(
                    step: step,
                    kind: .outcome,
                    title: outcome.summary,
                    success: outcome.isSuccess
                )
            )
            feed.finish(success: outcome.isSuccess, summary: outcome.summary)
            return AppleScriptRunResult(
                outcome: outcome,
                scriptsExecuted: scriptsExecuted,
                modelTokens: modelTokens,
                lastOutput: lastOutput
            )
        }

        feed.emitPhase("generating", detail: modelId)

        while true {
            if interrupt.isInterrupted || Task.isCancelled {
                return terminate(.interrupted)
            }
            if Date() >= deadline {
                return terminate(.failed(reason: "Reached the time limit before finishing."))
            }
            if step >= limits.maxSteps {
                return terminate(.stepCapReached)
            }

            let iterationInput = AgentLoopBudget.composeIterationMessages(
                messages,
                notices: [],
                manager: budgetManager,
                watermark: watermark
            )
            let stepMessages = iterationInput.messages
            let stepIndex = step
            let capturedLastResult = lastToolResult
            let produce: @Sendable () async throws -> ModelStepResult = {
                if let nextScript {
                    let input = AppleScriptStepInput(step: stepIndex, lastToolResult: capturedLastResult)
                    return ModelStepResult(call: try await nextScript(input), text: nil, tokens: 0)
                }
                return try await modelStep(
                    engine: engine!,
                    modelId: modelId,
                    sessionId: sessionId,
                    messages: stepMessages
                )
            }

            let stepResult: ModelStepResult
            do {
                stepResult = try await runModelStep(
                    produce,
                    timeout: limits.modelStepTimeoutSeconds,
                    maxRetries: limits.maxInferenceRetries,
                    feed: feed,
                    step: step
                )
            } catch {
                return terminate(.failed(reason: error.localizedDescription))
            }
            modelTokens += stepResult.tokens

            // No tool call → the model is done. Its plain-text reply (if any)
            // is the summary. This is the natural completion path.
            guard let call = stepResult.call else {
                let text = stepResult.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = (text?.isEmpty ?? true) ? "Completed the AppleScript task." : text!
                return terminate(.done(summary: summary))
            }

            let assistantMessage = ChatMessage(
                role: "assistant",
                content: nil,
                tool_calls: [
                    ToolCall(
                        id: call.id,
                        type: "function",
                        function: ToolCallFunction(
                            name: AppleScriptAction.toolName,
                            arguments: call.arguments
                        )
                    )
                ],
                tool_call_id: nil
            )

            let decoded = AppleScriptAction.decode(argumentsJSON: call.arguments)
            guard case .script(let script) = decoded else {
                consecutiveInvalid += 1
                let reason: String
                if case .invalid(let r) = decoded { reason = r } else { reason = "Invalid call." }
                feed.emit(
                    SubagentActivityEvent(
                        step: step,
                        kind: .retry,
                        title: "Invalid run_applescript call",
                        detail: reason
                    )
                )
                if consecutiveInvalid >= limits.maxConsecutiveInvalid {
                    return terminate(
                        .failed(reason: "The model could not produce a valid script: \(reason)")
                    )
                }
                let toolResult = "Your call was rejected: \(reason) Try again with a corrected run_applescript call."
                messages.append(assistantMessage)
                messages.append(
                    ChatMessage(
                        role: "tool",
                        content: toolResult,
                        tool_calls: nil,
                        tool_call_id: call.id
                    )
                )
                lastToolResult = toolResult
                continue
            }
            consecutiveInvalid = 0
            messages.append(assistantMessage)

            // Surface the proposed script in the feed regardless of gate mode,
            // so the chat row always records what was generated.
            feed.emit(
                SubagentActivityEvent(
                    step: step,
                    kind: .propose,
                    title: "AppleScript",
                    detail: scriptPreview(script)
                )
            )

            // Gate: confirm-each pauses for explicit approval (the confirm
            // overlay shows the full script); auto-run-with-warning runs but
            // emits a prominent warning event showing the script.
            let approved: Bool
            switch executionMode {
            case .confirmEach:
                let preview = ActionPreview(
                    appName: nil,
                    actionLabel: L("Run AppleScript"),
                    targetLabel: nil,
                    effect: .consequential,
                    note: nil,
                    scriptBody: script
                )
                feed.emit(
                    SubagentActivityEvent(
                        step: step,
                        kind: .confirmRequested,
                        title: "Confirm: Run AppleScript",
                        detail: scriptPreview(script)
                    )
                )
                approved = await confirm(preview)
                if approved {
                    feed.emit(
                        SubagentActivityEvent(step: step, kind: .confirmed, title: "Approved: Run AppleScript")
                    )
                } else {
                    feed.emit(
                        SubagentActivityEvent(step: step, kind: .denied, title: "Declined: Run AppleScript")
                    )
                }
            case .autoRunWithWarning:
                feed.emit(
                    SubagentActivityEvent(
                        step: step,
                        kind: .error,
                        title: "Auto-running AppleScript without confirmation",
                        detail: scriptPreview(script),
                        success: nil
                    )
                )
                approved = true
            }

            guard approved else {
                let toolResult =
                    "The user declined to run that script. Try a different approach, or finish with a "
                    + "short explanation if you can't proceed."
                messages.append(
                    ChatMessage(
                        role: "tool",
                        content: toolResult,
                        tool_calls: nil,
                        tool_call_id: call.id
                    )
                )
                lastToolResult = toolResult
                step += 1
                continue
            }

            feed.emit(SubagentActivityEvent(step: step, kind: .act, title: "Running AppleScript"))
            let execution = await runExecutor(script)
            scriptsExecuted += 1
            let toolResult = describe(execution, feed: feed, step: step)
            if execution.isSuccess { lastOutput = execution.output }
            messages.append(
                ChatMessage(role: "tool", content: toolResult, tool_calls: nil, tool_call_id: call.id)
            )
            lastToolResult = toolResult
            step += 1
        }
    }

    /// Map an execution result to the tool-result text fed back to the model AND
    /// emit the matching feed event. The model gets the REAL outcome (output or
    /// the actual error) so it can self-correct — no fake success.
    private static func describe(
        _ result: AppleScriptExecutionResult,
        feed: SubagentFeed,
        step: Int
    ) -> String {
        switch result.status {
        case .success:
            let output = result.output?.trimmingCharacters(in: .whitespacesAndNewlines)
            feed.emit(
                SubagentActivityEvent(
                    step: step,
                    kind: .verify,
                    title: "Script succeeded",
                    detail: (output?.isEmpty ?? true) ? nil : scriptPreview(output!),
                    success: true
                )
            )
            if let output, !output.isEmpty {
                return "The script ran successfully. Output:\n\(output)"
            }
            return "The script ran successfully with no output."
        case .compileError:
            let message = result.errorMessage ?? "syntax error"
            feed.emit(
                SubagentActivityEvent(
                    step: step, kind: .error, title: "Script did not compile", detail: message,
                    success: false
                )
            )
            return
                "The script did not compile: \(message). Fix the AppleScript syntax and call run_applescript again."
        case .runtimeError:
            let message = result.errorMessage ?? "runtime error"
            let code = result.errorNumber.map { " (error \($0))" } ?? ""
            feed.emit(
                SubagentActivityEvent(
                    step: step, kind: .error, title: "Script failed at runtime",
                    detail: message + code, success: false
                )
            )
            return
                "The script failed at runtime: \(message)\(code). Adjust the script and call run_applescript again."
        case .permissionRequired:
            let message = result.errorMessage ?? "Automation permission is required."
            feed.emit(
                SubagentActivityEvent(
                    step: step, kind: .error, title: "Automation permission needed", detail: message,
                    success: false
                )
            )
            return
                "macOS blocked the script because Automation permission for that app isn't granted yet "
                + "(\(message)). A system permission dialog should have appeared — once the user approves "
                + "it, call run_applescript again. If it keeps failing, ask the user to enable Osaurus under "
                + "System Settings → Privacy & Security → Automation."
        case .timedOut:
            let message = result.errorMessage ?? "The script timed out."
            feed.emit(
                SubagentActivityEvent(
                    step: step, kind: .error, title: "Script timed out", detail: message, success: false
                )
            )
            return
                "\(message) It may have been waiting on the app or a dialog. Simplify the script or break "
                + "the task into smaller steps, then call run_applescript again."
        }
    }

    /// A compact, single-line-ish preview of a script/output for the feed
    /// (the confirm overlay shows the full body). Collapses whitespace runs and
    /// caps the length so the activity row stays readable.
    private static func scriptPreview(_ source: String) -> String {
        let collapsed = source
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let squeezed = collapsed.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        return squeezed.count > 200 ? String(squeezed.prefix(200)) + "…" : squeezed
    }

    // MARK: - Model step

    /// One model step's result: the proposed call (nil when the model emitted
    /// no tool call → completion), the assistant text (the completion summary),
    /// and the token usage.
    struct ModelStepResult: Sendable {
        var call: ModelActionCall?
        var text: String?
        var tokens: Int = 0
    }

    private static func modelStep(
        engine: ChatEngine,
        modelId: String,
        sessionId: String,
        messages: [ChatMessage]
    ) async throws -> ModelStepResult {
        var req = ChatCompletionRequest(
            model: modelId,
            messages: messages,
            temperature: nil,
            max_tokens: nil,
            stream: false,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: [AppleScriptAction.toolSpec],
            tool_choice: AppleScriptAction.autoToolChoice,
            session_id: sessionId
        )
        req.samplingParametersAreImplicit = true
        req.isAgentRequest = true
        let response = try await engine.completeChat(request: req)
        let tokens = response.usage.total_tokens
        guard let message = response.choices.first?.message else {
            return ModelStepResult(call: nil, text: nil, tokens: tokens)
        }
        let text = message.content
        if let calls = message.tool_calls,
            let call = calls.first(where: { $0.function.name == AppleScriptAction.toolName })
                ?? calls.first
        {
            return ModelStepResult(
                call: ModelActionCall(id: call.id, arguments: call.function.arguments),
                text: text,
                tokens: tokens
            )
        }
        return ModelStepResult(call: nil, text: text, tokens: tokens)
    }

    // MARK: - Model-step robustness (mirrors ComputerUseLoop)

    private struct ModelStepTimeout: Error, LocalizedError {
        var errorDescription: String? { "The model step timed out." }
    }

    private static func runModelStep(
        _ produce: @escaping @Sendable () async throws -> ModelStepResult,
        timeout: TimeInterval,
        maxRetries: Int,
        feed: SubagentFeed,
        step: Int
    ) async throws -> ModelStepResult {
        var attempt = 0
        while true {
            do {
                return try await withModelStepTimeout(timeout, produce)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt >= maxRetries { throw error }
                attempt += 1
                feed.emit(
                    SubagentActivityEvent(
                        step: step,
                        kind: .retry,
                        title: "Model step failed; retrying (\(attempt)/\(maxRetries))",
                        detail: error.localizedDescription
                    )
                )
                try? await Task.sleep(nanoseconds: UInt64(min(attempt, 4)) * 250_000_000)
            }
        }
    }

    private static func withModelStepTimeout(
        _ seconds: TimeInterval,
        _ op: @escaping @Sendable () async throws -> ModelStepResult
    ) async throws -> ModelStepResult {
        guard seconds > 0, seconds.isFinite else { return try await op() }
        return try await withThrowingTaskGroup(of: ModelStepResult.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ModelStepTimeout()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw ModelStepTimeout() }
            return result
        }
    }

    // MARK: - System prompt

    static func systemPrompt() -> String {
        """
        You are Osaurus's AppleScript agent. You accomplish the user's task on this Mac by writing a \
        complete, executable AppleScript and running it.

        Rules:
        - To run a script, call the `run_applescript` tool exactly once with the ENTIRE AppleScript in \
        `script`. Do not wrap it in Markdown code fences.
        - You will receive the script's output, or a compile/runtime error. If it failed, correct the \
        script and call `run_applescript` again.
        - Script the relevant app directly when it helps (e.g. `tell application "Safari" … end tell`). \
        The first time you control an app, macOS may ask the user to grant Automation permission — that \
        is expected; if a run reports a permission error, try again after the user approves the dialog.
        - Only do what the task asks. Avoid destructive or irreversible actions (deleting, sending, \
        purchasing) unless the user explicitly requested them.
        - When the task is complete, reply with a SHORT plain-text summary of what you did or found and \
        do NOT call the tool again. That plain-text reply ends the task.
        - Be efficient: there is a step limit.
        """
    }
}
