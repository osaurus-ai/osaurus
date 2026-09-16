//
//  AgentSetupWizardView.swift
//  osaurus
//
//  Guided setup for an agent whose configuration this Mac cannot honour
//  yet: a model that is not installed, a working folder without access, a
//  knowledge grant with no collection, tools no server here provides, a
//  system permission the OS has not given. Steps are generated from an
//  `AgentSetupReport`, so an agent with one gap gets one step plus Review.
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
        case review

        var title: String {
            switch self {
            case .model: return L("Model")
            case .folder: return L("Working Folder")
            case .knowledge: return L("Knowledge")
            case .tools: return L("Tools")
            case .permissions: return L("Permissions")
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
            case .review: return "checkmark.seal"
            }
        }

        static func steps(for report: AgentSetupReport) -> [Step] {
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

        func items(in report: AgentSetupReport) -> [AgentSetupItem] {
            report.items.filter { item in
                switch self {
                case .model: return item.kind == .model
                case .folder: return item.kind == .workingFolder
                case .knowledge: return item.kind == .knowledgeCollection
                case .tools: return item.kind == .mcpServer || item.kind == .plugin
                case .permissions: return item.kind == .systemPermission
                case .review: return false
                }
            }
        }
    }

    /// Draft-mode working copy. Saved mode reads `AgentManager` directly.
    @State private var draft: Agent?
    @State private var report: AgentSetupReport?
    @State private var steps: [Step] = [.review]
    @State private var current: Step = .review
    @State private var hasAppeared = false
    @State private var footerWarning: String?
    /// Rail step glowing after a refused primary action.
    @State private var glowingStep: Step?
    @State private var glowClearTask: Task<Void, Never>?

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
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 0, maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.primaryBackground)
            footer
        }
        .fittedSheetFrame(width: 820, height: 560)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.primaryBorder.opacity(0.5), lineWidth: 1))
        .opacity(hasAppeared ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: hasAppeared)
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
    }

    @ViewBuilder
    private var header: some View {
        if let template {
            AgentSheetHeader(
                icon: "square.on.square.dashed",
                title: "Create Agent from Template",
                subtitleText: L("Based on the \(template.name) template"),
                onClose: onClose
            )
        } else {
            AgentSheetHeader(
                icon: "checklist",
                title: "Set Up Agent",
                subtitleText: agent?.name,
                onClose: onClose
            )
        }
    }

    // MARK: - Rail

    private var stepRail: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                let remaining = report.map { step.items(in: $0) } ?? []
                let done = step != .review && remaining.isEmpty
                let blocked = remaining.contains(where: \.isBlocking)
                let isCurrent = step == current
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { current = step }
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(isCurrent ? theme.accentColor.opacity(0.15) : theme.tertiaryBackground)
                                .frame(width: 26, height: 26)
                            if done {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(theme.successColor)
                            } else {
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(isCurrent ? theme.accentColor : theme.secondaryText)
                            }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.title)
                                .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                                .foregroundColor(isCurrent ? theme.primaryText : theme.secondaryText)
                            if step != .review, report != nil {
                                Text(done ? L("Done") : (blocked ? L("Required") : L("Optional")))
                                    .font(.system(size: 10))
                                    .foregroundColor(done ? theme.successColor : (blocked ? theme.warningColor : theme.tertiaryText))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isCurrent ? theme.accentColor.opacity(0.08) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .settingsSearchHighlight(glowingStep == step)
            }
            Spacer()
        }
        .padding(12)
        .background(theme.secondaryBackground.opacity(0.5))
    }

    // MARK: - Footer

    private var footer: some View {
        AgentSheetFooter(
            primary: AgentSheetFooter.Action(
                label: isLast ? (subject.isDraft ? "Create Agent" : "Finish") : "Next",
                handler: { if isLast { finish() } else { advance() } }
            ),
            secondary: AgentSheetFooter.Action(
                label: currentIndex == 0 ? (subject.isDraft ? "Cancel" : "Later") : "Back",
                handler: { if currentIndex == 0 { onClose() } else { goBack() } }
            ),
            hint: nil,
            warning: footerWarning
        )
    }

    private func advance() {
        guard currentIndex + 1 < steps.count else { return }
        withAnimation(.easeInOut(duration: 0.18)) { current = steps[currentIndex + 1] }
    }

    private func goBack() {
        guard currentIndex > 0 else { return }
        withAnimation(.easeInOut(duration: 0.18)) { current = steps[currentIndex - 1] }
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
        var final = agent
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
            AgentManager.shared.add(final)
            // `add` flags the agent for first-run setup; the check that just
            // passed is that setup, so clear it right away.
            AgentSetupStateStore.shared.clear(final.id)
            onFinished(final)
        case .saved:
            if final != agent { AgentManager.shared.update(final) }
            AgentSetupStateStore.shared.clear(final.id)
            _ = ToastManager.shared.success(L("\(final.name) is ready"))
            onFinished(final)
        }
        onClose()
    }

    private func warn(_ text: String, glowing step: Step) {
        withAnimation(.easeOut(duration: 0.15)) { footerWarning = text }
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
        withAnimation(.easeOut(duration: 0.15)) { footerWarning = nil }
        refresh(rebuildSteps: false)
    }

    /// Re-run the check. Steps are rebuilt only on first appear so a fixed
    /// step stays in the rail with its check mark instead of vanishing.
    private func refresh(rebuildSteps: Bool) {
        guard let agent else { return }
        var fresh = AgentSetupChecker.check(agent)
        if let template, template.modelPolicy == .preferred {
            fresh = Self.downgradeModelToAdvisory(fresh, requested: template.agent.model.valueOrNil)
        }
        report = fresh
        if rebuildSteps {
            steps = Step.steps(for: fresh)
            current = steps.first ?? .review
        }
    }

    /// `preferred` templates may fall back to the default model, so a
    /// missing model is a choice to confirm, not a blocker.
    private static func downgradeModelToAdvisory(_ report: AgentSetupReport, requested: String?) -> AgentSetupReport {
        let items = report.items.map { item -> AgentSetupItem in
            guard item.kind == .model else { return item }
            let name = requested ?? item.value
            return AgentSetupItem(
                kind: .model, severity: .advisory, title: item.title,
                detail: L("The template prefers \(name), which is not installed here. Create will use your default model unless you pick one."),
                value: item.value)
        }
        return AgentSetupReport(agentId: report.agentId, items: items)
    }

    // MARK: - Step content

    @ViewBuilder
    private func stepContent(agent: Agent, report: AgentSetupReport) -> some View {
        let items = current.items(in: report)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: current.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text(current.title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(theme.primaryText)
            }
            switch current {
            case .model: ModelStep(agent: agent, items: items, mutate: mutate)
            case .folder: FolderStep(agent: agent, items: items, mutate: mutate)
            case .knowledge: KnowledgeStep(agent: agent, items: items, mutate: mutate)
            case .tools: ToolsStep(agent: agent, items: items, mutate: mutate)
            case .permissions: PermissionsStep(agent: agent, items: items, onChanged: { refresh(rebuildSteps: false) })
            case .review:
                ReviewStep(
                    agent: agent, report: report, isDraft: subject.isDraft,
                    onRename: { newName in mutate { $0.name = newName } }
                )
            }
        }
    }
}

