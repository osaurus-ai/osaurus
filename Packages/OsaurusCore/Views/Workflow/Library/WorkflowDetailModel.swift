//
//  WorkflowDetailModel.swift
//  osaurus
//
//  What a workflow's page computes once instead of on every redraw: its
//  setup report and where its model steps run (both from one look at this
//  Mac's tools, models, folders and keys), and the runs it has recorded.
//  It looks again when the workflow's record changes, when the window comes
//  back to the front (a sheet closed, keys added in the Vault), and when
//  one of its runs ends. A run going step by step never makes it look.
//

import AppKit
import Combine
import Foundation

@MainActor
final class WorkflowDetailModel: ObservableObject {
    struct Locality: Equatable {
        let icon: String
        let text: String
    }

    let workflowID: UUID
    @Published private(set) var report: SetupReport?
    @Published private(set) var locality: Locality?
    /// Settled runs, newest first; runs going now come from `WorkflowLiveRuns`.
    @Published private(set) var recordedRuns: [WorkflowRun] = []
    /// The look the report came from, for the rows that resolve models.
    private(set) var environment: SetupChecker.Environment?

    private var subscriptions = Set<AnyCancellable>()
    private var runsTask: Task<Void, Never>?

    init(workflowID: UUID, store: InstalledWorkflowStore = .shared, liveRuns: WorkflowLiveRuns = .shared) {
        self.workflowID = workflowID
        refresh(store.workflow(id: workflowID))
        recordedRuns = WorkflowRunStore.shared.recentRuns()
            .filter { $0.workflowID == workflowID && $0.status.isTerminal }
        reloadRuns()

        // `@Published` sends before the store changes, with the new value.
        store.$workflows
            .map { $0.first { $0.id == workflowID } }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] in self?.refresh($0) }
            .store(in: &subscriptions)
        store.$modifiedOutsideApp
            .map { $0.contains(workflowID) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &subscriptions)
        liveRuns.$byRun
            .map { runs in Set(runs.values.filter { $0.workflowID == workflowID && !$0.isGoing }.map(\.id)) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.reloadRuns() }
            .store(in: &subscriptions)
        Publishers.Merge(
            NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification).map { _ in () },
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).map { _ in () }
        )
        .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
        .sink { [weak self] in self?.refresh() }
        .store(in: &subscriptions)
    }

    func refresh(_ workflow: InstalledWorkflow? = nil) {
        guard let workflow = workflow ?? InstalledWorkflowStore.shared.workflow(id: workflowID) else {
            report = nil
            locality = nil
            environment = nil
            return
        }
        let env = SetupChecker.Environment.live(secrets: .install, attended: true)
        environment = env
        let checked = SetupChecker.check(workflow, secrets: .install, environment: env)
        if checked != report { report = checked }
        let place = Self.locality(workflow, environment: env)
        if place != locality { locality = place }
    }

    /// Where its model steps run once chosen; nil when it uses no model or
    /// none is chosen yet.
    static func locality(_ workflow: InstalledWorkflow, environment env: SetupChecker.Environment) -> Locality? {
        let models = workflow.template.requirements.models.compactMap {
            SetupChecker.resolvedModel(for: $0, bindings: workflow.bindings, environment: env)
        }
        guard !models.isEmpty else { return nil }
        return models.allSatisfy({ SetupChecker.isLocalModel($0, catalog: env.modelCatalog) })
            ? Locality(icon: "lock.laptopcomputer", text: L("Runs on this Mac"))
            : Locality(icon: "cloud", text: L("Uses the cloud"))
    }

    /// The record, read off the main actor, with this launch's settled runs
    /// laid over it (one that just ended may not be written yet).
    func reloadRuns() {
        runsTask?.cancel()
        let id = workflowID
        runsTask = Task { [weak self] in
            let loaded = await WorkflowRunStore.shared.loadRuns(workflowID: id, limit: 50, includeTests: false)
            guard !Task.isCancelled, let self else { return }
            let live = WorkflowRunStore.shared.live.values.filter { $0.workflowID == id && !$0.isTest }
            let going = Set(live.filter { !$0.status.isTerminal }.map(\.id))
            var byID = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for run in live where run.status.isTerminal { byID[run.id] = run }
            let settled = byID.values.filter { !going.contains($0.id) }.sorted { $0.startedAt > $1.startedAt }
            if settled != self.recordedRuns { self.recordedRuns = settled }
        }
    }
}
