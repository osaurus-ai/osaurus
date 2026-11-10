//
//  WorkflowSetupWizardView.swift
//  osaurus
//
//  Guided setup for a workflow template on this Mac. Steps are built from
//  what the template requires: a model per slot (only models that can
//  enforce the node schemas, honoring local-only and tool-use slots),
//  secrets, folders, MCP servers and plugins, system permissions, saved
//  answers, and review.
//
//  Three modes, one view:
//   - install: adding a template. Nothing is installed until Install passes
//     the check, so a template this Mac cannot run never yields a broken
//     workflow.
//   - setup: an installed workflow that needs something (or the user
//     wants to change its bindings). Finish saves the bindings.
//   - update: re-pin an installed workflow to a newer template version.
//     Only new or changed requirements (and anything now blocking) get a
//     step; a version that reaches new hosts or tools re-asks every
//     secret; saved answers migrate by node and field key.
//   - draft: an Architect draft about to test. Finish saves the bindings
//     to the draft; nothing is installed.
//
//  Stepping aside to another tab parks the wizard with its edits on
//  `ManagementStateManager.pendingSetupSubject`.
//

import AppKit
import SwiftUI

struct WorkflowSetupSubject: Identifiable {
    enum Mode: Equatable {
        case install
        case setup(UUID)
        case update(UUID)
        case draft(UUID)
    }

    let id = UUID()
    var mode: Mode
    var template: Template
    var bindings: InstallBindings
    var name: String
    /// `InstalledWorkflow.agentStepsAllowed`, saved with the bindings.
    var agentStepsAllowed = false
    /// The registry listing an install or update came from.
    var source: InstalledWorkflow.Source?

    /// Adding a template. A template already installed here opens as setup on
    /// that install: one installed workflow per template per Mac.
    @MainActor
    static func install(_ template: Template) -> WorkflowSetupSubject {
        if let existing = InstalledWorkflowStore.shared.workflow(templateID: template.id) {
            if existing.templateVersion < template.version { return update(existing, to: template) }
            return setup(existing)
        }
        return WorkflowSetupSubject(mode: .install, template: template, bindings: InstallBindings(), name: template.name)
    }

    static func setup(_ workflow: InstalledWorkflow) -> WorkflowSetupSubject {
        WorkflowSetupSubject(
            mode: .setup(workflow.id), template: workflow.template, bindings: workflow.bindings, name: workflow.name,
            agentStepsAllowed: workflow.agentStepsAllowed)
    }

    /// A version that asks a new agent is asked about again.
    static func update(_ workflow: InstalledWorkflow, to template: Template) -> WorkflowSetupSubject {
        let newAgents = TemplateDiff.newRequirements(from: workflow.template.requirements, to: template.requirements).agents
        return WorkflowSetupSubject(
            mode: .update(workflow.id), template: template, bindings: workflow.bindings, name: workflow.name,
            agentStepsAllowed: newAgents.isEmpty && workflow.agentStepsAllowed)
    }

    @MainActor
    static func draft(_ draft: WorkflowDraft) -> WorkflowSetupSubject {
        WorkflowSetupSubject(
            mode: .draft(draft.id), template: draft.template(),
            bindings: WorkflowDraftStore.shared.testBindings(draft.id), name: draft.name)
    }

    var installedID: UUID? {
        switch mode {
        case .install, .draft: return nil
        case .setup(let id), .update(let id): return id
        }
    }

    var isDraft: Bool {
        if case .draft = mode { return true }
        return false
    }

    /// The id setup checks and parked state key on.
    var subjectID: UUID {
        switch mode {
        case .draft(let id): return id
        default: return installedID ?? template.id
        }
    }
}

struct WorkflowSetupWizardView: View {
    @Environment(\.theme) private var theme

    let subject: WorkflowSetupSubject
    let onClose: () -> Void
    var onFinished: (InstalledWorkflow) -> Void = { _ in }

    enum Step: Hashable {
        case models, secrets, folders, agents, tools, dependencies, permissions, answers, review

        var title: String {
            switch self {
            case .models: return L("Models")
            case .secrets: return L("Secrets")
            case .folders: return L("Folders")
            case .agents: return L("Agents")
            case .tools: return L("Tools")
            case .dependencies: return L("Dependencies")
            case .permissions: return L("Permissions")
            case .answers: return L("Saved Answers")
            case .review: return L("Review")
            }
        }

        var icon: String {
            switch self {
            case .models: return "cube"
            case .secrets: return "key"
            case .folders: return "folder"
            case .agents: return "person.2"
            case .tools: return "wrench.and.screwdriver"
            case .dependencies: return "shippingbox"
            case .permissions: return "lock.shield"
            case .answers: return "text.badge.checkmark"
            case .review: return "checkmark.seal"
            }
        }

        func items(in report: SetupReport) -> [SetupItem] {
            report.items.filter { item in
                switch self {
                case .models: return item.kind == .model
                case .secrets: return item.kind == .secret
                case .folders: return item.kind == .folder
                case .agents: return item.kind == .agent
                case .tools:
                    return item.kind == .mcpServer || item.kind == .plugin || item.kind == .network
                        || item.kind == .tool
                case .dependencies: return item.kind == .dependency
                case .permissions: return item.kind == .systemPermission
                case .answers, .review: return false
                }
            }
        }
    }

    @State private var working: WorkflowSetupSubject?
    @State private var report: SetupReport?
    @State private var steps: [Step] = [.review]
    @State private var current: Step = .review
    @State private var footerWarning: String?
    @State private var glowingStep: Step?
    @State private var glowClearTask: Task<Void, Never>?
    @State private var hasAppeared = false
    /// Example to run once installed; nil runs nothing.
    @State private var exampleToRun: String?

    /// Update mode: what the newer version asks for that the pin did not.
    private var newRequirements: TemplateDiff.NewRequirements? {
        guard let working, case .update(let id) = working.mode,
            let installed = InstalledWorkflowStore.shared.workflow(id: id)
        else { return nil }
        return TemplateDiff.newRequirements(from: installed.template.requirements, to: working.template.requirements)
    }

    /// Secrets the person confirmed (kept or re-entered) during an update
    /// that widens where the workflow can reach.
    @State private var confirmedSecrets: Set<String> = []

    /// Update mode: stored secrets to confirm again, with why.
    private var reconfirmSecrets: [String: String] {
        guard let working, let new = newRequirements, new.widensAccess else { return [:] }
        let reason = Self.widenedAccessReason(new)
        var out: [String: String] = [:]
        for secret in working.template.requirements.secrets
        where !new.secrets.contains(secret.key) && !confirmedSecrets.contains(secret.key) {
            out[secret.key] = reason
        }
        return out
    }

    static func widenedAccessReason(_ new: TemplateDiff.NewRequirements) -> String {
        var parts: [String] = []
        if !new.network.isEmpty { parts.append(L("hosts \(new.network.sorted().joined(separator: ", "))")) }
        if !new.tools.isEmpty { parts.append(L("tools \(new.tools.sorted().joined(separator: ", "))")) }
        if !new.mcpServers.isEmpty { parts.append(L("MCP servers \(new.mcpServers.sorted().joined(separator: ", "))")) }
        if !new.plugins.isEmpty { parts.append(L("plugins \(new.plugins.sorted().joined(separator: ", "))")) }
        if !new.permissions.isEmpty {
            parts.append(L("permissions \(new.permissions.sorted().joined(separator: ", "))"))
        }
        return L("This version can reach \(parts.joined(separator: "; ")). Confirm the stored value may be used there, or enter a new one.")
    }

