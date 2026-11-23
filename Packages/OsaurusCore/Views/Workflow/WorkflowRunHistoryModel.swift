//
//  WorkflowRunHistoryModel.swift
//  osaurus
//
//  How a workflow run reads in a list: its outcome, who started it, its
//  time label, and the day groups, search and filters over an agent's
//  runs (the Architect sees every workflow's runs; any other agent sees
//  the runs it started and the runs of its workflows).
//

import SwiftUI

/// What the Runs tab lists, and how a run reads in it.
enum WorkflowRunHistoryModel {
    /// Most runs the tab loads.
    static let limit = 200

    enum StatusFilter: Hashable, CaseIterable {
        case all, needsYou, running, failed, completed, stopped

        var title: String {
            switch self {
            case .all: return L("All Runs")
            case .needsYou: return L("Waiting on You")
            case .running: return L("Running")
            case .failed: return L("Failed")
            case .completed: return L("Completed")
            case .stopped: return L("Stopped")
            }
        }

        func matches(_ status: WorkflowRunStatus) -> Bool {
            switch self {
            case .all: return true
            case .needsYou: return status == .awaitingUser || status == .needsSetup
            case .running: return status == .running
            case .failed: return status == .failed
            case .completed: return status == .completed
            case .stopped: return status == .cancelled
            }
        }
    }

    enum Day: Int, Comparable {
        case today, yesterday, thisWeek, older

