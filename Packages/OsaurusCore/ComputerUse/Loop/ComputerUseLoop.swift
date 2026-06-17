//
//  ComputerUseLoop.swift
//  OsaurusCore — Computer Use
//
//  The perceive → decide → gate → act → verify controller. The model only
//  ever decodes one `AgentAction` per step (forced `tool_choice`); the
//  harness owns every deterministic decision: which element the mark maps
//  to, whether the gate allows it, and whether the action actually landed.
//
//  Runs as a nested subagent inside `ComputerUseTool` (the `sandbox_reduce`
//  pattern), so the inner steps never leak into the parent chat transcript —
//  they surface only through the `ComputerUseFeed`.
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

    public init(
        maxSteps: Int = 24,
        maxConsecutiveInvalid: Int = 3,
        maxConsecutiveReobserve: Int = 2,
        maxConsecutiveDeadEnd: Int = 3,
        wallClockSeconds: TimeInterval = 300
    ) {
        self.maxSteps = max(1, maxSteps)
        self.maxConsecutiveInvalid = max(1, maxConsecutiveInvalid)
        self.maxConsecutiveReobserve = max(1, maxConsecutiveReobserve)
        self.maxConsecutiveDeadEnd = max(1, maxConsecutiveDeadEnd)
        self.wallClockSeconds = wallClockSeconds
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
        case .gaveUp(let r): return "Gave up: \(r)"
        case .stepCapReached: return "Stopped: reached the step limit before finishing."
        case .deadEnd(let r): return "Stopped: \(r)"
        case .interrupted: return "Stopped by user."
        case .failed(let r): return "Failed: \(r)"
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

public enum ComputerUseLoop {

    /// Drive a goal to completion. Pure orchestration over the injected
    /// `MacDriver` / `ComputerUseGating` / confirm surface — no UI, no
    /// registry coupling, so it's fully testable with `MockMacDriver`.
    public static func run(
        goal: String,
        modelId: String,
        driver: MacDriver,
        gate: ComputerUseGating,
        feed: ComputerUseFeed,
        interrupt: InterruptToken,
        confirm: @escaping @Sendable (ActionPreview) async -> Bool,
        limits: RunLimits = RunLimits(),
        policySummary: String = "",
        vision: VisionContext = .none,
        sessionId: String
    ) async -> ComputerUseRunResult {
        let deadline = Date().addingTimeInterval(limits.wallClockSeconds)
        let engine = ChatEngine(source: .chatUI)

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

        // Driver state.
        var currentPid: Int32? = await driver.activeWindow()?.pid
        var currentApp: String? = nil
        var lastView: AgentView? = nil
        var lastSnapshot: CUSnapshot? = nil
        // Apps whose recipe hint has already been injected (once per app).
        var hintedApps: Set<String> = []
        // Estimated tokens of the single screenshot currently in context (0 = none).
        var imageTokensInContext = 0

        // Initial perception so the model's first turn has something to act on.
        let initialView = await perceive(
            pid: currentPid,
            driver: driver,
            previous: nil,
            feed: feed,
            step: 0
        )
        lastView = initialView.view
        lastSnapshot = initialView.snapshot
        if let app = initialView.snapshot?.app { currentApp = app }

        messages.append(
            ChatMessage(
                role: "user",
                content: "Goal: \(goal)\n\nCurrent view:\n" + initialView.render
            )
        )
        appendAppGuidance(app: currentApp, into: &messages, hinted: &hintedApps)

        var step = 0
        var consecutiveInvalid = 0
        var consecutiveDeadEnd = 0
        var lastReobserveTargetKey: String? = nil
        var consecutiveReobserve = 0

        func terminate(_ outcome: RunOutcome) -> ComputerUseRunResult {
            metrics.steps = step
            feed.emit(
                FeedEvent(
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
            let parsed: (id: String, arguments: String)?
            do {
                parsed = try await modelStep(
                    engine: engine,
                    modelId: modelId,
                    sessionId: sessionId,
                    messages: input.messages
                )
            } catch {
                return terminate(.failed(reason: error.localizedDescription))
            }

            // The model ignored the forced tool call and emitted text. Re-ask.
            guard let call = parsed else {
                consecutiveInvalid += 1
                feed.emit(FeedEvent(step: step, kind: .retry, title: "Model did not call agent_action"))
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
                feed.emit(FeedEvent(step: step, kind: .retry, title: "Invalid action", detail: reason))
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
                FeedEvent(
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

            // Build the tool-result that closes this step (new view + outcome).
            var toolResult = ""
            var advancedStep = true
            // A frame captured during an escalated re-perceive, attached to the model
            // AFTER this step's tool result (so tool_call -> tool_result stays intact).
            var pendingFrameImage: CUImage? = nil

            switch action.verb {
            case .observe:
                let p = await perceive(
                    pid: currentPid,
                    driver: driver,
                    previous: lastView,
                    feed: feed,
                    step: step + 1
                )
                lastView = p.view
                lastSnapshot = p.snapshot
                toolResult = p.render

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

            case .click, .type, .setValue, .clear, .pressKey, .scroll:
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

                // Classify the real effect (verb baseline refined upward by the
                // resolved element + app context), then let the injected gate decide.
                let effect = EffectClassifier.classify(
                    action: action,
                    resolvedRole: resolvedElement?.role,
                    resolvedLabel: resolvedElement?.label,
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
                        pid: pid,
                        driver: driver,
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
        feed: ComputerUseFeed,
        step: Int
    ) async -> Bool {
        switch decision {
        case .reject(let reason):
            metrics.blocked += 1
            feed.emit(
                FeedEvent(step: step, kind: .blocked, title: "Blocked: \(action.feedLabel)", detail: reason)
            )
            toolResult = "That action is not allowed: \(reason). Choose a different action."
            advancedStep = false
            return false
        case .confirm(let preview):
            metrics.confirmsRequested += 1
            feed.emit(
                FeedEvent(
                    step: step,
                    kind: .confirmRequested,
                    title: "Confirm: \(preview.summary)",
                    detail: preview.note
                )
            )
            if await confirm(preview) {
                metrics.confirmsApproved += 1
                feed.emit(FeedEvent(step: step, kind: .confirmed, title: "Approved: \(action.feedLabel)"))
                return true
            }
            metrics.confirmsDeclined += 1
            feed.emit(FeedEvent(step: step, kind: .denied, title: "Declined: \(action.feedLabel)"))
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
        feed: ComputerUseFeed,
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
            FeedEvent(
                step: step,
                kind: .perceive,
                title: "Looked at \(snapshot.app)",
                detail: "\(view.items.count) elements" + (view.hasChanges ? " (changed)" : "")
            )
        )
        return Perception(view: view, snapshot: snapshot, render: view.renderForModel())
    }

    // MARK: - Find

    private static func handleFind(
        action: AgentAction,
        pid: Int32?,
        driver: MacDriver,
        lastView: inout AgentView?,
        lastSnapshot: inout CUSnapshot?,
        feed: ComputerUseFeed,
        step: Int
    ) async -> String {
        guard let pid else { return "No app is focused. Use `open` first." }
        // Re-perceive the full view so marks stay in one consistent space, then
        // point at the matches by mark.
        let snapshot = await driver.capture(pid: pid, tier: .ax)
        let view = AgentView.build(from: snapshot, previous: lastView)
        lastView = view
        lastSnapshot = snapshot
        let needle = action.query?.lowercased() ?? ""
        let roleFilter = Set(action.roles.map { $0.lowercased() })
        let matches = view.items.filter { item in
            let roleOk = roleFilter.isEmpty || roleFilter.contains(item.role.lowercased())
            let textOk =
                needle.isEmpty
                || (item.label?.lowercased().contains(needle) ?? false)
                || (item.value?.lowercased().contains(needle) ?? false)
            return roleOk && textOk
        }
        feed.emit(
            FeedEvent(
                step: step,
                kind: .act,
                title: "Find " + (action.query.map { "\"\($0)\"" } ?? "elements"),
                detail: "\(matches.count) match(es)",
                success: !matches.isEmpty
            )
        )
        if matches.isEmpty {
            return "No matches. Full view:\n" + view.renderForModel()
        }
        let marks = matches.prefix(12).map { "[\($0.mark)] \($0.role) \"\($0.label ?? "")\"" }
            .joined(separator: "\n")
        return "Matches (address by mark):\n" + marks
    }

    // MARK: - Open

    private enum OpenResult {
        case opened(pid: Int32, app: String, view: AgentView?, snapshot: CUSnapshot?, render: String)
        case failure(String)
    }

    private static func handleOpen(
        action: AgentAction,
        driver: MacDriver,
        feed: ComputerUseFeed,
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
                FeedEvent(step: step, kind: .act, title: "Opened \(info.name)", success: true)
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
                FeedEvent(
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

    private static func act(
        action: AgentAction,
        element: CUElement?,
        pid: Int32,
        driver: MacDriver,
        lastView: inout AgentView?,
        lastSnapshot: inout CUSnapshot?,
        metrics: inout ComputerUseRunMetrics,
        feed: ComputerUseFeed,
        step: Int
    ) async -> String {
        metrics.actsAttempted += 1
        let result: CUActionResult
        switch action.verb {
        case .click:
            guard let element else { return "Click needs a resolved target." }
            result = await driver.perform(.click(id: element.id, button: .left, doubleClick: false))
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
            result = await driver.coordinate(
                .scroll(direction: dir, amount: Int32(action.amount ?? 3), x: nil, y: nil, pid: pid)
            )
        default:
            return "Unsupported action."
        }

        feed.emit(
            FeedEvent(
                step: step,
                kind: .act,
                title: action.feedLabel,
                detail: result.error,
                success: result.success
            )
        )

        // Verify: re-perceive and report the delta.
        let snapshot = await driver.capture(pid: pid, tier: .ax)
        let view = AgentView.build(from: snapshot, previous: lastView)
        lastView = view
        lastSnapshot = snapshot
        if view.hasChanges { metrics.verifyChanged += 1 }
        feed.emit(
            FeedEvent(
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
        out += view.hasChanges ? " The view changed." : " The view looks unchanged."
        out += "\n\nCurrent view:\n" + view.renderForModel()
        return out
    }

    // MARK: - Model step

    /// One forced agent_action call. Returns the first matching tool call, or
    /// nil when the model emitted no usable tool call.
    private static func modelStep(
        engine: ChatEngine,
        modelId: String,
        sessionId: String,
        messages: [ChatMessage]
    ) async throws -> (id: String, arguments: String)? {
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
        guard let message = response.choices.first?.message else { return nil }
        if let calls = message.tool_calls,
            let call = calls.first(where: { $0.function.name == AgentAction.toolName }) ?? calls.first
        {
            return (call.id, call.function.arguments)
        }
        return nil
    }

    // MARK: - Helpers

    private static func requiresTarget(_ verb: AgentVerb) -> Bool {
        switch verb {
        case .click, .setValue, .clear: return true
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

    /// Attach a freshly captured frame to the model conversation when the
    /// `VisionContext` allows it. Local models receive the frame directly; remote
    /// models receive a `FrameScrubber`-redacted frame routed through
    /// `CaptureRouter.cloudRoute`, and only with consent. Otherwise this is a
    /// no-op and the loop continues on the AX text alone.
    private static func attachFrame(
        image: CUImage,
        vision: VisionContext,
        availability: MacDriverAvailability,
        messages: inout [ChatMessage],
        imageTokensInContext: inout Int,
        metrics: inout ComputerUseRunMetrics,
        feed: ComputerUseFeed,
        step: Int
    ) async {
        switch VisionAttachment.decide(image: image, context: vision, availability: availability) {
        case .none:
            return
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
                FeedEvent(
                    step: step,
                    kind: .perceive,
                    title: "Attached a screenshot",
                    detail: "on-device"
                )
            )
        case .needsScrubForCloud(let img):
            // Scrub, then build the consented cloud route. The route is the only way
            // to reach `.cloudVision`, and it only accepts a `ScrubbedFrame`, so a
            // raw or unconsented frame can never be attached here.
            guard let frame = await FrameScrubber.scrub(img, mode: .pii),
                let route = CaptureRouter.cloudRoute(
                    scrubbed: frame,
                    consentGranted: vision.cloudConsent,
                    availability: availability
                ),
                case .cloudVision(let scrubbed) = route
            else { return }
            appendImageMessage(
                scrubbed.image,
                note:
                    "Screenshot of the current view (sensitive text was redacted before it left the device). "
                    + "Use it to locate the element, then address it by `describe`.",
                into: &messages,
                imageTokensInContext: &imageTokensInContext
            )
            metrics.cloudVisionUsed = true
            feed.emit(
                FeedEvent(
                    step: step,
                    kind: .perceive,
                    title: "Attached a screenshot",
                    detail: "redacted \(frame.report.maskedRegions) region(s) before cloud vision"
                )
            )
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
