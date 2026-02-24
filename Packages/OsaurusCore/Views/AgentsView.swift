//
//  AgentsView.swift
//  osaurus
//
//  Management view for creating, editing, and deleting Agents
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared Helpers

/// Generate a consistent color based on an agent name
func agentColorFor(_ name: String) -> Color {
    let hash = abs(name.hashValue)
    let hue = Double(hash % 360) / 360.0
    return Color(hue: hue, saturation: 0.6, brightness: 0.8)
}

/// Format a model identifier to show only the last path component
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

    // Import/Export
    @State private var showImportPicker = false
    @State private var importError: String?
    @State private var showExportSuccess = false

    /// Custom agents only (excluding built-in)
    private var customAgents: [Agent] {
        agentManager.agents.filter { !$0.isBuiltIn }
    }

    var body: some View {
        ZStack {
            // Grid view
            if selectedAgent == nil {
                gridContent
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }

            // Detail view
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
                            agentManager.delete(id: p.id)
                            showSuccess("Deleted \"\(p.name)\"")
                        }
                    },
                    showSuccess: { msg in
                        showSuccess(msg)
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            // Success toast
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
                    AgentStore.save(agent)
                    agentManager.refresh()
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
            // Header
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            // Content
            if customAgents.isEmpty {
                SettingsEmptyState(
                    icon: "theatermasks.fill",
                    title: "Create Your First Agent",
                    subtitle: "Custom AI assistants with unique prompts, tools, and styles.",
                    examples: [
                        .init(icon: "calendar", title: "Daily Planner", description: "Manage your schedule"),
                        .init(icon: "message.fill", title: "Message Assistant", description: "Draft and send texts"),
                        .init(icon: "map.fill", title: "Local Guide", description: "Find places nearby"),
                    ],
                    primaryAction: .init(title: "Create Agent", icon: "plus", handler: { isCreating = true }),
                    secondaryAction: .init(
                        title: "Import",
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
                                    agentManager.delete(id: agent.id)
                                    showSuccess("Deleted \"\(agent.name)\"")
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
            title: "Agents",
            subtitle: "Create custom assistant personalities with unique behaviors",
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

    private func duplicateAgent(_ agent: Agent) {
        // Generate unique copy name
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
            enabledTools: agent.enabledTools,
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

        // Open detail for the duplicated agent
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

            // Start accessing security-scoped resource
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
    @ObservedObject private var scheduleManager = ScheduleManager.shared

    let agent: Agent
    let isActive: Bool
    let animationDelay: Double
    let hasAppeared: Bool
    let onSelect: () -> Void
    let onDuplicate: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var showDeleteConfirm = false

    private var agentColor: Color { agentColorFor(agent.name) }

    /// Resolved enabled tool count
    private var enabledToolCount: Int {
        let overrides = agentManager.effectiveToolOverrides(for: agent.id)
        let tools = ToolRegistry.shared.listUserTools(withOverrides: overrides, excludeInternal: true)
        return tools.filter { $0.enabled }.count
    }

    /// Total tool count
    private var totalToolCount: Int {
        ToolRegistry.shared.listTools().count
    }

    /// Resolved enabled skill count
    private var enabledSkillCount: Int {
        let skills = SkillManager.shared.skills
        return skills.filter { skill in
            if let overrides = agentManager.effectiveSkillOverrides(for: agent.id),
                let value = overrides[skill.name]
            {
                return value
            }
            return skill.enabled
        }.count
    }

    /// Total skill count
    private var totalSkillCount: Int {
        SkillManager.shared.skills.count
    }

    /// Schedule count for this agent
    private var scheduleCount: Int {
        scheduleManager.schedules.filter { $0.agentId == agent.id }.count
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                // Header row
                HStack(alignment: .center, spacing: 12) {
                    // Avatar with colored ring
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
                                Text("Active")
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

                    // Context menu button
                    Menu {
                        Button(action: onSelect) {
                            Label("Open", systemImage: "arrow.right.circle")
                        }
                        Button(action: onDuplicate) {
                            Label("Duplicate", systemImage: "doc.on.doc")
                        }
                        Button(action: onExport) {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        Divider()
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete", systemImage: "trash")
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

                // System prompt excerpt
                if !agent.systemPrompt.isEmpty {
                    Text(agent.systemPrompt)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Compact stat row
                compactStats
            }
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
            message: "Are you sure you want to delete \"\(agent.name)\"? This action cannot be undone.",
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
            statItem(icon: "wrench.and.screwdriver", text: "\(enabledToolCount)/\(totalToolCount)")
            statDot
            statItem(icon: "sparkles", text: "\(enabledSkillCount)/\(totalSkillCount)")

            if scheduleCount > 0 {
                statDot
                statItem(icon: "clock", text: "\(scheduleCount)")
            }

            if let model = agent.defaultModel {
                statDot
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

// MARK: - Agent Detail View

struct AgentDetailView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var scheduleManager = ScheduleManager.shared
    @ObservedObject private var watcherManager = WatcherManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    let agent: Agent
    let onBack: () -> Void
    let onExport: (Agent) -> Void
    let onDelete: (Agent) -> Void
    let showSuccess: (String) -> Void

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

    // MARK: - UI State

    @State private var hasAppeared = false
    @State private var saveIndicator: String?
    @State private var saveDebounceTask: Task<Void, Never>?
    @State private var showDeleteConfirm = false

    // Model picker
    @State private var modelOptions: [ModelOption] = []
    @State private var showModelPicker = false
    @State private var selectedModel: String?

    // Schedule & Watcher creation
    @State private var showCreateSchedule = false
    @State private var showCreateWatcher = false

    // Memory
    @State private var memoryEntries: [MemoryEntry] = []
    @State private var conversationSummaries: [ConversationSummary] = []
    @State private var showAllSummaries = false

    // Guard to prevent save on initial load
    @State private var isInitialLoadComplete = false

    /// Current agent (refreshed from manager)
    private var currentAgent: Agent {
        agentManager.agent(for: agent.id) ?? agent
    }

    /// Schedules linked to this agent
    private var linkedSchedules: [Schedule] {
        scheduleManager.schedules.filter { $0.agentId == agent.id }
    }

    /// Watchers linked to this agent
    private var linkedWatchers: [Watcher] {
        watcherManager.watchers.filter { $0.agentId == agent.id }
    }

    /// Chat sessions for this agent
    private var chatSessions: [ChatSessionData] {
        ChatSessionsManager.shared.sessions(for: agent.id)
    }

    /// Tasks for this agent
    private var workTasks: [WorkTask] {
        (try? IssueStore.listTasks(agentId: agent.id)) ?? []
    }

    private var agentColor: Color { agentColorFor(name) }

    /// Resolved enabled tool count using AgentManager's effective overrides
    private var resolvedEnabledToolCount: Int {
        let overrides = agentManager.effectiveToolOverrides(for: agent.id)
        let tools = ToolRegistry.shared.listUserTools(withOverrides: overrides, excludeInternal: true)
        return tools.filter { $0.enabled }.count
    }

    /// Resolved enabled skill count using AgentManager's effective overrides
    private var resolvedEnabledSkillCount: Int {
        let skills = SkillManager.shared.skills
        return skills.filter { skill in
            if let overrides = agentManager.effectiveSkillOverrides(for: agent.id),
                let value = overrides[skill.name]
            {
                return value
            }
            return skill.enabled
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            detailHeaderBar

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Hero header
                    heroHeader
                        .padding(.bottom, 8)

                    // Sections (all always expanded, ordered by importance)
                    identitySection
                    systemPromptSection
                    generationSection
                    capabilitiesSection
                    quickActionsSection
                    themeSection
                    schedulesSection
                    watchersSection
                    historySection
                    workingMemorySection
                    conversationSummariesSection
                }
                .padding(24)
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
            // Defer the flag so initial .onChange triggers are ignored
            DispatchQueue.main.async {
                isInitialLoadComplete = true
            }
            withAnimation { hasAppeared = true }
        }
        .onReceive(ModelOptionsCache.shared.$modelOptions) { options in
            modelOptions = options
        }
        .themedAlert(
            "Delete Agent",
            isPresented: $showDeleteConfirm,
            message: "Are you sure you want to delete \"\(currentAgent.name)\"? This action cannot be undone.",
            primaryButton: .destructive("Delete") { onDelete(currentAgent) },
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
                    Text("Agents")
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
                .help("Export")

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
                .help("Delete")
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

            VStack(alignment: .leading, spacing: 6) {
                Text(name.isEmpty ? "Untitled Agent" : name)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(theme.primaryText)

                if !description.isEmpty {
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                }

                HStack(spacing: 12) {
                    let toolCount = resolvedEnabledToolCount
                    let totalTools = ToolRegistry.shared.listTools().count
                    statBadge(icon: "wrench.and.screwdriver", text: "\(toolCount)/\(totalTools) tools", color: .orange)

                    let skillCount = resolvedEnabledSkillCount
                    let totalSkills = SkillManager.shared.skills.count
                    statBadge(icon: "sparkles", text: "\(skillCount)/\(totalSkills) skills", color: .cyan)

                    if !linkedSchedules.isEmpty {
                        statBadge(
                            icon: "clock",
                            text: "\(linkedSchedules.count) schedule\(linkedSchedules.count == 1 ? "" : "s")",
                            color: .green
                        )
                    }
                    if !linkedWatchers.isEmpty {
                        statBadge(
                            icon: "eye",
                            text: "\(linkedWatchers.count) watcher\(linkedWatchers.count == 1 ? "" : "s")",
                            color: .purple
                        )
                    }
                    statBadge(
                        icon: "calendar",
                        text: "Created \(agent.createdAt.formatted(date: .abbreviated, time: .omitted))",
                        color: theme.tertiaryText
                    )
                }
                .padding(.top, 2)
            }

            Spacer()
        }
    }

    private func statBadge(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.tertiaryText)
        }
    }

    // MARK: - Identity Section

    private var identitySection: some View {
        AgentDetailSection(title: "Identity", icon: "person.circle.fill") {
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
            .onChange(of: name) { debouncedSave() }
            .onChange(of: description) { debouncedSave() }
        }
    }

    // MARK: - System Prompt Section

    private var systemPromptSection: some View {
        AgentDetailSection(title: "System Prompt", icon: "brain") {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if systemPrompt.isEmpty {
                        Text("Enter instructions for this agent...")
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

                Text("Instructions that define this agent's behavior. Leave empty to use global settings.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            .onChange(of: systemPrompt) { debouncedSave() }
        }
    }

    // MARK: - Generation Section

    private var generationSection: some View {
        AgentDetailSection(title: "Generation", icon: "cpu") {
            VStack(spacing: 16) {
                // Model selector
                VStack(alignment: .leading, spacing: 6) {
                    Label("Default Model", systemImage: "cube.fill")
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
                                Text("Default (from global settings)")
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
                            options: modelOptions,
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
                                Text("Reset to default")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(theme.accentColor)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Temperature", systemImage: "thermometer.medium")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.secondaryText)

                        StyledTextField(placeholder: "0.7", text: $temperature, icon: nil)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Max Tokens", systemImage: "number")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.secondaryText)

                        StyledTextField(placeholder: "4096", text: $maxTokens, icon: nil)
                    }
                }

                Text("Leave empty to use default values from global settings.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            .onChange(of: temperature) { debouncedSave() }
            .onChange(of: maxTokens) { debouncedSave() }
        }
    }

    // MARK: - Abilities Section

    private var capabilitiesSection: some View {
        AgentDetailSection(
            title: "Abilities",
            icon: "wrench.and.screwdriver",
            subtitle: "\(resolvedEnabledToolCount + resolvedEnabledSkillCount) enabled"
        ) {
            CapabilitiesSelectorView(agentId: agent.id, isInline: true)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Quick Actions Section

    private var quickActionsSection: some View {
        AgentDetailSection(
            title: "Quick Actions",
            icon: "bolt.fill"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Prompt shortcuts shown in the empty state. Customize each mode independently.")
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
                            Text("Add")
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
                                Text("Reset to Defaults")
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

    // MARK: - Theme Section

    private var themeSection: some View {
        AgentDetailSection(title: "Visual Theme", icon: "paintpalette.fill") {
            VStack(alignment: .leading, spacing: 12) {
                themePickerGrid

                Text("Optionally assign a visual theme to this agent.")
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

    // MARK: - Schedules Section

    private var schedulesSection: some View {
        AgentDetailSection(
            title: "Schedules",
            icon: "clock.fill",
            subtitle: linkedSchedules.isEmpty ? "None" : "\(linkedSchedules.count)"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if linkedSchedules.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.badge.questionmark")
                            .font(.system(size: 24))
                            .foregroundColor(theme.tertiaryText)
                        Text("No schedules linked to this agent")
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
                                        Text("Next: \(nextRun)")
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
                        Text("Create Schedule")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    // MARK: - Watchers Section

    private var watchersSection: some View {
        AgentDetailSection(
            title: "Watchers",
            icon: "eye.fill",
            subtitle: linkedWatchers.isEmpty ? "None" : "\(linkedWatchers.count)"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if linkedWatchers.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 24))
                            .foregroundColor(theme.tertiaryText)
                        Text("No watchers linked to this agent")
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
                        Text("Create Watcher")
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
                        Text("Last: \(lastTriggered.formatted(date: .abbreviated, time: .shortened))")
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

    // MARK: - History Section

    private var historySection: some View {
        AgentDetailSection(
            title: "History",
            icon: "clock.arrow.circlepath",
            subtitle:
                "\(chatSessions.count) chat\(chatSessions.count == 1 ? "" : "s"), \(workTasks.count) task\(workTasks.count == 1 ? "" : "s")"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                // Chat sessions
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(theme.accentColor)
                            Text("RECENT CHATS")
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
                                Text("New Chat")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(theme.accentColor)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    if chatSessions.isEmpty {
                        Text("No chat sessions yet")
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
                                        Text("\(session.turns.count) turns")
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
                            Text("and \(chatSessions.count - 5) more...")
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                                .padding(.leading, 4)
                        }
                    }
                }

                Rectangle()
                    .fill(theme.primaryBorder)
                    .frame(height: 1)

                // Work tasks
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "checklist")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.accentColor)
                        Text("RECENT TASKS")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(theme.secondaryText)
                            .tracking(0.3)
                    }

                    if workTasks.isEmpty {
                        Text("No work tasks yet")
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
                            Text("and \(workTasks.count - 5) more...")
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                                .padding(.leading, 4)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Working Memory Section

    private var workingMemorySection: some View {
        AgentDetailSection(
            title: "Working Memory",
            icon: "brain.head.profile",
            subtitle: memoryEntries.isEmpty ? "None" : "\(memoryEntries.count)"
        ) {
            if memoryEntries.isEmpty {
                Text("No working memory entries yet. Memories are automatically extracted from conversations.")
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

    // MARK: - Conversation Summaries Section

    private var conversationSummariesSection: some View {
        AgentDetailSection(
            title: "Summaries",
            icon: "doc.text",
            subtitle: conversationSummaries.isEmpty ? "None" : "\(conversationSummaries.count)"
        ) {
            if conversationSummaries.isEmpty {
                Text("No conversation summaries yet.")
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
    }

    private func loadMemoryData() {
        let db = MemoryDatabase.shared
        if !db.isOpen { try? db.open() }
        memoryEntries = (try? db.loadActiveEntries(agentId: agent.id.uuidString)) ?? []
        conversationSummaries = (try? db.loadSummaries(agentId: agent.id.uuidString)) ?? []
    }

    // MARK: - Save

    private func debouncedSave() {
        guard isInitialLoadComplete else { return }
        saveDebounceTask?.cancel()
        saveDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            saveAgent()
        }
    }

    private func saveAgent() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        // Preserve existing tool/skill overrides managed by CapabilitiesSelectorView
        let current = currentAgent

        let updated = Agent(
            id: agent.id,
            name: trimmedName,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            enabledTools: current.enabledTools,
            enabledSkills: current.enabledSkills,
            themeId: selectedThemeId,
            defaultModel: selectedModel,
            temperature: Float(temperature),
            maxTokens: Int(maxTokens),
            chatQuickActions: chatQuickActions,
            workQuickActions: workQuickActions,
            isBuiltIn: false,
            createdAt: agent.createdAt,
            updatedAt: Date()
        )

        agentManager.update(updated)
        showSaveIndicator()
    }

    private func showSaveIndicator() {
        withAnimation(.easeOut(duration: 0.2)) {
            saveIndicator = "Saved"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
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
            // Header
            headerView

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Identity Section
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

                    // System Prompt Section
                    EditorSection(title: "System Prompt", icon: "brain") {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack(alignment: .topLeading) {
                                if systemPrompt.isEmpty {
                                    Text("Enter instructions for this agent...")
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
                                "Instructions that define this agent's behavior. Leave empty to use global settings."
                            )
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                        }
                    }

                    // Generation Settings
                    EditorSection(title: "Generation", icon: "cpu") {
                        VStack(spacing: 16) {
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Label("Temperature", systemImage: "thermometer.medium")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(theme.secondaryText)

                                    StyledTextField(
                                        placeholder: "0.7",
                                        text: $temperature,
                                        icon: nil
                                    )
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Label("Max Tokens", systemImage: "number")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(theme.secondaryText)

                                    StyledTextField(
                                        placeholder: "4096",
                                        text: $maxTokens,
                                        icon: nil
                                    )
                                }
                            }

                            Text("Leave empty to use default values from global settings.")
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                        }
                    }

                    // Theme Section
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

                            Text("Optionally assign a visual theme to this agent.")
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
                Text("Create Agent")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text("Build your custom AI assistant")
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
                Text("\u{2318}")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.tertiaryBackground)
                    )
                Text("+ Enter to save")
                    .font(.system(size: 11))
            }
            .foregroundColor(theme.tertiaryText)

            Spacer()

            Button("Cancel", action: onCancel)
                .buttonStyle(SecondaryButtonStyle())

            Button("Create Agent") {
                saveAgent()
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

    private func saveAgent() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let agent = Agent(
            id: UUID(),
            name: trimmedName,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            enabledTools: nil,
            enabledSkills: nil,
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
