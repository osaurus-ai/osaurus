//
//  WorkflowBundleSetupView.swift
//  osaurus
//
//  One setup pass for every workflow an agent template brings: model slots
//  and folders per workflow, then secrets, MCP servers, plugins, and
//  permissions asked once however many workflows need them. Install installs them all, or
//  none while anything still blocks.
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

    /// Items other than model slots and folders (both per workflow), each
    /// kind and value once.
    static func sharedItems(_ reports: [SetupReport]) -> [SetupItem] {
        var seen = Set<String>()
        return reports.flatMap(\.items).filter { item in
            item.kind != .model && item.kind != .folder && seen.insert("\(item.kind.rawValue)|\(item.value)").inserted
        }
    }
}

struct WorkflowBundleSetupView: View {
    @Environment(\.theme) private var theme

    let subjects: [WorkflowSetupSubject]
    let onClose: () -> Void
    let onLeave: (ManagementTab) -> Void
    var onFinished: ([InstalledWorkflow]) -> Void = { _ in }

    private typealias Step = WorkflowSetupWizardView.Step

    @State private var bundle = WorkflowBundleSetup(subjects: [])
    @State private var reports: [SetupReport] = []
    @State private var steps: [Step] = [.review]
    @State private var current: Step = .review
    @State private var footerWarning: String?
    @State private var glowingStep: Step?
    @State private var hasAppeared = false

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
            SettingsSheetFooter(
                primary: SettingsSheetFooter.Action(
                    label: isLast ? "Install All" : "Next",
                    handler: { if isLast { finish() } else { move(1) } }),
                secondary: SettingsSheetFooter.Action(
                    label: currentIndex == 0 ? "Cancel" : "Back",
                    handler: { if currentIndex == 0 { cancel() } else { move(-1) } }),
                hint: nil,
                warning: footerWarning
            )
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
        if reqs.contains(where: { !$0.models.isEmpty }) { out.append(.models) }
        if !bundle.secrets.isEmpty { out.append(.secrets) }
        if reqs.contains(where: { !$0.folders.isEmpty }) { out.append(.folders) }
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
        refresh(rebuildSteps: false)
        if let step = steps.first(where: { items($0).contains(where: \.isBlocking) }),
            let blocker = items(step).first(where: \.isBlocking)
        {
            withAnimation(theme.motion.quick) { footerWarning = blocker.detail }
            glowingStep = step
            return
        }
        do {
            let installed = try bundle.subjects.compactMap { try WorkflowSetupWizardView.commit($0) }
            bundle.discardScratch()
            _ = ToastManager.shared.success(L("Installed \(installed.map(\.name).joined(separator: ", "))"))
            onFinished(installed)
            onClose()
        } catch {
            withAnimation(theme.motion.quick) { footerWarning = WorkflowErrorText.text(error) }
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
                    if !subject.template.requirements.models.isEmpty {
                        Text(subject.name)
                            .font(SettingsFont.sectionTitle)
                            .foregroundColor(theme.text.primary)
                        WorkflowModelsStep(
                            template: subject.template, bindings: subject.bindings,
                            items: index < reports.count ? Step.models.items(in: reports[index]) : [],
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
