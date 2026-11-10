//
//  TaskDetailSheet.swift
//  osaurus
//
//  One task in full: where it came from, how long it waited and ran, what
//  it produced, the tasks around it and every step it journaled.
//

import SwiftUI

struct TaskDetailSheet: View {
    let onClose: () -> Void

    @State private var taskId: UUID
    @State private var loadedTask: OsaurusTask?
    @State private var parent: OsaurusTask?
    @State private var children: [OsaurusTask] = []
    @State private var events: [TaskEvent] = []
    private var store: TaskStore { .shared }
    /// The live record while the task runs (heartbeats do not reload the
    /// sheet), else the loaded one.
    private var task: OsaurusTask? { store.live[taskId] ?? loadedTask }

    init(taskId: UUID, onClose: @escaping () -> Void) {
        self._taskId = State(initialValue: taskId)
        self.onClose = onClose
    }

    var body: some View {
        SettingsSheet(
            icon: task.map(TaskPresentation.icon) ?? "checklist",
            title: LocalizedStringKey(task?.title ?? L("Task")),
            subtitle: task.map { LocalizedStringKey(TaskPresentation.stateLabel($0)) },
            width: SettingsSheetWidth.regular,
            maxBodyHeight: 560,
            primary: stopAction,
            secondary: .init(label: "Done", handler: onClose),
            onClose: onClose
        ) {
            if let task {
                summary(task)
                links(task)
                lineage
                timeline
            } else {
                SettingsEmptyState(inline: "checklist", title: "This task is no longer in history.")
            }
        }
        .task(id: TaskReloadKey(taskId: taskId, revision: store.revision)) { await reload() }
    }

    private var stopAction: SettingsSheetFooter.Action? {
        guard let task, TaskControl.canStop(task) else { return nil }
        return .init(label: "Stop", isDestructive: true) { TaskControl.stop(task) }
    }

    // MARK: - Sections

    private func summary(_ task: OsaurusTask) -> some View {
        SettingsSection(title: "Summary") {
            SettingsValueRow(
                title: "Runs", value: task.work.isModelAnswer ? L("Model answer") : task.work.kind.displayName)
            SettingsValueRow(title: "Started by", value: task.origin.displayName)
            if store.hasMultipleQueues || task.queueId != TaskQueue.defaultID {
                SettingsValueRow(title: "Queue", value: store.queue(id: task.queueId)?.name ?? L("Default"))
            }
            if let waiting = waitingOn(task) {
                SettingsValueRow(title: "Waiting On", value: waiting)
            }
            if let queued = task.queuedAt, let admitted = task.admittedAt {
                SettingsValueRow(title: "Waited", value: TaskPresentation.duration(admitted.timeIntervalSince(queued)))
            }
            if let started = task.startedAt {
                SettingsValueRow(
                    title: "Ran For",
                    value: TaskPresentation.duration((task.finishedAt ?? Date()).timeIntervalSince(started)))
            }
            if task.attemptCount > 1 {
                SettingsValueRow(title: "Attempts", value: "\(task.attemptCount)")
            }
            if let note = task.progressNote, !note.isEmpty, !task.state.isTerminal {
                SettingsValueRow(title: "Now", value: note)
            }
            if let error = task.lastError, task.state == .failed {
                SettingsValueRow(title: "Error", value: error)
            }
            if let result = task.result?.summary, !result.isEmpty {
                SettingsValueRow(title: "Result", value: result)
            }
            SettingsValueRow(title: "Task ID", value: task.id.uuidString, monospaced: true, copyable: true)
        }
    }

