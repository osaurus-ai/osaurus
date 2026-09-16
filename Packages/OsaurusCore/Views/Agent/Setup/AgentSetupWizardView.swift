//
//  AgentSetupWizardView.swift
//  osaurus
//
//  Guided setup for an agent whose configuration this Mac cannot honour
//  yet: a model that is not installed, a working folder without access, a
//  knowledge grant with no collection, tools no server here provides, a
//  system permission the OS has not given. Steps are generated from an
//  `AgentSetupReport`, so a clean agent has nothing to walk through and an
//  agent with one gap gets one step plus Review.
//
//  Entry points: Use Template (when the created agent has gaps), the agent
//  card's Run Setup, the first-open checklist alert's "Set up now", and the
//  Agents-tab request `ManagementStateManager.pendingAgentSetupId`.
//
//  The wizard edits a SAVED agent through `AgentManager`; quitting midway
//  keeps the agent and its needs-setup marker (plan test case 34).
//

import AppKit
import SwiftUI

struct AgentSetupWizardView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared

    let agentId: UUID
    let onClose: () -> Void

    enum Step: Hashable {
        case model
        case folder
        case knowledge
        case tools
        case permissions
        case review

        var title: String {
            switch self {
            case .model: return L("Brain")
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

        /// Items of the current report that belong to this step.
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

    @State private var report: AgentSetupReport?
    @State private var steps: [Step] = [.review]
    @State private var current: Step = .review
    @State private var hasAppeared = false

    private var agent: Agent? { agentManager.agent(for: agentId) }

    private var currentIndex: Int { steps.firstIndex(of: current) ?? 0 }
    private var isLast: Bool { currentIndex == steps.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            AgentSheetHeader(
                icon: "checklist",
                title: "Set Up Agent",
                subtitleText: agent?.name,
                onClose: onClose
            )
            HStack(spacing: 0) {
                stepRail
                    .frame(width: 200)
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
            refresh(rebuildSteps: true)
        }
        // Permissions granted in System Settings land here when the user
        // comes back; the step re-checks without a relaunch.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh(rebuildSteps: false)
        }
        .onChange(of: agentManager.agents) { _, _ in refresh(rebuildSteps: false) }
    }

    // MARK: - Rail

    private var stepRail: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                let done = report.map { step != .review && step.items(in: $0).isEmpty } ?? false
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
                            if let report, step != .review {
                                let count = step.items(in: report).count
                                Text(count == 0 ? L("Done") : L("\(count) to fix"))
                                    .font(.system(size: 10))
                                    .foregroundColor(count == 0 ? theme.successColor : theme.tertiaryText)
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
            }
            Spacer()
        }
        .padding(12)
        .background(theme.secondaryBackground.opacity(0.5))
    }

    // MARK: - Footer

    private var footer: some View {
        let cleanForFinish = report?.hasBlockers == false
        return AgentSheetFooter(
            primary: AgentSheetFooter.Action(
                label: isLast ? "Finish" : "Next",
                isEnabled: isLast ? cleanForFinish : true,
                handler: {
                    if isLast { finish() } else { advance() }
                }
            ),
            secondary: AgentSheetFooter.Action(
                label: currentIndex == 0 ? "Later" : "Back",
                handler: {
                    if currentIndex == 0 { onClose() } else { goBack() }
                }
            ),
            hint: isLast && !cleanForFinish ? "Fix the remaining items to finish" : nil
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

    private func finish() {
        refresh(rebuildSteps: false)
        if report?.hasBlockers == false {
            AgentSetupStateStore.shared.clear(agentId)
            if let agent {
                ToastManager.shared.success(L("\(agent.name) is ready"))
            }
            onClose()
        }
    }

    /// Re-run the check. Steps are only rebuilt on first appear so a fixed
    /// step stays in the rail with its check mark instead of vanishing.
    private func refresh(rebuildSteps: Bool) {
        guard let agent else { return }
        let fresh = AgentSetupChecker.check(agent)
        report = fresh
        if rebuildSteps {
            steps = Step.steps(for: fresh)
            current = steps.first ?? .review
        }
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
            case .model: ModelStep(agent: agent, items: items, onChanged: { refresh(rebuildSteps: false) })
            case .folder: FolderStep(agent: agent, items: items, onChanged: { refresh(rebuildSteps: false) })
            case .knowledge: KnowledgeStep(agent: agent, items: items, onChanged: { refresh(rebuildSteps: false) })
            case .tools: ToolsStep(agent: agent, items: items, onChanged: { refresh(rebuildSteps: false) })
            case .permissions: PermissionsStep(agent: agent, items: items, onChanged: { refresh(rebuildSteps: false) })
            case .review: ReviewStep(report: report)
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

private struct StepActionButton: View {
    let title: LocalizedStringKey
    let icon: String
    var primary: Bool = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label { Text(title, bundle: .module) } icon: { Image(systemName: icon) }
                .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(primary ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(SecondaryButtonStyle()))
    }
}

/// Type-erased button style so a step can pick primary/secondary at runtime.
private struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - Model

private struct ModelStep: View {
    @Environment(\.theme) private var theme
    let agent: Agent
    let items: [AgentSetupItem]
    let onChanged: () -> Void

    @State private var pickerItems: [ModelPickerItem] = []
    @State private var showPicker = false
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if items.isEmpty {
                StepDoneBanner(text: L("This agent has a model it can run."))
            } else {
                StepIssueList(items: items)
                Text("Pick a model that is installed, or install the one the agent asks for and come back.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
            }
            HStack(spacing: 10) {
                StepActionButton(title: "Choose a Model…", icon: "cube") { showPicker = true }
                    .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                        ModelPickerView(
                            options: pickerItems,
                            selectedModel: Binding(
                                get: { selected ?? agent.defaultModel },
                                set: { newModel in
                                    selected = newModel
                                    AgentManager.shared.updateDefaultModel(for: agent.id, model: newModel)
                                    showPicker = false
                                    onChanged()
                                }),
                            agentId: agent.id,
                            onDismiss: { showPicker = false }
                        )
                    }
                StepActionButton(title: "Use Default Model", icon: "arrow.uturn.backward", primary: false) {
                    AgentManager.shared.updateDefaultModel(for: agent.id, model: nil)
                    onChanged()
                }
                StepActionButton(title: "Open Local Models", icon: "arrow.down.circle", primary: false) {
                    AppDelegate.shared?.showManagementWindow(initialTab: .models)
                }
                StepActionButton(title: "Open Providers", icon: "cloud", primary: false) {
                    AppDelegate.shared?.showManagementWindow(initialTab: .providers)
                }
            }
        }
        .onReceive(ModelPickerItemCache.shared.$items) { pickerItems = $0 }
    }
}

