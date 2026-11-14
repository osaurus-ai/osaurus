//
//  ArchitectInlineHandoff.swift
//  osaurus
//
//  `architect_handoff`. The Architect drafts a
//  small workflow for the request inside the Orchestrator's turn (fast-draft
//  persona, validator only, at most five steps) and the draft runs at once
//  as an ephemeral run the chat follows like `run_workflow`. Two deadlines:
//  the draft gets `DraftBudget` (scaled to the model's speed), and the run's
//  first step gets `firstStepDeadline` from run start. When either passes,
//  the draft is dropped and the Orchestrator gets the request back to hand
//  to a worker with `run_workflow` or to ask about. A run that completes carries a keep
//  offer; the user's yes comes back as `keep_draft` and raises the same Save
//  card the Architect's `workflow_propose_save` does. Only the card's Save
//  writes.
//

import Foundation

/// The Architect's wall clock for a draft: the time `tokenBudget` tokens
/// take at the model's last measured rate, never under `floorSeconds`.
struct DraftBudget {
    static let tokenBudget = 1_200
    static let floorSeconds: TimeInterval = 20
    static let defaultTokensPerSecond = 15.0

    static func wallClock(measuredTokensPerSecond: Double?) -> TimeInterval {
        let rate = measuredTokensPerSecond.flatMap { $0 > 0 ? $0 : nil } ?? defaultTokensPerSecond
        return max(floorSeconds, Double(tokenBudget) / rate)
    }

    /// The budget for `model`, or for the resident model when the Architect
    /// uses the chat's.
    static func wallClock(model: String?) -> TimeInterval {
        wallClock(measuredTokensPerSecond: ModelThroughputLedger.tokensPerSecond(for: model))
    }
}

enum ArchitectInlineHandoff {
    /// From the run starting to its first step running.
    static let firstStepDeadline: TimeInterval = 10
    /// Model turns for a fast draft: the patch, one fix, the reply.
    static let draftMaxSteps = 4
    /// The input every fast draft takes: the request in the user's words.
    static let requestInput = "request"
    static let keepChangelog = "First version, kept from a chat run."

    /// Test seams: force the model, replace the Architect's dispatch or
    /// stream, and move either deadline.
    struct Seams: Sendable {
        var evalModel: String?
        var dispatchOverride: (@Sendable (ServiceToolInvocation) async -> String)?
        var streamProvider: AgentSubagentRunner.ResponsesStreamProvider?
        /// Seconds for the draft; nil derives them from the model (`DraftBudget`).
        var draftDeadline: TimeInterval?
        var stepDeadline: TimeInterval = ArchitectInlineHandoff.firstStepDeadline
        /// Replaces the wait for the run's first step.
        var firstStepRunning: (@Sendable (UUID, Date) async -> Bool)?
        /// Holds the draft until the draft deadline cancels it, so a draft
        /// that fails fast cannot win the race.
        var holdDraft = false
        /// Called once the draft stage settles (evals record latency and
        /// tokens per second from it).
        var report: (@Sendable (DraftReport) -> Void)?

        init(
            evalModel: String? = nil,
            dispatchOverride: (@Sendable (ServiceToolInvocation) async -> String)? = nil,
            streamProvider: AgentSubagentRunner.ResponsesStreamProvider? = nil,
            draftDeadline: TimeInterval? = nil,
            stepDeadline: TimeInterval = ArchitectInlineHandoff.firstStepDeadline,
            firstStepRunning: (@Sendable (UUID, Date) async -> Bool)? = nil,
            holdDraft: Bool = false,
            report: (@Sendable (DraftReport) -> Void)? = nil
        ) {
            self.evalModel = evalModel
            self.dispatchOverride = dispatchOverride
            self.streamProvider = streamProvider
            self.draftDeadline = draftDeadline
            self.stepDeadline = stepDeadline
            self.firstStepRunning = firstStepRunning
            self.holdDraft = holdDraft
            self.report = report
        }
    }

