//
//  WorkflowLiveRuns.swift
//  osaurus
//
//  This launch's runs (tests left out), as the few facts a page shows about
//  them: how they stand, which step, of how many. The run store publishes
//  on every streamed word; this publishes only when one of these facts
//  changes, so pages that show a run going stay still while it streams.
//

import Combine
import SwiftUI

@MainActor
final class WorkflowLiveRuns: ObservableObject {
    static let shared = WorkflowLiveRuns()

    struct Summary: Equatable, Sendable, Identifiable {
        let id: UUID
        let workflowID: UUID
        let workflowName: String
        let status: WorkflowRunStatus
        let caller: WorkflowCaller
        /// 1-based: the step it is on.
        let step: Int
        let stepCount: Int
        let stepNodeID: String?
        let startedAt: Date
        let finishedAt: Date?

        init(_ run: WorkflowRun) {
            id = run.id
            workflowID = run.workflowID
            workflowName = run.workflowName
            status = run.status
            caller = run.caller
            let finished = run.nodes.filter { [.done, .pinned, .skipped].contains($0.status) }.count
            stepCount = run.nodes.count
            step = min(run.nodes.count, finished + 1)
            stepNodeID =
                run.status.isTerminal
                ? nil : (run.nodes.first { $0.status == .awaitingUser } ?? run.nodes.first { $0.status == .running })?.nodeID
            startedAt = run.startedAt
            finishedAt = run.finishedAt
        }

        var isGoing: Bool { !status.isTerminal }
        var isWaitingOnYou: Bool { status == .awaitingUser }

        func stepName(in definition: WorkflowDefinition?) -> String? {
            stepNodeID.flatMap { definition?.node($0)?.name }
        }

        /// "Step 4 of 6: Read those messages", "Waiting for your answer".
        func progress(stepName: String?) -> String {
            if isWaitingOnYou {
                return stepName.map { L("Waiting for your answer at \($0)") } ?? L("Waiting for your answer")
            }
            guard stepCount > 0 else { return L("Starting…") }
            let position = L("Step \(step) of \(stepCount)")
            return stepName.map { L("\(position): \($0)") } ?? position
        }

        /// For a narrow row beside a spinner: "Step 4 of 6", "Waiting for your answer".
        var shortLine: String { progress(stepName: nil) }
    }

    /// By run id.
    @Published private(set) var byRun: [UUID: Summary] = [:]
    private var subscription: AnyCancellable?

    init(store: WorkflowRunStore = .shared) {
        // `$live` fires before the store changes, with the new value.
        subscription = store.$live
            .map(Self.summaries)
            .removeDuplicates()
            .sink { [weak self] in self?.byRun = $0 }
    }

    nonisolated static func summaries(_ live: [UUID: WorkflowRun]) -> [UUID: Summary] {
        var out: [UUID: Summary] = [:]
        for run in live.values where !run.isTest { out[run.id] = Summary(run) }
        return out
    }

    /// Runs going now, newest first.
    var going: [Summary] { byRun.values.filter(\.isGoing).sorted { $0.startedAt > $1.startedAt } }

    /// The workflow's runs going now, newest first.
    func going(of workflowID: UUID) -> [Summary] { going.filter { $0.workflowID == workflowID } }
}

/// Draws `content` with the newest run of one workflow going now, so only
/// this part of a row redraws as runs start, move a step, and end.
struct WorkflowLiveRunReader<Content: View>: View {
    @ObservedObject private var live = WorkflowLiveRuns.shared
    let workflowID: UUID?
    @ViewBuilder let content: (WorkflowLiveRuns.Summary?) -> Content

    var body: some View {
        content(workflowID.flatMap { live.going(of: $0).first })
    }
}
