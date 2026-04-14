import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared Helpers

func agentColorFor(_ name: String) -> Color {
    let hue = Double(abs(name.hashValue % 360)) / 360.0
    return Color(hue: hue, saturation: 0.6, brightness: 0.8)
}

private func formatModelName(_ model: String) -> String {
    if let last = model.split(separator: "/").last {
        return String(last)
    }
    return model
}

// MARK: - Agents View

struct AgentsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var selectedAgent: Agent?
    @State private var isCreating = false
    @State private var hasAppeared = false
    @State private var successMessage: String?
    @State private var sandboxCleanupNotice: SandboxCleanupNotice?

    @State private var showImportPicker = false
    @State private var importError: String?
    @State private var showExportSuccess = false

    private var customAgents: [Agent] {
        agentManager.agents.filter { !$0.isBuiltIn }
    }

    var body: some View {
        ZStack {
            if selectedAgent == nil {
                gridContent
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }

            if let agent = selectedAgent {
                AgentDetailView(
                    agent: agent,
                    onBack: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            selectedAgent = nil
                        }
                    },
                    onExport: { p in
                        exportAgent(p)
                    },
                    onDelete: { p in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            selectedAgent = nil
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            deleteAgent(p)
                        }
                    },
                    showSuccess: { msg in
                        showSuccess(msg)
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            if let message = successMessage {
                VStack {
                    Spacer()
                    ThemedToastView(message, type: .success)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 20)
                }
                .zIndex(100)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .sheet(isPresented: $isCreating) {
            AgentEditorSheet(
                onSave: { agent in
                    agentManager.add(agent)
                    isCreating = false
                    showSuccess("Created \"\(agent.name)\"")
                },
                onCancel: {
                    isCreating = false
                }
            )
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .themedAlert(
            "Import Error",
            isPresented: Binding(
                get: { importError != nil },
                set: { newValue in
                    if !newValue { importError = nil }
                }
            ),
            message: importError,
            primaryButton: .primary("OK") { importError = nil }
        )
        .themedAlert(
            sandboxCleanupNotice?.title ?? "Sandbox Cleanup",
            isPresented: Binding(
                get: { sandboxCleanupNotice != nil },
                set: { newValue in
                    if !newValue { sandboxCleanupNotice = nil }
                }
            ),
            message: sandboxCleanupNotice?.message,
            primaryButton: .primary("OK") { sandboxCleanupNotice = nil }
        )
        .onAppear {
            agentManager.refresh()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
    }

    // MARK: - Grid Content

    private var gridContent: some View {
        VStack(spacing: 0) {
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            if customAgents.isEmpty {
                SettingsEmptyState(
                    icon: "theatermasks.fill",
                    title: L("Create Your First Agent"),
                    subtitle: L("Custom AI assistants with unique prompts, tools, and styles."),
                    examples: [
                        .init(icon: "calendar", title: "Daily Planner", description: "Manage your schedule"),
                        .init(icon: "message.fill", title: "Message Assistant", description: "Draft and send texts"),
                        .init(icon: "map.fill", title: "Local Guide", description: "Find places nearby"),
                    ],
                    primaryAction: .init(title: "Create Agent", icon: "plus", handler: { isCreating = true }),
                    secondaryAction: .init(
                        title: L("Import"),
                        icon: "square.and.arrow.down",
                        handler: { showImportPicker = true }
                    ),
                    hasAppeared: hasAppeared
                )
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(minimum: 300), spacing: 20),
                            GridItem(.flexible(minimum: 300), spacing: 20),
                        ],
                        spacing: 20
                    ) {
                        ForEach(Array(customAgents.enumerated()), id: \.element.id) { index, agent in
                            AgentCard(
                                agent: agent,
                                isActive: agentManager.activeAgentId == agent.id,
                                animationDelay: Double(index) * 0.05,
                                hasAppeared: hasAppeared,
                                onSelect: {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        selectedAgent = agent
                                    }
                                },
                                onDuplicate: {
                                    duplicateAgent(agent)
                                },
                                onExport: {
                                    exportAgent(agent)
                                },
                                onDelete: {
                                    deleteAgent(agent)
                                }
                            )
                        }
                    }
                    .padding(24)
                }
                .opacity(hasAppeared ? 1 : 0)
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("Agents"),
            subtitle: L("Create custom assistant personalities with unique behaviors"),
            count: customAgents.isEmpty ? nil : customAgents.count
        ) {
            HeaderIconButton("arrow.clockwise", help: "Refresh agents") {
                agentManager.refresh()
            }
            HeaderSecondaryButton("Import", icon: "square.and.arrow.down") {
                showImportPicker = true
            }
            HeaderPrimaryButton("Create Agent", icon: "plus") {
                isCreating = true
            }
        }
    }

    // MARK: - Success Toast

    private func showSuccess(_ message: String) {
        withAnimation(theme.springAnimation()) {
            successMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(theme.animationQuick()) {
                successMessage = nil
            }
        }
    }

    // MARK: - Actions

    private func deleteAgent(_ agent: Agent) {
        Task { @MainActor in
            let result = await agentManager.delete(id: agent.id)
            guard result.deleted else {
                ToastManager.shared.error("Failed to delete agent", message: "Please try again.")
                return
            }
            showSuccess("Deleted \"\(agent.name)\"")
            sandboxCleanupNotice = result.sandboxCleanupNotice
        }
    }

    private func duplicateAgent(_ agent: Agent) {
        let baseName = "\(agent.name) Copy"
        let existingNames = Set(customAgents.map { $0.name })
        var newName = baseName
        var counter = 1

        while existingNames.contains(newName) {
            counter += 1
            newName = "\(agent.name) Copy \(counter)"
        }

        let duplicated = Agent(
            id: UUID(),
            name: newName,
            description: agent.description,
            systemPrompt: agent.systemPrompt,
            themeId: agent.themeId,
            defaultModel: agent.defaultModel,
            temperature: agent.temperature,
            maxTokens: agent.maxTokens,
            chatQuickActions: agent.chatQuickActions,
            workQuickActions: agent.workQuickActions,
            isBuiltIn: false,
            createdAt: Date(),
            updatedAt: Date()
        )

        AgentStore.save(duplicated)
        agentManager.refresh()
        showSuccess("Duplicated as \"\(newName)\"")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                selectedAgent = duplicated
            }
        }
    }

    // MARK: - Import/Export

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                importError = "Unable to access the selected file"
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: url)
                try agentManager.importAgent(from: data)
                showSuccess("Imported agent successfully")
            } catch {
                importError = "Failed to import agent: \(error.localizedDescription)"
            }

        case .failure(let error):
            importError = "Failed to select file: \(error.localizedDescription)"
        }
    }

    private func exportAgent(_ agent: Agent) {
        do {
            let data = try agentManager.exportAgent(agent)

            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(agent.name).json"
            panel.title = "Export Agent"
            panel.message = "Choose where to save the agent file"

            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url)
                showSuccess("Exported \"\(agent.name)\"")
            }
        } catch {
            print("[Osaurus] Failed to export agent: \(error)")
        }
    }
}

// MARK: - Agent Card

