//
//  WorkflowsSidebar.swift
//  osaurus
//
//  The Workflows destination's sidebar, in the column the chat sidebar
//  uses: search, Home, then Pinned, All Workflows (with New Workflow's +),
//  Drafts and Workspaces, each folding like the chat sidebar's groups,
//  with the Osaurus Store at the foot. Each workflow row
//  says how it runs in a few words and has Automate and Run beside it.
//  What it lists comes from `WorkflowsSidebarModel`.
//

import AppKit
import SwiftUI

/// Ids the sidebar can be asked to scroll to.
enum WorkflowsSidebarSection {
    static let drafts = "drafts"
}

struct WorkflowsSidebar: View {
    @Environment(\.theme) private var theme
    @ObservedObject var windowState: ChatWindowState
    @ObservedObject var overview: WorkflowsOverviewModel
    @ObservedObject private var installed = InstalledWorkflowStore.shared
    @ObservedObject private var hostedLinks = HostedWorkflowLinkStore.shared
    @ObservedObject private var registryRecords = WorkflowRegistryRecordStore.shared
    @ObservedObject private var drafts = WorkflowDraftStore.shared
    @ObservedObject private var workspaces = WorkspacesService.shared

    let width: CGFloat
    let selection: ChatWindowState.WorkflowsSidebarSelection
    /// Wraps an installed workflow's row with its context menu.
    let workflowMenu: (InstalledWorkflow, AnyView) -> AnyView
    let onRun: (WorkflowsSidebarModel.Row) -> Void
    let onDeleteDraft: (WorkflowDraft) -> Void

    static let storeURL = URL(string: "https://store.osaurus.ai/")!

    @State private var searchText = ""
    @State private var query = ""
    @AppStorage("workflowsSidebar.pinnedCollapsed") private var pinnedCollapsed = false
    @AppStorage("workflowsSidebar.allCollapsed") private var allCollapsed = false
    @AppStorage("workflowsSidebar.draftsCollapsed") private var draftsCollapsed = false
    @AppStorage("workflowsSidebar.workspacesCollapsed") private var workspacesCollapsed = false
    @AppStorage("workflowsSidebar.sort") private var sortStorage = WorkflowsSidebarSort.name.rawValue
    /// My Order, as row sort keys joined by commas.
    @AppStorage("workflowsSidebar.manualOrder") private var manualOrderStorage = ""

    /// All Workflows while a row is dragged; nil otherwise.
    @State private var dragOrder: [WorkflowsSidebarModel.Row]?
    @State private var draggingKey: String?
    @State private var dragOffset: CGFloat = 0
    /// How far live swaps have already moved the dragged row this drag.
    @State private var dragSwapped: CGFloat = 0
    @State private var rowHeights: [String: CGFloat] = [:]

    private var sort: WorkflowsSidebarSort { WorkflowsSidebarSort(rawValue: sortStorage) ?? .name }
    private var manualOrder: [String] { manualOrderStorage.split(separator: ",").map(String.init) }

    private var model: WorkflowsSidebarModel {
        WorkflowsSidebarModel.make(
            workflows: installed.workflows,
            hostedLinks: hostedLinks.links,
            automations: overview.automationFacts,
            publishedTemplateIDs: Set(installed.workflows.map(\.templateID).filter { registryRecords.record(for: $0) != nil }),
            drafts: drafts.libraryDrafts,
            workspaces: workspaces.workspaces.map { .init(id: $0.id, name: $0.name) },
            query: query,
            sort: sort,
            lastRunAt: overview.lastRunAt,
            manualOrder: manualOrder)
    }

