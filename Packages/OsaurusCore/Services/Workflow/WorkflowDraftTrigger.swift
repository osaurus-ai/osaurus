//
//  WorkflowDraftTrigger.swift
//  osaurus
//
//  The automation the Architect proposes with `workflow_propose_save`: one
//  `automations[]` entry without `workflow`, checked against the draft
//  with the same `ConfigEvents.build` the Orchestrator's apply uses, then
//  created by the save card once the workflow is installed. Matched by
//  name, so saving a new version again updates it instead of adding a
//  second one.
//

import Foundation

struct WorkflowDraftTrigger: Equatable, Sendable {
    /// The automation entry; `workflow` is filled in at save.
    var entry: EventEntry
    /// "Schedule · Every day at 8:00 AM", for the card and the tool result.
    var summary: String
    /// Notes the apply will raise (a new webhook's URL is in Automations).
    var notes: [String]

    /// Proposals waiting on their draft's save card, by draft id.
    @MainActor private static var pending: [UUID: WorkflowDraftTrigger] = [:]

    @MainActor static func proposed(for draftID: UUID) -> WorkflowDraftTrigger? { pending[draftID] }

    @MainActor static func setProposed(_ trigger: WorkflowDraftTrigger?, for draftID: UUID) {
        pending[draftID] = trigger
    }

    /// Kinds a workflow trigger may use. Channel messages are routing rules
    /// set up in Channels; email is a channel.
    static let allowedKinds: [EventSourceKind] = [.schedule, .folder, .webhook, .rss, .sse, .runFailed, .app]

    /// Parse and check `value` (the tool's `trigger` argument) against
    /// `draft`. The failure is a message for the Architect.
    @MainActor
    static func parse(_ value: JSONValue, draft: WorkflowDraft) -> Result<WorkflowDraftTrigger, ConfigEventError> {
        guard var object = value.objectValue else {
            return .failure(.init("`trigger` must be an object: {name, source: {kind, ...}, input: {...}}."))
        }
        for key in ["agent", "instructions", "model", "working_folder", "fresh_session", "reply"]
        where object[key] != nil {
            return .failure(.init("`trigger.\(key)`: a trigger runs this workflow; leave `\(key)` out."))
        }
        if object["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            object["name"] = .string(draft.name)
        }
        object.removeValue(forKey: "workflow")
        let entry: EventEntry
        do {
            entry = try JSONDecoder().decode(EventEntry.self, from: JSONEncoder().encode(JSONValue.object(object)))
        } catch {
            return .failure(
                .init(
                    "`trigger` does not match an automation entry: \(error.localizedDescription) Shape: {name, "
                        + "source: {kind: schedule | folder | webhook | rss | sse | run_failed | app, ...}, "
                        + "input: {field: \"{{schedule.scheduled_for}}\"}}."))
        }
        guard let rawKind = entry.source?.kind?.lowercased(), let kind = EventSourceKind(rawValue: rawKind),
            allowedKinds.contains(kind)
        else {
            return .failure(
                .init(
                    "`trigger.source.kind` must be one of: " + allowedKinds.map(\.rawValue).joined(separator: ", ")
                        + ". Channel messages start a workflow through a rule in Channels → Routing."))
        }
        let installedID = draft.templateID.flatMap { InstalledWorkflowStore.shared.workflow(templateID: $0)?.id }
        return check(entry, draftSchema: draft.definition.inputSchema, installedID: installedID)
    }

    /// Build the automation against a stand-in for the workflow (the draft
    /// is not installed yet, or is a new version of `installedID`).
    @MainActor
    static func check(
        _ entry: EventEntry, draftSchema: JSONValue, installedID: UUID?
    ) -> Result<WorkflowDraftTrigger, ConfigEventError> {
        let workflowID = installedID ?? UUID()
        var probe = entry
        probe.workflow = workflowID.uuidString
        let existing = ConfigEvents.existingEvent(named: entry.name, in: .automations)
        if let existing {
            guard let current = existing.action.workflow, current.workflowID == installedID else {
                return .failure(
                    .init(
                        "`trigger.name`: `\(entry.name)` is already an automation that runs something else — "
                            + "pick another name."))
            }
        } else if let other = ConfigEvents.existingEvent(named: entry.name) {
            return .failure(
                .init("`trigger.name`: the name is taken by \(ConfigEventScope.describe(other)) — pick another name."))
        }
        let built = ConfigEvents.build(
            probe, existing: existing, resolveAgent: ConfigEvents.liveAgentResolver,
            resolveWorkflow: { $0 == workflowID.uuidString ? workflowID : ConfigEvents.liveWorkflowResolver($0) },
            workflowInputSchema: { $0 == workflowID ? draftSchema : nil },
            mintBookmarks: false, path: "trigger")
        switch built {
        case .failure(let error):
            return .failure(error)
        case .success(let outcome):
            let summary = "\(outcome.event.sourceKind.displayName) · \(outcome.event.sourceSummary)"
            return .success(WorkflowDraftTrigger(entry: entry, summary: summary, notes: outcome.notes))
        }
    }

    /// Create (or update) the automation for the saved workflow.
    @MainActor
    func apply(to installed: InstalledWorkflow) -> ConfigApplyResult? {
        var entry = entry
        entry.workflow = installed.id.uuidString
        return ConfigEvents.apply([entry], scope: .automations, prune: false).first
    }
}
