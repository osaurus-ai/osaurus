//
//  ProjectsView.swift
//  osaurus
//
//  Settings → Projects: the only place projects are created, edited and
//  deleted. The chat sidebar lists existing projects below Agents, each
//  with its chats and a New Chat that starts with the project's default
//  agent.
//

import AppKit
import SwiftUI

/// Opens Settings → Projects from outside Settings (a
/// project's gear in the chat sidebar).
@MainActor
enum ProjectsSettingsLink {
    static func open(projectId: UUID? = nil) {
        if let projectId { ManagementStateManager.shared.pendingProjectDetailId = projectId }
        AppDelegate.shared?.showManagementWindow(initialTab: .projects)
    }
}

struct ProjectsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var projectManager = ProjectManager.shared
    @ObservedObject private var sessionsManager = ChatSessionsManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var managementState = ManagementStateManager.shared
    @ObservedObject private var highlightCoordinator = SettingsHighlightCoordinator.shared

    @State private var selectedProjectId: UUID?
    @State private var isCreating = false

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var sortedProjects: [Project] {
        projectManager.projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Group {
            if let id = selectedProjectId, projectManager.project(for: id) != nil {
                ProjectDetailPage(projectId: id) {
                    withAnimation(theme.motion.quick) { selectedProjectId = nil }
                }
                .id(id)
                .transition(.opacity)
            } else {
                listPage
                    .transition(.opacity)
            }
        }
        .environment(\.theme, theme)
        .sheet(isPresented: $isCreating) {
            NewProjectSheet { project in
                withAnimation(theme.motion.quick) { selectedProjectId = project.id }
            }
            .environment(\.theme, theme)
        }
        .onAppear {
            applyPendingDetail()
            routeSettingsLanding(highlightCoordinator.pending)
        }
        .onReceive(managementState.$pendingProjectDetailId) { _ in applyPendingDetail() }
        .onChange(of: highlightCoordinator.pending) { _, pending in routeSettingsLanding(pending) }
    }

    // MARK: - List

    private var listPage: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Projects",
                subtitle: "Group chats around shared instructions, knowledge and a working folder. Projects appear in the chat sidebar below Agents.",
                count: projectManager.projects.count,
                primary: {
                    SettingsButton(.primary, "New Project", icon: "plus") { isCreating = true }
                        .settingsLandingAnchor("projects.new")
                }
            )
        } content: {
            if projectManager.projects.isEmpty {
                SettingsEmptyState(
                    icon: "folder",
                    title: "No Projects Yet",
                    subtitle: "A project gives its chats shared instructions, knowledge, memory and a working folder. Agents cover most of this on their own, so you may not need one.",
                    primaryAction: .init(title: L("New Project"), icon: "plus") { isCreating = true }
                )
            } else {
                SettingsGroup {
                    ForEach(sortedProjects) { project in
                        projectRow(project)
                    }
                }
            }
        }
    }

    private func projectRow(_ project: Project) -> some View {
        LibraryRow(
            title: project.name,
            subtitle: rowSubtitle(for: project),
            showsChevron: true,
            action: { open(project) }
        ) {
            SettingsIconTile(icon: "folder.fill", size: 32)
        } menu: {
            Button(L("Open project")) { open(project) }
        }
    }

    private func rowSubtitle(for project: Project) -> String {
        let count = sessionsManager.sessions.filter { $0.projectId == project.id && !$0.archived }.count
        let chats = count == 1 ? L("1 chat") : L("\(count) chats")
        guard let agentId = project.defaultAgentId, let agent = agentManager.agent(for: agentId) else {
            return chats
        }
        return chats + " · " + agent.displayName
    }

    private func open(_ project: Project) {
        withAnimation(theme.motion.quick) { selectedProjectId = project.id }
    }

    // MARK: - Deep links

    private func applyPendingDetail() {
        guard let id = managementState.pendingProjectDetailId else { return }
        managementState.pendingProjectDetailId = nil
        guard projectManager.project(for: id) != nil else { return }
        selectedProjectId = id
    }

    /// Detail-field results land on the open project, or the first one;
    /// list results pop back to the list. With no projects there is
    /// nothing to land on but the empty state.
    private func routeSettingsLanding(_ pending: String?) {
        guard let pending, pending.hasPrefix("projects.") else { return }
        if ProjectDetailPage.anchorIds.contains(pending) {
            if selectedProjectId == nil { selectedProjectId = sortedProjects.first?.id }
        } else {
            selectedProjectId = nil
        }
    }
}