    /// How the draft stage went: the Architect's handoff envelope (nil when
    /// the deadline won first), the draft budget it had, seconds to the
    /// draft starting and to the first step running, the draft's step count,
    /// and the Architect's tool calls (empty when the deadline won first).
    struct DraftReport: Sendable {
        var handoffEnvelope: String?
        var draftBudgetSeconds: TimeInterval = 0
        var draftSeconds: Double?
        var firstStepSeconds: Double?
        var nodeCount: Int
        var abandoned: Abandoned?
        var calls: [HandoffToolCall] = []
    }

    static let draftTarget = draftTarget(wallClockSeconds: DraftBudget.floorSeconds)

    static func draftTarget(
        wallClockSeconds: TimeInterval, observe: (@Sendable ([HandoffToolCall]) -> Void)? = nil
    ) -> HiddenAgentTarget {
        HiddenAgentTarget(
            agentId: Agent.architectId,
            capability: SubagentCapabilityRegistry.architectHandoff,
            feedTitle: "Workflow",
            maxSteps: draftMaxSteps,
            wallClockSeconds: wallClockSeconds,
            systemPrompt: { ArchitectSystemPromptBuilder.fastDraft },
            toolNames: { [WorkflowDraftTool.toolName] },
            configuredModel: { ArchitectConfigurationStore.load().model },
            temperature: { nil },
            classify: { calls, digest, _ in
                observe?(calls)
                return classifyDraft(calls, digest: digest)
            },
            endsRun: { draftIsReady($0) },
            workingPhase: planningPhase
        )
    }

    /// The feed's step while the Architect drafts, and the collapsed row it
    /// leaves once the run starts.
    static let planningPhase = L("Planning")

    /// A patch that leaves a complete draft with no issues: it can run now,
    /// so the Architect's closing reply is not waited for.
    static func draftIsReady(_ call: HandoffToolCall) -> Bool {
        guard call.name == WorkflowDraftTool.toolName,
            JSONValue.parse(call.argumentsJSON)?.objectValue?["action"]?.stringValue == "patch",
            let result = ToolEnvelope.successPayload(call.result) as? [String: Any]
        else { return false }
        return (result["node_count"] as? Int ?? 0) > 0
            && (result["placeholders"] as? [Any])?.isEmpty ?? true
            && (result["issues"] as? [Any])?.isEmpty ?? true
    }

    /// The Architect's reply is not the result; the draft is. A successful
    /// patch counts as drafted even when the step cap ends the run.
    static func classifyDraft(_ calls: [HandoffToolCall], digest: String) -> HandoffResult {
        let patched = calls.contains { call in
            call.name == WorkflowDraftTool.toolName && ToolEnvelope.isSuccess(call.result)
                && JSONValue.parse(call.argumentsJSON)?.objectValue?["action"]?.stringValue == "patch"
        }
        let text = digest.isEmpty ? "Drafted the workflow." : digest
        return patched ? .applied(text) : .answer(digest.isEmpty ? "No draft." : digest)
    }

    // MARK: - Draft and run

    /// Which budget ran out: the Architect's draft or the run's first step.
    enum Phase: String, Sendable {
        case draft
        case step
    }

    enum Abandoned: Equatable, Sendable {
        case deadline(Phase)
        case invalid(String)
        case cancelled
    }

    enum Started: Sendable {
        case running(runID: UUID, draftID: UUID, workflow: InstalledWorkflow, planning: WorkflowCallFeed.Planning)
        case abandoned(Abandoned)
    }

    static func run(_ handoff: Handoff, tool: String, seams: Seams = Seams()) async -> String {
        let caller = await WorkflowToolCall.caller(kind: .orchestrator)
        let started = await draftAndStart(handoff, caller: caller, tool: tool, seams: seams)
        switch started {
        case .running(let runID, let draftID, let workflow, let planning):
            let envelope = await WorkflowToolCall.follow(
                runID, workflow: workflow, caller: caller, tool: tool, routed: true, planning: planning)
            return withKeepOffer(envelope, draftID: draftID, name: workflow.name, tool: tool)
        case .abandoned(.cancelled):
            return ToolEnvelope.failure(
                kind: .userDenied, message: "Stopped before the workflow ran.", tool: tool, retryable: false)
        case .abandoned(let why):
            print("[Osaurus][Architect] inline draft handed back: \(describe(why))")
            return handBack(why, tool: tool)
        }
    }

