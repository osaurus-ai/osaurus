//
//  WorkflowBundleSetupView.swift
//  osaurus
//
//  One setup pass for every workflow an agent template brings: model slots
//  and folders per workflow, then secrets, MCP servers, plugins, and
//  permissions asked once however many workflows need them. Install All
//  installs them all, or none while anything Osaurus can't fetch itself
//  still blocks. Models, the sandbox and packages it can fetch are handed
//  to `WorkflowInstallCoordinator`, one job per workflow, and their
//  progress shows here until they finish or the sheet goes to the
//  background.
//

import AppKit
import SwiftUI

/// The workflows of one bundle and what they need, merged.
struct WorkflowBundleSetup {
    var subjects: [WorkflowSetupSubject]

    /// Every secret any workflow needs, each key once.
    var secrets: [SecretRequirement] {
        var seen = Set<String>()
        return subjects.flatMap(\.template.requirements.secrets).filter { seen.insert($0.key).inserted }
    }

    /// Where the Secrets step writes a value entered once for the bundle.
    /// `bindSecret` copies it into every workflow that needs the key;
    /// `discardScratch` removes it when the pass ends.
    let scratchScope = UUID()

    /// The binding a shared secret shows: the first workflow's that has one.
    var secretBindings: InstallBindings {
        var merged = InstallBindings()
        for subject in subjects {
            for (key, account) in subject.bindings.secrets where merged.secrets[key] == nil {
                merged.secrets[key] = account
            }
        }
        return merged
    }

    /// A secret saved once (into the scratch scope) is copied to every
    /// workflow that needs it and bound under that workflow's own account.
    mutating func bindSecret(_ key: String, account: String) {
        for i in subjects.indices where subjects[i].template.requirements.secrets.contains(where: { $0.key == key }) {
            let scope = subjects[i].subjectID
            if WorkflowCredentials.copy(key: key, from: scratchScope, to: scope) {
                subjects[i].bindings.secrets[key] = WorkflowSecretsKeychain.secretAccount(scope: scope, key: key)
            }
        }
    }

    func discardScratch() {
        WorkflowCredentials.forget(keys: secrets.map(\.key), scope: scratchScope)
    }

    /// Every MCP server any workflow names, each once, in first-seen order.
    var serverNames: [String] {
        var seen = Set<String>()
        return subjects.flatMap(\.template.requirements.mcpServers).filter { seen.insert($0).inserted }
    }

    /// The first workflow naming `server`; its card stands for all of them.
    func owner(ofServer server: String) -> Int? {
        subjects.firstIndex { $0.template.requirements.mcpServers.contains(server) }
    }

    /// A server picked once binds on every workflow that names it.
    mutating func bindServer(_ server: String, to local: String?) {
        for i in subjects.indices where subjects[i].template.requirements.mcpServers.contains(server) {
            subjects[i].bindings.mcpServers[server] = local
        }
    }

    @MainActor
    mutating func applyAutoBindings() {
        for i in subjects.indices {
            subjects[i].bindings = MCPServerResolution.liveAutoBindings(
                for: subjects[i].template, bindings: subjects[i].bindings)
        }
    }

    @MainActor
    func reports() -> [SetupReport] {
        subjects.map {
            SetupChecker.check(
                $0.template, bindings: $0.bindings, subjectId: $0.subjectID, secrets: .install, attended: true)
        }
    }

    /// Items other than models and folders (both per workflow), each kind
    /// and value once.
    static func sharedItems(_ reports: [SetupReport]) -> [SetupItem] {
        var seen = Set<String>()
        return reports.flatMap(\.items).filter { item in
            item.kind != .model && item.kind != .mediaModel && !item.needsMediaModel && item.kind != .folder
                && seen.insert("\(item.kind.rawValue)|\(item.value)").inserted
        }
    }
}

struct WorkflowBundleSetupView: View {
    @Environment(\.theme) private var theme

    let subjects: [WorkflowSetupSubject]
    let onClose: () -> Void
    let onLeave: (ManagementTab) -> Void
    var onFinished: () -> Void = {}