private struct AgentCard: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared
    private var scheduleManager = ScheduleManager.shared

    let agent: Agent
    let isActive: Bool
    let animationDelay: Double
    let hasAppeared: Bool
    let onSelect: () -> Void
    let onDuplicate: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    init(
        agent: Agent,
        isActive: Bool,
        animationDelay: Double,
        hasAppeared: Bool,
        onSelect: @escaping () -> Void,
        onDuplicate: @escaping () -> Void,
        onExport: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.agent = agent
        self.isActive = isActive
        self.animationDelay = animationDelay
        self.hasAppeared = hasAppeared
        self.onSelect = onSelect
        self.onDuplicate = onDuplicate
        self.onExport = onExport
        self.onDelete = onDelete
    }

    @State private var isHovered = false
    @State private var showDeleteConfirm = false

    private var agentColor: Color { agentColorFor(agent.name) }

    private var scheduleCount: Int {
        scheduleManager.schedules.filter { $0.agentId == agent.id }.count
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [agentColor.opacity(0.15), agentColor.opacity(0.05)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )

                        Circle()
                            .strokeBorder(agentColor.opacity(0.4), lineWidth: 2)

                        Text(agent.name.prefix(1).uppercased())
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(agentColor)
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(agent.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(1)

                            if isActive {
                                Text("Active", bundle: .module)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(theme.successColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(theme.successColor.opacity(0.12))
                                    )
                            }
                        }

                        if !agent.description.isEmpty {
                            Text(agent.description)
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    Menu {
                        Button(action: onSelect) {
                            Label {
                                Text("Open", bundle: .module)
                            } icon: {
                                Image(systemName: "arrow.right.circle")
                            }
                        }
                        Button(action: onDuplicate) {
                            Label {
                                Text("Duplicate", bundle: .module)
                            } icon: {
                                Image(systemName: "doc.on.doc")
                            }
                        }
                        Button(action: onExport) {
                            Label {
                                Text("Export", bundle: .module)
                            } icon: {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label {
                                Text("Delete", bundle: .module)
                            } icon: {
                                Image(systemName: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 24, height: 24)
                            .background(
                                Circle()
                                    .fill(theme.tertiaryBackground)
                            )
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 24)
                }

                if !agent.systemPrompt.isEmpty {
                    Text(agent.systemPrompt)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                compactStats
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(16)
            .background(cardBackground)
            .overlay(hoverGradient)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(cardBorder)
            .shadow(
                color: Color.black.opacity(isHovered ? 0.08 : 0.04),
                radius: isHovered ? 10 : 5,
                x: 0,
                y: isHovered ? 3 : 2
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 20)
        .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(animationDelay), value: hasAppeared)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .themedAlert(
            "Delete Agent",
            isPresented: $showDeleteConfirm,
            message:
                "Are you sure you want to delete \"\(agent.name)\"? This action cannot be undone. Any sandbox resources provisioned for this agent will also be removed.",
            primaryButton: .destructive("Delete", action: onDelete),
            secondaryButton: .cancel("Cancel")
        )
    }

    // MARK: - Card Background

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(theme.cardBackground)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                isHovered
                    ? agentColor.opacity(0.25)
                    : (isActive ? agentColor.opacity(0.3) : theme.cardBorder),
                lineWidth: isActive || isHovered ? 1.5 : 1
            )
    }

    private var hoverGradient: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(
                LinearGradient(
                    colors: [
                        agentColor.opacity(isHovered ? 0.06 : 0),
                        Color.clear,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }

    // MARK: - Compact Stats

    @ViewBuilder
    private var compactStats: some View {
        HStack(spacing: 0) {
            if scheduleCount > 0 {
                statItem(icon: "clock", text: "\(scheduleCount)")
            }

            if let model = agent.defaultModel {
                if scheduleCount > 0 { statDot }
                statItem(icon: "cube", text: formatModelName(model))
            }

            Spacer(minLength: 0)
        }
    }

    private func statItem(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(theme.tertiaryText)
    }

    private var statDot: some View {
        Circle()
            .fill(theme.tertiaryText.opacity(0.4))
            .frame(width: 3, height: 3)
            .padding(.horizontal, 8)
    }
}

// MARK: - Detail Tab

private enum DetailTab: String, CaseIterable {
    case configure
    case sandbox
    case automation
    case memory

    var label: String {
        switch self {
        case .configure: return "Configure"
        case .sandbox: return "Sandbox"
        case .automation: return "Automation"
        case .memory: return "Memory"
        }
    }

    var icon: String {
        switch self {
        case .configure: return "gear"
        case .sandbox: return "shippingbox"
        case .automation: return "clock.badge.checkmark"
        case .memory: return "brain.head.profile"
        }
    }

    var helperText: String {
        switch self {
        case .configure: return "Set up instructions, model settings, shortcuts, and appearance."
        case .sandbox: return "Configure sandbox execution and relay tunnel access."
        case .automation: return "Set up schedules and file watchers for autonomous behavior."
        case .memory: return "View conversation history, working memory, and summaries."
        }
    }
}

private enum AgentTab: Hashable {
    case builtIn(DetailTab)
    case plugin(String)
}

// MARK: - Agent Detail View

struct AgentDetailView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    private var scheduleManager = ScheduleManager.shared
    private var watcherManager = WatcherManager.shared
    @ObservedObject private var relayManager = RelayTunnelManager.shared
    @EnvironmentObject private var server: ServerController

    private var theme: ThemeProtocol { themeManager.currentTheme }

    let agent: Agent
    let onBack: () -> Void
    let onExport: (Agent) -> Void
    let onDelete: (Agent) -> Void
    let showSuccess: (String) -> Void

    init(
        agent: Agent,
        onBack: @escaping () -> Void,
        onExport: @escaping (Agent) -> Void,
        onDelete: @escaping (Agent) -> Void,
        showSuccess: @escaping (String) -> Void
    ) {
        self.agent = agent
        self.onBack = onBack
        self.onExport = onExport
        self.onDelete = onDelete
        self.showSuccess = showSuccess
    }

    // MARK: - Editable State

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var systemPrompt: String = ""
    @State private var temperature: String = ""
    @State private var maxTokens: String = ""
    @State private var selectedThemeId: UUID?
    @State private var chatQuickActions: [AgentQuickAction]?
    @State private var workQuickActions: [AgentQuickAction]?
    @State private var editingQuickActionId: UUID?
    @State private var pluginInstructionsMap: [String: String] = [:]
    @State private var disableTools: Bool = false
    @State private var disableMemory: Bool = false
    @State private var toolSelectionMode: ToolSelectionMode = .auto
    @State private var manualToolNames: Set<String> = []
    @State private var manualSkillNames: Set<String> = []
    @State private var toolSearchText: String = ""
    @State private var cachedTools: [ToolRegistry.ToolEntry] = []
    @State private var cachedSkills: [Skill] = []
    @State private var displayedTools: [ToolRegistry.ToolEntry] = []
    @State private var displayedSkills: [Skill] = []

    // MARK: - UI State

    @State private var selectedTab: AgentTab = .builtIn(.configure)
    @State private var hasAppeared = false
    @State private var saveIndicator: String?
    @State private var saveDebounceTask: Task<Void, Never>?
    @State private var showDeleteConfirm = false
    @State private var showRelayConfirmation = false
    @State private var copiedRelayURL = false
    @State private var copiedRouteURL: String?
    @State private var pickerItems: [ModelPickerItem] = []
    @State private var showModelPicker = false
    @State private var selectedModel: String?
    @State private var showCreateSchedule = false
    @State private var showCreateWatcher = false
    @State private var memoryEntries: [MemoryEntry] = []
    @State private var conversationSummaries: [ConversationSummary] = []
    @State private var showAllSummaries = false
    @State private var isInitialLoadComplete = false

    private var currentAgent: Agent {
        agentManager.agent(for: agent.id) ?? agent
    }

    private var linkedSchedules: [Schedule] {
        scheduleManager.schedules.filter { $0.agentId == agent.id }
    }

    private var linkedWatchers: [Watcher] {
        watcherManager.watchers.filter { $0.agentId == agent.id }
    }

    private var chatSessions: [ChatSessionData] {
        ChatSessionsManager.shared.sessions(for: agent.id)
    }

    private var workTasks: [WorkTask] {
        (try? IssueStore.listTasks(agentId: agent.id)) ?? []
    }

    private var agentColor: Color { agentColorFor(name) }

    private var agentPlugins: [PluginManager.LoadedPlugin] {
        PluginManager.shared.plugins.filter { loaded in
            let hasConfig = loaded.plugin.manifest.capabilities.config != nil
            let hasInstructions =
                loaded.plugin.manifest.instructions != nil
                || currentAgent.pluginInstructions?[loaded.plugin.id] != nil
            let hasRoutes = !loaded.routes.isEmpty
            return hasConfig || hasInstructions || hasRoutes
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            detailHeaderBar

            VStack(alignment: .leading, spacing: 0) {
                heroHeader
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                tabBar
                    .padding(.horizontal, 20)

                Divider()
                    .foregroundColor(theme.primaryBorder)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch selectedTab {
                        case .builtIn(.configure):
                            configureTabContent
                        case .builtIn(.sandbox):
                            sandboxTabContent
                        case .builtIn(.automation):
                            automationTabContent
                        case .builtIn(.memory):
                            memoryTabContent
                        case .plugin(let pid):
                            pluginTabContent(for: pid)
                        }
                    }
                    .padding(24)
                    .id(selectedTab)
                }
                .animation(nil, value: selectedTab)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .opacity(hasAppeared ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: hasAppeared)
        .onAppear {
            loadAgentData()
            loadMemoryData()
            selectedModel = currentAgent.defaultModel
            DispatchQueue.main.async {
                isInitialLoadComplete = true
            }
            withAnimation { hasAppeared = true }
        }
        .onReceive(ModelPickerItemCache.shared.$items) { options in
            pickerItems = options
        }
        .themedAlert(
            "Delete Agent",
            isPresented: $showDeleteConfirm,
            message:
                "Are you sure you want to delete \"\(currentAgent.name)\"? This action cannot be undone. Any sandbox resources provisioned for this agent will also be removed.",
            primaryButton: .destructive("Delete") { onDelete(currentAgent) },
            secondaryButton: .cancel("Cancel")
        )
        .themedAlert(
            "Expose Agent to Internet?",
            isPresented: $showRelayConfirmation,
            message:
                "This will create a public URL for this agent via agent.osaurus.ai. Anyone with the URL can send requests to your local server. Your access keys still protect the API endpoints.",
            primaryButton: .destructive("Enable Relay") {
                relayManager.setTunnelEnabled(true, for: agent.id)
            },
            secondaryButton: .cancel("Cancel")
        )
        .sheet(isPresented: $showCreateSchedule) {
            ScheduleEditorSheet(
                mode: .create,
                onSave: { schedule in
                    ScheduleManager.shared.create(
                        name: schedule.name,
                        instructions: schedule.instructions,
                        agentId: schedule.agentId,
                        frequency: schedule.frequency,
                        isEnabled: schedule.isEnabled
                    )
                    showCreateSchedule = false
                    showSuccess("Created schedule \"\(schedule.name)\"")
                },
                onCancel: { showCreateSchedule = false },
                initialAgentId: agent.id
            )
            .environment(\.theme, themeManager.currentTheme)
        }
        .sheet(isPresented: $showCreateWatcher) {
            WatcherEditorSheet(
                mode: .create,
                onSave: { watcher in
                    watcherManager.create(
                        name: watcher.name,
                        instructions: watcher.instructions,
                        agentId: watcher.agentId,
                        watchPath: watcher.watchPath,
                        watchBookmark: watcher.watchBookmark,
                        isEnabled: watcher.isEnabled,
                        recursive: watcher.recursive,
                        responsiveness: watcher.responsiveness
                    )
                    showCreateWatcher = false
                    showSuccess("Created watcher \"\(watcher.name)\"")
                },
                onCancel: { showCreateWatcher = false },
                initialAgentId: agent.id
            )
            .environment(\.theme, themeManager.currentTheme)
        }
    }

    // MARK: - Detail Header Bar

    private var detailHeaderBar: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Agents", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(theme.accentColor)
            }
            .buttonStyle(PlainButtonStyle())

            Spacer()

            if let indicator = saveIndicator {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                    Text(indicator)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(theme.successColor)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            HStack(spacing: 6) {
                Button {
                    onExport(currentAgent)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(theme.tertiaryBackground))
                }
                .buttonStyle(PlainButtonStyle())
                .help(Text("Export", bundle: .module))

                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.errorColor)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(theme.errorColor.opacity(0.1)))
                }
                .buttonStyle(PlainButtonStyle())
                .help(Text("Delete", bundle: .module))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(
            theme.secondaryBackground
                .overlay(
                    Rectangle()
                        .fill(theme.primaryBorder)
                        .frame(height: 1),
                    alignment: .bottom
                )
        )
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [agentColor.opacity(0.2), agentColor.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Circle()
                    .strokeBorder(agentColor.opacity(0.5), lineWidth: 2.5)
                Text(name.isEmpty ? "?" : name.prefix(1).uppercased())
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(agentColor)
            }
            .frame(width: 72, height: 72)
            .animation(.spring(response: 0.3), value: name)

            VStack(alignment: .leading, spacing: 8) {
                StyledTextField(
                    placeholder: "e.g., Code Assistant",
                    text: $name,
                    icon: "textformat"
                )

                StyledTextField(
                    placeholder: "Brief description (optional)",
                    text: $description,
                    icon: "text.alignleft"
                )

                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                    Text("Created \(agent.createdAt.formatted(date: .abbreviated, time: .omitted))", bundle: .module)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                }
            }

            Spacer()
        }
        .onChange(of: name) { debouncedSave() }
        .onChange(of: description) { debouncedSave() }
    }

    // MARK: - Tab Bar

    private func tabBadgeCount(for tab: AgentTab) -> Int? {
        switch tab {
        case .builtIn(let dt):
            switch dt {
            case .configure: return nil
            case .sandbox: return nil
            case .automation:
                let count = linkedSchedules.count + linkedWatchers.count
                return count > 0 ? count : nil
            case .memory:
                let count = chatSessions.count + workTasks.count
                return count > 0 ? count : nil
            }
        case .plugin:
            return nil
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(DetailTab.allCases, id: \.self) { tab in
                tabButton(for: .builtIn(tab), label: tab.label, icon: tab.icon)
            }
            ForEach(agentPlugins, id: \.plugin.id) { loaded in
                tabButton(
                    for: .plugin(loaded.plugin.id),
                    label: loaded.plugin.manifest.name ?? loaded.plugin.id,
                    icon: "puzzlepiece.extension"
                )
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private func tabButton(for tab: AgentTab, label: String, icon: String) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))

                    Text(label)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))

                    if let count = tabBadgeCount(for: tab) {
                        Text("\(count)", bundle: .module)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(isSelected ? theme.accentColor : theme.tertiaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(isSelected ? theme.accentColor.opacity(0.12) : theme.inputBackground)
                            )
                    }
                }
                .foregroundColor(isSelected ? theme.accentColor : theme.tertiaryText)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

                Rectangle()
                    .fill(isSelected ? theme.accentColor : Color.clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func tabHelperText(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
        }
        .padding(.bottom, 4)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var configureTabContent: some View {
        tabHelperText(DetailTab.configure.helperText)
        systemPromptSection
        generationSection
        disableTogglesSection
        if !disableTools {
            toolSelectionSection
        }
        quickActionsSection
        themeSection
    }

    @ViewBuilder
    private var sandboxTabContent: some View {
        tabHelperText(DetailTab.sandbox.helperText)
        sandboxSection
        bonjourSection
        relaySection
    }

    @ViewBuilder
    private var automationTabContent: some View {
        tabHelperText(DetailTab.automation.helperText)
        schedulesSection
        watchersSection
    }

    @ViewBuilder
    private var memoryTabContent: some View {
        tabHelperText(DetailTab.memory.helperText)
        historySection
        workingMemorySection
        conversationSummariesSection
    }

    // MARK: - Configure Tab Sections

    private var systemPromptSection: some View {
        AgentDetailSection(title: "System Prompt", icon: "brain") {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if systemPrompt.isEmpty {
                        Text("Enter instructions for this agent...", bundle: .module)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(theme.placeholderText)
                            .padding(.top, 12)
                            .padding(.leading, 16)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $systemPrompt)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 160, maxHeight: 300)
                        .padding(12)
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )

                Text(
                    "Instructions that define this agent's behavior. Leave empty to use global settings.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            }
            .onChange(of: systemPrompt) { debouncedSave() }
        }
    }

    private var generationSection: some View {
        AgentDetailSection(title: "Generation", icon: "cpu") {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text("Default Model", bundle: .module)
                    } icon: {
                        Image(systemName: "cube.fill")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                    Button {
                        showModelPicker.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            if let model = selectedModel {
                                Text(formatModelName(model))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(theme.primaryText)
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
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(theme.inputBorder, lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .popover(isPresented: $showModelPicker, arrowEdge: .bottom) {
                        ModelPickerView(
                            options: pickerItems,
                            selectedModel: Binding(
                                get: { selectedModel },
                                set: { newModel in
                                    selectedModel = newModel
                                    agentManager.updateDefaultModel(for: agent.id, model: newModel)
                                    showSaveIndicator()
                                }
                            ),
                            agentId: agent.id,
                            onDismiss: { showModelPicker = false }
                        )
                    }

                    if selectedModel != nil {
                        Button {
                            selectedModel = nil
                            agentManager.updateDefaultModel(for: agent.id, model: nil)
                            showSaveIndicator()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 10))
                                Text("Reset to default", bundle: .module)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(theme.accentColor)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label {
                            Text("Temperature", bundle: .module)
                        } icon: {
                            Image(systemName: "thermometer.medium")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                        StyledTextField(placeholder: "0.7", text: $temperature, icon: nil)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Label {
                            Text("Max Tokens", bundle: .module)
                        } icon: {
                            Image(systemName: "number")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                        StyledTextField(placeholder: "4096", text: $maxTokens, icon: nil)
                    }
                }

                Text("Leave empty to use default values from global settings.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            .onChange(of: temperature) { debouncedSave() }
            .onChange(of: maxTokens) { debouncedSave() }
        }
    }

    // MARK: - Tool Selection

    private func reloadToolsAndSkills() {
        let hidden = ToolRegistry.shared.builtInToolNames
            .union(ToolRegistry.shared.runtimeManagedToolNames)
        cachedTools = ToolRegistry.shared.listTools().filter { $0.enabled && !hidden.contains($0.name) }
        cachedSkills = SkillManager.shared.skills.filter { $0.enabled || !$0.isBuiltIn }
        applyToolSearchFilter()
    }

    private func applyToolSearchFilter() {
        guard !toolSearchText.isEmpty else {
            displayedTools = cachedTools
            displayedSkills = cachedSkills
            return
        }
        let query = toolSearchText.lowercased()
        displayedTools =
            cachedTools
            .compactMap { entry -> (ToolRegistry.ToolEntry, Int)? in
                let score = fuzzyScore(query: query, name: entry.name, description: entry.description)
                return score > 0 ? (entry, score) : nil
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        displayedSkills = cachedSkills.filter {
            fuzzyScore(query: query, name: $0.name, description: $0.description) > 0
        }
    }

    private func fuzzyScore(query: String, name: String, description: String) -> Int {
        let n = name.lowercased()
        let d = description.lowercased()
        if n == query { return 100 }
        if n.hasPrefix(query) { return 80 }
        if n.contains(query) { return 60 }
        if d.contains(query) { return 40 }
        if SearchService.fuzzyMatch(query: query, in: n) { return 20 }
        return 0
    }

    private var disableTogglesSection: some View {
        AgentDetailSection(title: "Features", icon: "switch.2") {
            VStack(alignment: .leading, spacing: 10) {
                featureToggleRow(
                    title: "Disable Tools",
                    subtitle: "No tools or pre-flight context will be sent to the model.",
                    isOn: $disableTools
                )
                featureToggleRow(
                    title: "Disable Memory",
                    subtitle: "Memory will not be injected into prompts or recorded.",
                    isOn: $disableMemory
                )
            }
        }
    }

    private func featureToggleRow(title: LocalizedStringKey, subtitle: LocalizedStringKey, isOn: Binding<Bool>)
        -> some View
    {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title, bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text(subtitle, bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                .labelsHidden()
                .onChange(of: isOn.wrappedValue) { debouncedSave() }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
    }

    private var toolSelectionSection: some View {
        AgentDetailSection(title: "Tools", icon: "wrench.and.screwdriver") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $toolSelectionMode) {
                    Text("Auto", bundle: .module).tag(ToolSelectionMode.auto)
                    Text("Manual", bundle: .module).tag(ToolSelectionMode.manual)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(
                    toolSelectionMode == .auto
                        ? "Tools are discovered automatically using pre-flight search."
                        : "Core tools are always available. Select additional tools and skills below."
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)

                if toolSelectionMode == .manual {
                    manualSearchField
                    manualToolList
                    manualSkillList
                    manualSelectionSummary
                }
            }
            .onChange(of: toolSelectionMode) {
                if toolSelectionMode == .manual { reloadToolsAndSkills() }
                debouncedSave()
            }
            .task(id: toolSearchText) {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                applyToolSearchFilter()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toolsListChanged)) { _ in
                reloadToolsAndSkills()
            }
            .onAppear {
                if toolSelectionMode == .manual { reloadToolsAndSkills() }
            }
        }
    }

    private var manualSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            TextField(text: $toolSearchText, prompt: Text("Search tools and skills...", bundle: .module)) {
                Text("Search tools and skills...", bundle: .module)
            }
            .font(.system(size: 12))
            .textFieldStyle(.plain)
            .foregroundColor(theme.primaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1))
        )
    }

    @ViewBuilder
    private var manualToolList: some View {
        if !displayedTools.isEmpty {
            selectableSection("Tools", maxHeight: 300) {
                ForEach(displayedTools, id: \.name) { entry in
                    selectableRow(
                        title: entry.name,
                        subtitle: entry.description,
                        isSelected: manualToolNames.contains(entry.name),
                        titleFont: .system(size: 12, weight: .medium, design: .monospaced)
                    ) {
                        manualToolNames.formSymmetricDifference([entry.name])
                        debouncedSave()
                    }
                    if entry.name != displayedTools.last?.name {
                        Divider().foregroundColor(theme.primaryBorder)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var manualSkillList: some View {
        if !displayedSkills.isEmpty {
            selectableSection("Skills", maxHeight: 200) {
                ForEach(displayedSkills, id: \.id) { skill in
                    selectableRow(
                        title: skill.name,
                        subtitle: skill.description,
                        isSelected: manualSkillNames.contains(skill.name),
                        badge: skill.category
                    ) {
                        manualSkillNames.formSymmetricDifference([skill.name])
                        debouncedSave()
                    }
                    if skill.id != displayedSkills.last?.id {
                        Divider().foregroundColor(theme.primaryBorder)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var manualSelectionSummary: some View {
        let parts = [
            pluralized("tool", count: manualToolNames.count),
            pluralized("skill", count: manualSkillNames.count),
        ].compactMap { $0 }

        if !parts.isEmpty {
            Text(parts.joined(separator: ", ") + " selected")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
    }

    private func pluralized(_ word: String, count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(word)\(count == 1 ? "" : "s")"
    }

    private func selectableSection<Content: View>(
        _ title: String,
        maxHeight: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.secondaryText)
                .textCase(.uppercase)

            ScrollView {
                VStack(spacing: 0) { content() }
            }
            .frame(maxHeight: maxHeight)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.inputBackground)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.inputBorder, lineWidth: 1))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func selectableRow(
        title: String,
        subtitle: String,
        isSelected: Bool,
        titleFont: Font = .system(size: 12, weight: .medium),
        badge: String? = nil,
        onToggle: @escaping () -> Void
    ) -> some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? theme.accentColor : theme.tertiaryText)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(titleFont)
                            .foregroundColor(theme.primaryText)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(theme.tertiaryText)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(theme.inputBackground)
                                        .overlay(Capsule().stroke(theme.inputBorder, lineWidth: 0.5))
                                )
                        }
                    }
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Plugin Tab Content

    @ViewBuilder
    private func pluginTabContent(for pid: String) -> some View {
        if let loaded = PluginManager.shared.loadedPlugin(for: pid) {
            let pluginName = loaded.plugin.manifest.name ?? pid
            tabHelperText(String(format: L("Configure %@ settings for this agent."), pluginName))

            if loaded.plugin.manifest.instructions != nil || pluginInstructionsMap[pid] != nil {
                pluginInstructionsCard(for: loaded)
            }

            if let configSpec = loaded.plugin.manifest.capabilities.config {
                AgentDetailSection(title: "Configuration", icon: "slider.horizontal.3") {
                    PluginConfigView(
                        pluginId: pid,
                        agentId: agent.id,
                        configSpec: configSpec,
                        plugin: loaded.plugin
                    )
                }
            }

            if !loaded.routes.isEmpty {
                pluginRoutesCard(for: loaded)
            }
        }
    }

    @ViewBuilder
    private func pluginInstructionsCard(for loaded: PluginManager.LoadedPlugin) -> some View {
        let pid = loaded.plugin.id
        let manifestDefault = loaded.plugin.manifest.instructions ?? ""

        AgentDetailSection(title: "Instructions", icon: "text.bubble") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Customize how the AI uses this plugin.", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)

                    Spacer()

                    if let current = pluginInstructionsMap[pid],
                        !manifestDefault.isEmpty,
                        current.trimmingCharacters(in: .whitespacesAndNewlines)
                            != manifestDefault.trimmingCharacters(in: .whitespacesAndNewlines)
                    {
                        Button {
                            pluginInstructionsMap[pid] = manifestDefault
                            debouncedSave()
                        } label: {
                            Text("Reset to Default", bundle: .module)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(theme.accentColor)
                    }
                }

                ZStack(alignment: .topLeading) {
                    if (pluginInstructionsMap[pid] ?? "").isEmpty {
                        Text("Custom instructions for this plugin...", bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.placeholderText)
                            .padding(.top, 10)
                            .padding(.leading, 14)
                            .allowsHitTesting(false)
                    }

                    TextEditor(
                        text: Binding(
                            get: { pluginInstructionsMap[pid] ?? manifestDefault },
                            set: { pluginInstructionsMap[pid] = $0 }
                        )
                    )
                    .font(.system(size: 12))
                    .foregroundColor(theme.primaryText)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 80, maxHeight: 160)
                    .padding(10)
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )
            }
            .onChange(of: pluginInstructionsMap) { debouncedSave() }
        }
    }

    @ViewBuilder
    private func pluginRoutesCard(for loaded: PluginManager.LoadedPlugin) -> some View {
        let pid = loaded.plugin.id
        let tunnelStatus = relayManager.agentStatuses[agent.id]
        let tunnelBaseURL: String? = {
            if case .connected(let baseURL) = tunnelStatus {
                return "\(baseURL)/plugins/\(pid)"
            }
            return nil
        }()

        AgentDetailSection(title: "Route Endpoints", icon: "arrow.left.arrow.right") {
            VStack(alignment: .leading, spacing: 16) {
                if let baseURL = tunnelBaseURL {
                    routeBaseURLRow(
                        label: "Public URL",
                        url: baseURL,
                        dotColor: theme.successColor
                    )
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                        Text("Enable relay in the Sandbox tab to get a public URL.", bundle: .module)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(loaded.routes.enumerated()), id: \.element.id) { idx, route in
                        if idx > 0 {
                            Divider().opacity(0.3)
                        }
                        routeRow(route: route, pluginId: pid, baseURL: tunnelBaseURL)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.tertiaryBackground.opacity(0.3))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )
            }
        }
    }

    private func routeBaseURLRow(label: String, url: String, dotColor: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)

            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 60, alignment: .leading)

            Text(url)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.accentColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 4)

            routeCopyButton(url: url)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(dotColor.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(dotColor.opacity(0.15), lineWidth: 1)
                )
        )
    }

    private func routeRow(route: PluginManifest.RouteSpec, pluginId: String, baseURL: String?) -> some View {
        let fullPath = "/plugins/\(pluginId)\(route.path)"
        let fullURL = baseURL.map { "\($0)\(route.path)" }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(route.methods.joined(separator: ", "))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(routeMethodColor(route.methods.first ?? "GET"))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(routeMethodColor(route.methods.first ?? "GET").opacity(0.12))
                    )

                Text(fullPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Spacer()

                Text(route.auth.rawValue)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(routeAuthColor(route.auth))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(routeAuthColor(route.auth).opacity(0.12))
                    )

                if let url = fullURL {
                    routeCopyButton(url: url)
                }
            }

            if let desc = route.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func routeCopyButton(url: String) -> some View {
        let isCopied = copiedRouteURL == url
        return Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
            copiedRouteURL = url
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if copiedRouteURL == url { copiedRouteURL = nil }
            }
        } label: {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(isCopied ? theme.successColor : theme.tertiaryText)
                .frame(width: 20, height: 20)
                .background(Circle().fill(theme.tertiaryBackground.opacity(0.5)))
        }
        .buttonStyle(PlainButtonStyle())
        .help(isCopied ? "Copied" : "Copy URL")
    }

    private func routeMethodColor(_ method: String) -> Color {
        switch method.uppercased() {
        case "GET": return .green
        case "POST": return .blue
        case "PUT", "PATCH": return .orange
        case "DELETE": return .red
        default: return theme.accentColor
        }
    }

    private func routeAuthColor(_ auth: PluginManifest.RouteAuth) -> Color {
        switch auth {
        case .none: return .green
        case .verify: return .orange
        case .owner: return .blue
        }
    }

    // MARK: - Sandbox Tab Sections

    @ViewBuilder
    private var sandboxSection: some View {
        let sandboxAvailable = SandboxManager.State.shared.availability.isAvailable
        let sandboxRunning = SandboxManager.State.shared.status == .running
        let execConfig = agentManager.effectiveAutonomousExec(for: agent.id)
        let updateExecConfig: ((inout AutonomousExecConfig) -> Void) -> Void = { update in
            var config = execConfig ?? .default
            update(&config)
            Task { @MainActor in
                do {
                    try await agentManager.updateAutonomousExec(config, for: agent.id)
                } catch {
                    ToastManager.shared.error(
                        "Failed to update sandbox access",
                        message: error.localizedDescription
                    )
                }
            }
        }

        let sandboxSubtitle: String = {
            if sandboxRunning { return "Running" }
            if sandboxAvailable { return "Not Running" }
            return "Unavailable"
        }()

        AgentDetailSection(
            title: L("Sandbox"),
            icon: "shippingbox",
            subtitle: sandboxSubtitle
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if !sandboxAvailable {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundColor(theme.tertiaryText)
                        Text("Sandbox requires macOS 26+. Native plugins work normally.", bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                    }
                } else if !sandboxRunning {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundColor(theme.tertiaryText)
                        Text("Start the sandbox container to enable these options.", bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                    }
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Autonomous Execution", bundle: .module)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.primaryText)
                            Text("Allow agent to run arbitrary commands in the sandbox", bundle: .module)
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                        }
                        Spacer()
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { execConfig?.enabled ?? false },
                                set: { enabled in
                                    updateExecConfig { $0.enabled = enabled }
                                }
                            )
                        )
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }

                    if execConfig?.enabled == true {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Plugin Creation", bundle: .module)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.primaryText)
                                Text("Agent can create its own tools as plugins", bundle: .module)
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.tertiaryText)
                            }
                            Spacer()
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { execConfig?.pluginCreate ?? false },
                                    set: { create in
                                        updateExecConfig { $0.pluginCreate = create }
                                    }
                                )
                            )
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }
                    }

                }
            }
        }
    }

    @ViewBuilder
    private var bonjourSection: some View {
        AgentDetailSection(title: "Bonjour", icon: "antenna.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Advertise this agent on your local network via Bonjour so nearby devices can discover it automatically.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local Network Discovery", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                        Text("Broadcast this agent as a \(BonjourAdvertiser.serviceType) service", bundle: .module)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }

                    Spacer()

                    Toggle(
                        "",
                        isOn: Binding(
                            get: { currentAgent.bonjourEnabled },
                            set: { newValue in
                                var updated = currentAgent
                                updated.bonjourEnabled = newValue
                                agentManager.update(updated)
                                showSaveIndicator()
                            }
                        )
                    )
                    .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                    .labelsHidden()
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )

                if currentAgent.bonjourEnabled {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(theme.warningColor)
                        Text("Your server is exposed to the local network while Bonjour is enabled.", bundle: .module)
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var relaySection: some View {
        let hasIdentity = currentAgent.agentAddress != nil && currentAgent.agentIndex != nil
        if hasIdentity {
            let status = relayManager.agentStatuses[agent.id] ?? .disconnected
            let isEnabled = relayManager.isTunnelEnabled(for: agent.id)

            AgentDetailSection(title: "Relay", icon: "globe") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(
                        "Expose this agent to the public internet via a relay tunnel so external services can reach it.",
                        bundle: .module
                    )
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)

                    HStack(spacing: 12) {
                        relayStatusDot(status)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 3) {
                            if let address = currentAgent.agentAddress {
                                let truncated = String(address.prefix(8)) + "..." + String(address.suffix(4))
                                Text(truncated)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(theme.tertiaryText)
                            }

                            if case .connected(let url) = status {
                                HStack(spacing: 4) {
                                    Text(url)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(theme.accentColor)
                                        .lineLimit(1)

                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(url, forType: .string)
                                        copiedRelayURL = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                            copiedRelayURL = false
                                        }
                                    } label: {
                                        Image(systemName: copiedRelayURL ? "checkmark" : "doc.on.doc")
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundColor(copiedRelayURL ? theme.successColor : theme.tertiaryText)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .help(Text("Copy relay URL", bundle: .module))
                                }
                            }

                            if case .error(let msg) = status {
                                Text(msg)
                                    .font(.system(size: 10))
                                    .foregroundColor(theme.errorColor)
                            }
                        }

                        Spacer()

                        relayStatusBadge(status)

                        Toggle(
                            "",
                            isOn: Binding(
                                get: { isEnabled },
                                set: { newValue in
                                    if newValue {
                                        showRelayConfirmation = true
                                    } else {
                                        relayManager.setTunnelEnabled(false, for: agent.id)
                                    }
                                }
                            )
                        )
                        .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                        .labelsHidden()
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.inputBorder, lineWidth: 1)
                            )
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func relayStatusDot(_ status: AgentRelayStatus) -> some View {
        switch status {
        case .disconnected:
            Circle()
                .fill(theme.tertiaryText.opacity(0.4))
                .frame(width: 8, height: 8)
        case .connecting:
            Circle()
                .fill(theme.warningColor)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .fill(theme.warningColor.opacity(0.3))
                        .frame(width: 16, height: 16)
                )
        case .connected:
            Circle()
                .fill(theme.successColor)
                .frame(width: 8, height: 8)
        case .error:
            Circle()
                .fill(theme.errorColor)
                .frame(width: 8, height: 8)
        }
    }

    private func relayStatusBadge(_ status: AgentRelayStatus) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case .disconnected: return ("Disconnected", theme.tertiaryText)
            case .connecting: return ("Connecting", theme.warningColor)
            case .connected: return ("Connected", theme.successColor)
            case .error: return ("Error", theme.errorColor)
            }
        }()
        return Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.1)))
    }

    private var quickActionsSection: some View {
        AgentDetailSection(
            title: L("Quick Actions"),
            icon: "bolt.fill"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Prompt shortcuts shown in the empty state. Customize each mode independently.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)

                quickActionsModeGroup(
                    label: "Chat",
                    icon: "bubble.left.fill",
                    actions: $chatQuickActions,
                    defaults: AgentQuickAction.defaultChatQuickActions
                )

                quickActionsModeGroup(
                    label: "Work",
                    icon: "hammer.fill",
                    actions: $workQuickActions,
                    defaults: AgentQuickAction.defaultWorkQuickActions
                )
            }
        }
    }

    private func quickActionsModeGroup(
        label: String,
        icon: String,
        actions: Binding<[AgentQuickAction]?>,
        defaults: [AgentQuickAction]
    ) -> some View {
        let enabled = actions.wrappedValue == nil || !actions.wrappedValue!.isEmpty
        let resolved = actions.wrappedValue ?? defaults
        let isCustomized = actions.wrappedValue != nil

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text(!enabled ? "Hidden" : isCustomized ? "\(resolved.count) custom" : "Default")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)

                Spacer()

                Toggle(
                    "",
                    isOn: Binding(
                        get: { enabled },
                        set: { newEnabled in
                            if newEnabled {
                                actions.wrappedValue = nil
                            } else {
                                actions.wrappedValue = []
                            }
                            editingQuickActionId = nil
                            debouncedSave()
                        }
                    )
                )
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            }

            if enabled {
                VStack(spacing: 0) {
                    ForEach(Array(resolved.enumerated()), id: \.element.id) { index, action in
                        if index > 0 {
                            Divider().background(theme.primaryBorder)
                        }
                        quickActionRow(
                            action: action,
                            index: index,
                            actions: actions,
                            isCustomized: isCustomized
                        )
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 12) {
                    Button {
                        if actions.wrappedValue == nil {
                            actions.wrappedValue = defaults
                        }
                        let newAction = AgentQuickAction(icon: "star", text: "", prompt: "")
                        actions.wrappedValue!.append(newAction)
                        editingQuickActionId = newAction.id
                        debouncedSave()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Add", bundle: .module)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(PlainButtonStyle())

                    if isCustomized {
                        Button {
                            actions.wrappedValue = nil
                            editingQuickActionId = nil
                            debouncedSave()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 10))
                                Text("Reset to Defaults", bundle: .module)
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(theme.secondaryText)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    Spacer()
                }
            }
        }
    }

    private func quickActionRow(
        action: AgentQuickAction,
        index: Int,
        actions: Binding<[AgentQuickAction]?>,
        isCustomized: Bool
    ) -> some View {
        let isEditing = editingQuickActionId == action.id

        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: action.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(action.text.isEmpty ? "Untitled" : action.text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(action.text.isEmpty ? theme.placeholderText : theme.primaryText)
                        .lineLimit(1)
                    Text(action.prompt.isEmpty ? "No prompt" : action.prompt)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }

                Spacer()

                if isCustomized {
                    HStack(spacing: 4) {
                        Button {
                            editingQuickActionId = isEditing ? nil : action.id
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(isEditing ? theme.accentColor : theme.tertiaryText)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(PlainButtonStyle())

                        if index > 0 {
                            Button {
                                moveQuickAction(in: actions, from: index, direction: -1)
                            } label: {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(theme.tertiaryText)
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        if index < (actions.wrappedValue?.count ?? 0) - 1 {
                            Button {
                                moveQuickAction(in: actions, from: index, direction: 1)
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(theme.tertiaryText)
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        Button {
                            deleteQuickAction(in: actions, at: index)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(theme.tertiaryText)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                if isCustomized {
                    editingQuickActionId = isEditing ? nil : action.id
                }
            }

            if isEditing, isCustomized {
                VStack(spacing: 10) {
                    Divider().background(theme.primaryBorder)

                    HStack(spacing: 10) {
                        StyledTextField(
                            placeholder: "SF Symbol name",
                            text: quickActionBinding(in: actions, for: action.id, keyPath: \.icon),
                            icon: "star"
                        )
                        .frame(width: 160)

                        StyledTextField(
                            placeholder: "Display text",
                            text: quickActionBinding(in: actions, for: action.id, keyPath: \.text),
                            icon: "textformat"
                        )
                    }

                    StyledTextField(
                        placeholder: "Prompt prefix (e.g. 'Explain ')",
                        text: quickActionBinding(in: actions, for: action.id, keyPath: \.prompt),
                        icon: "text.cursor"
                    )
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isEditing)
    }

    private func quickActionBinding(
        in actions: Binding<[AgentQuickAction]?>,
        for id: UUID,
        keyPath: WritableKeyPath<AgentQuickAction, String>
    ) -> Binding<String> {
        Binding(
            get: {
                actions.wrappedValue?.first(where: { $0.id == id })?[keyPath: keyPath] ?? ""
            },
            set: { newValue in
                if let idx = actions.wrappedValue?.firstIndex(where: { $0.id == id }) {
                    actions.wrappedValue?[idx][keyPath: keyPath] = newValue
                    debouncedSave()
                }
            }
        )
    }

    private func moveQuickAction(in actions: Binding<[AgentQuickAction]?>, from index: Int, direction: Int) {
        guard var list = actions.wrappedValue else { return }
        let newIndex = index + direction
        guard newIndex >= 0, newIndex < list.count else { return }
        list.swapAt(index, newIndex)
        actions.wrappedValue = list
        debouncedSave()
    }

    private func deleteQuickAction(in actions: Binding<[AgentQuickAction]?>, at index: Int) {
        guard actions.wrappedValue != nil else { return }
        let deletedId = actions.wrappedValue![index].id
        actions.wrappedValue!.remove(at: index)
        if editingQuickActionId == deletedId {
            editingQuickActionId = nil
        }
        debouncedSave()
    }

    private var themeSection: some View {
        AgentDetailSection(title: "Visual Theme", icon: "paintpalette.fill") {
            VStack(alignment: .leading, spacing: 12) {
                themePickerGrid

                Text("Optionally assign a visual theme to this agent.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }

    @ViewBuilder
    private var themePickerGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
            ThemeOptionCard(
                name: "Default",
                colors: [theme.accentColor, theme.primaryBackground, theme.successColor],
                isSelected: selectedThemeId == nil,
                onSelect: {
                    selectedThemeId = nil; saveAgent()
                }
            )

            ForEach(themeManager.installedThemes, id: \.metadata.id) { customTheme in
                ThemeOptionCard(
                    name: customTheme.metadata.name,
                    colors: [
                        Color(themeHex: customTheme.colors.accentColor),
                        Color(themeHex: customTheme.colors.primaryBackground),
                        Color(themeHex: customTheme.colors.successColor),
                    ],
                    isSelected: selectedThemeId == customTheme.metadata.id,
                    onSelect: {
                        selectedThemeId = customTheme.metadata.id; saveAgent()
                    }
                )
            }
        }
    }

    // MARK: - Automation Tab Sections

    private var schedulesSection: some View {
        AgentDetailSection(
            title: L("Schedules"),
            icon: "clock.fill",
            subtitle: linkedSchedules.isEmpty ? "None" : "\(linkedSchedules.count)"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if linkedSchedules.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.badge.questionmark")
                            .font(.system(size: 24))
                            .foregroundColor(theme.tertiaryText)
                        Text("No schedules linked to this agent", bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    ForEach(linkedSchedules) { schedule in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(schedule.isEnabled ? theme.successColor : theme.tertiaryText)
                                .frame(width: 8, height: 8)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(schedule.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(theme.primaryText)

                                HStack(spacing: 8) {
                                    Text(schedule.frequency.displayDescription)
                                        .font(.system(size: 11))
                                        .foregroundColor(theme.secondaryText)

                                    if let nextRun = schedule.nextRunDescription {
                                        Text("Next: \(nextRun)", bundle: .module)
                                            .font(.system(size: 10))
                                            .foregroundColor(theme.tertiaryText)
                                    }
                                }
                            }

                            Spacer()

                            Text(schedule.isEnabled ? "Active" : "Paused")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(schedule.isEnabled ? theme.successColor : theme.tertiaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(
                                            (schedule.isEnabled ? theme.successColor : theme.tertiaryText).opacity(0.1)
                                        )
                                )
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.inputBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.inputBorder, lineWidth: 1)
                                )
                        )
                    }
                }

                Button {
                    showCreateSchedule = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 11))
                        Text("Create Schedule", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private var watchersSection: some View {
        AgentDetailSection(
            title: L("Watchers"),
            icon: "eye.fill",
            subtitle: linkedWatchers.isEmpty ? "None" : "\(linkedWatchers.count)"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if linkedWatchers.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 24))
                            .foregroundColor(theme.tertiaryText)
                        Text("No watchers linked to this agent", bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    ForEach(linkedWatchers) { watcher in
                        watcherRow(watcher)
                    }
                }

                Button {
                    showCreateWatcher = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 11))
                        Text("Create Watcher", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private func watcherRow(_ watcher: Watcher) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(watcher.isEnabled ? theme.successColor : theme.tertiaryText)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(watcher.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)

                HStack(spacing: 8) {
                    if let path = watcher.watchPath {
                        Text(path)
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }

                    if let lastTriggered = watcher.lastTriggeredAt {
                        Text("Last: \(lastTriggered.formatted(date: .abbreviated, time: .shortened))", bundle: .module)
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                    }
                }
            }

            Spacer()

            Text(watcher.isEnabled ? "Active" : "Paused")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(watcher.isEnabled ? theme.successColor : theme.tertiaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill((watcher.isEnabled ? theme.successColor : theme.tertiaryText).opacity(0.1))
                )
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Memory Tab Sections

    private var historySection: some View {
        AgentDetailSection(
            title: L("History"),
            icon: "clock.arrow.circlepath",
            subtitle:
                "\(chatSessions.count) chat\(chatSessions.count == 1 ? "" : "s"), \(workTasks.count) task\(workTasks.count == 1 ? "" : "s")"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(theme.accentColor)
                            Text("RECENT CHATS", bundle: .module)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(theme.secondaryText)
                                .tracking(0.3)
                        }
                        Spacer()
                        Button {
                            ChatWindowManager.shared.createWindow(agentId: agent.id)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "plus")
                                    .font(.system(size: 9, weight: .semibold))
                                Text("New Chat", bundle: .module)
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(theme.accentColor)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    if chatSessions.isEmpty {
                        Text("No chat sessions yet", bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.tertiaryText)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(chatSessions.prefix(5)) { session in
                            ClickableHistoryRow {
                                ChatWindowManager.shared.createWindow(
                                    agentId: agent.id,
                                    sessionData: session
                                )
                            } content: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.title)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(theme.primaryText)
                                            .lineLimit(1)

                                        Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.system(size: 10))
                                            .foregroundColor(theme.tertiaryText)
                                    }
                                    Spacer()
                                    HStack(spacing: 4) {
                                        Text("\(session.turns.count) turns", bundle: .module)
                                            .font(.system(size: 10))
                                            .foregroundColor(theme.tertiaryText)
                                        Image(systemName: "arrow.up.right")
                                            .font(.system(size: 8, weight: .medium))
                                            .foregroundColor(theme.tertiaryText)
                                    }
                                }
                            }
                        }
                        if chatSessions.count > 5 {
                            Text("and \(chatSessions.count - 5) more...", bundle: .module)
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                                .padding(.leading, 4)
                        }
                    }
                }

                Rectangle()
                    .fill(theme.primaryBorder)
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "checklist")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.accentColor)
                        Text("RECENT TASKS", bundle: .module)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(theme.secondaryText)
                            .tracking(0.3)
                    }

                    if workTasks.isEmpty {
                        Text("No work tasks yet", bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.tertiaryText)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(workTasks.prefix(5)) { task in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(taskStatusColor(task.status))
                                    .frame(width: 6, height: 6)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(theme.primaryText)
                                        .lineLimit(1)

                                    Text(task.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 10))
                                        .foregroundColor(theme.tertiaryText)
                                }
                                Spacer()
                                Text(task.status.rawValue.capitalized)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(taskStatusColor(task.status))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.inputBackground.opacity(0.5))
                            )
                        }
                        if workTasks.count > 5 {
                            Text("and \(workTasks.count - 5) more...", bundle: .module)
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                                .padding(.leading, 4)
                        }
                    }
                }
            }
        }
    }

    private var workingMemorySection: some View {
        AgentDetailSection(
            title: L("Working Memory"),
            icon: "brain.head.profile",
            subtitle: memoryEntries.isEmpty ? "None" : "\(memoryEntries.count)"
        ) {
            if memoryEntries.isEmpty {
                Text(
                    "No working memory entries yet. Memories are automatically extracted from conversations.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
                .padding(.vertical, 8)
            } else {
                AgentEntriesPanel(
                    entries: memoryEntries,
                    onDelete: { entryId in
                        deleteMemoryEntry(entryId)
                    }
                )
            }
        }
    }

    private var conversationSummariesSection: some View {
        AgentDetailSection(
            title: L("Summaries"),
            icon: "doc.text",
            subtitle: conversationSummaries.isEmpty ? "None" : "\(conversationSummaries.count)"
        ) {
            if conversationSummaries.isEmpty {
                Text("No conversation summaries yet.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    let displayed = showAllSummaries ? conversationSummaries : Array(conversationSummaries.prefix(10))

                    ForEach(Array(displayed.enumerated()), id: \.element.id) { index, summary in
                        if index > 0 {
                            Divider().opacity(0.5)
                        }
                        MemorySummaryRow(summary: summary)
                    }

                    if conversationSummaries.count > 10 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showAllSummaries.toggle()
                            }
                        } label: {
                            Text(showAllSummaries ? "Show Less" : "View All \(conversationSummaries.count) Summaries")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.accentColor)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.top, 8)
                    }
                }
            }
        }
    }

    private func deleteMemoryEntry(_ entryId: String) {
        try? MemoryDatabase.shared.deleteMemoryEntry(id: entryId)
        loadMemoryData()
        showSuccess("Memory entry deleted")
    }

    private func taskStatusColor(_ status: WorkTaskStatus) -> Color {
        switch status {
        case .active: return theme.accentColor
        case .completed: return theme.successColor
        case .cancelled: return theme.tertiaryText
        }
    }

    // MARK: - Data Loading

    private func loadAgentData() {
        name = agent.name
        description = agent.description
        systemPrompt = agent.systemPrompt
        temperature = agent.temperature.map { String($0) } ?? ""
        maxTokens = agent.maxTokens.map { String($0) } ?? ""
        selectedThemeId = agent.themeId
        chatQuickActions = agent.chatQuickActions
        workQuickActions = agent.workQuickActions
        disableTools = agent.disableTools ?? false
        disableMemory = agent.disableMemory ?? false
        toolSelectionMode = agent.toolSelectionMode ?? .auto
        manualToolNames = Set(agent.manualToolNames ?? [])
        manualSkillNames = Set(agent.manualSkillNames ?? [])

        var instrMap: [String: String] = [:]
        let overrides = agent.pluginInstructions ?? [:]
        for loaded in PluginManager.shared.plugins {
            let pid = loaded.plugin.id
            if let text = overrides[pid] ?? loaded.plugin.manifest.instructions {
                instrMap[pid] = text
            }
        }
        pluginInstructionsMap = instrMap
    }

    private func loadMemoryData() {
        let db = MemoryDatabase.shared
        if !db.isOpen { try? db.open() }
        memoryEntries = (try? db.loadActiveEntries(agentId: agent.id.uuidString)) ?? []
        conversationSummaries = (try? db.loadSummaries(agentId: agent.id.uuidString)) ?? []
    }

    // MARK: - Save

    @MainActor
    private func debouncedSave() {
        guard isInitialLoadComplete else { return }
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            saveAgent()
        }
    }

    @MainActor
    private func saveAgent() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let effectivePluginInstructions: [String: String]? = {
            let overrides = pluginInstructionsMap.filter { pid, text in
                let manifest = PluginManager.shared.loadedPlugin(for: pid)?.plugin.manifest.instructions ?? ""
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
                    != manifest.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return overrides.isEmpty ? nil : overrides
        }()

        let current = currentAgent
        let updated = Agent(
            id: agent.id,
            name: trimmedName,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            themeId: selectedThemeId,
            defaultModel: selectedModel,
            temperature: Float(temperature),
            maxTokens: Int(maxTokens),
            chatQuickActions: chatQuickActions,
            workQuickActions: workQuickActions,
            isBuiltIn: false,
            createdAt: agent.createdAt,
            updatedAt: Date(),
            agentIndex: current.agentIndex,
            agentAddress: current.agentAddress,
            sandboxPlugins: current.sandboxPlugins,
            autonomousExec: current.autonomousExec,
            pluginInstructions: effectivePluginInstructions,
            toolSelectionMode: toolSelectionMode,
            manualToolNames: toolSelectionMode == .manual ? Array(manualToolNames) : nil,
            manualSkillNames: toolSelectionMode == .manual ? Array(manualSkillNames) : nil,
            disableTools: disableTools ? true : nil,
            disableMemory: disableMemory ? true : nil
        )

        agentManager.update(updated)
        showSaveIndicator()
    }

    @MainActor
    private func showSaveIndicator() {
        withAnimation(.easeOut(duration: 0.2)) {
            saveIndicator = "Saved"
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeOut(duration: 0.3)) {
                saveIndicator = nil
            }
        }
    }
}

