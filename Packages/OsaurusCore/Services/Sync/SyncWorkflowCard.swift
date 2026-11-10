//
//  SyncWorkflowCard.swift
//  osaurus
//
//  A workflow run a chat's tool call started, as the user's other devices
//  show it: the workflow's name, each step and how it is going, and how the
//  run ended. The Mac chat's tool card follows the run the same way
//  (`WorkflowCallFeed`). Carried on the call in run progress while the reply
//  runs, and in the committed turn's `toolCallDisplay` after
//  (docs/SYNC_MOBILE_CONTRACT.md §3.2, §3.3, `workflow_runs`).
//

import Foundation
import os

struct SyncWorkflowCard: Codable, Equatable, Sendable {
    var runId: String
    var name: String
    /// running | awaiting_user | completed | failed | cancelled | needs_setup
    var status: String
    var steps: [Step]
    /// Why it failed, with the step's name when one did.
    var error: String?

    struct Step: Codable, Equatable, Sendable {
        var id: String
        var name: String
        /// pending | running | awaiting_user | done | skipped | failed | pinned
        var status: String
    }

    static let stepLimit = 40
    static let errorLimit = 300

    /// The card for `run`, naming its steps from `definition` when there is one.
    static func make(_ run: WorkflowRun, definition: WorkflowDefinition?) -> SyncWorkflowCard {
        var names: [String: String] = [:]
        for node in definition?.nodes ?? [] {
            names[node.id] = node.name
            if case .map = node.kind { names[node.id + ".item"] = L("\(node.name) (item)") }
        }
        let error = run.error.map { e in e.nodeID.map { "\(names[$0] ?? $0): \(e.reason)" } ?? e.reason }
        return SyncWorkflowCard(
            runId: run.id.uuidString.lowercased(),
            name: run.workflowName,
            status: run.status.rawValue,
            steps: run.nodes.prefix(stepLimit).map {
                Step(id: $0.nodeID, name: names[$0.nodeID] ?? $0.nodeID, status: $0.status.rawValue)
            },
            error: error.map { String($0.prefix(errorLimit)) }
        )
    }
}

/// The last card each workflow call showed, so a committed turn, written
/// off the main actor, carries the card its run ended with.
enum SyncWorkflowCards {
    private static let cards = OSAllocatedUnfairLock(initialState: [String: SyncWorkflowCard]())
    private static let rememberLimit = 200

    /// The run `callId` started: the one its result names, else the newest
    /// whose caller is that call. nil for a call that is not a workflow's.
    @MainActor
    static func card(forCall callId: String, name toolName: String, result: String?) -> SyncWorkflowCard? {
        guard WorkflowToolCall.isWorkflowCall(toolName) else { return nil }
        let store = WorkflowRunStore.shared
        let named = result.flatMap(WorkflowToolCall.runID(inResult:)).flatMap(store.run(id:))
        let started = store.live.values
            .filter { $0.caller.toolCallID == callId }
            .max { $0.startedAt < $1.startedAt }
        guard let run = named ?? started else { return remembered(forCall: callId) }
        let card = SyncWorkflowCard.make(
            run, definition: InstalledWorkflowStore.shared.workflow(id: run.workflowID)?.definition)
        cards.withLock { cards in
            if cards.count >= rememberLimit, cards[callId] == nil { cards.removeAll() }
            cards[callId] = card
        }
        return card
    }

    /// The card `callId` last showed in this launch.
    static func remembered(forCall callId: String) -> SyncWorkflowCard? {
        cards.withLock { $0[callId] }
    }
}

extension SyncWorkflowCard {
    /// The card with the status its call's result reports, when the result
    /// came in before the card caught up with the run's end.
    func settled(by result: String?) -> SyncWorkflowCard {
        guard let result, let object = JSONValue.parse(result)?.objectValue else { return self }
        let reported = object["result"]?.objectValue?["status"]?.stringValue ?? object["status"]?.stringValue
        guard let reported, reported != status else { return self }
        var card = self
        card.status = reported
        // A step still running when the card was taken finished with the run.
        if reported == WorkflowRunStatus.completed.rawValue {
            for index in card.steps.indices where card.steps[index].status == NodeRunStatus.running.rawValue {
                card.steps[index].status = NodeRunStatus.done.rawValue
            }
        }
        return card
    }

    /// The card as a JSON object, for a record built from JSON objects.
    var jsonObject: [String: Any]? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