// MARK: - Shared step pieces

private struct StepDoneBanner: View {
    @Environment(\.theme) private var theme
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(theme.successColor)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundColor(theme.primaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.successColor.opacity(0.08)))
    }
}

private struct StepIssueList: View {
    @Environment(\.theme) private var theme
    let items: [AgentSetupItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.isBlocking ? "exclamationmark.circle.fill" : "info.circle")
                        .foregroundColor(item.isBlocking ? theme.warningColor : theme.infoColor)
                        .padding(.top, 1)
                    Text(item.detail)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The inline accent button the agent detail view uses for actions like
/// "Choose…" next to the working folder, so wizard steps read as part of the
/// same product rather than a second button vocabulary.
private struct StepActionButton: View {
    @Environment(\.theme) private var theme
    let title: LocalizedStringKey
    let icon: String
    var primary: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title, bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(primary ? theme.accentColor : theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(primary ? theme.accentColor.opacity(0.08) : theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(primary ? theme.accentColor.opacity(0.2) : theme.inputBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

/// Thin rule with a word in the middle, for "one thing or the other" rows.
private struct OrSeparator: View {
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(theme.inputBorder).frame(height: 1)
            Text("or", bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.tertiaryText)
            Rectangle().fill(theme.inputBorder).frame(height: 1)
        }
    }
}

// MARK: - Model

private struct ModelStep: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var pickerCache = ModelPickerItemCache.shared
    let agent: Agent
    let items: [AgentSetupItem]
    let mutate: ((inout Agent) -> Void) -> Void

    @State private var showPicker = false

    /// The model the template asked for, when it is the thing missing.
    private var requested: String? { items.first(where: { $0.kind == .model })?.value }

    /// Hosted models read like hosted models; everything else is a local
    /// bundle to download.
    private var requestedIsLocal: Bool {
        guard let id = requested?.lowercased() else { return true }
        let cloudHints = ["claude", "gpt", "sonnet", "opus", "haiku", "gemini", "grok", "mistral-large", "o1", "o3"]
        return !cloudHints.contains(where: { id.contains($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if items.isEmpty {
                StepDoneBanner(text: L("This agent has a model it can run."))
            } else {
                StepIssueList(items: items)
            }
            VStack(alignment: .leading, spacing: 12) {
                modelField
                if let requested, !items.isEmpty {
                    OrSeparator()
                    if requestedIsLocal {
                        StepActionButton(title: "Download \(requested)", icon: "arrow.down.circle") {
                            AppDelegate.shared?.showManagementWindow(initialTab: .models, deeplinkModelId: requested)
                        }
                    } else {
                        StepActionButton(title: "Configure Provider", icon: "cloud") {
                            AppDelegate.shared?.showManagementWindow(initialTab: .providers)
                        }
                    }
                }
            }
            .frame(width: 380)
        }
        .onAppear {
            // The cache is prewarmed at launch; guard the cold case anyway.
            if !pickerCache.isLoaded { pickerCache.prewarm() }
        }
    }

    /// Same dropdown as the Create Agent sheet's Default Model field.
    private var modelField: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentSheetSectionLabel("Default Model")
            Button {
                showPicker.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "cube.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(agent.defaultModel == nil ? theme.tertiaryText : theme.accentColor)
                    if let model = agent.defaultModel, !model.isEmpty {
                        Text(model.split(separator: "/").last.map(String.init) ?? model)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(items.isEmpty ? theme.primaryText : theme.warningColor)
                            .lineLimit(1)
                    } else {
                        Text("Default (from global settings)", bundle: .module)
                            .font(.system(size: 13))
                            .foregroundColor(theme.placeholderText)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.inputBorder, lineWidth: 1))
                )
            }
            .buttonStyle(PlainButtonStyle())
            .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                ModelPickerView(
                    options: pickerCache.items,
                    selectedModel: Binding(
                        get: { agent.defaultModel },
                        set: { newModel in
                            mutate { $0.defaultModel = newModel }
                            showPicker = false
                        }),
                    agentId: nil,
                    onDismiss: { showPicker = false }
                )
            }
        }
    }
}

