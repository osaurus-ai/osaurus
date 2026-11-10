//
//  AgentSetupWizardView.swift
//  osaurus
//
//  Guided setup for an agent whose configuration this Mac cannot honour
//  yet: a model that is not installed, a working folder without access, a
//  knowledge grant with no collection, tools no server here provides, a
//  system permission the OS has not given. Steps are generated from an
//  `SetupReport`, so an agent with one gap gets one step plus Review.
//
//  Two modes, one view:
//   - `.draft(agent, template)`: Use Template. The agent does NOT exist
//     yet; every step edits the in-memory record and the primary button
//     creates the agent only when nothing blocks. Nothing is written
//     before that, so a template that cannot work here never produces a
//     broken agent.
//   - `.saved(id)`: Run Setup / first-open prompt / spawn refusal on an
//     agent that already exists. Steps write through `AgentManager`.
//
//  Guidance rule: the primary button is never disabled for a reason the
//  user cannot see. Tapping it with gaps left shows the reason in the
//  footer and glows the step that needs attention.
//

import AppKit
import SwiftUI

/// What the wizard works on.
enum AgentSetupSubject: Identifiable {
    case saved(UUID)
    case draft(Agent, template: AgentTemplate)

    var id: UUID {
        switch self {
        case .saved(let id): return id
        case .draft(let agent, _): return agent.id
        }
    }

    var isDraft: Bool {
        if case .draft = self { return true }
        return false
    }
}