// MARK: - Detail

private struct ProjectDetailPage: View {
    static let anchorIds: Set<String> = [
        "projects.name", "projects.defaultAgent", "projects.instructions", "projects.knowledge",
        "projects.workingFolder", "projects.sharedMemory", "projects.delete",
    ]

    let projectId: UUID
    let onBack: () -> Void

    @Environment(\.theme) private var theme
    @ObservedObject private var projectManager = ProjectManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var knowledgeManager = KnowledgeManager.shared
    @ObservedObject private var sessionsManager = ChatSessionsManager.shared
    @ObservedObject private var recentFolders = RecentFoldersStore.shared

    @State private var name = ""
    @State private var instructions = ""
    @State private var instructionsSaveTask: Task<Void, Never>?
    @State private var showDeleteConfirm = false

    private var project: Project? { projectManager.project(for: projectId) }

    var body: some View {
        if let project {
            SettingsPage {
                header(project)
            } content: {
                generalSection(project)
                instructionsSection
                knowledgeSection(project)
                folderSection(project)
                memorySection
                SettingsDestructiveZone {
                    SettingsDestructiveRow(
                        title: "Delete Project",
                        description: "Its chats are kept and move out of the project. The project's shared memory is cleared.",
                        actionTitle: "Delete",
                        anchorId: "projects.delete"
                    ) { showDeleteConfirm = true }
                }
            }
            .onAppear {
                name = project.name
                instructions = project.instructions
            }
            .onDisappear(perform: flushInstructions)
            .themedAlert(
                L("Delete Project?"),
                isPresented: $showDeleteConfirm,
                message: L("\"\(project.name)\" will be removed. Its conversations are kept and move out of the project."),
                primaryButton: .destructive(L("Delete")) {
                    instructionsSaveTask?.cancel()
                    instructionsSaveTask = nil
                    ChatSessionsManager.shared.deleteProject(id: projectId)
                    onBack()
                },
                secondaryButton: .cancel(L("Cancel"))
            )
        }
    }

    // MARK: Header