// MARK: - Folder

private struct FolderStep: View {
    @Environment(\.theme) private var theme
    let agent: Agent
    let items: [AgentSetupItem]
    let mutate: ((inout Agent) -> Void) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if items.isEmpty {
                StepDoneBanner(text: L("Osaurus can read and write \(agent.workingFolderPath ?? "")."))
            } else {
                StepIssueList(items: items)
                if let hint = agent.workingFolderPath {
                    Text("Hint from the agent's author: \(hint)", bundle: .module)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
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
            .frame(width: 380)
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
    let items: [AgentSetupItem]
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
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    AgentSheetSectionLabel("Grant Collections")
                        .frame(width: 380, alignment: .leading)
                    ForEach(collections) { collection in
                        let granted = agent.settings.knowledgeCollectionIds.contains(collection.id)
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(collection.name).font(.system(size: 12, weight: .medium)).foregroundColor(theme.primaryText)
                                Text(collection.folderPath).font(.system(size: 10)).foregroundColor(theme.tertiaryText).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 12)
                            Toggle("", isOn: Binding(get: { granted }, set: { on in setGrant(collection.id, on) }))
                                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                                .labelsHidden()
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground.opacity(0.6)))
                        .frame(width: 380)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                if !collections.isEmpty { OrSeparator() }
                StepActionButton(title: "Create From Folder…", icon: "folder.badge.plus") { createFromFolder() }
                    .disabled(isCreating)
                OrSeparator()
                StepActionButton(title: "Turn Knowledge Off", icon: "book.closed", primary: false) {
                    mutate { $0.settings.knowledgeEnabled = false }
                }
            }
            .frame(width: 380)
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
    let items: [AgentSetupItem]
    let mutate: ((inout Agent) -> Void) -> Void

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
                            Text(name)
                                .font(.system(size: 10, design: .monospaced))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Capsule().fill(theme.tertiaryBackground))
                                .foregroundColor(theme.secondaryText)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                StepActionButton(title: "Open MCP Servers", icon: "server.rack") {
                    AppDelegate.shared?.showManagementWindow(initialTab: .tools)
                }
                StepActionButton(title: "Open Plugins", icon: "puzzlepiece.extension") {
                    AppDelegate.shared?.showManagementWindow(initialTab: .skills)
                }
                OrSeparator()
                StepActionButton(title: "Remove Missing Tools", icon: "minus.circle", primary: false) {
                    let missing = Set(missingNames)
                    mutate { $0.manualToolNames = ($0.manualToolNames ?? []).filter { !missing.contains($0) } }
                }
                .disabled(items.isEmpty)
            }
            .frame(width: 380)
        }
    }
}