struct AgentSetupWizardView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared

    let subject: AgentSetupSubject
    let onClose: () -> Void
    /// Draft mode: the agent was created. Saved mode: setup finished.
    var onFinished: (Agent) -> Void = { _ in }

    enum Step: Hashable {
        case model
        case folder
        case knowledge
        case tools
        case permissions
        case workflows
        case review

        var title: String {
            switch self {
            case .model: return L("Model")
            case .folder: return L("Working Folder")
            case .knowledge: return L("Knowledge")
            case .tools: return L("Tools")
            case .permissions: return L("Permissions")
            case .workflows: return L("Workflows")
            case .review: return L("Review")
            }
        }

        var icon: String {
            switch self {
            case .model: return "cube"
            case .folder: return "folder"
            case .knowledge: return "books.vertical"
            case .tools: return "wrench.and.screwdriver"
            case .permissions: return "lock.shield"
            case .workflows: return "flowchart"
            case .review: return "checkmark.seal"
            }
        }

        static func steps(for report: SetupReport) -> [Step] {
            var steps: [Step] = []
            let kinds = Set(report.items.map(\.kind))
            if kinds.contains(.model) { steps.append(.model) }
            if kinds.contains(.workingFolder) { steps.append(.folder) }
            if kinds.contains(.knowledgeCollection) { steps.append(.knowledge) }
            if kinds.contains(.mcpServer) || kinds.contains(.plugin) { steps.append(.tools) }
            if kinds.contains(.systemPermission) { steps.append(.permissions) }
            steps.append(.review)
            return steps
        }

        func items(in report: SetupReport) -> [SetupItem] {
            report.items.filter { item in
                switch self {
                case .model: return item.kind == .model
                case .folder: return item.kind == .workingFolder
                case .knowledge: return item.kind == .knowledgeCollection
                case .tools: return item.kind == .mcpServer || item.kind == .plugin
                case .permissions: return item.kind == .systemPermission
                case .workflows, .review: return false
                }
            }
        }
    }

    /// Draft-mode working copy. Saved mode reads `AgentManager` directly.
    @State private var draft: Agent?
    @State private var report: SetupReport?
    @State private var steps: [Step] = [.review]
    @State private var current: Step = .review
    @State private var hasAppeared = false
    @State private var footerWarning: String?
    /// Rail step glowing after a refused primary action.
    @State private var glowingStep: Step?
    @State private var glowClearTask: Task<Void, Never>?
    /// Add-provider form, presented over the wizard so configuring a
    /// provider never tears the wizard (and, in draft mode, the unsaved
    /// agent) down.
    @State private var showAddProvider = false
    /// Template workflows this agent calls. Installed before the agent.
    @State private var bundlePlan: AgentBundlePlan?
    @State private var workflowSetup: WorkflowBundleSetupRequest?
    @State private var oneModelForAll = true

    private var template: AgentTemplate? {
        if case .draft(_, let template) = subject { return template }
        return nil
    }

    private var agent: Agent? {
        switch subject {
        case .saved(let id): return agentManager.agent(for: id)
        case .draft: return draft
        }
    }

    private var currentIndex: Int { steps.firstIndex(of: current) ?? 0 }
    private var isLast: Bool { currentIndex == steps.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                stepRail
                    .frame(width: 200)
                    .layoutPriority(1)
                Divider()
                ScrollView {
                    Group {
                        if let report, let agent {
                            stepContent(agent: agent, report: report)
                        } else {
                            ProgressView()
                        }
                    }
                    .padding(theme.space.s24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 0, maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.surface.overlay)
            footer
        }
        .fittedSheetFrame(width: 820, height: 560)
        .settingsSheetSurface()
        .overlay(RoundedRectangle(cornerRadius: theme.radius.xlarge).stroke(theme.border.subtle, lineWidth: theme.stroke.default))
        .opacity(hasAppeared ? 1 : 0)
        .animation(theme.motion.quick, value: hasAppeared)
        .onAppear {
            hasAppeared = true
            if case .draft(let agent, _) = subject, draft == nil { draft = agent }
            refresh(rebuildSteps: true)
        }
        // Permissions granted in System Settings land here when the user
        // comes back; the step re-checks without a relaunch.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh(rebuildSteps: false)
        }
        .onChange(of: agentManager.agents) { _, _ in
            if !subject.isDraft { refresh(rebuildSteps: false) }
        }
        .sheet(isPresented: $showAddProvider) {
            RemoteProviderEditSheet(provider: nil) { provider, apiKey, oauthTokens in
                RemoteProviderManager.shared.addProvider(provider, apiKey: apiKey, oauthTokens: oauthTokens)
                Task { @MainActor in
                    // A new provider only becomes a pickable model once its
                    // catalog is fetched and the picker cache rebuilt.
                    await RemoteProviderManager.shared.refreshConnectedProviders()
                    await ModelPickerItemCache.shared.buildModelPickerItems()
                    refresh(rebuildSteps: false)
                }
            }
            .environment(\.theme, theme)
        }
        .sheet(item: $workflowSetup) { request in
            WorkflowBundleSetupView(
                subjects: request.subjects, onClose: { workflowSetup = nil },
                onLeave: { tab in
                    workflowSetup = nil
                    leave(to: tab)
                },
                onFinished: { _ in refresh(rebuildSteps: false) }
            )
            .environment(\.theme, theme)
        }
    }

    /// Hand the wizard off to another tab without losing it. The subject,
    /// including edits made to an unsaved draft, is parked on the shared
    /// management state; `AgentsView` reopens the wizard from there when the
    /// user comes back.
    private func leave(to tab: ManagementTab) {
        let resume: AgentSetupSubject
        if case .draft(let original, let template) = subject {
            resume = .draft(draft ?? original, template: template)
        } else {
            resume = subject
        }
        ManagementStateManager.shared.pendingSetupSubject = .agent(resume)
        onClose()
        AppDelegate.shared?.showManagementWindow(initialTab: tab)
    }

    @ViewBuilder
    private var header: some View {
        if let template {
            SettingsSheetHeader(
                icon: "square.on.square.dashed",
                title: "Create Agent from Template",
                subtitleText: L("Based on the \(template.name) template"),
                onClose: onClose
            )
        } else {
            SettingsSheetHeader(
                icon: "checklist",
                title: "Set Up Agent",
                subtitleText: agent?.name,
                onClose: onClose
            )
        }
    }

    // MARK: - Rail

    private var stepRail: some View {
        SetupStepRail(steps: steps, current: $current, glowing: glowingStep, title: \.title) { step in
            if step == .workflows, let bundlePlan {
                if !bundlePlan.pending.isEmpty { return .required }
                return bundlePlan.rows.allSatisfy { if case .installed = $0.state { true } else { false } }
                    ? .done : .optional
            }
            guard step != .review, let report else { return .none }
            let remaining = step.items(in: report)
            if remaining.isEmpty { return .done }
            return remaining.contains(where: \.isBlocking) ? .required : .optional
        }
    }

    // MARK: - Footer

    private var footer: some View {
        SettingsSheetFooter(
            primary: SettingsSheetFooter.Action(
                label: isLast ? (subject.isDraft ? "Create agent" : "Finish") : "Next",
                handler: { if isLast { finish() } else { advance() } }
            ),
            secondary: SettingsSheetFooter.Action(
                label: currentIndex == 0 ? (subject.isDraft ? "Cancel" : "Later") : "Back",
                handler: { if currentIndex == 0 { onClose() } else { goBack() } }
            ),
            hint: nil,
            warning: footerWarning
        )
    }

    private func advance() {
        guard currentIndex + 1 < steps.count else { return }
        withAnimation(theme.motion.quick) { current = steps[currentIndex + 1] }
    }

    private func goBack() {
        guard currentIndex > 0 else { return }
        withAnimation(theme.motion.quick) { current = steps[currentIndex - 1] }
    }

    /// Create (draft) or finish (saved). Refused with guidance while a
    /// blocking item remains.
    private func finish() {
        refresh(rebuildSteps: false)
        guard let agent, let report else { return }
        if let blocker = report.blocking.first,
            let step = steps.first(where: { !$0.items(in: report).filter(\.isBlocking).isEmpty })
        {
            warn(blocker.detail, glowing: step)
            return
        }
        if let first = bundlePlan?.pending.first {
            warn(L("Set up \(first.name) before creating the agent."), glowing: .workflows)
            return
        }
        var final = agent
        if let bundlePlan {
            var ids = final.settings.enabledWorkflowIDs
            for id in bundlePlan.enabledWorkflowIDs where !ids.contains(id) { ids.append(id) }
            final.settings.enabledWorkflowIDs = ids
        }
        // A `preferred` template whose model is still missing falls back to
        // the default model here, explicitly, after the user saw the step.
        if subject.isDraft, let pinned = final.defaultModel, !pinned.isEmpty,
            report.items.contains(where: { $0.kind == .model })
        {
            final.defaultModel = nil
        }
        switch subject {
        case .draft:
            let trimmed = final.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                warn(L("Give the agent a name before creating it."), glowing: .review)
                return
            }
            final.name = trimmed
            final.sourceTemplateName = template?.name
            AgentManager.shared.add(final)
            // `add` flags the agent for first-run setup; the check that just
            // passed is that setup, so clear it right away.
            SetupStateStore.shared.clear(final.id)
            onFinished(final)
        case .saved:
            if final != agent { AgentManager.shared.update(final) }
            SetupStateStore.shared.clear(final.id)
            _ = ToastManager.shared.success(L("\(final.name) is ready"))
            onFinished(final)
        }
        onClose()
    }

    private func warn(_ text: String, glowing step: Step) {
        withAnimation(theme.motion.quick) { footerWarning = text }
        glowClearTask?.cancel()
        glowingStep = nil
        glowingStep = step
        glowClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            glowingStep = nil
        }
    }

    /// Apply a change to the subject: the draft in memory, or the saved
    /// agent through the manager. Re-checks afterwards.
    private func mutate(_ change: (inout Agent) -> Void) {
        switch subject {
        case .draft:
            guard var working = draft else { return }
            change(&working)
            draft = working
        case .saved(let id):
            guard var working = AgentManager.shared.agent(for: id) else { return }
            change(&working)
            AgentManager.shared.update(working)
        }
        withAnimation(theme.motion.quick) { footerWarning = nil }
        refresh(rebuildSteps: false)
    }

    /// Re-run the check. Steps are rebuilt only on first appear so a fixed
    /// step stays in the rail with its check mark instead of vanishing.
    private func refresh(rebuildSteps: Bool) {
        adoptTemplateGroupTools()
        guard let agent else { return }
        var fresh = SetupChecker.check(agent)
        if let template, template.modelPolicy == .preferred {
            fresh = Self.downgradeModelToAdvisory(fresh, requested: template.agent.model.valueOrNil)
        }
        report = fresh
        if let template, !template.workflowReferences.isEmpty {
            bundlePlan = AgentBundlePlan.make(for: template)
        }
        if rebuildSteps {
            var fresh = Step.steps(for: fresh)
            if bundlePlan != nil { fresh.insert(.workflows, at: fresh.count - 1) }
            steps = fresh
            current = steps.first ?? .review
        }
    }

    /// Pull in the tools of any template MCP server or plugin that exists
    /// now, e.g. one the user just added from the Tools step.
    private func adoptTemplateGroupTools() {
        guard let agent, let source = agent.sourceTemplateName,
            let groups = TemplateStore.shared.template(named: source)?.toolGroups, !groups.isEmpty
        else { return }
        let updated = SetupChecker.addingTemplateGroupTools(
            to: agent, groups: groups, available: ToolRegistry.shared.portableToolGroups())
        guard updated.manualToolNames != agent.manualToolNames else { return }
        switch subject {
        case .draft: draft = updated
        case .saved: AgentManager.shared.update(updated)
        }
    }

    /// `preferred` templates may fall back to the default model, so a
    /// missing model is a choice to confirm, not a blocker.
    private static func downgradeModelToAdvisory(_ report: SetupReport, requested: String?) -> SetupReport {
        let items = report.items.map { item -> SetupItem in
            guard item.kind == .model else { return item }
            let name = requested ?? item.value
            return SetupItem(
                kind: .model, severity: .advisory, title: item.title,
                detail: L("The template prefers \(name), which is not installed here. Create will use your default model unless you pick one."),
                value: item.value)
        }
        return SetupReport(subjectId: report.subjectId, items: items)
    }

    // MARK: - Step content

    @ViewBuilder
    private func stepContent(agent: Agent, report: SetupReport) -> some View {
        let items = current.items(in: report)
        VStack(alignment: .leading, spacing: 18) {
            SettingsDetailHeader(icon: current.icon, title: current.title)
            switch current {
            case .model:
                ModelStep(
                    agent: agent, items: items, mutate: mutate,
                    onAddProvider: { showAddProvider = true },
                    onBrowseModels: { leave(to: .models) }
                )
            case .folder: FolderStep(agent: agent, items: items, mutate: mutate)
            case .knowledge: KnowledgeStep(agent: agent, items: items, mutate: mutate)
            case .tools: ToolsStep(agent: agent, items: items, mutate: mutate, onLeave: { leave(to: $0) })
            case .permissions:
                PermissionsStep(
                    items: items, doneText: L("Every permission this agent needs is granted."),
                    onChanged: { refresh(rebuildSteps: false) })
            case .workflows:
                if let bundlePlan {
                    BundledWorkflowsStep(
                        plan: bundlePlan, agentModel: agent.defaultModel, oneModelForAll: $oneModelForAll,
                        onSetUp: {
                            let subjects = bundlePlan.setupSubjects(
                                oneModel: oneModelForAll ? agent.defaultModel : nil)
                            guard !subjects.isEmpty else { return }
                            workflowSetup = WorkflowBundleSetupRequest(subjects: subjects)
                        })
                }
            case .review:
                ReviewStep(
                    agent: agent, report: report, isDraft: subject.isDraft,
                    onRename: { newName in mutate { $0.name = newName } }
                )
            }
        }
    }
}

