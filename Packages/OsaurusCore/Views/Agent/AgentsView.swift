import SwiftUI

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
    /// Shared spring used for grid ↔ detail navigation. Centralized so the
    /// transition feels identical whether the user opens a local agent, a
    /// remote agent, or a freshly-duplicated one.
    fileprivate static let navTransition = Animation.spring(response: 0.35, dampingFraction: 0.85)

    /// Two-column grid layout reused by the main agent grid and the
    /// "Paired Remote Agents" section in the empty state.
    fileprivate static let gridColumns: [GridItem] = [
        GridItem(.flexible(minimum: 300), spacing: 20),
        GridItem(.flexible(minimum: 300), spacing: 20),
    ]

    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var remoteAgentManager = RemoteAgentManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var selectedAgent: Agent?
    @State private var selectedRemoteAgentId: UUID?
    @State private var isCreating = false
    @State private var hasAppeared = false
    @State private var successMessage: String?
    @State private var sandboxCleanupNotice: SandboxCleanupNotice?

    private var customAgents: [Agent] {
        agentManager.agents.filter { !$0.isBuiltIn }
    }

    private var remoteAgents: [RemoteAgent] {
        remoteAgentManager.remoteAgents
    }

    var body: some View {
        ZStack {
            if selectedAgent == nil && selectedRemoteAgentId == nil {
                gridContent
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }

            if let agent = selectedAgent {
                // `.id(agent.id)` below makes SwiftUI tear down + recreate the
                // detail view when the user switches agents, so all editable
                // state reloads via onAppear without manual onChange wiring.
                AgentDetailView(
                    agent: agent,
                    onBack: {
                        withAnimation(Self.navTransition) { selectedAgent = nil }
                    },
                    onDelete: { p in
                        withAnimation(Self.navTransition) { selectedAgent = nil }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            deleteAgent(p)
                        }
                    },
                    onSwitchAgent: { newAgent in selectedAgent = newAgent },
                    showSuccess: showSuccess
                )
                .id(agent.id)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            if let remoteId = selectedRemoteAgentId {
                RemoteAgentDetailView(
                    remoteId: remoteId,
                    onBack: {
                        withAnimation(Self.navTransition) { selectedRemoteAgentId = nil }
                    },
                    onRemoved: {
                        withAnimation(Self.navTransition) { selectedRemoteAgentId = nil }
                        showSuccess("Removed remote agent")
                    },
                    onChat: { _ in ChatWindowManager.shared.toggleLastFocused() }
                )
                .id(remoteId)
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

            // First-agent onboarding stays reachable as long as the user has no
            // *local* agents — even if they've already paired a remote agent.
            // That way the "Create Your First Agent" CTA never silently
            // disappears just because someone else's agent is sitting in the
            // grid. When both lists exist, we fall through to the normal grid.
            if customAgents.isEmpty {
                ScrollView {
                    VStack(spacing: 24) {
                        SettingsEmptyState(
                            icon: "theatermasks.fill",
                            title: L("Create Your First Agent"),
                            subtitle: L("Custom AI assistants with unique prompts, tools, and styles."),
                            examples: [
                                .init(icon: "calendar", title: "Daily Planner", description: "Manage your schedule"),
                                .init(
                                    icon: "message.fill",
                                    title: "Message Assistant",
                                    description: "Draft and send texts"
                                ),
                                .init(icon: "map.fill", title: "Local Guide", description: "Find places nearby"),
                            ],
                            primaryAction: .init(title: "Create Agent", icon: "plus", handler: { isCreating = true }),
                            hasAppeared: hasAppeared
                        )

                        if !remoteAgents.isEmpty {
                            remoteAgentsSection
                                .padding(.horizontal, 24)
                                .padding(.bottom, 24)
                        }
                    }
                }
                .opacity(hasAppeared ? 1 : 0)
            } else {
                ScrollView {
                    LazyVGrid(columns: Self.gridColumns, spacing: 20) {
                        ForEach(Array(customAgents.enumerated()), id: \.element.id) { index, agent in
                            AgentCard(
                                agent: agent,
                                isActive: agentManager.activeAgentId == agent.id,
                                animationDelay: Double(index) * 0.05,
                                hasAppeared: hasAppeared,
                                onSelect: {
                                    withAnimation(Self.navTransition) { selectedAgent = agent }
                                },
                                onDuplicate: { duplicateAgent(agent) },
                                onDelete: { deleteAgent(agent) }
                            )
                        }

                        // Remote (paired) agents follow local ones with their own
                        // "Remote" treatment. Tap → RemoteAgentDetailView; the
                        // underlying chat plumbing lives in RemoteProviderManager
                        // (created at pair time) so the chat window already lists
                        // this agent in its picker.
                        ForEach(Array(remoteAgents.enumerated()), id: \.element.id) { index, remote in
                            remoteCardCell(remote: remote, indexInGrid: customAgents.count + index)
                        }
                    }
                    .padding(24)
                }
                .opacity(hasAppeared ? 1 : 0)
            }
        }
    }

    /// Standalone "Paired Remote Agents" group rendered below the empty-state
    /// CTA when the user has zero local agents but does have remotes paired.
    /// Keeps remotes discoverable without obscuring the create-first-agent
    /// onboarding above.
    private var remoteAgentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                AgentSheetSectionLabel("Paired Remote Agents")
                Spacer()
            }

            LazyVGrid(columns: Self.gridColumns, spacing: 20) {
                ForEach(Array(remoteAgents.enumerated()), id: \.element.id) { index, remote in
                    remoteCardCell(remote: remote, indexInGrid: index)
                }
            }
        }
    }

    /// Single source of truth for how a `RemoteAgentCard` is wired in either
    /// the main grid or the standalone remote section.
    private func remoteCardCell(remote: RemoteAgent, indexInGrid: Int) -> some View {
        RemoteAgentCard(
            remote: remote,
            animationDelay: Double(indexInGrid) * 0.05,
            hasAppeared: hasAppeared,
            onSelect: {
                withAnimation(Self.navTransition) { selectedRemoteAgentId = remote.id }
            },
            onChat: { ChatWindowManager.shared.toggleLastFocused() },
            onRemove: {
                _ = remoteAgentManager.remove(id: remote.id)
                showSuccess("Removed remote agent")
            }
        )
    }

    // MARK: - Header

    private var headerView: some View {
        let totalCount = customAgents.count + remoteAgents.count
        return ManagerHeaderWithActions(
            title: L("Agents"),
            subtitle: L("Create custom assistant personalities with unique behaviors"),
            count: totalCount == 0 ? nil : totalCount
        ) {
            HeaderIconButton("arrow.clockwise", help: "Refresh agents") {
                agentManager.refresh()
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
            withAnimation(Self.navTransition) {
                selectedAgent = duplicated
            }
        }
    }

}