    private func header(_ project: Project) -> some View {
        SettingsPageHeader(
            title: project.name,
            verbatimTitle: true,
            subtitle: chatCountLabel,
            verbatimSubtitle: true,
            leading: { SettingsIconTile(icon: "folder.fill", size: 40) },
            overflow: {
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Label(L("Delete"), systemImage: "trash")
                }
            }
        )
        .settingsBackDestination(L("Projects"), verbatim: true, action: onBack)
    }

    private var chatCountLabel: String {
        let count = sessionsManager.sessions.filter { $0.projectId == projectId && !$0.archived }.count
        return count == 1 ? L("1 chat") : L("\(count) chats")
    }

    // MARK: General

    private func generalSection(_ project: Project) -> some View {
        SettingsSection(title: "General") {
            SettingsFieldRow(label: "Name", anchorId: "projects.name") {
                SettingsTextField(
                    placeholder: L("Project name"),
                    text: $name,
                    onEditingChanged: { editing in if !editing { commitName() } },
                    onSubmit: commitName
                )
            }
            SettingsRow(
                title: "Default Agent",
                description: defaultAgentDescription(project),
                anchorId: "projects.defaultAgent"
            ) {
                SettingsMenuPicker(selection: defaultAgentBinding, options: ProjectAgentOptions.options(agentManager))
            }
        }
    }

    private func defaultAgentDescription(_ project: Project) -> String {
        if ProjectAgentOptions.selectable(project.defaultAgentId, agentManager) == nil {
            return "Not set: New Chat in the project's sidebar group starts with the agent the window is on."
        }
        return "New Chat in the project's sidebar group starts with this agent. Chats from any agent can still be moved in."
    }

    private var defaultAgentBinding: Binding<UUID?> {
        Binding(
            get: { ProjectAgentOptions.selectable(project?.defaultAgentId, agentManager) },
            set: { id in save { $0.defaultAgentId = id } }
        )
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            name = project?.name ?? ""
            return
        }
        save { $0.name = trimmed }
    }

    // MARK: Instructions

    private var instructionsSection: some View {
        SettingsSection(
            title: "Instructions",
            subtitle: "Added after the agent's own system prompt in every chat in this project.",
            anchorId: "projects.instructions"
        ) {
            SettingsTextEditor(
                text: $instructions,
                placeholder: L("Shared context for every chat in this project…"),
                minHeight: 120,
                maxHeight: 300
            )
            .onChange(of: instructions) { scheduleInstructionsSave() }
        }
    }

    private func scheduleInstructionsSave() {
        instructionsSaveTask?.cancel()
        let value = instructions
        instructionsSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            save { $0.instructions = value }
            instructionsSaveTask = nil
        }
    }

    private func flushInstructions() {
        guard instructionsSaveTask != nil else { return }
        instructionsSaveTask?.cancel()
        instructionsSaveTask = nil
        let value = instructions
        save { $0.instructions = value }
    }

    // MARK: Knowledge

    private func knowledgeSection(_ project: Project) -> some View {
        SettingsSection(
            title: "Knowledge",
            subtitle: "Collections every chat in this project can search, combined with the agent's own.",
            anchorId: "projects.knowledge",
            accessory: {
                SettingsButton(.secondary, "New Collection", icon: "plus", size: .compact) {
                    ManagementStateManager.shared.pendingKnowledgeCreate = .init(
                        prefillName: L("\(project.name) Collection"),
                        grantProjectId: project.id
                    )
                    ManagementStateManager.shared.selectedTab = .knowledge
                }
            }
        ) {
            if knowledgeManager.collections.isEmpty {
                SettingsEmptyState(inline: "books.vertical", title: "No knowledge collections yet")
            } else {
                ForEach(knowledgeManager.collections) { collection in
                    SettingsToggle(
                        title: collection.name,
                        description: collection.summary,
                        style: .checkbox,
                        verbatim: true,
                        isOn: knowledgeBinding(collection.id)
                    )
                }
            }
        }
    }

    private func knowledgeBinding(_ collectionId: UUID) -> Binding<Bool> {
        Binding(
            get: { project?.knowledgeCollectionIds.contains(collectionId) ?? false },
            set: { granted in
                save { project in
                    project.knowledgeCollectionIds.removeAll { $0 == collectionId }
                    if granted { project.knowledgeCollectionIds.append(collectionId) }
                }
            }
        )
    }

    // MARK: Working Folder

    private func folderSection(_ project: Project) -> some View {
        let path = project.folderPath?.isEmpty == false ? project.folderPath : nil
        return SettingsSection(
            title: "Working Folder",
            subtitle: "New chats in this project open in this folder. It replaces the agent's own working folder; a folder picked in a chat still wins."
        ) {
            HStack(spacing: theme.space.s12) {
                Text(path ?? L("No folder selected"))
                    .font(SettingsFont.rowTitle)
                    .foregroundColor(path == nil ? theme.text.tertiary : theme.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                SettingsButton(.secondary, path == nil ? "Choose…" : "Change…", icon: "folder", size: .compact) {
                    chooseFolder()
                }
                if path != nil {
                    SettingsIconButton("xmark", help: "Clear working folder", size: .compact) {
                        ProjectManager.shared.clearFolder(for: projectId)
                    }
                }
            }
            .settingsRowChrome()
            .settingsLandingAnchor("projects.workingFolder")

            if !recentFolders.entries.isEmpty {
                RecentFoldersList(activePath: path, showsPath: true, horizontalInset: 0) { entry in
                    applyRecent(entry)
                }
                .environment(\.theme, theme)
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
            panel.message = L("Choose the folder new chats in this project open in.")
            panel.prompt = L("Select")
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            if await ProjectManager.shared.setFolder(url, for: projectId) == nil {
                ToastManager.shared.error(L("Failed to grant folder access"))
            }
        }
    }

    private func applyRecent(_ entry: RecentFoldersStore.Entry) {
        Task { @MainActor in
            guard let url = await RecentFoldersStore.resolveURL(for: entry) else {
                recentFolders.remove(path: entry.path)
                ToastManager.shared.error(L("Folder no longer available"), message: entry.path)
                return
            }
            if await ProjectManager.shared.setFolder(url, for: projectId) == nil {
                ToastManager.shared.error(L("Failed to grant folder access"))
            }
        }
    }

    // MARK: Shared Memory

    private var memorySection: some View {
        SettingsSection {
            SettingsLinkRow(
                title: "Shared Memory",
                description: "What chats in this project have learned, shared across every agent.",
                actionTitle: "Open in Memory",
                anchorId: "projects.sharedMemory"
            ) {
                let state = ManagementStateManager.shared
                state.pendingMemoryProjectPreview = MemoryNamespace.project(projectId).key
                state.selectedTab = .memory
            }
        }
    }

    // MARK: Save

    private func save(_ change: (inout Project) -> Void) {
        guard var updated = projectManager.project(for: projectId) else { return }
        let before = updated
        change(&updated)
        guard updated != before else { return }
        projectManager.update(updated)
    }
}

// MARK: - Default agent options

/// The agents a project can default to: every user agent. The built-ins
/// (Orchestrator, Architect) configure the app and design workflows, so
/// they don't own project work.
@MainActor
enum ProjectAgentOptions {
    static func agents(_ manager: AgentManager) -> [Agent] {
        manager.agents.filter { !$0.isBuiltIn }
    }

    static func options(_ manager: AgentManager) -> [SettingsPickerRow<UUID?>.Option] {
        [.init(nil, L("Not set"), verbatim: true)]
            + agents(manager).map { .init($0.id, $0.displayName, verbatim: true) }
    }

    /// `id` when it names a selectable agent, nil otherwise (unset, deleted,
    /// or a built-in).
    static func selectable(_ id: UUID?, _ manager: AgentManager) -> UUID? {
        guard let id, agents(manager).contains(where: { $0.id == id }) else { return nil }
        return id
    }
}

// MARK: - New Project

private struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var agentManager = AgentManager.shared

    let onCreated: (Project) -> Void

    @State private var name = ""
    @State private var defaultAgentId: UUID?
    @State private var nameError: String?

    var body: some View {
        SettingsSheet(
            icon: "folder.fill",
            title: "New Project",
            subtitle: "Chats in a project share its instructions, knowledge, memory and working folder.",
            primary: .init(label: "Create", handler: create),
            secondary: .init(label: "Cancel") { dismiss() },
            onClose: { dismiss() }
        ) {
            SettingsFieldRow(label: "Name", hint: nameError, verbatimHint: true) {
                SettingsTextField(
                    placeholder: L("Project name"),
                    text: $name,
                    isInvalid: nameError != nil,
                    autofocus: true,
                    onSubmit: create
                )
                .onChange(of: name) { nameError = nil }
            }
            SettingsFieldRow(
                label: "Default Agent",
                hint: "New Chat in the project's sidebar group starts with this agent."
            ) {
                SettingsMenuPicker(selection: $defaultAgentId, options: ProjectAgentOptions.options(agentManager))
            }
        }
        .onAppear {
            defaultAgentId = ProjectAgentOptions.agents(agentManager).first?.id
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            nameError = L("Name is required")
            return
        }
        var project = ProjectManager.shared.create(name: trimmed)
        if let defaultAgentId {
            project.defaultAgentId = defaultAgentId
            ProjectManager.shared.update(project)
            project = ProjectManager.shared.project(for: project.id) ?? project
        }
        dismiss()
        onCreated(project)
    }
}
