//
//  WorkflowsHomeSections.swift
//  osaurus
//
//  Home's sections under Running now: the pinned workflows as tiles with
//  Run, every automation that runs a workflow with its switch and how its
//  last runs went, and the ways to automate, each starting from a
//  workflow you pick. Each hides when it has nothing to show.
//

import AppKit
import SwiftUI

/// "4 run on their own. 1 needs your attention." under Home's title.
struct WorkflowsHomeSubtitle: View {
    @Environment(\.theme) private var theme
    @ObservedObject var overview: WorkflowsOverviewModel
    @ObservedObject private var installed = InstalledWorkflowStore.shared

    var body: some View {
        let model = WorkflowsHomeModel.make(workflows: installed.workflows, automations: overview.automationFacts)
        Text(verbatim: model.subtitle)
            .font(SettingsFont.rowDescription)
            .foregroundStyle(theme.text.secondary)
    }
}

struct WorkflowsHomeSections: View {
    @Environment(\.theme) private var theme
    let windowState: ChatWindowState
    @ObservedObject var overview: WorkflowsOverviewModel
    @ObservedObject private var installed = InstalledWorkflowStore.shared
    @ObservedObject private var runs = WorkflowRunStore.shared

    let onRun: (InstalledWorkflow) -> Void
    let onSetUp: (InstalledWorkflow) -> Void
    let onAllActivity: () -> Void

    @State private var editorRequest: EventEditorRequest?

    var body: some View {
        let model = WorkflowsHomeModel.make(
            workflows: installed.workflows, automations: overview.automationFacts,
            eventRuns: overview.recentRuns, workflowRuns: runs.recentRuns(),
            otherAutomationCount: overview.otherAutomationCount)
        let attention = WorkflowActivityFeed.attention(
            workflows: installed.workflows, automations: overview.automationFacts,
            latestSettled: overview.latestSettled, run: { runs.run(id: $0) },
            targetProblem: { EventInspection.targetProblem($0)?.message })
        VStack(alignment: .leading, spacing: theme.space.s32) {
            if !attention.isEmpty { needsAttention(attention) }
            if !model.pinned.isEmpty { pinned(model.pinned) }
            if !model.groups.isEmpty || model.otherAutomationCount > 0 { runningOnTheirOwn(model) }
            ways(model.ways)
            fromTheStore
        }
        .task { await runs.loadRecentRunsIfNeeded() }
        .sheet(item: $editorRequest) { request in
            EventEditorSheet(
                request: request,
                onSave: { event in
                    let created = EventManager.shared.create(event, telemetryOrigin: "user")
                    editorRequest = nil
                    if created.sourceKind == .webhook { WorkflowAutomationLinks.openInSettings(created.id) }
                },
                onCancel: { editorRequest = nil })
        }
    }

    // MARK: Needs attention

