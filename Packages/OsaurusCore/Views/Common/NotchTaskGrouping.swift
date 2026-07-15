//
//  NotchTaskGrouping.swift
//  osaurus
//
//  Presentation model for the agent-tabbed notch. Groups the manager's
//  pre-sorted toast tasks into one tab per agent and resolves the
//  (possibly stale) tab/session selection against the current task set,
//  so the notch view never has to reason about index arithmetic.
//

import Foundation

// MARK: - Agent Group

/// One agent tab in the expanded notch: every notch-visible task (active,
/// queued, waiting, or recently finished) belonging to a single agent.
@MainActor
struct NotchAgentGroup: Identifiable {
    let agentId: UUID
    /// Tasks in the group, preserving the `sortedToastTasks` ordering
    /// (waiting first, then running, queued, terminal; recency within a
    /// status band).
    let tasks: [BackgroundTaskState]

    nonisolated var id: UUID { agentId }

    /// The group's highest-priority task. The input ordering is already
    /// sorted by status priority, so this is simply the head.
    var primaryTask: BackgroundTaskState? { tasks.first }

    var hasActiveTasks: Bool { tasks.contains { $0.status.isActive } }

    var activeTaskCount: Int { tasks.filter { $0.status.isActive }.count }
}

// MARK: - Grouping & Selection

@MainActor
enum NotchTaskGrouping {
    /// Group pre-sorted toast tasks by agent. Group order follows each
    /// agent's first (highest-priority) task; tasks within a group keep
    /// their global order. An agent therefore bubbles to the front of the
    /// tab rail when one of its sessions starts waiting for input.
    static func groups(from sortedTasks: [BackgroundTaskState]) -> [NotchAgentGroup] {
        var order: [UUID] = []
        var tasksByAgent: [UUID: [BackgroundTaskState]] = [:]
        for task in sortedTasks {
            if tasksByAgent[task.agentId] == nil { order.append(task.agentId) }
            tasksByAgent[task.agentId, default: []].append(task)
        }
        return order.map { NotchAgentGroup(agentId: $0, tasks: tasksByAgent[$0] ?? []) }
    }

    /// Resolve a stored tab/session selection against the current groups.
    /// Selection is id-based so it survives reordering; when the selected
    /// agent or task has since finalized, fall back to the first group and
    /// that group's highest-priority task rather than showing nothing.
    static func resolveSelection(
        groups: [NotchAgentGroup],
        selectedAgentId: UUID?,
        selectedTaskId: UUID?
    ) -> (group: NotchAgentGroup, task: BackgroundTaskState)? {
        guard let group = groups.first(where: { $0.agentId == selectedAgentId }) ?? groups.first
        else { return nil }
        guard
            let task = group.tasks.first(where: { $0.id == selectedTaskId })
                ?? group.tasks.first
        else { return nil }
        return (group, task)
    }
}
