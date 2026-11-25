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

import CoreGraphics
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
    /// When true (production default), a `done` after at least one acting
    /// step is only accepted once some step's verify (or a later observe /
    /// wait) saw the view change. Synthesized macOS input is fire-and-forget,
    /// so without this a run whose every click was silently dropped could
    /// still report success. The model gets ONE bounded challenge to observe
    /// and confirm; a second unverified `done` ends the run as `gaveUp`.
    /// Scripted evals that only exercise gate/parse contracts may turn it off.
    public var requireVerifiedChangeForDone: Bool
    /// History-window ceiling, in positions, that every model step is trimmed
    /// to and checked against after tokenization. RAM admission prices this
    /// exact number, so it can only tighten the model's resolved window.
    /// `nil` runs on the resolved window with no position check.
    public var contextPositions: Int?

    /// Wall-clock allowance per step when the caller doesn't set one. A local
    /// vision model spends 7–15 s per step (prompt with a screenshot, then the
    /// action), so the run's clock grows with its step cap rather than ending
    /// a long `max_steps` run early.
    public static let wallClockSecondsPerStep: TimeInterval = 20
    /// The shortest default wall clock, for small step caps.
    public static let minimumWallClockSeconds: TimeInterval = 300

    /// The default wall clock for a run capped at `maxSteps`.
    public static func defaultWallClockSeconds(maxSteps: Int) -> TimeInterval {
        max(minimumWallClockSeconds, Double(max(1, maxSteps)) * wallClockSecondsPerStep)
    }

    public init(
        maxSteps: Int = 24,
        maxConsecutiveInvalid: Int = 3,
        maxConsecutiveReobserve: Int = 2,
        maxConsecutiveDeadEnd: Int = 3,
        wallClockSeconds: TimeInterval? = nil,
        modelStepTimeoutSeconds: TimeInterval = 90,
        maxInferenceRetries: Int = 2,
        maxRepeatedActions: Int = 4,
        requireVerifiedChangeForDone: Bool = true,
        contextPositions: Int? = nil
    ) {
        self.maxSteps = max(1, maxSteps)
        self.maxConsecutiveInvalid = max(1, maxConsecutiveInvalid)
        self.maxConsecutiveReobserve = max(1, maxConsecutiveReobserve)
        self.maxConsecutiveDeadEnd = max(1, maxConsecutiveDeadEnd)
        self.wallClockSeconds = wallClockSeconds ?? Self.defaultWallClockSeconds(maxSteps: maxSteps)
        self.modelStepTimeoutSeconds = modelStepTimeoutSeconds
        self.maxInferenceRetries = max(0, maxInferenceRetries)
        self.maxRepeatedActions = maxRepeatedActions
        self.requireVerifiedChangeForDone = requireVerifiedChangeForDone
        self.contextPositions = contextPositions.map { max(1, $0) }
    }
}

/// How a run ended.
public enum RunOutcome: Sendable, Equatable {
    case done(summary: String)
    case gaveUp(reason: String)
    case stepCapReached
    case deadEnd(reason: String)
    case interrupted
    /// The user said no to Computer Use taking over the app it would start in.
    case declined(app: String)
    case failed(reason: String)

    public var isSuccess: Bool { if case .done = self { return true } else { return false } }