    private func needsAttention(_ all: [WorkflowAttention]) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            WorkflowSectionHeader(title: L("Needs attention"), count: all.count) {
                if all.count > WorkflowActivityFeed.attentionLimit {
                    WorkflowTextLink(title: L("Show all in Activity")) {
                        windowState.showWorkflowsActivity(.init(filter: .needsAttention))
                    }
                }
            }
            ForEach(all.prefix(WorkflowActivityFeed.attentionLimit)) { item in
                WorkflowsAttentionBanner(
                    item: item,
                    onRemedy: { remedy in
                        switch remedy {
                        case .fix(let fix): fix.perform(over: NSApp.keyWindow)
                        case .signInAgain: if let workflow = installed.workflow(id: item.workflowID) { onSetUp(workflow) }
                        }
                    },
                    onSeeWhatHappened: {
                        windowState.showWorkflowsActivity(.init(workflowID: item.itemID == nil ? item.workflowID : nil, focusItemID: item.itemID))
                    })
            }
        }
        .settingsLandingAnchor("workflows.needsAttention")
    }

    // MARK: Pinned

    private func pinned(_ tiles: [WorkflowsHomeModel.Tile]) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            sectionTitle(L("Pinned"), subtitle: L("One click to run"))
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180), spacing: theme.space.s12, alignment: .top)],
                alignment: .leading, spacing: theme.space.s12
            ) {
                ForEach(tiles) { tile in
                    WorkflowsPinnedTile(
                        tile: tile,
                        onOpen: { windowState.selectWorkflowsPage(.workflow(tile.id)) },
                        onRun: { if let workflow = installed.workflow(id: tile.id) { onRun(workflow) } })
                }
            }
        }
    }

    // MARK: Running on their own

    private func runningOnTheirOwn(_ model: WorkflowsHomeModel) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle(
                    L("Running on their own"),
                    subtitle: L("Your automations, and how the last \(WorkflowsHomeModel.healthRunCount) runs went"))
                Spacer(minLength: theme.space.s8)
                if !model.groups.isEmpty { WorkflowTextLink(title: L("All activity"), action: onAllActivity) }
            }
            if !model.groups.isEmpty {
                VStack(spacing: theme.space.s0) {
                    ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 { ThemeHairlineDivider(color: theme.border.subtle) }
                        if group.rows.count > 1 {
                            Text(verbatim: group.name)
                                .textStyle(.caption, weight: 500)
                                .foregroundStyle(theme.text.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, theme.space.s16)
                                .padding(.top, theme.space.s12)
                        }
                        ForEach(group.rows) { row in
                            WorkflowsHomeAutomationRow(row: row) {
                                windowState.showWorkflowAutomation(workflowID: row.workflowID, intent: .highlight(row.id))
                            }
                        }
                    }
                }
                .settingsChrome(.card)
            }
            if model.otherAutomationCount > 0 {
                HStack(spacing: theme.space.s6) {
                    Text(verbatim: L("\(model.otherAutomationCount) other automations run agents."))
                        .font(SettingsFont.footnote)
                        .foregroundStyle(theme.text.secondary)
                    WorkflowTextLink(title: L("Open Automations")) {
                        ManagementStateManager.shared.selectedTab = .automations
                        AppDelegate.shared?.showManagementWindow(initialTab: .automations)
                    }
                }
            }
        }
        .id(WorkflowsHomeSection.runningOnTheirOwn)
        .settingsLandingAnchor("workflows.runningOnTheirOwn")
    }

    // MARK: Ways to automate

    private func ways(_ ways: [WorkflowsHomeModel.Way]) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            sectionTitle(L("Ways to automate"), subtitle: L("Pick a moment, then pick a workflow"))
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180), spacing: theme.space.s12, alignment: .top)],
                alignment: .leading, spacing: theme.space.s12
            ) {
                ForEach(ways) { way in
                    Menu {
                        workflowPicker(for: way.item.entry)
                    } label: {
                        WorkflowsWayCard(way: way)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .disabled(installed.workflows.isEmpty)
                }
            }
            HStack(spacing: theme.space.s4) {
                Text(verbatim: L("Building something custom? Webhooks and event streams live under Advanced."))
                    .font(SettingsFont.footnote)
                    .foregroundStyle(theme.text.secondary)
                WorkflowTextLink(title: L("Open Advanced"), action: WorkflowAutomationLinks.openAddAutomation)
            }
        }
        .id(WorkflowsHomeSection.ways)
        .settingsLandingAnchor("workflows.waysToAutomate")
    }

    /// The workflows to start this way, by name; an app's news picks the app next.
    @ViewBuilder
    private func workflowPicker(for entry: AutomationCatalog.Entry) -> some View {
        Text(verbatim: L("Pick a workflow"))
        ForEach(installed.workflows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { workflow in
            if entry == .appNews {
                Menu(workflow.name) {
                    ForEach(WebhookProvider.services, id: \.self) { provider in
                        Button(provider.shortName) {
                            editorRequest = EventEditorRequest(template: .providerWebhook(provider), initialWorkflowId: workflow.id)
                        }
                    }
                }
            } else {
                Button(workflow.name) { start(entry, for: workflow) }
            }
        }
    }

    private func start(_ entry: AutomationCatalog.Entry, for workflow: InstalledWorkflow) {
        let source: EventSource
        switch entry {
        case .kind(.schedule): source = AutomationDefaults.schedule
        case .kind(.app): source = AutomationDefaults.appLaunch
        case .kind(.runFailed): source = AutomationDefaults.runFailed
        case .kind(.rss):
            windowState.showWorkflowAutomation(workflowID: workflow.id, intent: .addFeed)
            return
        case .kind(.folder):
            Task { @MainActor in
                guard let picked = await WorkflowAutomationFolderPicker.pick(startingAt: nil) else { return }
                let created = EventManager.shared.create(
                    AutomationDefaults.event(for: workflow, source: AutomationDefaults.folder(path: picked.path, bookmark: picked.bookmark)),
                    telemetryOrigin: "user")
                windowState.showWorkflowAutomation(workflowID: workflow.id, intent: .highlight(created.id))
            }
            return
        case .kind(let kind):
            windowState.showWorkflowAutomation(workflowID: workflow.id, intent: .openEditor(.source(kind)))
            return
        case .appNews:
            return
        }
        let created = EventManager.shared.create(AutomationDefaults.event(for: workflow, source: source), telemetryOrigin: "user")
        windowState.showWorkflowAutomation(workflowID: workflow.id, intent: .highlight(created.id))
    }

    // MARK: From the Store

    /// Listings wait for a registry list to show; until then, the way to
    /// the Store and how to share there.
    private var fromTheStore: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle(L("From the Store"), subtitle: L("Shared by the people who made them"))
                Spacer(minLength: theme.space.s8)
                WorkflowTextLink(title: L("Browse the Store")) { NSWorkspace.shared.open(WorkflowsSidebar.storeURL) }
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180), spacing: theme.space.s12, alignment: .top)],
                alignment: .leading, spacing: theme.space.s12
            ) {
                WorkflowsShareInviteCard()
            }
        }
        .id(WorkflowsHomeSection.fromTheStore)
        .settingsLandingAnchor("workflows.fromTheStore")
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s2) {
            Text(verbatim: title)
                .textStyle(.body, weight: 600)
                .foregroundStyle(theme.text.primary)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: subtitle)
                .font(SettingsFont.footnote)
                .foregroundStyle(theme.text.secondary)
        }
    }
}

