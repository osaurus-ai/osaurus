//
//  TasksView.swift
//  osaurus
//
//  The Tasks tab: one row per queue with what runs, what waits and the
//  last few that finished; and History, the one run history for
//  automations, background agents, workflows and helpers. What waits on
//  the owner is the Approvals page. Quiet by
//  design; a task's steps, lineage and links live in its detail sheet.
//

import SwiftUI

struct TasksView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var managementState = ManagementStateManager.shared
    @Environment(\.settingsLandingPending) private var landingPending
    private var store: TaskStore { .shared }
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var page: TasksPage = .queues
    @State private var historyFilter = TaskHistoryFilter()
    @State private var expandedQueues: Set<UUID> = []
    @State private var detail: TaskDetailRequest?
    @State private var queueEditor: QueueEditorRequest?
    /// Live foreground reservations; never stored.
    @State private var reservations: [ForegroundReservation] = []

    /// Finished tasks shown under each queue before "See All".
    private static let finishedTail = 3

    var body: some View {
        SettingsPage {
            header
        } content: {
            if !reservations.isEmpty || foregroundNote != nil {
                foregroundSection
            }
            switch page {
            case .queues:
                ForEach(store.queues) { queue in
                    lane(queue)
                }
            case .history:
                historySection
            }
        }
        .environment(\.theme, themeManager.currentTheme)
        .sheet(item: $detail) { request in
            TaskDetailSheet(taskId: request.id) { detail = nil }
        }
        .sheet(item: $queueEditor) { request in
            QueueSettingsSheet(queue: request.queue) { queueEditor = nil }
        }
        .onAppear {
            consumePendingDetail()
            consumePendingHistory()
            routeSettingsLanding(landingPending)
        }
        .task {
            // The center is the source of truth: an event's snapshot can
            // arrive after a newer one.
            let events = store.bus.stream()
            reservations = ForegroundReservationCenter.shared.active
            for await event in events {
                if case .reservationsChanged = event { reservations = ForegroundReservationCenter.shared.active }
            }
        }
        .onChange(of: landingPending) { _, pending in routeSettingsLanding(pending) }
        .onChange(of: managementState.pendingTaskDetailId) { _, _ in consumePendingDetail() }
        .onChange(of: managementState.pendingTaskHistory) { _, _ in consumePendingHistory() }
    }

    // MARK: - Header

    private var header: some View {
        SettingsPageHeader(
            title: "Tasks",
            subtitle: "Everything that runs on its own: automations, background agents, workflows and helpers",
            count: store.live.count,
            primary: {
                SettingsButton(.primary, "Add Queue", icon: "plus") {
                    queueEditor = QueueEditorRequest(queue: nil)
                }
                .settingsLandingAnchor("tasks.addQueue")
            },
            toolbar: {
                SettingsTabsRow(selection: $page, showSearch: false) {
                    if page == .history { historyFilters }
                }
                .settingsLandingAnchor("tasks.history")
            }
        )
    }

    // MARK: - Foreground

    /// Shown only while a chat is actually holding tasks back.
    private var foregroundNote: String? {
        let held = store.live.values.filter { $0.waitReason == "foreground_active" }.count
        guard held > 0 else { return nil }
        let model = ForegroundReservationCenter.shared.localActive.first?.model.map(Self.modelName)
        if let model, !model.isEmpty {
            return L("A chat on \(model) is using the model; \(held) waiting.")
        }
        return L("A chat is using the model; \(held) waiting.")
    }

    /// What holds a model right now: chats, API clients and plugins. Not
    /// tasks; tasks for another local model wait while one is local.
    private var foregroundSection: some View {
        SettingsSection(
            title: "Foreground",
            subtitle: foregroundNote ?? "Chats and requests using a model right now"
        ) {
            if foregroundNote != nil { StatusChip(L("Yielding"), tone: .info) }
        } content: {
            if reservations.isEmpty, let note = foregroundNote {
                SettingsRow(title: "Chat in Progress", description: note, verbatimDescription: true) { EmptyView() }
            }
            ForEach(reservations) { reservation in
                ForegroundRow(reservation: reservation, modelName: reservation.model.map(Self.modelName))
            }
        }
    }

    private static func modelName(_ id: String) -> String {
        ModelPickerItemCache.shared.items
            .first { $0.id.caseInsensitiveCompare(id) == .orderedSame }?.displayName ?? id
    }

    // MARK: - History

    private var historySection: some View {
        SettingsSection(
            title: "History",
            subtitle: "Every run, newest first, including skipped ones"
        ) {
            RecentTasksList(query: historyFilter.query(), emptyText: "Nothing matches.")
            if historyFilter.origin == nil || historyFilter.origin == .automation || historyFilter.origin == .channel {
                SettingsLinkRow(
                    title: "Channel Messages",
                    description: L("Messages refused, claimed by no automation, or taken as a form's answer"),
                    actionTitle: "Open"
                ) {
                    managementState.automationsSubTabRequest = AutomationsPage.history.rawValue
                    managementState.selectedTab = .automations
                }
            }
        }
    }

    private var historyFilters: some View {
        HStack(spacing: theme.settingsControlGap) {
            if let scope = historyScopeLabel {
                FilterChip(scope, icon: "xmark", isSelected: true) {
                    historyFilter.agentId = nil
                    historyFilter.workflowID = nil
                    historyFilter.originSessionId = nil
                }
            }
            SettingsMenuPicker(selection: $historyFilter.origin) {
                Text("From Anywhere", bundle: .module).tag(TaskOrigin?.none)
                ForEach(TaskOrigin.allCases, id: \.self) { origin in
                    Text(origin.displayName).tag(TaskOrigin?.some(origin))
                }
            }
            SettingsMenuPicker(selection: $historyFilter.status) {
                ForEach(TaskHistoryFilter.Status.allCases) { status in
                    Text(status.displayName).tag(status)
                }
            }
            if store.hasMultipleQueues {
                SettingsMenuPicker(selection: $historyFilter.queueId) {
                    Text("Every Queue", bundle: .module).tag(UUID?.none)
                    ForEach(store.queues) { queue in
                        Text(queue.name).tag(UUID?.some(queue.id))
                    }
                }
            }
        }
    }

    /// The agent, workflow or chat History is narrowed to, by name.
    private var historyScopeLabel: String? {
        if let id = historyFilter.originSessionId {
            let title = ChatSessionsManager.shared.sessions.first { $0.id == id }?.title ?? ""
            return title.isEmpty ? L("From one chat") : L("From \(title)")
        }
        if let id = historyFilter.agentId {
            return AgentManager.shared.agent(for: id)?.name ?? L("One agent")
        }
        if let id = historyFilter.workflowID {
            return InstalledWorkflowStore.shared.workflow(id: id)?.name ?? L("One workflow")
        }
        return nil
    }

    // MARK: - Queue Lanes

    private func lane(_ queue: TaskQueue) -> some View {
        let active = store.activeTasks.filter { $0.queueId == queue.id }
        let running = active.filter { $0.state == .running || $0.state == .admitted || $0.state == .waitingUser }
        let waiting = active.filter { $0.state == .queued || $0.state == .received }
        let finished = store.recent.filter { $0.queueId == queue.id && $0.state.isTerminal && $0.state.didRun }
        let expanded = expandedQueues.contains(queue.id)

        return SettingsSection(
            title: queue.name,
            subtitle: laneSubtitle(queue, running: running.count, waiting: waiting.count),
            anchorId: queue.isDefault ? "tasks.queue.default" : nil,
            verbatimTitle: true
        ) {
            HStack(spacing: theme.space.s6) {
                if queue.isDefault { StatusChip(L("Default"), tone: .neutral) }
                if queue.policy.paused { StatusChip(L("Paused"), tone: .warning) }
                SettingsIconButton("slider.horizontal.3", help: L("Queue Settings")) {
                    queueEditor = QueueEditorRequest(queue: queue)
                }
                .settingsLandingAnchor(queue.isDefault ? "tasks.queue.settings" : nil)
            }
        } content: {
            if running.isEmpty && waiting.isEmpty && finished.isEmpty {
                SettingsEmptyState(inline: "tray", title: "Nothing has run on this queue yet.")
            }
            ForEach(running) { task in
                TaskRow(task: task) { detail = TaskDetailRequest(id: task.id) }
            }
            ForEach(waiting) { task in
                TaskRow(task: task) { detail = TaskDetailRequest(id: task.id) }
            }
            if expanded {
                RecentTasksList(query: TaskQuery(queueId: queue.id, states: TaskState.finishedStates, limit: 25))
            } else {
                ForEach(finished.prefix(Self.finishedTail)) { task in
                    TaskRow(task: task) { detail = TaskDetailRequest(id: task.id) }
                }
            }
            if finished.count > Self.finishedTail || expanded {
                SettingsButton(.tertiary, expanded ? "Show Less" : "See All Finished", size: .compact) {
                    withAnimation(theme.motion.quick) {
                        if expanded { expandedQueues.remove(queue.id) } else { expandedQueues.insert(queue.id) }
                    }
                }
            }
        }
    }

    private func laneSubtitle(_ queue: TaskQueue, running: Int, waiting: Int) -> String {
        var parts = [L("\(running) running"), L("\(waiting) waiting")]
        parts.append(L("up to \(queue.policy.maxConcurrent) at once"))
        return parts.joined(separator: " · ")
    }

    /// Settings search lands on a page or, for a queue control, opens the
    /// Default queue's settings where the control lives.
    private func routeSettingsLanding(_ pending: String?) {
        guard let pending, pending.hasPrefix("tasks.") else { return }
        switch pending {
        case "tasks.history": page = .history
        case "tasks.needsYou": managementState.selectedTab = .approvals
        case "tasks.queue.maxConcurrent", "tasks.queue.maxWaiting", "tasks.queue.overflow", "tasks.queue.ordering",
            "tasks.queue.paused":
            page = .queues
            if queueEditor == nil { queueEditor = QueueEditorRequest(queue: store.defaultQueue) }
        default: page = .queues
        }
    }

    private func consumePendingHistory() {
        guard let filter = managementState.pendingTaskHistory else { return }
        historyFilter = filter
        page = .history
        managementState.pendingTaskHistory = nil
    }

    private func consumePendingDetail() {
        guard let id = managementState.pendingTaskDetailId else { return }
        detail = TaskDetailRequest(id: id)
        managementState.pendingTaskDetailId = nil
    }
}

private enum TasksPage: String, CaseIterable, AnimatedTabItem {
    case queues, history

    var title: String {
        switch self {
        case .queues: L("Queues")
        case .history: L("History")
        }
    }
}

private struct TaskDetailRequest: Identifiable {
    let id: UUID
}

private struct QueueEditorRequest: Identifiable {
    let id = UUID()
    let queue: TaskQueue?
}