// MARK: - Permissions

private struct PermissionsStep: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var permissionService = SystemPermissionService.shared
    let agent: Agent
    let items: [AgentSetupItem]
    let onChanged: () -> Void

    private var permissions: [SystemPermission] {
        items.compactMap { SystemPermission(rawValue: $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if items.isEmpty {
                StepDoneBanner(text: L("Every permission this agent needs is granted."))
            } else {
                StepIssueList(items: items)
                ForEach(permissions, id: \.self) { permission in
                    HStack(spacing: 10) {
                        Image(systemName: permission.iconName)
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 18)
                        Text(permission.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                        Spacer()
                        StepActionButton(title: "Open System Settings", icon: "gear") {
                            permissionService.openSystemSettings(for: permission)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground.opacity(0.6)))
                }
                Text("Grant the permission, then come back to this window. It re-checks on its own.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            StepActionButton(title: "Check Again", icon: "arrow.clockwise", primary: false) {
                permissionService.refreshAllPermissions()
                onChanged()
            }
        }
    }
}

// MARK: - Review

private struct ReviewStep: View {
    @Environment(\.theme) private var theme
    let agent: Agent
    let report: AgentSetupReport
    let isDraft: Bool
    let onRename: (String) -> Void

    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isDraft {
                VStack(alignment: .leading, spacing: 6) {
                    AgentSheetSectionLabel("Agent Name")
                    StyledTextField(placeholder: L("e.g., Invoice Bot"), text: $name, icon: "textformat")
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
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                AgentSetupChecklistView(report: report)
            } else {
                Text("Nothing blocks this agent. The notes below are worth a look but do not stop it from running.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                AgentSetupChecklistView(report: report)
            }
        }
        .onAppear { if name.isEmpty { name = agent.name } }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentSheetSectionLabel("What Will Be Created")
            VStack(alignment: .leading, spacing: 4) {
                row("cube", agent.defaultModel.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? L("Default Model"))
                if agent.toolSelectionMode == .manual {
                    row("wrench.and.screwdriver", L("\(agent.manualToolNames?.count ?? 0) tools"))
                } else {
                    row("sparkles", L("Auto tools"))
                }
                if agent.autonomousExec?.enabled == true { row("shippingbox", L("Sandbox on")) }
                if agent.settings.spawnDelegationEnabled { row("person.2", L("Can use subagents")) }
                if agent.memoryEnabled { row("brain", L("Memory on")) }
                if let path = agent.workingFolderPath, !path.isEmpty { row("folder", path) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(theme.tertiaryBackground.opacity(0.6)))
        }
    }

    private func row(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(theme.tertiaryText).frame(width: 14)
            Text(text).font(.system(size: 12)).foregroundColor(theme.secondaryText).lineLimit(1).truncationMode(.middle)
        }
    }
}
