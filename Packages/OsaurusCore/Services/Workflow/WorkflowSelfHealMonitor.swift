//
//  WorkflowSelfHealMonitor.swift
//  osaurus
//
//  Repair as a flow. `WorkflowRepairBrief` is what the Architect is told
//  about a failed run, whether the person clicked "Fix with the Architect"
//  or self-heal fired. `WorkflowSelfHealMonitor` watches finished runs of
//  installed workflows that opted in: when the same step fails the same
//  way `threshold` runs in a row, it dispatches the Architect in a
//  background chat seeded with the workflow and the run, and a
//  notification offers the chat for review. Nothing is saved without the
//  person: the Architect's `workflow_propose_save` still ends in a card.
//

import Combine
import Foundation
import os

private let logger = Logger(subsystem: "ai.osaurus", category: "workflow.selfheal")

enum WorkflowRepairBrief {
    /// The person's message to the Architect, in their words.
    static func message(_ run: WorkflowRun, definition: WorkflowDefinition?) -> String {
        let time = run.startedAt.formatted(date: .abbreviated, time: .shortened)
        let reason = firstLine(run.error?.reason)
        if let failed = WorkflowRunsTool.failedStep(run) {
            let step = definition?.node(failed.nodeID)?.name ?? failed.nodeID
            return reason.map { L("The run on \(time) failed at the “\(step)” step: \($0). Fix it.") }
                ?? L("The run on \(time) failed at the “\(step)” step. Fix it.")
        }
        return reason.map { L("The run on \(time) failed: \($0). Fix it.") } ?? L("The run on \(time) failed. Fix it.")
    }

    /// The sidebar note that rides with the message: the run id and how to
    /// work from it.
    static func note(_ run: WorkflowRun, workflow: InstalledWorkflow) -> String {
        note(run, workflowName: workflow.name)
    }

    static func note(_ run: WorkflowRun, workflowName: String) -> String {
        var line =
            "The user asked you to fix run \(run.id.uuidString) of \"\(workflowName)\" (version "
            + "\(run.templateVersion), started \(WorkflowRunsTool.iso(run.startedAt)))"
        if let failed = WorkflowRunsTool.failedStep(run) {
            line += ", which failed at `\(failed.nodeID)`: \(firstLine(failed.reason) ?? failed.reason)"
        }
        line +=
            ". It is this chat's repair run: `workflow_runs` `get` reads it (pass `node` for the failed step's "
            + "full record, its definition, and every log line), `workflow_runs` `failures` shows whether the "
            + "same failure repeats, and `workflow_test` with `from_run` re-runs from the failed step with the "
            + "run's input and the finished steps' real outputs pinned."
        if let failure = run.primaryFailure {
            line += " " + failureLine(failure) + " " + nextStep(failure.fixIn)
        } else {
            line += " Fix the step, re-test that way, then propose the save."
        }
        return line
    }

    /// The failed step's classification, for the Architect.
    static func failureLine(_ failure: NodeRunFailure) -> String {
        var line =
            "The failure is `\(failure.kind)` (\(failure.errorType.isEmpty ? "error" : failure.errorType), "
            + (failure.retryable ? "retryable" : "not retryable") + "); its fix belongs in "
            + fixDescription(failure.fixIn) + "."
        if let hint = failure.hint, !hint.isEmpty { line += " Hint: \(hint)" }
        return line
    }

    static func fixDescription(_ fixIn: NodeRunFailure.FixIn) -> String {
        switch fixIn {
        case .workflow: return "the workflow (the step itself)"
        case .setup: return "setup (a secret, connection, folder, program, or model slot)"
        case .settings: return "an app setting, not the workflow"
        case .retry: return "nothing yet: it may pass on another attempt"
        case .person: return "the person's answer"
        }
    }

    /// What to do about a failure, by where its fix belongs.
    static func nextStep(_ fixIn: NodeRunFailure.FixIn) -> String {
        switch fixIn {
        case .workflow:
            return "Fix the step, re-test with `workflow_test` `from_run`, then propose the save."
        case .setup:
            return "Add or fix the setup requirement the message names instead of working around it in the step, "
                + "then re-test with `from_run`."
        case .settings:
            return "Do not change the workflow to hide it. Tell the person exactly which setting to change and where "
                + "(the message and hint name it), unless the step can reasonably stay within the setting; then "
                + "re-test with `from_run`."
        case .retry:
            return "Re-test once with `from_run`. If it fails the same way, raise the step's timeout or add a retry "
                + "policy, and propose that."
        case .person:
            return "Ask the person what they want before testing again."
        }
    }