    var body: some View {
        let model = model
        SidebarContainer(
            attachedEdge: .leading, topPadding: theme.space.s16, width: width, roundBottomCorners: false,
            showsBorder: false
        ) {
            searchRow
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: theme.space.s2) {
                        destinationRow(L("Home"), icon: "house", isSelected: selection == .home) {
                            windowState.selectWorkflowsPage(nil)
                        }
                        activityRow
                        list(model)
                    }
                    .padding(.horizontal, theme.space.s16)
                    .padding(.bottom, theme.space.s16)
                }
                .sidebarScrollEdgeFade()
                .onAppear { scrollToTarget(proxy) }
                .onChange(of: windowState.workflowsSidebarScrollTarget) { _, _ in scrollToTarget(proxy) }
            }
            footer
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Workflows", bundle: .module))
    }

    // MARK: Search

    private var searchRow: some View {
        SearchField(text: $searchText, placeholder: "Search workflows", fillsAvailableWidth: true)
            .task(id: searchText) {
                let text = searchText
                if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    try? await Task.sleep(for: SearchDebounce.interval)
                    guard !Task.isCancelled else { return }
                }
                if query != text { query = text }
            }
            .frame(minHeight: theme.space.s32)
            .padding(.horizontal, theme.space.s16)
            .padding(.bottom, theme.space.s16)
            .settingsLandingAnchor("workflows.search")
    }

    // MARK: Lists

    /// Activity, with how many workflows need attention.
    private var activityRow: some View {
        let issues = Self.issueCount(workflows: installed.workflows, automations: overview.automationFacts)
        return WorkflowsSidebarDestinationRow(
            title: L("Activity"), icon: "waveform.path.ecg", isSelected: selection == .activity,
            badge: issues > 0 ? L("\(issues) issues") : nil
        ) {
            windowState.selectWorkflowsPage(.activity)
        }
    }

    /// Workflows whose automation's latest run failed or can't start it.
    static func issueCount(
        workflows: [InstalledWorkflow], automations: [UUID: [WorkflowsSidebarModel.AutomationFacts]]
    ) -> Int {
        workflows.filter { WorkflowsSidebarModel.status($0, automations: automations[$0.id] ?? []) == .problem }.count
    }

    @ViewBuilder
    private func list(_ model: WorkflowsSidebarModel) -> some View {
        let searching = !query.isEmpty
        if !model.pinned.isEmpty {
            WorkflowsSidebarGroupHeader(
                title: L("Pinned"), isCollapsed: $pinnedCollapsed, isSearching: searching,
                help: (show: L("Show pinned workflows"), hide: L("Hide pinned workflows")),
                workflowIDs: model.pinned.compactMap(\.workflowID))
                .settingsLandingAnchor("workflows.pin")
            if !pinnedCollapsed || searching { ForEach(model.pinned) { workflowRow($0) } }
        }
        if !model.all.isEmpty || !searching {
            WorkflowsSidebarGroupHeader(
                title: L("All Workflows"), isCollapsed: $allCollapsed, isSearching: searching,
                help: (show: L("Show workflows"), hide: L("Hide workflows")),
                workflowIDs: model.all.compactMap(\.workflowID)
            ) { isHovered in
                sortMenu
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
                SettingsIconButton("plus", help: "New Workflow (⌘N)", size: .extraSmall, role: .tertiary) {
                    windowState.isWorkflowsDrawerPresented = false
                    windowState.showNewWorkflow()
                }
                .accessibilityLabel(Text("New Workflow", bundle: .module))
            }
            .settingsLandingAnchor("workflows.all")
            if !allCollapsed || searching {
                ForEach(dragOrder ?? model.all) { row in
                    reorderable(row, in: model.all, enabled: !searching)
                }
            }
        }
        if !model.drafts.isEmpty {
            WorkflowsSidebarGroupHeader(
                title: L("Drafts"), isCollapsed: $draftsCollapsed, isSearching: searching,
                help: (show: L("Show drafts"), hide: L("Hide drafts")))
                .id(WorkflowsSidebarSection.drafts)
                .settingsLandingAnchor("workflows.drafts")
            if !draftsCollapsed || searching { ForEach(model.drafts) { draftRow($0) } }
        }
        if !model.workspaces.isEmpty {
            WorkflowsSidebarGroupHeader(
                title: L("Workspaces"), isCollapsed: $workspacesCollapsed, isSearching: searching,
                help: (show: L("Show workspaces"), hide: L("Hide workspaces")))
                .settingsLandingAnchor("workflows.workspaces")
            if !workspacesCollapsed || searching {
                ForEach(model.workspaces) { workspace in
                    destinationRow(workspace.name, icon: "person.3", isSelected: selection == .workspace(workspace.id)) {
                        windowState.selectWorkflowsPage(.workspace(workspace.id))
                    }
                }
            }
        }
        if model.isEmpty, !query.isEmpty {
            SidebarNoResultsView(searchQuery: query) {
                searchText = ""
                query = ""
            }
            .padding(.top, theme.space.s24)
        }
    }

    @ViewBuilder
    private func workflowRow(_ row: WorkflowsSidebarModel.Row) -> some View {
        let label = WorkflowsSidebarWorkflowRow(
            row: row,
            isSelected: row.workflowID.map { selection == .workflow($0) } ?? false,
            onOpen: { open(row) },
            onRun: { onRun(row) },
            automatePopover: { close in
                guard let id = row.workflowID, let workflow = installed.workflow(id: id) else { return nil }
                return AnyView(
                    WorkflowAutomatePopover(
                        workflow: workflow,
                        onOpenPage: { intent in
                            close()
                            windowState.isWorkflowsDrawerPresented = false
                            windowState.showWorkflowAutomation(workflowID: id, intent: intent)
                        },
                        onSeeAllWays: {
                            close()
                            windowState.isWorkflowsDrawerPresented = false
                            windowState.selectWorkflowsPage(.workflow(id))
                        },
                        onClose: close))
            })
        switch row.kind {
        case .installed(let id):
            if let workflow = installed.workflow(id: id) {
                workflowMenu(workflow, AnyView(label))
            }
        case .hosted(let id):
            label.assignedContextMenu {
                Button { hostedLinks.setPinned(!row.isPinned, id: id) } label: {
                    Label(row.isPinned ? L("Unpin") : L("Pin"), systemImage: row.isPinned ? "pin.slash" : "pin")
                }
                Button { onRun(row) } label: { Label(L("Run…"), systemImage: "play") }
                Toggle(
                    L("Osaurus can run this for you"),
                    isOn: Binding(
                        get: { hostedLinks.link(id: id)?.orchestratorVisible ?? false },
                        set: { hostedLinks.setOrchestratorVisible($0, id: id) })
                )
                .settingsCheckbox()
                Divider()
                Button(role: .destructive) { hostedLinks.remove(id: id) } label: {
                    Label(L("Remove from My Workflows"), systemImage: "minus.circle")
                }
            }
        }
    }

    private func open(_ row: WorkflowsSidebarModel.Row) {
        switch row.kind {
        case .installed(let id): windowState.selectWorkflowsPage(.workflow(id))
        case .hosted: onRun(row)
        }
    }

    private func draftRow(_ draft: WorkflowsSidebarModel.DraftRow) -> some View {
        let resume = {
            if let stored = drafts.libraryDrafts.first(where: { $0.id == draft.id }) {
                windowState.isWorkflowsDrawerPresented = false
                ArchitectLauncher.resume(stored, in: windowState)
            }
        }
        return destinationRow(draft.name, icon: "pencil.and.outline", isSelected: false, action: resume)
            .assignedContextMenu {
                Button(action: resume) { Label(L("Continue Editing"), systemImage: "pencil.and.outline") }
                Divider()
                Button(role: .destructive) {
                    if let stored = drafts.libraryDrafts.first(where: { $0.id == draft.id }) { onDeleteDraft(stored) }
                } label: {
                    Label(L("Delete Draft…"), systemImage: "trash")
                }
            }
    }

    // MARK: Sort and reorder

    private var sortMenu: some View {
        let size = theme.assignedMetric(SettingsButtonSize.extraSmall.assignment("height"), fallback: theme.space.s24)
        return AssignedActionMenu(accessibilityLabel: L("Sort By")) {
            ForEach(WorkflowsSidebarSort.allCases, id: \.self) { option in
                Button {
                    withAnimation(theme.motion.quick) { sortStorage = option.rawValue }
                } label: {
                    if option == sort {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(verbatim: option.title)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .buttonStyle(SettingsIconButtonStyle(size: .extraSmall, role: .tertiary))
        .frame(width: size, height: size)
        .help(L("Sort By: \(sort.title)"))
    }

    /// A row of All Workflows that can be dragged into a new place, which
    /// switches the list to My Order. A search's results don't move.
    private func reorderable(
        _ row: WorkflowsSidebarModel.Row, in rows: [WorkflowsSidebarModel.Row], enabled: Bool
    ) -> some View {
        let isDragging = draggingKey == row.sortKey
        return workflowRow(row)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeights[row.sortKey] = $0 }
            .offset(y: isDragging ? dragOffset : 0)
            .zIndex(isDragging ? 1 : 0)
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { drag(row.sortKey, in: rows, translation: $0.translation.height) }
                    .onEnded { _ in endDrag() },
                including: enabled ? .all : .subviews)
    }

    private func drag(_ key: String, in rows: [WorkflowsSidebarModel.Row], translation: CGFloat) {
        if draggingKey != key {
            draggingKey = key
            dragOrder = rows
            dragOffset = 0
            dragSwapped = 0
        }
        guard var order = dragOrder, var index = order.firstIndex(where: { $0.sortKey == key }) else { return }
        func pitch(_ row: WorkflowsSidebarModel.Row) -> CGFloat { (rowHeights[row.sortKey] ?? theme.space.s40) + theme.space.s2 }
        var offset = translation - dragSwapped
        while index < order.count - 1, offset > pitch(order[index + 1]) / 2 {
            let step = pitch(order[index + 1])
            order.swapAt(index, index + 1)
            index += 1
            dragSwapped += step
            offset -= step
        }
        while index > 0, offset < -pitch(order[index - 1]) / 2 {
            let step = pitch(order[index - 1])
            order.swapAt(index, index - 1)
            index -= 1
            dragSwapped -= step
            offset += step
        }
        if index == 0 { offset = max(offset, 0) }
        if index == order.count - 1 { offset = min(offset, 0) }
        dragOrder = order
        dragOffset = offset
    }

    private func endDrag() {
        if let order = dragOrder {
            manualOrderStorage = order.map(\.sortKey).joined(separator: ",")
            sortStorage = WorkflowsSidebarSort.manual.rawValue
        }
        withAnimation(theme.motion.springAnimation(responseMultiplier: 0.8)) { dragOffset = 0 }
        draggingKey = nil
        dragOrder = nil
    }

    private func destinationRow(
        _ title: String, icon: String, isSelected: Bool, action: @escaping () -> Void
    ) -> some View {
        WorkflowsSidebarDestinationRow(title: title, icon: icon, isSelected: isSelected, action: action)
    }

    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let target = windowState.workflowsSidebarScrollTarget else { return }
        windowState.workflowsSidebarScrollTarget = nil
        if target == WorkflowsSidebarSection.drafts { draftsCollapsed = false }
        withAnimation(theme.motion.quick) { proxy.scrollTo(target, anchor: .top) }
    }

    // MARK: Footer

    private var footer: some View {
        WorkflowsSidebarStoreRow { NSWorkspace.shared.open(Self.storeURL) }
            .settingsLandingAnchor("workflows.store")
            .padding(.horizontal, theme.space.s16)
            .padding(.top, theme.space.s8)
            .padding(.bottom, theme.space.s16)
    }
}

