//
//  RunFailedEventSource.swift
//  osaurus
//
//  The "Run failed" automation (n8n's Error Trigger). It watches two
//  places runs end: `WorkflowRunService` (every installed workflow's run,
//  whoever started it) and `EventManager.finalize` (automations that ran
//  an agent, or failed before a workflow run started). A failure is handed
//  to every enabled run-failed automation it matches.
//
//  Never re-entrant: a run a run-failed automation started, or that
//  automation's own failure, fires nothing, so two handlers cannot keep
//  waking each other. Test runs and steps nested in another run are not
//  reported (the outer run's failure is), unless the nested workflow is
//  named in the automation.
//

import Foundation

@MainActor
final class RunFailedEventSource: EventSourceAdapter {
    let kind: EventSourceKind = .runFailed
    private unowned let manager: EventManager
    private var observer: NSObjectProtocol?
    /// Resolves a finished run; tests substitute one.
    var runLookup: @MainActor (UUID) -> WorkflowRun? = { WorkflowRunStore.shared.run(id: $0) }

    init(manager: EventManager) {
        self.manager = manager
    }

    func start() async {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .workflowRunFinished, object: nil, queue: .main
        ) { [weak self] note in
            guard let runID = note.userInfo?["runID"] as? UUID else { return }
            Task { @MainActor in
                guard let self, let run = self.runLookup(runID) else { return }
                self.workflowRunFinished(run)
            }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func reconcile(_ events: [OsaurusEvent]) async {}

    func status(_ eventId: UUID) -> EventSourceStatus {
        manager.sourceStatus[eventId] ?? EventSourceStatus()
    }

    func fireNow(_ event: OsaurusEvent, sample: JSONValue?) async -> EventFireResult {
        let now = Date()
        let payload =
            sample.flatMap { $0.value(atPath: "failure") != nil ? $0 : nil }
            ?? EventTriggerValues.samplePayload(for: event, now: now)
        return manager.submit(
            EventOccurrence(
                eventId: event.id, firedAt: now, payload: payload, trigger: .manual, loadIntent: .interactive,
                summary: Self.summary(payload)))
    }

    // MARK: - Failures

    /// A workflow run ended; fires when it failed.
    func workflowRunFinished(_ run: WorkflowRun) {
        guard run.status == .failed, !run.isTest, !startedByHandler(run.caller.eventID) else { return }
        let nested = run.caller.kind == .workflow
        let installed = InstalledWorkflowStore.shared.workflow(id: run.workflowID)
        let failedStep = run.error?.nodeID.map { nodeID in
            let node = installed?.definition.nodes.first { $0.id == nodeID }
            return (id: nodeID, name: node?.name, kind: node?.kindName)
        }
        let automation = run.caller.kind == .event ? run.caller.eventID.map { id in
            (id: id, name: run.caller.eventName ?? manager.event(for: id)?.name ?? "")
        } : nil
        let failure = EventPayload.Failure(
            kind: .workflowRun, runId: run.id,
            message: run.error?.reason ?? L("The workflow run failed."),
            workflow: (run.workflowID, installed?.name ?? run.workflowName), failedStep: failedStep,
            automation: automation, caller: run.caller.kind.rawValue, startedAt: run.startedAt,
            finishedAt: run.finishedAt)
        submit(failure) { config in
            if config.workflowIDs.isEmpty { return !nested }
            return config.workflowIDs.contains(run.workflowID)
        }
    }

    /// An automation's run settled as failed. One that started a workflow
    /// run is reported through that run instead.
    func automationRunFailed(_ run: EventRun, event: OsaurusEvent?) {
        guard run.status == .failed, run.workflowRunId == nil, let event, event.sourceKind != .runFailed else {
            return
        }
        let workflow = event.action.workflow.map { action in
            (id: action.workflowID, name: InstalledWorkflowStore.shared.workflow(id: action.workflowID)?.name ?? "")
        }
        let failure = EventPayload.Failure(
            kind: .automationRun, runId: run.id,
            message: run.error ?? run.reason ?? L("The automation's run failed."), workflow: workflow,
            failedStep: nil, automation: (event.id, event.name), caller: "event", startedAt: run.startedAt,
            finishedAt: run.finishedAt)
        submit(failure) { $0.includeAutomationRuns }
    }

    private func startedByHandler(_ eventID: UUID?) -> Bool {
        guard let eventID else { return false }
        return manager.event(for: eventID)?.sourceKind == .runFailed
    }

    private func submit(_ failure: EventPayload.Failure, matches: (RunFailedSourceConfig) -> Bool) {
        let now = Date()
        for event in manager.events where event.isEnabled {
            guard let config = event.source.runFailed, matches(config) else { continue }
            let payload = EventPayload.failure(event: event, firedAt: now, failure: failure)
            manager.submit(
                EventOccurrence(
                    eventId: event.id, firedAt: now, payload: payload, dedupeKey: "failure:" + failure.runId.uuidString,
                    loadIntent: .background, summary: Self.summary(payload)))
        }
    }

    nonisolated static func summary(_ payload: JSONValue) -> [String: String] {
        var summary: [String: String] = [:]
        if let kind = payload.value(atPath: "failure.kind")?.stringValue { summary["failure_kind"] = kind }
        if let run = payload.value(atPath: "failure.run_id")?.stringValue { summary["failed_run_id"] = run }
        if let name = payload.value(atPath: "failure.workflow.name")?.stringValue, !name.isEmpty {
            summary["workflow"] = String(name.prefix(120))
        }
        return summary
    }
}