        static func < (lhs: Day, rhs: Day) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .today: return L("Today")
            case .yesterday: return L("Yesterday")
            case .thisWeek: return L("Earlier This Week")
            case .older: return L("Older")
            }
        }
    }

    struct Section: Identifiable, Equatable {
        let day: Day
        let runs: [WorkflowRun]
        var id: Day { day }
    }

    /// A day header or a run, in list order.
    enum Item: Identifiable, Equatable {
        case header(Day)
        case run(WorkflowRun)

        var id: String {
            switch self {
            case .header(let day): return "day-\(day.rawValue)"
            case .run(let run): return run.id.uuidString
            }
        }
    }

    static func items(_ sections: [Section]) -> [Item] {
        sections.flatMap { [Item.header($0.day)] + $0.runs.map(Item.run) }
    }

    struct WorkflowChoice: Identifiable, Equatable {
        let id: UUID
        let name: String
        let count: Int
    }

    /// The runs `agentId`'s History lists: every run for the Architect;
    /// otherwise the runs the agent started (an unnamed caller counts as
    /// the Orchestrator) and the runs of `agentWorkflowIDs`. Test runs never.
    static func scope(_ runs: [WorkflowRun], agentId: UUID, agentWorkflowIDs: Set<UUID>) -> [WorkflowRun] {
        runs.filter { run in
            guard !run.isTest else { return false }
            if agentId == Agent.architectId || agentWorkflowIDs.contains(run.workflowID) { return true }
            return (run.caller.agentID ?? Agent.defaultId) == agentId
        }
    }

    /// `scope` against the agent's workflows on this Mac, dropping runs of
    /// workflows no longer installed.
    @MainActor
    static func scope(
        _ runs: [WorkflowRun],
        agentId: UUID,
        installed: InstalledWorkflowStore = .shared
    ) -> [WorkflowRun] {
        let mine = Set(WorkflowListModel.workflows(for: agentId, installed: installed).map(\.id))
        return scope(runs, agentId: agentId, agentWorkflowIDs: mine).filter {
            installed.workflow(id: $0.workflowID) != nil
        }
    }

    static func filter(
        _ runs: [WorkflowRun],
        status: StatusFilter,
        workflowID: UUID?,
        query: String,
        searchText: (WorkflowRun) -> String
    ) -> [WorkflowRun] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return runs.filter { run in
            status.matches(run.status) && (workflowID == nil || run.workflowID == workflowID)
                && (trimmed.isEmpty || SearchService.matches(query: trimmed, in: searchText(run)))
        }
    }

    /// The workflows `runs` belong to, by their most recent name.
    static func workflowChoices(_ runs: [WorkflowRun]) -> [WorkflowChoice] {
        var names: [UUID: String] = [:]
        var counts: [UUID: Int] = [:]
        for run in runs.sorted(by: { $0.startedAt > $1.startedAt }) {
            if names[run.workflowID] == nil { names[run.workflowID] = run.workflowName }
            counts[run.workflowID, default: 0] += 1
        }
        return names.map { WorkflowChoice(id: $0.key, name: $0.value, count: counts[$0.key] ?? 0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func day(of date: Date, now: Date, calendar: Calendar) -> Day {
        let today = calendar.startOfDay(for: now)
        let start = calendar.startOfDay(for: date)
        if start >= today { return .today }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
            let weekAgo = calendar.date(byAdding: .day, value: -6, to: today)
        else { return .older }
        if start >= yesterday { return .yesterday }
        if start >= weekAgo { return .thisWeek }
        return .older
    }

    /// Newest first, one section per day bucket that has runs.
    static func sections(_ runs: [WorkflowRun], now: Date = Date(), calendar: Calendar = .current) -> [Section] {
        let grouped = Dictionary(grouping: runs) { day(of: $0.startedAt, now: now, calendar: calendar) }
        return grouped.keys.sorted().map { day in
            Section(day: day, runs: grouped[day, default: []].sorted { $0.startedAt > $1.startedAt })
        }
    }

    /// "Failed at Download", "2 of 4 steps", or the first line of the result.
    @MainActor
    static func outcome(_ run: WorkflowRun, definition: WorkflowDefinition?) -> String {
        switch run.status {
        case .running:
            let done = run.nodes.filter { [.done, .pinned, .skipped].contains($0.status) }.count
            return L("\(done) of \(run.nodes.count) steps")
        case .awaitingUser:
            return WorkflowRunTabView.statusText(.awaitingUser)
        case .needsSetup:
            return firstLine(run.error?.reason) ?? WorkflowRunTabView.statusText(.needsSetup)
        case .cancelled:
            return firstLine(run.error?.reason) ?? WorkflowRunTabView.statusText(.cancelled)
        case .failed:
            if let nodeID = run.error?.nodeID ?? run.nodes.first(where: { $0.status == .failed })?.nodeID {
                return definition?.node(nodeID).map { L("Failed at \($0.name)") } ?? L("Failed at a step")
            }
            return firstLine(run.error?.reason) ?? WorkflowRunTabView.statusText(.failed)
        case .completed:
            guard let output = run.output, output != .null else { return WorkflowRunTabView.statusText(.completed) }
            let text: String
            if let definition {
                text = WorkflowResultCard.plainText(output, schema: definition.outputSchema)
            } else if case .string(let string) = output {
                text = string
            } else {
                text = WorkflowSummary.preview(output)
            }
            return firstLine(text) ?? WorkflowRunTabView.statusText(.completed)
        }
    }

    /// Who started the run: "Automation · Daily Digest", "Scheduled", "API",
    /// "You", or the agent's name.
    static func startedBy(_ run: WorkflowRun, agentName: (UUID) -> String?) -> String {
        startedBy(run.caller, agentName: agentName)
    }

    static func startedBy(_ caller: WorkflowCaller, agentName: (UUID) -> String?) -> String {
        if let teammate = caller.onBehalfOf { return ParticipantFormatter.compact(teammate) }
        if caller.kind == .event, let name = caller.eventName, !name.isEmpty { return L("Automation · \(name)") }
        if caller.isUnattendedDispatch { return L("Scheduled") }
        if caller.isExternalSurface { return L("API") }
        if caller.kind == .user { return L("You") }
        return caller.agentID.flatMap(agentName) ?? caller.agentName ?? L("An agent")
    }

    /// Time of day for this week's runs, the date for older ones.
    static func timeLabel(_ run: WorkflowRun, now: Date = Date(), calendar: Calendar = .current) -> String {
        day(of: run.startedAt, now: now, calendar: calendar) == .older
            ? run.startedAt.formatted(.dateTime.month(.abbreviated).day())
            : run.startedAt.formatted(date: .omitted, time: .shortened)
    }

    /// What to tell the Architect about a failed run.
    static func fixPrompt(_ run: WorkflowRun, definition: WorkflowDefinition?) -> String {
        WorkflowRepairBrief.message(run, definition: definition)
    }

    private static func firstLine(_ text: String?) -> String? {
        guard let line = text?.split(whereSeparator: \.isNewline).first else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
