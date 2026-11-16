//
//  WorkflowActivityFeed.swift
//  osaurus
//
//  What Activity lists: every run of an installed workflow (test runs and
//  steps nested in another workflow left out), plus automations that could
//  not start their workflow at all, newest first. Filters, day groups,
//  which failures are still unresolved (the workflow has not finished a
//  run since), and Home's Needs attention list come from the same facts.
//

import Foundation

enum WorkflowActivityFilter: String, Hashable, CaseIterable, Sendable {
    case needsAttention, ranOnTheirOwn, runByMe

    var title: String {
        switch self {
        case .needsAttention: return L("Needs attention")
        case .ranOnTheirOwn: return L("Ran on their own")
        case .runByMe: return L("Run by me")
        }
    }
}

/// How Activity was asked to open: a filter, one workflow, and an item to
/// scroll to and expand.
struct WorkflowActivityRequest: Equatable, Sendable {
    var filter: WorkflowActivityFilter?
    var workflowID: UUID?
    var focusItemID: String?
}

extension Notification.Name {
    /// Activity is on screen and a link asked it to change its filter.
    static let workflowsActivityRequest = Notification.Name("WorkflowsActivityRequest")
}

struct WorkflowActivityItem: Identifiable, Equatable {
    enum Source: Equatable {
        case run(WorkflowRun)
        /// An automation's fire that failed before its workflow started.
        case refused(EventRun)
    }

    let source: Source
    let workflowID: UUID?
    let workflowName: String

    static func id(run: UUID) -> String { "run:" + run.uuidString }
    static func id(refused: UUID) -> String { "refused:" + refused.uuidString }

    var id: String {
        switch source {
        case .run(let run): return Self.id(run: run.id)
        case .refused(let fire): return Self.id(refused: fire.id)
        }
    }

    var date: Date {
        switch source {
        case .run(let run): return run.startedAt
        case .refused(let fire): return fire.firedAt
        }
    }

    var run: WorkflowRun? {
        if case .run(let run) = source { return run }
        return nil
    }

    var isFailed: Bool {
        switch source {
        case .run(let run): return run.status == .failed || run.status == .needsSetup
        case .refused: return true
        }
    }

    /// Finished one way or the other; a stopped run settles nothing.
    var isSettled: Bool {
        switch source {
        case .run(let run): return run.status == .completed || isFailed
        case .refused: return true
        }
    }

    var ranOnItsOwn: Bool {
        switch source {
        case .run(let run): return run.caller.kind == .event
        case .refused: return true
        }
    }

    var ranByMe: Bool { run?.caller.kind == .user }

    /// The automation behind it, when one started it.
    var eventID: UUID? {
        switch source {
        case .run(let run): return run.caller.eventID
        case .refused(let fire): return fire.eventId
        }
    }
}

struct WorkflowActivityDay: Identifiable, Equatable {
    let id: Date
    /// "Today", "Yesterday", "Friday", "Nov 3".
    let title: String
    let items: [WorkflowActivityItem]
}

/// A workflow in the problem state, for Home's banners.
struct WorkflowAttention: Identifiable, Equatable {
    var id: UUID { workflowID }
    let workflowID: UUID
    let workflowName: String
    let date: Date
    let explanation: WorkflowFailureExplanation
    /// The failed run, when the workflow started.
    let runID: UUID?
    /// Where Activity scrolls to for it.
    let itemID: String?
}

enum WorkflowActivityFeed {
    static let pageSize = 50
    static let attentionLimit = 3

