//
//  WorkflowRunHistoryList.swift
//  osaurus
//
//  The Runs tab of the chat inspector's History lens: workflow runs of the
//  agent on screen, newest first and grouped by day, with search and a
//  status / workflow filter. The Architect sees every workflow's runs; any
//  other agent sees the runs it started and the runs of its workflows.
//  Architect test runs stay in the Draft lens. A row opens the run in a
//  workflow tab of this window; its menu opens the chat that started it,
//  runs it again with the same input, or hands a failure to the Architect.
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

/// The Runs tab's search, filters, and scroll spot, for one agent.
struct WorkflowRunHistoryViewState: Equatable {
    var agentId: UUID?
    var query = ""
    var status: WorkflowRunHistoryModel.StatusFilter = .all
    var workflowID: UUID?
    /// The `Item` id at the top of the list.
    var scrolledItemID: String?
}

struct WorkflowRunHistoryList: View {
    @ObservedObject var windowState: ChatWindowState
    /// The agent's runs, already scoped (`WorkflowRunHistoryModel.scope`).
    let runs: [WorkflowRun]
    /// False until the persisted runs have loaded.
    let isLoaded: Bool
    /// Opens the chat a run was started from.
    let onSelectSession: (ChatSessionData) -> Void

    @Environment(\.theme) private var theme
    @ObservedObject private var installed = InstalledWorkflowStore.shared
    @ObservedObject private var agents = AgentManager.shared

    @State private var state: WorkflowRunHistoryViewState
    @FocusState private var isSearchFocused: Bool
    @State private var isFilterButtonHovered = false

    private typealias Model = WorkflowRunHistoryModel

    init(
        windowState: ChatWindowState, runs: [WorkflowRun], isLoaded: Bool,
        onSelectSession: @escaping (ChatSessionData) -> Void
    ) {
        self.windowState = windowState
        self.runs = runs
        self.isLoaded = isLoaded
        self.onSelectSession = onSelectSession
        let saved = windowState.runHistoryViewState
        _state = State(
            initialValue: saved.agentId == windowState.agentId
                ? saved : WorkflowRunHistoryViewState(agentId: windowState.agentId))
    }

    private var query: String { state.query }
    private var statusFilter: Model.StatusFilter { state.status }
    private var workflowFilter: UUID? { state.workflowID }

    private var hasActiveFilter: Bool { statusFilter != .all || workflowFilter != nil }

    private var activeFilterCount: Int { (statusFilter != .all ? 1 : 0) + (workflowFilter != nil ? 1 : 0) }

    private func definition(_ run: WorkflowRun) -> WorkflowDefinition? {
        installed.workflow(id: run.workflowID)?.definition
    }

    private func startedBy(_ run: WorkflowRun) -> String {
        Model.startedBy(run) { agents.agent(for: $0)?.displayName }
    }

    private var filteredRuns: [WorkflowRun] {
        Model.filter(runs, status: statusFilter, workflowID: workflowFilter, query: query) { run in
            [run.workflowName, startedBy(run), Model.outcome(run, definition: definition(run))]
                .joined(separator: " ")
        }
    }

    var body: some View {
        let filtered = filteredRuns
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                SidebarSearchField(text: $state.query, placeholder: "Search runs...", isFocused: $isSearchFocused)
                filterMenu
            }