// MARK: - Rows

/// A section header in the chat sidebar's anatomy: the title folds the
/// section, and a folded section still shows when one of its workflows is
/// running or waiting on you. A search keeps every section open.
private struct WorkflowsSidebarGroupHeader<Trailing: View>: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var live = WorkflowLiveRuns.shared
    let title: String
    @Binding var isCollapsed: Bool
    let isSearching: Bool
    let help: (show: String, hide: String)
    let workflowIDs: [UUID]
    let trailing: (Bool) -> Trailing

    init(
        title: String, isCollapsed: Binding<Bool>, isSearching: Bool, help: (show: String, hide: String),
        workflowIDs: [UUID] = [], @ViewBuilder trailing: @escaping (Bool) -> Trailing = { _ in EmptyView() }
    ) {
        self.title = title
        _isCollapsed = isCollapsed
        self.isSearching = isSearching
        self.help = help
        self.workflowIDs = workflowIDs
        self.trailing = trailing
    }

    var body: some View {
        let collapsed = isCollapsed && !isSearching
        NavigatorGroupHeader(
            title: title,
            isCollapsed: collapsed,
            isToggleEnabled: !isSearching,
            help: collapsed ? help.show : help.hide,
            activityStatus: collapsed ? activity : nil,
            onToggle: { withAnimation(theme.motion.quick) { isCollapsed.toggle() } },
            trailing: trailing
        )
        .padding(.top, theme.space.s14)
    }

    private var activity: SessionActivityMonitor.Status? {
        guard !workflowIDs.isEmpty else { return nil }
        let ids = Set(workflowIDs)
        return SessionActivityMonitor.rollUp(
            live.going.filter { ids.contains($0.workflowID) }.map { $0.isWaitingOnYou ? .waitingForInput : .working })
    }
}