    @ViewBuilder
    private func links(_ task: OsaurusTask) -> some View {
        let hasAutomation = task.origin == .automation && task.subscriptionId != nil
        SettingsSection(title: "Open") {
            if let origin = task.originSessionId, origin != task.sessionId {
                SettingsLinkRow(
                    title: "Started from chat", description: L("The conversation whose turn started this task"),
                    actionTitle: "Open"
                ) {
                    TaskControl.openOriginChat(task)
                }
            }
            if task.sessionId != nil {
                SettingsLinkRow(title: "Chat", description: L("The conversation this task ran in"), actionTitle: "Open") {
                    TaskControl.openSession(task)
                }
            }
            if let runId = task.workflowRunId {
                SettingsLinkRow(title: "Workflow run", description: L("Steps and outputs of the run"), actionTitle: "Open") {
                    WorkflowRunLauncher.open(runID: runId)
                }
            }
            if hasAutomation {
                SettingsLinkRow(title: "Automation", description: L("What started this task"), actionTitle: "Open") {
                    onClose()
                    TaskControl.openAutomation(task)
                }
            }
            SettingsLinkRow(
                title: "Insights",
                description: L("Every request and tool call this task made"),
                icon: "chart.bar.xaxis",
                actionTitle: "Show"
            ) {
                InsightsService.shared.showTask(task.id)
                InsightsService.shared.focus(taskId: task.id)
                onClose()
                ManagementStateManager.shared.selectedTab = .insights
            }
        }
    }

    @ViewBuilder
    private var lineage: some View {
        if parent != nil || !children.isEmpty {
            SettingsSection(title: "Related Tasks") {
                if let parent {
                    TaskRow(task: parent) { taskId = parent.id }
                }
                ForEach(children) { child in
                    TaskRow(task: child) { taskId = child.id }
                }
            }
        }
    }

    @ViewBuilder
    private var timeline: some View {
        if !events.isEmpty {
            SettingsSection(title: "Timeline") {
                ForEach(events) { event in
                    if event.kind == .approvalResolved,
                        let attentionId = event.data["attention_id"].flatMap(UUID.init(uuidString:))
                    {
                        SettingsLinkRow(
                            title: eventTitle(event),
                            description: event.at.formatted(date: .omitted, time: .standard),
                            icon: "chart.bar.xaxis",
                            actionTitle: "View in Insights"
                        ) {
                            InsightsService.shared.showInteraction(attentionId: attentionId)
                            onClose()
                            ManagementStateManager.shared.selectedTab = .insights
                        }
                    } else {
                        SettingsValueRow(
                            title: eventTitle(event),
                            value: event.at.formatted(date: .omitted, time: .standard),
                            verbatimTitle: true)
                    }
                }
            }
        }
    }

    /// What the task is blocked on: a queue reason, or the request it is
    /// waiting for you to answer and who it is for.
    private func waitingOn(_ task: OsaurusTask) -> String? {
        guard !task.state.isTerminal else { return nil }
        if let item = AttentionCenter.shared.pending.last(where: { $0.taskId == task.id && $0.kind.isBlocking }) {
            var value = item.kind.displayName
            if let tool = item.toolName { value += ": \(tool)" }
            if let requester = item.requester, !requester.kind.isTrusted {
                value += " · \(ParticipantFormatter.short(requester))"
            }
            return value
        }
        return TaskPresentation.waitLabel(task.waitReason)
    }

    private func eventTitle(_ event: TaskEvent) -> String {
        let attentionKind = event.data["attention_kind"].flatMap(AttentionKind.init(rawValue:))
        var title = attentionKind?.displayName ?? event.kind.displayName
        if let tool = event.data["tool"] { title += ": \(tool)" }
        if let reason = event.reason, !reason.isEmpty { title += " — \(reason)" }
        guard event.kind != .approvalRequested else { return title }
        if let who = event.data["who"] {
            title += " · \(who)"
        } else if event.actor?.kind == .user {
            title += " " + L("(you)")
        }
        return title
    }

    // MARK: - Loading

    private func reload() async {
        let loaded = await store.loadTask(id: taskId)
        loadedTask = loaded
        if let parentId = loaded?.parentId {
            parent = await store.loadTask(id: parentId)
        } else {
            parent = nil
        }
        children = await store.tasks(TaskQuery(parentId: taskId, limit: 50))
        events = await store.events(for: taskId)
    }
}

private struct TaskReloadKey: Hashable {
    let taskId: UUID
    let revision: Int
}
