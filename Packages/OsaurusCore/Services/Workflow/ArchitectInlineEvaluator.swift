//
//  ArchitectInlineEvaluator.swift
//  osaurus
//
//  Drives one `architect_handoff` for the
//  OsaurusEvals `architect_inline` domain: the real tool, the real
//  `SubagentSession` admission and fast-draft persona, the real ephemeral
//  run. A case can move the deadline and hold the draft past it (the hand
//  back), fail or stub the steps, and say yes to the keep offer, which
//  proposes the save and then saves as the card's Save would.
//

import Foundation

@MainActor
public enum ArchitectInlineEvaluator {
    public struct Options: Sendable {
        /// Seconds for the draft and for the first step alike; nil keeps the
        /// shipped budgets (the draft's derived from the model's speed).
        public var deadline: TimeInterval?
        /// The draft never starts, so the deadline always wins.
        public var holdDraft: Bool
        /// Every step fails.
        public var failSteps: Bool
        /// Every step returns this text instead of running.
        public var stubStepText: String?
        /// Say yes to the keep offer and save.
        public var keep: Bool

        public init(
            deadline: TimeInterval? = nil, holdDraft: Bool = false, failSteps: Bool = false,
            stubStepText: String? = nil, keep: Bool = false
        ) {
            self.deadline = deadline
            self.holdDraft = holdDraft
            self.failSteps = failSteps
            self.stubStepText = stubStepText
            self.keep = keep
        }
    }

    public struct Outcome: Sendable {
        /// `completed`, `failed`, `needs_choice`, `handed_back`, `error`, or
        /// a run status.
        public var result: String
        public var keepOffered: Bool
        public var options: [String]
        public var question: String?
        public var ephemeral: Bool
        public var firstStepSeconds: Double?
        public var totalSeconds: Double
        public var nodeCount: Int
        public var abandoned: String?
        /// `draft` or `step` when a deadline caused the hand back.
        public var fallbackPhase: String?
        /// The draft budget the run had, and seconds until the draft started.
        public var draftBudgetSeconds: Double?
        public var draftSeconds: Double?
        /// Seconds from the handoff the first step may take: both budgets.
        public var firstStepBudgetSeconds: Double?
        public var tokensPerSecond: Double?
        public var promptTokens: Int?
        public var completionTokens: Int?
        public var savePrompted: Bool
        public var installedName: String?
        public var installedValid: Bool
        public var envelope: String
        public var keepEnvelope: String?
        /// The Architect's own handoff result, nil when the deadline won.
        public var draftEnvelope: String?
        /// The Architect's tool calls: name, arguments, result.
        public var draftCalls: [String] = []
    }

    struct StepFailed: Error, CustomStringConvertible {
        var description: String { "The eval failed this step on purpose." }
    }

    public static func run(message: String, model: String, options: Options = Options()) async -> Outcome {
        let savedConfiguration = ArchitectConfigurationStore.load()
        var configuration = savedConfiguration
        configuration.model = model
        ArchitectConfigurationStore.save(configuration)
        defer { ArchitectConfigurationStore.save(savedConfiguration) }

        var stub: (@Sendable () -> WorkflowNodeExecuting)?
        if options.failSteps {
            stub = { StubExecutor { throw StepFailed() } }
        } else if let text = options.stubStepText {
            let output: JSONValue = .object([
                "text": .string(text), "answer": .string(text), "agent": .string("eval"), "needs_input": .bool(false),
            ])
            stub = { StubExecutor { WorkflowNodeOutcome(output: output) } }
        }
        return await WorkflowExecutorSeam.$override.withValue(stub) {
            await runScoped(message: message, model: model, options: options)
        }
    }

