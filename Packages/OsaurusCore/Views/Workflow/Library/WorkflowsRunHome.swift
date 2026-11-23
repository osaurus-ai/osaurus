//
//  WorkflowsRunHome.swift
//  osaurus
//
//  The Workflows window's home: the title with New Workflow (everything
//  else in ⋯), Get Started while it has steps left, workflows being added
//  in the background, what is running now,
//  from here, from an agent, or from an automation, then what needs you,
//  your workflows, and the Store. Drafts and workspaces list in the
//  sidebar, not here.
//

import SwiftUI

extension WorkflowsView {
    var workflowsHome: some View {
        VStack(alignment: .leading, spacing: theme.space.s32) {
            homeHeader
            WorkflowsGetStarted(windowState: windowState, overview: windowState.workflowsOverview, onRun: runOrSetUp)
            WorkflowsInstalling()
            WorkflowsRunningNow(onOpen: openRun)
            WorkflowsHomeSections(
                windowState: windowState, overview: windowState.workflowsOverview,
                onRun: runOrSetUp,
                onSetUp: { setupSubject = .setup($0) },
                onAllActivity: { windowState.showWorkflowsActivity(.init(filter: .ranOnTheirOwn)) })
            WorkflowsStoreCard()
            PublishedByYouLine(kind: .workflow, anchor: "workflows.publishedByYou")
        }
    }

    private func runOrSetUp(_ workflow: InstalledWorkflow) {
        if workflow.needsSetup { setupSubject = .setup(workflow) } else { play(workflow) }
    }

    /// The title, New Workflow, and ⋯ for the rest; one line under it
    /// says what is going on.
    private var homeHeader: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            homeTitle(L("Workflows")) {
                SettingsButton(
                    .primary, "New Workflow", icon: "plus",
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
            Button { WorkflowsSidebar.openStore() } label: {
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

// MARK: - Store

/// The foot of Home: workflows other people made, on store.osaurus.ai.
struct WorkflowsStoreCard: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: theme.space.s12) {
            LibraryIcon(symbol: "storefront", tint: theme.text.secondary, size: theme.space.s32)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text("Find more in the Osaurus Store", bundle: .module)
                    .textStyle(.body, weight: 500)
                    .foregroundStyle(theme.text.primary)
                Text("Workflows other people made for mail, meetings, research and more, ready to add.", bundle: .module)
                    .font(SettingsFont.footnote)
                    .foregroundStyle(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SettingsButton(.secondary, "Browse the Store", icon: "arrow.up.right", size: .small) {
                WorkflowsSidebar.openStore()
            }
        }
        .padding(theme.space.s16)
        .settingsChrome(.card)
        .accessibilityElement(children: .contain)
        .settingsLandingAnchor("workflows.storeCard")
    }
}

// MARK: - Installing

/// Workflows being added in the background: their downloads and setup,
/// what needs the person, and what stopped. Show reopens the installer.
/// Hidden when nothing is being added; a finished one leaves for Your
/// Workflows.
struct WorkflowsInstalling: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var coordinator = WorkflowInstallCoordinator.shared
    @State private var cancelling: WorkflowInstallCoordinator.Job?

    private var shown: [WorkflowInstallCoordinator.Job] {
        coordinator.jobs.filter { if case .done = $0.phase { false } else { true } }
    }

    var body: some View {
        let shown = shown
        Group {
            if !shown.isEmpty {
                SettingsSection(title: "Installing", layout: .plain) {
                    WorkflowRowList(items: shown) { job in
                        row(job)
                    }
                    .animation(theme.motion.standard, value: shown.map(\.id))
                }
                .settingsLandingAnchor("workflows.installing")
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(theme.motion.standard, value: shown.isEmpty)
        .themedAlert(
            L("Cancel Install?"),
            isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }),
            message: cancelling.map { L("Downloads Osaurus started for \($0.name) stop, and the workflow is not added.") },
            primaryButton: .destructive(L("Cancel Install")) {
                if let job = cancelling { coordinator.cancel(job.id) }
                cancelling = nil
            },
            secondaryButton: .cancel(L("Keep Installing")))
    }

    private func row(_ job: WorkflowInstallCoordinator.Job) -> some View {
        WorkflowRunRow(
            status: Self.status(job.phase), title: job.name, line: Self.line(job),
            lineIsProblem: { if case .failed = job.phase { true } else { false } }(),
            onOpen: { WorkflowInstallCoordinator.show(job) }
        ) {
            switch job.phase {
            case .running:
                SettingsButton(.secondary, "Cancel", size: .extraSmall, help: "Stop adding this workflow") {
                    cancelling = job
                }
            case .needsYou:
                SettingsButton(.primary, "Answer", size: .extraSmall) { WorkflowInstallCoordinator.show(job) }
            case .failed:
                SettingsButton(.secondary, "Try Again", size: .extraSmall) { coordinator.retry(job.id) }
            case .done:
                EmptyView()
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    static func status(_ phase: WorkflowInstallCoordinator.Phase) -> WorkflowRunStatus {
        switch phase {
        case .running: return .running
        case .needsYou: return .awaitingUser
        case .failed: return .failed
        case .done: return .completed
        }
    }

    /// "42% · Downloading the image model · About 5 minutes left".
    static func line(_ job: WorkflowInstallCoordinator.Job) -> String {
        switch job.phase {
        case .running:
            return ["\(Int((job.progress * 100).rounded(.down)))%", job.activity,
                job.remaining.map(WorkflowInstallCoordinator.remainingText)]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case .needsYou: return L("Needs one more answer from you")
        case .failed(let message): return message
        case .done: return L("Ready")
        }
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