// MARK: - Model

private struct ModelStep: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var pickerCache = ModelPickerItemCache.shared
    let agent: Agent
    let items: [SetupItem]
    let mutate: ((inout Agent) -> Void) -> Void
    /// Opens the add-provider form over the wizard.
    let onAddProvider: () -> Void
    /// Leaves for the Models tab to download a bundle, parking the wizard
    /// so it can be resumed.
    let onBrowseModels: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if items.isEmpty {
                StepDoneBanner(text: L("This agent has a model it can run."))
            } else {
                StepIssueList(items: items)
            }
            // One control. Models the user already has are in the dropdown,
            // and getting a new one is a footer row inside that same
            // dropdown, so there is never a second button to explain.
            modelField
                .frame(maxWidth: .infinity)
        }
        .onAppear {
            // The cache is prewarmed at launch; guard the cold case anyway.
            if !pickerCache.isLoaded { pickerCache.prewarm() }
        }
    }

    /// Same dropdown as the Create Agent sheet's Default Model field.
    private var modelField: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsFieldLabel("Default Model")
            ModelSearchablePicker(
                items: pickerCache.items,
                selection: Binding(
                    get: { agent.defaultModel.flatMap { $0.isEmpty ? nil : $0 } },
                    set: { newModel in mutate { $0.defaultModel = newModel } }),
                noneTitle: L("Default (from global settings)"),
                actions: [
                    .init(id: "add-provider", title: L("Add a provider"), icon: "cloud", handler: onAddProvider),
                    .init(id: "download-model", title: L("Download a model"), icon: "arrow.down.circle", handler: onBrowseModels),
                ]
            )
        }
    }
}