/// Home, a workspace or a draft: an icon and one line.
private struct WorkflowsSidebarDestinationRow: View {
    @Environment(\.theme) private var theme
    let title: String
    let icon: String
    let isSelected: Bool
    /// "1 issue", in the error tone.
    var badge: String? = nil
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: theme.space.s10) {
            Image(systemName: icon)
                .glyphSize(.footnote, weight: .medium)
                .foregroundStyle(isSelected ? theme.text.primary : theme.text.secondary)
                .frame(width: theme.space.s16)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .textStyle(.body, weight: 500)
                .foregroundStyle(theme.text.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let badge {
                StatusChip(badge, tone: .error)
            }
        }
        .padding(.horizontal, theme.space.s10)
        .padding(.vertical, theme.space.s8)
        .sidebarRowChrome(isSelected: isSelected, isHovered: isHovered)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering in withAnimation(theme.motion.quick) { isHovered = hovering } }
        .help(title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: badge.map { "\(title), \($0)" } ?? title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { action() }
    }
}

/// One workflow: how it runs (a dot and a few words), then Automate and Run.
struct WorkflowsSidebarWorkflowRow: View {
    @Environment(\.theme) private var theme
    let row: WorkflowsSidebarModel.Row
    let isSelected: Bool
    let onOpen: () -> Void
    let onRun: () -> Void
    /// The bolt's popover; its argument closes it.
    let automatePopover: (_ close: @escaping () -> Void) -> AnyView?
    @State private var isHovered = false
    @State private var showsAutomate = false
    /// The presenter keeps a card hidden until it has a height.
    @State private var automateHeight: CGFloat = 0

