//
//  WorkflowCallFeed.swift
//  osaurus
//
//  What a workflow is doing while an agent's tool call runs it. The
//  calling chat's tool card shows each step as it starts and ends and the
//  text a model step has produced so far — the same stream the workflow
//  tab shows — instead of a bare shimmer until the final envelope. Mirrors
//  the run records the runner already publishes; it adds no channel of its
//  own and nothing here reaches the model or run history.
//

import Combine
import Foundation

@MainActor
final class WorkflowCallFeed {
    /// The feed kind the tool card labels "Workflow".
    static let kindId = "workflow"

    let feed: SubagentFeed
    private let registry: SubagentFeedRegistry
    private let names: [String: String]
    private var statuses: [String: NodeRunStatus] = [:]
    /// Characters of a running step's streamed text already shown.
    private var shown: [String: Int] = [:]
    private var waitingShown = false
    private var cancellable: AnyCancellable?
    private var finished = false

    /// The inline Architect's draft, shown as the card's first step:
    /// collapsed to its time, expanding to the steps it planned and why.
    struct Planning: Sendable, Equatable {
        var seconds: Double
        var reason: String?
    }

    /// Starts mirroring the run into a feed under the tool call's id. The
    /// card binds to it by that id as soon as it mounts.
    static func attach(
        runID: UUID, toolCallID: String, workflow: InstalledWorkflow, caller: WorkflowCaller,
        planning: Planning? = nil, store: WorkflowRunStore = .shared, registry: SubagentFeedRegistry = .shared
    ) -> WorkflowCallFeed {
        WorkflowCallFeed(
            runID: runID, toolCallID: toolCallID, workflow: workflow, caller: caller, planning: planning, store: store,
            registry: registry)
    }

    private init(
        runID: UUID, toolCallID: String, workflow: InstalledWorkflow, caller: WorkflowCaller, planning: Planning?,
        store: WorkflowRunStore, registry: SubagentFeedRegistry
    ) {
        self.registry = registry
        var names: [String: String] = [:]
        for node in workflow.definition.nodes {
            names[node.id] = node.name
            if case .map = node.kind { names[node.id + ".item"] = L("\(node.name) (item)") }
        }
        self.names = names
        feed = SubagentFeed(
            toolCallId: toolCallID, kindId: Self.kindId, title: workflow.name, agentId: caller.agentID,
            parentSessionId: caller.sessionID)
        registry.register(feed)
        if let planning { feed.emit(Self.planningEvent(planning, workflow: workflow)) }
        feed.emitPhase(L("Running \(workflow.name)"))
        if let current = store.run(id: runID) { apply(current) }
        cancellable = store.$live
            .compactMap { $0[runID] }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] run in self?.apply(run) }
    }

    /// Folds one run snapshot into the feed: a row per step change, the new
    /// tail of a running model step's text, and the end.
    func apply(_ run: WorkflowRun) {
        guard !finished else { return }
        for node in run.nodes {
            let name = names[node.nodeID] ?? node.nodeID
            if statuses[node.nodeID] != node.status {
                statuses[node.nodeID] = node.status
                shown[node.nodeID] = 0
                switch node.status {
                case .running:
                    feed.emitPhase(name, detail: node.attempts > 1 ? L("Attempt \(node.attempts)") : nil)
                case .awaitingUser:
                    feed.emitPhase(name, detail: L("Waiting for an answer"))
                case .done:
                    feed.emit(
                        SubagentActivityEvent(
                            kind: .outcome, title: name, detail: Self.doneDetail(node), success: true))
                case .failed:
                    feed.emit(SubagentActivityEvent(kind: .error, title: name, detail: node.error, success: false))
                case .skipped:
                    feed.emitPhase(name, detail: L("Skipped"))
                case .pending, .pinned:
                    break
                }
            }
            guard node.status == .running, let streamed = node.streamed, !streamed.isEmpty else { continue }
            var already = shown[node.nodeID] ?? 0
            if streamed.count < already { already = 0 }  // A new attempt started over.
            guard streamed.count > already else { continue }
            feed.emitStreamDelta(kind: .response, title: name, delta: String(streamed.dropFirst(already)))
            shown[node.nodeID] = streamed.count
        }
        if run.status == .awaitingUser {
            if !waitingShown {
                waitingShown = true
                feed.emitPhase(L("Waiting for the user to fill in a form"))
            }
        } else {
            waitingShown = false
        }
        if run.status.isTerminal { finish(run) }
    }

    /// Ends the feed with the run's outcome. Idempotent; `nil` means the
    /// run was lost. A parked run (the chat continues later) ends the feed
    /// too: this tool call is over.
    func finish(_ run: WorkflowRun?) {
        guard !finished else { return }
        finished = true
        cancellable = nil
        let (success, summary): (Bool, String)
        switch run?.status {
        case .completed?:
            success = true
            summary = L("Finished \(Self.stepCount(run))")
        case .awaitingUser?:
            success = true
            summary = L("Waiting for the user to fill in a form")
        case .failed?:
            success = false
            let reason = run?.error.map { e in e.nodeID.map { "\(names[$0] ?? $0): \(e.reason)" } ?? e.reason }
            summary = reason ?? L("The run failed")
        case .cancelled?:
            success = false
            summary = run?.error?.reason ?? L("Stopped")
        case .needsSetup?:
            success = false
            summary = L("Needs setup")
        case .running?, nil:
            success = false
            summary = L("The run was lost")
        }
        feed.finish(success: success, summary: summary)
        registry.unregister(toolCallId: feed.toolCallId)
    }

    static func planningEvent(_ planning: Planning, workflow: InstalledWorkflow) -> SubagentActivityEvent {
        let steps = workflow.definition.nodes.map { "• \($0.name)" }
        var lines = [steps.count == 1 ? L("Planned 1 step:") : L("Planned \(steps.count) steps:")] + steps
        if let reason = planning.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            lines += ["", reason]
        }
        return SubagentActivityEvent(
            kind: .outcome, title: ArchitectInlineHandoff.planningPhase,
            detail: String(format: "%.1f s", planning.seconds), success: true,
            expandableText: lines.joined(separator: "\n"))
    }

    private static func stepCount(_ run: WorkflowRun?) -> String {
        let done = run?.nodes.filter { $0.status == .done }.count ?? 0
        return done == 1 ? L("1 step") : L("\(done) steps")
    }

    private static func doneDetail(_ node: NodeRun) -> String? {
        var parts: [String] = []
        if let model = node.model { parts.append(model) }
        if let ms = node.durationMs { parts.append(ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