// MARK: - Clickable History Row

private struct ClickableHistoryRow<Content: View>: View {
    @Environment(\.theme) private var theme

    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            isHovered
                                ? theme.tertiaryBackground.opacity(0.7)
                                : theme.inputBackground.opacity(0.5)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Detail Section Component

private struct AgentDetailSection<Content: View>: View {
    @Environment(\.theme) private var theme

    let title: String
    let icon: String
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 20)

                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.primaryText)
                    .tracking(0.5)

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - Agent Editor Sheet

private struct AgentEditorSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    let onSave: (Agent) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var systemPrompt: String = ""
    @State private var temperature: String = ""
    @State private var maxTokens: String = ""
    @State private var selectedThemeId: UUID?
    @State private var hasAppeared = false

    private var agentColor: Color { agentColorFor(name) }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    EditorSection(title: "Identity", icon: "person.circle.fill") {
                        VStack(spacing: 16) {
                            HStack(spacing: 16) {
                                ZStack {
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                colors: [agentColor.opacity(0.2), agentColor.opacity(0.05)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                    Circle()
                                        .strokeBorder(agentColor.opacity(0.5), lineWidth: 2)
                                    Text(name.isEmpty ? "?" : name.prefix(1).uppercased())
                                        .font(.system(size: 20, weight: .bold, design: .rounded))
                                        .foregroundColor(agentColor)
                                }
                                .frame(width: 52, height: 52)
                                .animation(.spring(response: 0.3), value: name)

                                VStack(alignment: .leading, spacing: 12) {
                                    StyledTextField(
                                        placeholder: "e.g., Code Assistant",
                                        text: $name,
                                        icon: "textformat"
                                    )
                                }
                            }

                            StyledTextField(
                                placeholder: "Brief description (optional)",
                                text: $description,
                                icon: "text.alignleft"
                            )
                        }
                    }

                    EditorSection(title: "System Prompt", icon: "brain") {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack(alignment: .topLeading) {
                                if systemPrompt.isEmpty {
                                    Text("Enter instructions for this agent...", bundle: .module)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(theme.placeholderText)
                                        .padding(.top, 12)
                                        .padding(.leading, 16)
                                        .allowsHitTesting(false)
                                }

                                TextEditor(text: $systemPrompt)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(theme.primaryText)
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 140, maxHeight: 200)
                                    .padding(12)
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(theme.inputBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(theme.inputBorder, lineWidth: 1)
                                    )
                            )

                            Text(
                                "Instructions that define this agent's behavior. Leave empty to use global settings.",
                                bundle: .module
                            )
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                        }
                    }

                    EditorSection(title: "Generation", icon: "cpu") {
                        VStack(spacing: 16) {
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Label {
                                        Text("Temperature", bundle: .module)
                                    } icon: {
                                        Image(systemName: "thermometer.medium")
                                    }
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(theme.secondaryText)

                                    StyledTextField(
                                        placeholder: "0.7",
                                        text: $temperature,
                                        icon: nil
                                    )
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Label {
                                        Text("Max Tokens", bundle: .module)
                                    } icon: {
                                        Image(systemName: "number")
                                    }
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(theme.secondaryText)

                                    StyledTextField(
                                        placeholder: "4096",
                                        text: $maxTokens,
                                        icon: nil
                                    )
                                }
                            }

                            Text("Leave empty to use default values from global settings.", bundle: .module)
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                        }
                    }

                    EditorSection(title: "Visual Theme", icon: "paintpalette.fill") {
                        VStack(alignment: .leading, spacing: 12) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                                ThemeOptionCard(
                                    name: "Default",
                                    colors: [theme.accentColor, theme.primaryBackground, theme.successColor],
                                    isSelected: selectedThemeId == nil,
                                    onSelect: { selectedThemeId = nil }
                                )

                                ForEach(themeManager.installedThemes, id: \.metadata.id) { customTheme in
                                    ThemeOptionCard(
                                        name: customTheme.metadata.name,
                                        colors: [
                                            Color(themeHex: customTheme.colors.accentColor),
                                            Color(themeHex: customTheme.colors.primaryBackground),
                                            Color(themeHex: customTheme.colors.successColor),
                                        ],
                                        isSelected: selectedThemeId == customTheme.metadata.id,
                                        onSelect: { selectedThemeId = customTheme.metadata.id }
                                    )
                                }
                            }

                            Text("Optionally assign a visual theme to this agent.", bundle: .module)
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                        }
                    }
                }
                .padding(24)
            }

            footerView
        }
        .frame(width: 580, height: 620)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.primaryBorder.opacity(0.5), lineWidth: 1)
        )
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.95)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hasAppeared)
        .onAppear {
            withAnimation { hasAppeared = true }
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [theme.accentColor.opacity(0.2), theme.accentColor.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [theme.accentColor, theme.accentColor.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("Create Agent", bundle: .module)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text("Build your custom AI assistant", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.tertiaryBackground))
            }
            .buttonStyle(PlainButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            theme.secondaryBackground
                .overlay(
                    LinearGradient(
                        colors: [theme.accentColor.opacity(0.03), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    // MARK: - Footer View

    private var footerView: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text("\u{2318}", bundle: .module)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.tertiaryBackground)
                    )
                Text("+ Enter to save", bundle: .module)
                    .font(.system(size: 11))
            }
            .foregroundColor(theme.tertiaryText)

            Spacer()

            Button(action: onCancel) { Text("Cancel", bundle: .module) }
                .buttonStyle(SecondaryButtonStyle())

            Button {
                saveAgent()
            } label: {
                Text("Create Agent", bundle: .module)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            theme.secondaryBackground
                .overlay(
                    Rectangle()
                        .fill(theme.primaryBorder)
                        .frame(height: 1),
                    alignment: .top
                )
        )
    }

    @MainActor
    private func saveAgent() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let agent = Agent(
            id: UUID(),
            name: trimmedName,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            themeId: selectedThemeId,
            defaultModel: nil,
            temperature: Float(temperature),
            maxTokens: Int(maxTokens),
            isBuiltIn: false,
            createdAt: Date(),
            updatedAt: Date()
        )

        onSave(agent)
    }
}