    /// Run and Automate only where the pointer is, so the list reads as
    /// names and states, and a selected row keeps its whole subtitle.
    private var showsActions: Bool { isHovered || showsAutomate }

    var body: some View {
        WorkflowLiveRunReader(workflowID: row.workflowID) { going in
            content(going: going)
        }
    }

    private func content(going: WorkflowLiveRuns.Summary?) -> some View {
        HStack(spacing: theme.space.s8) {
            Group {
                if let going {
                    if going.isWaitingOnYou {
                        Image(systemName: "hand.raised.fill")
                            .glyphSize(.footnote, weight: .semibold)
                            .foregroundStyle(theme.statusInk(.warning))
                    } else {
                        SettingsSpinner(size: .mini)
                    }
                } else {
                    WorkflowStatusMark(status: row.status)
                }
            }
            .frame(width: theme.space.s16, height: theme.space.s16)
            .help(going?.shortLine ?? WorkflowStatusMark.label(row.status))
            VStack(alignment: .leading, spacing: theme.space.s2) {
                HStack(spacing: theme.space.s4) {
                    Text(verbatim: row.name)
                        .textStyle(.body, weight: 500)
                        .foregroundStyle(theme.text.primary)
                        .lineLimit(1)
                    if row.isPublished {
                        Image(systemName: "globe")
                            .glyphSize(.micro, weight: .semibold)
                            .foregroundStyle(theme.text.tertiary)
                            .help(L("Published"))
                            .accessibilityLabel(Text("Published", bundle: .module))
                    }
                }
                Text(verbatim: going?.shortLine ?? row.subtitle)
                    .textStyle(.caption)
                    .foregroundStyle(subtitleInk(going))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(row.name)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { onOpen() }
            .accessibilityAction(named: Text("Run now", bundle: .module)) { onRun() }
            if showsActions { actions }
        }
        .padding(.horizontal, theme.space.s10)
        .padding(.vertical, theme.space.s8)
        .sidebarRowChrome(isSelected: isSelected, isHovered: isHovered)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering in withAnimation(theme.motion.quick) { isHovered = hovering } }
    }