// MARK: - Agent Card

private struct AgentCard: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared
    private var scheduleManager = ScheduleManager.shared
    private var watcherManager = WatcherManager.shared

    let agent: Agent
    let isActive: Bool
    let animationDelay: Double
    let hasAppeared: Bool
    let onSelect: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    init(
        agent: Agent,
        isActive: Bool,
        animationDelay: Double,
        hasAppeared: Bool,
        onSelect: @escaping () -> Void,
        onDuplicate: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.agent = agent
        self.isActive = isActive
        self.animationDelay = animationDelay
        self.hasAppeared = hasAppeared
        self.onSelect = onSelect
        self.onDuplicate = onDuplicate
        self.onDelete = onDelete
    }

    @State private var isHovered = false
    @State private var showDeleteConfirm = false

    private var agentColor: Color { agentColorFor(agent.name) }

    private var scheduleCount: Int {
        scheduleManager.schedules.filter { $0.agentId == agent.id }.count
    }

    private var watcherCount: Int {
        watcherManager.watchers.filter { $0.agentId == agent.id }.count
    }

    private var automationCount: Int { scheduleCount + watcherCount }

    /// Number of explicitly-enabled tools. `nil` when the agent has never
    /// engaged the capability picker (legacy / fresh agent that uses the
    /// global registry implicitly), so the UI can read "all" instead of "0".
    private var enabledToolCount: Int? {
        agentManager.effectiveEnabledToolNames(for: agent.id)?.count
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

                        // Always render the description line so card heights line
                        // up across the grid — placeholder when the agent has none.
                        Text(
                            agent.description.isEmpty
                                ? L("No description")
                                : agent.description
                        )
                        .font(.system(size: 11))
                        .foregroundColor(
                            agent.description.isEmpty ? theme.tertiaryText : theme.secondaryText
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)
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

                // System-prompt preview slot — always 2-line tall to keep
                // card rhythm uniform. Italic placeholder when empty.
                if agent.systemPrompt.isEmpty {
                    Text("No system prompt", bundle: .module)
                        .font(.system(size: 12).italic())
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(agent.systemPrompt)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 0)
                compactStats
            }
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .top)
            .padding(16)
            .background(cardBackground)
            .overlay(hoverGradient)
            .overlay(alignment: .bottomTrailing) { hoverChevron }
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

    /// Always-on metadata strip. Builds the chips eagerly so we can intersperse
    /// `statDot` separators without nested `if` chains.
    private var compactStats: some View {
        HStack(spacing: 0) {
            let chips = buildStatChips()
            ForEach(Array(chips.enumerated()), id: \.offset) { index, chip in
                if index > 0 { statDot }
                statItem(icon: chip.icon, text: chip.text)
            }
            Spacer(minLength: 0)
        }
    }

    private struct StatChip {
        let icon: String
        let text: String
    }

    private func buildStatChips() -> [StatChip] {
        var chips: [StatChip] = []

        // Model: always shown, "Default" when the agent inherits the global one.
        let modelText = agent.defaultModel.map(formatModelName) ?? L("Default")
        chips.append(.init(icon: "cube", text: modelText))

        // Capabilities: hide when 0 in `.auto` mode (means "all available"
        // until the user explicitly picks a subset). The "· Auto" / "· Custom"
        // suffix surfaces the discovery mode at a glance so the user can tell
        // a customized agent from one that's running on defaults without
        // opening the detail view.
        let mode = agentManager.effectiveToolSelectionMode(for: agent.id)
        if let count = enabledToolCount, count > 0 || mode != .auto {
            let modeLabel = mode == .auto ? L("Auto") : L("Custom")
            chips.append(.init(icon: "wrench.and.screwdriver", text: "\(count) · \(modeLabel)"))
        }

        // Automation: schedules + watchers, shown when non-zero.
        if automationCount > 0 {
            chips.append(.init(icon: "clock.badge.checkmark", text: "\(automationCount)"))
        }

        // Updated: relative time so it stays meaningful at a glance.
        chips.append(
            .init(icon: "clock", text: agent.updatedAt.formatted(.relative(presentation: .named)))
        )

        return chips
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

    /// Subtle "open" affordance that fades in on hover. Pinned to the
    /// card's bottom-trailing corner so it never collides with the menu.
    private var hoverChevron: some View {
        Image(systemName: "arrow.up.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(agentColor)
            .frame(width: 22, height: 22)
            .background(Circle().fill(agentColor.opacity(0.12)))
            .padding(10)
            .opacity(isHovered ? 1 : 0)
            .scaleEffect(isHovered ? 1 : 0.85)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Detail Tab

private enum DetailTab: String, CaseIterable {
    case configure
    case capabilities
    case customization
    case network
    case sandbox
    case automation
    case memory

    var label: String {
        switch self {
        case .configure: return "Configure"
        case .capabilities: return "Capabilities"
        case .customization: return "Customization"
        case .network: return "Network"
        case .sandbox: return "Sandbox"
        case .automation: return "Automation"
        case .memory: return "Memory"
        }
    }

    var icon: String {
        switch self {
        case .configure: return "gear"
        case .capabilities: return "wrench.and.screwdriver"
        case .customization: return "paintpalette.fill"
        case .network: return "network"
        case .sandbox: return "shippingbox"
        case .automation: return "clock.badge.checkmark"
        case .memory: return "brain.head.profile"
        }
    }

    var helperText: String {
        switch self {
        case .configure: return "Identity, model, and behavior overrides."
        case .capabilities: return "Pick which tools and skills this agent can use."
        case .customization: return "Quick actions and visual theme."
        case .network: return "Bonjour discovery and relay tunnel."
        case .sandbox: return "Container-based code execution."
        case .automation: return "Schedules and file watchers for autonomous behavior."
        case .memory: return "Conversation history, pinned facts, and episode summaries."
        }
    }
}

private enum AgentTab: Hashable {
    case builtIn(DetailTab)
    case plugin(String)
}

// MARK: - Tab Bar Preference Keys

/// Reports the natural width of the tab strip's HStack content (i.e. the
/// width *before* any horizontal scroll clipping). Compared against the
/// viewport width to decide whether the strip overflows.
private struct TabBarContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reports the visible width of the tab strip's ScrollView container.
private struct TabBarViewportWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Agent Detail View

struct AgentDetailView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    private var scheduleManager = ScheduleManager.shared
    private var watcherManager = WatcherManager.shared
    @ObservedObject private var relayManager = RelayTunnelManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    let agent: Agent
    let onBack: () -> Void
    let onDelete: (Agent) -> Void
    let onSwitchAgent: (Agent) -> Void
    let showSuccess: (String) -> Void

    init(
        agent: Agent,
        onBack: @escaping () -> Void,
        onDelete: @escaping (Agent) -> Void,
        onSwitchAgent: @escaping (Agent) -> Void,
        showSuccess: @escaping (String) -> Void
    ) {
        self.agent = agent
        self.onBack = onBack
        self.onDelete = onDelete
        self.onSwitchAgent = onSwitchAgent
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
    /// Drives the title-bar agent picker popover. Tapping the avatar / name in the
    /// header bar reveals the list of other custom agents so the user can jump
    /// between them without bouncing back to the Agents grid every time.
    @State private var showingAgentSwitcher: Bool = false

    /// Drives the share-agent sheet (cross-device deeplink invite flow).
    @State private var showingShareSheet: Bool = false

    /// Local UI state: which tabs the user has dropped into the "Advanced" disclosure
    /// of the Configure tab. Persists only for the lifetime of this view (intentional —
    /// the disclosure defaults to collapsed each time the agent is opened so the
    /// primary settings always greet the user first).
    @State private var showAdvancedSettings: Bool = false

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
    @State private var pinnedFacts: [PinnedFact] = []
    @State private var episodes: [Episode] = []
    @State private var showAllSummaries = false
    @State private var isInitialLoadComplete = false
    /// Captured by `GeometryReader`s wrapped around the tab strip so the
    /// "scrollable" affordance (right-edge fade + chevron) only renders when
    /// the tab content actually overflows the viewport AND the user hasn't
    /// already scrolled to the trailing edge.
    @State private var tabBarContentWidth: CGFloat = 0
    @State private var tabBarViewportWidth: CGFloat = 0
    @State private var tabBarScrollOffset: CGFloat = 0
    private var tabsOverflowRight: Bool {
        // 1pt fudge so pixel-aligned end-of-scroll positions don't leave a
        // phantom indicator on screen.
        tabBarContentWidth > tabBarViewportWidth + tabBarScrollOffset + 1
    }
    private var tabsOverflowLeft: Bool {
        tabBarScrollOffset > 1
    }

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
                tabBar
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                Divider()
                    .foregroundColor(theme.primaryBorder)

                // Capabilities is the only tab whose body has its own scroll
                // (NSTableView inside `AgentCapabilityManagerView`). Rendering
                // it directly — without the outer ScrollView the other tabs
                // share — keeps the table flush and avoids nested scrolling.
                switch selectedTab {
                case .builtIn(.capabilities):
                    AgentCapabilityManagerView(agentId: agent.id, onDismiss: nil)
                        .environment(\.theme, themeManager.currentTheme)
                        .id(selectedTab)
                default:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            scrollableTabContent
                        }
                        .padding(24)
                        .id(selectedTab)
                    }
                    .animation(nil, value: selectedTab)
                }
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

    /// Compact identity bar: back, avatar + name + optional description, actions.
    /// Tapping the identity block opens the agent switcher popover; editing the
    /// name / description happens inside the Configure tab's Identity section.
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

            // Vertical hairline so the back button reads as distinct from the
            // identity block even when the agent name is long.
            Rectangle()
                .fill(theme.primaryBorder)
                .frame(width: 1, height: 16)
                .opacity(0.6)

            identityButton

            Spacer(minLength: 8)

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
                headerActionButton(
                    icon: "square.and.arrow.up",
                    tint: theme.accentColor,
                    help: "Share Agent",
                    action: { showingShareSheet = true }
                )
                headerActionButton(
                    icon: "trash",
                    tint: theme.errorColor,
                    help: "Delete",
                    action: { showDeleteConfirm = true }
                )
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(
            theme.secondaryBackground
                .overlay(
                    Rectangle()
                        .fill(theme.primaryBorder)
                        .frame(height: 1),
                    alignment: .bottom
                )
        )
        .sheet(isPresented: $showingShareSheet) {
            ShareAgentSheet(agent: currentAgent)
                .environment(\.theme, themeManager.currentTheme)
        }
    }

    /// 28x28 circular icon button used by the detail header for Share / Delete.
    /// Background is a 10–12% tint of the foreground color so destructive vs.
    /// accent intent reads at a glance without shouting.
    private func headerActionButton(
        icon: String,
        tint: Color,
        help: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.12)))
        }
        .buttonStyle(PlainButtonStyle())
        .help(Text(help, bundle: .module))
    }

    /// Compact tappable identity block (avatar + name + optional description) inside
    /// the header bar. Tap opens an agent switcher so the user can jump straight to
    /// another agent's detail view. Editing the name / description happens inside the
    /// Configure tab's "Identity" section, not here — the title bar is for navigation.
    private var identityButton: some View {
        Button {
            showingAgentSwitcher = true
        } label: {
            HStack(spacing: 10) {
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
                        .strokeBorder(agentColor.opacity(0.5), lineWidth: 1.5)
                    Text(name.isEmpty ? "?" : name.prefix(1).uppercased())
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(agentColor)
                }
                .frame(width: 28, height: 28)
                .animation(.spring(response: 0.3), value: name)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(name.isEmpty ? L("Untitled Agent") : name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                    }
                    if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: 260, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .help(Text("Switch agent", bundle: .module))
        .popover(isPresented: $showingAgentSwitcher, arrowEdge: .bottom) {
            agentSwitcherPopover
        }
    }

    /// Popover content listing every custom agent for quick navigation. Tapping a
    /// row swaps the detail view to that agent (the parent uses `.id(agent.id)` to
    /// force a clean state reload). Built-in / Default agent is excluded — it has
    /// its own settings surface elsewhere and isn't represented in the Agents grid.
    private var agentSwitcherPopover: some View {
        let switchableAgents = agentManager.agents
            .filter { !$0.isBuiltIn }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                Text("Switch Agent", bundle: .module)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
                    .tracking(0.5)
                Spacer()
                Text("\(switchableAgents.count)", bundle: .module)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(theme.inputBackground))
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider().opacity(0.5)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(switchableAgents, id: \.id) { other in
                        agentSwitcherRow(other)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 280)
        .background(theme.cardBackground)
    }

    private func agentSwitcherRow(_ other: Agent) -> some View {
        let isCurrent = other.id == agent.id
        let color = agentColorFor(other.name)
        return Button {
            showingAgentSwitcher = false
            if !isCurrent {
                onSwitchAgent(other)
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.2), color.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Circle().strokeBorder(color.opacity(0.5), lineWidth: 1.5)
                    Text(other.name.isEmpty ? "?" : other.name.prefix(1).uppercased())
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(color)
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(other.name.isEmpty ? L("Untitled Agent") : other.name)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    if !other.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(other.description)
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isCurrent ? theme.accentColor.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab Bar

    private func tabBadgeCount(for tab: AgentTab) -> Int? {
        switch tab {
        case .builtIn(let dt):
            switch dt {
            case .configure, .capabilities, .customization, .network, .sandbox:
                return nil
            case .automation:
                let count = linkedSchedules.count + linkedWatchers.count
                return count > 0 ? count : nil
            case .memory:
                let count = chatSessions.count
                return count > 0 ? count : nil
            }
        case .plugin:
            return nil
        }
    }

    /// Horizontally scrollable tab bar — built-in tabs stay leftmost, then one
    /// per plugin. Wrapping in `ScrollView(.horizontal)` keeps every tab
    /// reachable when many plugins are installed; the right-edge fade + chevron
    /// signal the strip is scrollable when content overflows.
    private var tabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(DetailTab.allCases, id: \.self) { tab in
                        tabButton(for: .builtIn(tab), label: tab.label, icon: tab.icon)
                            .id(AgentTab.builtIn(tab))
                    }
                    ForEach(agentPlugins, id: \.plugin.id) { loaded in
                        tabButton(
                            for: .plugin(loaded.plugin.id),
                            label: loaded.plugin.manifest.name ?? loaded.plugin.id,
                            icon: "puzzlepiece.extension"
                        )
                        .id(AgentTab.plugin(loaded.plugin.id))
                    }
                }
                .padding(.horizontal, 4)
                .background(
                    GeometryReader { inner in
                        Color.clear.preference(
                            key: TabBarContentWidthKey.self,
                            value: inner.size.width
                        )
                    }
                )
            }
            .background(
                GeometryReader { outer in
                    Color.clear.preference(
                        key: TabBarViewportWidthKey.self,
                        value: outer.size.width
                    )
                }
            )
            .onPreferenceChange(TabBarContentWidthKey.self) { tabBarContentWidth = $0 }
            .onPreferenceChange(TabBarViewportWidthKey.self) { tabBarViewportWidth = $0 }
            // `onScrollGeometryChange` is the canonical macOS 15+ way to
            // observe scroll offset; the older GeometryReader-in-named-
            // coordinate-space pattern is flaky on horizontal AppKit-backed
            // scroll views and was leaving the trailing indicator stuck on.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x
            } action: { _, newOffset in
                tabBarScrollOffset = max(0, newOffset)
            }
            // Edge fades on whichever side has off-screen content. `mask`
            // runs before any overlay, so the chevrons sit ON TOP of the
            // fades rather than being faded themselves.
            .mask(tabBarFadeMask)
            .overlay(alignment: .leading) {
                if tabsOverflowLeft { scrollMoreChevron(direction: .leading) }
            }
            .overlay(alignment: .trailing) {
                if tabsOverflowRight { scrollMoreChevron(direction: .trailing) }
            }
            .animation(.easeOut(duration: 0.2), value: tabsOverflowLeft)
            .animation(.easeOut(duration: 0.2), value: tabsOverflowRight)
            // Auto-scroll the active tab into view when it changes (tap or programmatic).
            .onChange(of: selectedTab) { _, newValue in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    /// Linear gradient used as the tab strip's mask. Fades whichever side
    /// has content scrolled off; both sides can fade at once if the user is
    /// in the middle of an overflowed strip.
    private var tabBarFadeMask: LinearGradient {
        let fadeStart: CGFloat = 0.06  // ~6% of the strip on the leading edge
        let fadeEnd: CGFloat = 0.94  // ~6% on the trailing edge
        var stops: [Gradient.Stop] = []
        stops.append(.init(color: tabsOverflowLeft ? .clear : .black, location: 0.0))
        if tabsOverflowLeft {
            stops.append(.init(color: .black, location: fadeStart))
        }
        if tabsOverflowRight {
            stops.append(.init(color: .black, location: fadeEnd))
        }
        stops.append(.init(color: tabsOverflowRight ? .clear : .black, location: 1.0))
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }

    /// Floating "more →"/"← more" affordance pinned to whichever edge has
    /// off-screen content. Sits above the fade mask so it stays fully opaque,
    /// and is `allowsHitTesting(false)` so it never swallows tab taps.
    private func scrollMoreChevron(direction: HorizontalEdge) -> some View {
        Image(systemName: direction == .leading ? "chevron.left" : "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(theme.accentColor)
            .frame(width: 20, height: 20)
            .background(
                Circle()
                    .fill(theme.primaryBackground)
                    .overlay(Circle().strokeBorder(theme.accentColor.opacity(0.25), lineWidth: 1))
            )
            .shadow(
                color: Color.black.opacity(0.08),
                radius: 4,
                x: direction == .leading ? 1 : -1,
                y: 1
            )
            .padding(direction == .leading ? .leading : .trailing, 2)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.7)))
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

    /// Configure tab content. The Capabilities, Customization, and Network
    /// tabs handle their own concerns now, so this tab leads with the three
    /// fields that DEFINE an agent and tucks the rarely-touched knobs behind
    /// the Advanced disclosure.
    ///
    ///   PRIMARY: Identity, System Prompt, Model.
    ///   ADVANCED: Generation overrides (Temperature, Max Tokens) and the
    ///   Disable Tools / Disable Memory toggles.
    @ViewBuilder
    private var configureTabContent: some View {
        tabHelperText(DetailTab.configure.helperText)
        identitySection
        systemPromptSection
        defaultModelSection
        advancedSettingsDisclosure
    }

    /// Routed by `selectedTab` from the body. Capabilities is rendered
    /// directly (it has its own scroll); every other tab body is enumerated
    /// here so the outer ScrollView can wrap it uniformly.
    @ViewBuilder
    private var scrollableTabContent: some View {
        switch selectedTab {
        case .builtIn(.configure):
            configureTabContent
        case .builtIn(.customization):
            customizationTabContent
        case .builtIn(.network):
            networkTabContent
        case .builtIn(.sandbox):
            sandboxTabContent
        case .builtIn(.automation):
            automationTabContent
        case .builtIn(.memory):
            memoryTabContent
        case .builtIn(.capabilities):
            // Routed at the body level outside the ScrollView; nothing to
            // render here. This branch keeps the switch exhaustive.
            EmptyView()
        case .plugin(let pid):
            pluginTabContent(for: pid)
        }
    }

    /// Editable identity card — name, description, and "Created" footer. Lives at
    /// the top of the Configure tab now that the title bar's avatar/dropdown is
    /// dedicated to switching between agents.
    private var identitySection: some View {
        AgentDetailSection(title: "Identity", icon: "person.crop.circle") {
            VStack(alignment: .leading, spacing: 10) {
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

                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                    Text(
                        "Created \(agent.createdAt.formatted(date: .abbreviated, time: .omitted))",
                        bundle: .module
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                }
                .padding(.top, 2)
            }
            .onChange(of: name) { debouncedSave() }
            .onChange(of: description) { debouncedSave() }
        }
    }

    private var advancedSettingsDisclosure: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showAdvancedSettings.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .rotationEffect(.degrees(showAdvancedSettings ? 90 : 0))

                    Image(systemName: "wrench.adjustable")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.secondaryText)

                    Text("Advanced Settings", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text(advancedSummary)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)

                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.cardBackground.opacity(0.6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.cardBorder.opacity(0.5), lineWidth: 1)
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvancedSettings {
                VStack(alignment: .leading, spacing: 16) {
                    generationOverridesSection
                    disableTogglesSection
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// Tiny one-line summary shown next to "Advanced Settings" so users can see at
    /// a glance whether anything in there is overridden. Quick Actions and Theme
    /// moved to the Customization tab and are no longer reachable from here.
    private var advancedSummary: String {
        var parts: [String] = []
        if !temperature.isEmpty || !maxTokens.isEmpty { parts.append("generation") }
        if disableTools { parts.append("tools off") }
        if disableMemory { parts.append("memory off") }
        return parts.isEmpty ? L("Defaults") : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var customizationTabContent: some View {
        tabHelperText(DetailTab.customization.helperText)
        quickActionsSection
        themeSection
    }

    @ViewBuilder
    private var networkTabContent: some View {
        tabHelperText(DetailTab.network.helperText)
        bonjourSection
        relaySection
    }

    @ViewBuilder
    private var sandboxTabContent: some View {
        tabHelperText(DetailTab.sandbox.helperText)
        sandboxSection
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
        pinnedFactsSection
        episodesSection
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

    /// Primary "what model does this agent use?" picker. Lives at the top of the
    /// Configure tab next to System Prompt and Capabilities — the three things users
    /// reach for most. Temperature / Max Tokens overrides moved into the Advanced
    /// disclosure below.
    private var defaultModelSection: some View {
        AgentDetailSection(title: "Model", icon: "cube.fill") {
            VStack(alignment: .leading, spacing: 10) {
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
        }
    }

    /// Power-user generation overrides. Tucked inside the Advanced disclosure so
    /// the Configure tab leads with model + capabilities + system prompt for the
    /// 90% case.
    private var generationOverridesSection: some View {
        AgentDetailSection(title: "Generation Overrides", icon: "slider.horizontal.3") {
            VStack(spacing: 12) {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: temperature) { debouncedSave() }
            .onChange(of: maxTokens) { debouncedSave() }
        }
    }

    // MARK: - Tool Selection

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
                    AgentSectionEmptyState(
                        icon: "shippingbox",
                        title: "Sandbox unavailable",
                        hint:
                            "Container-based execution requires macOS 26 or later. Native plugins continue to work normally on this device."
                    )
                } else if !sandboxRunning {
                    AgentSectionEmptyState(
                        icon: "shippingbox",
                        title: "Sandbox not running",
                        hint:
                            "Start the sandbox container from the Sandbox status bar to enable autonomous execution and plugin creation."
                    )
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
                    AgentSectionEmptyState(
                        icon: "clock.badge.questionmark",
                        title: "No schedules yet",
                        hint:
                            "Schedule this agent to run on a recurring cadence — perfect for daily briefings or automated check-ins.",
                        actionLabel: "Create Schedule",
                        action: { showCreateSchedule = true }
                    )
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
    }

    private var watchersSection: some View {
        AgentDetailSection(
            title: L("Watchers"),
            icon: "eye.fill",
            subtitle: linkedWatchers.isEmpty ? "None" : "\(linkedWatchers.count)"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if linkedWatchers.isEmpty {
                    AgentSectionEmptyState(
                        icon: "eye.slash",
                        title: "No watchers yet",
                        hint: "Watch a folder for new files — the agent runs automatically whenever something changes.",
                        actionLabel: "Create Watcher",
                        action: { showCreateWatcher = true }
                    )
                } else {
                    ForEach(linkedWatchers) { watcher in
                        watcherRow(watcher)
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
            subtitle: "\(chatSessions.count) chat\(chatSessions.count == 1 ? "" : "s")"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
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
                        AgentSectionEmptyState(
                            icon: "bubble.left.and.bubble.right.fill",
                            title: "No chats yet",
                            hint:
                                "Start a conversation to build this agent's memory — history, pinned facts, and episode summaries all flow from here.",
                            actionLabel: "New Chat",
                            action: { ChatWindowManager.shared.createWindow(agentId: agent.id) }
                        )
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

            }
        }
    }

    private var pinnedFactsSection: some View {
        AgentDetailSection(
            title: L("Pinned Facts"),
            icon: "pin.fill",
            subtitle: pinnedFacts.isEmpty ? "None" : "\(pinnedFacts.count)"
        ) {
            if pinnedFacts.isEmpty {
                AgentSectionEmptyState(
                    icon: "pin.slash",
                    title: "No pinned facts yet",
                    hint:
                        "Facts are promoted from session distillations once they accumulate enough salience. Keep chatting and they'll show up here."
                )
            } else {
                PinnedFactsPanel(
                    facts: pinnedFacts,
                    onDelete: { factId in
                        deletePinnedFact(factId)
                    }
                )
            }
        }
    }

    private var episodesSection: some View {
        AgentDetailSection(
            title: L("Episodes"),
            icon: "doc.text",
            subtitle: episodes.isEmpty ? "None" : "\(episodes.count)"
        ) {
            if episodes.isEmpty {
                AgentSectionEmptyState(
                    icon: "doc.text.magnifyingglass",
                    title: "No episodes yet",
                    hint:
                        "After each chat, the agent distills the conversation into a short summary. Episodes accumulate here so the agent can recall past sessions."
                )
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    let displayed = showAllSummaries ? episodes : Array(episodes.prefix(10))

                    ForEach(Array(displayed.enumerated()), id: \.element.id) { index, episode in
                        if index > 0 {
                            Divider().opacity(0.5)
                        }
                        EpisodeRow(episode: episode)
                    }

                    if episodes.count > 10 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showAllSummaries.toggle()
                            }
                        } label: {
                            Text(showAllSummaries ? "Show Less" : "View All \(episodes.count) Episodes")
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

    private func deletePinnedFact(_ factId: String) {
        try? MemoryDatabase.shared.deletePinnedFact(id: factId)
        loadMemoryData()
        showSuccess("Pinned fact deleted")
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
        pinnedFacts = (try? db.loadPinnedFacts(agentId: agent.id.uuidString, limit: 200)) ?? []
        episodes = (try? db.loadEpisodes(agentId: agent.id.uuidString, limit: 100)) ?? []
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
        // The capability picker writes `manualToolNames`, `manualSkillNames`, and
        // `toolSelectionMode` directly via `AgentManager.update*` calls (so they
        // save instantly without going through this debounced path). We therefore
        // pass through `current.*` values rather than this view's local mirrors,
        // which only get refreshed via `loadAgentData()`. Otherwise the debounced
        // save could lose a picker change made between load and save.
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
            autonomousExec: current.autonomousExec,
            pluginInstructions: effectivePluginInstructions,
            toolSelectionMode: current.toolSelectionMode,
            manualToolNames: current.manualToolNames,
            manualSkillNames: current.manualSkillNames,
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

// MARK: - Starter Templates

/// Lightweight presets for the create-agent sheet. Picking one prefills the
/// system prompt and (only when the user hasn't typed yet) a default name.
/// Description, generation overrides, and visual theme are intentionally NOT
/// part of the create flow — they're all editable post-creation in Configure.
private enum AgentStarterTemplate: String, CaseIterable, Identifiable {
    case blank
    case writer
    case researcher
    case coder
    case productivity

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blank: return "Blank"
        case .writer: return "Writer"
        case .researcher: return "Researcher"
        case .coder: return "Coder"
        case .productivity: return "Productivity"
        }
    }

    var icon: String {
        switch self {
        case .blank: return "doc"
        case .writer: return "pencil.line"
        case .researcher: return "magnifyingglass"
        case .coder: return "chevron.left.forwardslash.chevron.right"
        case .productivity: return "checkmark.circle"
        }
    }

    /// Default name suggestion — only applied when the form's name field is
    /// still empty, so a user who started typing isn't clobbered.
    var defaultName: String {
        switch self {
        case .blank: return ""
        case .writer: return "Writer"
        case .researcher: return "Researcher"
        case .coder: return "Coder"
        case .productivity: return "Productivity"
        }
    }

    var systemPrompt: String {
        switch self {
        case .blank:
            return ""
        case .writer:
            return """
                You are a thoughtful writing partner. Help the user draft, edit, and \
                polish prose. Match their voice, suggest sharper word choices, and \
                keep edits surgical unless they ask for a rewrite. When they share a \
                draft, lead with what's working before what to change.
                """
        case .researcher:
            return """
                You are a careful research assistant. Break questions down, surface \
                what's known versus what's contested, and cite sources where you can. \
                Distinguish facts from opinions, prefer primary sources, and never \
                invent citations. When uncertain, say so plainly.
                """
        case .coder:
            return """
                You are a pragmatic coding partner. Read the user's code carefully, \
                ask clarifying questions when intent is ambiguous, and prefer minimal \
                diffs that match the surrounding style. Explain trade-offs briefly. \
                When you write code, make sure it actually compiles and runs.
                """
        case .productivity:
            return """
                You are a focused productivity assistant. Help the user plan their \
                day, capture todos, and triage what's important from what's noisy. \
                Be concise, action-oriented, and respect their time — short answers \
                beat long ones unless they ask for more.
                """
        }
    }
}

// MARK: - Agent Editor Sheet (Smart Create)

private struct AgentEditorSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    let onSave: (Agent) -> Void
    let onCancel: () -> Void

    @State private var selectedTemplate: AgentStarterTemplate = .blank
    @State private var name: String = ""
    /// Flips to `true` the first time the user types into the name field.
    /// Until then, switching presets is allowed to overwrite the name with
    /// the new preset's default — so toggling between Writer/Coder/etc. keeps
    /// the suggested name in sync. Once the user types their own value, the
    /// name is theirs and presets stop touching it.
    @State private var nameUserEdited: Bool = false
    @State private var systemPrompt: String = ""
    @State private var selectedModel: String?
    @State private var pickerItems: [ModelPickerItem] = []
    @State private var showModelPicker: Bool = false
    @State private var hasAppeared: Bool = false

    /// When true, the form column is replaced in place by an embedded
    /// `AgentCapabilityManagerView` operating in draft mode. Toggling this
    /// is purely a within-sheet view swap — no agent is created, no parent
    /// navigation occurs.
    @State private var inlineCustomize: Bool = false

    /// Draft capability state. Seeded on first appear from the live registries
    /// (matching what `AgentManager.seedEnabledCapabilitiesIfNeeded` would have
    /// written on first picker open) and then mutated in place by the embedded
    /// picker. Baked into the saved Agent's `manualToolNames` /
    /// `manualSkillNames` so the seed step is a no-op for newly created agents.
    @State private var draftMode: ToolSelectionMode = .auto
    @State private var draftToolNames: Set<String> = []
    @State private var draftSkillNames: Set<String> = []
    @State private var draftSeeded: Bool = false

    @FocusState private var nameFocused: Bool

    private var agentColor: Color { agentColorFor(name) }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            ZStack {
                if inlineCustomize {
                    capabilitiesPane
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity)
                            )
                        )
                } else {
                    HStack(spacing: 0) {
                        formColumn
                            .frame(width: 440)
                        Divider()
                        previewColumn
                            .frame(maxWidth: .infinity)
                    }
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        )
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.primaryBackground)
            .clipped()

            footerView
        }
        .frame(width: 760, height: 580)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.primaryBorder.opacity(0.5), lineWidth: 1)
        )
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.97)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hasAppeared)
        .onAppear {
            withAnimation { hasAppeared = true }
            seedDraftIfNeeded()
            // Slight delay so the sheet is fully presented before focus lands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                nameFocused = true
            }
        }
        .onReceive(ModelPickerItemCache.shared.$items) { pickerItems = $0 }
    }

    /// Embedded picker pane shown when the user clicks "Customize…". Operates
    /// in draft mode so toggles update local @State only — nothing is
    /// persisted until the user clicks "Create Agent" in the footer.
    /// `compact: true` drops the picker's own title row + bottom rule so it
    /// reads as a continuation of the editor's header rather than a stacked
    /// secondary chrome.
    private var capabilitiesPane: some View {
        AgentCapabilityManagerView(
            draftMode: $draftMode,
            draftTools: $draftToolNames,
            draftSkills: $draftSkillNames,
            onDismiss: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                    inlineCustomize = false
                }
            },
            compact: true
        )
        .environment(\.theme, theme)
    }

    /// One-shot seed of the draft sets to the same defaults
    /// `seedEnabledCapabilitiesIfNeeded` would have written. Idempotent: only
    /// runs once per sheet open so re-renders don't clobber user edits.
    private func seedDraftIfNeeded() {
        guard !draftSeeded else { return }
        draftSeeded = true
        draftToolNames = Set(ToolRegistry.shared.listDynamicTools().map(\.name))
        draftSkillNames = Set(SkillManager.shared.skills.map(\.name))
    }

    // MARK: Form column

    private var formColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                templatesStrip
                nameField
                modelField
                capabilitiesField
                promptField
            }
            .padding(20)
        }
    }

    private var templatesStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentSheetSectionLabel("Start From")
            HStack(spacing: 6) {
                ForEach(AgentStarterTemplate.allCases) { template in
                    templateChip(template)
                }
            }
        }
    }

    private func templateChip(_ template: AgentStarterTemplate) -> some View {
        let isSelected = selectedTemplate == template
        return Button {
            applyTemplate(template)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: template.icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(LocalizedStringKey(template.label), bundle: .module)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
            }
            .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? theme.accentColor.opacity(0.12) : theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                isSelected ? theme.accentColor.opacity(0.35) : theme.inputBorder,
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentSheetSectionLabel("Name")
            StyledTextField(
                placeholder: "e.g., Code Assistant",
                text: $name,
                icon: "textformat"
            )
            .focused($nameFocused)
            // Distinguish "user typed something the preset wouldn't have"
            // from "preset just wrote its defaultName here". Only the former
            // locks the name. Equality covers the harmless case where the
            // user types the exact preset name themselves.
            .onChange(of: name) { _, newValue in
                if newValue != selectedTemplate.defaultName {
                    nameUserEdited = true
                }
            }
        }
    }

    private var modelField: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentSheetSectionLabel("Default Model")
            Button {
                showModelPicker.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "cube.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(selectedModel == nil ? theme.tertiaryText : theme.accentColor)
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
                            RoundedRectangle(cornerRadius: 10).stroke(theme.inputBorder, lineWidth: 1)
                        )
                )
            }
            .buttonStyle(PlainButtonStyle())
            .popover(isPresented: $showModelPicker, arrowEdge: .bottom) {
                ModelPickerView(
                    options: pickerItems,
                    selectedModel: $selectedModel,
                    agentId: nil,
                    onDismiss: { showModelPicker = false }
                )
            }
        }
    }

    /// Capabilities row in the create sheet. Mirrors the Auto-discover affordance
    /// from the picker but renders against the draft sets so the count line
    /// stays honest as the user toggles things in the embedded picker pane.
    /// "Customize…" performs an inline view swap (no save) — the embedded
    /// picker writes back to the same draft bindings, so closing it and
    /// reopening it preserves all selections.
    private var capabilitiesField: some View {
        let isAuto = draftMode == .auto
        return VStack(alignment: .leading, spacing: 6) {
            AgentSheetSectionLabel("Capabilities")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: isAuto ? "sparkles" : "list.bullet.rectangle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isAuto ? theme.accentColor : theme.secondaryText)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle().fill(
                                isAuto
                                    ? theme.accentColor.opacity(0.12)
                                    : theme.inputBackground
                            )
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-discover relevant capabilities", bundle: .module)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        Text(capabilitiesSubtitle)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Toggle(
                        "",
                        isOn: Binding(
                            get: { draftMode == .auto },
                            set: { draftMode = $0 ? .auto : .manual }
                        )
                    )
                    .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                    .labelsHidden()
                }

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                        inlineCustomize = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Customize…", bundle: .module)
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                    }
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accentColor.opacity(0.10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(
                                        theme.accentColor.opacity(0.25),
                                        lineWidth: 1
                                    )
                            )
                    )
                }
                .buttonStyle(.plain)
                .help(Text("Pick which tools and skills this agent can use", bundle: .module))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10).stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
        }
    }

    /// Honest one-liner for the Capabilities row: counts come from the draft
    /// sets, so editing inside the embedded picker is reflected as soon as
    /// the user returns to the form.
    private var capabilitiesSubtitle: String {
        let toolCount = draftToolNames.count
        let skillCount = draftSkillNames.count
        let modeBlurb =
            draftMode == .auto
            ? L("Pre-flight picks the most relevant per turn.")
            : L("All enabled items are sent every turn.")
        return "\(toolCount) tools and \(skillCount) skills enabled · \(modeBlurb)"
    }

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentSheetSectionLabel("System Prompt")
            ZStack(alignment: .topLeading) {
                if systemPrompt.isEmpty {
                    Text("Enter instructions for this agent…", bundle: .module)
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
                    .frame(minHeight: 120, maxHeight: 180)
                    .padding(12)
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10).stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
            Text(
                "Capabilities, generation overrides, and theme are editable after creation in the Configure tab.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
        }
    }

    // MARK: Preview column

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "eye")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                AgentSheetSectionLabel("Preview")
            }

            previewCard

            Text(
                "This is how your agent will look in the grid.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.secondaryBackground.opacity(0.4))
    }

    private var previewCard: some View {
        let displayName = name.isEmpty ? L("Untitled Agent") : name
        let modelText = selectedModel.map(formatModelName) ?? L("Default")
        return VStack(alignment: .leading, spacing: 12) {
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
                    Circle().strokeBorder(agentColor.opacity(0.4), lineWidth: 2)
                    Text(name.isEmpty ? "?" : name.prefix(1).uppercased())
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(agentColor)
                }
                .frame(width: 36, height: 36)
                .animation(.spring(response: 0.3), value: name)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    Text("No description", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if systemPrompt.isEmpty {
                Text("No system prompt", bundle: .module)
                    .font(.system(size: 12).italic())
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(systemPrompt)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Image(systemName: "cube")
                    .font(.system(size: 9, weight: .medium))
                Text(modelText)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .top)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(theme.cardBorder, lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.04), radius: 5, x: 0, y: 2)
    }

    // MARK: Header / Footer

    private var headerView: some View {
        AgentSheetHeader(
            icon: "person.crop.circle.badge.plus",
            title: "Create Agent",
            subtitle: "Pick a starter, name it, write a prompt",
            onClose: onCancel
        )
    }

    private var footerView: some View {
        AgentSheetFooter(
            primary: AgentSheetFooter.Action(
                label: "Create Agent",
                isEnabled: canSave,
                handler: { saveAgent() }
            ),
            secondary: AgentSheetFooter.Action(
                label: "Cancel",
                handler: onCancel
            ),
            hint: "+ Enter to create"
        )
    }

    // MARK: Actions

    /// Apply a starter template's prompt to the form. The name follows the
    /// preset until the user types their own value (tracked by
    /// `nameUserEdited`); after that, presets stop touching the name. Picking
    /// `.blank` resets the name back to empty, which is the right "blank
    /// slate" behavior when the user is just sampling presets.
    private func applyTemplate(_ template: AgentStarterTemplate) {
        selectedTemplate = template
        systemPrompt = template.systemPrompt
        if !nameUserEdited {
            name = template.defaultName
        }
    }

    @MainActor
    private func saveAgent() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        // Bake the (possibly user-edited) draft sets directly into the new
        // agent so `seedEnabledCapabilitiesIfNeeded` is a no-op on first
        // Capabilities-tab open. The auto-grow path keeps these sets fresh
        // when new plugins are installed later.
        let agent = Agent(
            id: UUID(),
            name: trimmedName,
            description: "",
            systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            themeId: nil,
            defaultModel: selectedModel,
            temperature: nil,
            maxTokens: nil,
            isBuiltIn: false,
            createdAt: Date(),
            updatedAt: Date(),
            toolSelectionMode: draftMode,
            manualToolNames: Array(draftToolNames),
            manualSkillNames: Array(draftSkillNames)
        )

        onSave(agent)
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

#Preview {
    AgentsView()
}
