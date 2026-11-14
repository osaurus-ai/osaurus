//
//  WorkflowsRunHome.swift
//  osaurus
//
//  The Workflows window's home: what is running now, from here, from an
//  agent, or from an automation, then the workflows in tabs: All, Drafts
//  to continue while there are any, Published once anything is, and
//  Workspaces while this Mac belongs to one. A
//  workflow's row opens to show its last few runs, live ones filling in
//  step by step.
//

import SwiftUI

extension WorkflowsView {
    /// The tab on screen; Drafts and Published are offered only while they
    /// have something.
    var workflowsTab: ChatWindowState.WorkflowsTab {
        ChatWindowState.workflowsTab(
            chosen: windowState.workflowsTab, hasInstalled: !installed.workflows.isEmpty,
            hasDrafts: !drafts.libraryDrafts.isEmpty, hasPublished: !publishedWorkflows.isEmpty,
            hasWorkspaces: !workspaces.workspaces.isEmpty)
    }

    var workflowsHome: some View {
        let tab = workflowsTab
        return VStack(alignment: .leading, spacing: theme.space.s32) {
            homeHeader
            WorkflowsRunningNow(onOpen: openRun)
            VStack(alignment: .leading, spacing: theme.space.s16) {
                WorkflowPageTabBar(
                    selection: Binding(
                        get: { tab },
                        set: { chosen in
                            withAnimation(theme.motion.quick) {
                                selectedTag = nil
                                windowState.workflowsTab = chosen
                            }
                        }),
                    tabs: homeTabs
                ) {
                    if tab != .drafts && tab != .workspaces && showsSearch {
                        searchField.transition(.opacity)
                    }
                }
                .accessibilityLabel(Text("Workflows", bundle: .module))
                Group {
                    switch tab {
                    case .all, .published: workflowList(tab)
                    case .drafts: draftsList
                    case .workspaces:
                        WorkflowsWorkspacesTab(windowState: windowState, onSetUp: { setupSubject = .setup($0) })
                    }
                }
                .id(tab)
                .transition(.opacity)
            }
        }
    }