    static func describe(_ abandoned: Abandoned) -> String {
        switch abandoned {
        case .deadline(let phase): return "deadline (\(phase.rawValue))"
        case .cancelled: return "cancelled"
        case .invalid(let why): return "invalid: \(why)"
        }
    }

    /// Drafts into a fresh inline draft and starts it within the draft
    /// budget, then gives the run `seams.stepDeadline` to start its first
    /// step. A draft that misses either, or is not valid, is deleted.
    static func draftAndStart(
        _ handoff: Handoff, caller: WorkflowCaller, tool: String, seams: Seams
    ) async -> Started {
        let began = Date()
        let draftBudget: TimeInterval
        if let fixed = seams.draftDeadline {
            draftBudget = fixed
        } else {
            let configured = await MainActor.run { ArchitectConfigurationStore.load().model }
            draftBudget = DraftBudget.wallClock(model: seams.evalModel ?? configured)
        }
        let draftDeadline = began.addingTimeInterval(draftBudget)
        let stepBudget = seams.stepDeadline
        let waitForFirstStep = seams.firstStepRunning ?? { runID, deadline in await firstStepRunning(runID, by: deadline) }
        let draft = await MainActor.run { WorkflowDraftStore.shared.createInline() }
        let draftID = draft.id
        let claim = DeadlineClaim()
        let seed = seedContent(for: handoff)
        let message = handoff.userMessage
        let report = seams.report
        let callLog = HandoffToolLog()
        let target = draftTarget(wallClockSeconds: draftBudget) { calls in
            for call in calls { callLog.append(call) }
        }
        let holdDraft = seams.holdDraft
        let work: @Sendable () async -> Started = {
            if holdDraft {
                try? await Task.sleep(for: .seconds(max(1, draftBudget) * 10))
            }
            let kind = HiddenAgentHandoffKind(
                target: target, seedUserContent: seed, toolSessionId: draft.sessionID,
                evalModel: seams.evalModel, dispatchOverride: seams.dispatchOverride,
                streamProvider: seams.streamProvider)
            let envelope = await HiddenAgentHandoffRunner.run(kind, tool: tool)
            let nodeCount = await MainActor.run { WorkflowDraftStore.shared.draft(id: draftID)?.definition.nodes.count ?? 0 }
            let drafted = Date().timeIntervalSince(began)
            func settle(_ started: Started, firstStep: Double? = nil) -> Started {
                var abandoned: Abandoned?
                if case .abandoned(let why) = started { abandoned = why }
                report?(DraftReport(
                    handoffEnvelope: envelope, draftBudgetSeconds: draftBudget, draftSeconds: drafted,
                    firstStepSeconds: firstStep, nodeCount: nodeCount, abandoned: abandoned, calls: callLog.all))
                return started
            }
            let started: Started? = await MainActor.run {
                guard !Task.isCancelled, claim.claim(.work) else {
                    WorkflowDraftStore.shared.delete(draftID)
                    return nil
                }
                return start(
                    draftID: draftID, message: message, caller: caller,
                    planning: planning(seconds: drafted, calls: callLog.all))
            }
            // Lost to the deadline or Stop: the race already answered.
            guard let started else { return .abandoned(Task.isCancelled ? .cancelled : .deadline(.draft)) }
            guard case .running(let runID, _, _, _) = started else { return settle(started) }
            guard await waitForFirstStep(runID, Date().addingTimeInterval(stepBudget)) else {
                await MainActor.run {
                    WorkflowRunService.shared.cancel(runID)
                    WorkflowDraftStore.shared.delete(draftID)
                }
                return settle(.abandoned(.deadline(.step)))
            }
            return settle(started, firstStep: Date().timeIntervalSince(began))
        }
        let outcome = await race(work, deadline: draftDeadline, claim: claim)
        if case .abandoned(.deadline(.draft)) = outcome {
            if Task.isCancelled { return .abandoned(.cancelled) }
            if !claim.claim(.work) {
                report?(DraftReport(
                    handoffEnvelope: nil, draftBudgetSeconds: draftBudget, nodeCount: 0,
                    abandoned: .deadline(.draft), calls: callLog.all))
            }
        }
        return outcome
    }