    private typealias Step = WorkflowSetupWizardView.Step

    @State private var bundle = WorkflowBundleSetup(subjects: [])
    @State private var reports: [SetupReport] = []
    @State private var steps: [Step] = [.review]
    @State private var current: Step = .review
    @State private var footerWarning: String?
    @State private var glowingStep: Step?
    @State private var hasAppeared = false
    /// Install jobs started by Install All; the sheet shows their progress.
    @State private var jobIDs: [UUID] = []
    @State private var showsDetails = false
    @State private var isPlanning = false
    @ObservedObject private var coordinator = WorkflowInstallCoordinator.shared

    private var jobs: [WorkflowInstallCoordinator.Job] { jobIDs.compactMap { coordinator.job(id: $0) } }
    private var allDone: Bool {
        jobs.allSatisfy { if case .done = $0.phase { return true } else { return false } }
    }

    private var shared: [SetupItem] { WorkflowBundleSetup.sharedItems(reports) }
    private var currentIndex: Int { steps.firstIndex(of: current) ?? 0 }
    private var isLast: Bool { currentIndex == steps.count - 1 }

    private func items(_ step: Step) -> [SetupItem] {
        step == .models || step == .folders || step == .agents
            ? reports.flatMap { step.items(in: $0) } : step.items(in: SetupReport(subjectId: UUID(), items: shared))
    }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            SettingsSheetHeader(
                icon: "flowchart", title: "Set Up Workflows",
                subtitleText: bundle.subjects.map(\.name).joined(separator: ", "), onClose: cancel)
            if jobIDs.isEmpty {
                setupBody
            } else {
                installingBody
            }
            footer
        }
        .fittedSheetFrame(width: 820, height: 580)
        .settingsSheetSurface()
        .overlay(RoundedRectangle(cornerRadius: theme.radius.xlarge).stroke(theme.border.subtle, lineWidth: theme.stroke.default))
        .opacity(hasAppeared ? 1 : 0)
        .animation(theme.motion.quick, value: hasAppeared)
        .onAppear {
            hasAppeared = true
            if bundle.subjects.isEmpty { bundle = WorkflowBundleSetup(subjects: subjects) }
            refresh(rebuildSteps: true)
        }
        .onDisappear { present(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh(rebuildSteps: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .localModelsChanged)) { _ in
            refresh(rebuildSteps: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolsListChanged)) { _ in
            refresh(rebuildSteps: false)
        }
        .onReceive(ModelPickerItemCache.shared.$items.dropFirst()) { _ in
            refresh(rebuildSteps: false)
        }
    }

    private var setupBody: some View {
            HStack(spacing: theme.space.s0) {
                SetupStepRail(steps: steps, current: $current, glowing: glowingStep, title: \.title) { step in
                    guard step != .review else { return .none }
                    let remaining = items(step)
                    if remaining.isEmpty { return .done }
                    return remaining.contains(where: \.isBlocking) ? .required : .optional
                }
                .frame(width: 200)
                .layoutPriority(1)
                Divider()
                ScrollView {
                    stepContent
                        .padding(theme.space.s24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 0, maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.surface.overlay)
    }

    private var installingBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space.s24) {
                if allDone {
                    VStack(spacing: theme.space.s12) {
                        SettingsCompletionMark()
                        Text("Everything is ready", bundle: .module)
                            .font(SettingsFont.detailTitle)
                            .foregroundColor(theme.text.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .onAppear {
                        AccessibilityNotification.Announcement(L("Everything is ready")).post()
                    }
                }
                ForEach(jobs) { job in
                    VStack(alignment: .leading, spacing: theme.space.s10) {
                        WorkflowInstallProgressView(job: job, showsDetails: $showsDetails)
                        jobAction(job)
                    }
                    .padding(theme.space.s16)
                    .settingsChrome(.inset)
                }
            }
            .padding(theme.space.s24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.overlay)
    }

    @ViewBuilder
    private func jobAction(_ job: WorkflowInstallCoordinator.Job) -> some View {
        switch job.phase {
        case .failed(let message):
            HStack(spacing: theme.space.s8) {
                Text(verbatim: message)
                    .textStyle(.caption)
                    .foregroundColor(theme.status.error.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: theme.space.s8)
                Button(L("Try Again")) { coordinator.retry(job.id) }
                    .buttonStyle(.settings(.secondary, size: .small))
            }
        case .needsYou:
            HStack(spacing: theme.space.s8) {
                Text("It needs one more answer from you.", bundle: .module)
                    .textStyle(.caption)
                    .foregroundColor(theme.text.secondary)
                Spacer(minLength: theme.space.s8)
                Button(L("Finish Setting Up")) {
                    WorkflowInstallCoordinator.show(job)
                    onClose()
                }
                .buttonStyle(.settings(.primary, size: .small))
            }
        case .running, .done:
            EmptyView()
        }
    }

    @ViewBuilder
    private var footer: some View {
        if jobIDs.isEmpty {
            SettingsSheetFooter(
                primary: SettingsSheetFooter.Action(
                    label: isLast ? "Install All" : "Next", isLoading: isPlanning,
                    handler: { if isLast { finish() } else { move(1) } }),
                secondary: SettingsSheetFooter.Action(
                    label: currentIndex == 0 ? "Cancel" : "Back",
                    handler: { if currentIndex == 0 { cancel() } else { move(-1) } }),
                hint: nil,
                warning: footerWarning
            )
        } else if allDone {
            SettingsSheetFooter(primary: .init(label: "Done", handler: finishInstalls))
        } else {
            SettingsSheetFooter(secondary: .init(label: "Continue in Background", handler: onClose))
        }
    }

    private func present(_ on: Bool) {
        for job in jobs { coordinator.setPresented(job.templateID, on) }
    }

    private func finishInstalls() {
        for job in jobs { coordinator.dismiss(job.id) }
        onFinished()
        onClose()
    }

    private func move(_ delta: Int) {
        let target = currentIndex + delta
        guard steps.indices.contains(target) else { return }
        withAnimation(theme.motion.quick) { current = steps[target] }
    }

    private func refresh(rebuildSteps: Bool) {
        bundle.applyAutoBindings()
        reports = bundle.reports()
        withAnimation(theme.motion.quick) { footerWarning = nil }
        guard rebuildSteps else { return }
        let reqs = bundle.subjects.map(\.template.requirements)
        var out: [Step] = []
        if reqs.contains(where: { !$0.models.isEmpty || !$0.mediaModels.isEmpty })
            || reports.contains(where: { $0.items.contains(where: \.needsMediaModel) })
        {
            out.append(.models)
        }
        if !bundle.secrets.isEmpty { out.append(.secrets) }
        if reqs.contains(where: { !$0.folders.isEmpty }) { out.append(.folders) }
        if reqs.contains(where: { !$0.apps.isEmpty }) { out.append(.apps) }
        if reqs.contains(where: { !$0.agents.isEmpty }) { out.append(.agents) }
        if reqs.contains(where: { !$0.mcpServers.isEmpty || !$0.plugins.isEmpty })
            || shared.contains(where: { $0.kind == .network || $0.kind == .tool })
        {
            out.append(.tools)
        }
        if reqs.contains(where: { !$0.dependencies.isEmpty }) { out.append(.dependencies) }
        if reqs.contains(where: { !$0.permissions.isEmpty }) { out.append(.permissions) }
        out.append(.review)
        steps = out
        current = out.first ?? .review
    }

    /// Closing without installing drops the values entered for the bundle.
    private func cancel() {
        bundle.discardScratch()
        onClose()
    }

    private func finish() {
        guard !isPlanning else { return }
        refresh(rebuildSteps: false)
        isPlanning = true
        Task { @MainActor in
            defer { isPlanning = false }
            let subjects = bundle.subjects
            let reports = self.reports
            var plans: [WorkflowInstallPlan?] = []
            for (index, subject) in subjects.enumerated() {
                guard subject.mode == .install, index < reports.count else {
                    plans.append(nil)
                    continue
                }
                plans.append(
                    await WorkflowInstallPlan.live(
                        template: subject.template, bindings: subject.bindings, report: reports[index]))
            }
            let blockers = reports.indices.flatMap { index in
                let covered = Set(plans[index]?.items.flatMap(\.covers) ?? [])
                return reports[index].blocking.filter { !covered.contains($0.id) }
            }
            if let blocker = blockers.first {
                withAnimation(theme.motion.quick) { footerWarning = blocker.detail }
                glowingStep = steps.first { !$0.items(in: SetupReport(subjectId: UUID(), items: [blocker])).isEmpty }
                return
            }
            var seen = Set<String>()
            let downloads = plans.compactMap { $0 }.flatMap(\.items).filter { seen.insert($0.id).inserted }
            let needed = downloads.compactMap(\.sizeBytes).reduce(0, +)
            if let free = WorkflowInstallPlan.liveFreeBytes(),
                let refusal = ModelDownloadService.storageRefusalMessage(neededBytes: needed, freeBytes: free)
            {
                withAnimation(theme.motion.quick) { footerWarning = refusal }
                return
            }
            do {
                var installed: [InstalledWorkflow] = []
                var started: [UUID] = []
                for (index, subject) in subjects.enumerated() {
                    if let plan = plans[index], !plan.items.isEmpty {
                        started.append(coordinator.start(subject, items: plan.items))
                    } else if let workflow = try subject.commit() {
                        installed.append(workflow)
                    }
                }
                bundle.discardScratch()
                if !installed.isEmpty {
                    _ = ToastManager.shared.success(L("Installed \(installed.map(\.name).joined(separator: ", "))"))
                }
                guard !started.isEmpty else {
                    onFinished()
                    onClose()
                    return
                }
                withAnimation(theme.motion.standard) { jobIDs = started }
                present(true)
            } catch {
                withAnimation(theme.motion.quick) { footerWarning = WorkflowErrorText.text(error) }
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        VStack(alignment: .leading, spacing: theme.space.s16) {
            SettingsDetailHeader(icon: current.icon, title: current.title)
            switch current {
            case .models:
                WorkflowModelsStep.explainer.textStyle(.caption).foregroundColor(theme.text.secondary)
                ForEach(Array(bundle.subjects.enumerated()), id: \.element.id) { index, subject in
                    let modelItems = index < reports.count ? Step.models.items(in: reports[index]) : []
                    if !subject.template.requirements.models.isEmpty
                        || !WorkflowModelsStep.mediaNeeds(subject.template, items: modelItems).isEmpty
                    {
                        Text(subject.name)
                            .font(SettingsFont.sectionTitle)
                            .foregroundColor(theme.text.primary)
                        WorkflowModelsStep(
                            template: subject.template, bindings: subject.bindings,
                            items: modelItems,
                            onlySlots: nil,
                            setModel: { slot, model in
                                bundle.subjects[index].bindings.models[slot] = model
                                refresh(rebuildSteps: false)
                            },
                            onLeave: nil)
                    }
                }
                WorkflowModelsStep.actions(onLeave)
            case .secrets:
                WorkflowSecretsStep(
                    secrets: bundle.secrets, scope: bundle.scratchScope, bindings: bundle.secretBindings,
                    items: items(.secrets),
                    onSaved: { key, account in
                        bundle.bindSecret(key, account: account)
                        refresh(rebuildSteps: false)
                    })
            case .folders:
                ForEach(Array(bundle.subjects.enumerated()), id: \.element.id) { index, subject in
                    if !subject.template.requirements.folders.isEmpty {
                        Text(subject.name)
                            .font(SettingsFont.sectionTitle)
                            .foregroundColor(theme.text.primary)
                        WorkflowFoldersStep(
                            folders: subject.template.requirements.folders, bindings: subject.bindings,
                            items: index < reports.count ? Step.folders.items(in: reports[index]) : [],
                            onChoose: { key, path in
                                bundle.subjects[index].bindings.folders[key] = path
                                refresh(rebuildSteps: false)
                            })
                    }
                }
            case .apps:
                WorkflowAppsStep(
                    apps: bundle.subjects.map(\.template.requirements).reduce(TemplateRequirements()) {
                        $0.merged(with: $1)
                    }.apps,
                    items: items(.apps), onCheckAgain: { refresh(rebuildSteps: false) })
            case .agents:
                ForEach(Array(bundle.subjects.enumerated()), id: \.element.id) { index, subject in
                    if !subject.template.requirements.agents.isEmpty {
                        Text(subject.name)
                            .font(SettingsFont.sectionTitle)
                            .foregroundColor(theme.text.primary)
                        WorkflowAgentsStep(
                            agents: subject.template.requirements.agents, bindings: subject.bindings,
                            items: index < reports.count ? Step.agents.items(in: reports[index]) : [],
                            allowsWithoutAsking: subject.agentStepsAllowed,
                            onSetAllowsWithoutAsking: { on in bundle.subjects[index].agentStepsAllowed = on },
                            onAllowed: { refresh(rebuildSteps: false) },
                            onChoose: { id, target in
                                bundle.subjects[index].bindings.agents[id] = target
                                refresh(rebuildSteps: false)
                            })
                    }
                }
            case .tools:
                let servers = bundle.serverNames
                ForEach(servers, id: \.self) { name in
                    if let owner = bundle.owner(ofServer: name) {
                        WorkflowMCPServerCard(
                            name: name, template: bundle.subjects[owner].template,
                            bindings: bundle.subjects[owner].bindings,
                            onBind: { local in
                                bundle.bindServer(name, to: local)
                                refresh(rebuildSteps: false)
                            })
                    }
                }
                WorkflowToolsStep(
                    items: items(.tools), cardsAbove: servers,
                    onLeave: onLeave, onCheckAgain: { refresh(rebuildSteps: false) })
            case .dependencies:
                ForEach(Array(bundle.subjects.enumerated()), id: \.element.id) { index, subject in
                    if !subject.template.requirements.dependencies.isEmpty {
                        Text(subject.name)
                            .font(SettingsFont.sectionTitle)
                            .foregroundColor(theme.text.primary)
                        WorkflowDependenciesStep(
                            dependencies: subject.template.requirements.dependencies,
                            environmentID: subject.template.id,
                            items: index < reports.count ? Step.dependencies.items(in: reports[index]) : [],
                            onLeave: onLeave, onChanged: { refresh(rebuildSteps: false) })
                    }
                }
            case .permissions:
                PermissionsStep(
                    items: items(.permissions), doneText: L("Every permission these workflows need is granted."),
                    onChanged: { refresh(rebuildSteps: false) })
            case .answers, .review:
                review
            }
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            ForEach(Array(bundle.subjects.enumerated()), id: \.element.id) { index, subject in
                let report = index < reports.count ? reports[index] : nil
                HStack(spacing: theme.space.s10) {
                    Image(systemName: report?.hasBlockers == false ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundColor(
                            report?.hasBlockers == false ? theme.status.success.foreground : theme.text.secondary
                        )
                    VStack(alignment: .leading, spacing: theme.space.s2) {
                        Text(subject.name)
                            .font(SettingsFont.rowTitle)
                            .foregroundColor(theme.text.primary)
                        Text(
                            subject.mode == .install
                                ? L("Installs version \(subject.template.version)")
                                : L("Updates to version \(subject.template.version)")
                        )
                        .textStyle(.footnote)
                        .foregroundColor(theme.text.tertiary)
                    }
                    Spacer()
                }
                .padding(theme.space.s8)
                .settingsChrome(.inset)
                if let report, !report.isClean { AgentSetupChecklistView(report: report) }
            }
        }
    }
}
