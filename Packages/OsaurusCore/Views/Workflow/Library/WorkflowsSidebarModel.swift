//
//  WorkflowsSidebarModel.swift
//  osaurus
//
//  What the Workflows sidebar lists, from plain values so it is testable:
//  Pinned, All workflows (installed and teammates' hosted links), Drafts
//  and Workspaces, each workflow with its status and the few words that
//  say how it runs. The view draws it; `WorkflowsOverviewModel` feeds it.
//

import Foundation

struct WorkflowsSidebarModel: Equatable {
    /// How a workflow runs, worst first.
    enum Status: Equatable, Sendable {
        /// Can't run until Set Up is finished.
        case needsSetup
        /// An automation's latest run failed, or its target has a problem.
        case problem
        /// At least one automation is on and its latest run did not fail.
        case automated
        /// Nothing starts it but the person.
        case manual
    }

    enum RowKind: Equatable, Hashable, Sendable {
        case installed(UUID)
        /// A teammate's workflow that runs on their Mac.
        case hosted(UUID)
    }

    struct Row: Equatable, Identifiable, Sendable {
        let kind: RowKind
        let name: String
        /// Already localized.
        let subtitle: String
        let status: Status
        let isPinned: Bool
        let isPublished: Bool
        /// Hosted links can't be automated or shared from here.
        var canAutomate: Bool { if case .installed = kind { return true } else { return false } }
        var id: RowKind { kind }

        /// Stable tie-break between two rows with the same name.
        var sortKey: String {
            switch kind {
            case .installed(let id): return "0" + id.uuidString
            case .hosted(let id): return "1" + id.uuidString
            }
        }

        var workflowID: UUID? {
            if case .installed(let id) = kind { return id }
            return nil
        }
    }

    struct DraftRow: Equatable, Identifiable, Sendable {
        let id: UUID
        let name: String
    }

    struct WorkspaceRow: Equatable, Identifiable, Sendable {
        let id: String
        let name: String
    }

    /// Facts about one workflow's automations the model can't derive from
    /// the workflow itself.
    struct AutomationFacts: Equatable, Sendable {
        var event: OsaurusEvent
        /// The latest run that settled (succeeded or failed); nil before one.
        var latestSettled: EventRunStatus?
        /// `EventInspection.targetProblem` found something.
        var hasTargetProblem = false
    }

    var pinned: [Row] = []
    var all: [Row] = []
    var drafts: [DraftRow] = []
    var workspaces: [WorkspaceRow] = []

    var isEmpty: Bool { pinned.isEmpty && all.isEmpty && drafts.isEmpty && workspaces.isEmpty }

    /// `automations` maps a workflow id to its workflow-action automations,
    /// oldest first. A non-empty `query` matches names (and an installed
    /// workflow's tags) the way chat search does.
    static func make(
        workflows: [InstalledWorkflow],
        hostedLinks: [HostedWorkflowLink] = [],
        automations: [UUID: [AutomationFacts]] = [:],
        publishedTemplateIDs: Set<UUID> = [],
        drafts: [WorkflowDraft] = [],
        workspaces: [WorkspaceRow] = [],
        query: String = "",
        style: AutomationSentence.Style = .current
    ) -> WorkflowsSidebarModel {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        func matches(_ text: String) -> Bool { trimmed.isEmpty || SearchService.matches(query: trimmed, in: text) }

        func row(_ workflow: InstalledWorkflow) -> Row {
            installedRow(
                workflow, automations: automations[workflow.id] ?? [],
                isPublished: publishedTemplateIDs.contains(workflow.templateID), style: style)
        }

        var model = WorkflowsSidebarModel()
        var pinned: [(row: Row, at: Date?)] = []
        var unpinned: [Row] = []
        for workflow in workflows where matches(workflow.searchText) {
            if workflow.isPinned { pinned.append((row(workflow), workflow.pinnedAt)) } else { unpinned.append(row(workflow)) }
        }
        for link in hostedLinks where matches(link.name) {
            let row = Row(
                kind: .hosted(link.id), name: link.name, subtitle: link.hostLabel, status: .manual,
                isPinned: link.isPinned, isPublished: false)
            if link.isPinned { pinned.append((row, link.pinnedAt)) } else { unpinned.append(row) }
        }
        model.pinned = pinned.sorted { pinOrder($0.at, $0.row, $1.at, $1.row) }.map(\.row)
        model.all = unpinned.sorted(by: nameOrder)
        model.drafts = drafts.sorted { $0.updatedAt > $1.updatedAt }.compactMap { draft in
            let name = draft.name.isEmpty ? L("Untitled Workflow") : draft.name
            return matches(name) ? DraftRow(id: draft.id, name: name) : nil
        }
        model.workspaces = workspaces.filter { matches($0.name) }
        return model
    }

    /// By name; the same name keeps a stable order.
    static func nameOrder(_ lhs: Row, _ rhs: Row) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        return order == .orderedSame ? lhs.sortKey < rhs.sortKey : order == .orderedAscending
    }

    /// Oldest pin first; a pin with no date first.
    static func pinOrder(_ lhsAt: Date?, _ lhs: Row, _ rhsAt: Date?, _ rhs: Row) -> Bool {
        switch (lhsAt, rhsAt) {
        case let (l?, r?) where l != r: return l < r
        case (nil, _?): return true
        case (_?, nil): return false
        default: return nameOrder(lhs, rhs)
        }
    }

    static func installedRow(
        _ workflow: InstalledWorkflow, automations: [AutomationFacts], isPublished: Bool,
        style: AutomationSentence.Style = .current
    ) -> Row {
        let status = status(workflow, automations: automations)
        return Row(
            kind: .installed(workflow.id), name: workflow.name,
            subtitle: subtitle(status: status, automations: automations, style: style),
            status: status, isPinned: workflow.isPinned, isPublished: isPublished)
    }

    /// The worst state among the workflow's automations that are on. One
    /// turned off by the person counts for nothing.
    static func status(_ workflow: InstalledWorkflow, automations: [AutomationFacts]) -> Status {
        if workflow.needsSetup { return .needsSetup }
        let on = automations.filter(\.event.isEnabled)
        if on.contains(where: { $0.latestSettled == .failed || $0.hasTargetProblem }) { return .problem }
        return on.isEmpty ? .manual : .automated
    }

    static func subtitle(
        status: Status, automations: [AutomationFacts], style: AutomationSentence.Style = .current
    ) -> String {
        if status == .problem { return L("Needs attention") }
        let on = automations.filter(\.event.isEnabled)
        guard let first = on.first else { return status == .needsSetup ? L("Finish setup to run") : L("Run by hand") }
        let words = AutomationSentence.short(first.event, style: style)
        let more = on.count - 1
        return more > 0 ? L("\(words) +\(more) more") : words
    }
}
