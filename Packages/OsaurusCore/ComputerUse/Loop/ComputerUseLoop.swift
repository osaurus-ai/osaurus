//
//  ComputerUseLoop.swift
//  OsaurusCore — Computer Use
//
//  The perceive → decide → gate → act → verify controller. The model only
//  ever decodes one `AgentAction` per step (forced `tool_choice`); the
//  harness owns every deterministic decision: which element the mark maps
//  to, whether the gate allows it, and whether the action actually landed.
//
//  Runs as a nested subagent inside `ComputerUseKind` on the shared
//  `SubagentSession` host (the nested-subagent pattern), so the inner steps
//  never leak into the parent chat transcript — they surface only through the
//  shared `SubagentFeed`.
//

import Foundation

// MARK: - Limits + outcome

/// Termination knobs. Defaults are conservative; PR2/PR3 may tune them off
/// the eval sweep.
public struct RunLimits: Sendable {
    /// Hard cap on productive steps (perceive→act cycles).
    public var maxSteps: Int
    /// Consecutive invalid `agent_action` shapes before giving up (re-ask budget).
    public var maxConsecutiveInvalid: Int
    /// Consecutive reobserve attempts for the same target before it's a dead end.
    public var maxConsecutiveReobserve: Int
    /// Consecutive dead ends before the run terminates.
    public var maxConsecutiveDeadEnd: Int
    /// Wall-clock budget for the whole run.
    public var wallClockSeconds: TimeInterval
    /// Per-model-step inference budget. A single hung inference is aborted (and
    /// retried per `maxInferenceRetries`) instead of stalling until the whole
    /// `wallClockSeconds`. `<= 0` disables the per-step timeout.
    public var modelStepTimeoutSeconds: TimeInterval
    /// Extra attempts after a model-step throws/times out before the run fails.
    /// e.g. `2` means up to three tries total, with a short backoff between.
    public var maxInferenceRetries: Int
    /// Consecutive identical acting actions (same verb+target+payload) before
    /// the run dead-ends as stalled. `<= 0` disables stall detection. Verbs
    /// where repetition is legitimate progress (scroll/observe/wait/find) are
    /// exempt.
    public var maxRepeatedActions: Int

    public init(
        maxSteps: Int = 24,
        maxConsecutiveInvalid: Int = 3,
        maxConsecutiveReobserve: Int = 2,
        maxConsecutiveDeadEnd: Int = 3,
        wallClockSeconds: TimeInterval = 300,
        modelStepTimeoutSeconds: TimeInterval = 90,
        maxInferenceRetries: Int = 2,
        maxRepeatedActions: Int = 4
    ) {
        self.maxSteps = max(1, maxSteps)
        self.maxConsecutiveInvalid = max(1, maxConsecutiveInvalid)
        self.maxConsecutiveReobserve = max(1, maxConsecutiveReobserve)
        self.maxConsecutiveDeadEnd = max(1, maxConsecutiveDeadEnd)
        self.wallClockSeconds = wallClockSeconds
        self.modelStepTimeoutSeconds = modelStepTimeoutSeconds
        self.maxInferenceRetries = max(0, maxInferenceRetries)
        self.maxRepeatedActions = maxRepeatedActions
    }
}

/// How a run ended.
public enum RunOutcome: Sendable, Equatable {
    case done(summary: String)
    case gaveUp(reason: String)
    case stepCapReached
    case deadEnd(reason: String)
    case interrupted
    case failed(reason: String)

    public var isSuccess: Bool { if case .done = self { return true } else { return false } }

    public var summary: String {
        switch self {
        case .done(let s): return s
        case .gaveUp(let r): return L("Gave up: \(r)")
        case .stepCapReached: return L("Stopped: reached the step limit before finishing.")
        case .deadEnd(let r): return L("Stopped: \(r)")
        case .interrupted: return L("Stopped by user.")
        case .failed(let r): return L("Failed: \(r)")
        }
    }
}

// MARK: - Loop

/// Outcome plus the measurement gathered along the way. The tool emits a
/// coarse, privacy-clean summary from `metrics`; the eval harness consumes
/// the full struct.
public struct ComputerUseRunResult: Sendable {
    public let outcome: RunOutcome
    public let metrics: ComputerUseRunMetrics

    public init(outcome: RunOutcome, metrics: ComputerUseRunMetrics) {
        self.outcome = outcome
        self.metrics = metrics
    }
}

// MARK: - Model-step seam

/// One model-proposed action surfaced to the loop: the tool-call id plus the
/// raw `agent_action` arguments JSON. The default provider builds this from the
/// live `ChatEngine`; tests and scripted-model evals build it from a programmed
/// sequence so the whole `run` loop is drivable without a real model.
public struct ModelActionCall: Sendable, Equatable {
    public let id: String
    public let arguments: String

    public init(id: String, arguments: String) {
        self.id = id
        self.arguments = arguments
    }
}

/// A public, redacted projection of the conversation the loop has built so far.
/// Lets an injected `AgentStepProvider` react to the latest tool result (e.g.
/// recover after a rejected action) without exposing the module-internal
/// `ChatMessage` to out-of-module callers (the eval harness imports OsaurusCore
/// non-`@testable`, so the seam cannot reference internal types).
public struct AgentStepInput: Sendable {
    public struct Turn: Sendable, Equatable {
        public let role: String
        public let text: String

        public init(role: String, text: String) {
            self.role = role
            self.text = text
        }
    }

    /// 0-based productive-step index for this decision.
    public let step: Int
    /// The conversation so far as role + text only (images and tool-call
    /// metadata are intentionally omitted).
    public let transcript: [Turn]

    public init(step: Int, transcript: [Turn]) {
        self.step = step
        self.transcript = transcript
    }

    /// The most recent `tool`-role result text, if any — the feedback a
    /// recovering scripted model would key off.
    public var lastToolResult: String? {
        transcript.last(where: { $0.role == "tool" })?.text
    }
}

/// Injectable model step. Returns the next action call, or `nil` to signal the
/// model produced no usable tool call (the loop treats that as a re-ask).
public typealias AgentStepProvider =
    @Sendable (_ input: AgentStepInput) async throws -> ModelActionCall?

public enum ComputerUseLoop {

    /// Upper bound on a single `wait` so a model can't park the run against the
    /// wall clock by requesting a huge pause.
    static let maxWaitSeconds = 10

    /// Bounds on a single `scroll` amount (wheel clicks). The raw model value is
    /// an unbounded 64-bit Int; clamping keeps it positive and inside Int32 so
    /// neither the `Int32(...)` conversion nor the driver's `-amount` negation
    /// can trap.
    static let scrollAmountRange: ClosedRange<Int> = 1 ... 1000

    /// Build a deterministic provider that vends `actions` in order. After the
    /// list is exhausted it repeats the final action (so a miscounted script
    /// can't spin forever — pair it with `RunLimits.maxSteps`); end scripts with
    /// a terminal `done`/`give_up` for a clean outcome.
    public static func scriptedProvider(_ actions: [AgentAction]) -> AgentStepProvider {
        let cursor = ScriptedActionCursor(actions)
        return { _ in await cursor.next() }
    }

    /// Like `scriptedProvider(_:)` but vends raw `agent_action` arguments-JSON
    /// strings in order (the eval scene format). Lets a scripted scenario drive
    /// deliberately malformed steps — the exact bytes — for recovery coverage,
    /// without round-tripping through `AgentAction`. Repeats the final entry
    /// once exhausted; pair with `RunLimits.maxSteps`.
    public static func scriptedProvider(rawArguments: [String]) -> AgentStepProvider {
        let cursor = ScriptedArgumentCursor(rawArguments)
        return { _ in await cursor.next() }
    }

