//
//  WorkflowsOverviewModel.swift
//  osaurus
//
//  What the Workflows sidebar, Home and Activity know about automations,
//  joined once per window so they never disagree: every automation that
//  runs a workflow, its recent fires, and whether its target has a problem.
//  It watches only the event list, the run ledger's revision and the
//  installed workflows, so chat activity never re-renders Workflows. Fires
//  load off the main thread and are cached per automation.
//

import Combine
import Foundation
import Observation

@MainActor
final class WorkflowsOverviewModel: ObservableObject {
    /// How many fires per automation the cache keeps: enough for the
    /// longest health strip with room for skipped attempts between.
    static let runsPerAutomation = 40

    /// Automations whose action runs a workflow, in the event list's order.
    @Published private(set) var workflowEvents: [OsaurusEvent] = []
    /// Recent fires per automation, newest first.
    @Published private(set) var recentRuns: [UUID: [EventRun]] = [:]
    /// Automation ids whose target is missing or can't run.
    @Published private(set) var targetProblems: Set<UUID> = []
    /// Automations that run an agent or a prompt instead of a workflow,
    /// not counting channel messages.
    @Published private(set) var otherAutomationCount = 0
    /// When each workflow last started a run that finished, from the recent
    /// runs. A failure before it is resolved.
    @Published private(set) var lastFinishedRun: [UUID: Date] = [:]
    /// When each workflow last started a run of any outcome, for the
    /// sidebar's Last Run order. Test runs and steps of another workflow
    /// don't count.
    @Published private(set) var lastRunAt: [UUID: Date] = [:]

    private let events: EventManager
    private var cancellables: Set<AnyCancellable> = []
    private var loadTask: Task<Void, Never>?
    private var loadedRevision: Int?

    init(events: EventManager = .shared, installed: InstalledWorkflowStore = .shared) {
        self.events = events
        observeEvents()
        installed.$workflows
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshTargets() } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .workflowRunFinished)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refreshFinishedRuns()
                    self?.reloadRuns(force: true)
                }
            }
            .store(in: &cancellables)
        WorkflowRunStore.shared.$recentPersisted
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshFinishedRuns() } }
            .store(in: &cancellables)
        refresh()
        Task { [weak self] in
            await WorkflowRunStore.shared.loadRecentRunsIfNeeded()
            self?.refreshFinishedRuns()
        }
    }

    deinit { loadTask?.cancel() }

    // MARK: Reading

    /// The workflow's automations, oldest first.
    func automations(forWorkflowID id: UUID) -> [OsaurusEvent] {
        workflowEvents.filter { $0.action.workflow?.workflowID == id }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// The latest fire that settled (succeeded or failed). A failure the
    /// workflow has since finished a run after is resolved: nil.
    func latestSettled(_ eventID: UUID) -> EventRun? {
        guard let fire = recentRuns[eventID]?.first(where: { $0.status == .succeeded || $0.status == .failed }) else {
            return nil
        }
        if fire.status == .failed,
            let workflowID = workflowEvents.first(where: { $0.id == eventID })?.action.workflow?.workflowID,
            Self.isResolved(fire, lastFinishedRun: lastFinishedRun[workflowID])
        {
            return nil
        }
        return fire
    }

    static func isResolved(_ fire: EventRun, lastFinishedRun: Date?) -> Bool {
        guard fire.status == .failed, let lastFinishedRun else { return false }
        return lastFinishedRun > fire.firedAt
    }

    /// What the sidebar model needs, by workflow.
    var automationFacts: [UUID: [WorkflowsSidebarModel.AutomationFacts]] {
        var byWorkflow: [UUID: [WorkflowsSidebarModel.AutomationFacts]] = [:]
        for event in workflowEvents.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let workflowID = event.action.workflow?.workflowID else { continue }
            byWorkflow[workflowID, default: []].append(
                .init(
                    event: event, latestSettled: latestSettled(event.id)?.status,
                    hasTargetProblem: targetProblems.contains(event.id)))
        }
        return byWorkflow
    }

    // MARK: Watching

    private func observeEvents() {
        withObservationTracking {
            _ = events.events
            _ = events.ledgerRevision
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.observeEvents()
            }
        }
    }

    private func refresh() {
        let all = events.events
        let workflow = all.filter { $0.action.workflow != nil }
        if workflow != workflowEvents { workflowEvents = workflow }
        let others = all.filter { $0.action.workflow == nil && $0.sourceKind != .channelMessage }.count
        if others != otherAutomationCount { otherAutomationCount = others }
        refreshTargets()
        reloadRuns(force: false)
    }

    private func refreshFinishedRuns() {
        var latest: [UUID: Date] = [:]
        var anyLatest: [UUID: Date] = [:]
        for run in WorkflowRunStore.shared.recentRuns() where run.caller.kind != .workflow {
            if !run.isTest, run.startedAt > anyLatest[run.workflowID] ?? .distantPast {
                anyLatest[run.workflowID] = run.startedAt
            }
            guard run.status == .completed else { continue }
            if run.startedAt > latest[run.workflowID] ?? .distantPast { latest[run.workflowID] = run.startedAt }
        }
        if latest != lastFinishedRun { lastFinishedRun = latest }
        if anyLatest != lastRunAt { lastRunAt = anyLatest }
    }

    private func refreshTargets() {
        let problems = Set(workflowEvents.filter { EventInspection.targetProblem($0) != nil }.map(\.id))
        if problems != targetProblems { targetProblems = problems }
    }

    /// Reloads every automation's fires once the ledger moved (or always,
    /// when `force`). Off the main thread; a newer reload cancels this one.
    private func reloadRuns(force: Bool) {
        let revision = events.ledgerRevision
        let ids = workflowEvents.map(\.id)
        guard force || loadedRevision != revision || Set(recentRuns.keys) != Set(ids) else { return }
        loadedRevision = revision
        loadTask?.cancel()
        loadTask = Task { [weak self, events] in
            var loaded: [UUID: [EventRun]] = [:]
            for id in ids {
                guard !Task.isCancelled else { return }
                loaded[id] = await events.runs(eventId: id, limit: Self.runsPerAutomation)
            }
            guard !Task.isCancelled, let self else { return }
            if loaded != self.recentRuns { self.recentRuns = loaded }
        }
    }
}
