//
//  AppleScriptLoop.swift
//  OsaurusCore — AppleScript Computer Use
//
//  The generate → classify → gate → execute → feed-back controller for the
//  AppleScript subagent (`applescript` automate + `mac_query` read-only). Each
//  step the model emits ONE `run_applescript` call; the loop classifies its
//  effect (read / edit / consequential), gates it by mode (query + the
//  verification read-back auto-run reads and BLOCK writes; automate honors the
//  user's confirm-each / auto-run-with-warning policy), runs it in-process via
//  `AppleScriptExecutor`, and feeds the real output / error back so the model
//  can iterate. It accumulates a per-step transcript and, when a data task ends
//  without a captured value, runs one bounded read-only verification read-back.
//  Completion is the model's own signal: a plain-text reply with NO tool call
//  ends the task (honoring the bundle's native training rather than forcing a
//  tool call every turn).
//
//  Runs as a nested subagent inside `AppleScriptKind` on the shared
//  `SubagentSession` host, so its steps never leak into the parent transcript —
//  they surface only through the shared `SubagentFeed`. Mirrors
//  `ComputerUseLoop`'s model-step robustness (per-step timeout + bounded retry,
//  context-budget trimming).
//

import Foundation

/// Whether a run is a read-only information `query` (`mac_query`) or a state-
/// changing `automate` task (`applescript`). Drives the system prompt emphasis
/// and the per-script gate (query auto-runs reads and BLOCKS writes; automate
/// keeps the user's confirm-each / auto-run-with-warning policy).
public enum AppleScriptRunMode: String, Sendable, Equatable {
    case automate
    case query
}

/// One executed / declined / blocked / invalid step, captured so the parent
/// gets a real, troubleshootable transcript (which script, what it returned,
/// the exact error + AppleScript error number) instead of an opaque summary.
public struct AppleScriptStepRecord: Sendable, Equatable {
    public let n: Int
    /// `"read"` / `"action"` — the classified intent of the proposed script.
    public let intent: String
    /// `success` / `compile_error` / `runtime_error` / `permission_required` /
    /// `timed_out` / `declined` / `blocked` / `invalid`.
    public let status: String
    /// Coerced textual return value on success, if any.
    public let output: String?
    /// The error message on a failure / block / invalid step.
    public let error: String?
    /// The `NSAppleScript` error number on a compile / runtime failure.
    public let errorNumber: Int?
    /// A compact, single-line preview of the proposed script.
    public let scriptPreview: String?

