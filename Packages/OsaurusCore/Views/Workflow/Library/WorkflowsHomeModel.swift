//
//  WorkflowsHomeModel.swift
//  osaurus
//
//  What Workflows Home shows, from the same facts the sidebar reads: how
//  many workflows run on their own and how many need attention, the
//  pinned workflows as tiles, every automation that runs a workflow
//  (grouped by workflow) with how it last went, and the ways to automate.
//

import Foundation

/// Scroll targets on Home.
enum WorkflowsHomeSection {
    static let ways = "workflows.home.ways"
    static let runningOnTheirOwn = "workflows.home.runningOnTheirOwn"
}

struct WorkflowsHomeModel {
    struct Tile: Identifiable {
        let id: UUID
        let name: String
        let summary: String?
        /// "Ran today, 8:00 AM", "Failed yesterday", "Not run yet".
        let lastRun: String
        let lastRunFailed: Bool
        let needsSetup: Bool
    }

    struct AutomationRow: Identifiable {
        var id: UUID { event.id }
        let event: OsaurusEvent
        let workflowID: UUID
        let workflowName: String
        /// "runs every weekday at 8:00 AM", after the workflow's name.
        let sentence: String
        let state: String
        let stateTone: ThemeStatusKind?
    }

    struct Group: Identifiable {
        let id: UUID
        let name: String
        let rows: [AutomationRow]
    }

    struct Way: Identifiable {
        let item: AutomationCatalog.Item
        /// "On for 3 workflows" or "Set up".
        let state: String
        let enabledCount: Int
        var id: AutomationCatalog.Entry { item.entry }
    }

    var runOnOwnCount = 0
    var attentionCount = 0
    var subtitle = ""
    var pinned: [Tile] = []
    var groups: [Group] = []
    var otherAutomationCount = 0
    var ways: [Way] = []

    var automationCount: Int { groups.reduce(0) { $0 + $1.rows.count } }

    /// `automations` maps a workflow id to its workflow-action automations,
    /// oldest first; `eventRuns` are each automation's fires, newest first;
    /// `workflowRuns` are recent runs, newest first.
    static func make(
        workflows: [InstalledWorkflow],
        automations: [UUID: [WorkflowsSidebarModel.AutomationFacts]],
        eventRuns: [UUID: [EventRun]] = [:],
        workflowRuns: [WorkflowRun] = [],
        otherAutomationCount: Int = 0,
        now: Date = Date(),
        style: AutomationSentence.Style = .current
    ) -> WorkflowsHomeModel {
        var model = WorkflowsHomeModel()
        let byID = Dictionary(workflows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for workflow in workflows {
            switch WorkflowsSidebarModel.status(workflow, automations: automations[workflow.id] ?? []) {
            case .automated: model.runOnOwnCount += 1
            case .problem:
                model.runOnOwnCount += 1
                model.attentionCount += 1
            case .manual, .needsSetup: break
            }
        }
        model.subtitle = subtitle(runOnOwn: model.runOnOwnCount, attention: model.attentionCount)

        var latestRun: [UUID: WorkflowRun] = [:]
        for run in workflowRuns where !run.isTest && latestRun[run.workflowID] == nil { latestRun[run.workflowID] = run }
        model.pinned = workflows.filter(\.isPinned)
            .sorted { ($0.pinnedAt ?? .distantPast, $0.name) < ($1.pinnedAt ?? .distantPast, $1.name) }
            .map { workflow in
                let run = latestRun[workflow.id]
                return Tile(
                    id: workflow.id, name: workflow.name, summary: workflow.summary,
                    lastRun: lastRunLine(run, now: now, style: style),
                    lastRunFailed: run?.status == .failed || run?.status == .needsSetup,
                    needsSetup: workflow.needsSetup)
            }

        model.groups = automations.compactMap { workflowID, facts -> Group? in
            guard let workflow = byID[workflowID], !facts.isEmpty else { return nil }
            let rows = facts.sorted { $0.event.createdAt < $1.event.createdAt }.map { fact in
                let runs = eventRuns[fact.event.id] ?? []
                let latest = fact.latestSettled == nil ? nil : runs.first { $0.status == .succeeded || $0.status == .failed }
                let state = WorkflowAutomationState.line(
                    fact.event, latestSettled: latest, needsSetup: workflow.needsSetup,
                    hasTargetProblem: fact.hasTargetProblem, now: now, style: style)
                return AutomationRow(
                    event: fact.event, workflowID: workflowID, workflowName: workflow.name,
                    sentence: AutomationSentence.long(fact.event, style: style),
                    state: state.text, stateTone: state.tone)
            }
            return Group(id: workflowID, name: workflow.name, rows: rows)
        }
        .sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : order == .orderedAscending
        }

        model.otherAutomationCount = otherAutomationCount
        let events = model.groups.flatMap { $0.rows.map(\.event) }
        model.ways = AutomationCatalog.items.map { item in
            let count = AutomationCatalog.enabledWorkflowCount(item.entry, in: events)
            return Way(item: item, state: count > 0 ? L("On for \(count) workflows") : L("Set up"), enabledCount: count)
        }
        return model
    }

    /// "1 running now. 4 run on their own. 1 needs your attention."
    static func subtitle(runOnOwn: Int, attention: Int, running: Int = 0) -> String {
        var parts: [String] = []
        if running > 0 { parts.append(L("\(running) running now.")) }
        if runOnOwn == 1 {
            parts.append(L("1 runs on its own."))
        } else if runOnOwn > 1 {
            parts.append(L("\(runOnOwn) run on their own."))
        }
        if attention == 1 {
            parts.append(L("1 needs your attention."))
        } else if attention > 1 {
            parts.append(L("\(attention) need your attention."))
        }
        return parts.isEmpty ? L("Nothing runs on its own yet.") : parts.joined(separator: " ")
    }

    /// A tile's last line.
    static func lastRunLine(_ run: WorkflowRun?, now: Date = Date(), style: AutomationSentence.Style = .current) -> String {
        guard let run else { return L("Not run yet") }
        let date = run.finishedAt ?? run.startedAt
        let day = WorkflowRunWords.day(date, now: now, style: style)
        switch run.status {
        case .running, .awaitingUser: return L("Running now")
        case .completed: return L("Ran \(day)")
        case .failed, .needsSetup: return L("Failed \(day)")
        case .cancelled: return L("Stopped \(day)")
        }
    }
}