    public var summary: String {
        switch self {
        case .done(let s): return s
        case .gaveUp(let r): return L("Gave up: \(r)")
        case .stepCapReached: return L("Stopped: reached the step limit before finishing.")
        case .deadEnd(let r): return L("Stopped: \(r)")
        case .interrupted: return L("Stopped by user.")
        case .declined(let app): return L("The user declined letting Computer Use take over \(app).")
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

/// Image-processing dependency for cloud attachment, like the injected driver
/// and model-step provider. A successful value must come from FrameScrubber.
public typealias CloudFrameScrubOperation =
    @Sendable (CUImage, ScrubMode) async throws -> ScrubbedFrame

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
        /// Returns a reason when no surface can show a confirm card right now
        /// (e.g. the chat window is closed), so a gated action fails fast with
        /// that reason instead of parking on `confirm` until the wall clock.
        /// `nil` (the default) means confirms are presentable.
        confirmUnavailable: @escaping @Sendable () async -> String? = { nil },
        /// The app to work in (name or bundle id). It is opened behind the
        /// user's work and cleared by the same gate as an `open` action.
        targetApp: String? = nil,
        /// Asked, with the app's name, before a run without `targetApp`
        /// takes over the frontmost app.
        confirmTakeover: @escaping @Sendable (String) async -> Bool = { _ in true },
        limits: RunLimits = RunLimits(),
        policySummary: String = "",
        vision: VisionContext = .none,
        sessionId: String,
        enableThinking: Bool? = nil,
        reasoningEffort: String? = nil,
        scrubFrame: @escaping CloudFrameScrubOperation = { image, mode in
            try await FrameScrubber.scrub(
                image,
                mode: mode,
                honorUserRules: true,
                useModelDetection: mode == .pii
            )
        },
        nextAction: AgentStepProvider? = nil,
        presenter: ComputerUsePresenting = ComputerUseNoopPresenter()
    ) async -> ComputerUseRunResult {
        await presenter.begin(goal: goal)
        let heartbeat = Task {
            while !Task.isCancelled {
                await presenter.heartbeat()
                try? await Task.sleep(nanoseconds: UInt64(presenceHeartbeatSeconds * 1_000_000_000))
            }
        }
        let result = await runCore(
            goal: goal,
            modelId: modelId,
            driver: driver,
            gate: gate,
            feed: feed,
            interrupt: interrupt,
            confirm: confirm,
            requestCloudVisionConsent: requestCloudVisionConsent,
            confirmUnavailable: confirmUnavailable,
            targetApp: targetApp,
            confirmTakeover: confirmTakeover,
            limits: limits,
            policySummary: policySummary,
            vision: vision,
            sessionId: sessionId,
            enableThinking: enableThinking,
            reasoningEffort: reasoningEffort,
            scrubFrame: scrubFrame,
            nextAction: nextAction,
            presenter: presenter
        )
        heartbeat.cancel()
        await presenter.end(result.outcome)
        return result
    }

    /// How often `run` tells the presenter the run is still alive.
    public static let presenceHeartbeatSeconds: TimeInterval = 2

    private static func runCore(
        goal: String,
        modelId: String,
        driver: MacDriver,
        gate: ComputerUseGating,
        feed: SubagentFeed,
        interrupt: InterruptToken,
        confirm: @escaping @Sendable (ActionPreview) async -> Bool,
        requestCloudVisionConsent: @escaping @Sendable () async -> CloudVisionConsentChoice,
        confirmUnavailable: @escaping @Sendable () async -> String?,
        targetApp: String?,
        confirmTakeover: @escaping @Sendable (String) async -> Bool,
        limits: RunLimits,
        policySummary: String,
        vision: VisionContext,
        sessionId: String,
        enableThinking: Bool?,
        reasoningEffort: String?,
        scrubFrame: @escaping CloudFrameScrubOperation,
        nextAction: AgentStepProvider?,
        presenter: ComputerUsePresenting
    ) async -> ComputerUseRunResult {
        // The wall clock measures the RUN, not the user. Time spent inside a
        // confirm card or a cloud-vision consent prompt is credited back, so a
        // user who takes a few minutes to read a preview doesn't come back to
        // "Reached the time limit" with nothing done.
        let userWaitCredit = UserWaitCredit()
        let baseDeadline = Date().addingTimeInterval(limits.wallClockSeconds)
        var deadline: Date { baseDeadline.addingTimeInterval(userWaitCredit.total) }
        let timedConfirm: @Sendable (ActionPreview) async -> Bool = { preview in
            let began = Date()
            await presenter.confirmPending(true)
            let approved = await confirm(preview)
            await presenter.confirmPending(false)
            userWaitCredit.add(Date().timeIntervalSince(began))
            return approved
        }
        let timedCloudVisionConsent: @Sendable () async -> CloudVisionConsentChoice = {
            let began = Date()
            let choice = await requestCloudVisionConsent()
            userWaitCredit.add(Date().timeIntervalSince(began))
            return choice
        }
        let timedTakeover: @Sendable (String) async -> Bool = { app in
            let began = Date()
            await presenter.confirmPending(true)
            let approved = await confirmTakeover(app)
            await presenter.confirmPending(false)
            userWaitCredit.add(Date().timeIntervalSince(began))
            return approved
        }
        var metrics = ComputerUseRunMetrics()

        // Settle where the run works before anything is perceived or locked.
        var currentPid: Int32?
        switch await settleTarget(
            targetApp: targetApp,
            driver: driver,
            gate: gate,
            confirm: timedConfirm,
            confirmUnavailable: confirmUnavailable,
            confirmTakeover: timedTakeover,
            interrupt: interrupt,
            metrics: &metrics,
            feed: feed
        ) {
        case .pid(let pid):
            currentPid = pid
        case .refused(let outcome):
            feed.emit(
                SubagentActivityEvent(step: 0, kind: .outcome, title: outcome.summary, success: false)
            )
            feed.finish(success: false, summary: outcome.summary)
            return ComputerUseRunResult(outcome: outcome, metrics: metrics)
        }
        // Default path drives the live ChatEngine; an injected `nextAction`
        // (tests / scripted-model evals) drives the loop deterministically and
        // never constructs an engine.
        // Auto-scrub: the user is watching the app being driven, not the
        // chat window, so a Privacy Filter review sheet per step would go
        // unanswered until the step timeout failed the run.
        // Residency follows the run that invoked the tool (chat / HTTP /
        // channel / schedule…); Insights shows every helper step as Agent.
        let engine: ChatEngine? =
            nextAction == nil
            ? ChatEngine(
                source: ChatExecutionContext.currentSessionSource?.inferenceSource ?? .chatUI,
                activitySource: .agent,
                privacyReviewMode: .autoScrub
            ) : nil

        // A local bundle that states no grounding frame is measured once before
        // its first run; the outcome is cached per bundle.
        let calibrationStarted = Date()
        let vision = await groundedVision(
            vision,
            engine: engine,
            modelId: modelId,
            sessionId: sessionId,
            enableThinking: enableThinking,
            reasoningEffort: reasoningEffort,
            limits: limits,
            interrupt: interrupt,
            feed: feed
        )
        // One-time setup, not part of the task's time.
        userWaitCredit.add(Date().timeIntervalSince(calibrationStarted))
        let pointing = PointingSurface(vision.grounding)

        // Capture availability once: it gates the escalation ladder (som/vision
        // need Screen Recording) for the whole run.
        let availability = await driver.availability()
        // The tier the next AX-resolution capture runs at. Escalates when a target
        // won't resolve; drops back to the resting tier once one does.
        var currentTier = restingTier(vision: vision, availability: availability)

        // Conversation state.
        var messages: [ChatMessage] = [
            ChatMessage(role: "system", content: systemPrompt(policySummary: policySummary, pointing: pointing))
        ]
        let resolvedWindow = await AgentLoopBudget.resolveContextWindow(modelId: modelId)
        let positionLimit = limits.contextPositions.map { min(resolvedWindow, $0) }
        let contextWindow = positionLimit ?? resolvedWindow
        let systemChars = messages.first?.content?.count ?? 0
        // Bumped per-iteration by the in-context image's estimated tokens (the
        // text budget doesn't count image parts).
        let baseToolTokens = toolSchemaReserveTokens
        let budgetManager = AgentLoopBudget.makeBudgetManager(
            contextWindow: contextWindow,
            systemPromptChars: systemChars,
            toolTokens: baseToolTokens,
            maxResponseTokens: nil
        )
        let watermark = CompactionWatermark()

        var currentApp: String? = nil
        var lastView: AgentView? = nil
        var lastSnapshot: CUSnapshot? = nil
        // Apps whose recipe hint has already been injected (once per app).
        var hintedApps: Set<String> = []
        // Estimated tokens of the single screenshot currently in context (0 = none).
        var imageTokensInContext = 0
        // The screenshot the model was last shown; `target.point` and `zoom`
        // regions are read against it in `vision.grounding`'s frame.
        var shownFrame: CUImage? = nil
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
            do {
                shownFrame = try await attachFrame(
                    image: frame,
                    snapshot: initialView.snapshot,
                    vision: vision,
                    consent: &runConsent,
                    requestConsent: timedCloudVisionConsent,
                    availability: availability,
                    messages: &messages,
                    imageTokensInContext: &imageTokensInContext,
                    metrics: &metrics,
                    feed: feed,
                    step: 0,
                    scrubFrame: scrubFrame
                ) ?? shownFrame
            } catch {
                return frameScrubFailureResult(error, step: 0, completedSteps: 0, metrics: metrics, feed: feed)
            }
        }

        var step = 0
        var consecutiveInvalid = 0
        var consecutiveDeadEnd = 0
        var lastReobserveTargetKey: String? = nil
        var consecutiveReobserve = 0
        var lastActionSignature: String? = nil
        var repeatedActionCount = 0
        // Completion evidence. `verifyChanged` counts changes seen by the
        // verify capture right after an act; an app that renders late shows
        // the change on a later observe/wait instead, which this flag records
        // so a slow-but-real edit isn't mistaken for a dropped one.
        var lateVerifiedChange = false
        // The one bounded "prove it" re-ask a `done` with no verified change
        // gets before the run is downgraded.
        var doneChallengeIssued = false
        // Told the model once that there is no screenshot rung to climb to
        // (Screen Recording not granted) when a target failed to resolve, so
        // it stops expecting pixels and works the AX list / `find` / gives up.
        var screenRecordingNoticeGiven = false

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
            await presenter.targetChanged(ComputerUsePresenceTarget(snapshot: lastSnapshot))
            if Date() >= deadline {
                return terminate(.deadEnd(reason: "Reached the time limit before finishing."))
            }
            if step >= limits.maxSteps {
                return terminate(.stepCapReached)
            }

            // Collapse old screen listings in batches before building the step
            // input (see `compactStaleViews`).
            let compacted = compactStaleViews(&messages)
            if compacted > 0 {
                ComputerUseTraceLog.note("compacted \(compacted) stale view(s) before step \(step + 1)")
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
            let responseAttempt = nextAction == nil ? DesktopResponsesAttempt() : nil
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
                        messages: stepMessages,
                        enableThinking: enableThinking,
                        reasoningEffort: reasoningEffort,
                        attempt: responseAttempt,
                        pointing: pointing,
                        positionLimit: positionLimit
                    )
                }
            }
            let parsed: ModelActionCall?
            var completedAssistant: ChatMessage?
            do {
                let stepResult = try await runModelStep(
                    produce,
                    timeout: limits.modelStepTimeoutSeconds,
                    maxRetries: limits.maxInferenceRetries,
                    interrupt: interrupt,
                    feed: feed,
                    step: step,
                    shouldRetry: { error in
                        responseAttempt?.permitsRetry(error, isTimeout: error is ModelStepTimeout) ?? true
                    }
                )
                if let tokens = stepResult.tokens { metrics.modelTokens += tokens }
                completedAssistant = stepResult.assistantMessage
                metrics.recordDecodeTokensPerSecond(stepResult.tokensPerSecond)
                parsed = stepResult.call
            } catch where isMissingRequiredAgentActionError(error) {
                // ChatEngine correctly fails closed when a named/required
                // local tool turn reaches EOS without a parsed call. For
                // Computer Use that error means exactly the same thing as a
                // nil `agent_action`, so route it through the loop's bounded
                // protocol re-ask below. Treating it as an inference failure
                // here used to terminate a visibly successful desktop action
                // before the model got one chance to emit `done`.
                parsed = nil
            } catch {
                if interrupt.isInterrupted || Task.isCancelled { return terminate(.interrupted) }
                return terminate(.failed(reason: error.localizedDescription))
            }
            if interrupt.isInterrupted || Task.isCancelled {
                return terminate(.interrupted)
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
            let assistantMessage = completedAssistant ?? ChatMessage(
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
                    title: action.auditLabel(
                        element: proposedElement(action.target, view: lastView, snapshot: lastSnapshot),
                        destination: proposedElement(action.to, view: lastView, snapshot: lastSnapshot),
                        app: lastSnapshot?.app
                    ),
                    detail: action.note
                )
            )

            // Terminal verbs end the run immediately — except a `done` that
            // nothing observable backs up. Input posting carries no delivery
            // proof, so "I clicked Send" is only trusted once a verify /
            // observe saw the app change. One bounded challenge asks the model
            // to look; a second unproven `done` is reported as such instead of
            // as success.
            if action.verb == .done {
                let acted = metrics.actsAttempted > 0
                let verified = metrics.verifyChanged > 0 || lateVerifiedChange
                if limits.requireVerifiedChangeForDone, acted, !verified {
                    if doneChallengeIssued {
                        return terminate(
                            .gaveUp(
                                reason:
                                    "The model reported the task as done, but none of its "
                                    + "\(metrics.actsAttempted) action(s) produced an observable "
                                    + "change in the app, so completion could not be verified."
                            )
                        )
                    }
                    doneChallengeIssued = true
                    feed.emit(
                        SubagentActivityEvent(
                            step: step,
                            kind: .retry,
                            title: "Unverified done",
                            detail: "No action produced an observable change; asking the model to confirm."
                        )
                    )
                    messages.append(
                        ChatMessage(
                            role: "tool",
                            content:
                                "You reported done, but none of your actions produced an observable "
                                + "change in the app, so the result cannot be confirmed. Use `observe` "
                                + "to check whether the intended state is actually present, then call "
                                + "`done` only if it is; otherwise call `give_up` and say what did not "
                                + "take effect.",
                            tool_calls: nil,
                            tool_call_id: callId
                        )
                    )
                    continue
                }
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
                                    "Repeated the same action (\(action.auditLabel(element: nil, app: nil))) "
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
                if metrics.actsAttempted > 0, p.view?.hasChanges == true { lateVerifiedChange = true }
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
                if metrics.actsAttempted > 0, p.view?.hasChanges == true { lateVerifiedChange = true }
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
                var openAbort: RunOutcome? = nil
                if await applyGate(
                    openDecision,
                    label: action.auditLabel(element: nil, app: nil),
                    effect: openEffect,
                    appName: action.app,
                    confirm: timedConfirm,
                    confirmUnavailable: confirmUnavailable,
                    toolResult: &toolResult,
                    advancedStep: &advancedStep,
                    abort: &openAbort,
                    metrics: &metrics,
                    interrupt: interrupt,
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
                } else if let openAbort {
                    return terminate(openAbort)
                }

            case .screenshot, .zoom:
                guard let pid = currentPid else {
                    toolResult = "No app is focused yet. Use `open` to launch or switch to an app first."
                    advancedStep = false
                    break
                }
                if let unavailable = pixelsUnavailableReason(availability: availability, vision: vision) {
                    toolResult = unavailable
                    break
                }
                if action.verb == .screenshot {
                    let tier = CaptureRouter.nextTier(
                        current: .ax,
                        reason: .pixelsRequested,
                        availability: availability
                    )
                    metrics.raiseTier(to: tier)
                    let p = await perceive(
                        pid: pid,
                        driver: driver,
                        previous: lastView,
                        feed: feed,
                        step: step + 1,
                        tier: tier
                    )
                    lastView = p.view
                    lastSnapshot = p.snapshot
                    if let image = p.snapshot?.image, image.width > 0 {
                        pendingFrameImage = image
                        toolResult = "Captured a screenshot; it follows this result.\n" + p.render
                    } else {
                        toolResult = "The screenshot capture failed.\n" + p.render
                    }
                    break
                }
                guard let area = action.region else { break }
                switch ScreenshotPointing.screenRegion(area, in: shownFrame, grounding: vision.grounding) {
                case .invalid(let reason):
                    toolResult = reason
                    advancedStep = false
                case .screen(let region):
                    guard let image = await driver.zoom(pid: pid, region: region), image.width > 0 else {
                        toolResult = "Couldn't capture that region."
                        break
                    }
                    feed.emit(
                        SubagentActivityEvent(
                            step: step + 1,
                            kind: .perceive,
                            title: "Zoomed in",
                            detail: "\(image.width)×\(image.height) px"
                        )
                    )
                    pendingFrameImage = image
                    toolResult =
                        "The close-up follows. A `target.point` now refers to the close-up until the next "
                        + "screenshot."
                }

            case .batch:
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
                let batch = await runBatch(
                    action.actions,
                    pid: pid,
                    view: view,
                    snapshot: snapshot,
                    shownFrame: shownFrame,
                    grounding: vision.grounding,
                    appName: currentApp,
                    driver: driver,
                    gate: gate,
                    availability: availability,
                    confirm: timedConfirm,
                    confirmUnavailable: confirmUnavailable,
                    presenter: presenter,
                    currentTier: &currentTier,
                    pendingFrameImage: &pendingFrameImage,
                    lastView: &lastView,
                    lastSnapshot: &lastSnapshot,
                    metrics: &metrics,
                    interrupt: interrupt,
                    feed: feed,
                    step: step + 1
                )
                if let abort = batch.abort { return terminate(abort) }
                toolResult = batch.toolResult
                advancedStep = batch.performed > 0
                if batch.performed > 0 { consecutiveDeadEnd = 0 }

            case .click, .doubleClick, .rightClick, .drag, .type, .setValue, .clear, .pressKey, .scroll, .hover,
                .select:
                guard let pid = currentPid else {
                    toolResult =
                        "No app is focused yet. Use `open` to launch or switch to an app first, then act."
                    advancedStep = false
                    break
                }
                // Re-seed the target before posting input at it. A quit or
                // relaunched app leaves `currentPid` pointing at a dead (or
                // recycled) process; per-pid posting into that "succeeds" and
                // the model spends its step budget acting into a void.
                if await driver.isRunning(pid: pid) == false {
                    toolResult = targetExited(app: currentApp, pid: pid, feed: feed, step: step + 1)
                    currentPid = nil
                    lastView = nil
                    lastSnapshot = nil
                    advancedStep = false
                    break
                }
                guard let snapshot = lastSnapshot, let view = lastView else {
                    toolResult = "No current view. Use `observe` first."
                    advancedStep = false
                    break
                }

                // Resolve the element for element-addressed verbs. A point is
                // placed through the shown screenshot and classified by the
                // element under it.
                var resolvedElement: CUElement? = nil
                var actPoint: CGPoint? = nil
                if let point = action.target?.point {
                    switch ScreenshotPointing.screenPoint(point, in: shownFrame, grounding: vision.grounding) {
                    case .invalid(let reason):
                        toolResult = reason
                        advancedStep = false
                    case .screen(let screenPoint):
                        actPoint = screenPoint
                        resolvedElement = ScreenshotPointing.hitTest(screenPoint, in: snapshot)
                    }
                    if actPoint == nil { break }
                    if resolvedElement == nil, needsElement(action.verb) {
                        toolResult =
                            "No accessible element is at that point, and \(action.verb.rawValue) needs one. "
                            + "Address it by `mark` instead."
                        advancedStep = false
                        break
                    }
                } else if requiresTarget(action.verb) || action.target != nil {
                    let resolution = TargetResolver.resolve(action.target, view: view, snapshot: snapshot)
                    switch resolution {
                    case .resolved(_, let element):
                        resolvedElement = element
                        metrics.recordResolveAttempt(success: true)
                        consecutiveReobserve = 0
                        lastReobserveTargetKey = nil
                        // Resolved against the AX tree; drop back to the resting tier.
                        currentTier = restingTier(
                            vision: vision.withConsent(runConsent.granted),
                            availability: availability
                        )
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
                        var noPixelsNotice = ""
                        if CaptureRouter.canEscalate(from: currentTier, availability: availability) {
                            currentTier = CaptureRouter.nextTier(
                                current: currentTier,
                                reason: .targetUnresolved,
                                availability: availability
                            )
                            metrics.raiseTier(to: currentTier)
                        } else if !availability.screenRecording, !screenRecordingNoticeGiven {
                            // The tool description promises a screenshot fallback;
                            // without Screen Recording there is none. Say so once
                            // instead of re-serving the same AX list until dead end.
                            screenRecordingNoticeGiven = true
                            noPixelsNotice =
                                "\nNote: Screen Recording permission isn't granted, so there is no "
                                + "screenshot fallback — only this accessibility list. Use `find` with a "
                                + "query or `scroll` to locate the control, or `give_up` and ask the user "
                                + "to grant Screen Recording in System Settings → Privacy & Security."
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
                                "Still can't resolve that target after re-looking. \(reason)\(noPixelsNotice)\n"
                                + "Here is the fresh view:\n" + p.render
                        } else {
                            toolResult = "\(reason)\(noPixelsNotice)\nHere is the fresh view:\n" + p.render
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
                var destinationPoint: CGPoint? = nil
                if action.verb == .drag {
                    switch resolveDestination(
                        action.to, view: view, snapshot: snapshot, shownFrame: shownFrame,
                        grounding: vision.grounding
                    ) {
                    case .success(let destination):
                        destinationElement = destination.element
                        destinationPoint = destination.point
                    case .failure(let problem):
                        toolResult = problem.message
                        advancedStep = false
                    }
                    if destinationElement == nil && destinationPoint == nil { break }
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
                let targetLabel =
                    resolvedElement.map { describe($0) }
                    ?? (actPoint != nil ? unlabeledPointLabel(action.target?.point) : action.target?.describe)
                let decision = await gate.evaluate(
                    action: action,
                    effect: effect,
                    appName: currentApp,
                    targetLabel: targetLabel
                )
                var actAbort: RunOutcome? = nil
                if await applyGate(
                    decision,
                    label: action.auditLabel(element: resolvedElement, destination: destinationElement, app: currentApp),
                    effect: effect,
                    appName: currentApp,
                    confirm: timedConfirm,
                    confirmUnavailable: confirmUnavailable,
                    toolResult: &toolResult,
                    advancedStep: &advancedStep,
                    abort: &actAbort,
                    metrics: &metrics,
                    interrupt: interrupt,
                    feed: feed,
                    step: step + 1
                ) {
                    await presenter.willAct(
                        ComputerUsePresenceAct(
                            verb: action.verb.rawValue,
                            point: actPoint ?? resolvedElement.map { CGPoint(x: $0.center.x, y: $0.center.y) },
                            movesPointer: movesPointer(action.verb)
                        )
                    )
                    toolResult = await act(
                        action: action,
                        element: resolvedElement,
                        destinationElement: destinationElement,
                        point: actPoint,
                        destinationPoint: destinationPoint,
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
                    await presenter.didAct()
                    consecutiveDeadEnd = 0
                } else if let actAbort {
                    return terminate(actAbort)
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
                do {
                    shownFrame = try await attachFrame(
                        image: frame,
                        snapshot: lastSnapshot,
                        vision: vision,
                        consent: &runConsent,
                        requestConsent: timedCloudVisionConsent,
                        availability: availability,
                        messages: &messages,
                        imageTokensInContext: &imageTokensInContext,
                        metrics: &metrics,
                        feed: feed,
                        step: step + 1,
                        scrubFrame: scrubFrame
                    ) ?? shownFrame
                } catch {
                    return frameScrubFailureResult(
                        error, step: step + 1, completedSteps: step + (advancedStep ? 1 : 0),
                        metrics: metrics, feed: feed
                    )
                }
            }
            if advancedStep { step += 1 }
        }
    }

    /// Where an untargeted scroll lands: the middle of the focused window, so
    /// it reaches the app's content rather than whatever is under the cursor.
    static func focusedWindowCenter(_ snapshot: CUSnapshot?) -> CGPoint? {
        guard let snapshot,
            let window = snapshot.windows.first(where: \.focused) ?? snapshot.windows.first,
            window.w > 0, window.h > 0
        else { return nil }
        return CGPoint(x: Double(window.x) + Double(window.w) / 2, y: Double(window.y) + Double(window.h) / 2)
    }

    /// Verbs that post mouse events (and so may take the HID route).
    static func movesPointer(_ verb: AgentVerb) -> Bool {
        switch verb {
        case .click, .doubleClick, .rightClick, .drag, .scroll, .hover: return true
        default: return false
        }
    }

    /// Why a `screenshot` / `zoom` can't produce pixels the model will see.
    static func pixelsUnavailableReason(availability: MacDriverAvailability, vision: VisionContext) -> String? {
        if !availability.screenRecording {
            return
                "Screen Recording permission isn't granted, so there are no screenshots. Work from the "
                + "element list, or ask the user to grant Screen Recording in System Settings → Privacy & "
                + "Security."
        }
        if !vision.modelAcceptsImages {
            return "This model doesn't take images, so a screenshot wouldn't reach you. Work from the element list."
        }
        return nil
    }

    /// Verbs that act on an element itself rather than a screen position.
    static func needsElement(_ verb: AgentVerb) -> Bool {
        switch verb {
        case .setValue, .clear, .select: return true
        default: return false
        }
    }

    private static func unlabeledPointLabel(_ point: AgentPoint?) -> String {
        guard let point else { return "an unlabeled spot" }
        return "an unlabeled spot at (\(Int(point.x)), \(Int(point.y))) in the screenshot"
    }

    struct TargetProblem: Error {
        let message: String
    }

    /// A drag destination: an element (by mark/describe) or a screen point.
    static func resolveDestination(
        _ target: AgentTarget?,
        view: AgentView,
        snapshot: CUSnapshot,
        shownFrame: CUImage?,
        grounding: GroundingProfile?
    ) -> Result<(element: CUElement?, point: CGPoint?), TargetProblem> {
        if let point = target?.point {
            switch ScreenshotPointing.screenPoint(point, in: shownFrame, grounding: grounding) {
            case .invalid(let reason): return .failure(TargetProblem(message: reason))
            case .screen(let screenPoint): return .success((nil, screenPoint))
            }
        }
        switch TargetResolver.resolve(target, view: view, snapshot: snapshot) {
        case .resolved(_, let element):
            return .success((element, nil))
        case .reobserve(let reason), .deadEnd(let reason):
            return .failure(TargetProblem(message: "Couldn't resolve the drag destination: \(reason)"))
        }
    }

    // MARK: - Batch

    struct BatchOutcome {
        var toolResult: String
        var performed: Int
        var abort: RunOutcome?
    }

    /// Run a `batch` in order against the view the model planned on. Each step
    /// is resolved and gated like a single action; the batch stops at the
    /// first step that can't be resolved, is blocked or declined, fails, or
    /// needed approval (it runs once approved, then the batch ends so the model
    /// sees the result before going further). One verify capture follows.
    static func runBatch(
        _ steps: [AgentAction],
        pid: Int32,
        view: AgentView,
        snapshot: CUSnapshot,
        shownFrame: CUImage?,
        grounding: GroundingProfile?,
        appName: String?,
        driver: MacDriver,
        gate: ComputerUseGating,
        availability: MacDriverAvailability,
        confirm: @escaping @Sendable (ActionPreview) async -> Bool,
        confirmUnavailable: @escaping @Sendable () async -> String?,
        presenter: ComputerUsePresenting,
        currentTier: inout CaptureTier,
        pendingFrameImage: inout CUImage?,
        lastView: inout AgentView?,
        lastSnapshot: inout CUSnapshot?,
        metrics: inout ComputerUseRunMetrics,
        interrupt: InterruptToken,
        feed: SubagentFeed,
        step: Int
    ) async -> BatchOutcome {
        var lines: [String] = []
        var performed = 0
        var last: (action: AgentAction, element: CUElement?, result: CUActionResult)? = nil
        var stoppedAt: Int? = nil

        for (index, action) in steps.enumerated() {
            let label = "\(index + 1). \(action.feedLabel)"
            var element: CUElement? = nil
            var point: CGPoint? = nil
            if let target = action.target?.point {
                switch ScreenshotPointing.screenPoint(target, in: shownFrame, grounding: grounding) {
                case .invalid(let reason):
                    lines.append("\(label): not run. \(reason)")
                case .screen(let screenPoint):
                    point = screenPoint
                    element = ScreenshotPointing.hitTest(screenPoint, in: snapshot)
                }
                if point == nil {
                    stoppedAt = index
                    break
                }
                if element == nil, needsElement(action.verb) {
                    lines.append("\(label): not run. No accessible element is at that point.")
                    stoppedAt = index
                    break
                }
            } else if requiresTarget(action.verb) || action.target != nil {
                switch TargetResolver.resolve(action.target, view: view, snapshot: snapshot) {
                case .resolved(_, let resolved):
                    element = resolved
                    metrics.recordResolveAttempt(success: true)
                case .reobserve(let reason), .deadEnd(let reason):
                    metrics.recordResolveAttempt(success: false)
                    lines.append("\(label): not run. \(reason)")
                }
                if element == nil {
                    stoppedAt = index
                    break
                }
            }
            var destinationElement: CUElement? = nil
            var destinationPoint: CGPoint? = nil
            if action.verb == .drag {
                switch resolveDestination(
                    action.to, view: view, snapshot: snapshot, shownFrame: shownFrame, grounding: grounding
                ) {
                case .success(let destination):
                    destinationElement = destination.element
                    destinationPoint = destination.point
                case .failure(let problem):
                    lines.append("\(label): not run. \(problem.message)")
                    stoppedAt = index
                }
                if stoppedAt != nil { break }
            }

            let effect = EffectClassifier.classify(
                action: action,
                resolvedRole: element?.role,
                resolvedLabel: element?.label,
                resolvedValue: element?.value,
                resolvedRoleDescription: element?.roleDescription,
                appName: appName,
                recipeSignals: AppRecipes.signals(for: appName)
            )
            metrics.recordEffect(effect)
            let decision = await gate.evaluate(
                action: action,
                effect: effect,
                appName: appName,
                targetLabel: element.map { describe($0) }
                    ?? (point != nil ? unlabeledPointLabel(action.target?.point) : action.target?.describe)
            )
            let neededApproval: Bool
            if case .confirm = decision { neededApproval = true } else { neededApproval = false }
            var gateResult = ""
            var advanced = true
            var abort: RunOutcome? = nil
            guard
                await applyGate(
                    decision,
                    label: action.auditLabel(element: element, destination: destinationElement, app: appName),
                    effect: effect,
                    appName: appName,
                    confirm: confirm,
                    confirmUnavailable: confirmUnavailable,
                    toolResult: &gateResult,
                    advancedStep: &advanced,
                    abort: &abort,
                    metrics: &metrics,
                    interrupt: interrupt,
                    feed: feed,
                    step: step
                )
            else {
                if let abort { return BatchOutcome(toolResult: gateResult, performed: performed, abort: abort) }
                lines.append("\(label): not run. \(gateResult)")
                stoppedAt = index
                break
            }

            await presenter.willAct(
                ComputerUsePresenceAct(
                    verb: action.verb.rawValue,
                    point: point ?? element.map { CGPoint(x: $0.center.x, y: $0.center.y) },
                    movesPointer: movesPointer(action.verb)
                )
            )
            let outcome = await performAct(
                action: action,
                element: element,
                destinationElement: destinationElement,
                point: point,
                destinationPoint: destinationPoint,
                pid: pid,
                driver: driver,
                lastSnapshot: snapshot,
                metrics: &metrics,
                feed: feed,
                step: step
            )
            await presenter.didAct()
            guard let result = outcome.result else {
                lines.append("\(label): not run. \(outcome.message ?? "Unsupported action.")")
                stoppedAt = index
                break
            }
            performed += 1
            last = (action, element, result)
            if !result.success {
                lines.append("\(label): failed. \(result.error ?? "unknown error").")
                stoppedAt = index
                break
            }
            lines.append("\(label): posted.")
            if neededApproval, index < steps.count - 1 {
                lines.append("Stopped after this approved step so you can check its result first.")
                stoppedAt = index
                break
            }
        }

        if let stoppedAt, stoppedAt + 1 < steps.count {
            let skipped = (stoppedAt + 2 ... steps.count).map(String.init).joined(separator: ", ")
            lines.append("Not run: step(s) \(skipped).")
        }
        var toolResult = "Batch of \(steps.count): \(performed) performed.\n" + lines.joined(separator: "\n")
        if let last {
            toolResult +=
                "\n"
                + (await verifyAct(
                    action: last.action,
                    element: last.element,
                    result: last.result,
                    pid: pid,
                    driver: driver,
                    availability: availability,
                    currentTier: &currentTier,
                    pendingFrameImage: &pendingFrameImage,
                    lastView: &lastView,
                    lastSnapshot: &lastSnapshot,
                    metrics: &metrics,
                    feed: feed,
                    step: step
                ))
        } else {
            toolResult += "\n\nCurrent view:\n" + view.renderForModel()
        }
        return BatchOutcome(toolResult: toolResult, performed: performed, abort: nil)
    }

    // MARK: - Gate

    /// Apply a gate decision's bookkeeping (feed event + metrics + tool-result)
    /// and report whether the caller should perform the action. Both gated paths
    /// (`open` and the element-addressed verbs) share this so the
    /// block / confirm / decline wording and counters stay identical. `label`
    /// is the action's `auditLabel`, the only form the feed records.
    private static func applyGate(
        _ decision: GateDecision,
        label: String,
        effect: EffectClass,
        appName: String?,
        confirm: (ActionPreview) async -> Bool,
        confirmUnavailable: () async -> String? = { nil },
        toolResult: inout String,
        advancedStep: inout Bool,
        abort: inout RunOutcome?,
        metrics: inout ComputerUseRunMetrics,
        interrupt: InterruptToken,
        feed: SubagentFeed,
        step: Int
    ) async -> Bool {
        let cleared = await gateClears(
            decision,
            label: label,
            effect: effect,
            appName: appName,
            confirm: confirm,
            confirmUnavailable: confirmUnavailable,
            toolResult: &toolResult,
            advancedStep: &advancedStep,
            abort: &abort,
            metrics: &metrics,
            interrupt: interrupt,
            feed: feed,
            step: step
        )
        // A Stop that landed during the model step or the approval card must
        // win over the action it was racing: nothing is posted after Stop.
        if interrupt.isInterrupted || Task.isCancelled {
            advancedStep = false
            abort = .interrupted
            return false
        }
        return cleared
    }

    private static func gateClears(
        _ decision: GateDecision,
        label: String,
        effect: EffectClass,
        appName: String?,
        confirm: (ActionPreview) async -> Bool,
        confirmUnavailable: () async -> String?,
        toolResult: inout String,
        advancedStep: inout Bool,
        abort: inout RunOutcome?,
        metrics: inout ComputerUseRunMetrics,
        interrupt: InterruptToken,
        feed: SubagentFeed,
        step: Int
    ) async -> Bool {
        switch decision {
        case .reject(let reason):
            ComputerUseTraceLog.recordGate(
                step: step,
                action: label,
                effect: effect,
                appName: appName,
                decision: "reject"
            )
            metrics.blocked += 1
            feed.emit(
                SubagentActivityEvent(step: step, kind: .blocked, title: "Blocked: \(label)", detail: reason)
            )
            toolResult = "That action is not allowed: \(reason). Choose a different action."
            advancedStep = false
            return false
        case .confirm(let preview):
            ComputerUseTraceLog.recordGate(
                step: step,
                action: label,
                effect: effect,
                appName: appName,
                decision: "confirm"
            )
            // Nobody can answer the card (chat window closed / headless
            // dispatch). Parking here would burn the whole wall clock and end
            // as "Reached the time limit" — end now with the real reason.
            if let reason = await confirmUnavailable() {
                ComputerUseTraceLog.recordGateResolution(
                    step: step,
                    action: label,
                    approved: false
                )
                metrics.confirmsUnpresentable += 1
                feed.emit(
                    SubagentActivityEvent(
                        step: step,
                        kind: .blocked,
                        title: "Cannot ask for approval: \(label)",
                        detail: reason
                    )
                )
                toolResult = "Could not ask the user to approve that action: \(reason)."
                advancedStep = false
                abort = .gaveUp(
                    reason:
                        "\(label) needs the user's approval, but \(reason), so the run "
                        + "cannot continue. Reopen the chat with this agent and try again, or lower "
                        + "the autonomy policy's confirm threshold for this app."
                )
                return false
            }
            metrics.confirmsRequested += 1
            feed.emit(
                SubagentActivityEvent(
                    step: step,
                    kind: .confirmRequested,
                    title: "Confirm: \(label)",
                    detail: preview.note
                )
            )
            if await confirm(preview) {
                ComputerUseTraceLog.recordGateResolution(
                    step: step,
                    action: label,
                    approved: true
                )
                metrics.confirmsApproved += 1
                feed.emit(SubagentActivityEvent(step: step, kind: .confirmed, title: "Approved: \(label)"))
                return true
            }
            // Stop withdraws the card; that is not the user declining the action.
            if interrupt.isInterrupted || Task.isCancelled { return false }
            ComputerUseTraceLog.recordGateResolution(
                step: step,
                action: label,
                approved: false
            )
            metrics.confirmsDeclined += 1
            feed.emit(SubagentActivityEvent(step: step, kind: .denied, title: "Declined: \(label)"))
            toolResult = "The user declined that action. Try a different approach or ask to stop."
            advancedStep = false
            return false
        case .run:
            ComputerUseTraceLog.recordGate(
                step: step,
                action: label,
                effect: effect,
                appName: appName,
                decision: "run"
            )
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
    /// is empty and pixels are available. The frame from the final capture (when
    /// it ran above `ax`) is staged in `pendingFrameImage` for attachment after
    /// the step's tool result. Bounded by the ladder height (at most two
    /// escalations), and a no-op for a normal, populated view.
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
        }
        // Stage the frame; attached after the step's tool result.
        if currentTier != .ax, let image = perception.snapshot?.image {
            pendingFrameImage = image
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

    /// The element a proposed mark or describe target names in the current
    /// view, for the feed only. Point targets are mapped when the action runs.
    private static func proposedElement(_ target: AgentTarget?, view: AgentView?, snapshot: CUSnapshot?) -> CUElement? {
        guard let target, target.point == nil, let view, let snapshot,
            case .resolved(_, let element) = TargetResolver.resolve(target, view: view, snapshot: snapshot)
        else { return nil }
        return element
    }

    // MARK: - Target

    private enum SettledTarget {
        case pid(Int32)
        case refused(RunOutcome)
    }

    /// The app a run starts in. A named app is opened behind the user's work
    /// and cleared by the same gate as an `open` action. Without a name the
    /// run may only take the frontmost app (never Osaurus: `activeWindow()`
    /// is nil while we're in front, so it falls back to the app the user was
    /// on before switching to Osaurus) once the user says yes.
    private static func settleTarget(
        targetApp: String?,
        driver: MacDriver,
        gate: ComputerUseGating,
        confirm: @escaping @Sendable (ActionPreview) async -> Bool,
        confirmUnavailable: @escaping @Sendable () async -> String?,
        confirmTakeover: @escaping @Sendable (String) async -> Bool,
        interrupt: InterruptToken,
        metrics: inout ComputerUseRunMetrics,
        feed: SubagentFeed
    ) async -> SettledTarget {
        if let app = targetApp?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty {
            let action = AgentAction(verb: .open, app: app)
            let effect = EffectClassifier.classify(
                action: action,
                appName: app,
                recipeSignals: AppRecipes.signals(for: app)
            )
            metrics.recordEffect(effect)
            let decision = await gate.evaluate(action: action, effect: effect, appName: app, targetLabel: app)
            if case .reject(let reason) = decision {
                return .refused(.gaveUp(reason: "Computer Use may not open \(app): \(reason)."))
            }
            var toolResult = ""
            var advanced = true
            var abort: RunOutcome? = nil
            guard
                await applyGate(
                    decision,
                    label: action.auditLabel(element: nil, app: nil),
                    effect: effect,
                    appName: app,
                    confirm: confirm,
                    confirmUnavailable: confirmUnavailable,
                    toolResult: &toolResult,
                    advancedStep: &advanced,
                    abort: &abort,
                    metrics: &metrics,
                    interrupt: interrupt,
                    feed: feed,
                    step: 0
                )
            else {
                return .refused(abort ?? .declined(app: app))
            }
            switch await handleOpen(action: action, driver: driver, feed: feed, step: 0) {
            case .opened(let pid, _, _, _, _):
                return .pid(pid)
            case .failure(let message):
                return .refused(.gaveUp(reason: "Could not open \(app): \(message)"))
            }
        }

        let candidate: (pid: Int32, name: String)?
        if let window = await driver.activeWindow() {
            candidate = (window.pid, window.app)
        } else if let pid = await FrontmostAppTracker.shared.lastNonSelfPid {
            candidate = (pid, await FrontmostAppTracker.shared.lastNonSelfAppName ?? "the app you were using")
        } else {
            candidate = nil
        }
        guard let candidate else {
            return .refused(
                .gaveUp(reason: "No app to work in. Name the app in `app`, or bring it to the front and try again.")
            )
        }
        if let reason = await confirmUnavailable() {
            metrics.confirmsUnpresentable += 1
            return .refused(
                .gaveUp(
                    reason:
                        "Taking over \(candidate.name) needs the user's approval, but \(reason). "
                        + "Name the app in `app` instead."
                )
            )
        }
        feed.emit(
            SubagentActivityEvent(step: 0, kind: .confirmRequested, title: "Take over \(candidate.name)?")
        )
        let approved = await confirmTakeover(candidate.name)
        if interrupt.isInterrupted || Task.isCancelled { return .refused(.interrupted) }
        metrics.takeoverApproved = approved
        guard approved else {
            feed.emit(SubagentActivityEvent(step: 0, kind: .denied, title: "Declined: take over \(candidate.name)"))
            return .refused(.declined(app: candidate.name))
        }
        feed.emit(SubagentActivityEvent(step: 0, kind: .confirmed, title: "Approved: take over \(candidate.name)"))
        return .pid(candidate.pid)
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
        // Open behind the user's work: the app launches without activating
        // (and never hidden, so its AX windows exist for the verify capture),
        // and an app that activates itself hands the front back. Input then
        // reaches it per-process, so the user keeps their own app in front.
        let result = await driver.open(identifier: identifier, background: true)
        switch result {
        case .success(let info):
            let snapshot = await driver.capture(pid: info.pid, tier: .ax)
            let view = AgentView.build(from: snapshot, previous: nil)
            // The readiness poll gave up AND the follow-up capture is empty:
            // the process exists but nothing is drivable yet. Reporting
            // "Opened X" here made the model act into a void and then read the
            // empty view as "X has no controls".
            if !info.ready, view.items.isEmpty {
                let message =
                    "\(info.name) is running (pid \(info.pid)) but exposed no accessible window "
                    + "within the readiness budget — it may still be starting, be hidden, or have "
                    + "no open window. `wait` a few seconds and `open` it again, or ask the user "
                    + "to bring one of its windows forward."
                feed.emit(
                    SubagentActivityEvent(
                        step: step,
                        kind: .act,
                        title: "Open \(info.name): not ready",
                        detail: message,
                        success: false
                    )
                )
                return .failure(message)
            }
            feed.emit(
                SubagentActivityEvent(step: step, kind: .act, title: "Opened \(info.name)", success: true)
            )
            var render = "Opened \(info.name).\n" + view.renderForModel()
            if !info.ready {
                render +=
                    "\n(\(info.name) took longer than expected to become ready; this view may be "
                    + "incomplete — `observe` before acting on anything that isn't listed.)"
            }
            return .opened(
                pid: info.pid,
                app: info.name,
                view: view,
                snapshot: snapshot,
                render: render
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
        point: CGPoint? = nil,
        destinationPoint: CGPoint? = nil,
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
        let performed = await performAct(
            action: action,
            element: element,
            destinationElement: destinationElement,
            point: point,
            destinationPoint: destinationPoint,
            pid: pid,
            driver: driver,
            lastSnapshot: lastSnapshot,
            metrics: &metrics,
            feed: feed,
            step: step
        )
        guard let result = performed.result else { return performed.message ?? "Unsupported action." }
        return await verifyAct(
            action: action,
            element: element,
            result: result,
            pid: pid,
            driver: driver,
            availability: availability,
            currentTier: &currentTier,
            pendingFrameImage: &pendingFrameImage,
            lastView: &lastView,
            lastSnapshot: &lastSnapshot,
            metrics: &metrics,
            feed: feed,
            step: step
        )
    }

    /// Report a target whose process exited, and tell the model how to recover.
    static func targetExited(app: String?, pid: Int32, feed: SubagentFeed, step: Int) -> String {
        let name = app ?? "The app"
        feed.emit(
            SubagentActivityEvent(
                step: step,
                kind: .blocked,
                title: "\(name) is no longer running",
                detail: "pid \(pid) exited; input was not posted"
            )
        )
        return "\(name) is no longer running (it quit or relaunched since it was opened), so "
            + "the action was not performed. Use `open` to attach to it again, then re-check "
            + "the view before continuing."
    }

    /// The driver result of one act, or why it couldn't be attempted.
    struct PerformedAct {
        var result: CUActionResult?
        var message: String?
    }

    /// Controls a plain click and `AXPress` do the same thing to.
    static let pressableRoles: Set<String> = [
        "button", "checkbox", "radiobutton", "menuitem", "menubutton", "popupbutton", "link",
    ]

    /// A plain click whose point lands on a pressable control goes through the element (`AXPress`, then a
    /// window-bound click): a background SwiftUI app such as Calculator drops a click posted to its pid.
    static func pressesAsElement(_ verb: AgentVerb, _ element: CUElement?) -> Bool {
        guard verb == .click, let element else { return false }
        return element.actions.contains("press") && pressableRoles.contains(element.role.lowercased())
    }

    /// Post one action (with the stale-ref coordinate fallback) and report the
    /// driver result. No verify capture: `act` and `runBatch` take that after.
    static func performAct(
        action: AgentAction,
        element: CUElement?,
        destinationElement: CUElement?,
        point: CGPoint?,
        destinationPoint: CGPoint?,
        pid: Int32,
        driver: MacDriver,
        lastSnapshot: CUSnapshot?,
        metrics: inout ComputerUseRunMetrics,
        feed: SubagentFeed,
        step: Int
    ) async -> PerformedAct {
        // The target can quit while an approval card is up or between batch
        // steps, after the pre-gate check passed.
        if await driver.isRunning(pid: pid) == false {
            return PerformedAct(message: targetExited(app: lastSnapshot?.app, pid: pid, feed: feed, step: step))
        }
        metrics.actsAttempted += 1
        let elementCenter = element.map { CGPoint(x: $0.center.x, y: $0.center.y) }
        var result: CUActionResult
        switch action.verb {
        case .click, .doubleClick, .rightClick:
            let button: CUMouseButton = action.verb == .rightClick ? .right : .left
            let double = action.verb == .doubleClick
            if let point, !pressesAsElement(action.verb, element) {
                result = await driver.coordinate(
                    .click(x: Double(point.x), y: Double(point.y), button: button, doubleClick: double, pid: pid)
                )
            } else if let element {
                result = await driver.perform(.click(id: element.id, button: button, doubleClick: double))
            } else {
                return PerformedAct(message: "\(action.verb.rawValue) needs a resolved target.")
            }
        case .hover:
            guard let at = point ?? elementCenter else {
                return PerformedAct(message: "hover needs a resolved target.")
            }
            result = await driver.coordinate(.move(x: Double(at.x), y: Double(at.y), pid: pid))
        case .select:
            guard let element else { return PerformedAct(message: "select needs a resolved control.") }
            result = await driver.perform(.selectOption(id: element.id, option: action.option ?? ""))
        case .drag:
            guard let start = point ?? elementCenter else {
                return PerformedAct(message: "drag needs a resolved start target.")
            }
            guard let end = destinationPoint ?? destinationElement.map({ CGPoint(x: $0.center.x, y: $0.center.y) })
            else { return PerformedAct(message: "drag needs a resolved destination.") }
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
            let replace = action.replace ?? true
            if let point, !(element.map { isTextBearing(role: $0.role) } ?? false) {
                // Nothing text-bearing is under the point: click there to put
                // the caret in place, then type into whatever took focus.
                let focus = await driver.coordinate(.click(x: Double(point.x), y: Double(point.y), pid: pid))
                guard focus.success else {
                    result = focus
                    break
                }
                result = await driver.perform(.typeText(id: nil, pid: pid, text: action.text ?? "", replace: replace))
            } else {
                result = await driver.perform(
                    .typeText(id: element?.id, pid: pid, text: action.text ?? "", replace: replace)
                )
            }
        case .setValue:
            guard let element else { return PerformedAct(message: "set_value needs a resolved target.") }
            result = await driver.perform(.setValue(id: element.id, value: action.text ?? ""))
        case .clear:
            guard let element else { return PerformedAct(message: "clear needs a resolved target.") }
            result = await driver.perform(.clearField(id: element.id))
        case .pressKey:
            let times = (action.repeatCount ?? 1).clamped(to: 1 ... AgentAction.maxKeyRepeat)
            result = .failure("press_key did not run.")
            for _ in 0 ..< times {
                result = await driver.perform(
                    .pressKey(pid: pid, key: action.key ?? "", modifiers: action.modifiers)
                )
                if !result.success { break }
            }
        case .scroll where point == nil && (element.map { AXAdjustment.supports($0.actions) } ?? false):
            // A slider or stepper: step it through its own AX actions rather
            // than posting a wheel event at it.
            let dir = action.direction ?? .down
            result = await driver.perform(
                .adjust(
                    id: element!.id,
                    increment: AXAdjustment.action(for: dir) == AXAdjustment.increment,
                    steps: (action.amount ?? 1).clamped(to: 1 ... AXAdjustment.maxSteps)
                )
            )
        case .scroll:
            let dir = action.direction ?? .down
            let amount = Int32((action.amount ?? 3).clamped(to: Self.scrollAmountRange))
            let at = point ?? elementCenter ?? focusedWindowCenter(lastSnapshot)
            result = await driver.coordinate(
                .scroll(
                    direction: dir,
                    amount: amount,
                    x: at.map { Double($0.x) },
                    y: at.map { Double($0.y) },
                    pid: pid
                )
            )
        default:
            return PerformedAct(message: "Unsupported action.")
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
        // A ref that died with its process is not a stale ref: the old frame
        // now belongs to whatever window is underneath.
        if (result.removed || result.stale), let element, await driver.isRunning(pid: pid) != false {
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
                title: action.auditLabel(element: element, destination: destinationElement, app: lastSnapshot?.app),
                detail: result.error,
                success: result.success
            )
        )
        metrics.recordRoute(result.routeUsed)
        return PerformedAct(result: result)
    }

    /// Re-perceive after an act and report the delta to the model.
    static func verifyAct(
        action: AgentAction,
        element: CUElement?,
        result: CUActionResult,
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
        // Verify: re-perceive at the current tier and report the delta. If the
        // action still failed stale/removed even after the coordinate fallback,
        // escalate the capture tier (ax->som->vision) so the re-perception
        // carries pixels the model can use to relocate the target, instead of
        // handing back the same AX view that just failed to resolve.
        var verifyTier = currentTier
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
        let snapshot = await settledVerificationSnapshot(
            action: action,
            element: element,
            result: result,
            pid: pid,
            tier: verifyTier,
            driver: driver
        )
        let view = AgentView.build(from: snapshot, previous: lastView)
        lastView = view
        lastSnapshot = snapshot
        // Stage any frame for attachment after this step's tool result.
        if verifyTier != .ax { pendingFrameImage = snapshot.image }
        if view.hasChanges { metrics.verifyChanged += 1 }
        // A driver "success" only means the input was posted (or AXPress
        // returned). Without an observed change it is unproven, and the
        // model is told so — calling it "succeeded" here is what let stalled
        // runs end in a confident `done`.
        let unverified = result.success && !view.hasChanges
        if unverified { metrics.unverifiedActs += 1 }
        feed.emit(
            SubagentActivityEvent(
                step: step,
                kind: .verify,
                title: view.hasChanges
                    ? "Change detected"
                    : (result.success ? "No visible change (input unverified)" : "No visible change"),
                // Neutral (nil) for an unverified post: neither a proven
                // landing nor a driver failure.
                success: unverified ? nil : result.success
            )
        )

        var out: String
        if !result.success {
            out = "Action failed: \(result.error ?? "unknown")."
        } else if view.hasChanges {
            out = "Action succeeded."
        } else {
            out =
                "Input was posted, but no change was observed in the app afterwards, so it cannot "
                + "be confirmed that it took effect."
        }
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
        if view.hasChanges {
            out += " The view changed:\n" + view.renderChanges()
        } else if unverified {
            out +=
                " The view looks unchanged. If the app may render late, `wait` or `observe` before "
                + "retrying; do not report the task done unless the intended state is visible."
        } else {
            out += " The view looks unchanged."
        }
        out += "\n\nCurrent view:\n" + view.renderForModel()
        return out
    }

    /// A posted keyboard event is not the same thing as a target app having
    /// processed that event. Cocoa and Chromium can acknowledge the final
    /// key-up while their AX value still trails by one or more characters. A
    /// single immediate capture therefore feeds a transient value back to the
    /// planner, which can turn a completed edit into a destructive retry.
    ///
    /// Only successful text mutations use the bounded settle loop. Navigation
    /// and pointer actions keep the existing one-capture behavior. Wholesale
    /// replacements have an exact expected value and may finish as soon as it
    /// appears; append-style edits require the target value to repeat across
    /// two captures. The latest real AX snapshot always wins at the deadline —
    /// no synthetic success or model-facing value is invented.
    private static func settledVerificationSnapshot(
        action: AgentAction,
        element: CUElement?,
        result: CUActionResult,
        pid: Int32,
        tier: CaptureTier,
        driver: MacDriver
    ) async -> CUSnapshot {
        var snapshot = await driver.capture(pid: pid, tier: tier)
        guard result.success, isTextMutation(action) else { return snapshot }

        let expectedValue = expectedWholesaleTextValue(action)
        var previousValue = verificationValue(in: snapshot, matching: element)

        if expectedValue.map({ previousValue == $0 }) == true { return snapshot }

        // Five follow-up reads at 50 ms intervals bound verification latency at
        // 250 ms while still covering the live TextEdit trace where the first
        // AX read ended at `Hello agai` and the next stable read was complete.
        for _ in 0 ..< 5 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            let next = await driver.capture(pid: pid, tier: tier)
            let nextValue = verificationValue(in: next, matching: element)

            if expectedValue.map({ nextValue == $0 }) == true { return next }
            if expectedValue == nil, let nextValue, nextValue == previousValue { return next }

            snapshot = next
            previousValue = nextValue
        }
        return snapshot
    }

    /// Match the same logical text control across snapshot generations. AX ids
    /// are generation-scoped, so identity comes from the owning window plus
    /// path/role/label, with the focused control as the final pid-context
    /// typing fallback.
    private static func verificationValue(
        in snapshot: CUSnapshot,
        matching element: CUElement?
    ) -> String? {
        guard let element else {
            return snapshot.elements.first(where: {
                $0.focused && isTextBearing(role: $0.role)
            })?.value
        }

        let sameWindowAndRole = snapshot.elements.filter {
            $0.windowId == element.windowId && $0.role == element.role
        }
        if let path = element.path,
            let exactPath = sameWindowAndRole.first(where: { $0.path == path })
        {
            return exactPath.value
        }
        if let label = element.label,
            let exactLabel = sameWindowAndRole.first(where: { $0.label == label })
        {
            return exactLabel.value
        }
        return sameWindowAndRole.first(where: { $0.focused })?.value
            ?? sameWindowAndRole.first?.value
    }

    private static func isTextMutation(_ action: AgentAction) -> Bool {
        switch action.verb {
        case .type, .setValue, .clear: return true
        default: return false
        }
    }

    private static func expectedWholesaleTextValue(_ action: AgentAction) -> String? {
        switch action.verb {
        case .setValue: return action.text ?? ""
        case .clear: return ""
        case .type where action.replace ?? true: return action.text ?? ""
        default: return nil
        }
    }

    private static func isTextBearing(role: String) -> Bool {
        let role = role.lowercased()
        return role.contains("text") || role == "combobox" || role == "searchfield"
    }

    // MARK: - Grounding calibration

    /// `vision` with its grounding settled: unchanged unless a local bundle
    /// still needs calibrating, in which case the model is measured through
    /// the loop's own model step, the outcome is cached for the bundle, and
    /// the run continues with the measured frame (or marks only).
    static func groundedVision(
        _ vision: VisionContext,
        engine: (any ResponsesEngineProtocol)?,
        modelId: String,
        sessionId: String,
        enableThinking: Bool?,
        reasoningEffort: String?,
        limits: RunLimits,
        interrupt: InterruptToken,
        feed: SubagentFeed,
        store: GroundingCalibrationStore = .shared
    ) async -> VisionContext {
        guard let key = vision.pendingCalibration, let engine else { return vision }
        feed.emit(
            SubagentActivityEvent(
                step: 0,
                kind: .perceive,
                title: "Checking how this model points at screenshots",
                detail: "one-time, \(GroundingCalibration.screenSizes.count) test screens"
            )
        )
        let result: GroundingCalibration.Result
        do {
            result = try await GroundingCalibration.run(
                budget: key.budget,
                isInterrupted: { interrupt.isInterrupted }
            ) { messages in
                try await runModelStep(
                    {
                        try await modelStep(
                            engine: engine,
                            modelId: modelId,
                            sessionId: sessionId,
                            messages: messages,
                            enableThinking: enableThinking,
                            reasoningEffort: reasoningEffort,
                            tool: GroundingCalibration.toolSpec,
                            positionLimit: limits.contextPositions
                        )
                    },
                    timeout: limits.modelStepTimeoutSeconds,
                    maxRetries: 0,
                    interrupt: interrupt,
                    feed: feed,
                    step: 0
                )
            }
        } catch {
            // Interrupted: leave the bundle uncalibrated and run on marks.
            return vision.withGrounding(nil)
        }
        store.record(result, for: key)
        let hits = result.hits.sorted { $0.value > $1.value }.first
        let speed = result.decodeTokensPerSecond.isEmpty
            ? "" : String(format: ", %.1f tok/s", result.decodeTokensPerSecond.reduce(0, +)
                / Double(result.decodeTokensPerSecond.count))
        switch result.outcome {
        case .frame(let frame):
            feed.emit(
                SubagentActivityEvent(
                    step: 0,
                    kind: .perceive,
                    title: "This model points in \(frame.label)",
                    detail: "\(hits?.value ?? 0)/\(result.trials) test targets hit\(speed)"
                )
            )
            return vision.withGrounding(GroundingProfile(frame: frame, source: .calibrated))
        case .marksOnly:
            feed.emit(
                SubagentActivityEvent(
                    step: 0,
                    kind: .perceive,
                    title: "This model will address elements by mark",
                    detail: "best frame hit \(hits?.value ?? 0)/\(result.trials) test targets\(speed)"
                )
            )
            return vision.withGrounding(nil)
        }
    }

    // MARK: - Model step

    /// Tokens the context budget holds back for the `agent_action` schema.
    static let toolSchemaReserveTokens = 500

    /// The smallest history window one step can run in: the system prompt
    /// and goal, the action schema, one screenshot when the model takes
    /// images (at most one is ever in context), one view listing at the
    /// delegated per-turn tool-result allowance, and one response. Token math
    /// matches `DelegatedRunContract` (chars × 3 / 8, rounded up).
    static func minimumStepPositions(
        goal: String,
        policySummary: String,
        vision: VisionContext
    ) -> Int {
        let pointing = PointingSurface(vision.grounding)
        let characters = systemPrompt(policySummary: policySummary, pointing: pointing).count + goal.count
        let textTokens = (characters * 3 + 7) / 8
        let imageTokens = vision.modelAcceptsImages ? Attachment.imageTokenCeiling : 0
        return textTokens + toolSchemaReserveTokens + imageTokens
            + DelegatedRunContract.toolResultAllowancePerTurn
            + AgentLoopBudget.defaultResponseReservation
    }

    /// Sparse model usage and the exact assistant snapshot. Scripted providers
    /// explicitly report zero tokens because they make no model call.
    struct ModelStepResult: Sendable {
        var call: ModelActionCall?
        var tokens: Int? = nil
        var tokensPerSecond: Double? = nil
        var assistantMessage: ChatMessage? = nil
        var inputTokenCount: Int? = nil
        var outputTokenCount: Int? = nil
    }

    static func modelStep(
        engine: any ResponsesEngineProtocol,
        modelId: String,
        sessionId: String,
        messages: [ChatMessage],
        enableThinking: Bool?,
        reasoningEffort: String?,
        attempt: DesktopResponsesAttempt? = nil,
        pointing: PointingSurface = .frame(.pixels),
        tool: Tool? = nil,
        positionLimit: Int? = nil
    ) async throws -> ModelStepResult {
        var request = ResponsesInferenceRequest(model: modelId, input: messages)
        request.tools = [tool ?? AgentAction.toolSpec(pointing: pointing)]
        request.toolChoice = AgentAction.forcedToolChoice
        request.sessionID = sessionId
        request.context.admissionPositionLimit = positionLimit
        request.context.samplingParametersAreImplicit = true
        request.context.isAgentRequest = true
        request.generation.enableThinking = enableThinking
        request.generation.reasoningEffort = reasoningEffort
        let generateStarted = Date()
        let response = try await DesktopResponsesModelStep.completeResponse(
            engine: engine, request: request, attempt: attempt
        )
        ComputerUseTraceLog.record(
            request: request, response: response,
            elapsedSeconds: Date().timeIntervalSince(generateStarted)
        )
        let call = try DesktopResponsesModelStep.actionCall(
            from: response, expectedTool: AgentAction.toolName, required: true
        )
        let total = response.inputTokenCount.flatMap { input in
            response.completion.tokenCount.map { input + $0 }
        }
        return ModelStepResult(
            call: call, tokens: total, tokensPerSecond: response.completion.tokensPerSecond,
            assistantMessage: try response.completedAssistantInput(),
            inputTokenCount: response.inputTokenCount, outputTokenCount: response.completion.tokenCount
        )
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

    /// ChatEngine's fail-closed signal for a required/named local tool turn
    /// that reached EOS without a parsed invocation. This is a protocol-shape
    /// miss, not a transient inference transport failure: retrying the exact
    /// same prompt inside `runModelStep` cannot supply the corrective
    /// `agent_action` nudge owned by the outer Computer Use loop.
    private static func isMissingRequiredAgentActionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "OsaurusToolChoice" && nsError.code == 422
    }

    /// Run one step with its explicit deadline/retry budget. Production retries
    /// require a transient transport failure before any typed output; scripted
    /// providers retain their explicit fixture retry policy.
    static func runModelStep<T: Sendable>(
        _ produce: @escaping @Sendable () async throws -> T,
        timeout: TimeInterval,
        maxRetries: Int,
        interrupt: InterruptToken? = nil,
        feed: SubagentFeed,
        step: Int,
        shouldRetry: (@Sendable (Error) -> Bool)? = nil
    ) async throws -> T {
        var attempt = 0
        while true {
            if interrupt?.isInterrupted == true { throw CancellationError() }
            do {
                return try await cancelling(on: interrupt) {
                    try await withModelStepTimeout(timeout, produce)
                }
            } catch is CancellationError {
                throw CancellationError()  // interrupt/teardown — don't retry
            } catch {
                if interrupt?.isInterrupted == true { throw CancellationError() }
                if isMissingRequiredAgentActionError(error) {
                    throw error
                }
                if attempt >= maxRetries || shouldRetry?(error) == false { throw error }
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

    /// Run `op` in a child task that a tripped `interrupt` cancels, so Stop
    /// ends an in-flight prefill/decode instead of waiting for it.
    private static func cancelling<T: Sendable>(
        on interrupt: InterruptToken?,
        _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let interrupt else { return try await op() }
        let task = Task { try await op() }
        let observer = interrupt.observeInterrupt { task.cancel() }
        defer { interrupt.removeInterruptObserver(observer) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
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
        if action.verb == .batch {
            return "batch[" + action.actions.map(actionSignature).joined(separator: ";") + "]"
        }
        return [
            action.verb.rawValue,
            targetKey(action.target),
            targetKey(action.to),
            action.text ?? "",
            action.key ?? "",
            action.modifiers.joined(separator: "+"),
            action.direction?.rawValue ?? "",
            action.app ?? "",
            action.option ?? "",
            action.repeatCount.map(String.init) ?? "",
        ].joined(separator: "|")
    }

    // MARK: - Helpers

    private static func requiresTarget(_ verb: AgentVerb) -> Bool {
        switch verb {
        case .click, .doubleClick, .rightClick, .drag, .setValue, .clear, .hover, .select: return true
        default: return false
        }
    }

    private static func targetKey(_ target: AgentTarget?) -> String {
        guard let target else { return "<none>" }
        if let point = target.point { return "point:\(Int(point.x)),\(Int(point.y))" }
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

    /// The tier perception rests at between escalations: `som` when frames
    /// reach the model by default, otherwise `ax`.
    static func restingTier(vision: VisionContext, availability: MacDriverAvailability) -> CaptureTier {
        vision.attachesPixelsByDefault(availability: availability) ? .som : .ax
    }

    /// Attach a freshly captured frame to the model conversation when the
    /// `VisionContext` allows it. The frame is first fitted to the run's
    /// `FrameBudget`; a `som` frame then gets the mark numbers of `snapshot`'s
    /// elements (the list the model was just shown). Local models receive the
    /// frame directly; remote models receive a `FrameScrubber`-redacted frame
    /// routed through `CaptureRouter.cloudRoute`, and only with consent, with
    /// the marks drawn after the scrub so the masks don't cover them.
    /// Otherwise this is a no-op and the loop continues on the AX text alone.
    @discardableResult
    private static func attachFrame(
        image captured: CUImage,
        snapshot: CUSnapshot?,
        vision: VisionContext,
        consent: inout RunCloudVisionConsent,
        requestConsent: @Sendable () async -> CloudVisionConsentChoice,
        availability: MacDriverAvailability,
        messages: inout [ChatMessage],
        imageTokensInContext: inout Int,
        metrics: inout ComputerUseRunMetrics,
        feed: SubagentFeed,
        step: Int,
        scrubFrame: CloudFrameScrubOperation
    ) async throws -> CUImage? {
        let effective = vision.withConsent(consent.granted)
        let image = FramePreparer.fit(captured, to: vision.frameBudget)
        let marks = snapshot?.tier == .som ? FramePreparer.marks(for: snapshot, in: image) : []
        switch VisionAttachment.decide(image: image, context: effective, availability: availability) {
        case .none:
            // The frame can't attach as-is. If the ONLY thing missing is
            // cloud-vision consent (remote image model + Screen Recording on),
            // offer a just-in-time prompt once per run rather than silently
            // dropping to AX-only.
            return try await offerJustInTimeCloudConsent(
                image: image,
                marks: marks,
                vision: vision,
                consent: &consent,
                requestConsent: requestConsent,
                availability: availability,
                messages: &messages,
                imageTokensInContext: &imageTokensInContext,
                metrics: &metrics,
                feed: feed,
                step: step,
                scrubFrame: scrubFrame
            )
        case .localFrame(let img):
            let shown = FramePreparer.drawMarks(marks, on: img)
            appendImageMessage(
                shown,
                note:
                    "Screenshot of the current view"
                    + (shown == img ? "" : "; each numbered red box is that `mark` in the element list")
                    + ". Use it to locate the element, then address it by "
                    + (vision.grounding == nil ? "`mark` or `describe`." : "`mark`, `describe`, or `target.point`."),
                pointing: PointingSurface(vision.grounding),
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
            return shown
        case .needsScrubForCloud(let img):
            return try await attachScrubbedForCloud(
                img,
                marks: marks,
                vision: vision,
                availability: availability,
                messages: &messages,
                imageTokensInContext: &imageTokensInContext,
                metrics: &metrics,
                feed: feed,
                step: step,
                scrubFrame: scrubFrame
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
        marks: [FrameMark],
        vision: VisionContext,
        consent: inout RunCloudVisionConsent,
        requestConsent: @Sendable () async -> CloudVisionConsentChoice,
        availability: MacDriverAvailability,
        messages: inout [ChatMessage],
        imageTokensInContext: inout Int,
        metrics: inout ComputerUseRunMetrics,
        feed: SubagentFeed,
        step: Int,
        scrubFrame: CloudFrameScrubOperation
    ) async throws -> CUImage? {
        let effective = vision.withConsent(consent.granted)
        guard
            !consent.asked,
            VisionAttachment.wouldAttachWithConsent(
                image: image,
                context: effective,
                availability: availability
            )
        else { return nil }
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
            return nil
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
        else { return nil }
        return try await attachScrubbedForCloud(
            img,
            marks: marks,
            vision: vision,
            availability: availability,
            messages: &messages,
            imageTokensInContext: &imageTokensInContext,
            metrics: &metrics,
            feed: feed,
            step: step,
            scrubFrame: scrubFrame
        )
    }

    /// Scrub a frame in the run's resolved cloud mode and attach it through the
    /// consented cloud route. The route is the only way to reach `.cloudVision`
    /// and only accepts a `ScrubbedFrame`, so a raw or unconsented frame can
    /// never be attached here. Only called once consent is effectively granted.
    @discardableResult
    static func attachScrubbedForCloud(
        _ img: CUImage,
        marks: [FrameMark] = [],
        vision: VisionContext,
        availability: MacDriverAvailability,
        messages: inout [ChatMessage],
        imageTokensInContext: inout Int,
        metrics: inout ComputerUseRunMetrics,
        feed: SubagentFeed,
        step: Int,
        scrubFrame: CloudFrameScrubOperation
    ) async throws -> CUImage? {
        let mode = vision.cloudScrubMode
        let masked = try await scrubFrame(img, mode)
        let frame = masked.withMarks(marks)
        guard
            let route = CaptureRouter.cloudRoute(
                scrubbed: frame,
                consentGranted: true,
                availability: availability
            ),
            case .cloudVision(let scrubbed) = route
        else { return nil }
        appendImageMessage(
            scrubbed.image,
            note: cloudFrameNote(mode: mode)
                + (frame.image == masked.image
                    ? "" : " Each numbered red box is that `mark` in the element list; you can address it by `mark`."),
            pointing: PointingSurface(vision.grounding),
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
        return scrubbed.image
    }

    private static func frameScrubFailureResult(
        _ error: Error,
        step: Int,
        completedSteps: Int,
        metrics: ComputerUseRunMetrics,
        feed: SubagentFeed
    ) -> ComputerUseRunResult {
        var metrics = metrics
        metrics.steps = completedSteps
        let outcome: RunOutcome
        if error is CancellationError {
            outcome = .interrupted
        } else {
            let reason = error.localizedDescription
            feed.emit(
                SubagentActivityEvent(
                    step: step,
                    kind: .error,
                    title: "Screenshot could not be redacted",
                    detail: reason
                )
            )
            outcome = .failed(reason: reason)
        }
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
        pointing: PointingSurface,
        into messages: inout [ChatMessage],
        imageTokensInContext: inout Int
    ) {
        dropPriorImages(&messages)
        let dataUrl = "data:\(image.mimeType);base64,\(image.base64)"
        var note = note
        if image.region != nil {
            switch pointing {
            case .frame(.pixels):
                note += " It is \(image.width)×\(image.height) pixels; a `target.point` is in these pixels."
            case .frame(.normalized1000):
                note += " A `target.point` is on a 0–1000 scale of its width and height."
            case .frame(.normalizedUnit):
                note += " A `target.point` is on a 0–1 scale of its width and height."
            case .marksOnly, .unstated:
                break
            }
        }
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

    // MARK: - Stale view compaction

    /// Placeholder left where an older screen listing was removed.
    static let compactedViewMarker = "(older screen listing omitted; act on the latest view)"
    /// Full screen listings always kept (the current one and the one before,
    /// so a verify delta still has its reference).
    static let keptRecentViews = 2
    /// Stale listings allowed to pile up before one compaction pass.
    static let viewCompactionBatch = 8

    /// Collapse all but the latest `keepRecent` screen listings once
    /// `batchSize` stale ones have accumulated. Every step appends a full
    /// listing (~2.5K tokens) and the history re-sends all of them, so a
    /// 30-step run grew from 3.5K to 68K prompt tokens and each step got
    /// slower. Rewriting old messages on EVERY step would keep the prompt
    /// minimal but change the prefix each time, defeating provider prompt
    /// caching; batching rewrites the history once per batch and keeps it
    /// append-only in between. The goal text and each action's result line
    /// survive; only the listing after them is dropped. Returns how many
    /// listings were collapsed.
    @discardableResult
    static func compactStaleViews(
        _ messages: inout [ChatMessage],
        keepRecent: Int = keptRecentViews,
        batchSize: Int = viewCompactionBatch
    ) -> Int {
        let viewIndices = messages.indices.filter { viewListingStart(in: messages[$0].content) != nil }
        guard viewIndices.count >= keepRecent + batchSize else { return 0 }
        let stale = viewIndices.dropLast(keepRecent)
        for index in stale {
            let message = messages[index]
            guard let content = message.content, let cut = viewListingStart(in: content) else { continue }
            let kept = content[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
            let replaced = kept.isEmpty ? compactedViewMarker : kept + "\n" + compactedViewMarker
            messages[index] = ChatMessage(
                role: message.role,
                content: replaced,
                tool_calls: message.tool_calls,
                tool_call_id: message.tool_call_id
            )
        }
        return stale.count
    }

    /// Where a rendered `AgentView` listing begins in a message: the
    /// "Current view:" label when present (step results, the goal message),
    /// else the listing header line (`open` results start straight at
    /// "App: … [tier: …]"). Nil for messages without a listing, including
    /// ones already compacted.
    static func viewListingStart(in content: String?) -> String.Index? {
        guard let content else { return nil }
        if let label = content.range(of: "Current view:\n") { return label.lowerBound }
        guard let tier = content.range(of: " [tier: ") else { return nil }
        let lineStart = content[..<tier.lowerBound].lastIndex(of: "\n").map { content.index(after: $0) }
            ?? content.startIndex
        return content[lineStart...].hasPrefix("App: ") ? lineStart : nil
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

    static func systemPrompt(policySummary: String = "", pointing: PointingSurface = .frame(.pixels)) -> String {
        let looking: String
        let addressing: String
        switch pointing {
        case .frame(.pixels):
            looking = "`screenshot` for pixels and `zoom` (`region`) for a close-up"
            addressing = "or `target.point` with pixel coordinates in the latest screenshot"
        case .frame(.normalized1000):
            looking = "`screenshot` for pixels and `zoom` (`region`) for a close-up"
            addressing = "or `target.point` with coordinates on a 0–1000 scale of the latest screenshot's width and height"
        case .frame(.normalizedUnit):
            looking = "`screenshot` for pixels and `zoom` (`region`) for a close-up"
            addressing = "or `target.point` with coordinates on a 0–1 scale of the latest screenshot's width and height"
        case .marksOnly:
            looking = "`screenshot` for pixels"
            addressing = "and nothing else; this model doesn't point by screenshot coordinates"
        case .unstated:
            looking = "`screenshot` for pixels and `zoom` (`region`) for a close-up"
            addressing = "or `target.point` on the element in the latest screenshot"
        }
        var prompt = """
            You are Computer Use, an agent that operates macOS apps for the user through an accessibility \
            driver. You perceive the screen as a numbered list of elements and act by proposing ONE action \
            at a time.

            Rules:
            - Each turn, call the `agent_action` tool exactly once.
            - Verbs: look with `observe`/`find`, or \(looking); interact with `click`, `double_click`, \
            `right_click` (context menu), `hover`, `select` (pick an `option` from a popup or menu), `type`, `set_value`, `clear`, `press_key` (`repeat` to \
            press it several times), `scroll`, and `drag` (`target` is the start, `to` is the destination); \
            switch apps with `open`; pause for async UI (a spinner or load) with `wait` (`seconds`); finish \
            with `done`/`give_up`.
            - Address elements by the `mark` number shown in the current view. If you don't have a mark, \
            use `target.describe` with the element's role and label, \(addressing).
            - When the next few steps don't depend on each other's results (filling several fields), send \
            them as one `batch` with `actions`. It stops at the first step that fails or needs approval.
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

/// Accumulated seconds the run spent waiting on the USER (confirm cards,
/// cloud-vision consent). Credited back to the wall-clock deadline so those
/// waits never count against the run's own budget. Lock-based rather than an
/// actor because it is read synchronously at the loop boundary.
final class UserWaitCredit: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulated: TimeInterval = 0

    var total: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return accumulated
    }

    func add(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        lock.lock()
        accumulated += seconds
        lock.unlock()
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