    public init(
        n: Int,
        intent: String,
        status: String,
        output: String? = nil,
        error: String? = nil,
        errorNumber: Int? = nil,
        scriptPreview: String? = nil
    ) {
        self.n = n
        self.intent = intent
        self.status = status
        self.output = output
        self.error = error
        self.errorNumber = errorNumber
        self.scriptPreview = scriptPreview
    }
}

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
    /// Scripts that ran successfully.
    public let succeeded: Int
    /// Scripts that ran but failed (compile / runtime / permission / timeout).
    public let failed: Int
    /// Total model tokens spent across the run.
    public let modelTokens: Int
    /// The last non-empty coerced output across the run (the headline `values`
    /// the parent reads back). Captured on any successful script, including the
    /// verification read-back.
    public let lastOutput: String?
    /// The full per-step transcript (executed + declined + blocked + invalid).
    public let steps: [AppleScriptStepRecord]

    public init(
        outcome: Outcome,
        scriptsExecuted: Int,
        succeeded: Int = 0,
        failed: Int = 0,
        modelTokens: Int,
        lastOutput: String?,
        steps: [AppleScriptStepRecord] = []
    ) {
        self.outcome = outcome
        self.scriptsExecuted = scriptsExecuted
        self.succeeded = succeeded
        self.failed = failed
        self.modelTokens = modelTokens
        self.lastOutput = lastOutput
        self.steps = steps
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

/// One model-proposed script, surfaced to an optional observer BEFORE it is
/// gated / executed. Carries both the pre-expansion form the model actually
/// emitted (so an eval can prove a `{{name}}` placeholder was used instead of
/// re-typed) and the post-expansion form that runs. Behavior-neutral: the loop
/// only READS this out; production omits the observer.
public struct AppleScriptProposalRecord: Sendable, Equatable {
    public let step: Int
    /// The script exactly as the model emitted it (fence-stripped), still
    /// containing any `{{name}}` placeholder tokens.
    public let proposedScript: String
    /// The script after literal expansion — what preview / gate / execution see.
    public let expandedScript: String
    /// The classified effect: `"read"` / `"edit"` / `"consequential"`.
    public let effect: String

    public init(step: Int, proposedScript: String, expandedScript: String, effect: String) {
        self.step = step
        self.proposedScript = proposedScript
        self.expandedScript = expandedScript
        self.effect = effect
    }
}

/// Injectable observer of each successfully-expanded proposed script. Used only
/// by evals; `nil` in production. Called before the gate so it sees every
/// proposal, including ones later blocked or declined.
public typealias AppleScriptProposalObserver =
    @Sendable (_ record: AppleScriptProposalRecord) -> Void

/// Tunable harness knobs for the loop. Every field DEFAULTS to today's shipped
/// production behavior, so `.default` (and every existing caller that omits it)
/// is byte-for-byte unchanged. Evals sweep these to find the configuration that
/// gets the most out of the fixed on-device model — the "bring out the full
/// potential" levers, exposed as data rather than forked prompts.
public struct AppleScriptHarnessOptions: Sendable, Equatable {
    /// Which system-prompt phrasing to use. `.standard` is the shipped prompt.
    public enum PromptVariant: String, Sendable, Equatable, CaseIterable {
        /// The shipped, detailed prompt.
        case standard
        /// A trimmed prompt: the same rules at a fraction of the tokens.
        case concise
    }

    /// How the provided-content placeholders are announced to the model.
    /// `.nameOnly` is the shipped announcement — the evidence-backed sweep
    /// winner. Two independent capability sweeps put the leaner `.nameOnly` /
    /// `.minimal` at ~82% vs the older `.namePreview` ~64%, and both reproduced
    /// the MECHANISTIC reason to prefer it: at the ~15-literal ceiling
    /// `.namePreview`'s per-literal content preview makes the model emit NO
    /// script, while dropping the preview clears it (`live-many-literals` — all
    /// namePreview variants fail, both lean styles pass, in both sweeps). The
    /// preview is model-prompt-only (never user-visible) and does NOT affect the
    /// verbatim `{{name}}` expansion, so removing it only removes the model's
    /// "peek": redundant for a few well-named literals, decisive at scale. Other
    /// mid-count cases still flip run-to-run (~3/11), so `.namePreview` is kept
    /// as a sweep/regression option (`OSAURUS_AS_LITERAL_STYLE`) — keep sweeping
    /// when the literal contract changes.
    public enum LiteralAnnouncementStyle: String, Sendable, Equatable, CaseIterable {
        /// Older style: name + length + a head/tail content preview + a usage
        /// example. Retained as a sweep/regression option (was the shipped
        /// default before the sweep promoted `.nameOnly`).
        case namePreview
        /// Shipped: name + length (no preview) + a usage example.
        case nameOnly
        /// A single line naming the placeholders + a usage example.
        case minimal
    }

    /// Whether to run the one-shot read-only verification read-back when a data
    /// task finishes without a captured value (shipped: on).
    public var verifyReadBack: Bool
    /// Whether to inject the live desktop context (frontmost / running apps)
    /// into the prompt when the caller provides it (shipped: on).
    public var includeDesktopContext: Bool
    /// Which system-prompt phrasing to use (shipped: `.standard`).
    public var promptVariant: PromptVariant
    /// How provided-content placeholders are announced (shipped: `.nameOnly`).
    public var literalAnnouncementStyle: LiteralAnnouncementStyle

    public init(
        verifyReadBack: Bool = true,
        includeDesktopContext: Bool = true,
        promptVariant: PromptVariant = .standard,
        literalAnnouncementStyle: LiteralAnnouncementStyle = .nameOnly
    ) {
        self.verifyReadBack = verifyReadBack
        self.includeDesktopContext = includeDesktopContext
        self.promptVariant = promptVariant
        self.literalAnnouncementStyle = literalAnnouncementStyle
    }

    /// The shipped production configuration.
    public static let `default` = AppleScriptHarnessOptions()
}

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
        mode: AppleScriptRunMode = .automate,
        environmentContext: String? = nil,
        literals: AppleScriptLiterals = AppleScriptLiterals(),
        harness: AppleScriptHarnessOptions = .default,
        execute: AppleScriptRunner? = nil,
        nextScript: AppleScriptStepProvider? = nil,
        observeProposal: AppleScriptProposalObserver? = nil
    ) async -> AppleScriptRunResult {
        let deadline = Date().addingTimeInterval(limits.wallClockSeconds)
        let engine: ChatEngine? = nextScript == nil ? ChatEngine(source: .chatUI) : nil
        // Default to the real in-process executor; tests inject their own. Kept
        // out of the (public) default argument because `AppleScriptExecutor` is
        // internal and a public default value can't reference an internal symbol.
        let runExecutor: AppleScriptRunner = execute ?? { await AppleScriptExecutor.run(source: $0) }

        var systemContent = systemPrompt(mode: mode, variant: harness.promptVariant)
        if harness.includeDesktopContext, let environmentContext, !environmentContext.isEmpty {
            systemContent += "\n\nCurrent desktop:\n\(environmentContext)"
        }
        if !literals.isEmpty {
            systemContent +=
                "\n\n" + literalsPromptSection(literals, style: harness.literalAnnouncementStyle)
        }
        var messages: [ChatMessage] = [
            ChatMessage(role: "system", content: systemContent)
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
        var succeeded = 0
        var failed = 0
        var modelTokens = 0
        var lastOutput: String? = nil
        var consecutiveInvalid = 0
        var consecutiveBlocked = 0
        var lastToolResult: String? = nil
        var steps: [AppleScriptStepRecord] = []
        // The one-shot verification read-back: when a data task finished without
        // returning a value, we nudge the model to run ONE read-only script that
        // `return`s the requested state. `verifying` forces read-only gating for
        // that follow-up so it never silently mutates or prompts the user.
        var verifyAttempted = false
        var verifying = false

        func record(
            intent: EffectClass,
            status: String,
            output: String? = nil,
            error: String? = nil,
            errorNumber: Int? = nil,
            script: String
        ) {
            steps.append(
                AppleScriptStepRecord(
                    n: steps.count + 1,
                    intent: intent == .read ? "read" : "action",
                    status: status,
                    output: output,
                    error: error,
                    errorNumber: errorNumber,
                    scriptPreview: scriptPreview(script)
                )
            )
        }

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
                succeeded: succeeded,
                failed: failed,
                modelTokens: modelTokens,
                lastOutput: lastOutput,
                steps: steps
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

            // No tool call → the model is done. Before accepting completion, run
            // the one-shot verification read-back when a data task produced no
            // value, so the parent gets a REAL result instead of "completed".
            guard let call = stepResult.call else {
                let text = stepResult.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                let haveValue = !(lastOutput?.isEmpty ?? true)
                if harness.verifyReadBack, !verifyAttempted, !haveValue, scriptsExecuted > 0,
                    shouldVerify(mode: mode, task: task)
                {
                    verifyAttempted = true
                    verifying = true
                    feed.emit(
                        SubagentActivityEvent(
                            step: step,
                            kind: .retry,
                            title: "Verifying: reading the result back"
                        )
                    )
                    let nudge =
                        "You finished without returning any data, but the task needs the result. Run "
                        + "ONE more READ-ONLY AppleScript that gets and `return`s the specific value(s) "
                        + "the task asked for (e.g. the current/resulting state). Reply with a single "
                        + "run_applescript call. If the value genuinely cannot be read, reply with a "
                        + "short plain-text explanation instead."
                    messages.append(ChatMessage(role: "user", content: nudge))
                    lastToolResult = nudge
                    continue
                }
                let summary = completionSummary(
                    modelText: text,
                    lastOutput: lastOutput,
                    scriptsExecuted: scriptsExecuted,
                    succeeded: succeeded,
                    failed: failed
                )
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
            guard case .script(let proposedScript) = decoded else {
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
                steps.append(
                    AppleScriptStepRecord(
                        n: steps.count + 1,
                        intent: "unknown",
                        status: "invalid",
                        error: reason
                    )
                )
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

            // Classify the proposed script's effect (read / edit / consequential).
            // Escalate-biased + surfaced to the user, never used to fake safety.
            let effect = AppleScriptEffectClassifier.classify(proposedScript)

            // Expand any {{name}} placeholders into exact, correctly-escaped
            // AppleScript string literals BEFORE preview / gate / execution, so
            // the small model never re-types verbatim content (and can't
            // mis-escape it). Classification ran on the PLACEHOLDER form above,
            // so user content can't trip the escalate-biased classifier.
            let expansion = literals.expand(proposedScript)
            if let undefinedName = expansion.undefinedName {
                consecutiveInvalid += 1
                let reason = undefinedPlaceholderReason(undefinedName, literals: literals)
                feed.emit(
                    SubagentActivityEvent(
                        step: step,
                        kind: .retry,
                        title: "Unknown placeholder {{\(undefinedName)}}",
                        detail: reason
                    )
                )
                if consecutiveInvalid >= limits.maxConsecutiveInvalid {
                    return terminate(
                        .failed(
                            reason:
                                "The model kept referencing content that wasn't provided "
                                + "({{\(undefinedName)}})."
                        )
                    )
                }
                steps.append(
                    AppleScriptStepRecord(
                        n: steps.count + 1,
                        intent: "unknown",
                        status: "invalid",
                        error: reason
                    )
                )
                messages.append(
                    ChatMessage(
                        role: "tool",
                        content: reason,
                        tool_calls: nil,
                        tool_call_id: call.id
                    )
                )
                lastToolResult = reason
                continue
            }
            // Downstream preview / gate / execution all operate on the EXPANDED
            // script (the user sees and approves the real content that runs).
            let script = expansion.script

            // Surface the full proposal to an eval observer (pre + post
            // expansion) before gating, so a harness can prove placeholder use
            // and match on the real generated script. No-op in production.
            observeProposal?(
                AppleScriptProposalRecord(
                    step: step,
                    proposedScript: proposedScript,
                    expandedScript: script,
                    effect: effectLabelForRecord(effect)
                )
            )

            // Surface the proposed script (with its effect badge) in the feed
            // regardless of gate mode, so the chat row always records what was
            // generated and how risky it is.
            feed.emit(
                SubagentActivityEvent(
                    step: step,
                    kind: .propose,
                    title: "AppleScript (\(effect.displayLabel))",
                    detail: scriptPreview(script)
                )
            )

            // Gate the script against the mode + effect:
            //  • query / verification → run reads automatically, BLOCK writes.
            //  • automate → the user's confirm-each / auto-run-with-warning policy.
            let approved: Bool
            switch gateDecision(
                mode: mode,
                executionMode: executionMode,
                effect: effect,
                verifying: verifying
            ) {
            case .block(let reason):
                consecutiveBlocked += 1
                feed.emit(
                    SubagentActivityEvent(
                        step: step,
                        kind: .error,
                        title: "Blocked: read-only mode",
                        detail: scriptPreview(script),
                        success: false
                    )
                )
                record(intent: effect, status: "blocked", error: reason, script: script)
                if consecutiveBlocked >= limits.maxConsecutiveInvalid {
                    return terminate(
                        .failed(
                            reason:
                                "The task needs changes this read-only tool can't make. Use the "
                                + "automation tool instead."
                        )
                    )
                }
                messages.append(
                    ChatMessage(role: "tool", content: reason, tool_calls: nil, tool_call_id: call.id)
                )
                lastToolResult = reason
                step += 1
                continue
            case .confirm:
                let preview = ActionPreview(
                    appName: nil,
                    actionLabel: L("Run AppleScript"),
                    targetLabel: nil,
                    effect: effect,
                    note: nil,
                    scriptBody: script
                )
                feed.emit(
                    SubagentActivityEvent(
                        step: step,
                        kind: .confirmRequested,
                        title: "Confirm: Run AppleScript (\(effect.displayLabel))",
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
            case .autoRunReadOnly:
                approved = true
            }

            guard approved else {
                record(intent: effect, status: "declined", script: script)
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
            consecutiveBlocked = 0
            let toolResult = describe(execution, feed: feed, step: step)
            let trimmedOutput = execution.output?.trimmingCharacters(in: .whitespacesAndNewlines)
            if execution.isSuccess {
                succeeded += 1
                if let trimmedOutput, !trimmedOutput.isEmpty { lastOutput = trimmedOutput }
            } else {
                failed += 1
            }
            record(
                intent: effect,
                status: stepStatus(execution.status),
                output: (trimmedOutput?.isEmpty ?? true) ? nil : trimmedOutput,
                error: execution.errorMessage,
                errorNumber: execution.errorNumber,
                script: script
            )
            messages.append(
                ChatMessage(role: "tool", content: toolResult, tool_calls: nil, tool_call_id: call.id)
            )
            lastToolResult = toolResult
            step += 1
        }
    }

    // MARK: - Gating + completion helpers

    /// The per-script gate outcome.
    private enum AppleScriptGate {
        /// Run with no prompt and no warning (a read in query / verification).
        case autoRunReadOnly
        /// Run automatically but emit a prominent warning (automate auto-run).
        case autoRunWithWarning
        /// Pause for the user's explicit approval (automate confirm-each).
        case confirm
        /// Refuse to run; feed `reason` back so the model rewrites as a read.
        case block(reason: String)
    }

    /// Decide how to gate a proposed script. Read-only modes (`mac_query` and
    /// the verification read-back) auto-run reads and block any mutation;
    /// `automate` honors the user's execution-mode policy for every script.
    private static func gateDecision(
        mode: AppleScriptRunMode,
        executionMode: AppleScriptExecutionMode,
        effect: EffectClass,
        verifying: Bool
    ) -> AppleScriptGate {
        if verifying {
            return effect == .read
                ? .autoRunReadOnly
                : .block(
                    reason:
                        "The verification step must be read-only. Reply with a script that ONLY reads "
                        + "and `return`s the requested value(s), or a short plain-text explanation."
                )
        }
        switch mode {
        case .query:
            return effect == .read
                ? .autoRunReadOnly
                : .block(
                    reason:
                        "This is a read-only query tool — it cannot change anything. Rewrite the script "
                        + "to ONLY read state and `return` the requested information."
                )
        case .automate:
            switch executionMode {
            case .confirmEach: return .confirm
            case .autoRunWithWarning: return .autoRunWithWarning
            }
        }
    }

    /// The short effect label carried on an `AppleScriptProposalRecord`. The
    /// AppleScript classifier only ever returns read / edit / consequential.
    private static func effectLabelForRecord(_ effect: EffectClass) -> String {
        switch effect {
        case .read: return "read"
        case .consequential: return "consequential"
        default: return "edit"
        }
    }

    /// Map an execution status onto the payload's per-step status string.
    private static func stepStatus(_ status: AppleScriptExecutionResult.Status) -> String {
        switch status {
        case .success: return "success"
        case .compileError: return "compile_error"
        case .runtimeError: return "runtime_error"
        case .permissionRequired: return "permission_required"
        case .timedOut: return "timed_out"
        }
    }

    /// Whether a finished run with no captured value should attempt the
    /// verification read-back: always for a `query`, and for an `automate` task
    /// whose wording asks for information.
    static func shouldVerify(mode: AppleScriptRunMode, task: String) -> Bool {
        if mode == .query { return true }
        let t = task.lowercased()
        let dataIntent: [String] = [
            "report", "return", "what ", "which ", "list", "get ", "read", "status",
            "state", "current", "name", "title", "url", "value", "count", "how many",
            "tell me", "show me", "check", "contents", "selected", "version", "summary",
            "is ", "are ", "does ",
        ]
        return dataIntent.contains { t.contains($0) }
    }

    /// Build the completion summary: prefer the model's own plain-text reply;
    /// otherwise synthesize an honest one from the captured value / counts so
    /// the parent never sees the bare "Completed the AppleScript task." again.
    static func completionSummary(
        modelText: String?,
        lastOutput: String?,
        scriptsExecuted: Int,
        succeeded: Int,
        failed: Int
    ) -> String {
        if let modelText, !modelText.isEmpty { return modelText }
        if let value = lastOutput, !value.isEmpty {
            let capped = value.count > 400 ? String(value.prefix(400)) + "…" : value
            return "Done. Result: \(capped)"
        }
        if scriptsExecuted == 0 { return "Completed the task." }
        if succeeded == 0 { return "Ran \(scriptsExecuted) script(s); all failed." }
        if failed > 0 {
            return "Ran \(scriptsExecuted) script(s) (\(succeeded) ok, \(failed) failed)."
        }
        return "Ran \(scriptsExecuted) script(s) successfully."
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
                    step: step,
                    kind: .error,
                    title: "Script did not compile",
                    detail: message,
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
                    step: step,
                    kind: .error,
                    title: "Script failed at runtime",
                    detail: message + code,
                    success: false
                )
            )
            return
                "The script failed at runtime: \(message)\(code). Adjust the script and call run_applescript again."
        case .permissionRequired:
            let message = result.errorMessage ?? "Automation permission is required."
            feed.emit(
                SubagentActivityEvent(
                    step: step,
                    kind: .error,
                    title: "Automation permission needed",
                    detail: message,
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
                    step: step,
                    kind: .error,
                    title: "Script timed out",
                    detail: message,
                    success: false
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
        let collapsed =
            source
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let squeezed = collapsed.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        return squeezed.count > 200 ? String(squeezed.prefix(200)) + "…" : squeezed
    }

    // MARK: - Literal placeholders

    /// The system-prompt section announcing the verbatim content this run was
    /// given. It lists each placeholder's NAME and length (plus a head/tail
    /// preview under `.namePreview`) — never the full body, since the whole
    /// point is that the model references it instead of reproducing it — plus
    /// how to use it. With several literals the header reads in the plural; a
    /// task with MANY literals shows any previews for the first `maxPreviewed`
    /// and then names the rest (still referenceable) so the prompt stays bounded.
    static func literalsPromptSection(
        _ literals: AppleScriptLiterals,
        style: AppleScriptHarnessOptions.LiteralAnnouncementStyle = .nameOnly
    ) -> String {
        let names = literals.names
        guard !names.isEmpty else { return "" }
        let header =
            names.count == 1
            ? "Provided content — insert it VERBATIM via its placeholder; do NOT re-type the text:"
            : "Provided content — insert each block VERBATIM via its placeholder; do NOT re-type the text:"
        let example = names.first ?? "content"
        let usage =
            "Write the placeholder token exactly where its value belongs and do NOT re-type or rebuild "
            + "the value yourself (it expands to a complete, correctly-escaped AppleScript string — "
            + "quotes/newlines handled for you). This includes any NAME or identifier a value stands "
            + "for — a note title, file path, mailbox, or URL: write the placeholder in that slot too "
            + "instead of typing the name. Example: set body of note \"Title\" to {{\(example)}}"

        // `.minimal`: one line naming every placeholder, then the usage line.
        if style == .minimal {
            let all = names.map { "{{\($0)}}" }.joined(separator: ", ")
            return [header, "Placeholders: \(all)", usage].joined(separator: "\n")
        }

        var lines: [String] = [header]
        // Bound the per-item previews so a task with many literals can't blow
        // up the prompt; every name still appears (named-only past the cap) so
        // the model can reference all of them.
        let maxPreviewed = 12
        for name in names.prefix(maxPreviewed) {
            guard let value = literals.value(for: name) else { continue }
            let detail =
                style == .namePreview
                ? "\(value.count) characters; \(previewBounds(value))"
                : "\(value.count) characters"
            lines.append("- {{\(name)}} — \(detail)")
        }
        if names.count > maxPreviewed {
            let rest = names.dropFirst(maxPreviewed).map { "{{\($0)}}" }.joined(separator: ", ")
            lines.append("- …and \(names.count - maxPreviewed) more: \(rest)")
        }
        lines.append(usage)
        return lines.joined(separator: "\n")
    }

    /// A compact head/tail preview so the model can tell WHICH content a
    /// placeholder holds without us pasting the whole body back into the prompt.
    private static func previewBounds(_ value: String) -> String {
        let oneLine =
            value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let squeezed = oneLine.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        if squeezed.count <= 64 { return "content: \"\(squeezed)\"" }
        return "begins \"\(squeezed.prefix(36))…\", ends \"…\(squeezed.suffix(20))\""
    }

    /// Re-ask text when the model referenced a `{{name}}` placeholder that
    /// wasn't provided — names the placeholders that ARE available (or that none
    /// are) so it stops guessing instead of running a guaranteed compile error.
    private static func undefinedPlaceholderReason(
        _ name: String,
        literals: AppleScriptLiterals
    ) -> String {
        let available =
            literals.isEmpty
            ? "No content placeholders were provided"
            : "Available placeholders: "
                + literals.names.map { "{{\($0)}}" }.joined(separator: ", ")
        return
            "The placeholder {{\(name)}} isn't available. \(available). Insert an available "
            + "placeholder where the text goes, or write the literal text directly in the script."
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

    static func systemPrompt(
        mode: AppleScriptRunMode = .automate,
        variant: AppleScriptHarnessOptions.PromptVariant = .standard
    ) -> String {
        switch variant {
        case .standard: return standardSystemPrompt(mode: mode)
        case .concise: return conciseSystemPrompt(mode: mode)
        }
    }

    /// The shipped, detailed prompt.
    private static func standardSystemPrompt(mode: AppleScriptRunMode) -> String {
        let intro: String
        let modeRules: String
        switch mode {
        case .automate:
            intro =
                "You are Osaurus's AppleScript agent. You accomplish the user's task on this Mac by "
                + "writing a complete, executable AppleScript and running it."
            modeRules =
                "- After you change something, run ONE more read-only script that gets and `return`s "
                + "the resulting state, so the result can be verified (e.g. after setting the volume, "
                + "return the new volume).\n"
                + "- When you address an app object by name (a note, file, mailbox, playlist), it may "
                + "not exist yet or be named slightly differently; prefer a script that finds or "
                + "creates it (e.g. `if not (exists note \"X\") then make new note`) instead of "
                + "assuming it is there.\n"
                + "- Only do what the task asks. Avoid destructive or irreversible actions (deleting, "
                + "sending, purchasing) unless the user explicitly requested them."
        case .query:
            intro =
                "You are Osaurus's AppleScript query agent. You answer questions about this Mac by "
                + "writing a READ-ONLY AppleScript that gets information and `return`s it. Never change "
                + "anything — no setting properties, creating, deleting, sending, or clicking."
            modeRules =
                "- Every script must be read-only: use `get` / `return` / `count` and property reads "
                + "only. A script that tries to modify state will be blocked, so rewrite it as a read.\n"
                + "- Make your FIRST script a read — never `set`, `make`, `delete`, or click, even as an "
                + "opening step. Read the value directly and `return` it, e.g. `return output volume of "
                + "(get volume settings)` or `tell application \"Safari\" to return URL of front "
                + "document`.\n"
                + "- Always `return` the requested information as your final value."
        }
        return """
            \(intro)

            Rules:
            - To run a script, call the `run_applescript` tool exactly once with the ENTIRE AppleScript \
            in `script`. Do not wrap it in Markdown code fences.
            - You will receive the script's RETURN VALUE, or a compile/runtime error. If it failed, \
            correct the script and call `run_applescript` again.
            - When the task asks for information (a value, state, name, count, list, …), END the script \
            with `return` of exactly those value(s). To return several values, build a string like \
            `return "volume: " & v & ", track: " & t`, or `return` a list — these read back cleanly. \
            A script with no `return` hands back nothing.
            \(modeRules)
            - Script the relevant app directly when it helps (e.g. `tell application "Safari" … end \
            tell`). The first time you control an app, macOS may ask the user to grant Automation \
            permission — that is expected; if a run reports a permission error, try again after the \
            user approves the dialog.
            - When the task is complete, reply with a SHORT plain-text summary that INCLUDES the actual \
            value(s) you found, and do NOT call the tool again. That plain-text reply ends the task.
            - Be efficient: there is a step limit.
            """
    }

    /// A trimmed prompt variant — the same contract at a fraction of the tokens.
    /// A harness sweep lever, not the shipped default.
    private static func conciseSystemPrompt(mode: AppleScriptRunMode) -> String {
        let intro: String
        let modeRule: String
        switch mode {
        case .automate:
            intro =
                "You are Osaurus's AppleScript agent: accomplish the Mac task by writing and running "
                + "one complete AppleScript at a time."
            modeRule =
                "- Address objects that may be missing with find-or-create (`if not (exists note \"X\") "
                + "then make new note`), not by assuming. After a change, run one read-only script that "
                + "`return`s the resulting state. Avoid destructive/irreversible actions unless "
                + "explicitly asked."
        case .query:
            intro =
                "You are Osaurus's AppleScript query agent: answer by writing a READ-ONLY AppleScript "
                + "that `return`s the information. Never change anything."
            modeRule =
                "- Reads only (`get`/`return`/`count`) — make even the FIRST script a read, never "
                + "`set`/`make`/`delete`; e.g. `return output volume of (get volume settings)`. A "
                + "mutation is blocked, so rewrite it as a read."
        }
        return """
            \(intro)

            Rules:
            - Call `run_applescript` once with the ENTIRE script in `script` (no code fences). You get \
            its return value or the real error; fix and call again on failure.
            - For information, END with `return` of exactly the value(s) (a string or list for several); \
            no `return` hands back nothing.
            \(modeRule)
            - The first time you control an app, macOS may prompt for Automation permission; retry after \
            the user approves.
            - Finish with a SHORT plain-text summary that includes the value(s) and no tool call. There \
            is a step limit.
            """
    }
}
