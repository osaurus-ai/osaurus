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
    /// Total wall-clock seconds for the whole run (includes confirmation waits
    /// and script execution).
    public let elapsedSeconds: Double
    /// Seconds spent inside model-generation steps only — the honest
    /// denominator for tokens-per-second (a user sitting on a confirm card
    /// must not dilute the reported generation throughput).
    public let modelSeconds: Double
    /// The last non-empty coerced output across the run (the headline `values`
    /// the parent reads back). Captured on any successful script, including the
    /// verification read-back.
    public let lastOutput: String?
    /// The full per-step transcript (executed + declined + blocked + invalid).
    public let steps: [AppleScriptStepRecord]

    /// The engine's own decode-speed measurement (mean of the per-step
    /// `usage.tokens_per_second` hints), when any step carried one. This is
    /// the AUTHORITATIVE decode number: tool-call turns report
    /// `completion_tokens == 0` by contract, so a tokens/seconds division
    /// over the loop's counters would understate a tool-heavy run.
    public let engineDecodeTokensPerSecond: Double?

    public init(
        outcome: Outcome,
        scriptsExecuted: Int,
        succeeded: Int = 0,
        failed: Int = 0,
        modelTokens: Int,
        elapsedSeconds: Double = 0,
        modelSeconds: Double = 0,
        engineDecodeTokensPerSecond: Double? = nil,
        lastOutput: String?,
        steps: [AppleScriptStepRecord] = []
    ) {
        self.outcome = outcome
        self.scriptsExecuted = scriptsExecuted
        self.succeeded = succeeded
        self.failed = failed
        self.modelTokens = modelTokens
        self.elapsedSeconds = elapsedSeconds
        self.modelSeconds = modelSeconds
        self.engineDecodeTokensPerSecond = engineDecodeTokensPerSecond
        self.lastOutput = lastOutput
        self.steps = steps
    }

    /// Model-generation throughput (tokens per second), or `nil` when the run
    /// spent no measurable time generating (scripted/injected steps). Prefers
    /// the engine's own decode measurement; falls back to the loop-derived
    /// division. Never fabricated: no tokens or no time → no number.
    public var tokensPerSecond: Double? {
        if let engineDecodeTokensPerSecond { return engineDecodeTokensPerSecond }
        guard modelTokens > 0, modelSeconds > 0.001 else { return nil }
        return Double(modelTokens) / modelSeconds
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
/// Carries the script's OSA language (AppleScript / JXA) so the real executor
/// picks the right component; string-keyed mocks can ignore it.
public typealias AppleScriptRunner =
    @Sendable (_ script: String, _ language: AppleScriptLanguage) async ->
    AppleScriptExecutionResult

/// Injectable compile-only dry run for the confirm gate: returns the
/// `.compileError` execution result when the script can't compile (fed back to
/// the model instead of asking the user to approve an un-runnable script), or
/// `nil` when it compiles / the check is unavailable. Production defaults to
/// the real `AppleScriptExecutor.compileCheck`; mock-executor runs default to
/// no check (a mock world has no OSA syntax to protect).
public typealias AppleScriptCompileCheck =
    @Sendable (_ script: String, _ language: AppleScriptLanguage) async ->
    AppleScriptExecutionResult?

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
    /// Whether to inject the target app's distilled scripting dictionary
    /// (sdef) when the caller provides it (shipped: on). Sweepable via
    /// `OSAURUS_AS_DICTIONARY_CONTEXT` — the model stops guessing vocabulary,
    /// the biggest reducer of compile/runtime errors.
    public var includeDictionaryContext: Bool
    /// Whether to inject the per-app AppleScript recipe tips when the caller
    /// provides them (shipped: on). Sweepable via `OSAURUS_AS_APP_RECIPES`.
    public var includeAppRecipes: Bool
    /// Which system-prompt phrasing to use (shipped: `.standard`).
    public var promptVariant: PromptVariant
    /// How provided-content placeholders are announced (shipped: `.nameOnly`).
    public var literalAnnouncementStyle: LiteralAnnouncementStyle

    public init(
        verifyReadBack: Bool = true,
        includeDesktopContext: Bool = true,
        includeDictionaryContext: Bool = true,
        includeAppRecipes: Bool = true,
        promptVariant: PromptVariant = .standard,
        literalAnnouncementStyle: LiteralAnnouncementStyle = .nameOnly
    ) {
        self.verifyReadBack = verifyReadBack
        self.includeDesktopContext = includeDesktopContext
        self.includeDictionaryContext = includeDictionaryContext
        self.includeAppRecipes = includeAppRecipes
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
        dictionaryContext: String? = nil,
        recipeContext: String? = nil,
        literals: AppleScriptLiterals = AppleScriptLiterals(),
        harness: AppleScriptHarnessOptions = .default,
        execute: AppleScriptRunner? = nil,
        nextScript: AppleScriptStepProvider? = nil,
        observeProposal: AppleScriptProposalObserver? = nil,
        accessibilityGranted: (@Sendable () -> Bool)? = nil,
        requestAccessibility: (@Sendable () -> Void)? = nil,
        compileCheck: AppleScriptCompileCheck? = nil,
        samplingTemperature: Double? = nil,
        enableThinking: Bool? = nil
    ) async -> AppleScriptRunResult {
        let runStarted = Date()
        let deadline = runStarted.addingTimeInterval(limits.wallClockSeconds)
        let engine: ChatEngine? = nextScript == nil ? ChatEngine(source: .chatUI) : nil
        // Default to the real in-process executor; tests inject their own. Kept
        // out of the (public) default argument because `AppleScriptExecutor` is
        // internal and a public default value can't reference an internal symbol.
        let runExecutor: AppleScriptRunner =
            execute ?? { await AppleScriptExecutor.run(source: $0, language: $1) }
        // Compile-before-confirm dry run: real OSA compile when the real
        // executor runs the scripts; no check for an injected mock executor
        // (deterministic tests, no OSA dependency) unless the caller injects
        // its own checker.
        let dryCompile: AppleScriptCompileCheck?
        if let compileCheck {
            dryCompile = compileCheck
        } else if execute == nil {
            dryCompile = { await AppleScriptExecutor.compileCheck(source: $0, language: $1) }
        } else {
            dryCompile = nil
        }
        // Accessibility preflight seams. The REAL check/prompt guards only the
        // real OS executor: a mock world has no OS to protect, so an injected
        // executor defaults to "granted" and stays deterministic. Tests of the
        // preflight itself inject both closures explicitly.
        let axGranted: @Sendable () -> Bool
        let axPrompt: @Sendable () -> Void
        if let accessibilityGranted {
            axGranted = accessibilityGranted
        } else if execute == nil {
            axGranted = { AppleScriptAccessibility.isGranted() }
        } else {
            axGranted = { true }
        }
        if let requestAccessibility {
            axPrompt = requestAccessibility
        } else if execute == nil {
            // Fire-and-forget: the TCC dialog must attach on the main actor.
            axPrompt = { Task { @MainActor in AppleScriptAccessibility.promptForGrant() } }
        } else {
            axPrompt = {}
        }

        var systemContent = systemPrompt(mode: mode, variant: harness.promptVariant)
        if harness.includeDesktopContext, let environmentContext, !environmentContext.isEmpty {
            systemContent += "\n\nCurrent desktop:\n\(environmentContext)"
        }
        // App knowledge (caller-composed, harness-gated): the target app's
        // distilled scripting dictionary + curated per-app idiom tips, so the
        // model writes against the app's REAL vocabulary instead of guessing.
        if harness.includeDictionaryContext, let dictionaryContext, !dictionaryContext.isEmpty {
            systemContent += "\n\n\(dictionaryContext)"
        }
        if harness.includeAppRecipes, let recipeContext, !recipeContext.isEmpty {
            systemContent += "\n\n\(recipeContext)"
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
        // Seconds spent inside model-generation steps only, so token/s reflects
        // generation throughput rather than confirm-wait / execution time.
        var modelSeconds = 0.0
        // Per-step engine decode-speed hints (`usage.tokens_per_second`) — the
        // authoritative token/s source (tool-call turns carry no completion
        // token count by contract, so counter division would understate).
        var decodeRates: [Double] = []
        var lastOutput: String? = nil
        // A raw return from a mutating script remains part of the public run
        // result, but only a read step can verify requested state.
        var lastReadOutput: String? = nil
        var consecutiveInvalid = 0
        var consecutiveLiteralFailures = 0
        var consecutiveBlocked = 0
        // Consecutive confirm-gate dry-compile failures. Bounded separately so
        // a model stuck on syntax terminates with the real reason (the compile
        // error) instead of ping-ponging until the wall clock. Reset when a
        // script compiles.
        var consecutiveCompileFailures = 0
        // UI-scripting proposals stopped by the Accessibility preflight. Bounded
        // separately from read-only blocks so the termination reason names the
        // real blocker (the missing permission, not "invalid actions").
        var accessibilityBlocked = 0
        // The OS grant dialog fires at most once per run — repeats would stack
        // no new information on the user.
        var accessibilityPromptShown = false
        var lastToolResult: String? = nil
        var steps: [AppleScriptStepRecord] = []
        // The one-shot verification read-back: when a data task finished without
        // returning a value, we nudge the model to run ONE read-only script that
        // `return`s the requested state. `verifying` forces read-only gating for
        // that follow-up so it never silently mutates or prompts the user.
        var verifyAttempted = false
        var verifying = false
        // One empty/EOS response immediately after a real execution failure
        // gets one bounded chance to emit a corrected tool call. The recovery
        // instruction must preserve the original run mode: a `mac_query`
        // retry stays strictly read-only, while an automation retry may apply
        // only the still-missing requested change. A failed automation script
        // is not evidence that state changed, so it must not enter read-back
        // verification until a mutation actually succeeds.
        var executionRecoveryAttempted = false
        // A reasoning-enabled helper can consume compile-error feedback,
        // reason about the repair, and end its turn without the required tool
        // envelope. Nothing ran in that state. Give that exact empty-envelope
        // case one bounded protocol retry; never execute reasoning text or
        // retry a real plain-text explanation.
        var compileEnvelopeRecoveryAttempted = false
        let requiresBlankTextEditDocument =
            mode == .automate && blankTextEditDocumentTask(task: task, literals: literals)
        let blankTextEditDocumentCountBefore: Int?
        if requiresBlankTextEditDocument {
            let observation = await runExecutor(textEditDocumentCountScript, .appleScript)
            blankTextEditDocumentCountBefore = observation.isSuccess
                ? Int(observation.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                : nil
        } else {
            blankTextEditDocumentCountBefore = nil
        }

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
                elapsedSeconds: Date().timeIntervalSince(runStarted),
                modelSeconds: modelSeconds,
                engineDecodeTokensPerSecond: decodeRates.isEmpty
                    ? nil : decodeRates.reduce(0, +) / Double(decodeRates.count),
                lastOutput: lastOutput,
                steps: steps
            )
        }

        // Exact whole-document TextEdit replacement is a deterministic app
        // operation, not an open-ended synthesis problem. The live AppleScript
        // 16B rows either invented replacement bytes despite receiving the
        // authoritative {{content}} placeholder or failed to correct that
        // omission. Before invoking that model, read the actual front document.
        // For old/new replacement, require the live text to contain the supplied
        // old value and compute the complete expected document in Swift. For an
        // explicit whole-document set, the supplied content is already complete.
        // Offer one minimal placeholder-expanded whole-document write through the
        // ordinary user gate, then read OS state back and require an exact match.
        // A read failure, old-value mismatch, other app, missing literals, or
        // ambiguous task keeps the existing model-driven path.
        if mode == .automate,
            let contract = exactTextEditReplacementContract(task: task, literals: literals)
        {
            let beforeObservation = await runExecutor(
                textEditFrontDocumentReadScript,
                .appleScript
            )
            let expectedText: String?
            if let before = beforeObservation.output, let oldText = contract.oldText {
                expectedText = before.contains(oldText)
                    ? before.replacingOccurrences(of: oldText, with: contract.newText)
                    : nil
            } else if contract.oldText == nil {
                expectedText = contract.newText
            } else {
                expectedText = nil
            }
            if beforeObservation.isSuccess, let expectedText {
                let replacementLiterals = AppleScriptLiterals([
                    "replacementDocument": expectedText
                ])
                let proposedScript: String
                if contract.saveRequested {
                    proposedScript = """
                        tell application "TextEdit"
                            set text of front document to {{replacementDocument}}
                            save front document
                        end tell
                        """
                } else {
                    proposedScript =
                        "tell application \"TextEdit\" to set text of front document to "
                        + "{{replacementDocument}}"
                }
                let expansion = replacementLiterals.expand(proposedScript)
                guard expansion.undefinedName == nil else {
                    return terminate(
                        .failed(reason: "The exact TextEdit replacement literal was unavailable.")
                    )
                }
                let script = expansion.script
                let effect = AppleScriptEffectClassifier.classify(
                    proposedScript,
                    language: .appleScript
                )

                observeProposal?(
                    AppleScriptProposalRecord(
                        step: step,
                        proposedScript: proposedScript,
                        expandedScript: script,
                        effect: effectLabelForRecord(effect)
                    )
                )
                feed.emit(
                    SubagentActivityEvent(
                        step: step,
                        kind: .propose,
                        title: "AppleScript (\(effect.displayLabel))",
                        detail: scriptPreview(script)
                    )
                )

                if let dryCompile,
                    let compileFailure = await dryCompile(script, .appleScript),
                    compileFailure.status == .compileError
                {
                    let message = compileFailure.errorMessage ?? "syntax error"
                    record(
                        intent: effect,
                        status: "compile_error",
                        error: message,
                        errorNumber: compileFailure.errorNumber,
                        script: script
                    )
                    return terminate(
                        .failed(reason: "The exact TextEdit replacement did not compile: \(message)")
                    )
                }

                let gate = gateDecision(
                    mode: mode,
                    executionMode: executionMode,
                    effect: effect,
                    verifying: false
                )
                let approved: Bool
                switch gate {
                case .confirm:
                    AppleScriptTraceLog.recordGate(
                        mode: mode,
                        executionMode: executionMode,
                        effect: effect,
                        verifying: false,
                        decision: "confirm_exact_textedit"
                    )
                    let preview = ActionPreview(
                        appName: "TextEdit",
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
                case .autoRunWithWarning:
                    AppleScriptTraceLog.recordGate(
                        mode: mode,
                        executionMode: executionMode,
                        effect: effect,
                        verifying: false,
                        decision: "auto_warning_exact_textedit"
                    )
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
                case .autoRunReadOnly, .block:
                    // An edit in automate mode cannot legitimately resolve to
                    // either branch. Fail closed rather than bypassing policy.
                    approved = false
                }

                guard approved else {
                    record(intent: effect, status: "declined", script: script)
                    return terminate(.failed(reason: "The user declined the TextEdit replacement."))
                }
                feed.emit(
                    SubagentActivityEvent(
                        step: step,
                        kind: .confirmed,
                        title: "Approved: Run AppleScript"
                    )
                )
                feed.emit(
                    SubagentActivityEvent(step: step, kind: .act, title: "Running AppleScript")
                )

                let execution = await runExecutor(script, .appleScript)
                scriptsExecuted += 1
                let trimmedOutput = execution.output?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if execution.isSuccess {
                    succeeded += 1
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
                guard execution.isSuccess else {
                    return terminate(
                        .failed(
                            reason: execution.errorMessage
                                ?? "The exact TextEdit replacement failed to execute."
                        )
                    )
                }

                let afterObservation = await runExecutor(
                    textEditFrontDocumentReadScript,
                    .appleScript
                )
                let after = afterObservation.isSuccess ? afterObservation.output : nil
                let matched = after == expectedText
                steps.append(
                    AppleScriptStepRecord(
                        n: steps.count + 1,
                        intent: "read",
                        status: matched ? "success" : "verification_mismatch",
                        output: after,
                        error: matched
                            ? nil
                            : "The live TextEdit front document did not match the requested replacement.",
                        scriptPreview: scriptPreview(textEditFrontDocumentReadScript)
                    )
                )
                guard matched, let after else {
                    return terminate(
                        .failed(
                            reason:
                                "The live TextEdit front document did not match the requested replacement."
                        )
                    )
                }

                lastOutput = after
                lastReadOutput = after
                feed.emit(
                    SubagentActivityEvent(
                        step: step,
                        kind: .verify,
                        title: "Verified TextEdit replacement",
                        detail: scriptPreview(after),
                        success: true
                    )
                )
                let summary = completionSummary(
                    modelText: nil,
                    lastOutput: after,
                    scriptsExecuted: scriptsExecuted,
                    succeeded: succeeded,
                    failed: failed
                )
                return terminate(.done(summary: summary))
            }
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
                    messages: stepMessages,
                    samplingTemperature: samplingTemperature,
                    enableThinking: enableThinking
                )
            }

            let stepResult: ModelStepResult
            let modelStepStarted = Date()
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
            modelSeconds += Date().timeIntervalSince(modelStepStarted)
            if let rate = stepResult.tokensPerSecond, rate > 0 { decodeRates.append(rate) }

            // No tool call → the model is done. Before accepting completion, run
            // the one-shot verification read-back when a data task produced no
            // value, so the parent gets a REAL result instead of "completed".
            guard let call = stepResult.call else {
                let text = stepResult.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                // A few dedicated AppleScript bundles occasionally emit the
                // complete script as assistant text instead of wrapping it in
                // `run_applescript`. Treat only structurally script-like text
                // as a malformed call and ask for the required envelope. A
                // normal plain-text explanation still ends the run. This is a
                // protocol repair, not an execution shortcut: the raw text is
                // never run or counted as successful work.
                if let text, looksLikeUncalledScript(text) {
                    consecutiveInvalid += 1
                    let reason =
                        "You wrote AppleScript as plain text, so nothing ran. Call `run_applescript` "
                        + "with that complete script in its `script` argument. Do not print the script."
                    feed.emit(
                        SubagentActivityEvent(
                            step: step,
                            kind: .retry,
                            title: "Script was not called; requesting the tool envelope",
                            detail: scriptPreview(text)
                        )
                    )
                    steps.append(
                        AppleScriptStepRecord(
                            n: steps.count + 1,
                            intent: "unknown",
                            status: "invalid",
                            error: reason,
                            scriptPreview: scriptPreview(text)
                        )
                    )
                    if consecutiveInvalid >= limits.maxConsecutiveInvalid {
                        return terminate(
                            .failed(
                                reason:
                                    "The model kept writing AppleScript without calling "
                                    + "run_applescript."
                            )
                        )
                    }
                    messages.append(ChatMessage(role: "assistant", content: text))
                    messages.append(ChatMessage(role: "user", content: reason))
                    lastToolResult = reason
                    step += 1
                    continue
                }
                let haveValue = !(lastReadOutput?.isEmpty ?? true)
                let emptyCompletion = text?.isEmpty ?? true
                if succeeded == 0, failed == 0, consecutiveCompileFailures > 0,
                    !compileEnvelopeRecoveryAttempted, emptyCompletion
                {
                    compileEnvelopeRecoveryAttempted = true
                    feed.emit(
                        SubagentActivityEvent(
                            step: step,
                            kind: .retry,
                            title: "Compile repair omitted the tool call; requesting the envelope"
                        )
                    )
                    let nudge =
                        "The prior script still did not compile and nothing ran. Your last response "
                        + "ended without a run_applescript call. Call run_applescript ONE more time "
                        + "with a complete corrected script. If you cannot correct it, reply with a "
                        + "short plain-text explanation instead; do not return reasoning alone."
                    messages.append(ChatMessage(role: "user", content: nudge))
                    lastToolResult = nudge
                    step += 1
                    continue
                }
                if succeeded == 0, failed > 0, !executionRecoveryAttempted, emptyCompletion {
                    executionRecoveryAttempted = true
                    feed.emit(
                        SubagentActivityEvent(
                            step: step,
                            kind: .retry,
                            title: "Execution failed; requesting one corrected tool call"
                        )
                    )
                    let nudge: String
                    switch mode {
                    case .query:
                        nudge =
                            "The prior read-only script reported failure and the requested result is "
                            + "not available. Call run_applescript ONE more time with a corrected "
                            + "READ-ONLY script that only reads current state and returns the exact "
                            + "requested value(s). Do not change, type, open, close, or save anything. "
                            + "If you cannot correct it, reply with a short explanation."
                    case .automate:
                        nudge =
                            "The prior script reported failure and the requested result is not verified. "
                            + "Do not assume either that it completed or that state is unchanged. Call "
                            + "run_applescript ONE more time with an idempotent corrected script that "
                            + "reads current state and applies only the missing requested change. Use every "
                            + "required {{name}} placeholder instead of typing its name or value. If you "
                            + "cannot correct it, reply with a short explanation."
                    }
                    messages.append(ChatMessage(role: "user", content: nudge))
                    lastToolResult = nudge
                    step += 1
                    continue
                }
                if requiresBlankTextEditDocument {
                    return terminate(
                        .failed(
                            reason:
                                "TextEdit did not reach a verified blank editable document. "
                                + "The Open window must be closed and a new document must be frontmost."
                        )
                    )
                }
                if harness.verifyReadBack, !verifyAttempted, !haveValue, succeeded > 0,
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
                    lastOutput: shouldVerify(mode: mode, task: task)
                        ? lastReadOutput : lastOutput,
                    scriptsExecuted: scriptsExecuted,
                    succeeded: succeeded,
                    failed: failed
                )
                // A plain-text completion after attempted work does not erase
                // its real outcome. `steps` also includes malformed tool calls
                // and compile/placeholder rejections that never reached the
                // executor, so do not mistake `scriptsExecuted == 0` for a
                // clean no-tool explanation when such attempts exist.
                if succeeded == 0, scriptsExecuted > 0 || !steps.isEmpty {
                    let reason: String
                    if scriptsExecuted == 0 {
                        let detail = steps.last?.error ?? "The generated script call was invalid."
                        reason = "No valid script executed successfully. \(detail)"
                    } else {
                        reason = summary
                    }
                    return terminate(.failed(reason: reason))
                }
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
            guard case .script(let proposedScript, let language) = decoded else {
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
            let proposedEffect = AppleScriptEffectClassifier.classify(
                proposedScript,
                language: language
            )

            // Exact user values are deliberately withheld from the helper and
            // exposed only as placeholders. A script that invents replacement
            // bytes instead of consuming {{newText}} or the single supplied
            // {{content}} value would mutate the app with model-invented data.
            // Reject it before compile, approval, or execution; this is data-
            // contract validation, not script repair.
            if !verifying, proposedEffect != .read,
                let missingName = missingRequiredMutationPlaceholder(
                    in: proposedScript,
                    literals: literals
                )
            {
                consecutiveLiteralFailures += 1
                let reason =
                    "The script omitted the required {{\(missingName)}} placeholder. Put "
                    + "{{\(missingName)}} exactly where that provided value belongs; do not type "
                    + "the placeholder name or reconstruct its value."
                feed.emit(
                    SubagentActivityEvent(
                        step: step,
                        kind: .retry,
                        title: "Required replacement placeholder missing",
                        detail: reason
                    )
                )
                steps.append(
                    AppleScriptStepRecord(
                        n: steps.count + 1,
                        intent: "unknown",
                        status: "invalid",
                        error: reason,
                        scriptPreview: scriptPreview(proposedScript)
                    )
                )
                if consecutiveLiteralFailures >= limits.maxConsecutiveInvalid {
                    return terminate(
                        .failed(
                            reason:
                                "The model kept omitting the required replacement placeholder "
                                + "{{\(missingName)}}."
                        )
                    )
                }
                messages.append(
                    ChatMessage(
                        role: "tool",
                        content: reason,
                        tool_calls: nil,
                        tool_call_id: call.id
                    )
                )
                lastToolResult = reason
                step += 1
                continue
            }

            // TextEdit persistence is opt-in. `save`, Command-S, Save-menu
            // automation, closing-with-save, and clearing the document's dirty
            // flag all persist or falsely mark the document as persisted. A
            // helper may not add any of those when the user's task did not ask
            // to save. Reject the proposal before it reaches the approval UI so
            // a correct edit cannot be followed by an invented save workflow.
            if !verifying, proposedEffect != .read,
                let persistenceOperation = unrequestedTextEditPersistenceOperation(
                    in: proposedScript,
                    task: task,
                    language: language
                )
            {
                consecutiveInvalid += 1
                let reason =
                    "The script added an unrequested TextEdit persistence operation "
                    + "(\(persistenceOperation)). Remove it and apply only the requested edit; "
                    + "do not save or clear the document's changed state."
                feed.emit(
                    SubagentActivityEvent(
                        step: step,
                        kind: .retry,
                        title: "Unrequested TextEdit save rejected",
                        detail: reason
                    )
                )
                steps.append(
                    AppleScriptStepRecord(
                        n: steps.count + 1,
                        intent: "unknown",
                        status: "invalid",
                        error: reason,
                        scriptPreview: scriptPreview(proposedScript)
                    )
                )
                if consecutiveInvalid >= limits.maxConsecutiveInvalid {
                    return terminate(
                        .failed(reason: "The model kept adding an unrequested TextEdit save operation.")
                    )
                }
                messages.append(
                    ChatMessage(
                        role: "tool",
                        content: reason,
                        tool_calls: nil,
                        tool_call_id: call.id
                    )
                )
                lastToolResult = reason
                step += 1
                continue
            }

            // A request for a BLANK TextEdit document authorizes creating the
            // document, not inventing its contents. Reject model-authored
            // example/placeholder text before it reaches the confirmation UI.
            // This is the same user-data boundary as the literal placeholder
            // contract above, scoped only to the confirmed blank-document task.
            if !verifying, proposedEffect != .read,
                let contentOperation = unrequestedBlankTextEditContentOperation(
                    in: proposedScript,
                    task: task,
                    language: language,
                    literals: literals
                )
            {
                consecutiveInvalid += 1
                let reason =
                    "The task requested a blank TextEdit document, but the script added "
                    + "unrequested content (\(contentOperation)). Create the document without "
                    + "typing, setting, or inventing any text."
                feed.emit(
                    SubagentActivityEvent(
                        step: step,
                        kind: .retry,
                        title: "Unrequested TextEdit content rejected",
                        detail: reason
                    )
                )
                steps.append(
                    AppleScriptStepRecord(
                        n: steps.count + 1,
                        intent: "unknown",
                        status: "invalid",
                        error: reason,
                        scriptPreview: scriptPreview(proposedScript)
                    )
                )
                if consecutiveInvalid >= limits.maxConsecutiveInvalid {
                    return terminate(
                        .failed(reason: "The model kept adding text to a requested blank document.")
                    )
                }
                messages.append(
                    ChatMessage(
                        role: "tool",
                        content: reason,
                        tool_calls: nil,
                        tool_call_id: call.id
                    )
                )
                lastToolResult = reason
                step += 1
                continue
            }

            // Classify the proposed script's effect (read / edit / consequential).
            // Escalate-biased + surfaced to the user, never used to fake safety.
            // A JXA script floors at `.edit` (its mutations are statically
            // opaque to the AppleScript verb vocabulary).
            let effect = proposedEffect

            // Expand any {{name}} placeholders into exact, correctly-escaped
            // AppleScript string literals BEFORE preview / gate / execution, so
            // the small model never re-types verbatim content (and can't
            // mis-escape it). Classification ran on the PLACEHOLDER form above,
            // so user content can't trip the escalate-biased classifier.
            let expansion = literals.expand(proposedScript)
            if let undefinedName = expansion.undefinedName {
                consecutiveLiteralFailures += 1
                let reason = undefinedPlaceholderReason(undefinedName, literals: literals)
                feed.emit(
                    SubagentActivityEvent(
                        step: step,
                        kind: .retry,
                        title: "Unknown placeholder {{\(undefinedName)}}",
                        detail: reason
                    )
                )
                if consecutiveLiteralFailures >= limits.maxConsecutiveInvalid {
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
            consecutiveLiteralFailures = 0
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

            // Surface the proposed script (with its language + effect badge) in
            // the feed regardless of gate mode, so the chat row always records
            // what was generated and how risky it is.
            feed.emit(
                SubagentActivityEvent(
                    step: step,
                    kind: .propose,
                    title: "\(language.displayLabel) (\(effect.displayLabel))",
                    detail: scriptPreview(script)
                )
            )

            // Compile every proposal before ANY gate or execution path. The
            // effect classifier is intentionally structural and can classify a
            // malformed script as read-only when its attempted mutation uses
            // invented syntax. Restricting preflight to `.confirm` therefore
            // let those scripts auto-run, compile-fail in the executor, and
            // consume the full step cap. Universal preflight keeps malformed
            // reads and writes out of both the executor and confirmation UI and
            // applies the same bounded correction budget to each.
            if let dryCompile,
                let compileFailure = await dryCompile(script, language),
                compileFailure.status == .compileError
            {
                consecutiveCompileFailures += 1
                let message = compileFailure.errorMessage ?? "syntax error"
                feed.emit(
                    SubagentActivityEvent(
                        step: step,
                        kind: .retry,
                        title: "Script did not compile; asking for a correction",
                        detail: message
                    )
                )
                record(
                    intent: effect,
                    status: "compile_error",
                    error: message,
                    errorNumber: compileFailure.errorNumber,
                    script: script
                )
                if consecutiveCompileFailures >= limits.maxConsecutiveInvalid {
                    return terminate(
                        .failed(
                            reason: "The model could not produce a script that compiles: \(message)"
                        )
                    )
                }
                let toolResult =
                    "The script was NOT run — it does not compile: \(message). Fix the "
                    + "\(language.displayLabel) syntax and call run_applescript again."
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
            consecutiveCompileFailures = 0

            // Accessibility preflight: System Events UI scripting cannot run
            // without the user's Accessibility grant. Catch it BEFORE the gate
            // so the user is never asked to approve a script that can't run,
            // fire the OS grant dialog once (the first-class recovery), and
            // feed the real reason back so the model can prefer the app's own
            // dictionary or finish with an honest explanation.
            if AppleScriptAccessibility.requiresAccessibility(script), !axGranted() {
                accessibilityBlocked += 1
                let detail =
                    "System Events UI scripting needs the Accessibility permission for Osaurus "
                    + "(System Settings → Privacy & Security → Accessibility)."
                feed.emit(
                    SubagentActivityEvent(
                        step: step,
                        kind: .error,
                        title: "Accessibility permission needed",
                        detail: detail,
                        success: false
                    )
                )
                if !accessibilityPromptShown {
                    accessibilityPromptShown = true
                    axPrompt()
                }
                record(intent: effect, status: "permission_required", error: detail, script: script)
                if accessibilityBlocked >= limits.maxConsecutiveInvalid {
                    return terminate(
                        .failed(
                            reason:
                                "The task needs System Events UI scripting, but the Accessibility "
                                + "permission for Osaurus isn't granted. Enable Osaurus under System "
                                + "Settings → Privacy & Security → Accessibility, then try again."
                        )
                    )
                }
                let toolResult =
                    "The script was NOT run: it uses System Events UI scripting, which needs the "
                    + "user's Accessibility permission for Osaurus, and that permission is not "
                    + "granted. macOS is showing the grant request now. If the task can be done "
                    + "through the app's own scripting dictionary instead, do that; otherwise finish "
                    + "with a short explanation that the user must enable Osaurus under System "
                    + "Settings → Privacy & Security → Accessibility and retry."
                messages.append(
                    ChatMessage(role: "tool", content: toolResult, tool_calls: nil, tool_call_id: call.id)
                )
                lastToolResult = toolResult
                step += 1
                continue
            }

            // Gate the script against the mode + effect:
            //  • query / verification → run reads automatically, BLOCK writes.
            //  • automate → the user's confirm-each / auto-run-with-warning policy.
            let approved: Bool
            let gate = gateDecision(
                mode: mode,
                executionMode: executionMode,
                effect: effect,
                verifying: verifying
            )
            let gateLabel: String
            switch gate {
            case .autoRunReadOnly: gateLabel = "auto_read"
            case .autoRunWithWarning: gateLabel = "auto_warning"
            case .confirm: gateLabel = "confirm"
            case .block: gateLabel = "block"
            }
            AppleScriptTraceLog.recordGate(
                mode: mode,
                executionMode: executionMode,
                effect: effect,
                verifying: verifying,
                decision: gateLabel
            )
            switch gate {
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
                // Surface the target app so the confirm card names it AND the
                // shared prompt queue can offer "don't ask again in {app} this
                // run" (it scopes that blanket approval on `appName`).
                let appName = targetAppName(script)
                let actionLabel =
                    language == .javascript ? L("Run JXA script") : L("Run AppleScript")
                let preview = ActionPreview(
                    appName: appName,
                    actionLabel: actionLabel,
                    targetLabel: nil,
                    effect: effect,
                    note: nil,
                    scriptBody: script
                )
                feed.emit(
                    SubagentActivityEvent(
                        step: step,
                        kind: .confirmRequested,
                        title: "Confirm: \(actionLabel) (\(effect.displayLabel))",
                        detail: scriptPreview(script)
                    )
                )
                approved = await confirm(preview)
                if approved {
                    feed.emit(
                        SubagentActivityEvent(step: step, kind: .confirmed, title: "Approved: \(actionLabel)")
                    )
                } else {
                    feed.emit(
                        SubagentActivityEvent(step: step, kind: .denied, title: "Declined: \(actionLabel)")
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

            feed.emit(
                SubagentActivityEvent(
                    step: step,
                    kind: .act,
                    title: "Running \(language.displayLabel)"
                )
            )
            // The live TextEdit replacement regression exposed a gap in the
            // generic model-authored verification turn: the approved write
            // succeeded, then the dedicated AppleScript model emitted several
            // malformed read-back scripts and the parent retried an already-
            // completed edit. For the narrow exact-replacement contract we
            // already possess both authoritative values and a script targeting
            // TextEdit, observe the real front-document text before the write.
            // A matching post-read below is direct OS evidence, not a synthetic
            // success or prompt coercion. Every other task keeps the existing
            // model-driven verification path.
            let exactTextEditReplacement = exactTextEditReplacementContract(
                task: task,
                literals: literals,
                proposedScript: proposedScript,
                language: language,
                effect: effect
            )
            let textEditBefore: String?
            if exactTextEditReplacement != nil {
                let observation = await runExecutor(textEditFrontDocumentReadScript, .appleScript)
                textEditBefore = observation.isSuccess ? observation.output : nil
            } else {
                textEditBefore = nil
            }
            let execution = await runExecutor(script, language)
            scriptsExecuted += 1
            consecutiveBlocked = 0
            // An assistive-access denial that slipped past the preflight (an
            // unrecognized UI-scripting form) still gets the first-class
            // recovery: fire the OS grant dialog once, same as the preflight.
            if execution.status == .permissionRequired,
                AppleScriptAccessibility.isAccessibilityDenial(
                    errorNumber: execution.errorNumber,
                    errorMessage: execution.errorMessage
                ),
                !accessibilityPromptShown
            {
                accessibilityPromptShown = true
                axPrompt()
            }
            let toolResult = describe(execution, feed: feed, step: step)
            let trimmedOutput = execution.output?.trimmingCharacters(in: .whitespacesAndNewlines)
            if execution.isSuccess {
                succeeded += 1
                // Only a read result is evidence for a requested value or
                // post-action state. A mutating script can `return` any string
                // without having applied it (the JANG_6M TextEdit reproduction
                // returned the requested text from a local variable while the
                // document remained unchanged). Keep that output in the step
                // transcript, but require a later read for verification.
                if let trimmedOutput, !trimmedOutput.isEmpty {
                    lastOutput = trimmedOutput
                    if effect == .read { lastReadOutput = trimmedOutput }
                }
                // A task that names a readable postcondition (replace/change/
                // exact content, a requested value, etc.) must not execute a
                // second mutation before that state is read back. The small
                // AppleScript models can otherwise interpret a successful OS
                // execution as permission to repeat or embellish the same
                // edit. Enter the verification gate immediately: subsequent
                // reads are allowed, while another write is rejected before
                // approval/execution.
                if effect != .read, shouldVerify(mode: mode, task: task) {
                    verifying = true
                }
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

            if execution.isSuccess,
                let contract = exactTextEditReplacement,
                let before = textEditBefore,
                let oldText = contract.oldText
            {
                let observation = await runExecutor(textEditFrontDocumentReadScript, .appleScript)
                let after = observation.isSuccess ? observation.output : nil
                let expected = before.replacingOccurrences(
                    of: oldText,
                    with: contract.newText
                )
                let matched = after == expected
                    && (before.contains(oldText) || expected.contains(contract.newText))
                steps.append(
                    AppleScriptStepRecord(
                        n: steps.count + 1,
                        intent: "read",
                        status: matched ? "success" : "verification_mismatch",
                        output: after,
                        error: matched
                            ? nil
                            : "The live TextEdit front document did not match the requested replacement.",
                        scriptPreview: scriptPreview(textEditFrontDocumentReadScript)
                    )
                )
                if matched, let after {
                    lastOutput = after
                    lastReadOutput = after
                    feed.emit(
                        SubagentActivityEvent(
                            step: step,
                            kind: .verify,
                            title: "Verified TextEdit replacement",
                            detail: scriptPreview(after),
                            success: true
                        )
                    )
                    let summary = completionSummary(
                        modelText: nil,
                        lastOutput: after,
                        scriptsExecuted: scriptsExecuted,
                        succeeded: succeeded,
                        failed: failed
                    )
                    return terminate(.done(summary: summary))
                }
            }

            // `NSAppleScript` success only proves that the script returned; it
            // does not prove TextEdit left its startup Open window. The live
            // regression returned success for `make new document` while the
            // Open panel remained frontmost. For the narrow blank-document
            // contract, require BOTH a document-count increase and live AX
            // evidence of an editable front window with the Open panel gone.
            if execution.isSuccess, requiresBlankTextEditDocument {
                let uiObservation = await runExecutor(
                    textEditBlankDocumentUIStateScript,
                    .appleScript
                )
                let countObservation = await runExecutor(
                    textEditDocumentCountScript,
                    .appleScript
                )
                let uiState = uiObservation.output?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                let afterCount = Int(
                    countObservation.output?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ) ?? ""
                )
                let matched =
                    uiObservation.isSuccess
                    && countObservation.isSuccess
                    && uiState == "editable"
                    && blankTextEditDocumentCountBefore != nil
                    && afterCount != nil
                    && afterCount! > blankTextEditDocumentCountBefore!
                let mismatch =
                    "TextEdit postcondition was not met "
                    + "(ui=\(uiState ?? "unavailable"), "
                    + "documents=\(afterCount.map(String.init) ?? "unavailable"), "
                    + "before=\(blankTextEditDocumentCountBefore.map(String.init) ?? "unavailable"))."
                steps.append(
                    AppleScriptStepRecord(
                        n: steps.count + 1,
                        intent: "read",
                        status: matched ? "success" : "verification_mismatch",
                        output: uiState,
                        error: matched ? nil : mismatch,
                        scriptPreview: scriptPreview(textEditBlankDocumentUIStateScript)
                    )
                )
                if matched {
                    lastOutput = "blank editable document"
                    lastReadOutput = "blank editable document"
                    feed.emit(
                        SubagentActivityEvent(
                            step: step,
                            kind: .verify,
                            title: "Verified blank TextEdit document",
                            detail: "Open window closed; editable document is frontmost.",
                            success: true
                        )
                    )
                    return terminate(
                        .done(summary: "Created a blank editable document in TextEdit.")
                    )
                }

                feed.emit(
                    SubagentActivityEvent(
                        step: step,
                        kind: .retry,
                        title: "TextEdit is not ready for editing",
                        detail: mismatch,
                        success: false
                    )
                )
                let postconditionResult =
                    toolResult + "\n" + mismatch
                    + " Do not type any text. If the standard Open window is still frontmost, "
                    + "click its New Document button first; otherwise create one new document. "
                    + "Call run_applescript with only the missing state transition."
                messages.append(
                    ChatMessage(
                        role: "tool",
                        content: postconditionResult,
                        tool_calls: nil,
                        tool_call_id: call.id
                    )
                )
                lastToolResult = postconditionResult
                step += 1
                continue
            }

            // Do not ask the helper for a free-form terminal turn between an
            // already-successful mutation and the required OS read-back. Gemma
            // 4 AppleScript bundles can answer that `tool_choice:auto` turn
            // with reasoning only even when `enable_thinking=false`; nothing
            // is gained from that turn, and it delays completion before the
            // loop inevitably asks for verification. Advance the real state
            // machine directly to exactly one read-only verification request.
            // The verifier is still model-authored, effect-classified, compiled,
            // and gated; only its redundant predecessor is removed.
            if execution.isSuccess, harness.verifyReadBack, !verifyAttempted,
                effect != .read, shouldVerify(mode: mode, task: task)
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
                    "The requested change ran successfully. Run ONE READ-ONLY AppleScript that "
                    + "gets and `return`s the specific resulting value(s) the task asked for. "
                    + "Reply with a single run_applescript call. Do not change, type, open, close, "
                    + "or save anything during verification."
                messages.append(
                    ChatMessage(
                        role: "tool",
                        content: toolResult,
                        tool_calls: nil,
                        tool_call_id: call.id
                    )
                )
                messages.append(ChatMessage(role: "user", content: nudge))
                lastToolResult = nudge
                step += 1
                continue
            }

            // A successful action-only automation is complete even when the
            // script naturally returns no value (for example `activate`). Asking
            // the small dedicated model for another turn after that point lets
            // it repeat or expand the already-successful mutation until the user
            // declines or the step cap fires. Data-bearing automation tasks keep
            // the existing follow-up and read-back path. A returned value
            // completes a read query, but is not by itself proof that a
            // mutating automation changed state.
            let hasOutput = !(trimmedOutput?.isEmpty ?? true)
            let queryWithValue = mode == .query && hasOutput
            let verifiedValue = verifying && effect == .read && hasOutput
            let actionOnlyAutomation =
                mode == .automate && !shouldVerify(mode: mode, task: task)
            if execution.isSuccess, queryWithValue || verifiedValue || actionOnlyAutomation {
                let summary = completionSummary(
                    modelText: nil,
                    lastOutput: queryWithValue || verifiedValue ? trimmedOutput : nil,
                    scriptsExecuted: scriptsExecuted,
                    succeeded: succeeded,
                    failed: failed
                )
                return terminate(.done(summary: summary))
            }

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
            // A classified READ auto-runs with no prompt or warning even in
            // automate mode: the escalate-biased classifier only rates a script
            // `.read` when it has no mutating verb / app-state write / writing
            // shell command, so gating a pure read like a mutation is pure
            // friction with no safety value — it's the same property the
            // read-only `mac_query` gate already relies on. This roughly halves
            // confirmations on the common read-then-write and verification
            // patterns.
            if effect == .read { return .autoRunReadOnly }
            // A CONSEQUENTIAL script (destructive shell, delete/send/purchase,
            // quit/restart, running a user Shortcut — whose effect is opaque)
            // always pauses for explicit approval, even when the user chose
            // auto-run-with-warning: that mode trades confirmation for a
            // warning on ordinary edits, not on irreversible or trust-boundary
            // commits. This is the whole point of escalating classification —
            // an `rm -rf` must never run on a warning banner alone.
            if effect == .consequential { return .confirm }
            switch executionMode {
            case .confirmEach: return .confirm
            case .autoRunWithWarning: return .autoRunWithWarning
            }
        }
    }

    /// The first application a script targets via `tell application "Name"` (or
    /// `tell app "Name"`). Used to label the confirm card's App field and to
    /// scope the user's "don't ask again in {app} this run" approval, which the
    /// shared `ComputerUsePromptQueue` keys on `ActionPreview.appName`. `nil`
    /// when the script targets no named app (e.g. a bare `set volume …` system
    /// command), so appless scripts simply keep prompting each time.
    static func targetAppName(_ script: String) -> String? {
        // AppleScript app names are quoted string literals, so a quoted capture
        // after `tell application` / `tell app` is exact; JXA addresses the app
        // as `Application("Name")` / `Application('Name')`. Case-insensitive;
        // returns the first match.
        let patterns = [
            #"tell\s+application\s+"([^"]+)""#,
            #"tell\s+app\s+"([^"]+)""#,
            #"application\(\s*"([^"]+)"\s*\)"#,
            #"application\(\s*'([^']+)'\s*\)"#,
        ]
        for pattern in patterns {
            guard
                let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }
            let range = NSRange(script.startIndex ..< script.endIndex, in: script)
            guard let match = regex.firstMatch(in: script, options: [], range: range),
                match.numberOfRanges >= 2,
                let captured = Range(match.range(at: 1), in: script)
            else { continue }
            let name = String(script[captured]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return nil
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
            // Exact/verbatim mutations need a post-action read. Do not
            // classify them as fire-and-forget only because they are phrased
            // as commands rather than questions.
            "exactly", "contain", "insert ", "write ", "type ",
            "replace", "change the text", "edit the text", "remove the text",
        ]
        return dataIntent.contains { t.contains($0) }
    }

    private struct ExactTextEditReplacementContract {
        let oldText: String?
        let newText: String
        let saveRequested: Bool
    }

    private static let textEditFrontDocumentReadScript =
        #"tell application "TextEdit" to get text of front document"#
    private static let textEditDocumentCountScript =
        #"tell application "TextEdit" to count documents"#
    private static let textEditBlankDocumentUIStateScript = """
        tell application "System Events"
            tell process "TextEdit"
                if exists window "Open" then return "open_panel"
                if (count of windows) is 0 then return "no_window"
                if exists text area 1 of scroll area 1 of window 1 then return "editable"
                return "no_editable_document"
            end tell
        end tell
        """

    static func blankTextEditDocumentTask(
        task: String,
        literals: AppleScriptLiterals
    ) -> Bool {
        guard literals.isEmpty else { return false }
        let normalized = task.lowercased()
        guard normalized.contains("textedit") else { return false }
        let creationIntent =
            normalized.range(
                of: #"\b(?:create|make|open)\s+(?:a\s+)?(?:new|blank)\s+(?:plain\s+text\s+)?document\b"#,
                options: .regularExpression
            ) != nil
        guard creationIntent else { return false }
        let contentIntent: [String] = [
            "contain", " with ", "that says", "and type", "and write", "and enter",
            "and put", "insert ", "add the text", "content:",
        ]
        return !contentIntent.contains { normalized.contains($0) }
    }

    private static func exactTextEditReplacementContract(
        task: String,
        literals: AppleScriptLiterals
    ) -> ExactTextEditReplacementContract? {
        let normalizedTask = task.lowercased()
        guard normalizedTask.contains("textedit") else { return nil }
        let saveRequested = explicitlyRequestsSave(normalizedTask)

        if let oldText = literals.value(for: "oldText"),
            let newText = literals.value(for: "newText"),
            normalizedTask.contains("replace")
                || normalizedTask.range(
                    of: #"\bchange(?:\s+only)?\s+the\s+text\b"#,
                    options: .regularExpression
                ) != nil
                || normalizedTask.contains("edit the text")
        {
            return ExactTextEditReplacementContract(
                oldText: oldText,
                newText: newText,
                saveRequested: saveRequested
            )
        }

        let wholeDocumentIntent =
            normalizedTask.contains("entire contents")
            || normalizedTask.contains("entire content")
            || normalizedTask.contains("entire text")
            || normalizedTask.contains("whole document")
        guard wholeDocumentIntent, let content = literals.value(for: "content") else { return nil }
        return ExactTextEditReplacementContract(
            oldText: nil,
            newText: content,
            saveRequested: saveRequested
        )
    }

    /// Saving is opt-in. A task may contain the word "save" in an explicit
    /// prohibition, so a bare substring check would recreate the reported
    /// unrequested-save regression. Only a positive save request enables the
    /// deterministic replacement path's `save front document` statement.
    private static func explicitlyRequestsSave(_ normalizedTask: String) -> Bool {
        guard normalizedTask.range(of: #"\bsav(?:e|ing)\b"#, options: .regularExpression) != nil
        else { return false }
        let negativeSave =
            #"\b(?:do\s+not|don't|dont|never)\s+save\b|\bwithout\s+saving\b|\b(?:leave|keep)\b.{0,24}\bunsaved\b"#
        return normalizedTask.range(of: negativeSave, options: .regularExpression) == nil
    }

    /// Recognize only the confirmed TextEdit exact-replacement contract. The
    /// task must name TextEdit and replacement intent, the parent must have
    /// supplied both authoritative literals, and the generated mutation must
    /// itself target TextEdit. This deliberately does not become a global
    /// postcondition guess for other apps or ambiguous automation tasks.
    private static func exactTextEditReplacementContract(
        task: String,
        literals: AppleScriptLiterals,
        proposedScript: String,
        language: AppleScriptLanguage,
        effect: EffectClass
    ) -> ExactTextEditReplacementContract? {
        guard language == .appleScript, effect != .read,
            targetAppName(proposedScript)?.caseInsensitiveCompare("TextEdit") == .orderedSame,
            let contract = exactTextEditReplacementContract(task: task, literals: literals)
        else { return nil }
        return contract
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
            // Two distinct grants map here: the Automation/Apple Events consent
            // (`-1743`, auto-prompted by the OS at send time) and the
            // Accessibility grant System Events UI scripting needs (the loop
            // fires that dialog itself). Name the right one so the model and
            // the user recover down the correct path.
            if AppleScriptAccessibility.isAccessibilityDenial(
                errorNumber: result.errorNumber,
                errorMessage: result.errorMessage
            ) {
                let message = result.errorMessage ?? "Assistive access is required."
                feed.emit(
                    SubagentActivityEvent(
                        step: step,
                        kind: .error,
                        title: "Accessibility permission needed",
                        detail: message,
                        success: false
                    )
                )
                return
                    "macOS blocked the script because it uses System Events UI scripting and the "
                    + "Accessibility permission for Osaurus isn't granted (\(message)). macOS is showing "
                    + "the grant request — once the user enables Osaurus under System Settings → Privacy "
                    + "& Security → Accessibility, call run_applescript again. If the task can be done "
                    + "through the app's own scripting dictionary instead, do that."
            }
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

    /// Detect the confirmed protocol failure where a helper prints executable
    /// AppleScript instead of calling `run_applescript`. Keep this deliberately
    /// structural and multi-line so normal summaries that mention AppleScript
    /// or quote a short command are not converted into tool attempts.
    static func looksLikeUncalledScript(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("\n") else { return false }
        let lower = trimmed.lowercased()
        let hasTellBlock =
            (lower.contains("tell application \"") || lower.contains("tell process \""))
            && lower.contains("end tell")
        let hasHandler = lower.contains("\non ") && lower.contains("\nend ")
        let fencedScript =
            lower.hasPrefix("```applescript") || lower.hasPrefix("```osascript")
        return hasTellBlock || hasHandler || fencedScript
    }

    /// Exact replacement runs cannot safely reconstruct the requested new
    /// bytes: the helper sees only the placeholder name and length. Require
    /// the authoritative new-value token while allowing the old-value token to
    /// be omitted for the valid whole-document direct-set idiom.
    static func missingRequiredMutationPlaceholder(
        in script: String,
        literals: AppleScriptLiterals
    ) -> String? {
        // Preserve the more precise unknown-placeholder diagnostic. The main
        // loop validates undefined tokens immediately after this contract;
        // once the helper corrects that name, this required-value check runs.
        if literals.expand(script).undefinedName != nil { return nil }
        if literals.value(for: "newText") != nil {
            return script.contains("{{newText}}") ? nil : "newText"
        }
        guard literals.names == ["content"] else { return nil }
        return script.contains("{{content}}") ? nil : "content"
    }

    /// Preserve the original narrow helper name for callers/tests that reason
    /// specifically about the two-value replacement contract.
    static func missingRequiredReplacementPlaceholder(
        in script: String,
        literals: AppleScriptLiterals
    ) -> String? {
        guard literals.value(for: "newText") != nil else { return nil }
        return missingRequiredMutationPlaceholder(in: script, literals: literals)
    }

    /// Return the persistence primitive a TextEdit mutation added even though
    /// the user did not opt in to saving. This is deliberately scoped to
    /// AppleScript tasks naming TextEdit; it does not infer save policy for
    /// other apps or JXA.
    static func unrequestedTextEditPersistenceOperation(
        in script: String,
        task: String,
        language: AppleScriptLanguage
    ) -> String? {
        guard language == .appleScript else { return nil }
        let normalizedTask = task.lowercased()
        guard normalizedTask.contains("textedit"), !explicitlyRequestsSave(normalizedTask)
        else { return nil }

        let checks: [(pattern: String, label: String)] = [
            (#"(?i)\bsave\s+(?:(?:front|current)\s+)?document\b"#, "save command"),
            (#"(?i)\bkeystroke\s+[\"“]s[\"”]\s+using\s+\{[^}]*command\s+down"#, "Command-S"),
            (#"(?i)\bclick\s+(?:menu\s+item|button)\s+[\"“]save[\"”]"#, "Save UI action"),
            (#"(?im)^\s*close\b[^\n]*\bsaving\s+(?:yes|true)\b"#, "close-with-save"),
            (
                #"(?im)^\s*set\s+[^\n]*\b(?:changed|modified)\b[^\n]*\bto\s+false\b"#,
                "dirty-state reset"
            ),
        ]
        for check in checks
        where script.range(of: check.pattern, options: .regularExpression) != nil {
            return check.label
        }
        return nil
    }

    /// Return the unauthorized content primitive a model added to a request
    /// that only asked for a blank TextEdit document. Navigation keystrokes
    /// such as Command-N remain allowed; literal typing and document-text
    /// assignments do not.
    static func unrequestedBlankTextEditContentOperation(
        in script: String,
        task: String,
        language: AppleScriptLanguage,
        literals: AppleScriptLiterals
    ) -> String? {
        guard language == .appleScript,
            blankTextEditDocumentTask(task: task, literals: literals)
        else { return nil }

        let checks: [(pattern: String, label: String)] = [
            (
                #"(?i)\bset\s+(?:the\s+)?(?:text|content|contents|body|thetext|value)\s+of\b[^\n]*\bto\b"#,
                "document text assignment"
            ),
            (
                #"(?is)\bmake\s+new\s+document\s+with\s+properties\s+\{[^}]*(?:text|content|contents|body|thetext|value)\s*:"#,
                "document content property"
            ),
            (
                #"(?i)\bkeystroke\s+[\"“](?!n[\"”]\s+using\s+(?:\{[^}]*\bcommand\s+down\b[^}]*\}|\bcommand\s+down\b))[^\"”]+[\"”]"#,
                "typed text"
            ),
        ]
        for check in checks
        where script.range(of: check.pattern, options: .regularExpression) != nil {
            return check.label
        }
        return nil
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
    /// and the token usage (plus the engine's decode-speed hint when present).
    struct ModelStepResult: Sendable {
        var call: ModelActionCall?
        var text: String?
        var tokens: Int = 0
        var tokensPerSecond: Double? = nil
    }

    private static func modelStep(
        engine: ChatEngine,
        modelId: String,
        sessionId: String,
        messages: [ChatMessage],
        samplingTemperature: Double? = nil,
        enableThinking: Bool?
    ) async throws -> ModelStepResult {
        var req = ChatCompletionRequest(
            model: modelId,
            messages: messages,
            temperature: samplingTemperature.map(Float.init),
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
        // Sampling comes from the model bundle's generation_config unless the
        // caller EXPLICITLY overrode it (eval-case-declared A/B, recorded in
        // the report) — never a hidden synthetic default.
        req.samplingParametersAreImplicit = samplingTemperature == nil
        req.isAgentRequest = true
        req.enable_thinking = enableThinking
        let generateStarted = Date()
        let response = try await engine.completeChat(request: req)
        AppleScriptTraceLog.record(
            request: req,
            response: response,
            elapsedSeconds: Date().timeIntervalSince(generateStarted)
        )
        let tokens = response.usage.total_tokens
        let tokensPerSecond = response.usage.tokens_per_second
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
                tokens: tokens,
                tokensPerSecond: tokensPerSecond
            )
        }
        return ModelStepResult(call: nil, text: text, tokens: tokens, tokensPerSecond: tokensPerSecond)
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
                + "- When the task says `the file` or `the document`, use the named Frontmost app in "
                + "Current desktop and its open document. If neither the task nor Current desktop "
                + "identifies an app or exact path, do not open a chooser, create an output file, or "
                + "save anything; reply with one short clarification and no tool call. Editing an "
                + "open document never implies Save, Save As, export, or creating another file.\n"
                + "- When you address an app object by name (a note, file, mailbox, playlist), it may "
                + "not exist yet or be named slightly differently; prefer a script that finds or "
                + "creates it (e.g. `if not (exists note \"X\") then make new note`) instead of "
                + "assuming it is there.\n"
                + "- If an app has no usable scripting dictionary (commands keep failing with "
                + "\"doesn't understand\"), fall back to UI scripting: `activate` the app, then `tell "
                + "application \"System Events\" to tell process \"AppName\"` and drive its menus "
                + "(`click menu item \"Save\" of menu \"File\" of menu bar 1`) or type with "
                + "`keystroke`. Prefer the app's own dictionary whenever it works — UI scripting is "
                + "the fallback, and it needs the user's Accessibility permission (a run will report "
                + "if that is missing).\n"
                + "- Scripts are AppleScript by default. If an app is better driven through its "
                + "JavaScript bridge, set `language` to \"javascript\" in the call to run JXA "
                + "instead. JXA is always gated as state-changing, so use AppleScript for reads.\n"
                + "- The user's installed Shortcuts are runnable: `tell application \"Shortcuts "
                + "Events\" to run shortcut \"Name\"` (add `with input \"…\"` when the task provides "
                + "input; the result is the shortcut's output). List them with `get name of every "
                + "shortcut`. Use the exact shortcut name the user gave.\n"
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
            `return "volume: " & v & ", track: " & t`, `return` a list, or `return` a record like \
            `{volume:v, track:t}` — all read back cleanly (records as `key: value` pairs). \
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
                "- Resolve `the file`/`the document` only from the named Frontmost app in Current "
                + "desktop; if no app/path is identified, ask briefly without a tool call. Never "
                + "invent a chooser, output file, Save, or Save As for an existing-document edit. "
                + "Address other objects that may be missing with find-or-create (`if not (exists note \"X\") "
                + "then make new note`), not by assuming. After a change, run one read-only script that "
                + "`return`s the resulting state. Avoid destructive/irreversible actions unless "
                + "explicitly asked. If an app has no usable dictionary, fall back to System Events UI "
                + "scripting (`tell process`, menus, `keystroke`) — it needs the user's Accessibility "
                + "permission. The user's Shortcuts run via `tell application \"Shortcuts Events\" to "
                + "run shortcut \"Name\"` (optional `with input`)."
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