// MARK: - Folder

private struct FolderStep: View {
    @Environment(\.theme) private var theme
    let agent: Agent
    let items: [SetupItem]
    let mutate: ((inout Agent) -> Void) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if items.isEmpty {
                StepDoneBanner(text: L("Osaurus can read and write \(agent.workingFolderPath ?? "")."))
            } else {
                StepIssueList(items: items)
                if let hint = agent.workingFolderPath {
                    Text("Hint from the agent's author: \(hint)", bundle: .module)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.tertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                StepActionButton(title: "Choose Folder…", icon: "folder.badge.plus") { chooseFolder() }
                OrSeparator()
                StepActionButton(title: "Remove Working Folder", icon: "folder.badge.minus", primary: false) {
                    mutate {
                        $0.workingFolderBookmark = nil
                        $0.workingFolderPath = nil
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func chooseFolder() {
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.title = L("Select Working Folder")
            panel.message = L("Choose the folder this agent works inside.")
            panel.prompt = L("Select")
            if let hint = agent.workingFolderPath {
                let expanded = (hint as NSString).expandingTildeInPath
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                    panel.directoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
                }
            }
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            guard let bookmark = FolderContextService.makeSecurityScopedBookmark(for: url) else {
                _ = ToastManager.shared.error(L("Failed to grant folder access"))
                return
            }
            let path = url.standardizedFileURL.path
            RecentFoldersStore.shared.record(path: path, bookmark: bookmark)
            mutate {
                $0.workingFolderBookmark = bookmark
                $0.workingFolderPath = path
            }
        }
    }
}

// MARK: - Knowledge

private struct KnowledgeStep: View {
    @Environment(\.theme) private var theme
    let agent: Agent
    let items: [SetupItem]
    let mutate: ((inout Agent) -> Void) -> Void

    @State private var collections: [KnowledgeCollection] = []
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if items.isEmpty {
                StepDoneBanner(text: L("The agent has knowledge to search."))
            } else {
                StepIssueList(items: items)
            }
            if collections.isEmpty {
                Text("No knowledge collections exist on this Mac yet.", bundle: .module)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel("Grant Collections")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(collections) { collection in
                        let granted = agent.settings.knowledgeCollectionIds.contains(collection.id)
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(collection.name).font(SettingsFont.compactLabel).foregroundColor(
                                    theme.text.primary
                                )
                                Text(collection.folderPath).font(SettingsFont.footnote).foregroundColor(
                                    theme.text.tertiary
                                ).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 12)
                            Toggle("", isOn: Binding(get: { granted }, set: { on in setGrant(collection.id, on) }))
                                .settingsSwitch()
                        }
                        .padding(theme.space.s8)
                        .settingsChrome(.inset)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                if !collections.isEmpty { OrSeparator() }
                StepActionButton(title: "Create From Folder…", icon: "folder.badge.plus") { createFromFolder() }
                    .disabled(isCreating)
                StepActionButton(title: "Turn Knowledge Off", icon: "book.closed", primary: false) {
                    mutate { $0.settings.knowledgeEnabled = false }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear { collections = KnowledgeCollectionStore.loadAll() }
    }

    private func setGrant(_ id: UUID, _ on: Bool) {
        mutate { working in
            var ids = working.settings.knowledgeCollectionIds
            if on, !ids.contains(id) { ids.append(id) }
            if !on { ids.removeAll { $0 == id } }
            working.settings.knowledgeCollectionIds = ids
        }
    }

    private func createFromFolder() {
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.title = L("Choose a Knowledge Folder")
            panel.prompt = L("Select")
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            isCreating = true
            defer { isCreating = false }
            let name = url.lastPathComponent
            let collection = await KnowledgeManager.shared.create(name: name, folderPath: url.standardizedFileURL.path)
            collections = KnowledgeCollectionStore.loadAll()
            setGrant(collection.id, true)
        }
    }
}

// MARK: - Tools

private struct ToolsStep: View {
    @Environment(\.theme) private var theme
    let agent: Agent
    let items: [SetupItem]
    let mutate: ((inout Agent) -> Void) -> Void
    /// Parks the wizard (and an unsaved draft) before switching tabs; a
    /// bare tab switch tears the sheet down and loses the draft.
    let onLeave: (ManagementTab) -> Void