    /// The self-heal dispatch's prompt: the same brief, plus that nobody is
    /// watching.
    static func unattendedPrompt(_ run: WorkflowRun, workflow: InstalledWorkflow, repeats: Int) -> String {
        var prompt =
            message(run, definition: workflow.definition)
            + " This is the same failure \(repeats) runs in a row. Nobody is watching this chat: do not ask "
            + "questions; read the run with `workflow_runs`, make the smallest fix, re-test with `workflow_test` "
            + "`from_run`, and if the test passes call `workflow_propose_save` so the person can review it later. "
            + "If you cannot fix it without them, say in one short paragraph what you found and what they need to do."
        if let failure = run.primaryFailure {
            prompt += " " + failureLine(failure)
            if failure.fixIn != .workflow {
                prompt += " Since the fix is not in the step, say what the person needs to change rather than editing the workflow around it."
            }
        }
        return prompt
    }

    static func firstLine(_ text: String?) -> String? {
        guard let line = text?.split(whereSeparator: \.isNewline).first else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
final class WorkflowSelfHealMonitor {
    static let shared = WorkflowSelfHealMonitor()

    /// Identical failures in a row before the Architect is dispatched.
    static let threshold = 3
    static let sessionKeyPrefix = "workflow-self-heal:"

    private var cancellable: AnyCancellable?
    /// Runs already judged this launch.
    private var seen: Set<UUID> = []

    /// Dispatches the Architect. Tests swap it for a recorder.
    var dispatch: @MainActor (InstalledWorkflow, WorkflowRun, Int) async -> Bool = { workflow, run, repeats in
        await WorkflowSelfHealMonitor.dispatchArchitect(workflow: workflow, run: run, repeats: repeats)
    }

    func start(store: WorkflowRunStore = .shared) {
        guard cancellable == nil else { return }
        cancellable = store.$live.sink { [weak self] live in
            guard let self else { return }
            Task { @MainActor in self.inspect(live.values.filter { $0.status == .failed }) }
        }
    }

    func stop() {
        cancellable = nil
        seen = []
    }

    /// Looks at failed runs not yet judged; fires for a workflow that opted
    /// in whose last `threshold` runs failed the same way.
    func inspect(_ failed: [WorkflowRun], store: WorkflowRunStore = .shared, installed: InstalledWorkflowStore = .shared) {
        for run in failed.sorted(by: { $0.startedAt < $1.startedAt }) where !seen.contains(run.id) {
            seen.insert(run.id)
            guard !run.isTest, let workflow = installed.workflow(id: run.workflowID), workflow.selfHeal else { continue }
            let history = store.runs(workflowID: workflow.id, limit: Self.threshold * 4, includeTests: false)
            guard let decision = Self.decide(latest: run, history: history, alreadyDrafted: workflow.selfHealedSignature)
            else { continue }
            installed.setSelfHealedSignature(decision.signature, id: workflow.id)
            let repeats = decision.repeats
            Task { @MainActor in
                let ok = await self.dispatch(workflow, run, repeats)
                if !ok {
                    logger.error("Self-heal dispatch for \(workflow.name, privacy: .public) was refused")
                    installed.setSelfHealedSignature(nil, id: workflow.id)
                }
            }
        }
    }

    struct Decision: Equatable {
        var signature: String
        var repeats: Int
    }

    /// Whether `latest` is the `threshold`th identical failure in a row and
    /// not one already drafted for. `history` is newest first; a run that
    /// did not fail, or failed differently, breaks the streak. Test runs
    /// and runs older than `latest` started before it count only once it
    /// is included.
    static func decide(latest: WorkflowRun, history: [WorkflowRun], alreadyDrafted: String?, threshold: Int = threshold) -> Decision? {
        guard let signature = WorkflowRunsTool.signature(of: latest) else { return nil }
        guard signature != alreadyDrafted else { return nil }
        var streak = 0
        for run in history where !run.isTest && run.startedAt <= latest.startedAt {
            guard run.status.isTerminal else { continue }
            guard WorkflowRunsTool.signature(of: run) == signature else { break }
            streak += 1
        }
        guard streak >= threshold else { return nil }
        return Decision(signature: signature, repeats: streak)
    }

    /// Opens the Architect in a background chat seeded with the workflow
    /// and the run, and notifies. False when the dispatch was refused.
    static func dispatchArchitect(workflow: InstalledWorkflow, run: WorkflowRun, repeats: Int) async -> Bool {
        let key = sessionKeyPrefix + run.id.uuidString
        WorkflowDraftStore.shared.registerSeed(.init(template: workflow.template, repairRunID: run.id), key: key)
        let request = DispatchRequest(
            prompt: WorkflowRepairBrief.unattendedPrompt(run, workflow: workflow, repeats: repeats),
            agentId: Agent.architectId,
            title: L("Fix “\(workflow.name)”"),
            showToast: true,
            source: .chat,
            externalSessionKey: key,
            reattachSession: false,
            loadIntent: .background)
        guard let handle = await BackgroundTaskManager.shared.dispatchChat(request) else { return false }
        NotificationService.shared.postWorkflowSelfHeal(
            workflowName: workflow.name, repeats: repeats, backgroundTaskID: handle.id)
        logger.info("Self-heal dispatched the Architect for \(workflow.name, privacy: .public) (run \(run.id))")
        return true
    }
}
