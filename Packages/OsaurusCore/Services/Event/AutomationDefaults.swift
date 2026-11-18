//
//  AutomationDefaults.swift
//  osaurus
//
//  A new automation for one workflow, made from the Workflows screens. It
//  has the shape the automation editor in Settings writes: the source
//  kind's delivery defaults, no filter, no reply, and the input mapping the
//  editor prefills when a workflow is picked. A workflow whose required
//  inputs that mapping can't fill starts off, so it never runs without them.
//

import Foundation

enum AutomationDefaults {
    /// "Every weekday at 9:00 AM".
    static let scheduleFrequency = ScheduleCronShape.weekdays(hour: 9, minute: 0).frequency

    static var schedule: EventSource { .schedule(ScheduleSourceConfig(frequency: scheduleFrequency)) }

    static var appLaunch: EventSource { .app(AppEventsSourceConfig(reasons: [.appLaunched])) }

    static func folder(path: String, bookmark: Data?) -> EventSource {
        .folder(FolderSourceConfig(path: path, bookmark: bookmark))
    }

    static func feed(url: String) -> EventSource { .rss(RSSSourceConfig(url: url)) }

    static var runFailed: EventSource { .runFailed(RunFailedSourceConfig()) }

    /// "Morning Brief schedule", as Settings lists it.
    static func name(workflowName: String, kind: EventSourceKind) -> String {
        switch kind {
        case .schedule: return L("\(workflowName) schedule")
        case .folder: return L("\(workflowName) folder")
        case .rss: return L("\(workflowName) feed")
        case .app: return L("\(workflowName) on launch")
        default: return L("\(workflowName) automation")
        }
    }

    /// The editor's prefill without its catch-all: an input bound to the
    /// main text only because nothing else fit is left for the person, so
    /// a one-click automation never hands a workflow "app_launched" as a
    /// recipient. Defaults and the kind's named values stay.
    static func inputMapping(schema: JSONValue, kind: EventSourceKind) -> [String: String] {
        let fields = Set(WorkflowFormFields.fields(fromInputSchema: schema).map(\.key))
        let descriptor = kind.descriptor
        return WorkflowInputBinding.prefill(schema: schema, sourceKind: kind).filter { key, value in
            guard fields.contains(key), !value.isEmpty else { return false }
            return value != "{{text}}" || descriptor.knownBinding(field: key.lowercased()) == "{{text}}"
        }
    }

    /// Required inputs nothing fills each time.
    static func missingInputs(schema: JSONValue, mapping: [String: String]) -> [DialogField] {
        WorkflowInputBinding.missingRequired(
            fields: WorkflowFormFields.fields(fromInputSchema: schema), mapping: mapping)
    }

    static func event(
        workflowID: UUID, workflowName: String, inputSchema: JSONValue, source: EventSource, now: Date = Date()
    ) -> OsaurusEvent {
        let mapping = inputMapping(schema: inputSchema, kind: source.kind)
        return OsaurusEvent(
            name: name(workflowName: workflowName, kind: source.kind),
            isEnabled: missingInputs(schema: inputSchema, mapping: mapping).isEmpty,
            source: source,
            action: .workflow(WorkflowEventAction(workflowID: workflowID, inputMapping: mapping)),
            createdAt: now, updatedAt: now)
    }

    static func event(for workflow: InstalledWorkflow, source: EventSource) -> OsaurusEvent {
        event(
            workflowID: workflow.id, workflowName: workflow.name,
            inputSchema: workflow.definition.inputSchema, source: source)
    }
}