    /// Drive a goal to completion. Pure orchestration over the injected
    /// `MacDriver` / `ComputerUseGating` / confirm surface — no UI, no
    /// registry coupling, so it's fully testable with `MockMacDriver`.
    public static func run(
        goal: String,
        modelId: String,
        driver: MacDriver,
        gate: ComputerUseGating,
        feed: SubagentFeed,
        interrupt: InterruptToken,
        confirm: @escaping @Sendable (ActionPreview) async -> Bool,
        requestCloudVisionConsent: @escaping @Sendable () async -> CloudVisionConsentChoice = {
            .deny
        },
        limits: RunLimits = RunLimits(),
        policySummary: String = "",
        vision: VisionContext = .none,
        sessionId: String,
        nextAction: AgentStepProvider? = nil
    ) async -> ComputerUseRunResult {
        let deadline = Date().addingTimeInterval(limits.wallClockSeconds)
        // Default path drives the live ChatEngine; an injected `nextAction`
        // (tests / scripted-model evals) drives the loop deterministically and
        // never constructs an engine.
        let engine: ChatEngine? = nextAction == nil ? ChatEngine(source: .chatUI) : nil

        // Capture availability once: it gates the escalation ladder (som/vision
        // need Screen Recording) for the whole run.
        let availability = await driver.availability()
        var metrics = ComputerUseRunMetrics()
        // The tier the next AX-resolution capture runs at. Escalates when a target
        // won't resolve; resets to ax once one does.
        var currentTier: CaptureTier = .ax

        // Conversation state.
        var messages: [ChatMessage] = [
            ChatMessage(role: "system", content: systemPrompt(policySummary: policySummary))
        ]
        let contextWindow = await AgentLoopBudget.resolveContextWindow(modelId: modelId)
        let systemChars = messages.first?.content?.count ?? 0
        // Base tool-schema reservation; bumped per-iteration by the in-context
        // image's estimated tokens (the text budget doesn't count image parts).
        let baseToolTokens = 500
        let budgetManager = AgentLoopBudget.makeBudgetManager(
            contextWindow: contextWindow,
            systemPromptChars: systemChars,
            toolTokens: baseToolTokens,
            maxResponseTokens: nil
        )
        let watermark = CompactionWatermark()

        // Driver state. Seed the target from the frontmost app, but never
        // Osaurus itself: `activeWindow()` returns nil when we're frontmost (we
        // can't — and must not — perceive our own UI). Fall back to the app the
        // user was on right before switching to Osaurus (the same working-app
        // hint screen context uses) so a task started from the chat window still
        // has a sensible target instead of none.
        var currentPid: Int32? = await driver.activeWindow()?.pid
        if currentPid == nil {
            currentPid = await FrontmostAppTracker.shared.lastNonSelfPid
        }
        var currentApp: String? = nil
        var lastView: AgentView? = nil
        var lastSnapshot: CUSnapshot? = nil
        // Apps whose recipe hint has already been injected (once per app).
        var hintedApps: Set<String> = []
        // Estimated tokens of the single screenshot currently in context (0 = none).
        var imageTokensInContext = 0
        // Cloud-vision consent state for THIS run. Seeded from the snapshot taken
        // at run start; a just-in-time prompt can flip `granted` true mid-run.
        var runConsent = RunCloudVisionConsent(granted: vision.cloudConsent, asked: false)

        // Initial perception so the model's first turn has something to act on.
        // An empty AX tree (Electron, custom-drawn UI) escalates ax→som→vision
        // when Screen Recording is granted, so turn 1 already carries pixels.
        var initialFrame: CUImage? = nil
        let initialView = await perceiveEscalatingEmptyAX(
            pid: currentPid,
            driver: driver,
            previous: nil,
            availability: availability,
            currentTier: &currentTier,
            pendingFrameImage: &initialFrame,
            metrics: &metrics,
            feed: feed,
            step: 0
        )
        lastView = initialView.view
        lastSnapshot = initialView.snapshot
        if let app = initialView.snapshot?.app { currentApp = app }

        messages.append(
            ChatMessage(
                role: "user",
                content: "Goal: \(goal)\n\nCurrent view:\n"
                    + augmentEmptyAX(initialView.render, view: initialView.view, availability: availability)
            )
        )
        appendAppGuidance(app: currentApp, into: &messages, hinted: &hintedApps)
        if let frame = initialFrame {
            await attachFrame(
                image: frame,
                vision: vision,
                consent: &runConsent,
                requestConsent: requestCloudVisionConsent,
                availability: availability,
                messages: &messages,
                imageTokensInContext: &imageTokensInContext,
                metrics: &metrics,
                feed: feed,
                step: 0
            )
        }

        var step = 0
        var consecutiveInvalid = 0
        var consecutiveDeadEnd = 0
        var lastReobserveTargetKey: String? = nil
        var consecutiveReobserve = 0
        var lastActionSignature: String? = nil
        var repeatedActionCount = 0

        func terminate(_ outcome: RunOutcome) -> ComputerUseRunResult {
            metrics.steps = step
            feed.emit(
                SubagentActivityEvent(
                    step: step,
                    kind: .outcome,
                    title: outcome.summary,
                    success: outcome.isSuccess
                )
            )
            feed.finish(success: outcome.isSuccess, summary: outcome.summary)
            return ComputerUseRunResult(outcome: outcome, metrics: metrics)
        }

        while true {
            // Interrupt / cancellation / wall-clock boundary.
            if interrupt.isInterrupted || Task.isCancelled {
                return terminate(.interrupted)
            }
            if Date() >= deadline {
                return terminate(.deadEnd(reason: "Reached the time limit before finishing."))
            }
            if step >= limits.maxSteps {
                return terminate(.stepCapReached)
            }

            // Decide: force the single agent_action tool. When a screenshot is in
            // context, reserve its estimated tokens so the text trim leaves room.
            var iterationBudget = budgetManager
            if imageTokensInContext > 0 {
                iterationBudget.reserve(.tools, tokens: baseToolTokens + imageTokensInContext)
            }
            let input = AgentLoopBudget.composeIterationMessages(
                messages,
                notices: [],
                manager: iterationBudget,
                watermark: watermark
            )
            // One model step, captured so the timeout + retry wrapper can run it
            // repeatedly without re-deriving the (fixed) iteration messages.
            let stepMessages = input.messages
            let stepIndex = step
            let produce: @Sendable () async throws -> ModelStepResult = {
                if let nextAction {
                    let stepInput = AgentStepInput(
                        step: stepIndex,
                        transcript: projectTranscript(stepMessages)
                    )
                    return ModelStepResult(call: try await nextAction(stepInput), tokens: 0)
                } else {
                    return try await modelStep(
                        engine: engine!,
                        modelId: modelId,
                        sessionId: sessionId,
                        messages: stepMessages
                    )
                }
            }
            let parsed: ModelActionCall?
            do {
                let stepResult = try await runModelStep(
                    produce,
                    timeout: limits.modelStepTimeoutSeconds,
                    maxRetries: limits.maxInferenceRetries,
                    feed: feed,
                    step: step
                )
                metrics.modelTokens += stepResult.tokens
                metrics.recordDecodeTokensPerSecond(stepResult.tokensPerSecond)
                parsed = stepResult.call
            } catch {
                return terminate(.failed(reason: error.localizedDescription))
            }

            // The model ignored the forced tool call and emitted text. Re-ask.
            guard let call = parsed else {
                consecutiveInvalid += 1
                feed.emit(SubagentActivityEvent(step: step, kind: .retry, title: "Model did not call agent_action"))
                if consecutiveInvalid >= limits.maxConsecutiveInvalid {
                    return terminate(.gaveUp(reason: "The model stopped producing valid actions."))
                }
                messages.append(
                    ChatMessage(
                        role: "user",
                        content:
                            "You must respond by calling the agent_action tool with a single action. "
                            + "Do not reply with plain text."
                    )
                )
                continue
            }
            let callId = call.id
            let assistantMessage = ChatMessage(
                role: "assistant",
                content: nil,
                tool_calls: [
                    ToolCall(
                        id: call.id,
                        type: "function",
                        function: ToolCallFunction(name: AgentAction.toolName, arguments: call.arguments)
                    )
                ],
                tool_call_id: nil
            )
            let decoded = AgentAction.decode(argumentsJSON: call.arguments)

            // Invalid shape → bounded re-ask (feed the reason back as a tool result).
            guard case .action(let action) = decoded else {
                consecutiveInvalid += 1
                let reason: String
                if case .invalid(let r) = decoded { reason = r } else { reason = "Invalid action." }
                feed.emit(SubagentActivityEvent(step: step, kind: .retry, title: "Invalid action", detail: reason))
                if consecutiveInvalid >= limits.maxConsecutiveInvalid {
                    return terminate(.gaveUp(reason: "The model could not produce a valid action: \(reason)"))
                }
                messages.append(assistantMessage)
                messages.append(
                    ChatMessage(
                        role: "tool",
                        content: "Your action was rejected: \(reason) Try again with a corrected agent_action.",
                        tool_calls: nil,
                        tool_call_id: callId
                    )
                )
                continue
            }
            consecutiveInvalid = 0
            messages.append(assistantMessage)
            feed.emit(
                SubagentActivityEvent(
                    step: step,
                    kind: .propose,
                    title: action.feedLabel,
                    detail: action.note
                )
            )

            // Terminal verbs end the run immediately.
            if action.verb == .done {
                return terminate(.done(summary: action.reason ?? "Completed."))
            }
            if action.verb == .giveUp {
                return terminate(.gaveUp(reason: action.reason ?? "The goal could not be achieved."))
            }

            // Stall detection. A model that proposes the SAME acting action over
            // and over isn't making progress (the classic "keep clicking a dead
            // button" loop). Verbs where repetition is legitimate — scroll
            // (paging a list), observe, wait (polling async UI), find — are
            // exempt and reset the counter.
            if limits.maxRepeatedActions > 0 {
                if isRepeatProgressVerb(action.verb) {
                    repeatedActionCount = 0
                    lastActionSignature = nil
                } else {
                    let signature = actionSignature(action)
                    if signature == lastActionSignature {
                        repeatedActionCount += 1
                    } else {
                        repeatedActionCount = 1
                        lastActionSignature = signature
                    }
                    if repeatedActionCount >= limits.maxRepeatedActions {
                        metrics.deadEnds += 1
                        return terminate(
                            .deadEnd(
                                reason:
                                    "Repeated the same action (\(action.feedLabel)) "
                                    + "\(repeatedActionCount) times without progress."
                            )
                        )
                    }
                }
            }

            // Build the tool-result that closes this step (new view + outcome).
            var toolResult = ""
            var advancedStep = true
            // A frame captured during an escalated re-perceive, attached to the model
            // AFTER this step's tool result (so tool_call -> tool_result stays intact).
            var pendingFrameImage: CUImage? = nil

            switch action.verb {
            case .observe:
                let p = await perceiveEscalatingEmptyAX(
                    pid: currentPid,
                    driver: driver,
                    previous: lastView,
                    availability: availability,
                    currentTier: &currentTier,
                    pendingFrameImage: &pendingFrameImage,
                    metrics: &metrics,
                    feed: feed,
                    step: step + 1
                )
                lastView = p.view
                lastSnapshot = p.snapshot
                toolResult = augmentEmptyAX(p.render, view: p.view, availability: availability)

            case .wait:
                // Bounded pause for async UI (spinners, loads). Capped so a
                // model can't park the run on the wall clock; then re-perceive
                // so the next turn sees whatever settled.
                let seconds = min(max(action.seconds ?? 1, 0), Self.maxWaitSeconds)
                feed.emit(
                    SubagentActivityEvent(step: step + 1, kind: .act, title: "Wait \(seconds)s for UI to settle")
                )
                if seconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                }
                let p = await perceiveEscalatingEmptyAX(
                    pid: currentPid,
                    driver: driver,
                    previous: lastView,
                    availability: availability,
                    currentTier: &currentTier,
                    pendingFrameImage: &pendingFrameImage,
                    metrics: &metrics,
                    feed: feed,
                    step: step + 1
                )
                lastView = p.view
                lastSnapshot = p.snapshot
                toolResult =
                    "Waited \(seconds)s.\n"
                    + augmentEmptyAX(p.render, view: p.view, availability: availability)

            case .find:
                toolResult = await handleFind(
                    action: action,
                    pid: currentPid,
                    driver: driver,
                    lastView: &lastView,
                    lastSnapshot: &lastSnapshot,
                    feed: feed,
                    step: step + 1
                )

            case .open:
                // `open` is a navigate-class side effect (it launches/focuses an app),
                // so it clears the allowlist + navigate disposition like any other
                // gated action, against the app being opened.
                let openEffect = EffectClassifier.classify(
                    action: action,
                    resolvedRole: nil,
                    resolvedLabel: nil,
                    appName: action.app,
                    recipeSignals: AppRecipes.signals(for: action.app)
                )
                metrics.recordEffect(openEffect)
                let openDecision = await gate.evaluate(
                    action: action,
                    effect: openEffect,
                    appName: action.app,
                    targetLabel: action.app
                )
                if await applyGate(
                    openDecision,
                    action: action,
                    confirm: confirm,
                    toolResult: &toolResult,
                    advancedStep: &advancedStep,
                    metrics: &metrics,
                    feed: feed,
                    step: step + 1
                ) {
                    switch await handleOpen(action: action, driver: driver, feed: feed, step: step + 1) {
                    case .opened(let pid, let app, let view, let snapshot, let render):
                        currentPid = pid
                        currentApp = app
                        lastView = view
                        lastSnapshot = snapshot
                        toolResult = render
                    case .failure(let message):
                        toolResult = "Could not open app: \(message)"
                    }
                }

            case .click, .doubleClick, .rightClick, .drag, .type, .setValue, .clear, .pressKey, .scroll:
                guard let pid = currentPid else {
                    toolResult =
                        "No app is focused yet. Use `open` to launch or switch to an app first, then act."
                    advancedStep = false
                    break
                }
                guard let snapshot = lastSnapshot, let view = lastView else {
                    toolResult = "No current view. Use `observe` first."
                    advancedStep = false
                    break
                }

                // Resolve the element for element-addressed verbs.
                var resolvedElement: CUElement? = nil
                if requiresTarget(action.verb) || action.target != nil {
                    let resolution = TargetResolver.resolve(action.target, view: view, snapshot: snapshot)
                    switch resolution {
                    case .resolved(_, let element):
                        resolvedElement = element
                        metrics.recordResolveAttempt(success: true)
                        consecutiveReobserve = 0
                        lastReobserveTargetKey = nil
                        // Resolved against the AX tree — no pixels needed; drop back to ax.
                        currentTier = .ax
                    case .reobserve(let reason):
                        metrics.recordResolveAttempt(success: false)
                        let key = targetKey(action.target)
                        if key == lastReobserveTargetKey {
                            consecutiveReobserve += 1
                        } else {
                            consecutiveReobserve = 1
                            lastReobserveTargetKey = key
                        }
                        // Escalate the capture tier (ax→som→vision) when allowed, so the
                        // re-perception is richer than the one that just failed.
                        if CaptureRouter.canEscalate(from: currentTier, availability: availability) {
                            currentTier = CaptureRouter.nextTier(
                                current: currentTier,
                                reason: .targetUnresolved,
                                availability: availability
                            )
                            metrics.raiseTier(to: currentTier)
                        }
                        // Re-perceive so the next turn has a fresh view.
                        let p = await perceive(
                            pid: pid,
                            driver: driver,
                            previous: lastView,
                            feed: feed,
                            step: step + 1,
                            tier: currentTier
                        )
                        lastView = p.view
                        lastSnapshot = p.snapshot
                        // If escalation produced pixels, stage them for attachment to the
                        // model after this step's tool result (subject to `VisionContext`).
                        pendingFrameImage = p.snapshot?.image
                        if consecutiveReobserve >= limits.maxConsecutiveReobserve {
                            consecutiveDeadEnd += 1
                            metrics.deadEnds += 1
                            if consecutiveDeadEnd >= limits.maxConsecutiveDeadEnd {
                                return terminate(
                                    .deadEnd(reason: "Could not resolve the target after repeated attempts.")
                                )
                            }
                            toolResult =
                                "Still can't resolve that target after re-looking. \(reason)\nHere is the fresh view:\n"
                                + p.render
                        } else {
                            toolResult = "\(reason)\nHere is the fresh view:\n" + p.render
                        }
                        break
                    case .deadEnd(let reason):
                        metrics.recordResolveAttempt(success: false)
                        consecutiveDeadEnd += 1
                        metrics.deadEnds += 1
                        if consecutiveDeadEnd >= limits.maxConsecutiveDeadEnd {
                            return terminate(.deadEnd(reason: reason))
                        }
                        toolResult = "Dead end: \(reason)"
                        break
                    }
                    // If resolution didn't yield an element, the tool result is already set.
                    if resolvedElement == nil { break }
                }

                // `drag` needs a second resolved element — the destination. Resolve
                // it against the same snapshot so its mark/describe is consistent
                // with the start; on failure, report and let the model retry rather
                // than performing a half-specified drag.
                var destinationElement: CUElement? = nil
                if action.verb == .drag {
                    let destResolution = TargetResolver.resolve(action.to, view: view, snapshot: snapshot)
                    switch destResolution {
                    case .resolved(_, let element):
                        destinationElement = element
                    case .reobserve(let reason), .deadEnd(let reason):
                        toolResult = "Couldn't resolve the drag destination: \(reason)"
                        advancedStep = false
                    }
                    if destinationElement == nil { break }
                }

                // Classify the real effect (verb baseline refined upward by the
                // resolved element + app context), then let the injected gate decide.
                let effect = EffectClassifier.classify(
                    action: action,
                    resolvedRole: resolvedElement?.role,
                    resolvedLabel: resolvedElement?.label,
                    resolvedValue: resolvedElement?.value,
                    resolvedRoleDescription: resolvedElement?.roleDescription,
                    appName: currentApp,
                    recipeSignals: AppRecipes.signals(for: currentApp)
                )
                metrics.recordEffect(effect)
                let targetLabel = resolvedElement.map { describe($0) } ?? action.target?.describe
                let decision = await gate.evaluate(
                    action: action,
                    effect: effect,
                    appName: currentApp,
                    targetLabel: targetLabel
                )
                if await applyGate(
                    decision,
                    action: action,
                    confirm: confirm,
                    toolResult: &toolResult,
                    advancedStep: &advancedStep,
                    metrics: &metrics,
                    feed: feed,
                    step: step + 1
                ) {
                    toolResult = await act(
                        action: action,
                        element: resolvedElement,
                        destinationElement: destinationElement,
                        pid: pid,
                        driver: driver,
                        availability: availability,
                        currentTier: &currentTier,
                        pendingFrameImage: &pendingFrameImage,
                        lastView: &lastView,
                        lastSnapshot: &lastSnapshot,
                        metrics: &metrics,
                        feed: feed,
                        step: step + 1
                    )
                    consecutiveDeadEnd = 0
                }

            case .done, .giveUp:
                break  // handled above
            }

            messages.append(
                ChatMessage(role: "tool", content: toolResult, tool_calls: nil, tool_call_id: callId)
            )
            // The focused app may have changed (e.g. after `open`): inject its recipe
            // hints once, after the tool result so the call/result pairing is intact.
            appendAppGuidance(app: currentApp, into: &messages, hinted: &hintedApps)
            // Attach any escalated-capture frame as a trailing user turn (subject to
            // the VisionContext), again after the tool result for the same reason.
            if let frame = pendingFrameImage {
                await attachFrame(
                    image: frame,
                    vision: vision,
                    consent: &runConsent,
                    requestConsent: requestCloudVisionConsent,
                    availability: availability,
                    messages: &messages,
                    imageTokensInContext: &imageTokensInContext,
                    metrics: &metrics,
                    feed: feed,
                    step: step + 1
                )
            }
            if advancedStep { step += 1 }
        }
    }

    // MARK: - Gate

    /// Apply a gate decision's bookkeeping (feed event + metrics + tool-result)
    /// and report whether the caller should perform the action. Both gated paths
    /// (`open` and the element-addressed verbs) share this so the
    /// block / confirm / decline wording and counters stay identical.
    private static func applyGate(
        _ decision: GateDecision,
        action: AgentAction,
        confirm: (ActionPreview) async -> Bool,
        toolResult: inout String,
        advancedStep: inout Bool,
        metrics: inout ComputerUseRunMetrics,
        feed: SubagentFeed,
        step: Int
    ) async -> Bool {
        switch decision {
        case .reject(let reason):
            metrics.blocked += 1
            feed.emit(
                SubagentActivityEvent(step: step, kind: .blocked, title: "Blocked: \(action.feedLabel)", detail: reason)
            )
            toolResult = "That action is not allowed: \(reason). Choose a different action."
            advancedStep = false
            return false
        case .confirm(let preview):
            metrics.confirmsRequested += 1
            feed.emit(
                SubagentActivityEvent(
                    step: step,
                    kind: .confirmRequested,
                    title: "Confirm: \(preview.summary)",
                    detail: preview.note
                )
            )
            if await confirm(preview) {
                metrics.confirmsApproved += 1
                feed.emit(SubagentActivityEvent(step: step, kind: .confirmed, title: "Approved: \(action.feedLabel)"))
                return true
            }
            metrics.confirmsDeclined += 1
            feed.emit(SubagentActivityEvent(step: step, kind: .denied, title: "Declined: \(action.feedLabel)"))
            toolResult = "The user declined that action. Try a different approach or ask to stop."
            advancedStep = false
            return false
        case .run:
            return true
        }
    }

    // MARK: - Perceive

    private struct Perception {
        let view: AgentView?
        let snapshot: CUSnapshot?
        let render: String
    }

    private static func perceive(
        pid: Int32?,
        driver: MacDriver,
        previous: AgentView?,
        feed: SubagentFeed,
        step: Int,
        tier: CaptureTier = .ax
    ) async -> Perception {
        guard let pid else {
            return Perception(
                view: nil,
                snapshot: nil,
                render: "No app is focused. Use `open` to launch or switch to an app."
            )
        }
        let snapshot = await driver.capture(pid: pid, tier: tier)
        let view = AgentView.build(from: snapshot, previous: previous)
        feed.emit(
            SubagentActivityEvent(
                step: step,
                kind: .perceive,
                title: "Looked at \(snapshot.app)",
                detail: "\(view.items.count) elements" + (view.hasChanges ? " (changed)" : "")
            )
        )
        return Perception(view: view, snapshot: snapshot, render: view.renderForModel())
    }

    /// Perceive, climbing the capture ladder (ax→som→vision) while the AX view
    /// is empty and pixels are available. The frame from the final escalated
    /// capture is staged in `pendingFrameImage` for attachment after the step's
    /// tool result. Bounded by the ladder height (at most two escalations), and
    /// a no-op for a normal, populated view.
    private static func perceiveEscalatingEmptyAX(
        pid: Int32?,
        driver: MacDriver,
        previous: AgentView?,
        availability: MacDriverAvailability,
        currentTier: inout CaptureTier,
        pendingFrameImage: inout CUImage?,
        metrics: inout ComputerUseRunMetrics,
        feed: SubagentFeed,
        step: Int
    ) async -> Perception {
        var perception = await perceive(
            pid: pid,
            driver: driver,
            previous: previous,
            feed: feed,
            step: step,
            tier: currentTier
        )
        while let view = perception.view, view.items.isEmpty,
            let next = CaptureRouter.escalateForEmptyAX(
                currentTier: currentTier,
                itemCount: view.items.count,
                availability: availability
            )
        {
            currentTier = next
            metrics.raiseTier(to: currentTier)
            perception = await perceive(
                pid: pid,
                driver: driver,
                previous: previous,
                feed: feed,
                step: step,
                tier: currentTier
            )
            // Stage the escalated frame; attached after the step's tool result.
            pendingFrameImage = perception.snapshot?.image
        }
        return perception
    }

    /// Append a one-line, actionable note when a perceived view is empty: either
    /// "I took a screenshot" (Screen Recording granted, so escalation produced
    /// pixels) or a clear "grant Screen Recording / try another app" message
    /// (denied, so the loop can't see the contents and the model should pick a
    /// different approach rather than spin).
    private static func augmentEmptyAX(
        _ render: String,
        view: AgentView?,
        availability: MacDriverAvailability
    ) -> String {
        guard view?.items.isEmpty ?? false else { return render }
        return render + "\n" + emptyAXNote(availability: availability)
    }

    private static func emptyAXNote(availability: MacDriverAvailability) -> String {
        if availability.screenRecording {
            return
                "This app exposes no accessibility elements, so I captured a screenshot to look at it "
                + "directly. Locate the control in the image, then address it with `target.describe`."
        }
        return
            "This app exposes no accessibility elements and Screen Recording permission isn't granted, so I "
            + "can't see its contents. Ask the user to grant Screen Recording in System Settings → Privacy & "
            + "Security, or work in a different app."
    }

    // MARK: - Find

    private static func handleFind(
        action: AgentAction,
        pid: Int32?,
        driver: MacDriver,
        lastView: inout AgentView?,
        lastSnapshot: inout CUSnapshot?,
        feed: SubagentFeed,
        step: Int
    ) async -> String {
        guard let pid else { return "No app is focused. Use `open` first." }
        // Route to the driver's server-side query (it can search a richer tree
        // than a plain capture and apply role/text filters at the source). The
        // matches BECOME the current view, so the marks the model is told about
        // resolve against `lastSnapshot` — no second mark space to keep in sync.
        let roles = action.roles.isEmpty ? nil : action.roles
        let found = await driver.find(
            pid: pid,
            text: action.query,
            roles: roles,
            windowId: nil,
            enabledOnly: false,
            limit: 50
        )
        // Build standalone (previous: nil): a narrowed result would otherwise
        // report every element from the prior full view as "removed".
        let view = AgentView.build(from: found, previous: nil)
        feed.emit(
            SubagentActivityEvent(
                step: step,
                kind: .act,
                title: "Find " + (action.query.map { "\"\($0)\"" } ?? "elements"),
                detail: "\(view.items.count) match(es)",
                success: !view.items.isEmpty
            )
        )
        if view.items.isEmpty {
            // Don't strand the model on an empty view — re-perceive the full app
            // so it can keep going (scroll, observe, try a different query).
            let full = await driver.capture(pid: pid, tier: .ax)
            let fullView = AgentView.build(from: full, previous: lastView)
            lastView = fullView
            lastSnapshot = full
            return "No matches. Full view:\n" + fullView.renderForModel()
        }
        lastView = view
        lastSnapshot = found
        return
            "Matches (these are now your current view — address them by mark; `observe` to see everything "
            + "again):\n" + view.renderForModel()
    }

    // MARK: - Open

    private enum OpenResult {
        case opened(pid: Int32, app: String, view: AgentView?, snapshot: CUSnapshot?, render: String)
        case failure(String)
    }

    private static func handleOpen(
        action: AgentAction,
        driver: MacDriver,
        feed: SubagentFeed,
        step: Int
    ) async -> OpenResult {
        guard let identifier = action.app, !identifier.isEmpty else {
            return .failure("missing app name")
        }
        let result = await driver.open(identifier: identifier, background: true)
        switch result {
        case .success(let info):
            let snapshot = await driver.capture(pid: info.pid, tier: .ax)
            let view = AgentView.build(from: snapshot, previous: nil)
            feed.emit(
                SubagentActivityEvent(step: step, kind: .act, title: "Opened \(info.name)", success: true)
            )
            return .opened(
                pid: info.pid,
                app: info.name,
                view: view,
                snapshot: snapshot,
                render: "Opened \(info.name).\n" + view.renderForModel()
            )
        case .failure(let error):
            feed.emit(
                SubagentActivityEvent(
                    step: step,
                    kind: .act,
                    title: "Open \(identifier) failed",
                    detail: error.message,
                    success: false
                )
            )
            return .failure(error.message)
        }
    }

    // MARK: - Act + verify

    /// Internal (not private) so `ComputerUseLoopActTests` can drive the
    /// coordinate-fallback / tier-escalation paths with `MockMacDriver` without
    /// standing up a live model for the whole `run` loop.
    static func act(
        action: AgentAction,
        element: CUElement?,
        destinationElement: CUElement? = nil,
        pid: Int32,
        driver: MacDriver,
        availability: MacDriverAvailability,
        currentTier: inout CaptureTier,
        pendingFrameImage: inout CUImage?,
        lastView: inout AgentView?,
        lastSnapshot: inout CUSnapshot?,
        metrics: inout ComputerUseRunMetrics,
        feed: SubagentFeed,
        step: Int
    ) async -> String {
        metrics.actsAttempted += 1
        var result: CUActionResult
        switch action.verb {
        case .click:
            guard let element else { return "Click needs a resolved target." }
            result = await driver.perform(.click(id: element.id, button: .left, doubleClick: false))
        case .doubleClick:
            guard let element else { return "double_click needs a resolved target." }
            result = await driver.perform(.click(id: element.id, button: .left, doubleClick: true))
        case .rightClick:
            guard let element else { return "right_click needs a resolved target." }
            result = await driver.perform(.click(id: element.id, button: .right, doubleClick: false))
        case .drag:
            guard let element else { return "drag needs a resolved start target." }
            guard let destinationElement else { return "drag needs a resolved destination." }
            let start = element.center
            let end = destinationElement.center
            result = await driver.coordinate(
                .drag(
                    startX: Double(start.x),
                    startY: Double(start.y),
                    endX: Double(end.x),
                    endY: Double(end.y),
                    pid: pid
                )
            )
        case .type:
            result = await driver.perform(
                .typeText(id: element?.id, pid: pid, text: action.text ?? "", replace: action.replace ?? true)
            )
        case .setValue:
            guard let element else { return "set_value needs a resolved target." }
            result = await driver.perform(.setValue(id: element.id, value: action.text ?? ""))
        case .clear:
            guard let element else { return "clear needs a resolved target." }
            result = await driver.perform(.clearField(id: element.id))
        case .pressKey:
            result = await driver.perform(
                .pressKey(pid: pid, key: action.key ?? "", modifiers: action.modifiers)
            )
        case .scroll:
            let dir = action.direction ?? .down
            let amount = Int32((action.amount ?? 3).clamped(to: Self.scrollAmountRange))
            result = await driver.coordinate(
                .scroll(direction: dir, amount: amount, x: nil, y: nil, pid: pid)
            )
        default:
            return "Unsupported action."
        }

        // Coordinate fallback. The element resolved against the immutable
        // snapshot value copy (so `TargetResolver` was happy) but the action
        // failed at the LIVE AX layer because the ref died between capture and
        // act — the signature Electron failure in the Slack trace. The
        // element's last-known frame is still good, so retry at its center,
        // which needs no live ref:
        //   • click → a per-pid coordinate click at the center.
        //   • type / set_value / clear → a coordinate click to FOCUS the field,
        //     then re-issue the edit in pid context (`typeText` with no id),
        //     since an id-addressed edit can't survive a stale ref. set_value
        //     and clear are expressed as a wholesale replace (clear = empty).
        if (result.removed || result.stale), let element {
            let center = element.center
            let cx = Double(center.x)
            let cy = Double(center.y)
            // Emit the retry outcome and adopt it on success (shared shape).
            func adoptRetry(_ retry: CUActionResult) {
                feed.emit(
                    SubagentActivityEvent(
                        step: step,
                        kind: .act,
                        title: "Retry \(action.verb.rawValue) at element center",
                        detail: retry.error,
                        success: retry.success
                    )
                )
                if retry.success { result = retry }
            }
            switch action.verb {
            case .click, .doubleClick, .rightClick:
                metrics.coordinateFallbacks += 1
                let button: CUMouseButton = action.verb == .rightClick ? .right : .left
                let double = action.verb == .doubleClick
                adoptRetry(
                    await driver.coordinate(
                        .click(x: cx, y: cy, button: button, doubleClick: double, pid: pid)
                    )
                )

            case .type, .setValue, .clear:
                metrics.coordinateFallbacks += 1
                let focus = await driver.coordinate(.click(x: cx, y: cy, pid: pid))
                guard focus.success else {
                    feed.emit(
                        SubagentActivityEvent(
                            step: step,
                            kind: .act,
                            title: "Could not focus element for \(action.verb.rawValue) retry",
                            detail: focus.error,
                            success: false
                        )
                    )
                    break
                }
                let text: String
                let replace: Bool
                switch action.verb {
                case .clear: (text, replace) = ("", true)
                case .setValue: (text, replace) = (action.text ?? "", true)
                default: (text, replace) = (action.text ?? "", action.replace ?? true)  // .type
                }
                adoptRetry(
                    await driver.perform(.typeText(id: nil, pid: pid, text: text, replace: replace))
                )

            default:
                break
            }
        }

        feed.emit(
            SubagentActivityEvent(
                step: step,
                kind: .act,
                title: action.feedLabel,
                detail: result.error,
                success: result.success
            )
        )

        // Verify: re-perceive and report the delta. If the action still failed
        // stale/removed even after the coordinate fallback, escalate the capture
        // tier (ax->som->vision) so the re-perception carries pixels the model
        // can use to relocate the target, instead of handing back the same AX
        // view that just failed to resolve.
        var verifyTier: CaptureTier = .ax
        if result.removed || result.stale,
            CaptureRouter.canEscalate(from: currentTier, availability: availability)
        {
            currentTier = CaptureRouter.nextTier(
                current: currentTier,
                reason: .targetUnresolved,
                availability: availability
            )
            metrics.raiseTier(to: currentTier)
            verifyTier = currentTier
        }
        let snapshot = await driver.capture(pid: pid, tier: verifyTier)
        let view = AgentView.build(from: snapshot, previous: lastView)
        lastView = view
        lastSnapshot = snapshot
        // Stage any escalated frame for attachment after this step's tool result.
        if verifyTier != .ax { pendingFrameImage = snapshot.image }
        if view.hasChanges { metrics.verifyChanged += 1 }
        feed.emit(
            SubagentActivityEvent(
                step: step,
                kind: .verify,
                title: view.hasChanges ? "Change detected" : "No visible change",
                success: result.success
            )
        )

        var out = result.success ? "Action succeeded." : "Action failed: \(result.error ?? "unknown")."
        if result.stale { out += " (the element went stale)" }
        if result.removed { out += " (the element was removed)" }
        if let delta = result.delta?.focusedElement {
            out += " Focus moved to \(delta.role)" + (delta.label.map { " \"\($0)\"" } ?? "") + "."
        }
        switch result.routeUsed {
        case .hidFallback:
            out += " (input used the HID fallback, which moved the cursor)"
        case .perPid:
            out += " (input used per-pid routing; a Chromium web-content target may not have received it)"
        case .skyLight, .none:
            break
        }
        out += view.hasChanges ? " The view changed." : " The view looks unchanged."
        out += "\n\nCurrent view:\n" + view.renderForModel()
        return out
    }

    // MARK: - Model step

    /// One model step's result: the proposed call (nil when the model emitted
    /// no usable tool call) plus the token usage that step cost. `Sendable` so
    /// it can cross the timeout/retry task group; `tokens` is `0` for the
    /// scripted seam, which makes no model call.
    struct ModelStepResult: Sendable {
        var call: ModelActionCall?
        var tokens: Int = 0
        /// Decode speed (tok/s) for this model step, read from the response
        /// `usage.tokens_per_second`. `nil` for the scripted seam (no model
        /// call) and for providers that don't report a rate. The loop folds
        /// these into `metrics` so a model-driven CU run records real decode
        /// telemetry (eval harness + diagnostics), not just a token count.
        var tokensPerSecond: Double?
    }

    /// One forced agent_action call. Returns the first matching tool call (or
    /// nil when the model emitted no usable tool call) and the step's token
    /// usage so the run can accumulate a real token total.
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
            tools: [AgentAction.toolSpec],
            tool_choice: AgentAction.forcedToolChoice,
            session_id: sessionId
        )
        req.samplingParametersAreImplicit = true
        req.isAgentRequest = true
        let response = try await engine.completeChat(request: req)
        let tokens = response.usage.total_tokens
        let tps = response.usage.tokens_per_second
        guard let message = response.choices.first?.message else {
            return ModelStepResult(call: nil, tokens: tokens, tokensPerSecond: tps)
        }
        if let calls = message.tool_calls,
            let call = calls.first(where: { $0.function.name == AgentAction.toolName }) ?? calls.first
        {
            return ModelStepResult(
                call: ModelActionCall(id: call.id, arguments: call.function.arguments),
                tokens: tokens,
                tokensPerSecond: tps
            )
        }
        return ModelStepResult(call: nil, tokens: tokens, tokensPerSecond: tps)
    }

    /// Project the internal conversation into the public, redacted turns an
    /// injected `AgentStepProvider` may inspect (role + text only).
    private static func projectTranscript(_ messages: [ChatMessage]) -> [AgentStepInput.Turn] {
        messages.map { AgentStepInput.Turn(role: $0.role, text: $0.content ?? "") }
    }

    // MARK: - Model-step robustness

    /// A model step exceeded its per-step inference budget.
    private struct ModelStepTimeout: Error, LocalizedError {
        var errorDescription: String? { "The model step timed out." }
    }

    /// Run one model step with a per-step timeout and bounded retries. A throw
    /// or timeout is retried (with a short backoff) up to `maxRetries` times
    /// before propagating, so a single transient inference failure or hang
    /// doesn't sink the whole run.
    private static func runModelStep<T: Sendable>(
        _ produce: @escaping @Sendable () async throws -> T,
        timeout: TimeInterval,
        maxRetries: Int,
        feed: SubagentFeed,
        step: Int
    ) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await withModelStepTimeout(timeout, produce)
            } catch is CancellationError {
                throw CancellationError()  // interrupt/teardown — don't retry
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
                // Bounded linear backoff: 0.25s, 0.5s, 0.75s, capped.
                try? await Task.sleep(nanoseconds: UInt64(min(attempt, 4)) * 250_000_000)
            }
        }
    }

    /// Race the model step against a sleep. The first to finish wins; the loser
    /// is cancelled. Cooperative tasks (the scripted test seam, `Task.sleep`)
    /// unwind promptly; a non-cooperative live inference is still bounded by the
    /// run's wall clock.
    private static func withModelStepTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        // A non-finite timeout means "no timeout": run the op without racing a
        // sleep, since UInt64(infinity * ...) would trap.
        guard seconds > 0, seconds.isFinite else { return try await op() }
        return try await withThrowingTaskGroup(of: T.self) { group in
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

    /// Verbs whose repetition is legitimate progress (paging a list, polling
    /// async UI, re-querying), so they're exempt from stall detection.
    private static func isRepeatProgressVerb(_ verb: AgentVerb) -> Bool {
        switch verb {
        case .scroll, .observe, .wait, .find: return true
        default: return false
        }
    }

    /// A stable fingerprint of an acting action, used to detect a model that
    /// keeps proposing the identical step without making progress.
    private static func actionSignature(_ action: AgentAction) -> String {
        [
            action.verb.rawValue,
            targetKey(action.target),
            targetKey(action.to),
            action.text ?? "",
            action.key ?? "",
            action.modifiers.joined(separator: "+"),
            action.direction?.rawValue ?? "",
            action.app ?? "",
        ].joined(separator: "|")
    }

    // MARK: - Helpers

    private static func requiresTarget(_ verb: AgentVerb) -> Bool {
        switch verb {
        case .click, .doubleClick, .rightClick, .drag, .setValue, .clear: return true
        default: return false
        }
    }

    private static func targetKey(_ target: AgentTarget?) -> String {
        guard let target else { return "<none>" }
        if let mark = target.mark { return "mark:\(mark)" }
        if let d = target.describe { return "desc:\(d.lowercased())" }
        return "<empty>"
    }

    private static func describe(_ element: CUElement) -> String {
        var s = element.role
        if let label = element.label, !label.isEmpty { s += " \"\(label)\"" }
        return s
    }

    // MARK: - Vision frame attachment

    /// Mutable cloud-vision consent state for a single run. Seeded from the
    /// `VisionContext` snapshot; `asked` ensures the just-in-time prompt fires at
    /// most once per run, and `granted` records a mid-run grant.
    private struct RunCloudVisionConsent {
        var granted: Bool
        var asked: Bool
    }

    /// Attach a freshly captured frame to the model conversation when the
    /// `VisionContext` allows it. Local models receive the frame directly; remote
    /// models receive a `FrameScrubber`-redacted frame routed through
    /// `CaptureRouter.cloudRoute`, and only with consent. Otherwise this is a
    /// no-op and the loop continues on the AX text alone.
    private static func attachFrame(
        image: CUImage,
        vision: VisionContext,
        consent: inout RunCloudVisionConsent,
        requestConsent: @Sendable () async -> CloudVisionConsentChoice,
        availability: MacDriverAvailability,
        messages: inout [ChatMessage],
        imageTokensInContext: inout Int,
        metrics: inout ComputerUseRunMetrics,
        feed: SubagentFeed,
        step: Int
    ) async {
        let effective = vision.withConsent(consent.granted)
        switch VisionAttachment.decide(image: image, context: effective, availability: availability) {
        case .none:
            // The frame can't attach as-is. If the ONLY thing missing is
            // cloud-vision consent (remote image model + Screen Recording on),
            // offer a just-in-time prompt once per run rather than silently
            // dropping to AX-only.
            await offerJustInTimeCloudConsent(
                image: image,
                vision: vision,
                consent: &consent,
                requestConsent: requestConsent,
                availability: availability,
                messages: &messages,
                imageTokensInContext: &imageTokensInContext,
                metrics: &metrics,
                feed: feed,
                step: step
            )
        case .localFrame(let img):
            appendImageMessage(
                img,
                note:
                    "Screenshot of the current view (the accessibility tree could not resolve the target). "
                    + "Use it to locate the element, then address it by `describe`.",
                into: &messages,
                imageTokensInContext: &imageTokensInContext
            )
            feed.emit(
                SubagentActivityEvent(
                    step: step,
                    kind: .perceive,
                    title: "Attached a screenshot",
                    detail: "on-device"
                )
            )
        case .needsScrubForCloud(let img):
            await attachScrubbedForCloud(
                img,
                vision: vision,
                availability: availability,
                messages: &messages,
                imageTokensInContext: &imageTokensInContext,
                metrics: &metrics,
                feed: feed,
                step: step
            )
        }
    }

    /// Offer a one-per-run just-in-time cloud-vision prompt when a frame would
    /// reach a remote model if only consent were granted. On grant, scrub +
    /// attach through the cloud route; on decline (or if consent isn't the sole
    /// blocker) stay on accessibility text. Records that the prompt fired so it
    /// doesn't nag again this run.
    private static func offerJustInTimeCloudConsent(
        image: CUImage,
        vision: VisionContext,
        consent: inout RunCloudVisionConsent,
        requestConsent: @Sendable () async -> CloudVisionConsentChoice,
        availability: MacDriverAvailability,
        messages: inout [ChatMessage],
        imageTokensInContext: inout Int,
        metrics: inout ComputerUseRunMetrics,
        feed: SubagentFeed,
        step: Int
    ) async {
        let effective = vision.withConsent(consent.granted)
        guard
            !consent.asked,
            VisionAttachment.wouldAttachWithConsent(
                image: image,
                context: effective,
                availability: availability
            )
        else { return }
        consent.asked = true
        feed.emit(
            SubagentActivityEvent(
                step: step,
                kind: .perceive,
                title: "Asked to use Cloud vision",
                detail: "a screenshot would help here — waiting for your choice"
            )
        )
        switch await requestConsent() {
        case .deny:
            feed.emit(
                SubagentActivityEvent(
                    step: step,
                    kind: .perceive,
                    title: "Staying on-device",
                    detail: "Cloud vision declined; continuing from accessibility text"
                )
            )
            return
        case .allowOnce:
            await MainActor.run { CloudVisionConsent.shared.grantForSession() }
            consent.granted = true
        case .allowAlways:
            await MainActor.run { CloudVisionConsent.shared.grantPersistently() }
            consent.granted = true
        }
        guard
            case .needsScrubForCloud(let img) = VisionAttachment.decide(
                image: image,
                context: vision.withConsent(true),
                availability: availability
            )
        else { return }
        await attachScrubbedForCloud(
            img,
            vision: vision,
            availability: availability,
            messages: &messages,
            imageTokensInContext: &imageTokensInContext,
            metrics: &metrics,
            feed: feed,
            step: step
        )
    }

    /// Scrub a frame in the run's resolved cloud mode and attach it through the
    /// consented cloud route. The route is the only way to reach `.cloudVision`
    /// and only accepts a `ScrubbedFrame`, so a raw or unconsented frame can
    /// never be attached here. Only called once consent is effectively granted.
    private static func attachScrubbedForCloud(
        _ img: CUImage,
        vision: VisionContext,
        availability: MacDriverAvailability,
        messages: inout [ChatMessage],
        imageTokensInContext: inout Int,
        metrics: inout ComputerUseRunMetrics,
        feed: SubagentFeed,
        step: Int
    ) async {
        let mode = vision.cloudScrubMode
        guard
            let frame = await FrameScrubber.scrub(
                img,
                mode: mode,
                honorUserRules: true,
                useModelDetection: mode == .pii
            ),
            let route = CaptureRouter.cloudRoute(
                scrubbed: frame,
                consentGranted: true,
                availability: availability
            ),
            case .cloudVision(let scrubbed) = route
        else { return }
        appendImageMessage(
            scrubbed.image,
            note: cloudFrameNote(mode: mode),
            into: &messages,
            imageTokensInContext: &imageTokensInContext
        )
        metrics.cloudVisionUsed = true
        feed.emit(
            SubagentActivityEvent(
                step: step,
                kind: .perceive,
                title: "Attached a screenshot",
                detail: cloudFrameFeedDetail(mode: mode, masked: frame.report.maskedRegions)
            )
        )
    }

    /// The note attached to a cloud-bound screenshot, honest about what the
    /// resolved scrub mode actually masked (so neither the model nor the user
    /// is told more was redacted than was).
    private static func cloudFrameNote(mode: ScrubMode) -> String {
        switch mode {
        case .allText:
            return
                "Screenshot of the current view. All on-screen text was masked on-device before it "
                + "left the machine, so rely on layout and the accessibility text already provided to "
                + "locate the element, then address it by `describe`."
        case .pii:
            return
                "Screenshot of the current view. Detected sensitive text (names, contacts, account "
                + "numbers, secrets) was masked on-device before it left the machine; other on-screen "
                + "text is still visible. Use it to locate the element, then address it by `describe`."
        }
    }

    private static func cloudFrameFeedDetail(mode: ScrubMode, masked: Int) -> String {
        switch mode {
        case .allText: return "masked all \(masked) text region(s) before cloud vision"
        case .pii: return "masked \(masked) sensitive region(s) before cloud vision"
        }
    }

    /// Append a one-shot image message as a trailing `user` turn (images on
    /// `tool` messages are dropped by some remotes). Drops any earlier image
    /// parts first so at most one screenshot is ever in context, and records the
    /// estimated image token cost so the next iteration's trim can reserve it.
    private static func appendImageMessage(
        _ image: CUImage,
        note: String,
        into messages: inout [ChatMessage],
        imageTokensInContext: inout Int
    ) {
        dropPriorImages(&messages)
        let dataUrl = "data:\(image.mimeType);base64,\(image.base64)"
        messages.append(
            ChatMessage(
                role: "user",
                content: note,
                contentParts: [.text(note), .imageUrl(url: dataUrl, detail: "high")]
            )
        )
        let bytes = Data(base64Encoded: image.base64) ?? Data()
        imageTokensInContext = Attachment.estimatedImageTokens(forEncodedImage: bytes)
    }

    /// Collapse any prior image-carrying messages back to text-only so a long
    /// run never accumulates multiple screenshots in the prompt.
    private static func dropPriorImages(_ messages: inout [ChatMessage]) {
        for i in messages.indices {
            guard let parts = messages[i].contentParts,
                parts.contains(where: { if case .imageUrl = $0 { return true } else { return false } })
            else { continue }
            let text =
                parts
                .compactMap { part -> String? in
                    if case .text(let t) = part { return t } else { return nil }
                }
                .joined(separator: "\n")
            messages[i] = ChatMessage(role: messages[i].role, content: text)
        }
    }

    // MARK: - App guidance

    /// Inject a per-app recipe hint exactly once per app (e.g. the address-bar
    /// flow for browsers). No-op when the app has no recipe or was already
    /// hinted; the app is marked hinted regardless so we don't re-check it.
    private static func appendAppGuidance(
        app: String?,
        into messages: inout [ChatMessage],
        hinted: inout Set<String>
    ) {
        guard let app = app, !app.isEmpty else { return }
        let key = app.lowercased()
        guard !hinted.contains(key) else { return }
        hinted.insert(key)
        guard let text = AppRecipes.guidanceText(for: app) else { return }
        messages.append(ChatMessage(role: "system", content: text))
    }

    // MARK: - System prompt

    static func systemPrompt(policySummary: String = "") -> String {
        var prompt = """
            You are Computer Use, an agent that operates macOS apps for the user through an accessibility \
            driver. You perceive the screen as a numbered list of elements and act by proposing ONE action \
            at a time.

            Rules:
            - Each turn, call the `agent_action` tool exactly once with a single verb.
            - Verbs: look with `observe`/`find`; interact with `click`, `double_click`, `right_click` \
            (context menu), `type`, `set_value`, `clear`, `press_key`, `scroll`, and `drag` (`target` is \
            the start, `to` is the destination); switch apps with `open`; pause for async UI (a spinner or \
            load) with `wait` (`seconds`); finish with `done`/`give_up`.
            - Address elements by the `mark` number shown in the current view. If you don't have a mark, \
            use `target.describe` with the element's role and label.
            - After every action you get a fresh view with `*` marking elements that changed — use it to \
            verify the action worked before moving on.
            - The harness applies the user's autonomy policy to every action: some run immediately, some \
            pause for the user to approve, and some are blocked outright. Reads and navigation are usually \
            automatic; edits and consequential actions (sending, deleting, purchasing, sharing) are the ones \
            most likely to need approval, so always explain your intent in `note`.
            - If an action is declined or blocked, do not repeat it — try another approach or `give_up`.
            - Finish with `done` (include a `reason` summarizing what you accomplished) when the goal is met, \
            or `give_up` (with a `reason`) if it cannot be done.
            - Be efficient: the run has a step limit.
            """
        let trimmed = policySummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            prompt += "\n\nCurrent autonomy policy: \(trimmed)"
        }
        return prompt
    }
}

// MARK: - Scripted cursor

/// Reference-typed cursor so a `@Sendable` provider closure can vend a fixed
/// action sequence across steps. Repeats the final action once exhausted.
private actor ScriptedActionCursor {
    private let actions: [AgentAction]
    private var index = 0

    init(_ actions: [AgentAction]) {
        self.actions = actions
    }

    func next() -> ModelActionCall? {
        guard !actions.isEmpty else { return nil }
        let action = index < actions.count ? actions[index] : actions[actions.count - 1]
        index += 1
        return ModelActionCall(id: "scripted-\(index)", arguments: action.argumentsJSON())
    }
}

/// As `ScriptedActionCursor`, but over raw `agent_action` arguments-JSON
/// strings (so a scenario can script malformed bytes verbatim).
private actor ScriptedArgumentCursor {
    private let arguments: [String]
    private var index = 0

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    func next() -> ModelActionCall? {
        guard !arguments.isEmpty else { return nil }
        let arg = index < arguments.count ? arguments[index] : arguments[arguments.count - 1]
        index += 1
        return ModelActionCall(id: "scripted-\(index)", arguments: arg)
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