// MARK: - Editor Section

private struct EditorSection<Content: View>: View {
    @Environment(\.theme) private var theme

    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)

                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .tracking(0.5)
            }

            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - Styled Text Field

private struct StyledTextField: View {
    @Environment(\.theme) private var theme

    let placeholder: String
    @Binding var text: String
    let icon: String?

    @State private var isFocused = false

    var body: some View {
        HStack(spacing: 10) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isFocused ? theme.accentColor : theme.tertiaryText)
                    .frame(width: 16)
            }

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundColor(theme.placeholderText)
                        .allowsHitTesting(false)
                }

                TextField(
                    "",
                    text: $text,
                    onEditingChanged: { editing in
                        withAnimation(.easeOut(duration: 0.15)) {
                            isFocused = editing
                        }
                    }
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(theme.primaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isFocused ? theme.accentColor.opacity(0.5) : theme.inputBorder,
                            lineWidth: isFocused ? 1.5 : 1
                        )
                )
        )
    }
}

// MARK: - Theme Option Card

private struct ThemeOptionCard: View {
    @Environment(\.theme) private var theme

    let name: String
    let colors: [Color]
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(0 ..< min(3, colors.count), id: \.self) { index in
                        Circle()
                            .fill(colors[index])
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                            )
                    }
                }

                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isSelected ? theme.accentColor : theme.inputBorder,
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.spring(response: 0.2), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Button Styles

private struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.accentColor)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

#Preview {
    AgentsView()
}
