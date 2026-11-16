//
//  WorkflowsRunHome.swift
//  osaurus
//
//  The Workflows window's home: the title with New Workflow (everything
//  else in ⋯), what is running now, from here, from an agent, or from an
//  automation, then what needs you and your workflows. Every workflow,
//  draft and workspace lists in the sidebar, not here.
//

import SwiftUI

extension WorkflowsView {
    var workflowsHome: some View {
        VStack(alignment: .leading, spacing: theme.space.s32) {
            homeHeader
            WorkflowsRunningNow(onOpen: openRun)
            WorkflowsHomeSections(
                windowState: windowState, overview: windowState.workflowsOverview,
                onRun: { workflow in
                    if workflow.needsSetup { setupSubject = .setup(workflow) } else { play(workflow) }
                },
                onSetUp: { setupSubject = .setup($0) },
                onAllActivity: { windowState.showWorkflowsActivity(.init(filter: .ranOnTheirOwn)) })
            PublishedByYouLine(kind: .workflow, anchor: "workflows.publishedByYou")
        }
    }

    /// The title, New Workflow, and ⋯ for the rest; one line under it
    /// says what is going on.
    private var homeHeader: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            homeTitle(L("Workflows")) {
                SettingsButton(
                    .primary, "New Workflow", icon: "plus", size: .extraSmall,
                    help: "Describe a task and Osaurus builds it (⌘N)"
                ) {
                    withAnimation(theme.motion.quick) { windowState.showNewWorkflow() }
                }
                .settingsLandingAnchor("workflows.architect")
                homeMenu
            }
            WorkflowsHomeSubtitle(overview: windowState.workflowsOverview)
        }
    }

    private var homeMenu: some View {
        SettingsActionMenu(accessibilityLabel: L("More")) {
            Button(action: chooseFile) { Label(L("Import a Workflow File…"), systemImage: "square.and.arrow.down") }
            Divider()
            Button { showingConnections = true } label: { Label(L("Connections"), systemImage: "link") }
            Button {
                managementState.selectedTab = .automations
                AppDelegate.shared?.showManagementWindow(initialTab: .automations)
            } label: {
                Label(L("All Automations"), systemImage: "bolt")
            }
            Divider()
            Button { NSWorkspace.shared.open(WorkflowsSidebar.storeURL) } label: {
                Label(L("Browse the Store"), systemImage: "storefront")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .buttonStyle(SettingsIconButtonStyle(size: .standard, role: .tertiary))
        .fixedSize()
        .help(L("More"))
        .background(Color.clear.settingsLandingAnchor("workflows.importExport"))
        .background(Color.clear.settingsLandingAnchor("workflows.connections"))
        .background(Color.clear.settingsLandingAnchor("workflows.automations"))
    }
}

// MARK: - Running now

/// Runs going right now, whoever started them (you, an agent, an
/// automation), plus ones that ended moments ago. Waiting on you comes
/// first. Hidden when nothing is going.
struct WorkflowsRunningNow: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var live = WorkflowLiveRuns.shared
    @ObservedObject private var installed = InstalledWorkflowStore.shared
    let onOpen: (WorkflowLiveRuns.Summary) -> Void

    @State private var now = Date()

    static func shown(_ runs: some Sequence<WorkflowLiveRuns.Summary>, now: Date) -> [WorkflowLiveRuns.Summary] {
        runs.filter { run in
            guard let finished = run.finishedAt, !run.isGoing else { return run.isGoing }
            return now.timeIntervalSince(finished) < WorkflowRunPresentation.lingerInterval
        }
        .sorted { lhs, rhs in
            lhs.isWaitingOnYou != rhs.isWaitingOnYou
                ? lhs.isWaitingOnYou
                : lhs.isGoing != rhs.isGoing ? lhs.isGoing : lhs.startedAt > rhs.startedAt
        }
    }

    var body: some View {
        let shown = Self.shown(live.byRun.values, now: now)
        Group {
            if !shown.isEmpty {
                SettingsSection(title: "Running Now", layout: .plain) {
                    WorkflowRowList(items: shown) { run in
                        row(run)
                    }
                    .animation(theme.motion.standard, value: shown.map(\.id))
                }
                .settingsLandingAnchor("workflows.runningNow")
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(theme.motion.standard, value: shown.isEmpty)
        .task(id: nextExpiry(shown)) {
            guard let expiry = nextExpiry(shown) else { return }
            let wait = max(0, expiry.timeIntervalSinceNow) + 0.05
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            now = Date()
        }
        .onChange(of: live.byRun.count) { _, _ in now = Date() }
    }

    private func row(_ run: WorkflowLiveRuns.Summary) -> some View {
        let definition = installed.workflow(id: run.workflowID)?.definition
        return WorkflowRunRow(
            status: run.status, title: run.workflowName,
            line: run.isGoing
                ? run.progress(stepName: run.stepName(in: definition))
                : WorkflowRunPresentation.shortStatus(run.status),
            lineIsProblem: run.status == .failed,
            time: run.isGoing ? .elapsed(since: run.startedAt) : .none,
            onOpen: { onOpen(run) }
        ) {
            switch run.status {
            case .awaitingUser:
                SettingsButton(.primary, "Answer", size: .extraSmall) { onOpen(run) }
            case .running:
                SettingsButton(.secondary, "Stop", icon: "stop.fill", size: .extraSmall, help: "Stop this run") {
                    WorkflowRunService.shared.cancel(run.id)
                }
            default:
                EmptyView()
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// When the soonest-ending linger runs out, so the list drops it.
    private func nextExpiry(_ shown: [WorkflowLiveRuns.Summary]) -> Date? {
        shown.compactMap { run in
            run.isGoing ? nil : run.finishedAt?.addingTimeInterval(WorkflowRunPresentation.lingerInterval)
        }.min()
    }
}