    private var missingNames: [String] {
        items.flatMap { $0.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if items.isEmpty {
                StepDoneBanner(text: L("Every tool this agent lists is available here."))
            } else {
                StepIssueList(items: items)
                if !missingNames.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(missingNames, id: \.self) { name in
                            StatusChip(name, tone: .neutral)
                                .foregroundColor(theme.text.secondary)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                StepActionButton(title: "Open MCP Servers", icon: "server.rack") {
                    onLeave(.tools)
                }
                StepActionButton(title: "Open Plugins", icon: "puzzlepiece.extension") {
                    onLeave(.skills)
                }
                OrSeparator()
                StepActionButton(title: "Remove Missing Tools", icon: "minus.circle", primary: false) {
                    let missing = Set(missingNames)
                    mutate { $0.manualToolNames = ($0.manualToolNames ?? []).filter { !missing.contains($0) } }
                }
                .disabled(items.isEmpty)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Review

private struct ReviewStep: View {
    @Environment(\.theme) private var theme
    let agent: Agent
    let report: SetupReport
    let isDraft: Bool
    let onRename: (String) -> Void

    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isDraft {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel("Agent Name")
                    SettingsTextField(placeholder: L("e.g., Invoice Bot"), text: $name, icon: "textformat")
                        .onChange(of: name) { _, newValue in onRename(newValue) }
                }
                summary
            }
            if report.isClean {
                StepDoneBanner(
                    text: isDraft
                        ? L("Everything this template needs is in place. Create the agent when you are ready.")
                        : L("Everything checks out. The agent is ready to use."))
            } else if report.hasBlockers {
                Text(
                    isDraft
                        ? "Some items still block this agent. Go back to fix them before creating it."
                        : "Some items still block this agent. Go back to fix them, or choose Later to keep the agent as is.",
                    bundle: .module
                )
                .textStyle(.caption)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
                AgentSetupChecklistView(report: report)
            } else {
                Text(
                    "Nothing blocks this agent. The notes below are worth a look but do not stop it from running.",
                    bundle: .module
                )
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
                AgentSetupChecklistView(report: report)
            }
        }
        .onAppear { if name.isEmpty { name = agent.name } }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsFieldLabel("What Will Be Created")
            VStack(alignment: .leading, spacing: 4) {
                row("cube", agent.defaultModel.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? L("Default Model"))
                if agent.toolSelectionMode == .manual {
                    let toolCount = agent.manualToolNames?.count ?? 0
                    row("wrench.and.screwdriver", toolCount == 1 ? L("1 tool") : L("\(toolCount) tools"))
                } else {
                    row("sparkles", L("Auto tools"))
                }
                if agent.autonomousExec?.enabled == true { row("shippingbox", L("Sandbox on")) }
                if agent.settings.spawnDelegationEnabled { row("person.2", L("Can use subagents")) }
                if agent.memoryEnabled { row("brain", L("Memory on")) }
                if let path = agent.workingFolderPath, !path.isEmpty { row("folder", path) }
            }
            .padding(theme.space.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsChrome(.inset)
        }
    }

    private func row(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).glyphSize(11).foregroundColor(theme.text.tertiary).frame(width: 14)
            Text(text).font(SettingsFont.caption).foregroundColor(theme.text.secondary).lineLimit(1).truncationMode(
                .middle
            )
        }
    }
}

// MARK: - Workflows

struct WorkflowBundleSetupRequest: Identifiable {
    let id = UUID()
    let subjects: [WorkflowSetupSubject]
}

/// The workflows the template's agent calls. They are set up together in
/// one pass before the agent is created; requirements several of them share
/// are asked once.
private struct BundledWorkflowsStep: View {
    @Environment(\.theme) private var theme
    let plan: AgentBundlePlan
    let agentModel: String?
    @Binding var oneModelForAll: Bool
    let onSetUp: () -> Void