            if runs.isEmpty {
                if isLoaded {
                    SidebarEmptyState(icon: "clock.arrow.circlepath", title: "No workflow runs yet", hint: emptyHint)
                } else {
                    ProgressView().controlSize(.small).frame(maxHeight: .infinity)
                }
            } else if filtered.isEmpty, hasActiveFilter, query.trimmingCharacters(in: .whitespaces).isEmpty {
                VStack(spacing: 8) {
                    SidebarEmptyState(icon: "line.3.horizontal.decrease.circle", title: "No runs match this filter")
                    Button {
                        withAnimation(theme.motion.quick) { clearFilters() }
                    } label: {
                        Text("Clear Filters", bundle: .module)
                            .font(SettingsFont.smallLabel)
                            .foregroundColor(theme.text.link)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .padding(.bottom, theme.space.s16)
                }
            } else if filtered.isEmpty {
                SidebarNoResultsView(searchQuery: query) {
                    withAnimation(theme.motion.quick) { state.query = "" }
                }
            } else {
                list(Model.items(Model.sections(filtered)))
            }
        }
        .onChange(of: state) { _, new in windowState.runHistoryViewState = new }
        .onChange(of: windowState.agentId) { _, agentId in
            state = WorkflowRunHistoryViewState(agentId: agentId)
        }
    }

    private var emptyHint: LocalizedStringKey {
        windowState.agentId == Agent.architectId
            ? "Runs of your saved workflows appear here. Test runs stay in the Draft."
            : "Runs this agent starts, and runs of its workflows, appear here."
    }

    private func clearFilters() {
        state.status = .all
        state.workflowID = nil
    }

    // MARK: - List

    /// One flat run of headers and rows, so the scroll spot can be kept by
    /// item id across the inspector being rebuilt.
    private func list(_ items: [Model.Item]) -> some View {
        let openRunID: UUID? = {
            guard windowState.mainSurface == .workflows, windowState.showsWorkflowLibrary,
                case .run(_, let runID, _)? = windowState.workflowsPath.last
            else { return nil }
            return runID
        }()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    switch item {
                    case .header(let day):
                        sectionHeader(day.title)
                    case .run(let run):
                        WorkflowRunHistoryRow(
                            run: run,
                            outcome: Model.outcome(run, definition: definition(run)),
                            startedBy: startedBy(run),
                            time: Model.timeLabel(run),
                            isSelected: run.id == openRunID,
                            action: { open(run) },
                            menu: { rowMenu(run) }
                        )
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.bottom, theme.space.s4)
            .animation(theme.motion.springAnimation(responseMultiplier: 0.9), value: items.map(\.id))
        }
        .scrollPosition(id: $state.scrolledItemID, anchor: .top)
        .scrollIndicators(.hidden)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(SettingsFont.compactLabel)
            .foregroundColor(theme.text.secondary)
            .lineLimit(1)
            .padding(.horizontal, theme.space.s8)
            .padding(.top, theme.space.s8)
            .padding(.bottom, theme.space.s4)
    }

    // MARK: - Actions

    private func open(_ run: WorkflowRun) {
        windowState.openWorkflowTab(workflowID: run.workflowID, runID: run.id, agentId: windowState.agentId)
    }

    private func originChat(_ run: WorkflowRun) -> ChatSessionData? {
        run.caller.sessionID.flatMap(UUID.init(uuidString:)).flatMap { ChatSessionsManager.shared.session(for: $0) }
    }

    @ViewBuilder
    private func rowMenu(_ run: WorkflowRun) -> some View {
        Button {
            open(run)
        } label: {
            Text("Open Run", bundle: .module)
        }
        if let chat = originChat(run) {
            Button {
                onSelectSession(chat)
            } label: {
                Text("Open Chat That Started It", bundle: .module)
            }
        }
        if let input = run.input.objectValue {
            Button {
                WorkflowRunLauncher.stagePrefill(input, for: run.workflowID)
                windowState.openWorkflowTab(workflowID: run.workflowID, agentId: windowState.agentId)
            } label: {
                Text("Run Again with This Input", bundle: .module)
            }
        }
        if run.status == .failed, let workflow = installed.workflow(id: run.workflowID) {
            Divider()
            if WorkflowRunService.reasonNotToRetry(run) == nil {
                Button {
                    guard let newID = WorkflowRunService.shared.retry(runID: run.id) else { return }
                    windowState.openWorkflowTab(workflowID: run.workflowID, runID: newID, agentId: windowState.agentId)
                } label: {
                    Text("Retry from Failed Step", bundle: .module)
                }
            }
            Button {
                ArchitectLauncher.repair(run, of: workflow, in: windowState)
            } label: {
                Text("Fix with the Architect", bundle: .module)
            }
        }
    }

    // MARK: - Filter

    private var filterMenu: some View {
        let isActive = activeFilterCount > 0
        let isRaised = isActive || isFilterButtonHovered
        let choices = Model.workflowChoices(runs)
        return SettingsActionMenu(accessibilityLabel: L("Filter runs")) {
            Section {
                ForEach(Model.StatusFilter.allCases, id: \.self) { filter in
                    Toggle(
                        isOn: Binding(
                            get: { statusFilter == filter },
                            set: { if $0 { state.status = filter } }
                        )
                    ) {
                        Text(verbatim: filter.title)
                    }
                    .settingsCheckbox()
                }
            } header: {
                Text("Status", bundle: .module)
            }
            if choices.count > 1 || workflowFilter != nil {
                Section {
                    ForEach(choices) { choice in
                        Toggle(
                            isOn: Binding(
                                get: { workflowFilter == choice.id },
                                set: { state.workflowID = $0 ? choice.id : nil }
                            )
                        ) {
                            Text(verbatim: "\(choice.name) (\(choice.count))")
                        }
                        .settingsCheckbox()
                    }
                } header: {
                    Text("Workflow", bundle: .module)
                }
            }
            if isActive {
                Divider()
                Button {
                    clearFilters()
                } label: {
                    Text("Clear Filters", bundle: .module)
                }
            }
        } label: {
            HStack(alignment: .center, spacing: 4) {
                Image(
                    systemName: isActive
                        ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                )
                .textStyle(.caption, weight: 500)
                if isActive {
                    Text(verbatim: "\(activeFilterCount)")
                        .font(SettingsFont.smallLabel)
                        .monospacedDigit()
                }
            }
            .foregroundColor(isActive ? theme.text.link : (isRaised ? theme.text.primary : theme.text.secondary))
            .padding(.horizontal, theme.space.s8)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .fill(
                        isActive
                            ? theme.surface.selected
                            : (theme.isDark
                                ? theme.surface.canvas : theme.surface.hover)
                    )
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointingHandCursor()
        .onHover { isFilterButtonHovered = $0 }
        .localizedHelp("Filter runs by status or workflow")
        .accessibilityLabel(
            activeFilterCount == 0
                ? Text("Filter", bundle: .module) : Text("Filter (\(activeFilterCount))", bundle: .module)
        )
    }
}