    /// The collapsed Planning row: how long the draft took, the steps it
    /// planned, and the Architect's reason for the last patch.
    @MainActor
    static func planning(seconds: Double, calls: [HandoffToolCall]) -> WorkflowCallFeed.Planning {
        let why = calls.last { call in
            call.name == WorkflowDraftTool.toolName && ToolEnvelope.isSuccess(call.result)
        }.flatMap { JSONValue.parse($0.argumentsJSON)?.objectValue?["why"]?.stringValue }
        return WorkflowCallFeed.Planning(seconds: seconds, reason: why)
    }

    /// Validates the draft and starts its ephemeral run with the request
    /// as input.
    @MainActor
    static func start(
        draftID: UUID, message: String, caller: WorkflowCaller,
        planning: WorkflowCallFeed.Planning = WorkflowCallFeed.Planning(seconds: 0, reason: nil)
    ) -> Started {
        let store = WorkflowDraftStore.shared
        func abandon(_ reason: String) -> Started {
            store.delete(draftID)
            return .abandoned(.invalid(reason))
        }
        guard let draft = store.draft(id: draftID) else { return .abandoned(.invalid("The draft is gone.")) }
        let definition = draft.definition
        guard !definition.nodes.isEmpty else { return abandon("The draft has no steps.") }
        guard definition.nodes.count <= ArchitectSystemPromptBuilder.fastDraftMaxNodes else {
            return abandon("The draft has more than \(ArchitectSystemPromptBuilder.fastDraftMaxNodes) steps.")
        }
        let issues = WorkflowValidator.validate(definition, allowPlaceholders: false)
        guard issues.isEmpty else { return abandon(issues.map(\.message).joined(separator: "; ")) }
        let input: JSONValue = .object([requestInput: .string(message)])
        guard JSONSchemaValidator.validate(input, against: definition.inputSchema).isEmpty else {
            return abandon("The draft does not take the request as its input.")
        }
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try? store.applyArchitectPatch(draftID, ops: [.setInfo(name: defaultName(for: message), summary: nil)])
        }
        guard let ready = store.draft(id: draftID) else { return .abandoned(.invalid("The draft is gone.")) }
        let template = ready.template()
        let bindings = store.testBindings(draftID)
        let runID = WorkflowRunService.shared.startEphemeral(
            draftID: draftID, template: template, bindings: bindings, input: input, caller: caller)
        let workflow = InstalledWorkflow(id: draftID, template: template, bindings: bindings, orchestratorVisible: false)
        return .running(runID: runID, draftID: draftID, workflow: workflow, planning: planning)
    }

    /// The first words of the request, for a draft the Architect left
    /// unnamed.
    static func defaultName(for message: String) -> String {
        let words = message.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        return words.isEmpty ? "Workflow" : words
    }

    /// True once a step of `runID` has started (or the run already settled)
    /// before `deadline`.
    static func firstStepRunning(_ runID: UUID, by deadline: Date) async -> Bool {
        while true {
            let started = await MainActor.run { () -> Bool in
                guard let run = WorkflowRunStore.shared.run(id: runID) else { return false }
                return run.status != .running || run.nodes.contains { $0.status != .pending }
            }
            if started { return true }
            if Date() >= deadline || Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// `work`'s value, or `.abandoned(.deadline(.draft))` once `deadline` passes
    /// before the work claimed `claim`. A losing work is cancelled and not
    /// waited for.
    static func race(
        _ work: @escaping @Sendable () async -> Started, deadline: Date, claim: DeadlineClaim
    ) async -> Started {
        let tasks = TaskBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Started, Never>) in
                let resume = ResumeOnce(continuation)
                let workTask = Task { resume(await work()) }
                let timer = Task {
                    try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                    guard !Task.isCancelled, claim.claim(.deadline) else { return }
                    workTask.cancel()
                    resume(.abandoned(.deadline(.draft)))
                }
                tasks.set(work: workTask, timer: timer)
            }
        } onCancel: {
            tasks.cancelWork()
        }
    }

    // MARK: - Hand back

    static let handBackNextStep =
        "Hand the user's request to a worker or agent with `run_workflow`, or ask the user one question."

    /// The request goes back to the Orchestrator: calling the Architect
    /// again would miss the same deadline or draft the same invalid workflow.
    static func handBack(_ why: Abandoned, tool: String) -> String {
        if case .deadline = why {
            return ToolEnvelope.failure(
                kind: .timeout, message: "Couldn't set that up in time. " + handBackNextStep, tool: tool,
                retryable: false)
        }
        return ToolEnvelope.failure(
            kind: .executionError, message: "Couldn't set that up. " + handBackNextStep, tool: tool, retryable: false)
    }

    // MARK: - Keep

    /// The open item the Orchestrator records for a keep offer.
    static func keepItem(draftID: UUID, name: String) -> String {
        "keep_draft \(draftID.uuidString): offered to keep \"\(name)\""
    }

    /// A completed run's envelope with the keep offer; anything else as is.
    static func withKeepOffer(_ envelope: String, draftID: UUID, name: String, tool: String) -> String {
        guard !ToolEnvelope.isError(envelope),
            var payload = ToolEnvelope.successPayload(envelope) as? [String: Any],
            payload["status"] as? String == WorkflowCallResult.Status.completed.rawValue
        else { return envelope }
        payload["keep_offer"] = ["keep_draft": draftID.uuidString, "name": name]
        payload["present"] =
            "Give the user the result. Then offer once, in one short sentence, to keep it as a workflow "
            + "named \"\(name)\" they can run again, and add `\(keepItem(draftID: draftID, name: name))` to "
            + "open_items when you call state. Only if they say yes, call architect_handoff with "
            + "`keep_draft: \"\(draftID.uuidString)\"`."
        return ToolEnvelope.success(tool: tool, result: payload)
    }

    /// The user said yes to a keep offer: propose the save as the Architect
    /// would, on the draft's own session. The result raises the Save card.
    static func keep(draftKey: String, tool: String) async -> String {
        let trimmed = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID: String? = await MainActor.run {
            guard let id = UUID(uuidString: trimmed), let draft = WorkflowDraftStore.shared.draft(id: id),
                WorkflowDraftStore.isInline(draft)
            else { return nil }
            return draft.sessionID
        }
        guard let sessionID else {
            return HandoffResult.declined(
                "That workflow is no longer available to keep. Ask again and I'll build it again."
            ).envelope(tool: tool)
        }
        let arguments = JSONValue.object(["changelog": .string(keepChangelog)]).compactJSONString
        let proposed = await ChatExecutionContext.$currentAgentId.withValue(Agent.architectId) {
            await ChatExecutionContext.$currentSessionId.withValue(sessionID) {
                (try? await WorkflowProposeSaveTool().execute(argumentsJSON: arguments)) ?? ""
            }
        }
        guard !ToolEnvelope.isError(proposed), var payload = ToolEnvelope.successPayload(proposed) as? [String: Any]
        else {
            let message = proposed.isEmpty ? "" : ToolEnvelope.failureMessage(proposed)
            let reason = message.isEmpty ? "It could not be saved." : message
            return HandoffResult.declined("It can't be kept yet: \(reason)").envelope(tool: tool)
        }
        payload[savePromptKey] = true
        payload["present"] = "The user decides on the Save card now. Add nothing this turn."
        return ToolEnvelope.success(tool: tool, result: payload)
    }

    /// Marks a keep result that raises the Save card in chat.
    static let savePromptKey = "save_prompt"

    // MARK: - Seed

    static func seedContent(for handoff: Handoff) -> String {
        var request = "[Request]\nuser_message: \(handoff.userMessage)"
        if !handoff.brief.isEmpty { request += "\nbrief: \(handoff.brief)" }
        return request
    }
}

/// Who decided a race: the work starting the run, or the deadline.
final class DeadlineClaim: @unchecked Sendable {
    enum Owner { case work, deadline }
    private let lock = NSLock()
    private var owner: Owner?

    /// True when `who` holds the claim (first to ask wins).
    func claim(_ who: Owner) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if owner == nil { owner = who }
        return owner == who
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    func callAsFunction(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var cancelled = false

    func set(work: Task<Void, Never>, timer: Task<Void, Never>) {
        lock.lock()
        self.work = work
        self.timer = timer
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled { work.cancel() }
    }

    func cancelWork() {
        lock.lock()
        cancelled = true
        let work = self.work
        lock.unlock()
        work?.cancel()
    }
}