    /// Newest first. `eventWorkflows` maps each workflow-action automation
    /// to its workflow; `names` the installed workflows' names.
    static func items(
        runs: [WorkflowRun], eventRuns: [EventRun], eventWorkflows: [UUID: UUID], names: [UUID: String]
    ) -> [WorkflowActivityItem] {
        let runItems = runs.filter { !$0.isTest && !$0.isDerived && $0.caller.kind != .workflow }.map { run in
            WorkflowActivityItem(source: .run(run), workflowID: run.workflowID, workflowName: names[run.workflowID] ?? run.workflowName)
        }
        let refusedItems = eventRuns.filter { $0.actionKind == .workflow && $0.status == .failed && $0.workflowRunId == nil }
            .map { fire -> WorkflowActivityItem in
                let workflowID = eventWorkflows[fire.eventId]
                return WorkflowActivityItem(
                    source: .refused(fire), workflowID: workflowID,
                    workflowName: workflowID.flatMap { names[$0] } ?? fire.eventName)
            }
        var seen = Set<String>()
        return (runItems + refusedItems)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id }
    }

    /// For each workflow, its newest settled item when that one failed: a
    /// later finished run resolves it.
    static func unresolved(_ items: [WorkflowActivityItem]) -> Set<String> {
        var decided = Set<String>()
        var failures = Set<String>()
        for item in items where item.isSettled {
            let key = item.workflowID?.uuidString ?? item.workflowName
            guard decided.insert(key).inserted else { continue }
            if item.isFailed { failures.insert(item.id) }
        }
        return failures
    }

    static func filter(
        _ items: [WorkflowActivityItem], by filter: WorkflowActivityFilter?, workflowID: UUID?, unresolved: Set<String>
    ) -> [WorkflowActivityItem] {
        items.filter { item in
            if let workflowID, item.workflowID != workflowID { return false }
            switch filter {
            case nil: return true
            case .needsAttention?: return unresolved.contains(item.id)
            case .ranOnTheirOwn?: return item.ranOnItsOwn
            case .runByMe?: return item.ranByMe
            }
        }
    }

    /// The first `pages` pages.
    static func page(_ items: [WorkflowActivityItem], pages: Int) -> [WorkflowActivityItem] {
        Array(items.prefix(max(1, pages) * pageSize))
    }

    static func days(
        _ items: [WorkflowActivityItem], now: Date = Date(), style: AutomationSentence.Style = .current
    ) -> [WorkflowActivityDay] {
        let calendar = style.calendar
        var days: [WorkflowActivityDay] = []
        for item in items {
            let start = calendar.startOfDay(for: item.date)
            if let last = days.last, last.id == start {
                days[days.count - 1] = WorkflowActivityDay(id: start, title: last.title, items: last.items + [item])
            } else {
                days.append(WorkflowActivityDay(id: start, title: dayTitle(item.date, now: now, style: style), items: [item]))
            }
        }
        return days
    }

    static func dayTitle(_ date: Date, now: Date = Date(), style: AutomationSentence.Style = .current) -> String {
        let calendar = style.calendar
        if calendar.isDate(date, inSameDayAs: now) { return L("Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return L("Yesterday")
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days > 0, days < 7 { return style.date(date, template: "EEEE") }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return style.date(date, template: sameYear ? "MMMMd" : "yMMMMd")
    }

    /// "Ran on schedule. Took 42 sec.", "You ran it. Could not finish."
    static func line(
        _ item: WorkflowActivityItem, event: OsaurusEvent?, agentName: (UUID) -> String? = { _ in nil }
    ) -> String {
        switch item.source {
        case .refused:
            let started = event.map(startPhrase) ?? L("Ran on its own")
            return L("\(started). Could not start.")
        case .run(let run):
            let started =
                run.caller.kind == .event
                ? (event.map(startPhrase) ?? L("Ran on its own"))
                : WorkflowRunWords.howItStarted(run.caller, event: event, agentName: agentName)
            switch run.status {
            case .completed:
                let seconds = (run.finishedAt ?? run.startedAt).timeIntervalSince(run.startedAt)
                return L("\(started). Took \(WorkflowRunWords.duration(seconds)).")
            case .failed: return L("\(started). Could not finish.")
            case .needsSetup: return L("\(started). Needs setup first.")
            case .cancelled: return L("\(started). Stopped.")
            case .running: return L("\(started). Running now.")
            case .awaitingUser: return L("\(started). Waiting for your answer.")
            }
        }
    }

    /// "Ran on schedule", "A file was added to Downloads".
    static func startPhrase(_ event: OsaurusEvent) -> String {
        if case .schedule = event.source { return L("Ran on schedule") }
        return WorkflowRunWords.automationPhrase(event)
    }

    /// The workflows in the problem state, newest failure first. `run`
    /// reads a recorded run; `targetProblem` says why an automation can't
    /// start its workflow.
    static func attention(
        workflows: [InstalledWorkflow],
        automations: [UUID: [WorkflowsSidebarModel.AutomationFacts]],
        latestSettled: (UUID) -> EventRun?,
        run: (UUID) -> WorkflowRun?,
        targetProblem: (OsaurusEvent) -> String?,
        now: Date = Date()
    ) -> [WorkflowAttention] {
        var found: [WorkflowAttention] = []
        for workflow in workflows {
            let facts = automations[workflow.id] ?? []
            guard WorkflowsSidebarModel.status(workflow, automations: facts) == .problem else { continue }
            let on = facts.filter(\.event.isEnabled)
            let failed = on.compactMap { fact -> EventRun? in
                guard fact.latestSettled == .failed, let fire = latestSettled(fact.event.id), fire.status == .failed else {
                    return nil
                }
                return fire
            }.max { $0.firedAt < $1.firedAt }
            if let failed {
                if let runID = failed.workflowRunId, let recorded = run(runID) {
                    found.append(
                        WorkflowAttention(
                            workflowID: workflow.id, workflowName: workflow.name, date: failed.firedAt,
                            explanation: WorkflowFailureSentence.explain(recorded, definition: workflow.definition),
                            runID: runID, itemID: WorkflowActivityItem.id(run: runID)))
                } else {
                    found.append(
                        WorkflowAttention(
                            workflowID: workflow.id, workflowName: workflow.name, date: failed.firedAt,
                            explanation: WorkflowFailureSentence.explain(refused: failed, workflowName: workflow.name),
                            runID: nil, itemID: failed.workflowRunId == nil ? WorkflowActivityItem.id(refused: failed.id) : nil))
                }
            } else if let blocked = on.first(where: \.hasTargetProblem) {
                let sentence = targetProblem(blocked.event) ?? L("Osaurus could not start \(workflow.name).")
                found.append(
                    WorkflowAttention(
                        workflowID: workflow.id, workflowName: workflow.name, date: blocked.event.lastFiredAt ?? now,
                        explanation: WorkflowFailureExplanation(sentence: sentence, failedStep: nil, shortReason: nil, remedy: nil),
                        runID: nil, itemID: nil))
            }
        }
        return found.sorted { $0.date != $1.date ? $0.date > $1.date : $0.workflowName < $1.workflowName }
    }
}
