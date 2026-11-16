//
//  WorkflowsHomeSections.swift
//  osaurus
//
//  Home's sections under Running Now: what needs you, the pinned
//  workflows as tiles with Run, and every automation that runs a workflow
//  with its switch. Until the person has an automation, a few ways to
//  start one instead. Each hides when it has nothing to show.
//

import AppKit
import SwiftUI

/// "1 running now. 4 run on their own." under Home's title.
struct WorkflowsHomeSubtitle: View {
    @Environment(\.theme) private var theme
    @ObservedObject var overview: WorkflowsOverviewModel
    @ObservedObject private var installed = InstalledWorkflowStore.shared
    @ObservedObject private var live = WorkflowLiveRuns.shared

    var body: some View {
        let model = WorkflowsHomeModel.make(workflows: installed.workflows, automations: overview.automationFacts)
        Text(
            verbatim: WorkflowsHomeModel.subtitle(
                runOnOwn: model.runOnOwnCount, attention: model.attentionCount, running: live.going.count)
        )
        .font(SettingsFont.rowDescription)
        .foregroundStyle(theme.text.secondary)
        .animation(theme.motion.quick, value: live.going.count)
    }
}

struct WorkflowsHomeSections: View {
    @Environment(\.theme) private var theme
    let windowState: ChatWindowState
    @ObservedObject var overview: WorkflowsOverviewModel
    @ObservedObject private var installed = InstalledWorkflowStore.shared
    /// Redraws when a run starts, moves a step or ends, never per streamed word.
    @ObservedObject private var live = WorkflowLiveRuns.shared

    let onRun: (InstalledWorkflow) -> Void
    let onSetUp: (InstalledWorkflow) -> Void
    let onAllActivity: () -> Void

    @State private var editorRequest: EventEditorRequest?
    /// Bumps once the recorded runs load, so the tiles read them.
    @State private var recordedCount = -1

    private static var wayLimit: Int { 4 }

    var body: some View {
        let _ = recordedCount
        let runs = WorkflowRunStore.shared
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
            if !model.groups.isEmpty { automations(model) }
            if model.groups.isEmpty, model.otherAutomationCount == 0, !installed.workflows.isEmpty {
                ways(Array(model.ways.prefix(Self.wayLimit)))
            }
        }
        .task { await runs.loadRecentRunsIfNeeded() }
        .onReceive(WorkflowRunStore.shared.$recentPersisted.map { $0?.count ?? -1 }.removeDuplicates()) {
            recordedCount = $0
        }
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
        SettingsSection(title: "Needs Attention", layout: .plain) {
            if all.count > WorkflowActivityFeed.attentionLimit {
                WorkflowTextLink(title: L("See all")) {
                    windowState.showWorkflowsActivity(.init(filter: .needsAttention))
                }
            }
        } content: {
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
        SettingsSection(title: "Pinned", layout: .plain) {
            WorkflowCardGrid(items: tiles) { tile in
                WorkflowsPinnedTile(
                    tile: tile,
                    onOpen: { windowState.selectWorkflowsPage(.workflow(tile.id)) },
                    onRun: { if let workflow = installed.workflow(id: tile.id) { onRun(workflow) } })
            }
        }
    }

    // MARK: Your automations

    private func automations(_ model: WorkflowsHomeModel) -> some View {
        SettingsSection(title: "Your Automations", layout: .plain) {
            WorkflowTextLink(title: L("See all"), action: onAllActivity)
                .help(L("What your automations ran"))
        } content: {
            WorkflowRowList(items: model.groups.flatMap(\.rows)) { row in
                WorkflowsHomeAutomationRow(row: row) {
                    windowState.showWorkflowAutomation(workflowID: row.workflowID, intent: .highlight(row.id))
                }
            }
        }
        .id(WorkflowsHomeSection.runningOnTheirOwn)
        .settingsLandingAnchor("workflows.runningOnTheirOwn")
    }

    // MARK: Ways to automate

    /// Until the person has an automation: a few moments to start one at,
    /// each asking which workflow next.
    private func ways(_ ways: [WorkflowsHomeModel.Way]) -> some View {
        SettingsSection(title: "Ways to Automate", subtitle: "Pick a moment, then a workflow.", layout: .plain) {
            WorkflowCardGrid(items: ways) { way in
                Menu {
                    workflowPicker(for: way.item.entry)
                } label: {
                    WorkflowsWayCard(way: way)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
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
                    SettingsButton(.secondary, "See What Happened", size: .small, action: onSeeWhatHappened)
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
        .frame(maxWidth: .infinity, minHeight: theme.space.s64 + theme.space.s32, maxHeight: .infinity, alignment: .topLeading)
        .settingsChrome(isHovered ? .cardHover : .card)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering in withAnimation(theme.motion.quick) { isHovered = hovering } }
        .pointingHandCursor()
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Open", bundle: .module), onOpen)
    }
}

/// "Mail Triage runs every weekday at 8:00 AM", how it last went, and its switch.
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
                (Text(verbatim: row.workflowName).fontWeight(.medium) + Text(verbatim: " " + row.sentence))
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
            Toggle(
                L("\(row.workflowName) automation"),
                isOn: Binding(
                    get: { row.event.isEnabled },
                    set: { EventManager.shared.setEnabled(row.event.id, enabled: $0) })
            )
            .settingsSwitch()
        }
        .padding(.horizontal, theme.space.s16)
        .padding(.vertical, theme.space.s12)
        .background { if isHovered { theme.surface.hover } }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering in withAnimation(theme.motion.quick) { isHovered = hovering } }
        .pointingHandCursor()
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Open the workflow", bundle: .module), onOpen)
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
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, minHeight: theme.space.s64 + theme.space.s32, maxHeight: .infinity, alignment: .topLeading)
        .settingsChrome(isHovered ? .cardHover : .card)
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(theme.motion.quick) { isHovered = hovering } }
        .pointingHandCursor()
    }
}