    private var currentIndex: Int { steps.firstIndex(of: current) ?? 0 }
    private var isLast: Bool { currentIndex == steps.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                SetupStepRail(steps: steps, current: $current, glowing: glowingStep, title: \.title) { step in
                    guard let report, step != .review, step != .answers else { return .none }
                    let remaining = step.items(in: report)
                    if remaining.isEmpty { return .done }
                    return remaining.contains(where: \.isBlocking) ? .required : .optional
                }
                .frame(width: 200)
                .layoutPriority(1)
                Divider()
                ScrollView {
                    Group {
                        if let working, let report {
                            stepContent(working, report: report)
                        } else {
                            SettingsEmptyState(loading: "Checking what this workflow needs…")
                        }
                    }
                    .padding(theme.space.s24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 0, maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.surface.overlay)
            SettingsSheetFooter(
                primary: SettingsSheetFooter.Action(
                    label: isLast ? primaryLabel : "Next",
                    handler: { if isLast { finish() } else { advance() } }),
                secondary: SettingsSheetFooter.Action(
                    label: currentIndex == 0 ? (subject.mode == .install ? "Cancel" : "Later") : "Back",
                    handler: { if currentIndex == 0 { onClose() } else { goBack() } }),
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
            if working == nil { working = subject }
            refresh(rebuildSteps: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh(rebuildSteps: false)
        }
        // A download finishing, a provider connecting, or an MCP server
        // registering its tools can clear a step without leaving the sheet.
        .onReceive(NotificationCenter.default.publisher(for: .localModelsChanged)) { _ in
            refresh(rebuildSteps: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolsListChanged)) { _ in
            refresh(rebuildSteps: false)
        }
        .onReceive(ModelPickerItemCache.shared.$items.dropFirst()) { _ in
            refresh(rebuildSteps: false)
        }
        // The sandbox finishing provisioning clears the Dependencies
        // step's "not set up" item without leaving the sheet.
        .onReceive(SandboxManager.State.shared.$status.dropFirst().removeDuplicates()) { _ in
            refresh(rebuildSteps: false)
        }
        // A key set on the Keys page, or an older saved value found in the
        // background, can fill a secret.
        .onReceive(NotificationCenter.default.publisher(for: .credentialsDidChange, object: CredentialStore.shared)) { _ in
            refresh(rebuildSteps: false)
        }
    }

    private var primaryLabel: LocalizedStringKey {
        switch subject.mode {
        case .install: return "Install"
        case .setup, .draft: return "Finish"
        case .update: return "Update"
        }
    }

    private var header: some View {
        switch subject.mode {
        case .install:
            return SettingsSheetHeader(
                icon: "flowchart", title: "Install Workflow",
                subtitleText: L("From the \(subject.template.name) template, version \(subject.template.version)"),
                onClose: onClose)
        case .setup:
            return SettingsSheetHeader(icon: "checklist", title: "Set Up Workflow", subtitleText: subject.name, onClose: onClose)
        case .draft:
            return SettingsSheetHeader(
                icon: "checklist", title: "Set Up Test Run",
                subtitleText: L("What \(subject.name) needs on this Mac before it can run"), onClose: onClose)
        case .update:
            return SettingsSheetHeader(
                icon: "arrow.up.circle", title: "Update Workflow",
                subtitleText: L("\(subject.name) to version \(subject.template.version)"), onClose: onClose)
        }
    }

    // MARK: - Navigation

    private func advance() {
        guard currentIndex + 1 < steps.count else { return }
        withAnimation(theme.motion.quick) { current = steps[currentIndex + 1] }
    }

    private func goBack() {
        guard currentIndex > 0 else { return }
        withAnimation(theme.motion.quick) { current = steps[currentIndex - 1] }
    }

    private func leave(to tab: ManagementTab) {
        if let working {
            ManagementStateManager.shared.pendingSetupSubject = .workflow(working)
            ParkedWorkflowSetupWatcher.shared.watchParked()
        }
        onClose()
        AppDelegate.shared?.showManagementWindow(initialTab: tab)
    }

    private func warn(_ text: String, glowing step: Step) {
        withAnimation(theme.motion.quick) { footerWarning = text }
        glowClearTask?.cancel()
        glowingStep = step
        glowClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            glowingStep = nil
        }
    }

    private func setBindings(_ change: (inout InstallBindings) -> Void) {
        guard var w = working else { return }
        change(&w.bindings)
        working = w
        withAnimation(theme.motion.quick) { footerWarning = nil }
        refresh(rebuildSteps: false)
    }

    private func refresh(rebuildSteps: Bool) {
        guard var working else { return }
        let bound = MCPServerResolution.liveAutoBindings(for: working.template, bindings: working.bindings)
        if bound != working.bindings {
            working.bindings = bound
            self.working = working
        }
        let fresh = SetupChecker.check(
            working.template, bindings: working.bindings, subjectId: working.subjectID,
            reconfirmSecrets: reconfirmSecrets, secrets: .install, agentsByName: working.isDraft, attended: true)
        report = fresh
        if rebuildSteps {
            steps = Self.steps(for: working, report: fresh, newRequirements: newRequirements)
            current = steps.first ?? .review
        }
    }

    static func steps(
        for subject: WorkflowSetupSubject, report: SetupReport, newRequirements: TemplateDiff.NewRequirements?
    ) -> [Step] {
        let reqs = subject.template.requirements
        let blocking = Set(report.blocking.map(\.kind))
        func wanted(_ present: Bool, _ isNew: Bool, _ kinds: [TemplateRequirement.Kind]) -> Bool {
            guard present else { return false }
            guard newRequirements != nil else { return true }
            return isNew || kinds.contains(where: blocking.contains)
        }
        let new = newRequirements ?? TemplateDiff.NewRequirements()
        var out: [Step] = []
        if wanted(!reqs.models.isEmpty, !new.slots.isEmpty, [.model]) { out.append(.models) }
        // An update that reaches new hosts or tools re-asks every secret,
        // not only new keys: the old value would travel somewhere new.
        if wanted(!reqs.secrets.isEmpty, !new.secrets.isEmpty || new.widensAccess, [.secret]) { out.append(.secrets) }
        if wanted(!reqs.folders.isEmpty, !new.folders.isEmpty, [.folder]) { out.append(.folders) }
        if wanted(!reqs.agents.isEmpty, !new.agents.isEmpty, [.agent]) { out.append(.agents) }
        if wanted(
            !reqs.mcpServers.isEmpty || !reqs.plugins.isEmpty || blocking.contains(.network)
                || blocking.contains(.tool),
            !new.mcpServers.isEmpty || !new.plugins.isEmpty || !new.network.isEmpty || !new.tools.isEmpty,
            [.mcpServer, .plugin, .network, .tool])
        {
            out.append(.tools)
        }
        if wanted(!reqs.dependencies.isEmpty, !new.dependencies.isEmpty, [.dependency]) {
            out.append(.dependencies)
        }
        if wanted(!reqs.permissions.isEmpty, !new.permissions.isEmpty, [.systemPermission]) {
            out.append(.permissions)
        }
        if subject.installedID != nil, let def = subject.template.workflow, def.hasRememberedFields {
            out.append(.answers)
        }
        out.append(.review)
        return out
    }

    // MARK: - Finish

    private func finish() {
        refresh(rebuildSteps: false)
        guard let working, let report else { return }
        if let blocker = report.blocking.first {
            let step = steps.first { !$0.items(in: report).filter(\.isBlocking).isEmpty } ?? .review
            warn(blocker.detail, glowing: step)
            return
        }
        if case .draft(let id) = working.mode {
            WorkflowDraftStore.shared.setBindings(id, working.bindings)
            onClose()
            return
        }
        do {
            guard let result = try Self.commit(working) else { return }
            switch working.mode {
            case .install: _ = ToastManager.shared.success(L("Installed \(result.name)"))
            case .setup: _ = ToastManager.shared.success(L("\(result.name) is ready"))
            case .update:
                _ = ToastManager.shared.success(L("Updated \(result.name) to version \(result.templateVersion)"))
            case .draft: break
            }
            onFinished(result)
            onClose()
            if let name = exampleToRun, let example = working.template.workflow?.examples.first(where: { $0.name == name }) {
                WorkflowRunLauncher.runExample(example, of: result)
            }
        } catch {
            warn(WorkflowErrorText.text(error), glowing: .review)
        }
    }

    /// Installs, saves, or updates the subject. Nil for a draft (nothing
    /// installs) or an install that disappeared meanwhile.
    static func commit(_ working: WorkflowSetupSubject) throws -> InstalledWorkflow? {
        let store = InstalledWorkflowStore.shared
        switch working.mode {
        case .draft:
            return nil
        case .install:
            var installed = try store.install(working.template, bindings: working.bindings, name: working.name)
            // Secrets entered before the install existed sat under the
            // template id; move them to the install they now belong to.
            installed.bindings.secrets = WorkflowCredentials.rekey(
                working.template.requirements.secrets.map(\.key), from: working.subjectID, to: installed.id,
                keeping: working.bindings.secrets)
            installed.agentStepsAllowed = working.agentStepsAllowed
            if let source = working.source { installed.source = source }
            try store.save(installed)
            return store.workflow(id: installed.id) ?? installed
        case .setup(let id):
            guard var installed = store.workflow(id: id) else { return nil }
            installed.bindings = working.bindings
            installed.agentStepsAllowed = working.agentStepsAllowed
            installed.needsSetup = false
            try store.save(installed)
            return installed
        case .update(let id):
            guard let current = store.workflow(id: id) else { return nil }
            let name = working.name.trimmingCharacters(in: .whitespacesAndNewlines)
            var installed = try store.install(
                working.template, bindings: working.bindings, name: name == current.name ? nil : name)
            if installed.agentStepsAllowed != working.agentStepsAllowed
                || (working.source != nil && installed.source != working.source)
            {
                installed.agentStepsAllowed = working.agentStepsAllowed
                if let source = working.source { installed.source = source }
                try store.save(installed)
            }
            if let def = working.template.workflow {
                SavedAnswersStore.shared.migrate(workflowID: installed.id, to: def)
            }
            return installed
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private func stepContent(_ working: WorkflowSetupSubject, report: SetupReport) -> some View {
        let items = current.items(in: report)
        VStack(alignment: .leading, spacing: 18) {
            SettingsDetailHeader(icon: current.icon, title: current.title)
            switch current {
            case .models:
                WorkflowModelsStep(
                    template: working.template, bindings: working.bindings, items: items,
                    onlySlots: newRequirements.map { new in
                        new.slots.union(items.map(\.value))
                    },
                    setModel: { slot, model in setBindings { $0.models[slot] = model } },
                    onLeave: leave)
            case .secrets:
                WorkflowSecretsStep(
                    secrets: working.template.requirements.secrets, scope: working.subjectID,
                    bindings: working.bindings, items: items,
                    reconfirm: Set(reconfirmSecrets.keys),
                    workflowName: working.template.name,
                    onSaved: { key, account in
                        confirmedSecrets.insert(key)
                        setBindings { $0.secrets[key] = account }
                    })
            case .folders:
                WorkflowFoldersStep(
                    folders: working.template.requirements.folders, bindings: working.bindings, items: items,
                    onChoose: { key, path in setBindings { $0.folders[key] = path } })
            case .agents:
                WorkflowAgentsStep(
                    agents: working.template.requirements.agents, bindings: working.bindings, items: items,
                    allowsWithoutAsking: working.isDraft ? nil : working.agentStepsAllowed,
                    onSetAllowsWithoutAsking: { on in self.working?.agentStepsAllowed = on },
                    onAllowed: { refresh(rebuildSteps: false) },
                    onChoose: { id, target in setBindings { $0.agents[id] = target } })
            case .tools:
                WorkflowToolsStep(
                    items: items, template: working.template, bindings: working.bindings,
                    onBindServer: { name, local in setBindings { $0.mcpServers[name] = local } },
                    onLeave: leave, onCheckAgain: { refresh(rebuildSteps: false) })
            case .dependencies:
                WorkflowDependenciesStep(
                    dependencies: working.template.requirements.dependencies, environmentID: working.template.id,
                    items: items, onLeave: leave, onChanged: { refresh(rebuildSteps: false) })
            case .permissions:
                PermissionsStep(
                    items: items, doneText: L("Every permission this workflow needs is granted."),
                    onChanged: { refresh(rebuildSteps: false) })
            case .answers:
                if let id = working.installedID, let def = working.template.workflow {
                    if case .update = working.mode {
                        Text(
                            "Answers carry over by field. An answer whose field changed type is cleared when you update.",
                            bundle: .module
                        )
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    SavedAnswersSection(workflowID: id, definition: def)
                }
            case .review:
                WorkflowReviewStep(
                    subject: working, report: report, exampleToRun: $exampleToRun,
                    onRename: { name in self.working?.name = name })
            }
        }
    }
}

// MARK: - Models

struct WorkflowModelsStep: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var pickerCache = ModelPickerItemCache.shared

    let template: Template
    let bindings: InstallBindings
    let items: [SetupItem]
    /// Update mode: the slots to show. Nil shows every slot.
    let onlySlots: Set<String>?
    let setModel: (String, String?) -> Void
    /// Nil hides the provider and download actions (the bundle wizard
    /// shows them once below every workflow).
    let onLeave: ((ManagementTab) -> Void)?

    var body: some View {
        let slots = template.requirements.models.filter { onlySlots?.contains($0.slot) ?? true }
        VStack(alignment: .leading, spacing: 16) {
            if onLeave != nil { Self.explainer.textStyle(.caption).foregroundColor(theme.text.secondary) }
            ForEach(slots) { slot in slotCard(slot) }
            if let onLeave { Self.actions(onLeave) }
        }
        .onAppear { if !pickerCache.isLoaded { pickerCache.prewarm() } }
    }

    static var explainer: some View {
        Text("Pick the model each step uses. Only models that can return a step's result in the exact shape it needs are offered.", bundle: .module)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Where more models come from, as one quiet line under the slots.
    static func actions(_ onLeave: @escaping (ManagementTab) -> Void) -> some View {
        WorkflowModelSourcesLine(onLeave: onLeave)
    }

    private func usedBy(_ slot: String) -> [String] {
        (template.workflow?.nodes ?? []).compactMap { node in
            if case .inference(let spec) = node.kind, spec.modelSlot == slot { return node.name }
            return nil
        }
    }

    private func slotCard(_ slot: ModelRequirement) -> some View {
        let bound = bindings.models[slot.slot]
        let issues = items.filter { $0.value == slot.slot }
        let steps = usedBy(slot.slot)
        let suggested = WorkflowModelChoices.suggested(slot)
        let source = bound == nil ? WorkflowModelResolution.livePlan(for: suggested) : .none
        // The source row already says the suggested model is missing.
        let shownIssues = source.offersSource ? issues.filter { !$0.hasNoModel } : issues
        return VStack(alignment: .leading, spacing: theme.space.s12) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space.s6) {
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(verbatim: steps.isEmpty ? slot.slot : WorkflowSummary.list(steps))
                        .textStyle(.label, weight: 600)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(2)
                        .help(slot.slot)
                    if !steps.isEmpty {
                        Text(verbatim: steps.count == 1 ? L("The model this step uses") : L("The model these steps use"))
                            .textStyle(.caption)
                            .foregroundColor(theme.text.tertiary)
                    }
                }
                Spacer(minLength: theme.space.s8)
                if slot.locality == .localOnly { chip(L("Local only"), "desktopcomputer") }
                if slot.needsToolUse { chip(L("Uses tools"), "wrench.and.screwdriver") }
                if slot.requiredModel != nil { chip(L("Required model"), "lock") }
            }
            VStack(alignment: .leading, spacing: theme.space.s8) {
                modelPicker(slot, bound: bound)
                if !shownIssues.isEmpty {
                    StepIssueList(items: shownIssues)
                } else if issues.isEmpty {
                    Label {
                        Text("Ready", bundle: .module)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(theme.status.success.foreground)
                    }
                    .textStyle(.caption, weight: 500)
                    .foregroundColor(theme.text.secondary)
                }
            }
            if source.offersSource {
                WorkflowModelSourceRow(
                    plan: source, fallsBack: slot.strictness != .always,
                    hasDefault: !issues.contains(where: \.hasNoModel), onLeave: onLeave)
            }
        }
        .padding(theme.space.s16)
        .settingsChrome(.inset)
    }

    @ViewBuilder
    private func modelPicker(_ slot: ModelRequirement, bound: String?) -> some View {
        if let required = slot.requiredModel {
            // Only the required model runs this slot; a leftover binding
            // to another model stays listed so it can be switched back.
            SettingsMenuPicker(
                selection: Binding(get: { bound ?? "" }, set: { setModel(slot.slot, $0.isEmpty ? nil : $0) })
            ) {
                Text(verbatim: WorkflowModelChoices.displayName(required)).tag("")
                if let bound { Text(verbatim: bound).tag(bound) }
            }
            .settingsPickerHugging()
            .disabled(bound == nil)
        } else {
            WorkflowModelSlotPicker(requirement: slot, bound: bound) { setModel(slot.slot, $0) }
        }
    }

    private func chip(_ text: String, _ icon: String) -> some View {
        StatusChip(text, icon: icon)
    }
}

extension WorkflowModelChoices {
    /// The model a slot suggests. "default" names no model: it runs on the
    /// default model, the same as suggesting none.
    static func suggested(_ slot: ModelRequirement) -> String? {
        guard let id = slot.preferred?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
            id.caseInsensitiveCompare("default") != .orderedSame
        else { return nil }
        return id
    }