    private static func runScoped(message: String, model: String, options: Options) async -> Outcome {
        let reports = ReportBox()
        let seams = ArchitectInlineHandoff.Seams(
            evalModel: model, draftDeadline: options.deadline,
            stepDeadline: options.deadline ?? ArchitectInlineHandoff.firstStepDeadline,
            holdDraft: options.holdDraft, report: { reports.set($0) })

        let started = Date()
        let envelope = await call(#"{"user_message":"","brief":""}"#, message: message, seams: seams)
        let total = Date().timeIntervalSince(started)

        let report = reports.value
        var outcome = Outcome(
            result: "error", keepOffered: false, options: [], question: nil, ephemeral: false,
            firstStepSeconds: report?.firstStepSeconds, totalSeconds: total, nodeCount: report?.nodeCount ?? 0,
            abandoned: report?.abandoned.map(ArchitectInlineHandoff.describe), tokensPerSecond: nil, promptTokens: nil,
            completionTokens: nil, savePrompted: false, installedName: nil, installedValid: false,
            envelope: envelope, keepEnvelope: nil, draftEnvelope: report?.handoffEnvelope,
            draftCalls: (report?.calls ?? []).map { "\($0.name) \($0.argumentsJSON) -> \($0.result)" })
        if case .deadline(let phase)? = report?.abandoned { outcome.fallbackPhase = phase.rawValue }
        outcome.draftBudgetSeconds = report?.draftBudgetSeconds
        outcome.draftSeconds = report?.draftSeconds
        if let report {
            outcome.firstStepBudgetSeconds =
                report.draftBudgetSeconds + (options.deadline ?? ArchitectInlineHandoff.firstStepDeadline)
        }
        if let handoff = report?.handoffEnvelope,
            let usage = (ToolEnvelope.successPayload(handoff) as? [String: Any])?["usage"] as? [String: Any]
        {
            outcome.tokensPerSecond = usage["tokens_per_second"] as? Double
            outcome.promptTokens = usage["prompt_tokens"] as? Int
            outcome.completionTokens = usage["completion_tokens"] as? Int
        }

        if case .needsChoice(let question, let choices)? = HandoffResult.parse(envelope: envelope) {
            outcome.result = "needs_choice"
            outcome.question = question
            outcome.options = choices
            return outcome
        }
        if let failure = (try? JSONSerialization.jsonObject(with: Data(envelope.utf8))) as? [String: Any],
            (failure["message"] as? String)?.hasSuffix(ArchitectInlineHandoff.handBackNextStep) == true
        {
            outcome.result = "handed_back"
            return outcome
        }
        guard !ToolEnvelope.isError(envelope), let payload = ToolEnvelope.successPayload(envelope) as? [String: Any]
        else { return outcome }
        outcome.result = payload["status"] as? String ?? "error"
        if let runID = WorkflowToolCall.runID(inResult: envelope), let run = WorkflowRunStore.shared.run(id: runID) {
            outcome.ephemeral = run.ephemeral
        }
        guard let offer = payload["keep_offer"] as? [String: Any],
            let draftKey = offer["keep_draft"] as? String, let draftID = UUID(uuidString: draftKey)
        else { return outcome }
        outcome.keepOffered = true
        defer { WorkflowDraftStore.shared.delete(draftID) }
        guard options.keep else { return outcome }

        let keep = await call(
            JSONValue.object([
                "user_message": .string("yes, keep it"), "brief": .string("keep"), "keep_draft": .string(draftKey),
            ]).compactJSONString,
            message: "yes, keep it", seams: seams)
        outcome.keepEnvelope = keep
        guard let proposal = ToolEnvelope.successPayload(keep) as? [String: Any],
            proposal[ArchitectInlineHandoff.savePromptKey] as? Bool == true
        else { return outcome }
        outcome.savePrompted = true
        if let installed = try? WorkflowDraftSaver.save(draftID: draftID, changelog: ArchitectInlineHandoff.keepChangelog) {
            outcome.installedName = installed.name
            outcome.installedValid =
                WorkflowValidator.validate(installed.definition, allowPlaceholders: false).isEmpty
                && InstalledWorkflowStore.shared.workflow(id: installed.id) != nil
            InstalledWorkflowStore.shared.delete(id: installed.id)
        }
        return outcome
    }

    private static func call(_ arguments: String, message: String, seams: ArchitectInlineHandoff.Seams) async -> String {
        await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            await ChatExecutionContext.$currentSessionId.withValue("eval-architect-inline-\(UUID().uuidString)") {
                await ChatExecutionContext.$currentUserRequest.withValue(message) {
                    await ChatExecutionContext.$currentToolCallId.withValue("eval-inline-\(UUID().uuidString)") {
                        (try? await ArchitectHandoffTool(seams: seams).execute(argumentsJSON: arguments))
                            ?? ToolEnvelope.failure(
                                kind: .executionError, message: "architect_handoff threw", tool: "architect_handoff")
                    }
                }
            }
        }
    }

}

private struct StubExecutor: WorkflowNodeExecuting {
    let body: @Sendable () throws -> WorkflowNodeOutcome

    func execute(_ context: WorkflowNodeContext, awaitingUser: WorkflowAwaitingUserHandler) async throws
        -> WorkflowNodeOutcome
    {
        try body()
    }
}

private final class ReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var report: ArchitectInlineHandoff.DraftReport?

    func set(_ value: ArchitectInlineHandoff.DraftReport) {
        lock.lock()
        report = value
        lock.unlock()
    }

    var value: ArchitectInlineHandoff.DraftReport? {
        lock.lock()
        defer { lock.unlock() }
        return report
    }
}
