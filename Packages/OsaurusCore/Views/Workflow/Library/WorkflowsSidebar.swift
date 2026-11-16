//
//  WorkflowsSidebar.swift
//  osaurus
//
//  The Workflows destination's sidebar, in the column the chat sidebar
//  uses: search, Home, then Pinned, All workflows, Drafts and Workspaces,
//  with New workflow and the Osaurus Store at the foot. Each workflow row
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

    private var model: WorkflowsSidebarModel {
        WorkflowsSidebarModel.make(
            workflows: installed.workflows,
            hostedLinks: hostedLinks.links,
            automations: overview.automationFacts,
            publishedTemplateIDs: Set(installed.workflows.map(\.templateID).filter { registryRecords.record(for: $0) != nil }),
            drafts: drafts.libraryDrafts,
            workspaces: workspaces.workspaces.map { .init(id: $0.id, name: $0.name) },
            query: query)
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
        if !model.pinned.isEmpty {
            SidebarSectionHeader(title: L("Pinned"))
                .settingsLandingAnchor("workflows.pin")
            ForEach(model.pinned) { workflowRow($0) }
        }
        if !model.all.isEmpty {
            SidebarSectionHeader(title: L("All workflows"))
                .settingsLandingAnchor("workflows.all")
            ForEach(model.all) { workflowRow($0) }
        }
        if !model.drafts.isEmpty {
            SidebarSectionHeader(title: L("Drafts"))
                .id(WorkflowsSidebarSection.drafts)
                .settingsLandingAnchor("workflows.drafts")
            ForEach(model.drafts) { draftRow($0) }
        }
        if !model.workspaces.isEmpty {
            SidebarSectionHeader(title: L("Workspaces"))
                .settingsLandingAnchor("workflows.workspaces")
            ForEach(model.workspaces) { workspace in
                destinationRow(workspace.name, icon: "person.3", isSelected: selection == .workspace(workspace.id)) {
                    windowState.selectWorkflowsPage(.workspace(workspace.id))
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

    private func destinationRow(
        _ title: String, icon: String, isSelected: Bool, action: @escaping () -> Void
    ) -> some View {
        WorkflowsSidebarDestinationRow(title: title, icon: icon, isSelected: isSelected, action: action)
    }

    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let target = windowState.workflowsSidebarScrollTarget else { return }
        windowState.workflowsSidebarScrollTarget = nil
        withAnimation(theme.motion.quick) { proxy.scrollTo(target, anchor: .top) }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            SettingsButton(.secondary, "New Workflow", icon: "plus", size: .small, help: "Describe a task and Osaurus builds it (⌘N)") {
                windowState.isWorkflowsDrawerPresented = false
                windowState.showNewWorkflow()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            WorkflowsSidebarStoreRow { NSWorkspace.shared.open(Self.storeURL) }
                .settingsLandingAnchor("workflows.store")
        }
        .padding(.horizontal, theme.space.s16)
        .padding(.top, theme.space.s8)
        .padding(.bottom, theme.space.s16)
    }
}

// MARK: - Rows

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

    /// Run and Automate only where the pointer is, so the list reads as
    /// names and states.
    private var showsActions: Bool { isHovered || isSelected || showsAutomate }

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
                        size: CGSize(width: WorkflowAutomatePopover.width, height: 0),
                        besideAnchor: true, accessibilityLabel: L("Automate \(row.name)")
                    ) {
                        if showsAutomate { automatePopover { showsAutomate = false } }
                    }
            }
            SettingsIconButton("play", help: "Run now", size: .extraExtraSmall, role: .secondary, action: onRun)
                .accessibilityLabel(Text("Run \(row.name) now", bundle: .module))
        }
        .transition(.opacity)
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
                Circle().strokeBorder(theme.text.tertiary, lineWidth: theme.stroke.default)
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
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text("Osaurus Store", bundle: .module)
                    .textStyle(.body, weight: 500)
                    .foregroundStyle(theme.text.primary)
                Text("Workflows made by others", bundle: .module)
                    .textStyle(.caption)
                    .foregroundStyle(theme.text.secondary)
            }
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
        .help(L("Opens store.osaurus.ai in your browser"))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isLink)
        .accessibilityAction { action() }
    }
}