// MARK: - Tiles and rows

/// "Mail Triage could not run yesterday", what happened, and what to do.
private struct WorkflowsAttentionBanner: View {
    @Environment(\.theme) private var theme
    let item: WorkflowAttention
    let onRemedy: (WorkflowActivityRemedy) -> Void
    let onSeeWhatHappened: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: theme.space.s12) {
            Image(systemName: "exclamationmark.triangle")
                .glyphSize(.body, weight: .semibold)
                .foregroundStyle(theme.statusInk(.error))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: theme.space.s8) {
                Text(verbatim: L("\(item.workflowName) could not run \(WorkflowRunWords.day(item.date))"))
                    .textStyle(.body, weight: 600)
                    .foregroundStyle(theme.text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: item.explanation.sentence)
                    .font(SettingsFont.footnote)
                    .foregroundStyle(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: theme.space.s8) {
                    if let remedy = item.explanation.remedy {
                        SettingsButton(.primary, remedy.title, size: .small, verbatim: true) { onRemedy(remedy) }
                    }
                    SettingsButton(.secondary, "See what happened", size: .small, action: onSeeWhatHappened)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(theme.space.s16)
        .settingsChrome(.status(.error))
        .accessibilityElement(children: .contain)
    }
}

private struct WorkflowsPinnedTile: View {
    @Environment(\.theme) private var theme
    let tile: WorkflowsHomeModel.Tile
    let onOpen: () -> Void
    let onRun: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            Text(verbatim: tile.name)
                .textStyle(.body, weight: 500)
                .foregroundStyle(theme.text.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let summary = tile.summary, !summary.isEmpty {
                Text(verbatim: summary)
                    .font(SettingsFont.footnote)
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: theme.space.s0)
            HStack(spacing: theme.space.s8) {
                Text(verbatim: tile.needsSetup ? L("Finish setup to run") : tile.lastRun)
                    .font(SettingsFont.footnote)
                    .foregroundStyle(
                        tile.needsSetup ? theme.statusInk(.warning) : tile.lastRunFailed ? theme.statusInk(.error) : theme.text.tertiary)
                    .lineLimit(1)
                Spacer(minLength: theme.space.s4)
                SettingsButton(.secondary, tile.needsSetup ? "Set Up" : "Run", icon: tile.needsSetup ? nil : "play.fill", size: .extraSmall, action: onRun)
            }
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, minHeight: theme.space.s64 + theme.space.s32, alignment: .topLeading)
        .settingsChrome(isHovered ? .cardHover : .card)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering in withAnimation(theme.motion.quick) { isHovered = hovering } }
        .pointingHandCursor()
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Open", bundle: .module), onOpen)
    }
}