    /// Models a slot may bind: chat models that can enforce a response
    /// schema, local ones for local-only slots, tool-capable ones for
    /// slots that use tools.
    static func choices(for slot: ModelRequirement) -> (usable: [ModelPickerItem], hidden: Int) {
        let all = items(toolCapableOnly: false)
        let usable = all.filter { unusableReason($0, for: slot) == nil }
        return (usable, all.count - usable.count)
    }

    /// Why a model can't run a slot, in the words the model menus group by.
    static func unusableReason(_ item: ModelPickerItem, for slot: ModelRequirement) -> String? {
        if slot.locality == .localOnly {
            switch item.source {
            case .local, .foundation: break
            default: return L("Doesn't run on this Mac")
            }
        }
        if slot.needsToolUse, item.supportsToolCalling == false { return L("Can't use tools") }
        if StructuredOutputCapability.support(for: item.id) != .supported { return L("Can't return typed results") }
        return nil
    }

    /// Models a slot can't use, grouped by why, in first-seen order.
    static func unusable(for slot: ModelRequirement) -> [(reason: String, items: [ModelPickerItem])] {
        var groups: [(reason: String, items: [ModelPickerItem])] = []
        for item in items(toolCapableOnly: false) {
            guard let reason = unusableReason(item, for: slot) else { continue }
            if let i = groups.firstIndex(where: { $0.reason == reason }) {
                groups[i].items.append(item)
            } else {
                groups.append((reason, [item]))
            }
        }
        return groups
    }
}

// MARK: - Secrets

struct WorkflowSecretsStep: View {
    @Environment(\.theme) private var theme
    let secrets: [SecretRequirement]
    /// The id the values are stored under: the install, the draft, or the
    /// template until it installs.
    let scope: UUID
    let bindings: InstallBindings
    let items: [SetupItem]
    /// Keys with a stored value the person must confirm again (an update
    /// widened where the workflow can reach). Keeping it counts as saved.
    var reconfirm: Set<String> = []
    /// Prefix for a key this workflow keeps to itself.
    var workflowName: String = "Workflow"
    let onSaved: (String, String) -> Void