    /// The title with Import and New Workflow, then what you've published
    /// and links to what workflows use and what starts them.
    private var homeHeader: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            homeTitle(L("Workflows")) {
                SettingsButton(
                    .secondary, "Import", icon: "square.and.arrow.down", size: .extraSmall,
                    help: "Import a workflow file. You can also drop one anywhere here.", action: chooseFile
                )
                .settingsLandingAnchor("workflows.importExport")
                SettingsButton(.primary, "New Workflow", icon: "plus", size: .extraSmall, help: "Describe a task to the Architect (⌘N)") {
                    withAnimation(theme.motion.quick) { windowState.showNewWorkflow() }
                }
                .settingsLandingAnchor("workflows.architect")
            }
            HStack(spacing: theme.space.s4) {
                PublishedByYouLine(kind: .workflow, anchor: "workflows.publishedByYou")
                Spacer(minLength: theme.space.s8)
                WorkflowTextLink(title: L("Connections"), icon: "link") { showingConnections = true }
                    .help(L("The services your workflows sign in to. See what each one is used by and sign in again."))
                .settingsLandingAnchor("workflows.connections")
                WorkflowTextLink(title: L("Automations"), icon: "bolt") {
                    managementState.selectedTab = .automations
                    AppDelegate.shared?.showManagementWindow(initialTab: .automations)
                }
                .help(L("Start workflows on a schedule, from a folder, a webhook, or a channel message."))
                .settingsLandingAnchor("workflows.automations")
            }
            .padding(.trailing, -theme.space.s6)
        }
    }

    private var homeTabs: [WorkflowPageTab<ChatWindowState.WorkflowsTab>] {
        var tabs = [WorkflowPageTab(value: ChatWindowState.WorkflowsTab.all, title: L("All"), count: installed.workflows.count + hostedLinks.links.count)]
        let draftCount = drafts.libraryDrafts.count
        if draftCount > 0 { tabs.append(WorkflowPageTab(value: .drafts, title: L("Drafts"), count: draftCount)) }
        let publishedCount = publishedWorkflows.count
        if publishedCount > 0 {
            tabs.append(WorkflowPageTab(value: .published, title: L("Published"), count: publishedCount))
        }
        if !workspaces.workspaces.isEmpty {
            let shared = workspaces.workspaces.reduce(0) { total, workspace in
                let entry = workspaceCatalog.entry(workspace.id)
                let listed = Set(entry.workflows.map(\.templateID))
                return total + entry.workflows.count + entry.hosted.filter { !listed.contains($0.templateID) }.count
            }
            tabs.append(WorkflowPageTab(value: .workspaces, title: L("Workspaces"), count: shared))
        }
        return tabs
    }

    // MARK: Lists

    @ViewBuilder
    private func workflowList(_ tab: ChatWindowState.WorkflowsTab) -> some View {
        let links = tab == .all ? hostedLinks.links : []
        if tabWorkflows(tab).isEmpty, links.isEmpty {
            nothingToRun
                .settingsLandingAnchor(tab == .published ? "workflows.published" : "workflows.all")
        } else {
            let history = WorkflowRunPresentation.runsByWorkflow(runs.recentRuns())
            VStack(alignment: .leading, spacing: theme.space.s12) {
                filterChips(tab).padding(.bottom, theme.space.s4)
                let shown = shownInstalled(tab)
                let shownLinks = links.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                if shown.isEmpty, !tabWorkflows(tab).isEmpty || shownLinks.isEmpty { noMatches }
                let ids = shown.map(\.id)
                LazyVStack(alignment: .leading, spacing: theme.space.s12) {
                    ForEach(shown) { workflow in
                        WorkflowRowSnapshot(key: rowKey(workflow, ids: ids)) {
                            workflowRow(workflow, history: history[workflow.id] ?? [], ids: ids)
                        }
                        .equatable()
                    }
                }
                if !shownLinks.isEmpty {
                    WorkflowSectionHeader(title: L("On teammates' Macs"), count: shownLinks.count) { EmptyView() }
                        .padding(.top, theme.space.s8)
                    ForEach(shownLinks) { link in
                        HostedWorkflowLinkRow(link: link) { runningLink = link }
                    }
                }
            }
            .settingsLandingAnchor(tab == .published ? "workflows.published" : "workflows.all")
        }
    }

    private var nothingToRun: some View {
        SettingsEmptyState(
            inline: "play.circle", title: "Nothing to run yet.",
            hint: "Finish a draft, or start a new workflow.",
            action: .init(title: L("New Workflow"), icon: "plus") {
                withAnimation(theme.motion.quick) { windowState.showNewWorkflow() }
            })
    }

    private var draftsList: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            let ids = drafts.libraryDrafts.map(\.id)
            ForEach(drafts.libraryDrafts) { draft in
                draftRow(draft)
                    .keyboard(WorkflowRowFocusRequest.keyboard(for: draft.id, in: ids, current: $rowFocus))
            }
        }
        .settingsLandingAnchor("workflows.drafts")
    }

    private func draftRow(_ draft: WorkflowDraft) -> WorkflowHomepageRow<EmptyView, some View, some View, some View, EmptyView> {
        let resume = { ArchitectLauncher.resume(draft, in: windowState) }
        let summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkflowHomepageRow(
            title: draft.name.isEmpty ? L("Untitled Workflow") : draft.name,
            summary: summary.isEmpty ? DraftEditing(draft)?.label(draftName: draft.name) ?? "" : summary,
            isDraft: true,
            onOpen: resume,
            leading: { EmptyView() },
            meta: { DraftRowStage(draft: draft) },
            accessory: {
                SettingsButton(.secondary, "Continue", size: .extraSmall, action: resume)
            },
            actions: {
                Button(action: resume) { Label(L("Continue Editing"), systemImage: "pencil.and.outline") }
                Divider()
                Button(role: .destructive) { deletingDraft = draft } label: {
                    Label(L("Delete Draft…"), systemImage: "trash")
                }
            },
            expanded: { EmptyView() })
    }

    /// Where a draft stands and when it was last edited. It observes the
    /// run store itself: its stage follows the draft's latest test run.
    private struct DraftRowStage: View {
        @Environment(\.theme) private var theme
        @ObservedObject private var runs = WorkflowRunStore.shared
        let draft: WorkflowDraft

        var body: some View {
            let status = DraftStatus(draft: draft, latest: draft.testRunIDs.last.flatMap { runs.run(id: $0) })
            VStack(alignment: .trailing, spacing: theme.space.s2) {
                WorkflowStageStepper(stage: status.stage, compact: true)
                Text(verbatim: L("Edited \(WorkflowRunPresentation.relativeTime(draft.updatedAt))"))
                    .textStyle(.caption)
                    .foregroundStyle(theme.text.tertiary)
                    .lineLimit(1)
            }
            .fixedSize()
            .help(status.detail ?? status.title)
        }
    }

    // MARK: Rows

    /// The row shows its last run's outcome and whether one is going; an
    /// open row's recent runs fill in on their own.
    private func rowKey(_ workflow: InstalledWorkflow, ids: [UUID]) -> InstalledRowKey {
        var key = installedRowKey(workflow, ids: ids)
        key.isExpanded = expandedWorkflows.contains(workflow.id)
        if key.isExpanded {
            key.spotlight = windowState.workflowsSpotlightRunID
            key.automations = automationCount(workflow.id)
        }
        key.runs = runGlances.byWorkflow[workflow.id] ?? .init()
        return key
    }

    private func workflowRow(_ workflow: InstalledWorkflow, history: [WorkflowRun], ids: [UUID]) -> some View {
        let isExpanded = expandedWorkflows.contains(workflow.id)
        let live = history.first { !$0.status.isTerminal }
        let parts = WorkflowRowParts(
            isExpandable: true,
            isExpanded: isExpanded,
            meta: AnyView(rowMeta(workflow, lastRun: history.first)),
            accessory: AnyView(runButton(workflow, live: live)),
            expanded: AnyView(recentRuns(workflow)),
            keyboard: WorkflowRowFocusRequest.keyboard(for: workflow.id, in: ids, current: $rowFocus))
        return installedCard(workflow, row: parts) {
            withAnimation(expandAnimation) {
                if isExpanded { expandedWorkflows.remove(workflow.id) } else { expandedWorkflows.insert(workflow.id) }
            }
        }
        .id(workflow.id)
    }

    /// An available update and the Live badge once published, then the
    /// last run.
    private func rowMeta(_ workflow: InstalledWorkflow, lastRun run: WorkflowRun?) -> some View {
        HStack(spacing: theme.space.s6) {
            if let update = installed.availableUpdate(for: workflow) {
                StatusChip(L("Update to v\(update.version)"), tone: .accent)
            }
            if let published = registryRecords.record(for: workflow.templateID) {
                LiveBadge(record: published) { share(workflow.template, entry: .manage) }
            }
            if let workspaceID = workflow.source?.workspaceID,
                let workspace = workspaces.workspaces.first(where: { $0.id == workspaceID })
            {
                StatusChip(L("Shared in \(workspace.name)"), tone: .neutral)
                    .help(L("Installed from what \(workspace.name) shares. Updates show here when its author shares a new version."))
            }
            lastRun(run)
        }
        .fixedSize()
    }

    @ViewBuilder
    private func lastRun(_ run: WorkflowRun?) -> some View {
        if let run, !run.status.isTerminal {
            StatusChip(WorkflowRunPresentation.shortStatus(run.status), tone: WorkflowRunPresentation.tone(run.status), showsDot: true)
                .fixedSize()
        } else if let run {
            HStack(spacing: theme.space.s4) {
                Image(systemName: WorkflowRunStyle.icon(run.status))
                    .glyphSize(.micro, weight: .semibold)
                    .foregroundStyle(WorkflowRunStyle.color(run.status, theme: theme))
                    .accessibilityHidden(true)
                Text(verbatim: WorkflowRunPresentation.relativeTime(run.finishedAt ?? run.startedAt))
                    .textStyle(.caption)
                    .foregroundStyle(theme.text.tertiary)
                    .lineLimit(1)
            }
            .fixedSize()
            .help(WorkflowRunPresentation.lastRunSummary(run))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: L("Last run: \(WorkflowRunPresentation.lastRunSummary(run))")))
        } else {
            Text("Not run yet", bundle: .module)
                .textStyle(.caption)
                .foregroundStyle(theme.text.tertiary)
                .fixedSize()
        }
    }

    /// Run, or Set Up when the workflow can't run yet. While a run is
    /// going, a spinner that opens it.
    @ViewBuilder
    private func runButton(_ workflow: InstalledWorkflow, live: WorkflowRun?) -> some View {
        if let live {
            Button { openRun(live) } label: {
                SettingsSpinner(size: .mini)
            }
            .buttonStyle(SettingsIconButtonStyle(size: .extraSmall, role: .tertiary))
            .help(L("Running. Open the run"))
            .accessibilityLabel(Text("Open the run", bundle: .module))
        } else if workflow.needsSetup {
            SettingsButton(.secondary, "Set Up", icon: "checklist", size: .extraSmall) {
                setupSubject = .setup(workflow)
            }
        } else {
            SettingsIconButton("play.fill", help: "Run", size: .extraSmall, role: .primary) { play(workflow) }
                .accessibilityLabel(Text("Run \(workflow.name)", bundle: .module))
        }
    }

    private func recentRuns(_ workflow: InstalledWorkflow) -> some View {
        let automations = automationCount(workflow.id)
        return VStack(alignment: .leading, spacing: theme.space.s8) {
            WorkflowRecentRunsList(
                workflow: workflow, spotlightRunID: windowState.workflowsSpotlightRunID, onOpen: openRun)
            HStack(spacing: theme.space.s4) {
                if runGlances.byWorkflow[workflow.id]?.lastRun != nil {
                    WorkflowTextLink(title: L("See all runs"), icon: "clock.arrow.circlepath") {
                        windowState.pushWorkflowsPage(.workflow(workflow.id))
                    }
                }
                if !WorkflowFormFields.fields(fromInputSchema: workflow.definition.inputSchema).isEmpty,
                    !workflow.needsSetup
                {
                    WorkflowTextLink(title: L("Run with different input"), icon: "square.and.pencil") {
                        runSheet = RunSheetRequest(workflow: workflow)
                    }
                }
                Spacer(minLength: theme.space.s8)
                WorkflowTextLink(
                    title: automations == 0
                        ? L("Run it automatically")
                        : automations == 1 ? L("1 automation starts this") : L("\(automations) automations start this"),
                    icon: "bolt"
                ) {
                    managementState.selectedTab = .automations
                    AppDelegate.shared?.showManagementWindow(initialTab: .automations)
                }
            }
            .padding(.horizontal, -theme.space.s6)
        }
    }

    private func automationCount(_ workflowID: UUID) -> Int {
        EventManager.shared.events.filter { event in
            guard event.isEnabled, case .workflow(let action) = event.action else { return false }
            return action.workflowID == workflowID
        }.count
    }
}