private struct WorkflowsHomeAutomationRow: View {
    @Environment(\.theme) private var theme
    let row: WorkflowsHomeModel.AutomationRow
    let onOpen: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: theme.space.s12) {
            Image(systemName: EventSourceTemplate.icon(for: row.event))
                .glyphSize(.footnote, weight: .semibold)
                .foregroundStyle(row.event.isEnabled ? theme.text.secondary : theme.text.tertiary)
                .frame(width: theme.space.s16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                (Text(verbatim: row.workflowName).fontWeight(.semibold) + Text(verbatim: " " + row.sentence))
                    .font(SettingsFont.compactLabel)
                    .foregroundStyle(theme.text.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: row.state)
                    .font(SettingsFont.footnote)
                    .foregroundStyle(row.stateTone.map(theme.statusInk) ?? theme.text.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            WorkflowHealthStripView(bars: row.bars)
                .fixedSize()
            Toggle(
                L("\(row.workflowName) automation"),
                isOn: Binding(
                    get: { row.event.isEnabled },
                    set: { EventManager.shared.setEnabled(row.event.id, enabled: $0) })
            )
            .settingsSwitch()
        }
        .padding(.horizontal, theme.space.s16)
        .padding(.vertical, theme.space.s10)
        .background { if isHovered { theme.surface.hover } }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering in withAnimation(theme.motion.quick) { isHovered = hovering } }
        .pointingHandCursor()
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Open the workflow", bundle: .module), onOpen)
    }
}

/// "Made something useful?": a dashed card whose How to share explains
/// where Share is and what it sends.
private struct WorkflowsShareInviteCard: View {
    @Environment(\.theme) private var theme
    @State private var showsHow = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            Image(systemName: "square.and.arrow.up")
                .glyphSize(.body, weight: .semibold)
                .foregroundStyle(theme.text.secondary)
                .accessibilityHidden(true)
            Text("Made something useful?", bundle: .module)
                .textStyle(.body, weight: 500)
                .foregroundStyle(theme.text.primary)
            Text("Share a workflow so others can use it.", bundle: .module)
                .font(SettingsFont.footnote)
                .foregroundStyle(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: theme.space.s0)
            WorkflowTextLink(title: L("How to share")) { showsHow = true }
                .popover(isPresented: $showsHow, arrowEdge: .bottom) {
                    Text(
                        "Open a workflow you made and choose Share, then Publish to store.osaurus.ai and pick who can see it. You share the recipe, never your data: your results and accounts stay on your Mac.",
                        bundle: .module
                    )
                    .font(SettingsFont.compactLabel)
                    .foregroundStyle(theme.text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: theme.space.s64 * 4 + theme.space.s32)
                    .padding(theme.space.s16)
                }
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, minHeight: theme.space.s64 + theme.space.s48, alignment: .topLeading)
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                .strokeBorder(theme.border.strong, style: StrokeStyle(lineWidth: theme.stroke.default, dash: [5, 4])))
    }
}

private struct WorkflowsWayCard: View {
    @Environment(\.theme) private var theme
    let way: WorkflowsHomeModel.Way
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            Image(systemName: way.item.icon)
                .glyphSize(.body, weight: .semibold)
                .foregroundStyle(theme.text.secondary)
                .accessibilityHidden(true)
            Text(verbatim: way.item.title)
                .textStyle(.body, weight: 500)
                .foregroundStyle(theme.text.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: way.item.example)
                .font(SettingsFont.footnote)
                .foregroundStyle(theme.text.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: theme.space.s0)
            Text(verbatim: way.state)
                .font(SettingsFont.footnote)
                .foregroundStyle(way.enabledCount > 0 ? theme.statusInk(.success) : theme.text.tertiary)
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, minHeight: theme.space.s64 + theme.space.s48, alignment: .topLeading)
        .settingsChrome(isHovered ? .cardHover : .card)
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(theme.motion.quick) { isHovered = hovering } }
        .pointingHandCursor()
    }
}