    @ObservedObject private var connections = WorkflowConnectionStore.shared
    @State private var values: [String: String] = [:]
    /// Keys whose pasted value is also kept as a connection, with its name.
    @State private var keepAsConnection: Set<String> = []
    @State private var connectionNames: [String: String] = [:]
    /// Keys saved as a value only this workflow uses.
    @State private var separateValue: Set<String> = []
    /// OAuth sign-in state per key: client id / secret fields, the running
    /// sign-in (so it can be cancelled), error.
    @State private var clientIDs: [String: String] = [:]
    @State private var clientSecrets: [String: String] = [:]
    @State private var signInTasks: [String: Task<Void, Never>] = [:]
    @State private var signInErrors: [String: String] = [:]
    /// The name a new sign-in session is saved under, per key.
    @State private var sessionNames: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if items.isEmpty {
                StepDoneBanner(text: L("Every secret needed here is in the Keychain."))
            }
            Text(
                "Secrets are saved in the Vault on this Mac and are never exported with the template. Workflows and agents that use the same name share one value unless you give this workflow its own. An agent with its own value uses that when it runs this workflow.",
                bundle: .module
            )
            .font(SettingsFont.caption)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
            ForEach(secrets) { secret in row(secret) }
        }
        .onAppear {
            connections.loadIfNeeded()
            // A declared connection is meant to be shared: keep its value
            // as one unless the person unticks it.
            for secret in secrets where secret.isConnection && secret.oauth2 == nil {
                keepAsConnection.insert(secret.key)
            }
        }
        .onDisappear {
            // A waiting sign-in holds the redirect port until it times out.
            for task in signInTasks.values { task.cancel() }
            signInTasks = [:]
        }
    }

    /// The connection a key is bound to, when it is.
    private func boundConnection(_ key: String) -> WorkflowConnection? {
        bindings.secrets[key].flatMap { connections.connection(binding: $0) }
    }

    /// The bound sign-in, when it has expired: signing in renews it in place.
    private func expiredConnection(_ key: String) -> WorkflowConnection? {
        boundConnection(key).flatMap { $0.kind == .oauth2 && $0.needsSignIn() ? $0 : nil }
    }

    private func suggestedConnectionName(_ secret: SecretRequirement) -> String {
        if let provider = secret.provider.flatMap(ConnectionProviders.provider(id:)) { return provider.name }
        if let host = secret.serviceHost { return host }
        return secret.label
    }

    @ViewBuilder
    private func connectionControls(_ secret: SecretRequirement, missing: Bool) -> some View {
        let candidates = connections.candidates(for: secret).filter { $0.id != boundConnection(secret.key)?.id }
        if let bound = boundConnection(secret.key) {
            HStack(spacing: 6) {
                Image(systemName: "link")
                Text(L("Uses the session “\(bound.name)”"))
                if bound.needsSignIn() {
                    Text("Sign-in expired", bundle: .module).foregroundColor(theme.status.warning.foreground)
                }
            }
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.secondary)
        }
        ForEach(candidates) { connection in
            Button {
                onSaved(secret.key, connection.binding)
            } label: {
                Label(L("Use the session “\(connection.name)”"), systemImage: "link")
                    .textStyle(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.text.link)
            .settingsLandingAnchor("workflows.connections")
        }
        if let spec = secret.oauth2 {
            oauthControls(secret, spec: spec)
        }
    }

    @ViewBuilder
    private func oauthControls(_ secret: SecretRequirement, spec: OAuth2Spec) -> some View {
        let host = spec.serviceHost ?? L("the service")
        let provider = secret.provider.flatMap(ConnectionProviders.provider(id:))
        let service = provider?.name ?? host
        let waiting = signInTasks[secret.key] != nil
        // The expired connection already holds its client id and secret.
        let renews = expiredConnection(secret.key) != nil
            && (sessionNames[secret.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        VStack(alignment: .leading, spacing: theme.space.s8) {
            if spec.clientID == nil, !renews {
                Text(L("Sign in with your own \(service) app"))
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Group {
                    if let steps = provider?.oauthHelp {
                        Text(verbatim: steps)
                    } else if spec.requiresClientSecret {
                        Text(
                            L("Create an OAuth app in \(host)'s developer settings, add the redirect URL below, then paste its client ID and client secret.")
                        )
                    } else {
                        Text(L("Create an OAuth app in \(host)'s developer settings, add the redirect URL below, then paste its client ID."))
                    }
                }
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if let link = provider?.appSetupURL, let url = URL(string: link) {
                    Button {
                        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
                    } label: {
                        Label(L("Open \(service) developer settings"), systemImage: "arrow.up.right.square")
                            .textStyle(.footnote)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.text.link)
                }
                SettingsFieldRow(label: L("Redirect URL"), verbatimLabel: true) {
                    HStack(spacing: theme.space.s6) {
                        Text(verbatim: OAuth2ConnectionFlow.redirectURL)
                            .font(SettingsFont.monoSmall)
                            .foregroundColor(theme.text.primary)
                            .textSelection(.enabled)
                        SettingsIconButton("doc.on.doc", help: L("Copy redirect URL"), size: .compact) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(OAuth2ConnectionFlow.redirectURL, forType: .string)
                        }
                    }
                }
                SettingsFieldRow(label: L("Client ID"), verbatimLabel: true) {
                    SettingsTextField(
                        placeholder: L("From the app's settings on \(host)"),
                        text: Binding(get: { clientIDs[secret.key] ?? "" }, set: { clientIDs[secret.key] = $0 }),
                        monospaced: true
                    )
                }
            }
            if spec.requiresClientSecret, !renews {
                SettingsFieldRow(label: L("Client secret"), verbatimLabel: true) {
                    SettingsTextField(
                        placeholder: "",
                        text: Binding(get: { clientSecrets[secret.key] ?? "" }, set: { clientSecrets[secret.key] = $0 }),
                        monospaced: true, isSecure: true, revealable: true
                    )
                }
            }
            if !connections.candidates(for: secret).filter({ $0.service == spec.serviceHost }).isEmpty {
                SettingsTextField(
                    placeholder: L("New session name, e.g. Work"),
                    text: Binding(get: { sessionNames[secret.key] ?? "" }, set: { sessionNames[secret.key] = $0 })
                )
                .frame(maxWidth: 260)
            }
            HStack(spacing: theme.space.s8) {
                if waiting {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the browser…", bundle: .module)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                    Button {
                        cancelSignIn(secret.key)
                    } label: {
                        Text("Cancel", bundle: .module)
                    }
                    .assignedSettingsButtonStyle(.secondary)
                } else {
                    Button {
                        signIn(secret, spec: spec)
                    } label: {
                        Label(renews ? L("Sign In Again") : L("Sign in to \(host)"), systemImage: "person.badge.key")
                    }
                    .assignedSettingsButtonStyle(.secondary)
                    .disabled(
                        !renews
                            && ((spec.clientID == nil && (clientIDs[secret.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                                || (spec.requiresClientSecret && (clientSecrets[secret.key] ?? "").isEmpty)))
                }
                if !spec.scopes.isEmpty {
                    Text(L("Asks for: \(spec.scopes.joined(separator: ", "))"))
                        .font(SettingsFont.footnote).foregroundColor(theme.text.tertiary)
                        .lineLimit(2)
                }
            }
            if waiting, spec.clientID == nil {
                Text(L("If \(service) shows a redirect URL error, check that the app lists the Redirect URL above, then cancel and sign in again."))
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = signInErrors[secret.key] {
                Text(error).font(SettingsFont.rowDescription).foregroundColor(theme.status.error.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func cancelSignIn(_ key: String) {
        signInTasks[key]?.cancel()
        signInTasks[key] = nil
    }

    private func signIn(_ secret: SecretRequirement, spec: OAuth2Spec) {
        signInErrors[secret.key] = nil
        let clientID = clientIDs[secret.key]?.trimmingCharacters(in: .whitespaces)
        let clientSecret = clientSecrets[secret.key]?.trimmingCharacters(in: .whitespaces)
        let typed = (sessionNames[secret.key] ?? "").trimmingCharacters(in: .whitespaces)
        let name = typed.isEmpty ? suggestedConnectionName(secret) : typed
        let key = secret.key
        let renewing = typed.isEmpty ? expiredConnection(key) : nil
        signInTasks[key] = Task { @MainActor in
            do {
                let connection: WorkflowConnection
                if let renewing {
                    try await WorkflowConnectionActions.signInAgain(renewing, clientSecret: clientSecret)
                    connection = renewing
                } else {
                    connection = try await OAuth2ConnectionFlow.signIn(
                        spec: spec, name: name, clientID: clientID, clientSecret: clientSecret)
                }
                clientSecrets[key] = nil
                sessionNames[key] = nil
                onSaved(key, connection.binding)
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { signInErrors[key] = WorkflowErrorText.text(error) }
            }
            if !Task.isCancelled { signInTasks[key] = nil }
        }
    }

    /// Other installed workflows on this Mac that hold a value for the
    /// same key. Reusing one copies the value into this scope.
    private func reusable(_ key: String) -> [InstalledWorkflow] {
        InstalledWorkflowStore.shared.workflows.filter { other in
            other.id != scope && other.template.requirements.secrets.contains { $0.key == key }
                && WorkflowCredentials.isSetUp(scope: other.id, key: key)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The Keys entry that fills `key` for this workflow, when it has a value.
    private func sharedKey(_ key: String) -> String? {
        let resolved = WorkflowCredentials.slot(scope: scope, key: key).effectiveKey()
        return CredentialResolver.source(resolved, agentId: nil) == .global ? resolved : nil
    }

    private func row(_ secret: SecretRequirement) -> some View {
        let account = WorkflowSecretsKeychain.secretAccount(scope: scope, key: secret.key)
        let item = items.first { $0.value == secret.key }
        let confirming = item != nil && reconfirm.contains(secret.key)
        let missing = item != nil && !confirming
        // A plain key can wait: the workflow installs, and Keys lists it as missing.
        let canWait = missing && item?.isMissingKey == true && item?.isBlocking == false
        let others = missing ? reusable(secret.key) : []
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(secret.label).font(SettingsFont.compactLabel).foregroundColor(theme.text.primary)
                Text(secret.key).font(SettingsFont.monoSmall).foregroundColor(theme.text.tertiary)
                Spacer()
                Text(canWait ? L("Not set") : missing ? L("Missing") : confirming ? L("Confirm") : L("Stored"))
                    .font(SettingsFont.chip)
                    .foregroundColor(item != nil ? theme.status.warning.foreground : theme.status.success.foreground)
            }
            if let help = secret.help {
                Text(help).font(SettingsFont.rowDescription).foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if boundConnection(secret.key) == nil, let shared = sharedKey(secret.key) {
                Label(L("Uses the shared \(shared) in the Vault"), systemImage: "key")
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
            }
            if canWait {
                Text(
                    "Optional for now. You can add it later in Settings → Vault, shared by all agents or for one agent; Missing Keys lists it until then.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if confirming, let item {
                Text(item.detail).font(SettingsFont.rowDescription).foregroundColor(theme.status.warning.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    onSaved(secret.key, account)
                } label: {
                    Text("Keep Current Value", bundle: .module)
                }
                .assignedSettingsButtonStyle(.secondary)
            }
            if secret.oauth2 != nil {
                connectionControls(secret, missing: missing)
                Divider()
                Text("Or paste a token instead", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                if let tokenHelp = secret.provider.flatMap(ConnectionProviders.provider(id:))?.tokenHelp {
                    Text(verbatim: tokenHelp)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                pasteControls(secret, missing: missing, account: account)
            } else {
                pasteControls(secret, missing: missing, account: account)
                connectionControls(secret, missing: missing)
            }
            ForEach(others) { other in
                Button {
                    guard WorkflowCredentials.copy(key: secret.key, from: other.id, to: scope) else { return }
                    onSaved(secret.key, account)
                } label: {
                    Label(L("Use the value saved for \(other.name)"), systemImage: "arrow.right.doc.on.clipboard")
                        .textStyle(.footnote)
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.text.link)
            }
        }
        .padding(theme.space.s16)
        .settingsChrome(.inset)
    }

    /// The field that takes a pasted value, with where to keep it.
    @ViewBuilder
    private func pasteControls(_ secret: SecretRequirement, missing: Bool, account: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SettingsTextField(
                    placeholder: secret.oauth2 != nil ? L("Token") : missing ? L("Value") : L("Replace value"),
                    text: Binding(get: { values[secret.key] ?? "" }, set: { values[secret.key] = $0 }),
                    isSecure: true
                )
                Button {
                    let value = values[secret.key] ?? ""
                    guard !value.isEmpty else { return }
                    if keepAsConnection.contains(secret.key) {
                        let name = (connectionNames[secret.key] ?? "").trimmingCharacters(in: .whitespaces)
                        guard
                            let connection = connections.addValue(
                                name: name.isEmpty ? suggestedConnectionName(secret) : name,
                                service: secret.serviceHost, value: value)
                        else { return }
                        values[secret.key] = nil
                        onSaved(secret.key, connection.binding)
                        return
                    }
                    let saved =
                        separateValue.contains(secret.key)
                        ? WorkflowCredentials.saveSeparate(
                            value, scope: scope, key: secret.key, workflowName: workflowName)
                        : WorkflowCredentials.save(value, scope: scope, key: secret.key)
                    guard saved else { return }
                    values[secret.key] = nil
                    onSaved(secret.key, account)
                } label: {
                    Text("Save", bundle: .module)
                }
                .assignedSettingsButtonStyle(.secondary)
                .disabled((values[secret.key] ?? "").isEmpty)
            }
            if !(values[secret.key] ?? "").isEmpty {
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { keepAsConnection.contains(secret.key) },
                        set: { on in
                            if on { keepAsConnection.insert(secret.key) } else { keepAsConnection.remove(secret.key) }
                        }
                    )) {
                        Text("Keep as a connection other workflows can use", bundle: .module)
                            .font(SettingsFont.rowDescription)
                    }
                    .settingsCheckbox()
                    if keepAsConnection.contains(secret.key) {
                        SettingsTextField(
                            placeholder: suggestedConnectionName(secret),
                            text: Binding(get: { connectionNames[secret.key] ?? "" }, set: { connectionNames[secret.key] = $0 })
                        )
                        .frame(maxWidth: 200)
                    }
                }
                .settingsLandingAnchor("workflows.connections")
                if !keepAsConnection.contains(secret.key), sharedKey(secret.key) != nil {
                    Toggle(isOn: Binding(
                        get: { separateValue.contains(secret.key) },
                        set: { on in
                            if on { separateValue.insert(secret.key) } else { separateValue.remove(secret.key) }
                        }
                    )) {
                        Text("Use a separate value for this workflow", bundle: .module)
                            .font(SettingsFont.rowDescription)
                    }
                    .settingsCheckbox()
                }
            }
        }
    }
}

// MARK: - Agents

/// The agents a workflow's agent steps hand work to. Each runs as the
/// template names it, or as another agent chosen here. Unattended runs need
/// the hand-off allowed ahead of time, for this workflow only.
struct WorkflowAgentsStep: View {
    @Environment(\.theme) private var theme
    let agents: [AgentRequirement]
    let bindings: InstallBindings
    let items: [SetupItem]
    /// The workflow's own Allow Without Asking; nil hides it (a draft,
    /// whose test runs are watched).
    var allowsWithoutAsking: Bool?
    var onSetAllowsWithoutAsking: (Bool) -> Void = { _ in }
    /// Called after an agent is added to Allowed subagents.
    var onAllowed: () -> Void = {}
    let onChoose: (String, String?) -> Void

    @ObservedObject private var agentStore = AgentManager.shared
    @ObservedObject private var rosters = WorkspaceRosterStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if items.isEmpty {
                StepDoneBanner(text: L("Every agent this workflow asks is reachable from this Mac."))
            }
            Text(
                "Agent steps hand a task to another agent, which answers with its own model, tools, and permissions. A teammate's shared agent runs on their Mac, which pays for it; only the task text is sent.",
                bundle: .module
            )
            .font(SettingsFont.caption)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
            ForEach(agents) { req in row(req) }
            if let allowsWithoutAsking { unattendedRow(allowsWithoutAsking) }
        }
        .settingsLandingAnchor("workflows.setup.agents")
        .task {
            if rosters.lastRefreshedAt == nil { await rosters.refresh(reason: .manual) }
        }
    }

    private func row(_ req: AgentRequirement) -> some View {
        let bound = bindings.agents[req.id]
        let issue = items.first { $0.value == req.id }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: req.isShared ? "person.2" : "person.crop.circle")
                    .glyphSize(12).foregroundColor(theme.text.tertiary)
                Text(req.name).font(SettingsFont.compactLabel).foregroundColor(theme.text.primary)
                if req.isShared { StatusChip(L("Shared"), tone: .neutral) }
                Spacer()
                Text(issue == nil ? L("Reachable") : bound == nil ? L("Needs a choice") : L("Not reachable"))
                    .font(SettingsFont.chip)
                    .foregroundColor(issue == nil ? theme.status.success.foreground : theme.status.warning.foreground)
            }
            HStack(spacing: 8) {
                Text(verbatim: bound.map(label(forBinding:)) ?? L("Not chosen"))
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(bound == nil ? theme.text.tertiary : theme.text.secondary)
                    .lineLimit(1)
                Spacer()
                SettingsActionMenu(accessibilityLabel: L("Choose an agent")) {
                    Button(L("As the workflow names it")) { onChoose(req.id, InstallBindings.agentByName) }
                    Section(L("On This Mac")) {
                        ForEach(agentStore.agents.filter { $0.id != Agent.defaultId }) { agent in
                            Button(agent.name) { onChoose(req.id, agent.id.uuidString) }
                        }
                    }
                    let shared = AgentTargetResolver.liveSharedAgents()
                    if !shared.isEmpty {
                        Section(L("Shared in Workspaces")) {
                            ForEach(shared, id: \.ref) { entry in
                                Button(AgentTargetResolver.qualifiedDisplayName(for: entry.ref)) {
                                    onChoose(req.id, entry.ref.key)
                                }
                            }
                        }
                    }
                } label: {
                    Text("Choose…", bundle: .module)
                }
                .fixedSize()
            }
            if let issue {
                Text(issue.detail).font(SettingsFont.rowDescription).foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if issue != nil, let target = notAllowedTarget(req, bound: bound) {
                SettingsButton(.secondary, "Add to Allowed subagents", icon: "plus", size: .compact) {
                    AgentNodeExecutor.allowForOrchestrator(target)
                    onAllowed()
                }
            }
        }
        .padding(theme.space.s16)
        .settingsChrome(.inset)
    }

    /// The agent the step reaches when the only problem is that it isn't in
    /// the Orchestrator's Allowed subagents.
    private func notAllowedTarget(_ req: AgentRequirement, bound: String?) -> AgentNodeExecutor.Target? {
        guard bound != nil,
            case .target(let target) = AgentNodeExecutor.resolve(req, binding: bound, in: .live()),
            !AgentNodeExecutor.isAllowed(target)
        else { return nil }
        return target
    }

    private func unattendedRow(_ on: Bool) -> some View {
        SettingsToggle(
            title: "Allow Without Asking",
            description: on
                ? L("This workflow's agent steps run without an approval card, including in scheduled and event runs. Runs a teammate starts still need your approval, and an agent's Deny still applies.")
                : L("Each run asks before handing a task to another agent. Scheduled and event runs nobody watches stop at that step until this is on."),
            isOn: Binding(get: { on }, set: onSetAllowsWithoutAsking))
        .settingsLandingAnchor("workflows.setup.agentsUnattended")
    }

    private func label(forBinding bound: String) -> String {
        if bound == InstallBindings.agentByName { return L("As the workflow names it") }
        if let id = UUID(uuidString: bound), let agent = agentStore.agent(for: id) { return agent.name }
        if let ref = WorkspaceAgentRef(key: bound) { return AgentTargetResolver.qualifiedDisplayName(for: ref) }
        return bound
    }
}

// MARK: - Folders

/// The fixed folders a workflow's steps read from or save to. Each is
/// chosen once on this Mac; only the key and the author's hint travel with
/// the template.
struct WorkflowFoldersStep: View {
    @Environment(\.theme) private var theme
    let folders: [FolderRequirement]
    let bindings: InstallBindings
    let items: [SetupItem]
    let onChoose: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if items.isEmpty {
                StepDoneBanner(text: L("Every folder this workflow uses is chosen."))
            }
            Text(
                "Steps of this workflow can only use the folders you choose here, the folder of the chat that runs it, and its own workspace.",
                bundle: .module
            )
            .font(SettingsFont.caption)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
            ForEach(folders) { folder in row(folder) }
        }
    }

    private func row(_ folder: FolderRequirement) -> some View {
        let bound = bindings.folders[folder.key]
        let issue = items.first { $0.value == folder.key }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "folder").glyphSize(12).foregroundColor(theme.text.tertiary)
                Text(folder.label).font(SettingsFont.compactLabel).foregroundColor(theme.text.primary)
                StatusChip(folder.access.displayName, tone: .neutral)
                Spacer()
                Text(issue == nil ? L("Chosen") : L("Missing"))
                    .font(SettingsFont.chip)
                    .foregroundColor(issue == nil ? theme.status.success.foreground : theme.status.warning.foreground)
            }
            if let help = folder.help, !help.isEmpty {
                Text(help).font(SettingsFont.rowDescription).foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text(verbatim: bound ?? folder.hint.map { L("Suggested: \($0.path)") } ?? L("No folder chosen"))
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(bound == nil ? theme.text.tertiary : theme.text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    if let path = Self.chooseFolder(label: folder.label, startingAt: bound ?? folder.hint?.path) {
                        onChoose(folder.key, path)
                    }
                } label: {
                    Text("Choose…", bundle: .module)
                }
                .assignedSettingsButtonStyle(.secondary)
            }
            if let issue, bound != nil {
                Text(issue.detail).font(SettingsFont.rowDescription).foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(theme.space.s16)
        .settingsChrome(.inset)
    }

    @MainActor
    static func chooseFolder(label: String, startingAt path: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L("Choose the folder to use for \(label).")
        panel.prompt = L("Choose")
        if let path {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { panel.directoryURL = url }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.standardized.path
    }
}