/// An open row's recent runs, live ones filling in step by step. It
/// observes the run store itself, so the row around it stays put.
private struct WorkflowRecentRunsList: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var runs = WorkflowRunStore.shared
    let workflow: InstalledWorkflow
    let spotlightRunID: UUID?
    let onOpen: (WorkflowRun) -> Void

    var body: some View {
        let recent = Array(
            runs.recentRuns().lazy.filter { $0.workflowID == workflow.id }.prefix(WorkflowRunPresentation.recentPerWorkflow))
        if recent.isEmpty {
            Text("No runs yet. Press Run to start one.", bundle: .module)
                .textStyle(.caption)
                .foregroundStyle(theme.text.tertiary)
                .padding(.vertical, theme.space.s4)
        } else {
            VStack(alignment: .leading, spacing: theme.space.s2) {
                ForEach(recent) { run in
                    WorkflowRunCompactRow(run: run, definition: workflow.definition) { onOpen(run) }
                        .settingsChrome(run.id == spotlightRunID ? .selected : nil, radius: theme.radius.small)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, -theme.space.s8)
            .animation(theme.motion.quick, value: recent.map(\.id))
        }
    }
}

// MARK: - Running now

/// Runs going right now, whoever started them (you, an agent, an
/// automation), plus ones that ended moments ago. Waiting on you comes
/// first. Hidden when nothing is going.
struct WorkflowsRunningNow: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var runs = WorkflowRunStore.shared
    @ObservedObject private var installed = InstalledWorkflowStore.shared
    let onOpen: (WorkflowRun) -> Void

    @State private var now = Date()

    var body: some View {
        let activity = WorkflowRunPresentation.activity(runs.live.values, now: now)
        Group {
            if !activity.isEmpty {
                VStack(alignment: .leading, spacing: theme.space.s12) {
                    let waiting = activity.filter { $0.status == .awaitingUser }.count
                    WorkflowSectionHeader(
                        title: L("Running now"), count: activity.filter { !$0.status.isTerminal }.count
                    ) {
                        if waiting > 0 {
                            Text(verbatim: L("\(waiting) waiting on you"))
                                .textStyle(.caption, weight: 500)
                                .foregroundStyle(theme.text.secondary)
                        }
                    }
                    VStack(spacing: theme.space.s0) {
                        ForEach(Array(activity.enumerated()), id: \.element.id) { index, run in
                            if index > 0 {
                                ThemeHairlineDivider(color: theme.border.subtle)
                                    .padding(.horizontal, theme.space.s16)
                            }
                            WorkflowRunningNowRow(
                                run: run, definition: installed.workflow(id: run.workflowID)?.definition,
                                onOpen: { onOpen(run) })
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .settingsChrome(.card)
                    .animation(theme.motion.standard, value: activity.map(\.id))
                }
                .settingsLandingAnchor("workflows.runningNow")
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(theme.motion.standard, value: activity.isEmpty)
        .task(id: nextExpiry(activity)) {
            guard let expiry = nextExpiry(activity) else { return }
            let wait = max(0, expiry.timeIntervalSinceNow) + 0.05
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            now = Date()
        }
        .onChange(of: runs.live.count) { _, _ in now = Date() }
    }

    /// When the soonest-ending linger runs out, so the card drops it.
    private func nextExpiry(_ activity: [WorkflowRun]) -> Date? {
        activity.compactMap { run in
            run.status.isTerminal ? run.finishedAt?.addingTimeInterval(WorkflowRunPresentation.lingerInterval) : nil
        }.min()
    }
}

/// One run in Running Now: the workflow, how far it has got, who started
/// it, and the one thing to do about it (Respond or Stop).
private struct WorkflowRunningNowRow: View {
    @Environment(\.theme) private var theme
    let run: WorkflowRun
    let definition: WorkflowDefinition?
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: theme.space.s12) {
            WorkflowRunStatusIcon(status: run.status, size: 14)
                .frame(width: theme.space.s16, height: theme.space.s16)
                .padding(.top, theme.space.s2)
            VStack(alignment: .leading, spacing: theme.space.s6) {
                HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
                    Text(verbatim: run.workflowName)
                        .textStyle(.body, weight: 500)
                        .foregroundStyle(theme.text.primary)
                        .lineLimit(1)
                    WorkflowStartedByLabel(caller: run.caller)
                    Spacer(minLength: theme.space.s8)
                    WorkflowRunElapsed(run: run).fixedSize()
                }
                Text(verbatim: WorkflowRunPresentation.progressLine(run, definition: definition))
                    .textStyle(.caption)
                    .foregroundStyle(run.status == .failed ? theme.statusInk(.error) : theme.text.secondary)
                    .lineLimit(1)
                if !run.nodes.isEmpty, !run.status.isTerminal {
                    WorkflowStepStrip(run: run)
                }
            }
            action
                .padding(.top, -theme.space.s2)
        }
        .padding(.horizontal, theme.space.s16)
        .padding(.vertical, theme.space.s12)
        .background { if isHovered { theme.surface.hover } }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering in withAnimation(theme.motion.quick) { isHovered = hovering } }
        .pointingHandCursor()
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Open the run", bundle: .module), onOpen)
    }

    @ViewBuilder
    private var action: some View {
        switch run.status {
        case .awaitingUser:
            Button(action: onOpen) {
                Text("Respond", bundle: .module)
            }
            .assignedSettingsButtonStyle(.primary, size: .extraSmall)
        case .running:
            Button {
                WorkflowRunService.shared.cancel(run.id)
            } label: {
                HStack(spacing: theme.space.s6) {
                    Image(systemName: "stop.fill")
                        .glyphSize(.tiny)
                        .accessibilityHidden(true)
                    Text("Stop", bundle: .module)
                }
            }
            .assignedSettingsButtonStyle(.secondary, size: .extraSmall)
            .help(L("Stop this run"))
        default:
            Image(systemName: "chevron.right")
                .glyphSize(.tiny, weight: .semibold)
                .foregroundStyle(theme.text.tertiary)
                .frame(height: theme.space.s24)
                .accessibilityHidden(true)
        }
    }
}