// MARK: - Folder

private struct FolderStep: View {
    @Environment(\.theme) private var theme
    let agent: Agent
    let items: [AgentSetupItem]
    let onChanged: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if items.isEmpty {
                StepDoneBanner(text: L("Osaurus can read and write \(agent.workingFolderPath ?? "").") )
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
            HStack(spacing: 10) {
                StepActionButton(title: "Choose Folder…", icon: "folder.badge.plus") { chooseFolder() }
                StepActionButton(title: "Remove Working Folder", icon: "folder.badge.minus", primary: false) {
                    AgentManager.shared.clearWorkingFolder(for: agent.id)
                    onChanged()
                }
            }
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
            AgentManager.shared.updateWorkingFolder(for: agent.id, bookmark: bookmark, path: path)
            RecentFoldersStore.shared.record(path: path, bookmark: bookmark)
            onChanged()
        }
    }
}

// MARK: - Knowledge

private struct KnowledgeStep: View {
    @Environment(\.theme) private var theme
    let agent: Agent
    let items: [AgentSetupItem]
    let onChanged: () -> Void

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
                    ForEach(collections) { collection in
                        let granted = agent.settings.knowledgeCollectionIds.contains(collection.id)
                        Toggle(isOn: Binding(get: { granted }, set: { on in setGrant(collection.id, on) })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(collection.name).font(.system(size: 12, weight: .medium)).foregroundColor(theme.primaryText)
                                Text(collection.folderPath).font(.system(size: 10)).foregroundColor(theme.tertiaryText).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                    }
                }
            }
            HStack(spacing: 10) {
                StepActionButton(title: "Create From Folder…", icon: "folder.badge.plus") { createFromFolder() }
                    .disabled(isCreating)
                StepActionButton(title: "Turn Knowledge Off", icon: "book.closed", primary: false) {
                    guard var updated = AgentManager.shared.agent(for: agent.id) else { return }
                    updated.settings.knowledgeEnabled = false
                    AgentManager.shared.update(updated)
                    onChanged()
                }
            }
        }
        .onAppear { collections = KnowledgeCollectionStore.loadAll() }
    }

    private func setGrant(_ id: UUID, _ on: Bool) {
        guard var updated = AgentManager.shared.agent(for: agent.id) else { return }
        var ids = updated.settings.knowledgeCollectionIds
        if on, !ids.contains(id) { ids.append(id) }
        if !on { ids.removeAll { $0 == id } }
        updated.settings.knowledgeCollectionIds = ids
        AgentManager.shared.update(updated)
        onChanged()
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
    let onChanged: () -> Void

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
            HStack(spacing: 10) {
                StepActionButton(title: "Open MCP Servers", icon: "server.rack") {
                    AppDelegate.shared?.showManagementWindow(initialTab: .tools)
                }
                StepActionButton(title: "Open Plugins", icon: "puzzlepiece.extension", primary: false) {
                    AppDelegate.shared?.showManagementWindow(initialTab: .skills)
                }
                StepActionButton(title: "Remove Missing Tools", icon: "minus.circle", primary: false) {
                    guard var updated = AgentManager.shared.agent(for: agent.id) else { return }
                    let missing = Set(missingNames)
                    updated.manualToolNames = (updated.manualToolNames ?? []).filter { !missing.contains($0) }
                    AgentManager.shared.update(updated)
                    onChanged()
                }
                .disabled(items.isEmpty)
            }
        }
    }
}

// MARK: - Permissions

private struct PermissionsStep: View {
    @Environment(\.theme) private var theme
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
    let report: AgentSetupReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if report.isClean {
                StepDoneBanner(text: L("Everything checks out. The agent is ready to use."))
            } else if report.hasBlockers {
                Text("Some items still block this agent. Go back to fix them, or choose Later to keep the agent as is.", bundle: .module)
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
    }
}