    private func subtitleInk(_ going: WorkflowLiveRuns.Summary?) -> Color {
        if let going { return going.isWaitingOnYou ? theme.statusInk(.warning) : theme.text.secondary }
        return row.status == .problem ? theme.statusInk(.error) : theme.text.secondary
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: theme.space.s8) {
            if row.canAutomate {
                SidebarRowActionButton(icon: "bolt", help: "Automate") { showsAutomate.toggle() }
                    .accessibilityLabel(Text("Automate \(row.name)", bundle: .module))
                    .anchoredCard(
                        isPresented: $showsAutomate,
                        size: CGSize(width: WorkflowAutomatePopover.width, height: automateHeight),
                        besideAnchor: true, shadowPadding: theme.space.s20, shadowPassesThrough: true,
                        accessibilityLabel: L("Automate \(row.name)")
                    ) {
                        automateCard
                    }
            }
            SettingsIconButton("play", help: "Run now", size: .extraExtraSmall, role: .secondary, action: onRun)
                .accessibilityLabel(Text("Run \(row.name) now", bundle: .module))
        }
        .transition(.opacity)
    }

    /// The card leaves the sidebar, so it draws with the app theme rather
    /// than the sidebar's family scope, which would give it the sidebar's
    /// fill and no border. The surface wraps the scroll view so its shadow
    /// is not clipped.
    private var automateCard: some View {
        let cardTheme = theme.unscopedTheme
        return ScrollView(.vertical) {
            if showsAutomate, let card = automatePopover({ showsAutomate = false }) {
                card
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if abs(automateHeight - height) > 0.5 { automateHeight = max(1, height) }
                    }
            }
        }
        .scrollIndicators(.hidden)
        .clipShape(RoundedRectangle(cornerRadius: cardTheme.radius.xlarge, style: .continuous))
        .settingsChrome(.overlay)
        .environment(\.theme, cardTheme)
    }
}

/// How a workflow runs, never by color alone: a filled dot when it runs
/// on its own, a filled problem dot when it needs attention, a hollow
/// dot when only the person runs it, the setup glyph before it can run.
struct WorkflowStatusMark: View {
    @Environment(\.theme) private var theme
    let status: WorkflowsSidebarModel.Status

    var body: some View {
        Group {
            switch status {
            case .needsSetup:
                Image(systemName: "exclamationmark.circle")
                    .glyphSize(.footnote, weight: .semibold)
                    .foregroundStyle(theme.statusInk(.warning))
            case .problem:
                Image(systemName: "exclamationmark.circle.fill")
                    .glyphSize(.footnote, weight: .semibold)
                    .foregroundStyle(theme.statusInk(.error))
            case .automated:
                Circle().fill(theme.statusInk(.success))
                    .frame(width: theme.space.s8, height: theme.space.s8)
            case .manual:
                // The sidebar's family scope sets `stroke.default` to zero.
                Circle().strokeBorder(theme.text.tertiary, lineWidth: theme.unscopedTheme.stroke.default)
                    .frame(width: theme.space.s8, height: theme.space.s8)
            }
        }
        .frame(width: theme.space.s16, height: theme.space.s16)
        .help(Self.label(status))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Self.label(status)))
    }

    static func label(_ status: WorkflowsSidebarModel.Status) -> String {
        switch status {
        case .needsSetup: return L("Needs setup")
        case .problem: return L("Needs attention")
        case .automated: return L("Runs on its own")
        case .manual: return L("Run by hand")
        }
    }
}

/// The Store row: workflows made by others, on the website.
private struct WorkflowsSidebarStoreRow: View {
    @Environment(\.theme) private var theme
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: theme.space.s10) {
            Image(systemName: "storefront")
                .glyphSize(.footnote, weight: .medium)
                .foregroundStyle(theme.text.secondary)
                .frame(width: theme.space.s16)
                .accessibilityHidden(true)
            Text("Osaurus Store", bundle: .module)
                .textStyle(.body, weight: 500)
                .foregroundStyle(theme.text.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.up.right")
                .glyphSize(.micro, weight: .semibold)
                .foregroundStyle(theme.text.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, theme.space.s10)
        .padding(.vertical, theme.space.s8)
        .sidebarRowChrome(isSelected: false, isHovered: isHovered)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering in withAnimation(theme.motion.quick) { isHovered = hovering } }
        .help(L("Workflows made by others, on store.osaurus.ai"))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isLink)
        .accessibilityAction { action() }
    }
}
