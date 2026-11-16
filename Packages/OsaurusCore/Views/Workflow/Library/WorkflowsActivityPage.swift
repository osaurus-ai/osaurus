//
//  WorkflowsActivityPage.swift
//  osaurus
//
//  Activity: everything workflows did, newest first, by day. All or what
//  needs attention up front; what ran on its own, what you ran, and one
//  workflow in ⋯. A failure the workflow has not finished a run since opens
//  with what happened, its steps, and what to do: the fix, Run again, Ask
//  Osaurus to fix it, and Technical details (the run page).
//

import AppKit
import SwiftUI

struct WorkflowsActivityPage: View {
    @Environment(\.theme) private var theme
    let windowState: ChatWindowState
    @ObservedObject var overview: WorkflowsOverviewModel
    @ObservedObject private var installed = InstalledWorkflowStore.shared
    /// Redraws when a run starts, moves a step or ends, never per streamed word.
    @ObservedObject private var live = WorkflowLiveRuns.shared
    @ObservedObject private var agents = AgentManager.shared
    private var runs: WorkflowRunStore { .shared }

    let onRun: (InstalledWorkflow) -> Void
    let onSetUp: (InstalledWorkflow) -> Void

    @State private var filter: WorkflowActivityFilter?
    @State private var workflowFilter: UUID?
    @State private var pages = 1
    @State private var expanded: Set<String> = []
    @State private var collapsed: Set<String> = []
    @State private var focusItemID: String?
    /// Bumps once the recorded runs load.
    @State private var recordedCount = -1

