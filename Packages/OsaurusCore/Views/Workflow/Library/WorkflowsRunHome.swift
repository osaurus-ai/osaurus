//
//  WorkflowsRunHome.swift
//  osaurus
//
//  The Workflows window's home: the title with Import and New Workflow,
//  what is running now, from here, from an agent, or from an automation,
//  and at the foot what this Mac has published. Every workflow, draft and
//  workspace lists in the sidebar, not here.
//

import SwiftUI

extension WorkflowsView {
    var workflowsHome: some View {
        VStack(alignment: .leading, spacing: theme.space.s32) {
            homeHeader
            WorkflowsRunningNow(onOpen: openRun)
            PublishedByYouLine(kind: .workflow, anchor: "workflows.publishedByYou")
        }
    }

    /// The title with Import and New Workflow, then links to what
    /// workflows use and what starts them.
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