/// One run: its status, workflow, outcome, who started it, and when.
private struct WorkflowRunHistoryRow<RowMenu: View>: View {
    let run: WorkflowRun
    let outcome: String
    let startedBy: String
    let time: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let menu: () -> RowMenu

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        let tint = WorkflowRunStyle.color(run.status, theme: theme)
        HStack(spacing: 6) {
            Button(action: action) {
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(tint.opacity(theme.isDark ? 0.16 : 0.12))
                            .frame(width: 26, height: 26)
                        WorkflowRunStatusIcon(status: run.status, size: 11)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: run.workflowName)
                                .font(SettingsFont.compactLabel)
                                .foregroundColor(theme.text.primary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(verbatim: time)
                                .font(SettingsFont.footnote)
                                .foregroundColor(theme.text.tertiary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        Text(verbatim: outcome)
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(
                                run.status == .failed ? theme.statusInk.error : theme.text.secondary
                            )
                            .lineLimit(2)
                            .help(run.error?.reason ?? outcome)
                        Text(verbatim: L("by \(startedBy)"))
                            .font(SettingsFont.footnote)
                            .foregroundColor(theme.text.tertiary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            SettingsActionMenu(accessibilityLabel: L("More"), content: menu) {
                Image(systemName: "ellipsis")
                    .glyphSize(11, weight: .semibold)
                    .foregroundColor(theme.text.secondary)
                    .frame(width: SidebarStyle.actionButtonSize, height: SidebarStyle.actionButtonSize)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovered ? 1 : 0)
            .localizedHelp("More")
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s8)
        .sidebarRowChrome(isSelected: isSelected, isHovered: isHovered)
        .assignedContextMenu(menuItems: menu)
        .onHover { hovering in
            withAnimation(theme.motion.springAnimation(responseMultiplier: 0.8)) { isHovered = hovering }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(run.workflowName), \(outcome), \(time)"))
    }
}