    var body: some View {
        let _ = recordedCount
        let all = items
        let unresolved = WorkflowActivityFeed.unresolved(all)
        let shown = WorkflowActivityFeed.filter(all, by: filter, workflowID: workflowFilter, unresolved: unresolved)
        let page = WorkflowActivityFeed.page(shown, pages: pages)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s20) {
                    header
                    filters(all: all, unresolved: unresolved)
                    if page.isEmpty {
                        empty
                    } else {
                        ForEach(WorkflowActivityFeed.days(page)) { day in
                            dayGroup(day, unresolved: unresolved)
                        }
                        if shown.count > page.count {
                            SettingsButton(.secondary, "Show More", size: .small) { pages += 1 }
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(maxWidth: WorkflowLibraryLayout.columnWidth, alignment: .leading)
                .padding(.horizontal, theme.space.s24)
                .padding(.top, WorkflowLibraryLayout.pageTopInset(theme))
                .padding(.bottom, theme.space.s64)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .onChange(of: focusItemID) { _, id in
                guard let id else { return }
                DispatchQueue.main.async {
                    withAnimation(theme.motion.standard) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .onAppear { apply(windowState.takeWorkflowsActivityRequest()) }
        .onReceive(NotificationCenter.default.publisher(for: .workflowsActivityRequest)) { _ in
            apply(windowState.takeWorkflowsActivityRequest())
        }
        .onChange(of: filter) { _, _ in pages = 1 }
        .onChange(of: workflowFilter) { _, _ in pages = 1 }
        .task { await runs.loadRecentRunsIfNeeded() }
        .onReceive(WorkflowRunStore.shared.$recentPersisted.map { $0?.count ?? -1 }.removeDuplicates()) {
            recordedCount = $0
        }
        .background(theme.surface.canvas)
        .settingsLandingAnchor("workflows.activity")
    }

    private var items: [WorkflowActivityItem] {
        let names = Dictionary(installed.workflows.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let eventWorkflows = Dictionary(
            overview.workflowEvents.compactMap { event in event.action.workflow.map { (event.id, $0.workflowID) } },
            uniquingKeysWith: { first, _ in first })
        return WorkflowActivityFeed.items(
            runs: runs.recentRuns().filter { names[$0.workflowID] != nil },
            eventRuns: overview.recentRuns.values.flatMap { $0 },
            eventWorkflows: eventWorkflows, names: names)
    }

    private func apply(_ request: WorkflowActivityRequest?) {
        guard let request else { return }
        filter = request.filter
        workflowFilter = request.workflowID
        pages = 1
        if let id = request.focusItemID {
            expanded.insert(id)
            collapsed.remove(id)
            focusItemID = nil
            focusItemID = id
        }
    }

    // MARK: Header and filters

    private var header: some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            Text("Activity", bundle: .module)
                .textStyle(.title)
                .foregroundStyle(theme.text.primary)
                .accessibilityAddTraits(.isHeader)
            Text("Everything your workflows did, newest first.", bundle: .module)
                .font(SettingsFont.rowDescription)
                .foregroundStyle(theme.text.secondary)
        }
    }

    /// All and Needs attention; the rarer cuts in ⋯, shown as a chip
    /// while chosen.
    private func filters(all: [WorkflowActivityItem], unresolved: Set<String>) -> some View {
        let chips: [WorkflowActivityFilter] = [.needsAttention] + (filter.map { $0 == .needsAttention ? [] : [$0] } ?? [])
        return VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s12) {
                FilterChipRow(
                    chips, selection: $filter, title: \.title,
                    icon: { $0 == .needsAttention && !unresolved.isEmpty ? "circle.fill" : nil },
                    count: { $0 == .needsAttention && !unresolved.isEmpty ? unresolved.count : nil },
                    tint: { $0 == .needsAttention ? theme.statusInk(.error) : nil })
                Spacer(minLength: theme.space.s8)
                moreFilters(all)
            }
            if let workflowFilter {
                HStack(spacing: theme.space.s6) {
                    Text(verbatim: L("Showing only \(workflowName(workflowFilter, in: all))."))
                        .font(SettingsFont.footnote)
                        .foregroundStyle(theme.text.secondary)
                    WorkflowTextLink(title: L("Show all")) { self.workflowFilter = nil }
                }
            }
        }
    }

    private func workflowName(_ id: UUID, in all: [WorkflowActivityItem]) -> String {
        all.first { $0.workflowID == id }?.workflowName ?? installed.workflow(id: id)?.name ?? L("Workflow")
    }

    private func moreFilters(_ all: [WorkflowActivityItem]) -> some View {
        let choices = Dictionary(all.compactMap { item in item.workflowID.map { ($0, item.workflowName) } }, uniquingKeysWith: { first, _ in first })
            .sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
        return SettingsActionMenu(accessibilityLabel: L("More filters")) {
            Button(WorkflowActivityFilter.ranOnTheirOwn.title) { filter = .ranOnTheirOwn }
            Button(WorkflowActivityFilter.runByMe.title) { filter = .runByMe }
            if !choices.isEmpty {
                Divider()
                Menu(L("One Workflow")) {
                    ForEach(choices, id: \.key) { choice in
                        Button(choice.value) { workflowFilter = choice.key }
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
        .buttonStyle(SettingsIconButtonStyle(size: .standard, role: .tertiary))
        .fixedSize()
        .help(L("More filters"))
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            Text(verbatim: filter == .needsAttention ? L("Nothing needs your attention.") : L("Nothing here yet."))
                .font(SettingsFont.compactLabel)
                .foregroundStyle(theme.text.primary)
            Text("Runs show up here as your workflows run, whoever starts them.", bundle: .module)
                .font(SettingsFont.footnote)
                .foregroundStyle(theme.text.secondary)
        }
        .padding(theme.space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.card)
    }

    // MARK: Days and rows

    private func dayGroup(_ day: WorkflowActivityDay, unresolved: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            Text(verbatim: day.title.uppercased(with: .current))
                .textStyle(.caption, weight: 600)
                .foregroundStyle(theme.text.tertiary)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: theme.space.s8) {
                ForEach(groups(day.items, unresolved: unresolved), id: \.first!.id) { group in
                    if group.count == 1, let item = group.first, isExpanded(item, unresolved: unresolved) {
                        WorkflowActivityExpandedRow(
                            item: item, line: line(item),
                            workflow: item.workflowID.flatMap(installed.workflow(id:)),
                            onCollapse: { toggle(item, unresolved: unresolved) },
                            onOpen: { open(item) },
                            onRemedy: { perform($0, for: item) },
                            onRunAgain: { runAgain(item) },
                            onAskToFix: { askToFix(item) })
                        .id(item.id)
                    } else {
                        VStack(spacing: theme.space.s0) {
                            ForEach(Array(group.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { ThemeHairlineDivider(color: theme.border.subtle) }
                                WorkflowRunRow(
                                    status: item.run?.status ?? .failed, title: item.workflowName, line: line(item),
                                    lineIsProblem: item.isFailed, time: .clock(item.date), expands: item.isFailed,
                                    onOpen: { item.isFailed ? toggle(item, unresolved: unresolved) : open(item) }
                                )
                                .id(item.id)
                            }
                        }
                        .settingsChrome(.card)
                    }
                }
            }
        }
    }

    /// Runs of a day in cards, each expanded failure in a card of its own.
    private func groups(_ items: [WorkflowActivityItem], unresolved: Set<String>) -> [[WorkflowActivityItem]] {
        var groups: [[WorkflowActivityItem]] = []
        for item in items {
            if isExpanded(item, unresolved: unresolved) {
                groups.append([item])
            } else if let last = groups.last, let lastItem = last.last, !isExpanded(lastItem, unresolved: unresolved) {
                groups[groups.count - 1].append(item)
            } else {
                groups.append([item])
            }
        }
        return groups
    }

    private func isExpanded(_ item: WorkflowActivityItem, unresolved: Set<String>) -> Bool {
        guard item.isFailed else { return false }
        if expanded.contains(item.id) { return true }
        return unresolved.contains(item.id) && !collapsed.contains(item.id)
    }

    private func toggle(_ item: WorkflowActivityItem, unresolved: Set<String>) {
        withAnimation(theme.motion.quick) {
            if isExpanded(item, unresolved: unresolved) {
                expanded.remove(item.id)
                collapsed.insert(item.id)
            } else {
                expanded.insert(item.id)
                collapsed.remove(item.id)
            }
        }
    }

    private func line(_ item: WorkflowActivityItem) -> String {
        let event = item.eventID.flatMap { EventManager.shared.event(for: $0) }
        return WorkflowActivityFeed.line(item, event: event) { agents.agent(for: $0)?.displayName }
    }

    // MARK: Actions

    private func open(_ item: WorkflowActivityItem) {
        if let run = item.run {
            windowState.showWorkflowRun(workflowID: run.workflowID, runID: run.id, agentId: windowState.agentId)
        } else if let id = item.workflowID, installed.workflow(id: id) != nil {
            windowState.selectWorkflowsPage(.workflow(id))
        }
    }

    private func perform(_ remedy: WorkflowActivityRemedy, for item: WorkflowActivityItem) {
        switch remedy {
        case .fix(let fix): fix.perform(over: NSApp.keyWindow)
        case .signInAgain:
            if let workflow = item.workflowID.flatMap(installed.workflow(id:)) { onSetUp(workflow) }
        }
    }

    private func runAgain(_ item: WorkflowActivityItem) {
        if let run = item.run, WorkflowRunService.reasonNotToRetry(run) == nil,
            let newID = WorkflowRunService.shared.retry(runID: run.id)
        {
            windowState.showWorkflowRun(workflowID: run.workflowID, runID: newID, agentId: windowState.agentId)
        } else if let workflow = item.workflowID.flatMap(installed.workflow(id:)) {
            onRun(workflow)
        }
    }

    private func askToFix(_ item: WorkflowActivityItem) {
        guard let run = item.run, let workflow = installed.workflow(id: run.workflowID) else { return }
        ArchitectLauncher.repair(run, of: workflow, in: windowState)
    }
}

// MARK: - Rows

private struct WorkflowActivityExpandedRow: View {
    @Environment(\.theme) private var theme
    let item: WorkflowActivityItem
    let line: String
    let workflow: InstalledWorkflow?
    let onCollapse: () -> Void
    let onOpen: () -> Void
    let onRemedy: (WorkflowActivityRemedy) -> Void
    let onRunAgain: () -> Void
    let onAskToFix: () -> Void

    private var explanation: WorkflowFailureExplanation {
        switch item.source {
        case .run(let run): return WorkflowFailureSentence.explain(run, definition: workflow?.definition)
        case .refused(let fire): return WorkflowFailureSentence.explain(refused: fire, workflowName: item.workflowName)
        }
    }

    var body: some View {
        let explanation = explanation
        VStack(alignment: .leading, spacing: theme.space.s12) {
            HStack(alignment: .center, spacing: theme.space.s12) {
                WorkflowRunStatusIcon(status: item.run?.status ?? .failed, size: 12)
                    .frame(width: theme.space.s16, height: theme.space.s16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(verbatim: item.workflowName)
                        .textStyle(.body, weight: 500)
                        .foregroundStyle(theme.text.primary)
                        .lineLimit(1)
                    Text(verbatim: line)
                        .font(SettingsFont.footnote)
                        .foregroundStyle(theme.statusInk(.error))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: AutomationSentence.Style.current.time(item.date))
                    .font(SettingsFont.footnote)
                    .monospacedDigit()
                    .foregroundStyle(theme.text.tertiary)
                Image(systemName: "chevron.up")
                    .glyphSize(.tiny, weight: .semibold)
                    .foregroundStyle(theme.text.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onCollapse)
            .pointingHandCursor()
            .help(L("Hide what happened"))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text("Hide what happened", bundle: .module), onCollapse)
            VStack(alignment: .leading, spacing: theme.space.s10) {
                Text("What happened", bundle: .module)
                    .textStyle(.caption, weight: 600)
                    .foregroundStyle(theme.text.tertiary)
                Text(verbatim: explanation.sentence)
                    .font(SettingsFont.compactLabel)
                    .foregroundStyle(theme.text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let run = item.run, !run.nodes.isEmpty {
                    steps(run, explanation: explanation)
                }
                actions(explanation)
            }
            .padding(.leading, theme.space.s16 + theme.space.s12)
        }
        .padding(.horizontal, theme.space.s16)
        .padding(.vertical, theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.status(.error))
    }

    private func steps(_ run: WorkflowRun, explanation: WorkflowFailureExplanation) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            ForEach(run.nodes) { node in
                let name = workflow?.definition.node(node.nodeID)?.name ?? node.nodeID
                HStack(spacing: theme.space.s8) {
                    Group {
                        switch node.status {
                        case .done, .pinned:
                            Image(systemName: "checkmark").foregroundStyle(theme.statusInk(.success))
                        case .failed:
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(theme.statusInk(.error))
                        default:
                            Image(systemName: "circle").foregroundStyle(theme.text.tertiary)
                        }
                    }
                    .glyphSize(.tiny, weight: .semibold)
                    .frame(width: theme.space.s12)
                    .accessibilityHidden(true)
                    Text(verbatim: stepLine(node, name: name, explanation: explanation))
                        .font(SettingsFont.footnote)
                        .foregroundStyle(node.status == .failed ? theme.text.primary : theme.text.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func stepLine(_ node: NodeRun, name: String, explanation: WorkflowFailureExplanation) -> String {
        switch node.status {
        case .done, .pinned: return name
        case .failed:
            let reason = node.failure.flatMap { WorkflowFailureSentence.shortReason($0.kind) } ?? explanation.shortReason
            return reason.map { L("\(name): \($0)") } ?? L("\(name): did not finish")
        default: return L("\(name): skipped")
        }
    }

    private func actions(_ explanation: WorkflowFailureExplanation) -> some View {
        HStack(spacing: theme.space.s8) {
            if let remedy = explanation.remedy {
                SettingsButton(.primary, remedy.title, size: .small, verbatim: true) { onRemedy(remedy) }
            }
            if workflow != nil {
                SettingsButton(.secondary, "Run Again", size: .small, action: onRunAgain)
            }
            if item.run != nil, workflow != nil {
                SettingsButton(.secondary, "Ask Osaurus to Fix It", size: .small, action: onAskToFix)
            }
            if item.run != nil {
                WorkflowTextLink(title: L("Technical details"), action: onOpen)
            }
        }
    }
}
