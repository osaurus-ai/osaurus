//
//  WorkflowInstallerView.swift
//  osaurus
//
//  Adding a workflow, for someone who just wants it to work. Four screens:
//  Ready says what Osaurus will get ready, Questions asks only what needs
//  the person (one step at a time, and never when nothing does),
//  Installing shows the real progress, and Done offers to try it.
//
//  Installing runs in `WorkflowInstallCoordinator`, not here: closing the
//  sheet (or Esc) while it runs only minimises it to a toast and a row on
//  Workflows Home. Only Cancel Install stops it, after asking.
//
//  The rail wizard (`WorkflowSetupWizardView`) stays for Set Up, Update and
//  test runs, where someone adjusts a workflow rather than adds one.
//

import AppKit
import SwiftUI

struct WorkflowInstallerView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var coordinator: WorkflowInstallCoordinator

    let subject: WorkflowSetupSubject
    let onClose: () -> Void

    init(
        subject: WorkflowSetupSubject, coordinator: WorkflowInstallCoordinator = .shared,
        onClose: @escaping () -> Void
    ) {
        self.subject = subject
        self.coordinator = coordinator
        self.onClose = onClose
    }

    typealias Step = WorkflowSetupWizardView.Step

    enum Screen: Hashable {
        case preparing
        case ready
        case question(Int)
        case installing
        case done
        case problem
    }

    @State private var working: WorkflowSetupSubject?
    @State private var report: SetupReport?
    @State private var plan: WorkflowInstallPlan?
    /// The check the plan was made from, so the questions a set-aside
    /// download brings back stay put while the person answers them.
    @State private var planReport: SetupReport?
    @State private var included: Set<String> = []
    /// Slots whose suggested model the person won't download: they pick
    /// another model in the Models question.
    @State private var choosingSlots: Set<String> = []
    /// Slots left for after the install, which then reads Needs setup.
    @State private var skippedSlots: Set<String> = []
    @State private var freeBytes: Int64?
    @State private var screen: Screen = .preparing
    @State private var direction: OnboardingDirection = .forward
    @State private var warning: String?
    @State private var showsDetails = false
    @State private var confirmingCancel = false
    @State private var announcedDone = false

    private var job: WorkflowInstallCoordinator.Job? { coordinator.job(forTemplate: subject.template.id) }
    private var name: String { working?.name ?? subject.name }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            SettingsSheetHeader(
                icon: "arrow.down.circle", title: "Add Workflow", subtitleText: name, onClose: close)
            ZStack {
                content
                    .id(screen)
                    .transition(OnboardingMotion.pushFade(direction: direction, reduceMotion: reduceMotion))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            footer
        }
        .fittedSheetFrame(width: SettingsSheetWidth.regular, height: 600)
        .settingsSheetSurface()
        .themedAlert(
            L("Cancel Install?"), isPresented: $confirmingCancel,
            message: L("Downloads Osaurus started for \(name) stop, and the workflow is not added."),
            primaryButton: .destructive(L("Cancel Install"), action: cancelInstall),
            secondaryButton: .cancel(L("Keep Installing")), presentationStyle: .contained)
        .onAppear {
            coordinator.setPresented(subject.template.id, true)
            Task { await prepare() }
        }
        .onDisappear { coordinator.setPresented(subject.template.id, false) }
        .onReceive(coordinator.$jobs) { _ in DispatchQueue.main.async { followJob() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        .onReceive(ModelPickerItemCache.shared.$items.dropFirst()) { _ in refresh() }
    }

    // MARK: - Screens

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .preparing:
            VStack(spacing: theme.space.s12) {
                SettingsSpinner(size: .large)
                Text("Looking at what it needs…", bundle: .module)
                    .textStyle(.body)
                    .foregroundColor(theme.text.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            scrolling { ready }
        case .question(let index):
            scrolling { question(index) }
        case .installing:
            scrolling {
                if let job {
                    WorkflowInstallProgressView(job: job, coordinator: coordinator, showsDetails: $showsDetails)
                }
            }
        case .done:
            done
        case .problem:
            scrolling { problem }
        }
    }

    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space.s20) { content() }
                .padding(theme.settingsSheetInset)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var ready: some View {
        if let plan {
            let chosen = chosenPlan(plan)
            VStack(alignment: .leading, spacing: theme.space.s6) {
                Text(verbatim: name)
                    .font(SettingsFont.detailTitle)
                    .foregroundColor(theme.text.primary)
                if let summary = subject.template.summary, !summary.isEmpty {
                    Text(verbatim: summary)
                        .textStyle(.body)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onboardingEntrance(0)
            if chosen.items.isEmpty {
                Label {
                    if chosen.questionSteps().isEmpty && skippedSlots.isEmpty {
                        Text("Everything it needs is already on this Mac.", bundle: .module)
                    } else {
                        Text("Nothing to download.", bundle: .module)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(theme.status.success.foreground)
                }
                .textStyle(.body)
                .foregroundColor(theme.text.primary)
                .onboardingEntrance(1)
            } else {
                VStack(alignment: .leading, spacing: theme.space.s12) {
                    Text("Osaurus will get these ready for you", bundle: .module)
                        .textStyle(.label, weight: 600)
                        .foregroundColor(theme.text.primary)
                        .onboardingEntrance(1)
                    SettingsProgressChecklist(
                        items: chosen.items.map {
                            SettingsChecklistItem(id: $0.id, title: $0.title, detail: Self.size($0.sizeBytes), state: .waiting)
                        })
                    modelDownloadChoices(chosen)
                }
            }
            setAsideModels
            VStack(alignment: .leading, spacing: theme.space.s6) {
                let questions = chosen.questionSteps().count
                if questions > 0 {
                    Text(
                        verbatim: questions == 1
                            ? L("One quick question first.") : L("\(questions) quick questions first."))
                        .textStyle(.body)
                        .foregroundColor(theme.text.primary)
                }
                if let line = sizeLine(chosen) {
                    Text(verbatim: line)
                        .textStyle(.caption)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onboardingEntrance(chosen.items.count + 2)
            let trimmed = withoutSetAside(plan)
            if !trimmed.items.isEmpty || !trimmed.optional.isEmpty { readyDetails(trimmed) }
        }
    }

    /// A suggested text model the install would download: the person may
    /// pick another model instead, or leave the slot for later.
    @ViewBuilder
    private func modelDownloadChoices(_ chosen: WorkflowInstallPlan) -> some View {
        let downloads = chosen.items.filter { item in
            guard case .chatModel = item.work, !included.contains(item.id) else { return false }
            return !(chosen.chatSlots[item.id] ?? []).isEmpty
        }
        ForEach(downloads) { item in
            let slots = (chosen.chatSlots[item.id] ?? []).filter { !choosingSlots.contains($0) && !skippedSlots.contains($0) }
            HStack(spacing: theme.space.s8) {
                Text(verbatim: downloads.count == 1 ? L("Rather not download it?") : item.title)
                    .textStyle(.caption)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(1)
                Spacer(minLength: theme.space.s8)
                if slots.allSatisfy(canChooseAnother) {
                    SettingsButton(.tertiary, "Choose Another Model", size: .compact) {
                        setAside(slots, skipping: false)
                    }
                }
                SettingsButton(.tertiary, "Skip for Now", size: .compact) {
                    setAside(slots, skipping: true)
                }
            }
        }
    }

    /// Slots the person took out of the download, each with Undo.
    @ViewBuilder
    private var setAsideModels: some View {
        let slots = (working?.template.requirements.models ?? []).map(\.slot)
            .filter { choosingSlots.contains($0) || skippedSlots.contains($0) }
        if !slots.isEmpty {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                ForEach(slots, id: \.self) { slot in
                    HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
                        Image(systemName: skippedSlots.contains(slot) ? "clock" : "arrow.triangle.swap")
                            .glyphSize(.caption, weight: .semibold)
                            .foregroundColor(theme.text.tertiary)
                        VStack(alignment: .leading, spacing: theme.space.s2) {
                            Text(verbatim: slotTitle(slot))
                                .textStyle(.caption, weight: 600)
                                .foregroundColor(theme.text.primary)
                            Text(
                                verbatim: skippedSlots.contains(slot)
                                    ? L("Skipped. The workflow reads Needs setup until you choose a model in its setup.")
                                    : L("You'll choose a model on the next screen.")
                            )
                            .textStyle(.caption)
                            .foregroundColor(theme.text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: theme.space.s8)
                        SettingsButton(.tertiary, "Undo", size: .compact) { restoreDownload(slot) }
                    }
                }
            }
            .padding(theme.space.s12)
            .settingsChrome(.inset)
        }
    }

    /// Shown above the Models question for a slot the person chose to fill
    /// with a model other than the one the workflow suggests.
    @ViewBuilder
    private func otherModelDisclaimer(_ template: Template, asked: [SetupItem]) -> some View {
        let slots = template.requirements.models.filter { slot in
            choosingSlots.contains(slot.slot) && asked.contains { $0.kind == .model && $0.value == slot.slot }
        }
        ForEach(slots) { slot in
            let suggested = WorkflowModelChoices.suggested(slot).map(WorkflowModelChoices.displayName) ?? L("its suggested model")
            SettingsCallout(
                icon: "exclamationmark.triangle",
                title: L("This workflow was made for \(suggested)"),
                message: L(
                    "Another model can run it, but results may differ from what its author tested, and smaller models may struggle with some steps."
                ),
                tone: .warning
            ) {
                SettingsButton(.secondary, L("Download \(suggested) Instead"), size: .compact, verbatim: true) {
                    restoreDownload(slot.slot)
                    go(.ready)
                }
            }
        }
    }

    private func readyDetails(_ plan: WorkflowInstallPlan) -> some View {
        DisclosureGroup(isExpanded: $showsDetails) {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                ForEach(plan.items) { item in
                    detailLine(item.title, item.detail)
                }
                ForEach(plan.optional) { item in
                    SettingsToggle(
                        title: L("Also download \(item.detail)"),
                        description: [L("Suggested. Until it's here, your default model runs these steps."), Self.size(item.sizeBytes)]
                            .compactMap { $0 }.joined(separator: " "),
                        style: .checkbox, verbatim: true,
                        isOn: Binding(
                            get: { included.contains(item.id) },
                            set: { on in
                                if on { included.insert(item.id) } else { included.remove(item.id) }
                            }))
                }
            }
            .padding(.top, theme.space.s8)
        } label: {
            Text("Details", bundle: .module)
                .textStyle(.caption, weight: 600)
                .foregroundColor(theme.text.secondary)
        }
    }

    private func detailLine(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s2) {
            Text(verbatim: title)
                .textStyle(.caption, weight: 600)
                .foregroundColor(theme.text.secondary)
            Text(verbatim: detail)
                .textStyle(.caption)
                .monospaced()
                .foregroundColor(theme.text.tertiary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func question(_ index: Int) -> some View {
        let steps = questionSteps
        if let working, let report, steps.indices.contains(index) {
            let step = steps[index]
            let items = askedItems(step, in: report)
            VStack(alignment: .leading, spacing: theme.space.s4) {
                if steps.count > 1 {
                    Text(verbatim: L("\(index + 1) of \(steps.count)"))
                        .textStyle(.caption, weight: 600)
                        .foregroundColor(theme.text.tertiary)
                        .monospacedDigit()
                }
                Text(verbatim: Self.questionTitle(step))
                    .font(SettingsFont.detailTitle)
                    .foregroundColor(theme.text.primary)
            }
            switch step {
            case .models:
                otherModelDisclaimer(working.template, asked: items)
                WorkflowModelsStep(
                    template: working.template, bindings: working.bindings, items: items,
                    onlySlots: Set(items.filter { $0.kind == .model }.map(\.value)),
                    setModel: { slot, model in setBindings { $0.models[slot] = model } },
                    onLeave: leave)
            case .secrets:
                WorkflowSecretsStep(
                    secrets: working.template.requirements.secrets.filter { secret in items.contains { $0.value == secret.key } },
                    scope: working.subjectID, bindings: working.bindings, items: items, reconfirm: [],
                    workflowName: working.template.name,
                    onSaved: { key, account in setBindings { $0.secrets[key] = account } })
            case .folders:
                WorkflowFoldersStep(
                    folders: working.template.requirements.folders, bindings: working.bindings, items: items,
                    onChoose: { key, path in setBindings { $0.folders[key] = path } })
            case .apps:
                WorkflowAppsStep(
                    apps: working.template.requirements.apps, items: items, onCheckAgain: { refresh() })
            case .agents:
                WorkflowAgentsStep(
                    agents: working.template.requirements.agents, bindings: working.bindings, items: items,
                    allowsWithoutAsking: working.agentStepsAllowed,
                    onSetAllowsWithoutAsking: { on in self.working?.agentStepsAllowed = on },
                    onAllowed: { refresh() },
                    onChoose: { id, target in setBindings { $0.agents[id] = target } })
            case .tools:
                WorkflowToolsStep(
                    items: items, template: working.template, bindings: working.bindings,
                    onBindServer: { name, local in setBindings { $0.mcpServers[name] = local } },
                    onLeave: leave, onCheckAgain: { refresh() })
            case .dependencies:
                WorkflowDependenciesStep(
                    dependencies: working.template.requirements.dependencies, environmentID: working.template.id,
                    items: items, onLeave: leave, onChanged: { refresh() })
            case .permissions:
                PermissionsStep(
                    items: items, doneText: L("Every permission this workflow needs is granted."),
                    onChanged: { refresh() })
            case .answers, .review:
                EmptyView()
            }
        }
    }

    /// The install finished with a model slot left for later.
    private var finishedWithSkippedModel: Bool { !(job?.deferredSlots.isEmpty ?? true) }

    private var done: some View {
        VStack(spacing: theme.space.s16) {
            SettingsCompletionMark(size: 64)
            Text(verbatim: finishedWithSkippedModel ? L("\(name) is added") : L("\(name) is ready"))
                .font(SettingsFont.detailTitle)
                .foregroundColor(theme.text.primary)
                .multilineTextAlignment(.center)
                .onboardingEntrance(1, baseDelay: 0.35)
            Text(
                verbatim: finishedWithSkippedModel
                    ? L("It's in Your Workflows. Choose a model in its setup before you run it.")
                    : L("It's in Your Workflows whenever you need it.")
            )
                .textStyle(.body)
                .foregroundColor(theme.text.secondary)
                .multilineTextAlignment(.center)
                .onboardingEntrance(2, baseDelay: 0.35)
        }
        .padding(theme.settingsSheetInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: announceDone)
    }

    @ViewBuilder
    private var problem: some View {
        if let job, case .failed = job.phase {
            Label {
                VStack(alignment: .leading, spacing: theme.space.s6) {
                    Text("Something stopped the install", bundle: .module)
                        .textStyle(.label, weight: 600)
                        .foregroundColor(theme.text.primary)
                    Text("Osaurus already tried again on its own. You can try once more, or cancel the install.", bundle: .module)
                        .textStyle(.body)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .glyphSize(.body)
                    .foregroundColor(theme.status.warning.foreground)
            }
            SettingsProgressChecklist(items: WorkflowInstallProgressView.checklist(job), entrance: false)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        switch screen {
        case .preparing:
            SettingsSheetFooter(secondary: .init(label: "Cancel", handler: onClose))
        case .ready:
            let refusal = plan.flatMap { chosenPlan($0).storageRefusal(freeBytes: freeBytes) }
            SettingsSheetFooter(
                primary: .init(
                    label: questionSteps.isEmpty ? "Install" : "Continue", isEnabled: plan != nil && refusal == nil,
                    handler: fromReady),
                secondary: .init(label: "Cancel", handler: onClose),
                warning: refusal ?? warning)
        case .question(let index):
            SettingsSheetFooter(
                primary: .init(label: index == questionSteps.count - 1 ? "Install" : "Continue", handler: { answer(index) }),
                secondary: .init(label: index > 0 || !skipsReady ? "Back" : job == nil ? "Cancel" : "Close", handler: { back(from: index) }),
                warning: warning)
        case .installing:
            SettingsSheetFooter(
                secondary: .init(label: "Continue in Background", handler: onClose),
                destructive: .init(label: "Cancel Install", handler: { confirmingCancel = true }))
        case .done:
            if finishedWithSkippedModel {
                SettingsSheetFooter(primary: .init(label: "Done", handler: finishDone))
            } else {
                SettingsSheetFooter(
                    primary: .init(label: "Try It", handler: tryIt),
                    secondary: .init(label: "Done", handler: finishDone))
            }
        case .problem:
            SettingsSheetFooter(
                primary: .init(label: "Try Again", handler: retry),
                secondary: .init(label: "Close", handler: onClose),
                destructive: .init(label: "Cancel Install", handler: { confirmingCancel = true }))
        }
    }

    // MARK: - Flow

    private func prepare() async {
        guard working == nil else { return }
        if let job {
            working = job.subject
            skippedSlots = job.deferredSlots
            refresh()
            followJob()
            return
        }
        working = subject
        refresh()
        guard let working, let report else { return }
        let built = await WorkflowInstallPlan.live(template: working.template, bindings: working.bindings, report: report)
        freeBytes = WorkflowInstallPlan.liveFreeBytes()
        planReport = report
        plan = built
        go(skipsReady ? .question(0) : .ready)
    }

    /// With nothing to fetch, Ready would only repeat that; the installer
    /// opens on the first question instead.
    private var skipsReady: Bool {
        guard let plan else { return true }
        return plan.items.isEmpty && plan.optional.isEmpty && !questionSteps.isEmpty
    }

    /// Moves to the screen the coordinator's job is on.
    private func followJob() {
        guard let job else { return }
        switch job.phase {
        case .running:
            if screen != .installing { go(.installing) }
        case .needsYou:
            if case .question = screen { return }
            if working == nil || working?.template.id != job.subject.template.id { working = job.subject }
            refresh()
            plan = nil
            go(questionSteps.isEmpty ? .installing : .question(0))
        case .failed:
            if screen != .problem { go(.problem) }
        case .done:
            if screen != .done { go(.done) }
        }
    }

    private func go(_ next: Screen) {
        warning = nil
        direction = order(next) >= order(screen) ? .forward : .backward
        withAnimation(reduceMotion ? theme.motion.quick : OnboardingMotion.gentle) { screen = next }
    }

    private func order(_ screen: Screen) -> Int {
        switch screen {
        case .preparing: return 0
        case .ready: return 1
        case .question(let index): return 2 + index
        case .installing, .problem: return 100
        case .done: return 101
        }
    }

    private func fromReady() {
        if questionSteps.isEmpty { install() } else { go(.question(0)) }
    }

    private func answer(_ index: Int) {
        refresh()
        let steps = questionSteps
        guard let report, steps.indices.contains(index) else { return install() }
        if let blocker = askedItems(steps[index], in: report).first(where: \.isBlocking) {
            withAnimation(theme.motion.quick) { warning = blocker.detail }
            return
        }
        if index + 1 < steps.count { go(.question(index + 1)) } else { install() }
    }

    private func back(from index: Int) {
        if index > 0 {
            go(.question(index - 1))
        } else if !skipsReady {
            go(.ready)
        } else {
            onClose()
        }
    }

    private func install() {
        guard let working else { return }
        if let job, job.phase == .needsYou {
            coordinator.update(job.id, subject: working)
            if let report = coordinator.recheck(job.id), let blocker = report.blocking.first {
                withAnimation(theme.motion.quick) { warning = blocker.detail }
            }
            return
        }
        guard let plan else { return }
        coordinator.start(working, items: chosenPlan(plan).items, deferring: skippedSlots)
        followJob()
    }

    // MARK: - Suggested models

    /// A slot locked to its model (`always`) can only wait, not change.
    private func canChooseAnother(_ slot: String) -> Bool {
        working?.template.requirements.models.first { $0.slot == slot }?.requiredModel == nil
    }

    private func slotTitle(_ slot: String) -> String {
        let steps = WorkflowSummary.slotSteps(slot, in: working?.template.workflow)
        return steps.isEmpty ? L("Text model") : L("Text model for \(WorkflowSummary.list(steps))")
    }

    private func setAside(_ slots: [String], skipping: Bool) {
        withAnimation(theme.motion.quick) {
            if skipping { skippedSlots.formUnion(slots) } else { choosingSlots.formUnion(slots) }
            warning = nil
        }
    }

    /// Puts the suggested model back in the download and drops any other
    /// model picked for the slot meanwhile.
    private func restoreDownload(_ slot: String) {
        withAnimation(theme.motion.quick) {
            choosingSlots.remove(slot)
            skippedSlots.remove(slot)
        }
        if working?.bindings.models[slot] != nil { setBindings { $0.models[slot] = nil } }
    }

    private func cancelInstall() {
        if let job { coordinator.cancel(job.id) }
        onClose()
    }

    private func retry() {
        if let job { coordinator.retry(job.id) }
    }

    private func tryIt() {
        guard let job else { return onClose() }
        WorkflowInstallCoordinator.tryIt(job)
        coordinator.dismiss(job.id)
        onClose()
    }

    private func finishDone() {
        if let job { coordinator.dismiss(job.id) }
        onClose()
    }

    /// The close button and Esc: a running install keeps going.
    private func close() {
        if screen == .done { return finishDone() }
        onClose()
    }

    private func announceDone() {
        guard !announcedDone else { return }
        announcedDone = true
        AccessibilityNotification.Announcement(L("\(name) is ready")).post()
    }

    // MARK: - Answers

    private func refresh() {
        guard var working else { return }
        let bound = MCPServerResolution.liveAutoBindings(for: working.template, bindings: working.bindings)
        if bound != working.bindings {
            working.bindings = bound
            self.working = working
        }
        report = SetupChecker.check(
            working.template, bindings: working.bindings, subjectId: working.subjectID, secrets: .install,
            attended: true)
    }

    private func setBindings(_ change: (inout InstallBindings) -> Void) {
        guard var w = working else { return }
        change(&w.bindings)
        working = w
        withAnimation(theme.motion.quick) { warning = nil }
        refresh()
    }

    /// Stepping aside to another tab parks the installer with its answers.
    private func leave(to tab: ManagementTab) {
        if let working, job == nil {
            ManagementStateManager.shared.pendingSetupSubject = .workflow(working)
            ParkedWorkflowSetupWatcher.shared.watchParked()
        }
        onClose()
        AppDelegate.shared?.showManagementWindow(initialTab: tab)
    }

    /// Report items the installer does not take care of itself.
    private var covered: Set<String> {
        guard let plan else { return [] }
        return Set(chosenPlan(plan).items.flatMap(\.covers))
    }

    private func askedItems(_ step: Step, in report: SetupReport) -> [SetupItem] {
        step.items(in: report).filter {
            !covered.contains($0.id) && ($0.isBlocking || $0.isMissingKey)
                && !($0.kind == .model && skippedSlots.contains($0.value))
        }
    }

    /// The steps with something to ask, from the latest check. A step
    /// answered along the way stays, so the count does not jump.
    private var questionSteps: [Step] {
        guard let report else { return [] }
        let order: [Step] = [.models, .secrets, .folders, .apps, .agents, .tools, .dependencies, .permissions]
        let planned = Set(plan.map { chosenPlan($0).questionSteps() } ?? [])
        return order.filter { planned.contains($0) || !askedItems($0, in: report).isEmpty }
    }

    private func chosenPlan(_ plan: WorkflowInstallPlan) -> WorkflowInstallPlan {
        withoutSetAside(included.reduce(plan) { $0.including($1) })
    }

    private func withoutSetAside(_ plan: WorkflowInstallPlan) -> WorkflowInstallPlan {
        guard let planReport else { return plan }
        return plan.withoutDownloads(for: choosingSlots, deferring: skippedSlots, report: planReport)
    }

    // MARK: - Words

    static func questionTitle(_ step: Step) -> String {
        switch step {
        case .models: return L("Choose a model")
        case .secrets: return L("Add a key")
        case .folders: return L("Choose a folder")
        case .apps: return L("Install an app")
        case .agents: return L("Choose who it asks")
        case .tools: return L("Connect its tools")
        case .dependencies: return L("Let it reach the internet")
        case .permissions: return L("Allow access")
        case .answers, .review: return step.title
        }
    }

    static func size(_ bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func sizeLine(_ plan: WorkflowInstallPlan) -> String? {
        guard plan.totalBytes > 0, let total = Self.size(plan.totalBytes) else { return nil }
        guard let free = Self.size(freeBytes) else { return L("About \(total) to download.") }
        return L("About \(total) to download. \(free) is free on this Mac.")
    }
}

// MARK: - Installing

/// A running install: one bar, what is happening now, the time left, and
/// the checklist ticking off. The installer and the bundle setup share it.
struct WorkflowInstallProgressView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var coordinator: WorkflowInstallCoordinator

    let job: WorkflowInstallCoordinator.Job
    @Binding var showsDetails: Bool

    init(
        job: WorkflowInstallCoordinator.Job, coordinator: WorkflowInstallCoordinator = .shared,
        showsDetails: Binding<Bool>
    ) {
        self.job = job
        self.coordinator = coordinator
        self._showsDetails = showsDetails
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s20) {
            Text(verbatim: L("Getting \(job.name) ready"))
                .font(SettingsFont.detailTitle)
                .foregroundColor(theme.text.primary)
            VStack(alignment: .leading, spacing: theme.space.s8) {
                SettingsProgressBar(value: job.progress, height: 6)
                    .accessibilityLabel(Text(verbatim: L("Installing \(job.name)")))
                HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
                    Text(verbatim: job.activity)
                        .textStyle(.body)
                        .foregroundColor(theme.text.primary)
                        .contentTransition(.opacity)
                    Spacer(minLength: theme.space.s8)
                    Text(verbatim: "\(Int((job.progress * 100).rounded(.down)))%")
                        .textStyle(.body, weight: 600)
                        .monospacedDigit()
                        .foregroundColor(theme.text.secondary)
                        .contentTransition(.numericText(value: job.progress))
                }
                if let remaining = job.remaining {
                    Text(verbatim: WorkflowInstallCoordinator.remainingText(remaining))
                        .textStyle(.caption)
                        .monospacedDigit()
                        .foregroundColor(theme.text.tertiary)
                        .contentTransition(.numericText())
                }
            }
            .animation(theme.motion.standard, value: job.progress)
            .animation(theme.motion.standard, value: job.remaining)
            SettingsProgressChecklist(items: Self.checklist(job))
            Label {
                Text("You can keep using Osaurus. We'll tell you when it's ready.", bundle: .module)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "sparkles").foregroundColor(theme.status.info.foreground)
            }
            .textStyle(.caption)
            .foregroundColor(theme.text.secondary)
            details
        }
    }

    private var details: some View {
        DisclosureGroup(isExpanded: $showsDetails) {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                ForEach(job.items) { item in
                    VStack(alignment: .leading, spacing: theme.space.s2) {
                        Text(verbatim: item.title)
                            .textStyle(.caption, weight: 600)
                            .foregroundColor(theme.text.secondary)
                        Text(verbatim: technicalLine(item))
                            .textStyle(.caption)
                            .monospaced()
                            .foregroundColor(theme.text.tertiary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.top, theme.space.s8)
        } label: {
            Text("Details", bundle: .module)
                .textStyle(.caption, weight: 600)
                .foregroundColor(theme.text.secondary)
        }
    }

    private func technicalLine(_ item: WorkflowInstallPlan.Item) -> String {
        var parts = [item.detail]
        if let transfer = coordinator.transfer(of: item, in: job), let received = transfer.received {
            let total = transfer.total.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            let got = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
            parts.append(total.map { "\(got) / \($0)" } ?? got)
            if let speed = transfer.bytesPerSecond, speed > 0 {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s")
            }
        }
        return parts.joined(separator: " · ")
    }

    static func checklist(_ job: WorkflowInstallCoordinator.Job) -> [SettingsChecklistItem] {
        job.items.map { item in
            let state: SettingsChecklistItem.State
            var detail = WorkflowInstallerView.size(item.sizeBytes)
            switch job.state(of: item) {
            case .waiting: state = .waiting
            case .working: state = .working
            case .done: state = .done
            case .failed(let message):
                state = .failed
                detail = message
            }
            return SettingsChecklistItem(id: item.id, title: item.title, detail: detail, state: state)
        }
    }
}