// MARK: - Tools

struct WorkflowToolsStep: View {
    @Environment(\.theme) private var theme
    let items: [SetupItem]
    /// With a template, each MCP server it names gets a card that sets it
    /// up in place. Without one, only the issues and tab links show.
    var template: Template? = nil
    var bindings = InstallBindings()
    var onBindServer: (String, String?) -> Void = { _, _ in }
    /// Servers whose cards the caller draws above this step.
    var cardsAbove: [String] = []
    let onLeave: (ManagementTab) -> Void
    let onCheckAgain: () -> Void

    private var servers: [String] { template?.requirements.mcpServers ?? [] }

    /// Issues a server card does not already show.
    private var otherItems: [SetupItem] {
        items.filter { !($0.kind == .mcpServer && (servers + cardsAbove).contains($0.value)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if items.isEmpty {
                StepDoneBanner(text: L("Every server, plugin, and tool needed here is available."))
            }
            if let template {
                ForEach(servers, id: \.self) { name in
                    WorkflowMCPServerCard(
                        name: name, template: template, bindings: bindings,
                        onBind: { onBindServer(name, $0) })
                }
            }
            if !otherItems.isEmpty { StepIssueList(items: otherItems) }
            VStack(alignment: .leading, spacing: 12) {
                StepActionButton(title: "Open MCP Servers", icon: "server.rack", primary: template == nil && cardsAbove.isEmpty) {
                    onLeave(.tools)
                }
                if template?.requirements.plugins.isEmpty == false || template == nil {
                    StepActionButton(title: "Open Plugins", icon: "puzzlepiece.extension") { onLeave(.skills) }
                }
                OrSeparator()
                StepActionButton(title: "Check Again", icon: "arrow.clockwise", primary: false, action: onCheckAgain)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Dependencies

/// Declared packages and whether each is installed in the workflow's own
/// sandbox environment. Install runs every missing manager in order and
/// streams the installer's lines; Check Again re-reads the manifest.
struct WorkflowDependenciesStep: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var sandboxState = SandboxManager.State.shared

    let dependencies: [WorkflowDependency]
    /// Template id the environment is keyed by.
    let environmentID: UUID
    let items: [SetupItem]
    let onLeave: (ManagementTab) -> Void
    let onChanged: () -> Void

    @State private var installing = false
    @State private var log: [String] = []
    @State private var failure: String?

    private var sandboxReady: Bool {
        switch sandboxState.status {
        case .notProvisioned, .error: return false
        default: return true
        }
    }

    private var needsInstall: Bool {
        items.contains { item in dependencies.contains { $0.id == item.value } }
    }

    private var unsupported: [WorkflowDependency] {
        dependencies.filter { WorkflowSandboxEnvironment.shared.status(of: $0, environmentID: environmentID) == .unsupportedHere }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if items.isEmpty {
                StepDoneBanner(text: L("Every dependency is installed in this workflow's sandbox."))
            }
            Text(
                "Shell steps of this workflow run in its own sandbox environment, not on your Mac. The packages below are installed there once and reused by every run.",
                bundle: .module
            )
            .font(SettingsFont.caption)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
            ForEach(dependencies) { dependency in row(dependency) }
            let otherItems = items.filter { item in !dependencies.contains { $0.id == item.value } }
            if !otherItems.isEmpty { StepIssueList(items: otherItems) }
            if !log.isEmpty { logView }
            VStack(alignment: .leading, spacing: 12) {
                if needsInstall, unsupported.isEmpty {
                    StepActionButton(
                        title: installing ? "Installing…" : (sandboxReady ? "Install" : "Install (starts the sandbox)"),
                        icon: "arrow.down.circle", isLoading: installing, action: install)
                    .disabled(installing || !sandboxReady)
                }
                StepActionButton(title: "Open Sandbox", icon: "shippingbox", primary: !sandboxReady) { onLeave(.sandbox) }
                OrSeparator()
                StepActionButton(title: "Check Again", icon: "arrow.clockwise", primary: false) {
                    WorkflowSandboxEnvironment.shared.resetCache()
                    onChanged()
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func row(_ dependency: WorkflowDependency) -> some View {
        let status = WorkflowSandboxEnvironment.shared.status(of: dependency, environmentID: environmentID)
        let issue = items.first { $0.value == dependency.id }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .glyphSize(12)
                    .foregroundColor(theme.text.tertiary)
                Text(dependency.packages.joined(separator: ", "))
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(2)
                StatusChip(dependency.manager.displayName, tone: .neutral)
                Spacer()
                Text(Self.label(status))
                    .font(SettingsFont.chip)
                    .foregroundColor(
                        status == .installed ? theme.status.success.foreground : theme.status.warning.foreground
                    )
            }
            if !dependency.binaries.isEmpty {
                Text(L("Provides: \(dependency.binaries.joined(separator: ", "))"))
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
            }
            if let issue, status != .installed {
                Text(issue.detail)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(theme.space.s16)
        .settingsChrome(.inset)
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(log.suffix(12).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(line == failure ? theme.status.warning.foreground : theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(theme.space.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.inset)
    }

    static func label(_ status: WorkflowDependencyStatus) -> String {
        switch status {
        case .installed: return L("Installed")
        case .notInstalled: return L("Not installed")
        case .stale: return L("Needs reinstall")
        case .unsupportedHere: return L("Unavailable here")
        case .reinstallOnRun: return L("Reinstalls on next run")
        }
    }

    private func install() {
        guard !installing else { return }
        installing = true
        failure = nil
        log = []
        let toInstall = dependencies.filter {
            WorkflowSandboxEnvironment.shared.status(of: $0, environmentID: environmentID) != .installed
        }
        Task { @MainActor in
            do {
                try await WorkflowSandboxEnvironment.shared.install(toInstall, environmentID: environmentID) { line in
                    Task { @MainActor in log.append(line) }
                }
            } catch {
                let message = WorkflowErrorText.text(error)
                if log.last != message { log.append(message) }
                failure = message
            }
            installing = false
            onChanged()
        }
    }
}

// MARK: - Review

struct WorkflowReviewStep: View {
    @Environment(\.theme) private var theme
    let subject: WorkflowSetupSubject
    let report: SetupReport
    @Binding var exampleToRun: String?
    let onRename: (String) -> Void

    @State private var name = ""

    private var isUpdate: Bool {
        if case .update = subject.mode { return true }
        return false
    }

    var body: some View {
        let reqs = subject.template.requirements
        let def = subject.template.workflow
        VStack(alignment: .leading, spacing: 16) {
            if subject.mode == .install || isUpdate {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel("Workflow Name")
                    SettingsTextField(placeholder: L("e.g., Client Intake"), text: $name, icon: "textformat")
                        .onChange(of: name) { _, newValue in onRename(newValue) }
                    // Updating keeps the name agents call unless the person
                    // takes the new version's name here.
                    let pinned = subject.template.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if isUpdate, !pinned.isEmpty, pinned != name.trimmingCharacters(in: .whitespacesAndNewlines) {
                        HStack(spacing: 6) {
                            Text(
                                verbatim: L(
                                    "Version \(subject.template.version) is named “\(pinned)”. Updating keeps the current name unless you change it."
                                )
                            )
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(theme.text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            SettingsButton(.tertiary, L("Use “\(pinned)”"), size: .compact, verbatim: true) {
                                name = pinned
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                let rows = summaryRows(reqs, def)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Rectangle().fill(theme.border.subtle).frame(height: theme.stroke.default) }
                    row(item.icon, item.label, item.value)
                }
            }
            .padding(.horizontal, theme.space.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsChrome(.inset)
            if report.isClean {
                StepDoneBanner(text: L("Everything this workflow needs is in place."))
            } else {
                Text(
                    report.hasBlockers
                        ? "Some items still block this workflow. Go back to fix them."
                        : "Nothing blocks this workflow. The notes below are worth a look.",
                    bundle: .module
                )
                .textStyle(.caption)
                .foregroundColor(theme.text.secondary)
                AgentSetupChecklistView(report: report)
            }
            if let examples = def?.examples, !examples.isEmpty, subject.installedID != nil || subject.mode == .install {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel("Run an Example")
                    SettingsMenuPicker(selection: $exampleToRun) {
                        Text("Don't run anything", bundle: .module).tag(String?.none)
                        ForEach(examples, id: \.name) { example in
                            Text(example.name).tag(Optional(example.name))
                        }
                    }
                    .fixedSize()
                    Text(
                        "The example runs in a new workflow tab after you finish, so you can check the workflow works on this Mac.",
                        bundle: .module
                    )
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { if name.isEmpty { name = subject.name } }
    }

    private typealias SummaryRow = (icon: String, label: String, value: String)

    static func agentChoiceLabel(_ binding: String?) -> String {
        switch binding {
        case nil: return L("Not chosen")
        case InstallBindings.agentByName: return L("As named")
        default: return L("Another agent")
        }
    }

    private func summaryRows(_ reqs: TemplateRequirements, _ def: WorkflowDefinition?) -> [SummaryRow] {
        var rows: [SummaryRow] = []
        let steps = def?.nodes.count ?? 0
        rows.append(("square.stack.3d.up", L("Steps"), "\(steps)"))
        for slot in reqs.models {
            let model = subject.bindings.models[slot.slot] ?? WorkflowModelChoices.suggested(slot)
            rows.append(
                ("cube", WorkflowSummary.slotLabel(slot.slot, in: def),
                 model.map(WorkflowModelChoices.displayName) ?? L("Default model")))
        }
        if !reqs.secrets.isEmpty {
            rows.append(("key", L("Secrets"), "\(reqs.secrets.count)"))
        }
        for folder in reqs.folders {
            rows.append(("folder", folder.label, subject.bindings.folders[folder.key] ?? L("Not chosen")))
        }
        for agent in reqs.agents {
            rows.append(
                (agent.isShared ? "person.2" : "person.crop.circle", L("Asks \(agent.name)"),
                 Self.agentChoiceLabel(subject.bindings.agents[agent.id])))
        }
        if let def, !def.codeNodes.isEmpty {
            rows.append(
                ("chevron.left.forwardslash.chevron.right", L("Code steps"),
                 reqs.network.isEmpty
                    ? L("\(def.codeNodes.count), no network")
                    : L("\(def.codeNodes.count), can reach \(reqs.network.joined(separator: ", "))")))
        }
        if !reqs.mcpServers.isEmpty { rows.append(("server.rack", L("MCP servers"), reqs.mcpServers.joined(separator: ", "))) }
        if !reqs.plugins.isEmpty { rows.append(("puzzlepiece.extension", L("Plugins"), reqs.plugins.joined(separator: ", "))) }
        if !reqs.dependencies.isEmpty {
            rows.append(("shippingbox", L("Sandbox"), reqs.dependencies.map(\.summary).joined(separator: "; ")))
        }
        for tool in def?.calledTools ?? [] {
            rows.append(("wrench.and.screwdriver", tool.name, WorkflowToolCatalog.status(of: tool.name)))
        }
        return rows
    }

    private func row(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
            Image(systemName: icon).glyphSize(11).foregroundColor(theme.text.tertiary).frame(width: theme.space.s16)
            Text(verbatim: label)
                .textStyle(.bodySmall)
                .foregroundColor(theme.text.secondary)
                .lineLimit(2)
            Spacer(minLength: theme.space.s16)
            Text(verbatim: value)
                .textStyle(.bodySmall, weight: 500)
                .foregroundColor(theme.text.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, theme.space.s8 + theme.space.s2)
    }
}

extension WorkflowDefinition {
    /// True when any dialog field is remembered or prefilled from the
    /// last answer, so the workflow keeps saved answers.
    var hasRememberedFields: Bool {
        nodes.contains { node in
            guard case .dialog(let spec) = node.kind else { return false }
            return spec.fields.contains { field in
                if case .alwaysAsk(prefillLast: false) = field.persistence { return false }
                return true
            }
        }
    }
}