    private var needsWork: Bool {
        plan.rows.contains {
            switch $0.state {
            case .notInstalled, .updateAvailable: return true
            case .installed, .missingTemplate: return false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if plan.pending.isEmpty {
                StepDoneBanner(text: L("Every workflow this agent calls is installed."))
            } else {
                Text("Set up these workflows in one pass. The agent is created with them turned on.", bundle: .module)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)
            }
            ForEach(plan.rows) { row in
                HStack(spacing: 10) {
                    Image(systemName: icon(row.state))
                        .foregroundColor(color(row.state))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .font(SettingsFont.rowTitle)
                            .foregroundColor(theme.text.primary)
                        Text(status(row))
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(theme.text.tertiary)
                    }
                    Spacer()
                }
                .padding(theme.space.s8)
                .settingsChrome(.inset)
            }
            if needsWork {
                Button(action: onSetUp) {
                    Text(plan.pending.isEmpty ? "Update Workflows…" : "Set Up Workflows…", bundle: .module)
                }
                .assignedSettingsButtonStyle(.primary)
            }
            if plan.rows.contains(where: { $0.template?.requirements.models.isEmpty == false }) {
                Toggle(isOn: $oneModelForAll) {
                    Text(
                        agentModel.map { L("Use \($0) for every workflow model slot") }
                            ?? L("Use one model for every workflow model slot (pick the agent's model first)"))
                        .font(SettingsFont.caption)
                }
                .settingsCheckbox()
                .disabled(agentModel == nil)
            }
            sharedRequirements
        }
    }

    @ViewBuilder
    private var sharedRequirements: some View {
        let shared = plan.sharedRequirements
        let lines = [
            (L("Secrets"), shared.secrets), (L("MCP Servers"), shared.mcpServers), (L("Plugins"), shared.plugins),
            (L("Permissions"), shared.permissions),
        ].filter { !$0.1.isEmpty }
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Needed across these workflows", bundle: .module)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)
                ForEach(lines, id: \.0) { line in
                    Text("\(line.0): \(line.1.joined(separator: ", "))")
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                }
            }
        }
    }

    private func status(_ row: AgentBundlePlan.Row) -> String {
        switch row.state {
        case .installed: return L("Installed. The agent uses the copy on this Mac.")
        case .updateAvailable(_, let local):
            return L("Installed at version \(local); the template pins version \(row.reference.minVersion).")
        case .notInstalled: return L("Not installed yet.")
        case .missingTemplate: return L("Not included in this template. The agent is created without it.")
        }
    }

    private func icon(_ state: AgentBundlePlan.Row.State) -> String {
        switch state {
        case .installed: return "checkmark.circle.fill"
        case .updateAvailable: return "arrow.up.circle"
        case .notInstalled: return "circle.dashed"
        case .missingTemplate: return "exclamationmark.triangle"
        }
    }

    private func color(_ state: AgentBundlePlan.Row.State) -> Color {
        switch state {
        case .installed: return theme.status.success.foreground
        case .updateAvailable, .missingTemplate: return theme.status.warning.foreground
        case .notInstalled: return theme.text.secondary
        }
    }
}
