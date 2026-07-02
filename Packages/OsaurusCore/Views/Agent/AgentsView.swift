import AppKit
import OsaurusRepository
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
    /// Shared animation for grid ↔ detail navigation. A quick cross-fade (no
    /// horizontal slide) so opening an agent reads like the rest of the app's
    /// tab/content swaps rather than a push. Centralized so it feels identical
    /// whether the user opens a local agent, a remote agent, or a duplicate.
    fileprivate static let navTransition = Animation.easeInOut(duration: 0.2)

    /// Two-column grid layout reused by the main agent grid and the
    /// "Paired Remote Agents" section in the empty state.
    fileprivate static let gridColumns: [GridItem] = [
        GridItem(.flexible(minimum: 300), spacing: 20),
        GridItem(.flexible(minimum: 300), spacing: 20),
    ]

    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var remoteAgentManager = RemoteAgentManager.shared
    @ObservedObject private var managementState = ManagementStateManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    /// One-shot deep-link target: when set on construction (e.g. from the chat
    /// header's gear button), the matching local agent is opened in detail
    /// view as soon as the tab appears. Consumed exactly once via
    /// `consumedDeeplinkAgentId` so subsequent navigation back to the grid
    /// doesn't re-fire the auto-select.
    let deeplinkAgentId: UUID?

    @State private var selectedAgent: Agent?
    @State private var selectedRemoteAgentId: UUID?
    @State private var isCreating = false
    @State private var isReordering = false
    @State private var hasAppeared = false
    @State private var successMessage: String?
    @State private var consumedDeeplinkAgentId: UUID?
    /// One-shot inner-tab target paired with an agent id, set by the
    /// `.agentDetailDeeplink` handler so the detail view opens on a specific
    /// tab (e.g. Subagents). Applied at `AgentDetailView` construction so it
    /// survives a cold window open; matched on id so it only affects the
    /// deep-linked agent, and cleared on back.
    @State private var deeplinkTab: (agentId: UUID, tab: DetailTab)?

    init(deeplinkAgentId: UUID? = nil) {
        self.deeplinkAgentId = deeplinkAgentId
    }

    private var customAgents: [Agent] {
        agentManager.agents.filter { !$0.isBuiltIn }
    }

    /// The agent to show in the detail view. The built-in Default ("Osaurus")
    /// agent has no configuration surface — its core settings live in
    /// Settings > Chat — so selecting it falls back to the grid (the all-agents
    /// list) instead of opening `AgentDetailView`. This is the single catch-all:
    /// every selection path routes through here, so no deep-link, switch, or
    /// future code can force the detail open for the Default agent.
    private var detailAgent: Agent? {
        selectedAgent.flatMap { $0.isBuiltIn ? nil : $0 }
    }

    private var remoteAgents: [RemoteAgent] {
        remoteAgentManager.remoteAgents
    }

    /// Token fingerprinting the visible cell set. Drives `gridDiffAnimation`
    /// so SwiftUI snapshot-diffs the grid when agents are added/removed.
    private var gridChangeToken: String {
        let local = customAgents.map { $0.id.uuidString }.joined(separator: ",")
        let remote = remoteAgents.map { $0.id.uuidString }.joined(separator: ",")
        return "\(local)|\(remote)"
    }

    var body: some View {
        ZStack {
            if detailAgent == nil && selectedRemoteAgentId == nil {
                gridContent
                    .transition(.opacity)
            }

            if let agent = detailAgent {
                // `.id(agent.id)` below makes SwiftUI tear down + recreate the
                // detail view when the user switches agents, so all editable
                // state reloads via onAppear without manual onChange wiring.
                AgentDetailView(
                    agent: agent,
                    initialTab: deeplinkTab?.agentId == agent.id ? deeplinkTab?.tab.rawValue : nil,
                    onBack: {
                        deeplinkTab = nil
                        withAnimation(Self.navTransition) { selectedAgent = nil }
                    },
                    onDelete: { p in
                        withAnimation(Self.navTransition) { selectedAgent = nil }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            deleteAgent(p)
                        }
                    },
                    onSwitchAgent: { newAgent in selectedAgent = newAgent },
                    onSwitchRemoteAgent: { remoteId in
                        withAnimation(Self.navTransition) {
                            selectedAgent = nil
                            selectedRemoteAgentId = remoteId
                        }
                    },
                    showSuccess: showSuccess
                )
                .id(agent.id)
                .transition(.opacity)
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
                    onChat: { remote in
                        ChatWindowManager.shared.openChat(
                            withRemoteAgentProviderId: remote.providerId
                        )
                    },
                    onSwitchAgent: { newAgent in
                        withAnimation(Self.navTransition) {
                            selectedRemoteAgentId = nil
                            selectedAgent = newAgent
                        }
                    },
                    onSwitchRemoteAgent: { newRemoteId in
                        selectedRemoteAgentId = newRemoteId
                    }
                )
                .id(remoteId)
                .transition(.opacity)
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
        .sheet(isPresented: $isReordering) {
            AgentReorderSheet()
                .environment(\.theme, themeManager.currentTheme)
        }
        .onAppear {
            agentManager.refresh()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
            consumeDeeplinkIfPossible()
            applyPendingRemoteAgentDetail()
        }
        .onChange(of: agentManager.agents) { _, _ in
            // Agent list may load asynchronously after the view appears.
            consumeDeeplinkIfPossible()
        }
        .onChange(of: remoteAgentManager.remoteAgents) { _, _ in
            // Paired remote agents can load after the view appears; retry the
            // pending deep-link once the target record is known.
            applyPendingRemoteAgentDetail()
        }
        .onReceive(managementState.$pendingRemoteAgentDetailId) { _ in
            applyPendingRemoteAgentDetail()
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDetailDeeplink)) { note in
            // Notification-tap deep-link router (spec §3.3). Resolves
            // the target agent and surfaces it; `AgentDetailView`
            // observes the same notification to flip its inner tab
            // selection so this view stays single-purpose.
            guard let info = note.userInfo,
                let agentId = info["agentId"] as? UUID,
                let target = agentManager.agents.first(where: { $0.id == agentId })
            else { return }
            // Carry an optional inner-tab target so the detail opens on the
            // requested tab. Applied at construction below (cold open) and by
            // `AgentDetailView`'s own deeplink handler (warm, already mounted).
            if let tabRaw = info["tab"] as? String,
                let tab = DetailTab(rawValue: tabRaw),
                DetailTab.allTabsForAgent(target).contains(tab)
            {
                deeplinkTab = (agentId, tab)
            }
            withAnimation(Self.navTransition) {
                selectedRemoteAgentId = nil
                selectedAgent = target
            }
        }
    }

    // MARK: - Grid Content

    private var gridContent: some View {
        VStack(spacing: 0) {
            headerView
                .managerHeaderEntrance(hasAppeared: hasAppeared)

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
                                .init(
                                    icon: "calendar",
                                    title: L("Daily Planner"),
                                    description: L("Manage your schedule")
                                ),
                                .init(
                                    icon: "message.fill",
                                    title: L("Message Assistant"),
                                    description: L("Draft and send texts")
                                ),
                                .init(icon: "map.fill", title: L("Local Guide"), description: L("Find places nearby")),
                            ],
                            primaryAction: .init(
                                title: L("Create Agent"),
                                icon: "plus",
                                handler: { isCreating = true }
                            ),
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
                            .gridDiffCell()
                        }

                        // Remote (paired) agents follow local ones with their own
                        // "Remote" treatment. Tap → RemoteAgentDetailView; the
                        // underlying chat plumbing lives in RemoteProviderManager
                        // (created at pair time) so the chat window already lists
                        // this agent in its picker.
                        ForEach(Array(remoteAgents.enumerated()), id: \.element.id) { index, remote in
                            remoteCardCell(remote: remote, indexInGrid: customAgents.count + index)
                                .gridDiffCell()
                        }
                    }
                    .padding(24)
                    .gridDiffAnimation(token: gridChangeToken)
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
                        .gridDiffCell()
                }
            }
            .gridDiffAnimation(token: gridChangeToken)
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
            onChat: {
                ChatWindowManager.shared.openChat(
                    withRemoteAgentProviderId: remote.providerId
                )
            },
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
            if !customAgents.isEmpty {
                HeaderIconButton("list.bullet.indent", help: "Reorder agents") {
                    isReordering = true
                }
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

    // MARK: - Deeplink

    /// Auto-selects a non-built-in agent when the tab was opened with a
    /// deeplink target (e.g. via the chat header's gear button). Runs at
    /// most once per construction.
    private func consumeDeeplinkIfPossible() {
        guard let target = deeplinkAgentId,
            consumedDeeplinkAgentId != target,
            let agent = agentManager.agents.first(where: { $0.id == target }),
            !agent.isBuiltIn
        else { return }
        consumedDeeplinkAgentId = target
        withAnimation(Self.navTransition) {
            selectedRemoteAgentId = nil
            selectedAgent = agent
        }
    }

    /// Open a paired remote agent's detail view in response to a deep-link
    /// (`ManagementStateManager.pendingRemoteAgentDetailId`, e.g. from the chat
    /// empty-state gear). Mirrors `PluginsView.applyPendingPluginDetailRequest`:
    /// waits until the matching `RemoteAgent` record is known (the list can load
    /// after this view appears), then navigates and clears the request.
    private func applyPendingRemoteAgentDetail() {
        guard let pendingId = managementState.pendingRemoteAgentDetailId else { return }
        guard remoteAgentManager.remoteAgent(for: pendingId) != nil else { return }
        managementState.pendingRemoteAgentDetailId = nil
        withAnimation(Self.navTransition) {
            selectedAgent = nil
            selectedRemoteAgentId = pendingId
        }
    }

    // MARK: - Actions

    private func deleteAgent(_ agent: Agent) {
        Task { @MainActor in
            let result = await agentManager.delete(id: agent.id)
            guard result.deleted else {
                ToastManager.shared.errorLocalized("Failed to delete agent", message: "Please try again.")
                return
            }
            showSuccess(L("Deleted \"\(agent.name)\""))
            // Surface sandbox cleanup as a non-modal toast rather than a
            // modal alert. The notice is set after a slow `await
            // unprovision(...)`, by which point the user may already have
            // opened another agent's delete confirmation — a modal here
            // would clobber that dialog (see ThemedAlertCenter single-slot
            // scope), so a toast keeps the in-progress flow intact.
            if let notice = result.sandboxCleanupNotice {
                switch notice.kind {
                case .completed:
                    ToastManager.shared.success(notice.title, message: notice.message)
                case .incomplete:
                    ToastManager.shared.warning(notice.title, message: notice.message)
                }
            }
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
            chatGreeting: agent.chatGreeting,
            chatSubtitle: agent.chatSubtitle,
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
        scheduleManager.scheduleCount(forAgentId: agent.id)
    }

    private var watcherCount: Int {
        watcherManager.watcherCount(forAgentId: agent.id)
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
                    AgentAvatarView(
                        mascotId: agent.avatar,
                        name: agent.name,
                        tint: agentColor,
                        diameter: 36,
                        customImageURL: agent.customAvatarURL
                    )

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
            L("Delete Agent"),
            isPresented: $showDeleteConfirm,
            message:
                L(
                    "Are you sure you want to delete \"\(agent.name)\"? This action cannot be undone. Any sandbox resources provisioned for this agent will also be removed."
                ),
            primaryButton: .destructive(L("Delete"), action: onDelete),
            secondaryButton: .cancel(L("Cancel"))
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
    /// Per-agent subagent helpers (Computer Use, spawn, image) and their
    /// inline config, bound to `AgentSettings`. Custom agents only — the built-in
    /// Default agent has no detail view, so it never configures subagents here.
    case subagents
    case customization
    case network
    /// Host-side "who can reach this agent" surface. Lists the access keys /
    /// invites granted to remote peers, their inbound usage, and a Revoke
    /// action. Visible for every agent; the content gates itself to agents
    /// that actually have a shareable identity (`agentAddress`).
    case connections
    case sandbox
    case automation
    case memory
    /// Agent DB feature (spec §5.5 / §7). Visible only when
    /// `Agent.settings.dbEnabled == true`; the tab strip filters
    /// these out via `Self.allTabsForAgent`. Order in the strip
    /// follows the canonical iteration order on `allCases`.
    case home
    case schema
    case data
    case views
    case activity

    /// DetailTabs that belong to the Agent DB feature. Hidden from
    /// the tab strip unless the agent has `settings.dbEnabled`.
    static let dbTabs: Set<DetailTab> = [.home, .schema, .data, .views, .activity]

    /// Tabs visible for `agent`, in canonical order. We render the
    /// schema/data/activity trio at the end so they sit visually
    /// adjacent to memory — both surface "what does this agent
    /// remember?" but along different axes.
    static func allTabsForAgent(_ agent: Agent) -> [DetailTab] {
        var hidden: Set<DetailTab> = []
        // Agent DB tabs only appear once the feature is on.
        if !agent.settings.dbEnabled { hidden.formUnion(dbTabs) }
        return DetailTab.allCases.filter { !hidden.contains($0) }
    }

    var label: String {
        switch self {
        case .configure: return L("Configure")
        case .capabilities: return L("Capabilities")
        case .subagents: return L("Subagents")
        case .customization: return L("Customization")
        case .network: return L("Network")
        case .connections: return L("Remote Connections")
        case .sandbox: return L("Sandbox")
        case .automation: return L("Automation")
        case .memory: return L("Memory")
        case .home: return L("Home")
        case .schema: return L("Schema")
        case .data: return L("Data")
        case .views: return L("Views")
        case .activity: return L("Activity")
        }
    }

    var icon: String {
        switch self {
        case .configure: return "gear"
        case .capabilities: return "wrench.and.screwdriver"
        case .subagents: return "person.2.wave.2"
        case .customization: return "paintpalette.fill"
        case .network: return "network"
        case .connections: return "person.2.badge.key"
        case .sandbox: return "shippingbox"
        case .automation: return "clock.badge.checkmark"
        case .memory: return "brain.head.profile"
        case .home: return "house"
        case .schema: return "tablecells"
        case .data: return "square.grid.3x1.below.line.grid.1x2"
        case .views: return "eye"
        case .activity: return "waveform.path.ecg"
        }
    }

    var helperText: String {
        switch self {
        case .configure: return L("Identity, model, and behavior overrides.")
        case .capabilities: return L("Pick which tools and skills this agent can use.")
        case .subagents:
            return L(
                "Let this agent delegate work — control your Mac, hand tasks to other agents, or generate images."
            )
        case .customization: return L("Avatar, empty state, and visual theme.")
        case .network: return L("Bonjour discovery and relay tunnel.")
        case .connections:
            return L("Peers granted access to this agent — usage and revocation.")
        case .sandbox: return L("Container-based code execution.")
        case .automation: return L("Schedules and file watchers for autonomous behavior.")
        case .memory: return L("Conversation history, pinned facts, and episode summaries.")
        case .home:
            return L("Dashboard of pinned views — the agent's own home screen.")
        case .schema:
            return L("Tables, columns, indexes the agent has created in its private database.")
        case .data:
            return L("Browse, inspect, and export the rows stored in the agent's database.")
        case .views:
            return L("Saved SQL views the agent reuses across runs.")
        case .activity:
            return L("Run history and the audit trail of every write the agent has done.")
        }
    }
}

private enum AgentTab: Hashable {
    case builtIn(DetailTab)
    case plugin(String)
    /// Tab for a plugin that the host tried to load but couldn't —
    /// either failed during dlopen/init/handshake, or quarantined on
    /// the previous launch. Surfaces the structured error from
    /// `PluginManager.loadError(for:)` and a Retry button so the user
    /// can act on the crash without dropping into a terminal.
    case failedPlugin(String)
}

// MARK: - Agent Detail View

struct AgentDetailView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    private let scheduleManager = ScheduleManager.shared
    private let watcherManager = WatcherManager.shared
    /// Reference held for the "Enable Relay" alert callback only.
    /// Tunnel-status observation lives in `AgentDetailRelaySection` /
    /// `AgentRelayBaseURLProvider` so this view doesn't re-render on
    /// every relay heartbeat.
    private let relayManager = RelayTunnelManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    let agent: Agent
    let onBack: () -> Void
    let onDelete: (Agent) -> Void
    let onSwitchAgent: (Agent) -> Void
    /// Switch the detail pane to a paired remote agent (selected from the
    /// shared agent switcher). The parent flips its `selectedRemoteAgentId`.
    let onSwitchRemoteAgent: (UUID) -> Void
    let showSuccess: (String) -> Void

    init(
        agent: Agent,
        // Raw value of a `DetailTab` (file-private), kept stringly-typed so this
        // internal init — constructed cross-file (e.g. `MemoryView`) — doesn't
        // expose a private type. Deep-links already carry the tab as a raw
        // string; unknown values fall back to `.configure`.
        initialTab: String? = nil,
        onBack: @escaping () -> Void,
        onDelete: @escaping (Agent) -> Void,
        onSwitchAgent: @escaping (Agent) -> Void,
        onSwitchRemoteAgent: @escaping (UUID) -> Void,
        showSuccess: @escaping (String) -> Void
    ) {
        self.agent = agent
        self.onBack = onBack
        self.onDelete = onDelete
        self.onSwitchAgent = onSwitchAgent
        self.onSwitchRemoteAgent = onSwitchRemoteAgent
        self.showSuccess = showSuccess
        // Seed the inner tab at construction so a deep-link (e.g. the What's New
        // "Open Subagent settings" CTA) lands on the right tab even on a cold
        // window open, where a post-mount notification would race the view.
        let resolvedInitialTab = initialTab.flatMap(DetailTab.init(rawValue:)) ?? .configure
        _selectedTab = State(initialValue: .builtIn(resolvedInitialTab))
    }

    // MARK: - Editable State

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var systemPrompt: String = ""
    @State private var temperature: String = ""
    @State private var maxTokens: String = ""
    @State private var selectedThemeId: UUID?
    @State private var chatQuickActions: [AgentQuickAction]?
    @State private var editingQuickActionId: UUID?
    @State private var pluginInstructionsMap: [String: String] = [:]
    /// Positive-polarity local mirrors of `Agent.toolsEnabled` /
    /// `Agent.memoryEnabled` (default true). The Features toggles bind
    /// directly; `saveAgent` folds them back into the persisted agent.
    @State private var toolsEnabled: Bool = true
    @State private var memoryEnabled: Bool = true
    /// Local mirror of `Agent.settings.dbEnabled` (spec §5.5). The
    /// Features section binds a toggle to this; `debouncedSave`
    /// folds it back into the persisted `AgentSettings` block.
    @State private var dbEnabled: Bool = false
    /// Local mirrors of the per-agent built-in tool gates
    /// (`render_chart` / `speak` / `search_memory`). The Features
    /// section binds individual toggles to these; `saveAgent` folds
    /// them back into the persisted `AgentSettings` block.
    @State private var renderChartEnabled: Bool = false
    @State private var speakEnabled: Bool = false
    @State private var searchMemoryEnabled: Bool = false
    @State private var selfSchedulingEnabled: Bool = false
    /// Per-agent subagent capability toggles, keyed by the capability
    /// registry's `PerAgentFlag` (computer_use, spawn, image). Hydrated in
    /// `loadAgent` by looping the registry and folded back into `AgentSettings`
    /// in `saveAgent`, so adding a per-agent kind needs no new `@State` here.
    /// Custom agents only; the Subagents tab renders one card per flag.
    @State private var subagentToggles: [SubagentCapability.PerAgentFlag: Bool] = [:]
    /// Convenience reads over `subagentToggles` so the save path and the
    /// inline config rows keep their existing call sites.
    private var computerUseEnabled: Bool { subagentToggles[.computerUse] ?? false }
    private var spawnDelegationEnabled: Bool { subagentToggles[.spawn] ?? false }
    private var imageEnabled: Bool { subagentToggles[.image] ?? false }
    private var appleScriptEnabled: Bool { subagentToggles[.appleScript] ?? false }
    /// Per-agent `spawn_agent` allow-list (which agents this agent may spawn).
    /// Mirrored from / into `AgentSettings.spawnableAgentNames`; empty hides the
    /// `spawn_agent` tool.
    @State private var spawnableAgentNames: [String] = []
    /// Per-agent `spawn_model` allow-list (raw model ids this agent may spawn).
    /// Mirrored from / into `AgentSettings.spawnableModelNames`; empty hides the
    /// `spawn_model` tool.
    @State private var spawnableModelNames: [String] = []
    /// Per-agent "when/how to use" notes keyed by spawnable model id. Mirrored
    /// from / into `AgentSettings.spawnableModelNotes`; pruned to the pool on save.
    @State private var spawnableModelNotes: [String: String] = [:]
    /// Drives the "Add agent" / "Add model" multi-select popovers in the spawn
    /// config panel (UI-only; the selections persist immediately on toggle).
    @State private var spawnAgentPickerPresented = false
    @State private var spawnModelPickerPresented = false
    @State private var spawnAgentSearch = ""
    @State private var spawnModelSearch = ""
    /// Whether the Spawn card's "Limits" budget steppers are expanded. Collapsed
    /// by default — the normalized defaults are sensible, so these are power-user
    /// knobs tucked behind a disclosure (a one-line summary shows when closed).
    @State private var spawnLimitsExpanded = false
    /// Per-agent autonomy ceiling for Computer Use (PR2). `nil` means no
    /// ceiling. Mirrored from / into `AgentSettings.computerUseCeiling`.
    @State private var computerUseCeiling: AutonomyCeiling? = nil
    /// Per-agent screen-context toggle, nested under Computer Use. Default on;
    /// the effective value is gated by Computer Use, so it only matters while
    /// Computer Use is enabled. Mirrored from / into
    /// `AgentSettings.screenContextEnabled`.
    @State private var screenContextEnabled: Bool = true
    /// Drives the "Preview screen context" popover under the toggle (UI-only).
    @State private var showScreenContextPreview = false
    /// Per-agent image model bundle ids (generation / edit). `nil` resolves to
    /// the first ready model at run time. Mirrored from / into
    /// `AgentSettings.imageGenerationModelId` / `imageEditModelId`.
    @State private var imageGenerationModelId: String? = nil
    @State private var imageEditModelId: String? = nil
    /// Per-agent AppleScript model bundle id (`nil` resolves to the first
    /// installed catalog model at run time) and execution mode (confirm each
    /// script vs auto-run with a warning). Mirrored from / into
    /// `AgentSettings.appleScriptModelId` / `appleScriptExecutionMode`.
    @State private var appleScriptModelId: String? = nil
    @State private var appleScriptExecutionMode: AppleScriptExecutionMode = .default
    /// Per-agent delegation permissions (spawn / image) + spawn budgets. Mirrored
    /// from / into `AgentSettings`.
    @State private var subagentPermissions: SubagentPermissionDefaults = SubagentPermissionDefaults()
    @State private var subagentBudgets: SubagentBudgets = SubagentBudgets()
    @State private var spawnToolAccess: SpawnToolAccess = .none
    /// Per-agent subagent model overrides keyed by capability id (computer_use /
    /// spawn). Empty/absent = inherit the kind's default model.
    /// Mirrored from / into `AgentSettings.subagentModelOverrides`.
    @State private var subagentModelOverrides: [String: String] = [:]
    /// Read-only snapshot of the global `SubagentConfiguration`, loaded in
    /// `loadAgentData`. Used only by `spawnHandoffDisabledWarning` to surface the
    /// Local Orchestrator Handoff state while configuring an agent's spawn pool;
    /// the handoff toggle itself lives in Settings → Subagents.
    @State private var globalSubagentConfig: SubagentConfiguration = .default
    /// Display mirror of `Agent.hostWorkspacePath`. Drives the Host Files row
    /// so the selected folder updates immediately after the user picks/clears
    /// it (the persisted bookmark on `Agent.hostWorkspaceBookmark` is the real
    /// grant). `nil` means no host folder is granted.
    @State private var hostWorkspacePath: String? = nil
    /// Per-agent on/off for the chat empty-state generative greeting.
    /// Default off, like the other capability flags; the agent opts in
    /// from the Features tab. Drives whether the Empty State section
    /// shows the AI personality editor or the manual greeting editor.
    /// Flows through `loadAgent` / `saveAgent` like the other
    /// `AgentSettings` fields.
    @State private var generativeGreetingsEnabled: Bool = false
    /// Per-agent override for the empty-state greeting voice. Empty-after-
    /// trim falls through to the global persona on
    /// `ChatConfiguration.greetingPersona`; both empty falls back to the
    /// built-in default in `GenerativeGreetingService`.
    @State private var greetingPersona: String = ""
    /// Manual override for `Agent.chatGreeting`. Empty-after-trim becomes
    /// `nil` on save so the chat empty state falls through to the
    /// time-of-day default. Only rendered when `generativeGreetingsEnabled`
    /// is OFF for this agent.
    @State private var chatGreetingDraft: String = ""
    /// Manual override for `Agent.chatSubtitle`. Same gating and
    /// trim-empty-to-nil semantics as `chatGreetingDraft`.
    @State private var chatSubtitleDraft: String = ""
    /// Bound to the `Delete Data` confirmation dialog. We require an
    /// explicit confirmation because deleting an agent's DB throws
    /// away its only copy (the encrypted `db.sqlite`) of the data it
    /// has accumulated — no Trash, no undo.
    @State private var showDeleteDBConfirmation: Bool = false

    // MARK: - Bundle export/import state (spec §11.1)

    /// Pending export destination — `nil` when no export is in flight.
    /// Bound to the passphrase sheet so the user types the seal
    /// passphrase after picking a destination.
    @State private var bundleExportDestination: URL? = nil
    /// Pending import source URL the user picked from `NSOpenPanel`,
    /// awaiting passphrase entry.
    @State private var bundleImportSource: URL? = nil
    /// Passphrase typed into the active sheet. Cleared on dismiss.
    @State private var bundlePassphraseInput: String = ""
    /// Confirmation passphrase typed during export, to catch typos
    /// before we burn through PBKDF2 600k iterations sealing a key
    /// the user has no hope of remembering.
    @State private var bundleConfirmPassphraseInput: String = ""
    /// Held after a successful unpack — drives the review-before-
    /// activate sheet (manifest contents + Activate / Discard).
    @State private var bundleImportPreview: AgentBundleService.ImportPreview? = nil
    /// `true` while the bundle service is running export/unpack
    /// asynchronously. Disables both bundle buttons to avoid
    /// double-clicks.
    @State private var isBundleBusy: Bool = false
    /// Most-recent error message from a bundle operation. Surfaced
    /// via `ThemedAlertDialog` (reusing the existing alert host).
    @State private var bundleErrorMessage: String? = nil
    @State private var bundleSuccessMessage: String? = nil
    @State private var autoSpeak: Bool = false
    @State private var ttsVoice: String = ""
    @State private var avatar: String? = nil
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
    /// Optional saved-view name to focus when the user lands on the
    /// Views tab via the notification deep-link (spec §3.3). Passed
    /// through to `ViewsTabView`, which uses it as an initial
    /// `selection`. Cleared back to `nil` once the user navigates
    /// elsewhere so re-entering the tab manually doesn't keep
    /// snapping back to the old view.
    @State private var pendingFocusedViewName: String? = nil
    /// Optional table name to pre-select when the user lands on the
    /// Data tab via the Schema-tab "Browse" deep-link. Same lifecycle
    /// as `pendingFocusedViewName`.
    @State private var pendingFocusedTableName: String? = nil
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
    @State private var sessionTurnCounts: [UUID: Int] = [:]
    @State private var showAllSummaries = false
    @State private var isInitialLoadComplete = false
    @State private var agentSecrets: [AgentSecretEntry] = []
    @State private var editingSecretEntryId: AgentSecretEntry.ID?

    /// Pending plugin id for the failed-plugin Retry / Uninstall
    /// confirmation alerts. Kept separate so the two destructive
    /// dialogs don't race each other. Both are gated through alerts
    /// so a user can't crash-loop the host by mashing Retry on a
    /// still-broken plugin.
    @State private var pendingFailedPluginRetry: String?
    @State private var pendingFailedPluginUninstall: String?
    /// Bumped on `.toolsListChanged` so plugin tabs re-evaluate after async
    /// `PluginManager.loadAll()` — `PluginManager` is not Observable, so without
    /// this the tab strip can stay empty if the user opened this view before
    /// plugins finished loading.
    @State private var loadedPluginsRefreshNonce: UInt = 0

    /// Per-agent slices of the cross-manager data this detail screen
    /// renders. Refreshed by `refreshDetailCaches()` so the body
    /// doesn't have to re-filter the source arrays on every publish.
    @State private var linkedSchedules: [Schedule] = []
    @State private var linkedWatchers: [Watcher] = []
    @State private var chatSessions: [ChatSessionData] = []
    @State private var agentPlugins: [PluginManager.LoadedPlugin] = []
    @State private var agentFailedPlugins: [PluginManager.FailedPlugin] = []

    private var currentAgent: Agent {
        agentManager.agent(for: agent.id) ?? agent
    }

    private var agentColor: Color { agentColorFor(name) }

    /// Recompute the per-agent caches consumed by the tab strip and
    /// sub-sections. Called from `.onAppear`, `.onChange(of: agent.id)`,
    /// `loadedPluginsRefreshNonce` flips, and the `.schedulesChanged` /
    /// `.watchersChanged` notifications.
    private func refreshDetailCaches() {
        linkedSchedules = scheduleManager.schedules.filter { $0.agentId == agent.id }
        linkedWatchers = watcherManager.watchers.filter { $0.agentId == agent.id }
        chatSessions = ChatSessionsManager.shared.sessions(for: agent.id)
        agentPlugins = PluginManager.shared.plugins.filter(pluginAppearsInAgentDetailTabs)
        agentFailedPlugins = PluginManager.shared.failedPlugins.values
            .filter(failedPluginAppearsInAgentDetailTabs)
            .sorted { $0.pluginId < $1.pluginId }
    }

    /// Whether this loaded plugin should get its own tab on this agent's detail
    /// screen. Keep in sync with `agentPlugins` / `.toolsListChanged` invalidation.
    private func pluginAppearsInAgentDetailTabs(_ loaded: PluginManager.LoadedPlugin) -> Bool {
        let manifest = loaded.plugin.manifest
        return manifestExposesAgentSurface(manifest, pluginId: loaded.plugin.id)
            || !loaded.routes.isEmpty
            || loaded.webConfig != nil
    }

    /// Same predicate, but applied to the cached `lastKnownManifest`
    /// of a failed plugin. Failed plugins don't have a `LoadedPlugin`
    /// (no routes/web config materialized), so we only check the
    /// manifest-derived signals; `nil` manifest counts as "show
    /// anyway" — a quarantined plugin the host couldn't decode is
    /// still actionable (Retry / report the crash).
    private func failedPluginAppearsInAgentDetailTabs(_ failed: PluginManager.FailedPlugin) -> Bool {
        guard let manifest = failed.lastKnownManifest else { return true }
        return manifestExposesAgentSurface(manifest, pluginId: failed.pluginId)
            || (manifest.capabilities.routes?.isEmpty == false)
            || (manifest.capabilities.web != nil)
    }

    /// Per-agent surface signals available from the manifest alone
    /// (no `LoadedPlugin` required). Shared by the loaded-plugin and
    /// failed-plugin filters so a failed plugin shows up under the
    /// SAME conditions a successful load would have shown it.
    private func manifestExposesAgentSurface(_ manifest: PluginManifest, pluginId: String) -> Bool {
        let hasConfig = manifest.capabilities.config != nil
        let hasInstructions =
            manifest.instructions != nil
            || currentAgent.pluginInstructions?[pluginId] != nil
        let hasSecrets = !(manifest.secrets ?? []).isEmpty
        return hasConfig || hasInstructions || hasSecrets
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .builtIn(.capabilities):
            AgentCapabilityManagerView(agentId: agent.id, onDismiss: nil)
                .environment(\.theme, themeManager.currentTheme)
                .id(selectedTab)
        case .builtIn(.home):
            HomeTabView(agentId: agent.id)
                .environment(\.theme, themeManager.currentTheme)
                .id(selectedTab)
        case .builtIn(.schema):
            SchemaTabView(agentId: agent.id)
                .environment(\.theme, themeManager.currentTheme)
                .id(selectedTab)
        case .builtIn(.data):
            DataTabView(
                agentId: agent.id,
                initialSelectedTable: pendingFocusedTableName
            )
            .environment(\.theme, themeManager.currentTheme)
            .id(selectedTab)
        case .builtIn(.views):
            ViewsTabView(
                agentId: agent.id,
                initialFocusedViewName: pendingFocusedViewName
            )
            .environment(\.theme, themeManager.currentTheme)
            .id(selectedTab)
        case .builtIn(.activity):
            ActivityTabView(agentId: agent.id)
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

    private var bodyCore: some View {
        VStack(spacing: 0) {
            detailHeaderBar

            // Next Run panel (spec §9.4) sits above the tab strip for any
            // user-created agent that has self-scheduling switched on. The
            // panel renders one of three banner shapes — paused, scheduled,
            // or idle — and is the only place Pause/Resume is reachable
            // at-a-glance. The mode picker itself moved into the Configure
            // tab; a read-only mode chip here links back to it. With
            // self-scheduling off the agent never manages a next-run slot,
            // so the whole panel is hidden.
            if agent.id != Agent.defaultId, selfSchedulingEnabled {
                NextRunPanelView(agentId: agent.id)
                    .environment(\.theme, theme)
            }

            VStack(alignment: .leading, spacing: 0) {
                tabBar
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                Divider()
                    .foregroundColor(theme.primaryBorder)

                // Capabilities + Schema/Data/Activity host their own scrolling
                // (NSTableView / NSOutlineView). Rendering them directly —
                // without the outer ScrollView the other tabs share — keeps
                // their tables flush and avoids nested scrolling.
                tabContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        // No internal fade-in here: the parent's navigation transition
        // (spring slide + opacity) already animates this view's entrance. A
        // second easeOut opacity curve on top read as an inconsistent
        // "slide-then-fade", unlike the rest of the app's detail navigations.
        .onAppear {
            loadAgentData()
            loadMemoryData()
            loadAgentSecrets()
            selectedModel = currentAgent.defaultModel
            refreshDetailCaches()
            DispatchQueue.main.async {
                isInitialLoadComplete = true
            }
        }
        .onChange(of: agent.id) { _, _ in
            refreshDetailCaches()
        }
        .onChange(of: loadedPluginsRefreshNonce) { _, _ in
            refreshDetailCaches()
        }
        .onReceive(NotificationCenter.default.publisher(for: .schedulesChanged)) { _ in
            refreshDetailCaches()
        }
        .onReceive(NotificationCenter.default.publisher(for: .watchersChanged)) { _ in
            refreshDetailCaches()
        }
        .onChange(of: dbEnabled) { _, newValue in
            // Watch the local `@State dbEnabled` (driven by the Configure
            // tab toggle), not `agent.settings.dbEnabled` — the prop is
            // frozen at view construction and would never fire. If the
            // user just turned the DB feature off while sitting on a
            // DB-only tab, snap back to Configure so they're not
            // stranded on a tab whose data has just been deleted.
            if !newValue,
                case .builtIn(let dt) = selectedTab,
                DetailTab.dbTabs.contains(dt)
            {
                selectedTab = .builtIn(.configure)
            }
        }
        .onChange(of: selfSchedulingEnabled) { _, newValue in
            // The master Self-scheduling switch owns the on/off state, so the
            // mode picker only offers the "how often" presets (Ambient /
            // Reactive / Project) — the legacy `.manual` ("off") card is gone.
            if newValue {
                // If the feature is switched on while the persisted mode is
                // still `.manual`, promote it to `.ambient` so a real preset
                // is selected and the agent runs within sensible bounds.
                if currentAgent.settings.schedule.mode == .manual {
                    selectScheduleMode(.ambient)
                }
            } else {
                // Switching the feature off cancels any pending next-run so a
                // self-scheduled wake-up doesn't fire after the user has
                // opted out. The Next Run banner (and its Cancel button) is
                // hidden in this state, so we clear the slot here rather than
                // leaving an orphaned run the user can no longer see.
                try? LocalAgentBridge.shared.cancelNextRun(agentId: agent.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDetailDeeplink)) { note in
            // Tab + entity deep-link handler. Used by:
            //   - `NotifyTool` taps (`tab: "views"`, `viewRef: ...`)
            //   - `SchemaTabView` "Browse" button (`tab: "data"`,
            //     `tableRef: ...`)
            // AgentsView selects the right agent via the same
            // notification; this handler just flips the inner tab
            // and stashes the entity name for the destination tab to
            // pick up on first load.
            guard let info = note.userInfo,
                let targetId = info["agentId"] as? UUID,
                targetId == agent.id
            else { return }
            if let tabRaw = info["tab"] as? String,
                let tab = DetailTab(rawValue: tabRaw),
                DetailTab.allTabsForAgent(currentAgent).contains(tab)
            {
                pendingFocusedViewName = info["viewRef"] as? String
                pendingFocusedTableName = info["tableRef"] as? String
                selectedTab = .builtIn(tab)
            }
        }
        .onChange(of: selectedTab) { _, newValue in
            // Drop any leftover notification-driven focus when the
            // user navigates to a tab the focus doesn't apply to.
            // The focused-name state is set together with
            // `selectedTab` in the deeplink handler above so it
            // survives this transition exactly once.
            switch newValue {
            case .builtIn(.views):
                pendingFocusedTableName = nil
            case .builtIn(.data):
                pendingFocusedViewName = nil
            default:
                pendingFocusedViewName = nil
                pendingFocusedTableName = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolsListChanged)) { _ in
            loadedPluginsRefreshNonce &+= 1
            switch selectedTab {
            case .plugin(let pid):
                let stillVisible = PluginManager.shared.plugins.contains {
                    $0.plugin.id == pid && pluginAppearsInAgentDetailTabs($0)
                }
                if !stillVisible {
                    // After a Retry succeeds, a previously failed plugin
                    // promotes from `failedPlugins` to `plugins`. We
                    // intentionally let that flow drop the user back to
                    // Configure here too, so they SEE the success
                    // message and aren't sitting on a stale view.
                    selectedTab = .builtIn(.configure)
                }
            case .failedPlugin(let pid):
                // The plugin loaded successfully on Retry → switch to
                // its real tab so the user lands on the happy path.
                if let loaded = PluginManager.shared.plugins.first(where: { $0.plugin.id == pid }),
                    pluginAppearsInAgentDetailTabs(loaded)
                {
                    selectedTab = .plugin(pid)
                } else if PluginManager.shared.failedPlugins[pid] == nil {
                    // Plugin no longer present in either bucket
                    // (uninstalled while the failed tab was open).
                    selectedTab = .builtIn(.configure)
                }
            case .builtIn:
                break
            }
        }
        .onReceive(ModelPickerItemCache.shared.$items) { options in
            pickerItems = options
        }
    }

    private var bodyWithSheets: some View {
        bodyCore
            .sheet(
                isPresented: Binding(
                    get: { bundleExportDestination != nil },
                    set: { if !$0 { bundleExportDestination = nil } }
                )
            ) {
                bundleExportPassphraseSheet
            }
            .sheet(
                isPresented: Binding(
                    get: { bundleImportSource != nil },
                    set: { if !$0 { bundleImportSource = nil } }
                )
            ) {
                bundleImportPassphraseSheet
            }
            .sheet(
                isPresented: Binding(
                    get: { bundleImportPreview != nil },
                    set: { if !$0 { discardBundlePreview() } }
                )
            ) {
                bundleImportReviewSheet
            }
    }

    private var bodyWithAlerts: some View {
        bodyWithSheets
            .themedAlert(
                L("Bundle operation failed"),
                isPresented: Binding(
                    get: { bundleErrorMessage != nil },
                    set: { if !$0 { bundleErrorMessage = nil } }
                ),
                message: bundleErrorMessage ?? "",
                primaryButton: .primary("OK") { bundleErrorMessage = nil }
            )
            .themedAlert(
                L("Bundle ready"),
                isPresented: Binding(
                    get: { bundleSuccessMessage != nil },
                    set: { if !$0 { bundleSuccessMessage = nil } }
                ),
                message: bundleSuccessMessage ?? "",
                primaryButton: .primary("OK") { bundleSuccessMessage = nil }
            )
            .themedAlert(
                L("Delete Agent"),
                isPresented: $showDeleteConfirm,
                message:
                    L(
                        "Are you sure you want to delete \"\(currentAgent.name)\"? This action cannot be undone. Any sandbox resources provisioned for this agent will also be removed."
                    ),
                primaryButton: .destructive(L("Delete")) { onDelete(currentAgent) },
                secondaryButton: .cancel(L("Cancel"))
            )
            .themedAlert(
                L("Expose Agent to Internet?"),
                isPresented: $showRelayConfirmation,
                message:
                    L(
                        "This will create a public URL for this agent via agent.osaurus.ai. Anyone with the URL can send requests to your local server. Your access keys still protect the API endpoints."
                    ),
                primaryButton: .destructive(L("Enable Relay")) {
                    relayManager.setTunnelEnabled(true, for: agent.id)
                },
                secondaryButton: .cancel(L("Cancel"))
            )
            .themedAlert(
                L("Retry plugin load?"),
                isPresented: Binding(
                    get: { pendingFailedPluginRetry != nil },
                    set: { if !$0 { pendingFailedPluginRetry = nil } }
                ),
                message:
                    L(
                        "The host quarantined this plugin after it caused a crash during load. Retrying re-runs the same dylib against the same host build, so if the underlying bug (most often a misaligned `osr_host_api` mirror in the plugin) is unfixed it will crash again. Use this only after you have rebuilt or re-installed the plugin."
                    ),
                primaryButton: .destructive(L("Retry Anyway")) {
                    if let pid = pendingFailedPluginRetry {
                        confirmRetryFailedPlugin(pid)
                    }
                    pendingFailedPluginRetry = nil
                },
                secondaryButton: .cancel(L("Cancel"))
            )
            .themedAlert(
                L("Uninstall plugin?"),
                isPresented: Binding(
                    get: { pendingFailedPluginUninstall != nil },
                    set: { if !$0 { pendingFailedPluginUninstall = nil } }
                ),
                message:
                    L(
                        "This permanently deletes the plugin's installed dylib, manifest, and per-agent secrets from disk. The host will stop attempting to load it on every launch — the only way to escape a crash-looping plugin without editing files by hand. You can reinstall it later from the Tools manager."
                    ),
                primaryButton: .destructive(L("Uninstall")) {
                    if let pid = pendingFailedPluginUninstall {
                        confirmUninstallFailedPlugin(pid)
                    }
                    pendingFailedPluginUninstall = nil
                },
                secondaryButton: .cancel(L("Cancel"))
            )
    }

    var body: some View {
        bodyWithAlerts
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
        AgentDetailHeaderBar(
            onBack: onBack,
            identity: { identityButton },
            status: {
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
            },
            actions: {
                HStack(spacing: 6) {
                    AgentDetailHeaderActionButton(
                        icon: "square.and.arrow.up",
                        tint: theme.accentColor,
                        help: "Share Agent",
                        action: { showingShareSheet = true }
                    )
                    AgentDetailHeaderActionButton(
                        icon: "trash",
                        tint: theme.errorColor,
                        help: "Delete",
                        action: { showDeleteConfirm = true }
                    )
                }
            }
        )
        .sheet(isPresented: $showingShareSheet) {
            ShareAgentSheet(agent: currentAgent)
                .environment(\.theme, themeManager.currentTheme)
        }
    }

    /// Compact tappable identity block (avatar + name + optional description) inside
    /// the header bar. Tap opens an agent switcher so the user can jump straight to
    /// another agent's detail view. Editing the name / description happens inside the
    /// Configure tab's "Identity" section, not here — the title bar is for navigation.
    private var identityButton: some View {
        Button {
            showingAgentSwitcher = true
        } label: {
            AgentDetailIdentityLabel(
                mascotId: avatar,
                name: name,
                tint: agentColor,
                subtitle: description,
                showsChevron: true
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .localizedHelp("Switch agent")
        .popover(isPresented: $showingAgentSwitcher, arrowEdge: .bottom) {
            agentSwitcherPopover
        }
    }

    /// Quick-navigation popover listing every custom local agent AND every
    /// paired remote agent. Tapping a local row swaps the detail view to that
    /// agent (the parent uses `.id(agent.id)` to force a clean reload); tapping
    /// a remote row hands off to `onSwitchRemoteAgent`. Built-in / Default agent
    /// is excluded — it has its own settings surface and isn't in the grid.
    private var agentSwitcherPopover: some View {
        AgentSwitcherPopover(
            localAgents: agentManager.agents.filter { !$0.isBuiltIn },
            remoteAgents: RemoteAgentManager.shared.remoteAgents,
            currentLocalAgentId: agent.id,
            currentRemoteAgentId: nil,
            onSelectLocal: { other in
                showingAgentSwitcher = false
                onSwitchAgent(other)
            },
            onSelectRemote: { remote in
                showingAgentSwitcher = false
                onSwitchRemoteAgent(remote.id)
            },
            onDismiss: { showingAgentSwitcher = false }
        )
        .environment(\.theme, themeManager.currentTheme)
    }

    // MARK: - Tab Bar

    private func tabBadgeCount(for tab: AgentTab) -> Int? {
        switch tab {
        case .builtIn(let dt):
            switch dt {
            case .configure, .capabilities, .subagents, .customization, .network, .connections,
                .sandbox, .home, .schema, .data, .views, .activity:
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
        case .failedPlugin:
            // Suppress the badge so the warning icon (set in the strip)
            // is the only visual signal for the failed state — adding
            // a count on top would compete for attention.
            return nil
        }
    }

    /// Horizontally scrollable tab bar — built-in tabs stay leftmost, then one
    /// per plugin, then any failed-plugin warning tabs. The shared
    /// `AgentDetailTabStrip` owns the scroll / overflow-fade / chevron chrome,
    /// so this view only maps the agent's tab sources into items.
    private var tabBar: some View {
        AgentDetailTabStrip(items: tabItems, selection: $selectedTab)
    }

    /// Built-in + plugin + failed-plugin tabs as `AgentDetailTabStrip` items.
    /// IMPORTANT: read from `currentAgent`, not the captured `agent` prop — the
    /// prop is frozen at view construction, while `currentAgent` re-fetches from
    /// `AgentManager` so flipping `Enable Database` in Configure causes the DB
    /// tabs (Home/Schema/Data/Views/Activity) to appear here.
    private var tabItems: [AgentDetailTabItem<AgentTab>] {
        var items: [AgentDetailTabItem<AgentTab>] = []
        for tab in DetailTab.allTabsForAgent(currentAgent) {
            items.append(
                AgentDetailTabItem(
                    id: .builtIn(tab),
                    label: tab.label,
                    icon: tab.icon,
                    badgeCount: tabBadgeCount(for: .builtIn(tab))
                )
            )
        }
        for loaded in agentPlugins {
            items.append(
                AgentDetailTabItem(
                    id: .plugin(loaded.plugin.id),
                    label: loaded.plugin.manifest.name ?? loaded.plugin.id,
                    icon: "puzzlepiece.extension",
                    badgeCount: tabBadgeCount(for: .plugin(loaded.plugin.id))
                )
            )
        }
        // Failed plugins surface AFTER successfully loaded ones so the warning
        // tabs cluster on the trailing edge of the strip — visually obvious
        // without crowding the happy-path tabs. Each shows a structured error +
        // Retry button via `failedPluginTabContent`.
        for failed in agentFailedPlugins {
            items.append(
                AgentDetailTabItem(
                    id: .failedPlugin(failed.pluginId),
                    label: failedPluginTabLabel(for: failed),
                    icon: "exclamationmark.triangle.fill",
                    isWarning: true
                )
            )
        }
        return items
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
        voiceSection
        systemPromptSection
        defaultModelSection
        // The schedule-mode picker is configuration for the self-scheduling
        // feature, so it only appears once that capability is switched on
        // (the master toggle lives in the Features section below). With it
        // off the agent has no scheduler tools, so the bounds picker would
        // be dead UI.
        if agent.id != Agent.defaultId, selfSchedulingEnabled {
            scheduleSection
        }
        // Feature toggles are always visible (not tucked behind the Advanced
        // disclosure) so the per-agent capability surface — model access,
        // output, memory, autonomy, data, and code execution — is
        // discoverable at a glance. The Advanced Settings disclosure sits at
        // the very bottom.
        featuresSection
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
        case .builtIn(.subagents):
            subagentsTabContent
        case .builtIn(.customization):
            customizationTabContent
        case .builtIn(.network):
            networkTabContent
        case .builtIn(.connections):
            connectionsTabContent
        case .builtIn(.sandbox):
            sandboxTabContent
        case .builtIn(.automation):
            automationTabContent
        case .builtIn(.memory):
            memoryTabContent
        case .builtIn(.home),
            .builtIn(.schema),
            .builtIn(.data),
            .builtIn(.views),
            .builtIn(.activity):
            // Routed at the body level outside the ScrollView (the
            // DB tabs host their own scrolling); the
            // ScrollView-wrapping path would force a fixed sizing.
            EmptyView()
        case .builtIn(.capabilities):
            // Routed at the body level outside the ScrollView; nothing to
            // render here. This branch keeps the switch exhaustive.
            EmptyView()
        case .plugin(let pid):
            pluginTabContent(for: pid)
        case .failedPlugin(let pid):
            failedPluginTabContent(for: pid)
        }
    }

    /// Editable identity card — name, description, and "Created" footer. Lives at
    /// the top of the Configure tab now that the title bar's avatar/dropdown is
    /// dedicated to switching between agents.
    private var identitySection: some View {
        AgentDetailSection(title: L("editor.section.identity"), icon: "person.crop.circle") {
            VStack(alignment: .leading, spacing: 10) {
                StyledTextField(
                    placeholder: L("e.g., Code Assistant"),
                    text: $name,
                    icon: "textformat"
                )

                StyledTextField(
                    placeholder: L("Brief description (optional)"),
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
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// Tiny one-line summary shown next to "Advanced Settings" so users can see at
    /// a glance whether anything in there is overridden. The feature toggles now
    /// live in the always-visible Features section, so only generation overrides
    /// remain behind this disclosure.
    private var advancedSummary: String {
        var parts: [String] = []
        if !temperature.isEmpty || !maxTokens.isEmpty { parts.append("generation") }
        return parts.isEmpty ? L("Defaults") : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var customizationTabContent: some View {
        tabHelperText(DetailTab.customization.helperText)
        avatarSection
        emptyStateSection
        themeSection
    }

    /// Customization → Empty State. The Generative Greetings toggle in
    /// the Features tab decides which editor shows here:
    /// - **on** → free-text Personality drives the generated greeting + actions.
    /// - **off** → user-authored Greeting / Message / Action Bar.
    /// We render only the active side so the surface stays calm.
    private var emptyStateSection: some View {
        AgentDetailSection(title: L("Empty State"), icon: "sparkles") {
            VStack(alignment: .leading, spacing: 14) {
                if generativeGreetingsEnabled {
                    aiEmptyStateBody
                } else {
                    manualEmptyStateBody
                    Text(
                        "Turn on Generative Greetings in the Features tab to use an AI-written greeting instead.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                }
            }
            .onChange(of: chatGreetingDraft) { debouncedSave() }
            .onChange(of: chatSubtitleDraft) { debouncedSave() }
        }
    }

    /// AI side: just the Personality editor with one short helper line.
    /// We drop the noisy "Generates a fresh greeting + four quick
    /// actions on your Core Model. Falls back to the static defaults
    /// silently on any failure." paragraph — that's runtime trivia,
    /// not configuration the user needs to think about. The label row
    /// also hosts a "Reset to Default" button that flips the editor
    /// back to whatever the agent currently inherits.
    private var aiEmptyStateBody: some View {
        let isAtDefault =
            greetingPersona.trimmingCharacters(in: .whitespacesAndNewlines)
            == resolvedPersonaDefault.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Personality", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Spacer()
                if !isAtDefault {
                    Button {
                        greetingPersona = resolvedPersonaDefault
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Reset to Default", bundle: .module)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            personalityEditor

            Text(
                "Inherits from the global personality in Settings → Chat. Edit to give this agent its own voice.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
        }
    }

    /// Resolved default for the per-agent Personality field. The editor
    /// inherits from the global persona on `ChatConfiguration.greetingPersona`
    /// when the agent has no explicit override; if the global is also
    /// empty we fall back to the built-in default. Same precedence the
    /// runtime uses in `GenerativeGreetingService.resolvedPersona(...)`.
    private var resolvedPersonaDefault: String {
        let global = AppConfiguration.shared.chatConfig.greetingPersona
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return global.isEmpty
            ? GenerativeGreetingService.defaultPersonaInstruction
            : global
    }

    /// Manual side: Greeting / Message / Action Bar. The Action Bar's
    /// own group header (icon + label + Default/Custom badge + enable
    /// toggle, rendered by `quickActionsModeGroup`) is the only header
    /// — we no longer wrap it in an outer "Action Bar" Text since
    /// there's just one quick-actions block now that work mode is gone.
    private var manualEmptyStateBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Greeting", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                StyledTextField(
                    placeholder: L("Welcome back, friend"),
                    text: $chatGreetingDraft,
                    icon: "text.cursor"
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Message", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                StyledTextField(
                    placeholder: L("How can I help today?"),
                    text: $chatSubtitleDraft,
                    icon: "text.cursor"
                )
            }

            actionBarBlock
        }
    }

    /// Personality `TextEditor` with matching panel chrome. The editor
    /// is hydrated by `loadAgentData` with `resolvedPersonaDefault` when
    /// the agent has no explicit override, so the empty-placeholder
    /// branch we used to need is gone — the user always sees real text
    /// they can edit, copy, or wipe to type their own. Persists on
    /// change so the segmented picker doesn't need to push it onto the
    /// manual side's onChange handlers.
    private var personalityEditor: some View {
        TextEditor(text: $greetingPersona)
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(theme.primaryText)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 80, maxHeight: 200)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
            .onChange(of: greetingPersona) { debouncedSave() }
    }

    private var avatarSection: some View {
        AgentDetailSection(title: L("Avatar"), icon: "person.crop.circle") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    if currentAgent.customAvatarURL != nil {
                        customAvatarPreview
                    }
                    customAvatarUploadButton
                    avatarOption(mascotId: nil)
                    ForEach(AgentMascot.allCases) { mascot in
                        avatarOption(mascotId: mascot.id)
                    }
                    Spacer(minLength: 0)
                }

                Text("Upload a custom image, pick a mascot, or fall back to the agent's first letter.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }

    /// Square tile rendering the live custom avatar; tap clears it.
    private var customAvatarPreview: some View {
        Button {
            agentManager.clearCustomAvatar(for: agent.id)
            if let url = currentAgent.customAvatarURL {
                AvatarImageCache.shared.invalidate(url: url)
            }
        } label: {
            AgentAvatarView(
                mascotId: nil,
                name: name,
                tint: agentColor,
                diameter: 40,
                customImageURL: currentAgent.customAvatarURL,
                monogramFontSize: 16,
                borderWidth: 1.5
            )
            .overlay(
                Circle()
                    .strokeBorder(theme.accentColor, lineWidth: 2)
                    .padding(-3)
            )
            .overlay(alignment: .topTrailing) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .background(Circle().fill(theme.primaryBackground))
                    .offset(x: 4, y: -4)
            }
        }
        .buttonStyle(.plain)
        .localizedHelp("Remove custom avatar")
    }

    /// "Upload…" tile: opens an NSOpenPanel and writes the selected image
    /// (downscaled to 256×256 PNG) as this agent's custom avatar.
    private var customAvatarUploadButton: some View {
        Button(action: presentCustomAvatarPicker) {
            ZStack {
                Circle()
                    .fill(theme.secondaryBackground.opacity(theme.isDark ? 0.4 : 0.5))
                Circle()
                    .strokeBorder(theme.inputBorder, style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
            }
            .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .localizedHelp("Upload custom image")
    }

    @MainActor
    private func presentCustomAvatarPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .image]
        panel.prompt = L("Choose")
        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }

            guard let original = NSImage(contentsOf: url) else { return }
            let downscaled = downscaleAvatar(original, maxDimension: 256)
            guard let pngData = pngData(from: downscaled) else { return }
            agentManager.setCustomAvatar(pngData, ext: "png", for: agent.id)
            // Bust the cache for this agent's avatar URL so the new bytes show
            // up immediately in inline chat + sidebar without an mtime race.
            if let updated = agentManager.agent(for: agent.id), let newURL = updated.customAvatarURL {
                AvatarImageCache.shared.invalidate(url: newURL)
            }
        }
    }

    /// Downscale `image` so its longer edge is at most `maxDimension` while
    /// preserving aspect ratio. Source images are typically much larger; this
    /// keeps disk + memory bounded and decode-time cheap on each redraw.
    private func downscaleAvatar(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        let srcSize = image.size
        guard srcSize.width > 0, srcSize.height > 0 else { return image }
        let scale = min(1.0, maxDimension / max(srcSize.width, srcSize.height))
        guard scale < 1.0 else { return image }
        let target = NSSize(width: floor(srcSize.width * scale), height: floor(srcSize.height * scale))
        let result = NSImage(size: target)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: srcSize),
            operation: .copy,
            fraction: 1.0
        )
        result.unlockFocus()
        return result
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func avatarOption(mascotId: String?) -> some View {
        let isSelected = avatar == mascotId
        return Button {
            avatar = mascotId
            saveAgent()
        } label: {
            AgentAvatarView(
                mascotId: mascotId,
                name: name,
                tint: agentColor,
                diameter: 40,
                monogramFontSize: 16,
                borderWidth: 1.5
            )
            .overlay(
                Circle()
                    .strokeBorder(
                        isSelected ? theme.accentColor : Color.clear,
                        lineWidth: 2
                    )
                    .padding(-3)
            )
        }
        .buttonStyle(.plain)
        .help(Text(mascotId.map { "Mascot: \($0)" } ?? "Initial", bundle: .module))
    }

    @ViewBuilder
    private var networkTabContent: some View {
        tabHelperText(DetailTab.network.helperText)
        bonjourSection
        relaySection
    }

    @ViewBuilder
    private var connectionsTabContent: some View {
        tabHelperText(DetailTab.connections.helperText)
        AgentConnectionsSection(agent: currentAgent)
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
        AgentDetailSection(title: L("System Prompt"), icon: "brain") {
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
        AgentDetailSection(title: L("Model"), icon: "cube.fill") {
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

    // MARK: - Scheduling

    /// Schedule-mode picker. Only shown when self-scheduling is enabled
    /// (the master toggle gates this section), so it offers just the
    /// "how often" presets — the legacy `.manual` ("off") card is omitted
    /// because the toggle now owns the on/off state. Picking a mode
    /// rewrites the agent's `schedule` preset via
    /// `AgentScheduleSettings.defaults(for:)`. The read-only chip in the
    /// Next Run banner deep-links here.
    private var scheduleSection: some View {
        AgentDetailSection(title: L("Scheduling"), icon: "calendar.badge.clock") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "How often this agent is allowed to run itself in the background. The agent picks its own next time within these bounds.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 8) {
                    ForEach(Self.selectableScheduleModes, id: \.self) { mode in
                        scheduleModeCard(mode: mode)
                    }
                }
            }
        }
    }

    /// Schedule presets surfaced in the picker. Excludes `.manual` — the
    /// Self-scheduling master toggle owns the on/off state now, so a
    /// "Self-scheduling off" card inside an enabled section would be
    /// contradictory.
    private static let selectableScheduleModes: [AgentScheduleMode] =
        AgentScheduleMode.allCases.filter { $0 != .manual }

    /// One radio-card in the schedule-mode list. Filled circle when
    /// selected; the body lays out title + tagline + concrete preset
    /// numbers so the user sees exactly what changing the mode does.
    @ViewBuilder
    private func scheduleModeCard(mode: AgentScheduleMode) -> some View {
        let isSelected = (currentAgent.settings.schedule.mode == mode)
        Button {
            selectScheduleMode(mode)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? theme.accentColor : theme.tertiaryText)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(Self.scheduleModeTitle(mode))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        Text(Self.scheduleModeTagline(mode))
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                    }
                    Text(Self.scheduleModePresetSummary(mode))
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? theme.accentColor.opacity(0.08) : theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isSelected ? theme.accentColor.opacity(0.6) : theme.inputBorder,
                                lineWidth: 1
                            )
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // TODO(mode-merge): the spec (§9.4 / §13) allows per-field overrides
    // — horizon, interval, quiet hours — to coexist with the mode preset.
    // Once those override controls land, change the setter below to MERGE
    // `AgentScheduleSettings.defaults(for:)` with the user's preserved
    // overrides instead of overwriting the whole struct. Today the radio
    // cards are the only authoring surface so the destructive overwrite
    // is intentional; a no-op review-then-replace once finer-grained
    // controls ship.
    private func selectScheduleMode(_ newMode: AgentScheduleMode) {
        guard var current = agentManager.agent(for: agent.id) else { return }
        guard current.settings.schedule.mode != newMode else { return }
        // Mutate only the schedule preset so every other opt-in
        // (DB, generative greetings, persona, the built-in tool gates)
        // is preserved across a mode change.
        current.settings.schedule = AgentScheduleSettings.defaults(for: newMode)
        current.updatedAt = Date()
        agentManager.update(current)
        showSaveIndicator()
    }

    private static func scheduleModeTitle(_ mode: AgentScheduleMode) -> String {
        switch mode {
        case .ambient: return "Ambient"
        case .reactive: return "Reactive"
        case .project: return "Project"
        case .manual: return "Manual"
        }
    }

    private static func scheduleModeTagline(_ mode: AgentScheduleMode) -> String {
        switch mode {
        case .ambient: return "Background helper"
        case .reactive: return "Quick reflexes"
        case .project: return "Deep work"
        case .manual: return "Self-scheduling off"
        }
    }

    /// Plain-English summary of the values written by
    /// `AgentScheduleSettings.defaults(for:)` so the user knows what
    /// changing modes actually does. Keep in sync with the presets in
    /// `Agent.swift`.
    private static func scheduleModePresetSummary(_ mode: AgentScheduleMode) -> String {
        switch mode {
        case .ambient:
            return "Up to 6 runs/day · at most once an hour · quiet 10pm–7am."
        case .reactive:
            return "Up to 48 runs/day · as often as every 5 min · no quiet hours."
        case .project:
            return "Up to 4 runs/day · at most once an hour · quiet 10pm–7am."
        case .manual:
            return "The agent only runs when you ask. Scheduled API calls from the agent are rejected."
        }
    }

    /// Power-user generation overrides. Tucked inside the Advanced disclosure so
    /// the Configure tab leads with model + capabilities + system prompt for the
    /// 90% case.
    private var generationOverridesSection: some View {
        AgentDetailSection(title: L("Generation Overrides"), icon: "slider.horizontal.3") {
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

    // MARK: - Voice

    /// Auto-speak toggle + per-agent voice override. Content lives in
    /// `AgentDetailVoiceSection` so `TTSService.shared` observation
    /// stays local to that subview.
    private var voiceSection: some View {
        AgentDetailVoiceSection(
            theme: theme,
            autoSpeak: $autoSpeak,
            ttsVoice: $ttsVoice,
            onSave: debouncedSave
        )
    }

    // MARK: - Features

    private var featuresSection: some View {
        let isCustomAgent = agent.id != Agent.defaultId
        return AgentDetailSection(
            title: L("Features"),
            icon: "switch.2",
            subtitle: L("Control what this agent can do. Extra capabilities are off by default to keep it lean.")
        ) {
            VStack(alignment: .leading, spacing: 18) {
                featureGroup(
                    "Model Access",
                    description: "What the model can draw on by default."
                ) {
                    featureToggleRow(
                        title: "Tools",
                        subtitle:
                            "Let the agent use tools to take actions and look things up. Turn off for a chat-only agent.",
                        isOn: $toolsEnabled
                    )
                    // The default agent has no per-agent memory flag: its
                    // memory is governed globally (Settings > Enable memory),
                    // so a per-agent toggle here would be a dead control.
                    if isCustomAgent {
                        featureToggleRow(
                            title: "Memory",
                            subtitle: "Pull relevant memories into prompts and save new ones as you chat.",
                            isOn: $memoryEnabled
                        )
                    } else {
                        Text(
                            "Memory for the default agent is controlled globally in Settings > Enable memory.",
                            bundle: .module
                        )
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                    }
                }

                // Always shown (default + custom agents): the empty-state
                // greeting flavor. The on/off lives here; the matching
                // editor (AI personality vs. custom greeting) is in
                // Customization > Empty State.
                featureGroup(
                    "Empty State",
                    description: "How the chat looks before your first message."
                ) {
                    featureToggleRow(
                        title: "Generative Greetings",
                        subtitle:
                            "Generate a fresh AI greeting and quick actions on your Core Model each time you open an empty chat. Off uses your custom greeting. The first generation can feel slow on small models like Foundation.",
                        isOn: $generativeGreetingsEnabled
                    )
                }

                // Custom-agent-only groups. The default agent is locked to
                // its fixed baseline (DB hard-off, no sandbox), so these
                // would be dead UI for it.
                if isCustomAgent {
                    featureGroup(
                        "Output",
                        description: "Extra ways the agent can present results."
                    ) {
                        featureToggleRow(
                            title: "Charts",
                            subtitle: "Render data as inline chart cards.",
                            isOn: $renderChartEnabled
                        )
                        featureToggleRow(
                            title: "Speak Tool",
                            subtitle:
                                "Give the agent a tool it can call to read a reply aloud when you ask. For always-speak, use Auto Speak Responses in the Voice section.",
                            isOn: $speakEnabled
                        )
                    }

                    featureGroup(
                        "Memory & Recall",
                        description: "Active lookups into the agent's memory."
                    ) {
                        featureToggleRow(
                            title: "Memory Recall",
                            subtitle:
                                "Let the agent search its own memory mid-conversation to pull up past details on demand. Separate from Memory above, which only auto-injects and saves.",
                            isOn: $searchMemoryEnabled
                        )
                    }

                    featureGroup(
                        "Autonomy",
                        description: "Let the agent act between your messages."
                    ) {
                        featureToggleRow(
                            title: "Self-scheduling",
                            subtitle:
                                "Let the agent schedule its own follow-up runs and send you notifications.",
                            isOn: $selfSchedulingEnabled
                        )
                        if selfSchedulingEnabled {
                            Text(
                                "Run frequency and limits are configured in the Scheduling section below.",
                                bundle: .module
                            )
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                        }
                    }

                    featureGroup(
                        "Data",
                        description: "Durable storage for this agent."
                    ) {
                        databaseFeatureRow
                    }

                    featureGroup(
                        "Code Execution",
                        description: "Run code and commands in an isolated sandbox."
                    ) {
                        sandboxExecSubsection
                    }

                    featureGroup(
                        "Host Files",
                        description: "Let the agent read and write files inside a folder you choose."
                    ) {
                        hostWorkspaceFolderRow
                    }

                    Text(
                        "Voice output lives in the Voice section; the greeting text and personality are in Customization > Empty State.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                }
            }
        }
    }

    /// Row for the Agent DB feature (spec §5.5). Houses the on/off
    /// toggle plus a Delete Data action that wipes the per-agent
    /// `db.sqlite` (encrypted) and the scheduler-side rows belonging
    /// to this agent. The Delete action only renders when the agent
    /// has the feature on, since there's nothing to delete otherwise.
    @ViewBuilder
    private var databaseFeatureRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            featureToggleRow(
                title: "Database",
                subtitle:
                    "Give this agent a private encrypted database to remember structured data across runs.",
                isOn: $dbEnabled
            )
            if dbEnabled, isUsingRemoteProvider {
                // Spec §5.5.5 / line 340: when the agent's effective
                // model is a remote (cloud) provider, surface the
                // schema-leak disclaimer right under the toggle so the
                // user knows exactly what crosses the wire.
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                    Text(
                        "Schema (table names and column types) is sent with each request. Row data is not.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
            }
            if dbEnabled {
                HStack(spacing: 8) {
                    Button {
                        beginBundleExport()
                    } label: {
                        Label(localized: "Export Bundle…", systemImage: "square.and.arrow.up")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBundleBusy)
                    Button {
                        beginBundleImport()
                    } label: {
                        Label(localized: "Import Bundle…", systemImage: "square.and.arrow.down")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBundleBusy)
                    Spacer()
                    Button(role: .destructive) {
                        showDeleteDBConfirmation = true
                    } label: {
                        Label(localized: "Delete Data", systemImage: "trash")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                }
            }
        }
        .confirmationDialog(
            "Delete this agent's database?",
            isPresented: $showDeleteDBConfirmation,
            titleVisibility: .visible
        ) {
            Button(localized: "Delete Data", role: .destructive) {
                deleteAgentDatabaseData()
            }
            Button(localized: "Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently erases the encrypted SQLite database, all "
                    + "schema artifacts, all scheduled / pause state, and the run "
                    + "history for this agent. The agent itself stays. This can't "
                    + "be undone."
            )
        }
    }

    /// Whether the agent's effective model resolves to a connected
    /// remote provider. Used by the privacy disclaimer under the
    /// Database toggle (spec §5.5.5) so the warning only shows when
    /// the schema actually crosses the wire. Local models stay
    /// silent.
    private var isUsingRemoteProvider: Bool {
        guard let model = AgentManager.shared.effectiveModel(for: agent.id) else {
            return false
        }
        return RemoteProviderManager.shared.findService(forModel: model) != nil
    }

    // MARK: - Bundle export/import (spec §11.1)

    @ViewBuilder
    private var bundleExportPassphraseSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Seal Bundle", bundle: .module)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text(
                "Choose a passphrase (≥ 8 characters) to encrypt this agent's bundle. You'll need the same passphrase to import it on another Mac.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
            SecureField("Passphrase", text: $bundlePassphraseInput)
                .textFieldStyle(.roundedBorder)
            SecureField("Confirm passphrase", text: $bundleConfirmPassphraseInput)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(localized: "Cancel") {
                    bundleExportDestination = nil
                    bundlePassphraseInput = ""
                    bundleConfirmPassphraseInput = ""
                }
                .controlSize(.small)
                Button(localized: "Export") {
                    performBundleExport()
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    bundlePassphraseInput.count < 8
                        || bundlePassphraseInput != bundleConfirmPassphraseInput
                )
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    @ViewBuilder
    private var bundleImportPassphraseSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open Bundle", bundle: .module)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)
            if let url = bundleImportSource {
                Text(url.lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
            }
            Text("Enter the passphrase used when the bundle was exported.", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Passphrase", text: $bundlePassphraseInput)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(localized: "Cancel") {
                    bundleImportSource = nil
                    bundlePassphraseInput = ""
                }
                .controlSize(.small)
                Button(localized: "Unlock") {
                    performBundleImport()
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(bundlePassphraseInput.count < 8)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    @ViewBuilder
    private var bundleImportReviewSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review Bundle", bundle: .module)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)
            if let preview = bundleImportPreview {
                bundleManifestSummary(preview.manifest)
            }
            Text(
                "Activate copies the agent into ~/.osaurus/agents/<id>/, rekeys its database to your local key, and registers the agent for use. Discard wipes the unpacked scratch directory and changes nothing on disk.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(localized: "Discard", role: .destructive) {
                    discardBundlePreview()
                }
                .controlSize(.small)
                Button(localized: "Activate") {
                    activateBundlePreview()
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    @ViewBuilder
    private func bundleManifestSummary(_ manifest: AgentBundleManifest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(localized: "Agent:").font(.system(size: 11, weight: .semibold))
                Text(manifest.agentName).font(.system(size: 11))
            }
            if !manifest.agentDescription.isEmpty {
                Text(manifest.agentDescription)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Text(localized: "Tables: \(manifest.schemaTables)").font(.system(size: 11))
                Text(localized: "Views: \(manifest.savedViews)").font(.system(size: 11))
                Spacer()
            }
            .foregroundColor(theme.secondaryText)
            Text(localized: "Exported on \(manifest.exportedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground)
        )
    }

    private func beginBundleExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.nameFieldStringValue = currentAgent.displayName
        panel.canCreateDirectories = true
        panel.title = L("Export Bundle")
        panel.message = String(
            localized: "Pick a folder for the .osaurus-agent bundle.",
            bundle: .module
        )
        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            bundleExportDestination = url.deletingLastPathComponent()
            bundlePassphraseInput = ""
            bundleConfirmPassphraseInput = ""
        }
    }

    private func beginBundleImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = []
        panel.title = L("Import Bundle")
        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            bundleImportSource = url
            bundlePassphraseInput = ""
        }
    }

    private func performBundleExport() {
        guard let destination = bundleExportDestination else { return }
        let passphrase = bundlePassphraseInput
        bundleExportDestination = nil
        bundlePassphraseInput = ""
        bundleConfirmPassphraseInput = ""
        isBundleBusy = true
        let agentId = currentAgent.id
        Task {
            do {
                let result = try await AgentBundleService.shared.exportBundle(
                    agentId: agentId,
                    passphrase: passphrase,
                    destinationDirectory: destination
                )
                await MainActor.run {
                    isBundleBusy = false
                    bundleSuccessMessage = "Bundle saved to \(result.bundleURL.lastPathComponent)."
                }
            } catch {
                await MainActor.run {
                    isBundleBusy = false
                    bundleErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func performBundleImport() {
        guard let source = bundleImportSource else { return }
        let passphrase = bundlePassphraseInput
        bundleImportSource = nil
        bundlePassphraseInput = ""
        isBundleBusy = true
        Task {
            do {
                let preview = try await AgentBundleService.shared.openBundleForReview(
                    url: source,
                    passphrase: passphrase
                )
                await MainActor.run {
                    isBundleBusy = false
                    bundleImportPreview = preview
                }
            } catch {
                await MainActor.run {
                    isBundleBusy = false
                    bundleErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func activateBundlePreview() {
        guard let preview = bundleImportPreview else { return }
        bundleImportPreview = nil
        isBundleBusy = true
        Task {
            do {
                let imported = try await AgentBundleService.shared.activate(preview: preview)
                await MainActor.run {
                    isBundleBusy = false
                    agentManager.refresh()
                    bundleSuccessMessage = "Imported \(imported.displayName)."
                }
            } catch {
                await MainActor.run {
                    isBundleBusy = false
                    bundleErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func discardBundlePreview() {
        guard let preview = bundleImportPreview else { return }
        bundleImportPreview = nil
        AgentBundleService.shared.discard(preview: preview)
    }

    /// Wipe per-agent persisted DB + scheduler state for this agent.
    /// Lives here (rather than on `AgentManager`) because the feature
    /// surface is otherwise self-contained: the agent itself is
    /// kept and the toggle stays on, so the next write will simply
    /// re-create the DB lazily.
    private func deleteAgentDatabaseData() {
        let agentId = agent.id
        // The agent itself stays, so we close + drop the disk files
        // and forget any cached per-agent serial queue. The next DB
        // write reopens lazily and the agent rebuilds its own
        // tables from scratch — exactly the cold-start path.
        do {
            try AgentDatabaseStore.shared.deleteOnDisk(for: agentId)
        } catch {
            print("[Configure] Failed to delete agent DB for \(agentId): \(error)")
        }
        do {
            try SchedulerDatabase.shared.deleteAllForAgent(agentId)
        } catch {
            print(
                "[Configure] Failed to delete scheduler rows for \(agentId): \(error)"
            )
        }
        LocalAgentBridge.shared.forget(agentId: agentId)
    }

    /// Editor presentation for one per-agent subagent capability toggle. The
    /// SET + order of toggles is registry-driven (`perAgentToggleFlags`); only
    /// the copy lives here in the view layer.
    private struct PerAgentFeature {
        let flag: SubagentCapability.PerAgentFlag
        let title: LocalizedStringKey
        let subtitle: LocalizedStringKey
    }

    /// The per-agent capability cards to render in the Subagents tab, derived
    /// from the registry's distinct per-agent flags so a new per-agent kind
    /// surfaces here automatically (the exhaustive switch forces its copy to be
    /// supplied). The inline config under each toggle is rendered by
    /// `subagentInlineConfig(for:)`.
    private var perAgentFeatures: [PerAgentFeature] {
        SubagentCapabilityRegistry.perAgentToggleFlags.map { flag in
            switch flag {
            case .computerUse:
                return PerAgentFeature(
                    flag: .computerUse,
                    title: "Computer Use",
                    subtitle:
                        "Let the agent control macOS apps for you — clicking, typing, and reading the screen. Reads and navigation run automatically; edits and anything consequential pause for your approval."
                )
            case .spawn:
                return PerAgentFeature(
                    flag: .spawn,
                    title: "Spawn",
                    subtitle:
                        "Let this agent hand a bounded task to another agent or model you allow below — the subagent runs it and returns just the result."
                )
            case .image:
                return PerAgentFeature(
                    flag: .image,
                    title: "Image",
                    subtitle:
                        "Let the agent generate and edit images with a local model using the `image` tool."
                )
            case .appleScript:
                return PerAgentFeature(
                    flag: .appleScript,
                    title: "AppleScript",
                    subtitle:
                        "Let the agent automate this Mac by writing and running AppleScript with an on-device model. Each script is shown for your approval or auto-run with a warning, per the mode below."
                )
            }
        }
    }

    /// Two-way binding into `subagentToggles` for a per-agent flag, so the
    /// shared `featureToggleRow` can drive the registry-keyed edit-state.
    /// The setter persists via `debouncedSave()` (guarded by
    /// `isInitialLoadComplete`) so flipping a capability on/off is written to
    /// `AgentSettings` — matching every other control in this tab. Without it
    /// the toggle only mutated in-memory `@State` and reverted on reload (the
    /// capability never actually enabled).
    private func subagentToggleBinding(_ flag: SubagentCapability.PerAgentFlag) -> Binding<Bool> {
        Binding(
            get: { subagentToggles[flag] ?? false },
            set: {
                subagentToggles[flag] = $0
                debouncedSave()
            }
        )
    }

    // MARK: - Subagents tab

    /// The Subagents tab: one card per per-agent capability (Computer Use,
    /// spawn, image), each with its full config (model / targets / permission /
    /// budgets) revealed inline when the toggle is on. Every card binds to this
    /// agent's `AgentSettings` (custom agents only — the built-in Default agent
    /// has no detail view).
    @ViewBuilder
    private var subagentsTabContent: some View {
        tabHelperText(DetailTab.subagents.helperText)
        AgentDetailSection(
            title: L("Subagents"),
            icon: "person.2.wave.2",
            subtitle: L(
                "Each helper is off by default. Turn one on to set it up."
            )
        ) {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(perAgentFeatures, id: \.flag) { feature in
                    let isOn = subagentToggleBinding(feature.flag)
                    VStack(alignment: .leading, spacing: 6) {
                        subagentCapabilityCard(
                            title: feature.title,
                            subtitle: feature.subtitle,
                            isOn: isOn
                        )
                        if isOn.wrappedValue {
                            subagentConfigPanel {
                                // The standard model-override row is rendered from
                                // the registry flag (`supportsModelOverride`), so a
                                // new chat-driven kind gets the picker for free —
                                // the kind-specific config follows it.
                                if let capability = SubagentCapabilityRegistry.capability(
                                    forPerAgentFlag: feature.flag
                                ), capability.supportsModelOverride {
                                    subagentModelOverrideRow(capability)
                                    subagentPanelDivider
                                }
                                subagentInlineConfig(for: feature.flag)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Capability toggle card for the Subagents tab. Mirrors `featureCard`'s
    /// chrome so it matches the Features tab, but binds directly to the
    /// per-capability enable binding (which routes the right save) and tints its
    /// border with the accent color when on, so an active capability is
    /// scannable at a glance.
    private func subagentCapabilityCard(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title, bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text(subtitle, bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                .labelsHidden()
        }
        .padding(10)
        .background(
            roundedSurface(
                fill: theme.inputBackground,
                stroke: isOn.wrappedValue ? theme.accentColor.opacity(0.5) : theme.inputBorder
            )
        )
    }

    /// Calm, clearly subordinate container for a capability's expanded settings.
    /// Sits just under its toggle card, indented, with a quieter background and a
    /// single hairline border — so the controls read as "settings for this card"
    /// instead of more top-level cards.
    private func subagentConfigPanel<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(roundedSurface(fill: theme.tertiaryBackground, stroke: theme.inputBorder))
        .padding(.leading, 12)
    }

    /// Hairline separator between control clusters inside `subagentConfigPanel`.
    private var subagentPanelDivider: some View {
        Divider().overlay(theme.inputBorder)
    }

    /// Small footnote line (system-setting pointers, permission requirements)
    /// inside a subagent config panel.
    private func subagentFootnote(_ text: LocalizedStringKey) -> some View {
        Text(text, bundle: .module)
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Surfaced inside the Spawn config when the global Local Orchestrator
    /// Handoff is OFF. That handoff is a reject-before-evict gate: spawning a
    /// LOCAL target whose model differs from the resident chat model is refused
    /// (only remote targets and the already-loaded model run). Showing it here
    /// means the limit is visible while configuring targets, not just as a
    /// runtime error. Reads the global store snapshot (`globalSubagentConfig`)
    /// loaded for every agent; the toggle itself lives in Settings → Subagents.
    @ViewBuilder
    private var spawnHandoffDisabledWarning: some View {
        if !globalSubagentConfig.localTextDelegationEnabled {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(theme.warningColor)
                Text(
                    "Local Orchestrator Handoff is off (Settings → Subagents). Spawning a local agent or model whose model differs from the current chat model will be refused — only remote targets and the loaded model run.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.warningColor.opacity(0.12))
            )
        }
    }

    /// Leading label (plus an optional one-line description) and a trailing
    /// control — the shared layout for every borderless row inside a
    /// `subagentConfigPanel` (permission, budget, model, autonomy ceiling).
    private func subagentControlRow<Control: View>(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title, bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                if let subtitle {
                    Text(subtitle, bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
    }

    /// Rounded fill plus a hairline border — the shared surface chrome for the
    /// Subagents capability cards, the nested config panel, and the ceiling
    /// menu button.
    private func roundedSurface(
        fill: Color,
        stroke: Color,
        cornerRadius: CGFloat = 8
    ) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(stroke, lineWidth: 1)
            )
    }

    /// The inline config panel revealed under a subagent toggle when it is on.
    /// One arm per per-agent flag: computer_use → autonomy ceiling + permission
    /// note; spawn → spawnable allow-list + permission + budgets; image → gen /
    /// edit model pickers + permission. Each control binds to `AgentSettings`
    /// via the binding helpers.
    @ViewBuilder
    private func subagentInlineConfig(for flag: SubagentCapability.PerAgentFlag) -> some View {
        switch flag {
        case .computerUse:
            // The model-override row is rendered generically above (registry
            // `supportsModelOverride`); this arm holds only computer-use-specific
            // config.
            screenContextToggleRow
            subagentPanelDivider
            computerUseCeilingRow
            subagentFootnote(
                "Requires Accessibility permission. Grant it and review status in Settings > Computer Use."
            )
        case .spawn:
            // The model-override row is rendered generically above (registry
            // `supportsModelOverride`). Two allow-lists drive the two spawn tools:
            // agents (`spawn_agent`) and bare models (`spawn_model`).
            spawnHandoffDisabledWarning
            spawnableAgentsPicker
            subagentPanelDivider
            spawnableModelsPicker
            subagentPanelDivider
            subagentPermissionRow(
                for: SubagentCapabilityRegistry.spawn.id,
                label: "Permission"
            )
            subagentPanelDivider
            spawnToolAccessRow
            subagentPanelDivider
            subagentBudgetRows
            subagentFootnote(
                "Local handoff and RAM-safety for spawn jobs are system settings in Settings → Subagents."
            )
        case .image:
            imageModelPickerRows
            subagentPanelDivider
            subagentPermissionRow(
                for: SubagentCapabilityRegistry.image.id,
                label: "Permission"
            )
            subagentFootnote(
                "Image load policy is a system setting in the Images tab."
            )
        case .appleScript:
            // AppleScript owns its own dedicated model (supportsModelOverride is
            // false, so the generic override row above is skipped): pick which
            // installed AppleScript model this agent uses, plus how each script
            // is gated. The consent surface is the execution-mode gate, so there
            // is no permission row.
            appleScriptModelPickerRow
            subagentPanelDivider
            appleScriptExecutionModeRow
            subagentFootnote(
                "AppleScript runs on this Mac. The first time the agent controls an app, macOS asks you to allow Automation for Osaurus. Download AppleScript models in Settings → Computer Use → Models."
            )
        }
    }

    // MARK: - Subagent inline config: model / permission / budget controls

    /// Generation + edit model pickers for the Image card. `nil` (Choose
    /// automatically) resolves to the first ready model at run time.
    private var imageModelPickerRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentSheetSectionLabel("Models")
            subagentModelPicker(
                title: "Generation model",
                selection: imageGenerationModelSelection,
                candidates: pickerItems.imageGenerationDelegateCandidates,
                currentId: currentImageGenerationModelId
            )
            subagentModelPicker(
                title: "Edit model",
                selection: imageEditModelSelection,
                candidates: pickerItems.imageEditDelegateCandidates,
                currentId: currentImageEditModelId
            )
        }
    }

    /// The installed AppleScript models this agent can pick. AppleScript bundles
    /// stay in the picker cache (only hidden from the chat picker), so they're
    /// filtered straight out of `pickerItems`.
    private var appleScriptModelCandidates: [ModelPickerItem] {
        pickerItems.filter(\.isAppleScriptCatalogModel)
    }

    /// AppleScript model picker for the AppleScript card. `nil` (Choose
    /// automatically) resolves to the first installed catalog model at run time;
    /// a stored id no longer on disk shows an "(unavailable)" row.
    private var appleScriptModelPickerRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentSheetSectionLabel("Model")
            subagentModelPicker(
                title: "AppleScript model",
                selection: appleScriptModelSelection,
                candidates: appleScriptModelCandidates,
                currentId: appleScriptModelId
            )
            if appleScriptModelCandidates.isEmpty {
                subagentFootnote(
                    "No AppleScript models installed yet. Download one in Settings → Computer Use → Models."
                )
            }
        }
    }

    /// Execution-mode control for the AppleScript card: confirm each script
    /// (safe default) vs auto-run with a warning. The caption spells out the
    /// safety trade-off of the selected mode.
    private var appleScriptExecutionModeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            subagentControlRow("Script execution") {
                Picker("", selection: appleScriptExecutionModeSelection) {
                    ForEach(AppleScriptExecutionMode.allCases, id: \.self) { mode in
                        Text(verbatim: mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Text(verbatim: appleScriptExecutionMode.caption)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A labeled image-model `Picker` styled for the inline card. Mirrors the
    /// global Settings picker: a "Choose automatically" empty tag plus a stale
    /// "(unavailable)" tag when the stored id is no longer downloaded.
    private func subagentModelPicker(
        title: LocalizedStringKey,
        selection: Binding<String>,
        candidates: [ModelPickerItem],
        currentId: String?,
        emptyLabel: LocalizedStringKey = "Choose automatically"
    ) -> some View {
        subagentControlRow(title) {
            Picker("", selection: selection) {
                Text(emptyLabel, bundle: .module).tag("")
                if let currentId,
                    !currentId.isEmpty,
                    !candidates.contains(where: { $0.id == currentId })
                {
                    Text("\(currentId) (unavailable)", bundle: .module).tag(currentId)
                }
                ForEach(candidates) { item in
                    Text(item.displayName).tag(item.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220, alignment: .trailing)
        }
    }

    /// The standard per-capability model-override picker for any chat-driven
    /// kind that sets `supportsModelOverride` (computer_use /
    /// spawn). Empty selection = inherit the kind's default model source; the
    /// empty-tag label is derived from the kind's `modelSource` ("Use the agent's
    /// model" for spawn, else "Inherit parent model") so the row needs no
    /// per-kind copy. Lists chat-capable candidates; a stale stored id shows an
    /// "(unavailable)" tag. Binds per-agent via `subagentModelOverrideBinding`.
    private func subagentModelOverrideRow(_ capability: SubagentCapability) -> some View {
        let inheritLabel: LocalizedStringKey =
            capability.modelSource == .agent ? "Use the agent's model" : "Inherit parent model"
        let selection = subagentModelOverrideBinding(for: capability.id)
        return subagentModelPicker(
            title: "Model",
            selection: selection,
            candidates: pickerItems.chatModelCandidates,
            currentId: normalizedModelSelection(selection.wrappedValue),
            emptyLabel: inheritLabel
        )
    }

    /// Two-way binding into a capability's model override. Empty string clears
    /// the override (inherit). Writes `subagentModelOverrides` (debounced agent
    /// save).
    private func subagentModelOverrideBinding(for kindId: String) -> Binding<String> {
        Binding(
            get: { subagentModelOverrides[kindId] ?? "" },
            set: { newValue in
                if let trimmed = normalizedModelSelection(newValue) {
                    subagentModelOverrides[kindId] = trimmed
                } else {
                    subagentModelOverrides.removeValue(forKey: kindId)
                }
                debouncedSave()
            }
        )
    }

    /// Segmented Ask / Deny / Always permission picker for a delegation kind,
    /// bound per-agent. Borderless — it lives inside `subagentConfigPanel`.
    private func subagentPermissionRow(for kindId: String, label: LocalizedStringKey) -> some View {
        subagentControlRow(label) {
            Picker("", selection: subagentPermissionBinding(for: kindId)) {
                ForEach(SubagentPermissionPolicy.allCases, id: \.self) { policy in
                    Text(LocalizedStringKey(policy.displayName), bundle: .module).tag(policy)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
        }
    }

    /// Token / turn / wall-clock budget steppers for the Spawn card, tucked
    /// behind a collapsed-by-default "Limits" disclosure (the normalized defaults
    /// are sensible, so these are power-user knobs). A one-line summary of the
    /// current budgets shows on the header when collapsed.
    private var subagentBudgetRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    spawnLimitsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(theme.tertiaryText)
                        .rotationEffect(.degrees(spawnLimitsExpanded ? 90 : 0))
                    AgentSheetSectionLabel("Limits")
                    Spacer(minLength: 8)
                    if !spawnLimitsExpanded {
                        Text(spawnLimitsSummary)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if spawnLimitsExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    subagentBudgetStepper(
                        title: "Max tokens",
                        value: subagentBudgetBinding(\.maxDelegateTokens),
                        range: SubagentBudgets.tokenBounds,
                        step: 256
                    )
                    subagentBudgetStepper(
                        title: "Max turns",
                        value: subagentBudgetBinding(\.maxDelegateTurns),
                        range: SubagentBudgets.turnBounds,
                        step: 1
                    )
                    subagentBudgetStepper(
                        title: "Max seconds",
                        value: subagentBudgetBinding(\.maxElapsedSeconds),
                        range: SubagentBudgets.elapsedBounds,
                        step: 15
                    )
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// Compact "tokens · turns · seconds" summary shown on the collapsed Limits
    /// header so the current budgets are visible at a glance without expanding.
    private var spawnLimitsSummary: String {
        let tokens = subagentBudgetBinding(\.maxDelegateTokens).wrappedValue
        let turns = subagentBudgetBinding(\.maxDelegateTurns).wrappedValue
        let seconds = subagentBudgetBinding(\.maxElapsedSeconds).wrappedValue
        return "\(tokens.formatted()) tok · \(turns) turn\(turns == 1 ? "" : "s") · \(seconds)s"
    }

    private func subagentBudgetStepper(
        title: LocalizedStringKey,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        subagentControlRow(title) {
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .frame(width: 64, alignment: .trailing)
            }
            .frame(maxWidth: 180)
        }
    }

    // MARK: - Subagent inline config: bindings

    // These bind to `AgentSettings`; the global image settings (defaults,
    // permission, load policy) live in the Image Generation tab.
    private var imageGenerationModelSelection: Binding<String> {
        Binding(
            get: { imageGenerationModelId ?? "" },
            set: {
                imageGenerationModelId = normalizedModelSelection($0)
                debouncedSave()
            }
        )
    }

    private var imageEditModelSelection: Binding<String> {
        Binding(
            get: { imageEditModelId ?? "" },
            set: {
                imageEditModelId = normalizedModelSelection($0)
                debouncedSave()
            }
        )
    }

    private var currentImageGenerationModelId: String? { imageGenerationModelId }

    private var currentImageEditModelId: String? { imageEditModelId }

    private var appleScriptModelSelection: Binding<String> {
        Binding(
            get: { appleScriptModelId ?? "" },
            set: {
                appleScriptModelId = normalizedModelSelection($0)
                debouncedSave()
            }
        )
    }

    private var appleScriptExecutionModeSelection: Binding<AppleScriptExecutionMode> {
        Binding(
            get: { appleScriptExecutionMode },
            set: {
                appleScriptExecutionMode = $0
                debouncedSave()
            }
        )
    }

    private func subagentPermissionBinding(for kindId: String) -> Binding<SubagentPermissionPolicy> {
        Binding(
            get: { subagentPermissions.policy(for: kindId) },
            set: {
                subagentPermissions.setPolicy($0, for: kindId)
                debouncedSave()
            }
        )
    }

    private func subagentBudgetBinding(_ keyPath: WritableKeyPath<SubagentBudgets, Int>) -> Binding<Int> {
        Binding(
            get: { subagentBudgets[keyPath: keyPath] },
            set: {
                subagentBudgets[keyPath: keyPath] = $0
                debouncedSave()
            }
        )
    }

    /// Worker tool grant for spawned subagents: text-only (default) or the
    /// curated read-only file set. What "read-only" reaches is enforced in
    /// `TextSubagentKind.makeToolset`, not here.
    private var spawnToolAccessRow: some View {
        subagentControlRow(
            "Worker tools",
            subtitle:
                "Let spawned workers read files themselves (file_read / file_search) so bulk reading stays out of this agent's context."
        ) {
            Picker("", selection: spawnToolAccessSelection) {
                Text("Text-only", bundle: .module).tag(SpawnToolAccess.none)
                Text("Read-only files", bundle: .module).tag(SpawnToolAccess.readOnly)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 160)
        }
    }

    private var spawnToolAccessSelection: Binding<SpawnToolAccess> {
        Binding(
            get: { spawnToolAccess },
            set: {
                spawnToolAccess = $0
                debouncedSave()
            }
        )
    }

    private func normalizedModelSelection(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Spawn allow-lists (agents + models)

    /// The agents currently in this editor's `spawn_agent` pool.
    private var selectedSpawnableAgentNames: [String] { spawnableAgentNames }

    /// The model ids currently in this editor's `spawn_model` pool.
    private var selectedSpawnableModelNames: [String] { spawnableModelNames }

    /// Per-agent `spawn_agent` allow-list: the OTHER agents this agent may
    /// launch (it can't spawn itself), shown selected-first as removable chips
    /// with a searchable "Add" popover. Writes the pool + debounced agent save.
    private var spawnableAgentsPicker: some View {
        let candidates = agentManager.agents.filter { $0.id != agent.id }
        let selected = selectedSpawnableAgentNames
        let addable = candidates.filter { cand in
            !selected.contains { $0.caseInsensitiveCompare(cand.name) == .orderedSame }
        }
        return VStack(alignment: .leading, spacing: 8) {
            AgentSheetSectionLabel("Allowed agents")
            if candidates.isEmpty {
                spawnEmptyHint("No other agents yet — create another agent to make it spawnable.")
            } else {
                if selected.isEmpty {
                    spawnEmptyHint(
                        "None yet. Add an agent to delegate a task to it (using its own prompt + model)."
                    )
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(selected, id: \.self) { name in
                            spawnRemovableChip(label: name) {
                                spawnableMembership(name).wrappedValue = false
                            }
                        }
                    }
                }
                spawnAddButton(
                    title: "Add agent",
                    isPresented: $spawnAgentPickerPresented,
                    disabled: addable.isEmpty
                ) {
                    spawnAgentAddList()
                }
            }
        }
    }

    /// Per-agent `spawn_model` allow-list: bare model ids this agent may hand a
    /// task to directly (no agent), shown selected-first as rows with a
    /// local/remote badge and an inline "when to use" note, plus a searchable,
    /// source-grouped "Add" popover. Notes are pruned to the pool on save.
    private var spawnableModelsPicker: some View {
        let selected = selectedSpawnableModelNames
        let addable = pickerItems.chatModelCandidates.filter { !selected.contains($0.id) }
        return VStack(alignment: .leading, spacing: 8) {
            AgentSheetSectionLabel("Allowed models")
            if selected.isEmpty {
                spawnEmptyHint(
                    "None yet. Add a local or remote model to delegate to it directly, with no agent attached."
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(selected, id: \.self) { id in
                        spawnableModelRow(id)
                    }
                }
            }
            spawnAddButton(
                title: "Add model",
                isPresented: $spawnModelPickerPresented,
                disabled: addable.isEmpty
            ) {
                spawnModelAddList()
            }
        }
    }

    /// One selected `spawn_model` row: display name + local/remote badge, an
    /// inline optional note field, and a remove button.
    private func spawnableModelRow(_ id: String) -> some View {
        let item = spawnModelItem(id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(item?.displayName ?? id)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                if let badge = spawnModelBadge(item) {
                    spawnBadgePill(badge)
                }
                Spacer(minLength: 8)
                Button {
                    spawnableModelMembership(id).wrappedValue = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(PlainButtonStyle())
            }
            spawnModelNoteField(id)
        }
        .padding(8)
        .background(roundedSurface(fill: theme.inputBackground, stroke: theme.inputBorder))
    }

    /// Inline optional note field for a selected spawnable model.
    private func spawnModelNoteField(_ id: String) -> some View {
        let binding = spawnableModelNoteBinding(id)
        return ZStack(alignment: .leading) {
            if binding.wrappedValue.isEmpty {
                Text("When/how to use this model (optional)", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.placeholderText)
                    .allowsHitTesting(false)
            }
            TextField("", text: binding)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 11))
                .foregroundColor(theme.primaryText)
        }
    }

    /// The picker item for a stored model id (for display name / badge), or nil
    /// when the model is no longer in the cache.
    private func spawnModelItem(_ id: String) -> ModelPickerItem? {
        pickerItems.first { $0.id == id }
    }

    /// Short local/remote badge text for a model row (provider name for remote).
    private func spawnModelBadge(_ item: ModelPickerItem?) -> String? {
        guard let item else { return nil }
        switch item.source {
        case .remote(let providerName, _): return providerName
        case .local, .foundation: return L("Local")
        case .imageGeneration: return L("Image")
        }
    }

    /// A small capsule badge (local/remote/provider) used in the model rows.
    private func spawnBadgePill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(theme.tertiaryText)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.tertiaryBackground))
    }

    /// Empty-state / hint line shared by both spawn selectors.
    private func spawnEmptyHint(_ text: LocalizedStringKey) -> some View {
        Text(text, bundle: .module)
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A removable chip (selected `spawn_agent` agent).
    private func spawnRemovableChip(label: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(theme.tertiaryBackground))
        .overlay(Capsule().stroke(theme.inputBorder, lineWidth: 1))
    }

    /// The "+ Add …" button that reveals a searchable multi-select popover.
    /// Disabled (greyed) when nothing remains to add.
    private func spawnAddButton<Content: View>(
        title: LocalizedStringKey,
        isPresented: Binding<Bool>,
        disabled: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        Button {
            isPresented.wrappedValue = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                Text(title, bundle: .module).font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(disabled ? theme.tertiaryText : theme.accentColor)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(disabled)
        .popover(isPresented: isPresented, arrowEdge: .bottom) {
            content()
        }
    }

    /// Multi-select popover body for adding spawnable agents. Recomputes its
    /// addable list from live state so a tapped agent leaves the list while the
    /// popover stays open for more picks.
    private func spawnAgentAddList() -> some View {
        let selected = selectedSpawnableAgentNames
        let addable = agentManager.agents.filter { cand in
            cand.id != agent.id
                && !selected.contains { $0.caseInsensitiveCompare(cand.name) == .orderedSame }
        }
        let query = spawnAgentSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = addable.filter { cand in
            query.isEmpty
                || cand.name.localizedCaseInsensitiveContains(query)
                || cand.description.localizedCaseInsensitiveContains(query)
        }
        return VStack(alignment: .leading, spacing: 8) {
            SearchField(
                text: $spawnAgentSearch,
                placeholder: "Search agents",
                width: 264,
                compact: true
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if filtered.isEmpty {
                        spawnEmptyHint("No matching agents.").padding(.vertical, 6)
                    } else {
                        ForEach(filtered) { cand in
                            spawnAddRow(
                                title: cand.name,
                                subtitle: cand.description.isEmpty ? nil : cand.description
                            ) {
                                spawnableMembership(cand.name).wrappedValue = true
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(12)
        .frame(width: 292)
    }

    /// Multi-select popover body for adding spawnable models, grouped by source
    /// (Local / each provider) and searchable. Recomputes from live state.
    private func spawnModelAddList() -> some View {
        let selected = selectedSpawnableModelNames
        let addable = pickerItems.chatModelCandidates.filter { !selected.contains($0.id) }
        let filtered = addable.filter { $0.matches(searchQuery: spawnModelSearch) }
        let grouped = filtered.groupedBySource()
        return VStack(alignment: .leading, spacing: 8) {
            SearchField(
                text: $spawnModelSearch,
                placeholder: "Search models",
                width: 296,
                compact: true
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if grouped.isEmpty {
                        spawnEmptyHint("No matching models.").padding(.vertical, 6)
                    } else {
                        ForEach(Array(grouped.enumerated()), id: \.offset) { _, group in
                            Text(group.source.displayName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(theme.tertiaryText)
                                .padding(.top, 4)
                            ForEach(group.models) { item in
                                spawnAddRow(
                                    title: item.displayName,
                                    subtitle: spawnModelSubtitle(item)
                                ) {
                                    spawnableModelMembership(item.id).wrappedValue = true
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(12)
        .frame(width: 324)
    }

    /// One tappable add-row inside a spawn popover (title + optional subtitle +
    /// a leading-to-trailing add affordance).
    private func spawnAddRow(
        title: String,
        subtitle: String?,
        onAdd: @escaping () -> Void
    ) -> some View {
        Button(action: onAdd) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(theme.accentColor)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// Compact "size · quant · Vision" subtitle for a model add-row.
    private func spawnModelSubtitle(_ item: ModelPickerItem) -> String? {
        var parts: [String] = []
        if let params = item.parameterCount, !params.isEmpty { parts.append(params) }
        if let quant = item.quantization, !quant.isEmpty { parts.append(quant) }
        if item.isVLM { parts.append(L("Vision")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Case-insensitive membership binding into the spawnable pool, de-duping on
    /// insert so a duplicate agent name can't stack entries. Matches
    /// `SubagentToolVisibility.spawnTargetAllowed`'s comparison. Writes
    /// `AgentSettings.spawnableAgentNames` (debounced agent save).
    private func spawnableMembership(_ name: String) -> Binding<Bool> {
        Binding(
            get: {
                spawnableAgentNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            },
            set: { isOn in
                var names = spawnableAgentNames.filter {
                    $0.caseInsensitiveCompare(name) != .orderedSame
                }
                if isOn { names.append(name) }
                spawnableAgentNames = names
                debouncedSave()
            }
        )
    }

    /// Exact-match membership binding into the spawnable MODEL pool, de-duping on
    /// insert. Matches `SubagentToolVisibility.spawnModelAllowed` (model ids are
    /// canonical, so exact, not case-insensitive). Removing a model also drops
    /// its note. Writes `AgentSettings.spawnableModelNames` (debounced agent save).
    private func spawnableModelMembership(_ id: String) -> Binding<Bool> {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return Binding(
            get: { spawnableModelNames.contains(trimmed) },
            set: { isOn in
                var names = spawnableModelNames.filter { $0 != trimmed }
                if isOn {
                    names.append(trimmed)
                } else {
                    spawnableModelNotes.removeValue(forKey: trimmed)
                }
                spawnableModelNames = names
                debouncedSave()
            }
        )
    }

    /// Two-way binding into a spawnable model's note. A blank value clears the
    /// note. Writes `AgentSettings.spawnableModelNotes` (debounced agent save).
    private func spawnableModelNoteBinding(_ id: String) -> Binding<String> {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return Binding(
            get: { spawnableModelNotes[trimmed] ?? "" },
            set: { newValue in
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    spawnableModelNotes.removeValue(forKey: trimmed)
                } else {
                    spawnableModelNotes[trimmed] = newValue
                }
                debouncedSave()
            }
        )
    }

    /// Binding-backed feature toggle row. Thin wrapper over `featureCard`
    /// that writes the binding and triggers the debounced agent save. Used for
    /// every per-agent `AgentSettings` flag in the Features and Subagents tabs.
    private func featureToggleRow(title: LocalizedStringKey, subtitle: LocalizedStringKey, isOn: Binding<Bool>)
        -> some View
    {
        featureCard(title: title, subtitle: subtitle, isOn: isOn.wrappedValue) { newValue in
            isOn.wrappedValue = newValue
            debouncedSave()
        }
    }

    /// The single, canonical toggle-row visual for the Features section.
    /// Every row — model access, capability gates, data, and code execution —
    /// renders through this so they share identical padding, card chrome,
    /// and accent-tinted switch. `interactive: false` dims and disables the
    /// switch (sandbox rows use it when the container isn't running) while
    /// keeping the copy readable. Subtitles wrap instead of truncating.
    private func featureCard(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        isOn: Bool,
        interactive: Bool = true,
        onChange: @escaping (Bool) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title, bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text(subtitle, bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(get: { isOn }, set: onChange))
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                .labelsHidden()
                .disabled(!interactive)
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
        .opacity(interactive ? 1 : 0.55)
    }

    /// Per-agent screen-context toggle, nested under Computer Use. Defaults on
    /// with Computer Use; the effective value is gated by Computer Use, so this
    /// row only shows (and only matters) while Computer Use is enabled. What it
    /// captures is described in the row subtitle, and the Preview link below
    /// shows exactly what a new chat would freeze and share.
    private var screenContextToggleRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            subagentControlRow(
                "Share screen context",
                subtitle:
                    "Freeze a text-only snapshot of your screen at the start of each chat and share it as background context. No screenshots; scrubbed by the Privacy Filter before cloud sends."
            ) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { screenContextEnabled },
                        set: {
                            screenContextEnabled = $0
                            debouncedSave()
                        }
                    )
                )
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                .labelsHidden()
            }
            screenContextPreviewLink
        }
    }

    /// A quiet link that opens the live screen-context preview in a popover, so
    /// the user can confirm what this agent would share without leaving the
    /// sheet. The preview is read-only and independent of the toggle state.
    private var screenContextPreviewLink: some View {
        Button {
            showScreenContextPreview = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "eye")
                    .font(.system(size: 10))
                Text(L("Preview screen context"))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(theme.accentColor)
        }
        .buttonStyle(PlainButtonStyle())
        .popover(isPresented: $showScreenContextPreview, arrowEdge: .bottom) {
            ScreenContextPreview(previewHeight: 220)
                .frame(width: 440)
                .padding(16)
        }
    }

    /// Per-agent autonomy ceiling picker for Computer Use. The ceiling caps
    /// how far this agent can act regardless of the user's global policy
    /// (strictest-wins), expressed as "at most <preset>" so it reads like the
    /// global preset picker. "No ceiling" stores nil.
    private var computerUseCeilingRow: some View {
        let selectedPreset = computerUseCeiling?.matchingPreset
        return subagentControlRow(
            "Autonomy ceiling",
            subtitle: "Cap how far this agent can act, even when your global policy is more permissive."
        ) {
            Menu {
                Button {
                    computerUseCeiling = nil
                    debouncedSave()
                } label: {
                    if computerUseCeiling == nil {
                        Label {
                            Text(L("No ceiling"))
                        } icon: {
                            Image(systemName: "checkmark")
                        }
                    } else {
                        Text(L("No ceiling"))
                    }
                }
                Divider()
                ForEach(AutonomyPreset.allCases) { preset in
                    let label = String(format: L("At most: %@"), preset.displayLabel)
                    Button {
                        computerUseCeiling = AutonomyCeiling.cappedAt(preset)
                        debouncedSave()
                    } label: {
                        if selectedPreset == preset {
                            Label {
                                Text(label)
                            } icon: {
                                Image(systemName: "checkmark")
                            }
                        } else {
                            Text(label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(ceilingMenuLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    roundedSurface(
                        fill: theme.tertiaryBackground,
                        stroke: theme.inputBorder,
                        cornerRadius: 6
                    )
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var ceilingMenuLabel: String {
        guard let ceiling = computerUseCeiling else { return L("No ceiling") }
        if let preset = ceiling.matchingPreset {
            return String(format: L("At most: %@"), preset.displayLabel)
        }
        return L("Custom")
    }

    /// Labeled subgroup inside the Features section. Renders a small caps
    /// header (and an optional one-line description) above its rows so the
    /// section reads as distinct, self-explaining groups (Model Access /
    /// Output / Memory & Recall / Autonomy / Data / Code Execution) rather
    /// than one long undifferentiated toggle list.
    @ViewBuilder
    private func featureGroup<Content: View>(
        _ label: LocalizedStringKey,
        description: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                AgentSheetSectionLabel(label)
                if let description {
                    Text(description, bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 2)
            content()
        }
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
                AgentDetailSection(title: L("Configuration"), icon: "slider.horizontal.3") {
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

            pluginDiagnosticsCard(for: pid)
        }
    }

    /// One-shot warnings emitted by `PluginOnceLogger` for this plugin
    /// (NULL on_chunk callback, agent-scope override attempts, missing
    /// agent context on background threads, oversized config_set, etc.).
    /// Surfaces them in the plugin detail UI so authors don't have to
    /// grep `Console.app` to find ABI misuse the host has already
    /// flagged. Hidden when the plugin has no warnings yet.
    @ViewBuilder
    private func pluginDiagnosticsCard(for pluginId: String) -> some View {
        let entries = PluginOnceLogger.entries(forPlugin: pluginId)
        if !entries.isEmpty {
            AgentDetailSection(title: L("Diagnostics"), icon: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        String(
                            format: L("Host emitted %d one-shot warning%@ for this plugin."),
                            entries.count,
                            entries.count == 1 ? "" : "s"
                        )
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 16)

                    // Most-recent first so the latest issue is at the
                    // top — matches how console viewers usually order.
                    ForEach(entries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.message)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(theme.primaryText)
                                .textSelection(.enabled)
                            Text(entry.date.formatted(date: .omitted, time: .standard))
                                .font(.system(size: 10))
                                .foregroundColor(theme.tertiaryText)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.cardBackground.opacity(0.4))
                        )
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    /// Tab label for a failed plugin. Prefers the manifest display
    /// name when we managed to decode the manifest before the failure,
    /// falling back to the plugin id. Suffix `(Failed)` keeps the
    /// failure unambiguous in the tab strip.
    private func failedPluginTabLabel(for failed: PluginManager.FailedPlugin) -> String {
        let base = failed.lastKnownManifest?.name ?? failed.pluginId
        return "\(base) (Failed)"
    }

    /// Tab body for a plugin in `PluginManager.failedPlugins`. Names
    /// the likely cause (misaligned `osr_host_api` mirror), shows the
    /// install path with a Reveal-in-Finder shortcut, and surfaces
    /// two confirmation-gated actions: Retry (re-runs the same dylib,
    /// will crash again if unfixed) and Uninstall (wipes the plugin
    /// directory and secrets — the escape hatch).
    @ViewBuilder
    private func failedPluginTabContent(for pid: String) -> some View {
        let display = PluginManager.shared.failedPlugins[pid]?.lastKnownManifest?.name ?? pid
        let error =
            PluginManager.shared.loadError(for: pid)
            ?? "The host failed to load this plugin and the underlying error was not captured."
        let installPath = PluginInstallManager.toolsPluginDirectory(pluginId: pid).path

        tabHelperText(
            String(format: L("\u{201C}%@\u{201D} could not be loaded for this agent."), display)
        )

        AgentDetailSection(title: L("Plugin failed to load"), icon: "exclamationmark.triangle.fill") {
            VStack(alignment: .leading, spacing: 14) {
                failedPluginField(label: "Error") {
                    Text(error)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.cardBackground.opacity(0.6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.orange.opacity(0.4), lineWidth: 1)
                                )
                        )
                }

                failedPluginField(label: "Plugin id") {
                    Text(pid)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .textSelection(.enabled)
                }

                failedPluginField(
                    label: "Install path",
                    trailing: { revealInFinderButton(path: installPath) }
                ) {
                    Text(installPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                failedPluginField(label: "Most likely cause") {
                    Text(
                        "The plugin's `osr_host_api` mirror struct does not match the host's v6 layout — most often the v5 `log_structured` slot is skipped, which shifts every later slot by 8 bytes. The plugin then dispatches `host->free_string` to the wrong host trampoline and `libc free()` aborts on a non-malloc pointer, killing the host. See `docs/plugins/HOST_API.md → Mirror Struct Audit` and `docs/plugins/ABI_VERSIONS.md` for the pinned offsets and the documented v1..v6 evolution.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    failedPluginActionButton(
                        title: "Retry Load",
                        icon: "arrow.clockwise",
                        tint: theme.primaryText,
                        background: theme.cardBackground.opacity(0.6),
                        border: theme.tertiaryText.opacity(0.4),
                        helpText: "Re-load this plugin. Will crash again if the underlying bug is unfixed."
                    ) {
                        pendingFailedPluginRetry = pid
                    }

                    failedPluginActionButton(
                        title: "Uninstall Plugin",
                        icon: "trash",
                        tint: .red,
                        background: Color.red.opacity(0.15),
                        border: Color.red.opacity(0.5),
                        helpText: "Permanently delete this plugin from disk so the host stops trying to load it."
                    ) {
                        pendingFailedPluginUninstall = pid
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }

        pluginDiagnosticsCard(for: pid)
    }

    /// Labeled section block used inside `failedPluginTabContent`.
    /// `trailing` is rendered to the right of the label (e.g. the
    /// "Reveal in Finder" button on the install-path row).
    @ViewBuilder
    private func failedPluginField<Trailing: View, Content: View>(
        label: LocalizedStringKey,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(label, bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .textCase(.uppercase)
                Spacer()
                trailing()
            }
            content()
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func failedPluginField<Content: View>(
        label: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        failedPluginField(label: label, trailing: { EmptyView() }, content: content)
    }

    private func revealInFinderButton(path: String) -> some View {
        Button {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .semibold))
                Text("Reveal in Finder", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(theme.accentColor)
        }
        .buttonStyle(.plain)
    }

    private func failedPluginActionButton(
        title: LocalizedStringKey,
        icon: String,
        tint: Color,
        background: Color,
        border: Color,
        helpText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title, bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(background))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(border, lineWidth: 1))
            .foregroundColor(tint)
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    /// Drops the `pid` quarantine entry (and the stale
    /// `.currently_loading` marker) then triggers a forced reload of
    /// all plugins. Only invoked from the `pendingFailedPluginRetry`
    /// alert's primary button so the user has explicitly acknowledged
    /// that the plugin may crash again.
    private func confirmRetryFailedPlugin(_ pid: String) {
        PluginManager.removeFromQuarantine(pid)
        Task {
            await PluginManager.shared.loadAll(forceReload: true)
        }
    }

    /// Routes through `PluginRepositoryService.uninstall` so secrets,
    /// skills, and the install directory are cleaned up the same way
    /// the Tools manager would handle a normal uninstall. Also wipes
    /// the quarantine entry so a future re-install starts clean.
    private func confirmUninstallFailedPlugin(_ pid: String) {
        PluginManager.removeFromQuarantine(pid)
        Task {
            try? await PluginRepositoryService.shared.uninstall(pluginId: pid)
        }
    }

    @ViewBuilder
    private func pluginInstructionsCard(for loaded: PluginManager.LoadedPlugin) -> some View {
        let pid = loaded.plugin.id
        let manifestDefault = loaded.plugin.manifest.instructions ?? ""

        AgentDetailSection(title: L("Instructions"), icon: "text.bubble") {
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

    /// Per-plugin route list. `AgentRelayBaseURLProvider` localizes
    /// the `RelayTunnelManager.shared` observation needed to resolve
    /// the public `<base>/plugins/<id>` URL when the tunnel is live.
    @ViewBuilder
    private func pluginRoutesCard(for loaded: PluginManager.LoadedPlugin) -> some View {
        AgentRelayBaseURLProvider(agentId: agent.id, pluginId: loaded.plugin.id) { tunnelBaseURL in
            self.pluginRoutesCardContent(for: loaded, tunnelBaseURL: tunnelBaseURL)
        }
    }

    @ViewBuilder
    private func pluginRoutesCardContent(
        for loaded: PluginManager.LoadedPlugin,
        tunnelBaseURL: String?
    ) -> some View {
        let pid = loaded.plugin.id

        AgentDetailSection(title: L("Route Endpoints"), icon: "arrow.left.arrow.right") {
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
        .help(isCopied ? Text(localized: "Copied") : Text(localized: "Copy URL"))
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

        let subtitle: String = {
            if sandboxRunning { return L("Running") }
            if sandboxAvailable { return L("Not Running") }
            return L("Unavailable")
        }()

        AgentDetailSection(title: L("Sandbox"), icon: "shippingbox", subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 16) {
                if !sandboxAvailable {
                    AgentSectionEmptyState(
                        icon: "shippingbox",
                        title: "Sandbox unavailable",
                        hint:
                            "Container-based execution requires macOS 26 or later. Native plugins continue to work normally on this device."
                    )
                } else if !sandboxRunning {
                    workspaceFolderRow
                    AgentSectionEmptyState(
                        icon: "shippingbox",
                        title: "Sandbox not running",
                        hint:
                            "Start the sandbox container from the Sandbox status bar, then enable autonomous execution and plugin creation under Configure → Features."
                    )
                    secretsSubsection
                } else {
                    workspaceFolderRow
                    secretsSubsection
                }
            }
        }
    }

    /// Row inside the agent's Sandbox section that reveals the agent's
    /// host-side workspace folder in Finder. The folder is the same one
    /// bind-mounted into the guest at `/workspace/agents/<linuxName>/`,
    /// so any edit the user makes from Finder is visible to the agent
    /// immediately. `OsaurusPaths.revealInFinder` lazily creates the
    /// directory so agents that have never executed inside the
    /// sandbox still get a usable folder.
    private var workspaceFolderRow: some View {
        let linuxName = SandboxAgentProvisioner.linuxName(for: agent.id.uuidString)
        let workspaceURL = OsaurusPaths.containerAgentDir(linuxName)
        let isProvisioned = SandboxManager.State.shared.status != .notProvisioned

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Workspace Folder", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text(
                    "Browse and edit files in this agent's /workspace/agents/… home.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            }
            Spacer()
            Button {
                OsaurusPaths.revealInFinder(workspaceURL)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Open in Finder", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(theme.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.accentColor.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(theme.accentColor.opacity(0.2), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(!isProvisioned)
            .opacity(isProvisioned ? 1 : 0.45)
            .help(
                isProvisioned
                    ? "Reveal this agent's sandbox home folder in Finder."
                    : "Set up the sandbox to enable the workspace."
            )
        }
    }

    /// Host Files row (Configure → Features). Lets the user grant this agent a
    /// real macOS folder it may read and write inside — including over an
    /// authenticated remote agent run (Secure Channel, agent-scoped key). The
    /// grant is a security-scoped bookmark persisted on the agent; writes are
    /// confined to the folder and shell/git stay denied on the remote surface.
    /// Independent of the Linux sandbox, so it renders regardless of sandbox
    /// availability.
    @ViewBuilder
    private var hostWorkspaceFolderRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hostWorkspacePath ?? L("No folder selected"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(
                            hostWorkspacePath == nil ? theme.tertiaryText : theme.primaryText
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(
                        "The agent can read and write files within this folder, including over authenticated remote agent runs. Writes stay inside the folder; shell and git remain disabled.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    chooseHostWorkspaceFolder()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .semibold))
                        Text(
                            hostWorkspacePath == nil ? L("Choose…") : L("Change…")
                        )
                        .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.accentColor.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(theme.accentColor.opacity(0.2), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                if hostWorkspacePath != nil {
                    Button {
                        clearHostWorkspaceFolder()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                    .help(L("Remove host folder access"))
                }
            }
        }
    }

    /// Present a folder picker, mint a security-scoped bookmark, and persist it
    /// on the agent. Mirrors `FolderContextService.selectFolder`'s panel but
    /// stores the grant per-agent instead of in the process-wide context.
    private func chooseHostWorkspaceFolder() {
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.title = L("Select Host Workspace Folder")
            panel.message = L("Choose a folder this agent may read and write inside.")
            panel.prompt = L("Select")

            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            guard let bookmark = FolderContextService.makeSecurityScopedBookmark(for: url) else {
                ToastManager.shared.error(L("Failed to grant folder access"))
                return
            }
            guard var updated = agentManager.agent(for: agent.id) else { return }
            updated.hostWorkspaceBookmark = bookmark
            updated.hostWorkspacePath = url.path
            agentManager.update(updated)
            hostWorkspacePath = url.path
        }
    }

    /// Revoke the agent's host folder grant.
    private func clearHostWorkspaceFolder() {
        guard var updated = agentManager.agent(for: agent.id) else { return }
        updated.hostWorkspaceBookmark = nil
        updated.hostWorkspacePath = nil
        agentManager.update(updated)
        hostWorkspacePath = nil
    }

    /// Sandbox execution toggles, surfaced inside the Configure tab's
    /// Features section via the shared `featureCard` visual so they match
    /// the rest of the section. `interactive` is false when the sandbox is
    /// unavailable / not running: the rows still render (so the capability
    /// is discoverable) but the switches are disabled and dimmed, paired
    /// with an explanatory hint from `sandboxExecSubsection`.
    @ViewBuilder
    private func sandboxExecToggles(
        execConfig: AutonomousExecConfig?,
        interactive: Bool = true
    ) -> some View {
        featureCard(
            title: "Autonomous Execution",
            subtitle: "Allow the agent to run arbitrary commands in the sandbox.",
            isOn: execConfig?.enabled ?? false,
            interactive: interactive
        ) { enabled in
            updateAutonomousExec(from: execConfig) { $0.enabled = enabled }
        }

        if execConfig?.enabled == true {
            featureCard(
                title: "Plugin Creation",
                subtitle: "Let the agent create its own tools as plugins.",
                isOn: execConfig?.pluginCreate ?? false,
                interactive: interactive
            ) { create in
                updateAutonomousExec(from: execConfig) { $0.pluginCreate = create }
            }

            featureCard(
                title: "Sandbox Network",
                subtitle:
                    "Allow outbound network from the sandbox. Turn off to cut data exfiltration (takes effect on next sandbox start).",
                isOn: execConfig?.sandboxNetworkEnabled ?? true,
                interactive: interactive
            ) { networkOn in
                updateAutonomousExec(from: execConfig) { $0.sandboxNetworkEnabled = networkOn }
            }

            featureCard(
                title: "Background Processes",
                subtitle:
                    "Let the agent run long-lived processes (servers, watchers) detached and manage them. Off by default to keep the tool surface lean.",
                isOn: execConfig?.backgroundProcessEnabled ?? false,
                interactive: interactive
            ) { backgroundOn in
                updateAutonomousExec(from: execConfig) { $0.backgroundProcessEnabled = backgroundOn }
            }

            featureCard(
                title: "Read Secret Files",
                subtitle:
                    "With a working folder, allow reading .env / keys / credentials. Off by default to keep secrets out of the sandbox.",
                isOn: execConfig?.allowHostSecretReads ?? false,
                interactive: interactive
            ) { allow in
                updateAutonomousExec(from: execConfig) { $0.allowHostSecretReads = allow }
            }
        }
    }

    /// Sandbox execution rows for the Features section. Shows the toggles
    /// in every sandbox state: dimmed + disabled (with an explanatory hint)
    /// when the sandbox is unavailable or not running, fully interactive
    /// once it's running. The section gates this on `isCustomAgent`.
    @ViewBuilder
    private var sandboxExecSubsection: some View {
        let sandboxAvailable = SandboxManager.State.shared.availability.isAvailable
        let sandboxRunning = SandboxManager.State.shared.status == .running
        let execConfig = agentManager.effectiveAutonomousExec(for: agent.id)

        sandboxExecToggles(execConfig: execConfig, interactive: sandboxRunning)
        if !sandboxAvailable {
            sandboxFeatureHint("Container-based execution requires macOS 26 or later.")
        } else if !sandboxRunning {
            sandboxFeatureHint(
                "Start the sandbox container from the Sandbox status bar to enable these."
            )
        }
    }

    /// Small explanatory line shown under the sandbox toggles when they're
    /// disabled because the sandbox isn't ready.
    private func sandboxFeatureHint(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            Text(text, bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
    }

    private func updateAutonomousExec(
        from current: AutonomousExecConfig?,
        _ mutate: (inout AutonomousExecConfig) -> Void
    ) {
        var config = current ?? .default
        mutate(&config)
        Task { @MainActor in
            do {
                try await agentManager.updateAutonomousExec(config, for: agent.id)
            } catch {
                ToastManager.shared.error(
                    L("Failed to update sandbox access"),
                    message: error.localizedDescription
                )
            }
        }
    }

    @ViewBuilder
    private var secretsSubsection: some View {
        let savedCount = agentSecrets.filter { !$0.isNew }.count

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentSheetSectionLabel("SECRETS")
                if savedCount > 0 {
                    Text("\(savedCount)", bundle: .module)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(theme.tertiaryBackground))
                }
                Spacer()
                addSecretButton
            }

            Text(
                "Secrets are injected as environment variables when this agent runs commands or plugins in the sandbox.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)

            if agentSecrets.isEmpty {
                Text("No secrets configured", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(agentSecrets.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Divider().background(theme.primaryBorder)
                        }
                        AgentSecretRow(
                            entry: entry,
                            isEditing: editingSecretEntryId == entry.id,
                            theme: theme,
                            onCommit: { commitAgentSecret(entryId: entry.id, key: $0, value: $1) },
                            onDelete: { deleteAgentSecret(entryId: entry.id, key: entry.key) },
                            onStartEditing: { editingSecretEntryId = entry.id }
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
            }
        }
    }

    private var addSecretButton: some View {
        Button(action: addAgentSecret) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                Text("Add", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(theme.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.accentColor.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.accentColor.opacity(0.2), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
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

    /// Relay tunnel toggle + live status. Live reads happen inside
    /// `AgentDetailRelaySection`, the only place observing
    /// `RelayTunnelManager.shared`.
    @ViewBuilder
    private var relaySection: some View {
        let hasIdentity = currentAgent.agentAddress != nil && currentAgent.agentIndex != nil
        if hasIdentity {
            AgentDetailRelaySection(
                theme: theme,
                agentId: agent.id,
                agentAddress: currentAgent.agentAddress,
                showRelayConfirmation: $showRelayConfirmation,
                copiedRelayURL: $copiedRelayURL
            )
        }
    }

    /// Single quick-actions block surfaced under Custom in the merged
    /// Empty State section. Now that work mode is gone, there's only
    /// one list — `chatQuickActions` — so we label the group "Action
    /// Bar" rather than "Chat" to match the surrounding section copy.
    private var actionBarBlock: some View {
        quickActionsModeGroup(
            label: L("Action Bar"),
            icon: "bolt.fill",
            actions: $chatQuickActions,
            defaults: AgentQuickAction.defaultChatQuickActions
        )
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
                    Text(action.text.isEmpty ? L("Untitled") : action.text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(action.text.isEmpty ? theme.placeholderText : theme.primaryText)
                        .lineLimit(1)
                    Text(action.prompt.isEmpty ? L("No prompt") : action.prompt)
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
                            placeholder: L("SF Symbol name"),
                            text: quickActionBinding(in: actions, for: action.id, keyPath: \.icon),
                            icon: "star"
                        )
                        .frame(width: 160)

                        StyledTextField(
                            placeholder: L("Display text"),
                            text: quickActionBinding(in: actions, for: action.id, keyPath: \.text),
                            icon: "textformat"
                        )
                    }

                    StyledTextField(
                        placeholder: L("Prompt prefix (e.g. 'Explain ')"),
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
        AgentDetailSection(title: L("Visual Theme"), icon: "paintpalette.fill") {
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
            subtitle: linkedSchedules.isEmpty ? L("None") : "\(linkedSchedules.count)"
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

                            Text(schedule.isEnabled ? L("Active") : L("Paused"))
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
            subtitle: linkedWatchers.isEmpty ? L("None") : "\(linkedWatchers.count)"
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
            subtitle: L("\(chatSessions.count) chat\(chatSessions.count == 1 ? "" : "s")")
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
                                        let turnCount =
                                            sessionTurnCounts[session.id]
                                            ?? session.turns.count
                                        Text("\(turnCount) turns", bundle: .module)
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
            subtitle: pinnedFacts.isEmpty ? L("None") : "\(pinnedFacts.count)"
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
            subtitle: episodes.isEmpty ? L("None") : "\(episodes.count)"
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
        // Drop the matching vector so search can't keep surfacing a fact that
        // no longer exists in SQL (SQL<->vector consistency).
        let agentScope = agent.id.uuidString
        Task { await MemorySearchService.shared.removeDocument(id: factId, agentId: agentScope) }
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
        chatGreetingDraft = agent.chatGreeting ?? ""
        chatSubtitleDraft = agent.chatSubtitle ?? ""
        toolsEnabled = agent.toolsEnabled
        memoryEnabled = agent.memoryEnabled
        dbEnabled = agent.settings.dbEnabled
        renderChartEnabled = agent.settings.renderChartEnabled
        speakEnabled = agent.settings.speakEnabled
        searchMemoryEnabled = agent.settings.searchMemoryEnabled
        selfSchedulingEnabled = agent.settings.selfSchedulingEnabled
        subagentToggles = SubagentCapabilityRegistry.perAgentToggleFlags.reduce(into: [:]) {
            acc,
            flag in
            acc[flag] = flag.read(from: agent.settings)
        }
        computerUseCeiling = agent.settings.computerUseCeiling
        screenContextEnabled = agent.settings.screenContextEnabled
        spawnableAgentNames = agent.settings.spawnableAgentNames
        spawnableModelNames = agent.settings.spawnableModelNames
        spawnableModelNotes = agent.settings.spawnableModelNotes
        imageGenerationModelId = agent.settings.imageGenerationModelId
        imageEditModelId = agent.settings.imageEditModelId
        appleScriptModelId = agent.settings.appleScriptModelId
        appleScriptExecutionMode = agent.settings.appleScriptExecutionMode
        subagentPermissions = agent.settings.subagentPermissions
        subagentBudgets = agent.settings.subagentBudgets
        subagentModelOverrides = agent.settings.subagentModelOverrides
        spawnToolAccess = agent.settings.spawnToolAccess
        // Snapshot the global subagent config for the spawn-handoff warning.
        globalSubagentConfig = SubagentConfigurationStore.snapshot()
        hostWorkspacePath = agent.hostWorkspacePath
        generativeGreetingsEnabled = agent.settings.generativeGreetingsEnabled
        // Hydrate the Personality editor with the resolved default
        // (global persona, falling back to built-in) when the agent has
        // no explicit override. Mirrors the global Settings view: the
        // editor never shows an empty placeholder, just selectable text
        // the user can edit or wipe. `saveAgent` collapses an unedited
        // default back to nil so future changes upstream still flow.
        let savedPersona = agent.settings.greetingPersona?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        greetingPersona =
            (savedPersona?.isEmpty ?? true)
            ? resolvedPersonaDefault
            : (agent.settings.greetingPersona ?? "")
        autoSpeak = agent.autoSpeak ?? false
        ttsVoice = agent.ttsVoice ?? ""
        avatar = agent.avatar
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
        // Counts come from `sessions.turn_count` directly so the row's
        // "N turns" label is accurate without hydrating each session's
        // turn array (which only happens on click — the prior root cause
        // of the persistent "0 turns" display).
        let agentFilter: UUID? = (agent.id == Agent.defaultId) ? nil : agent.id
        sessionTurnCounts = ChatHistoryDatabase.shared.turnCounts(forAgent: agentFilter)
    }

    // MARK: - Agent Secrets

    private func loadAgentSecrets() {
        let stored = AgentSecretsKeychain.getAllSecrets(agentId: agent.id)
        agentSecrets =
            stored
            .map { AgentSecretEntry(key: $0.key, value: $0.value, isNew: false) }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    private func addAgentSecret() {
        let entry = AgentSecretEntry(key: "", value: "", isNew: true)
        agentSecrets.append(entry)
        editingSecretEntryId = entry.id
    }

    private func commitAgentSecret(entryId: AgentSecretEntry.ID, key: String, value: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedKey.isEmpty, !trimmedValue.isEmpty else {
            withAnimation(.easeInOut(duration: 0.15)) {
                agentSecrets.removeAll { $0.id == entryId }
            }
            editingSecretEntryId = nil
            return
        }

        if let existing = agentSecrets.first(where: { $0.id == entryId }),
            !existing.isNew, existing.key != trimmedKey
        {
            AgentSecretsKeychain.deleteSecret(id: existing.key, agentId: agent.id)
        }

        AgentSecretsKeychain.saveSecret(trimmedValue, id: trimmedKey, agentId: agent.id)

        if let idx = agentSecrets.firstIndex(where: { $0.id == entryId }) {
            agentSecrets[idx] = AgentSecretEntry(key: trimmedKey, value: trimmedValue, isNew: false)
        }
        editingSecretEntryId = nil
    }

    private func deleteAgentSecret(entryId: AgentSecretEntry.ID, key: String) {
        if !key.isEmpty {
            AgentSecretsKeychain.deleteSecret(id: key, agentId: agent.id)
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            agentSecrets.removeAll { $0.id == entryId }
        }
        if editingSecretEntryId == entryId {
            editingSecretEntryId = nil
        }
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
            chatGreeting: {
                let trimmed = chatGreetingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }(),
            chatSubtitle: {
                let trimmed = chatSubtitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }(),
            isBuiltIn: false,
            createdAt: agent.createdAt,
            updatedAt: Date(),
            agentIndex: current.agentIndex,
            agentAddress: current.agentAddress,
            autonomousExec: current.autonomousExec,
            pluginInstructions: effectivePluginInstructions,
            bonjourEnabled: current.bonjourEnabled,
            toolSelectionMode: current.toolSelectionMode,
            manualToolNames: current.manualToolNames,
            manualSkillNames: current.manualSkillNames,
            toolsEnabled: toolsEnabled,
            memoryEnabled: memoryEnabled,
            avatar: avatar,
            customAvatarFilename: current.customAvatarFilename,
            autoSpeak: autoSpeak ? true : nil,
            ttsVoice: ttsVoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : ttsVoice,
            settings: AgentSettings(
                dbEnabled: dbEnabled,
                schedule: current.settings.schedule,
                limits: current.settings.limits,
                generativeGreetingsEnabled: generativeGreetingsEnabled,
                greetingPersona: {
                    // Collapse an unedited inherited default back to
                    // nil so the agent stays in "inherit from global"
                    // mode — that way upstream persona / built-in
                    // changes still flow through. Trim before
                    // comparison so trailing whitespace from the
                    // editor doesn't accidentally diverge.
                    let trimmed = greetingPersona.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { return nil }
                    let inheritedTrimmed =
                        resolvedPersonaDefault
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed == inheritedTrimmed ? nil : trimmed
                }(),
                renderChartEnabled: renderChartEnabled,
                speakEnabled: speakEnabled,
                searchMemoryEnabled: searchMemoryEnabled,
                selfSchedulingEnabled: selfSchedulingEnabled,
                computerUseEnabled: computerUseEnabled,
                computerUseCeiling: computerUseEnabled ? computerUseCeiling : nil,
                screenContextEnabled: screenContextEnabled,
                spawnDelegationEnabled: spawnDelegationEnabled,
                imageEnabled: imageEnabled,
                // AppleScript enable + model + execution mode, declared right
                // after imageEnabled to match the AgentSettings initializer's
                // parameter order. Persist unconditionally (like the image
                // fields): a stored choice is ignored while the capability is
                // off, so a toggle round-trip keeps the user's pick.
                appleScriptEnabled: appleScriptEnabled,
                appleScriptModelId: appleScriptModelId,
                appleScriptExecutionMode: appleScriptExecutionMode,
                // Persist the allow-lists only while spawn is on, so toggling
                // spawn off doesn't silently retain a stale target list. The
                // model notes are pruned to the surviving model pool so a removed
                // model never leaves a dangling note.
                spawnableAgentNames: spawnDelegationEnabled ? spawnableAgentNames : [],
                spawnableModelNames: spawnDelegationEnabled
                    ? SubagentConfiguration.normalizedSpawnableModelNames(spawnableModelNames)
                    : [],
                spawnableModelNotes: spawnDelegationEnabled
                    ? SubagentConfiguration.normalizedSpawnableModelNotes(
                        spawnableModelNotes,
                        names: SubagentConfiguration.normalizedSpawnableModelNames(spawnableModelNames)
                    )
                    : [:],
                // Image models / permissions / budgets persist unconditionally —
                // a stored model id is ignored while the capability is off, so a
                // toggle round-trip keeps the user's choices (unlike the spawn
                // allow-list, which gates tool visibility).
                imageGenerationModelId: imageGenerationModelId,
                imageEditModelId: imageEditModelId,
                subagentPermissions: subagentPermissions,
                subagentBudgets: subagentBudgets,
                subagentModelOverrides: subagentModelOverrides,
                spawnToolAccess: spawnToolAccess
            ),
            order: current.order
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

// MARK: - Agent Detail Voice Section

/// Auto-speak toggle + per-agent voice override. Owns the
/// `TTSService.shared` observation so high-frequency model-state
/// updates don't invalidate the whole `AgentDetailView` body.
private struct AgentDetailVoiceSection: View {
    @ObservedObject private var ttsService = TTSService.shared
    let theme: ThemeProtocol
    @Binding var autoSpeak: Bool
    @Binding var ttsVoice: String
    let onSave: () -> Void

    var body: some View {
        AgentDetailSection(title: L("Voice"), icon: "speaker.wave.2") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto Speak Responses", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                        Text(
                            ttsService.isModelReady
                                ? "Read every reply aloud automatically after streaming completes. For on-request only, use the Speak Tool feature instead."
                                : "Download the PocketTTS model in Voice settings to enable.",
                            bundle: .module
                        )
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                    }
                    Spacer()
                    Toggle("", isOn: $autoSpeak)
                        .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                        .labelsHidden()
                        .disabled(!ttsService.isModelReady)
                        .onChange(of: autoSpeak) { onSave() }
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

                if !ttsService.isModelReady {
                    Button {
                        NotificationCenter.default.post(
                            name: .openTTSSettingsRequested,
                            object: nil
                        )
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Open Voice Settings", bundle: .module)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                if autoSpeak && ttsService.isModelReady {
                    HStack {
                        Text("Voice", bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                        Spacer()
                        Picker("", selection: $ttsVoice) {
                            Text("Default (global)", bundle: .module).tag("")
                            ForEach(agentVoiceOptions, id: \.self) { voice in
                                Text(PocketTTSVoiceCatalog.displayName(for: voice))
                                    .tag(voice)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(MenuPickerStyle())
                        .frame(maxWidth: 200)
                        .onChange(of: ttsVoice) { onSave() }
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
        .onAppear { ttsService.refreshModelState() }
    }

    /// Built-in catalog plus any stored custom voice (preserves legacy values).
    private var agentVoiceOptions: [String] {
        let builtIn = PocketTTSVoiceCatalog.availableVoices
        let current = ttsVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty && !builtIn.contains(current) {
            return [current] + builtIn
        }
        return builtIn
    }
}

// MARK: - Agent Detail Relay Section

/// Relay tunnel toggle + live status badge. Localizes
/// `RelayTunnelManager.shared` observation so per-second tunnel
/// ticks don't invalidate `AgentDetailView`.
private struct AgentDetailRelaySection: View {
    @ObservedObject private var relayManager = RelayTunnelManager.shared
    let theme: ThemeProtocol
    let agentId: UUID
    let agentAddress: String?
    @Binding var showRelayConfirmation: Bool
    @Binding var copiedRelayURL: Bool

    var body: some View {
        let status = relayManager.agentStatuses[agentId] ?? .disconnected
        let isEnabled = relayManager.isTunnelEnabled(for: agentId)

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
                        if let address = agentAddress {
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
                                .localizedHelp("Copy relay URL")
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
                                    relayManager.setTunnelEnabled(false, for: agentId)
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
}

// MARK: - Agent Relay Base URL Provider

/// Resolves the agent's live `<base>/plugins/<pid>` tunnel URL
/// (or `nil` when disconnected) and hands it to `content`. Used by
/// `pluginRoutesCard` to keep the relay observation off the parent.
private struct AgentRelayBaseURLProvider<Content: View>: View {
    @ObservedObject private var relayManager = RelayTunnelManager.shared
    let agentId: UUID
    let pluginId: String
    @ViewBuilder let content: (String?) -> Content

    var body: some View {
        let tunnelBaseURL: String? = {
            if case .connected(let baseURL) = relayManager.agentStatuses[agentId] {
                return "\(baseURL)/plugins/\(pluginId)"
            }
            return nil
        }()
        content(tunnelBaseURL)
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

// MARK: - Remote Connections (host side)

/// A single peer/grant row in the host-side "Remote Connections" tab. Backed
/// either by a minted agent-scoped access key (a LAN pairing or a redeemed
/// relay invite) or by a still-pending relay invite that hasn't been redeemed
/// into a key yet. `internal` (not file-private) so the pure assembly in
/// `RemoteConnectionsModel` is unit-testable.
struct ConnectionRow: Identifiable, Equatable {
    enum Status: Equatable {
        case active
        /// LAN pairing key that lives only for this app session
        /// (`TemporaryPairedKeyStore`).
        case temporary
        case expired
        case revoked
        /// Issued relay invite that nobody has redeemed yet — no key exists.
        case pending
    }

    /// Stable id — `key-<uuid>` for minted keys, `invite-<nonce>` for pending
    /// invites — so SwiftUI keeps row identity stable across reloads.
    let id: String
    let title: String
    let status: Status
    let createdAt: Date?
    let expiresAt: Date?
    /// Key nonce used to attribute inbound Insights rows. `nil` for pending
    /// invites (no key minted until redemption).
    let accessKeyNonce: String?
    /// Revoke target — exactly one of these is set per row.
    let keyId: UUID?
    let inviteNonce: String?

    var canRevoke: Bool {
        switch status {
        case .active, .temporary, .pending: return true
        case .expired, .revoked: return false
        }
    }
}

/// Pure assembly for the host-side Remote Connections list. Kept free of any
/// singletons or `@MainActor` UI state so the merge / status-mapping contract
/// (revoked → `.revoked`, expired → `.expired`, temporary LAN keys →
/// `.temporary`, unredeemed invites → `.pending`) is unit-testable. The live
/// view feeds it `APIKeyManager` keys, `AgentInviteStore` invites, and a
/// `TemporaryPairedKeyStore` predicate.
enum RemoteConnectionsModel {
    static func rows(
        keys: [AccessKeyInfo],
        invites: [IssuedInviteRecord],
        isTemporary: (UUID) -> Bool
    ) -> [ConnectionRow] {
        var result: [ConnectionRow] = []

        for key in keys.sorted(by: { $0.createdAt > $1.createdAt }) {
            let status: ConnectionRow.Status
            if key.revoked {
                status = .revoked
            } else if key.isExpired {
                status = .expired
            } else if isTemporary(key.id) {
                status = .temporary
            } else {
                status = .active
            }
            result.append(
                ConnectionRow(
                    id: "key-\(key.id.uuidString)",
                    title: key.label,
                    status: status,
                    createdAt: key.createdAt,
                    expiresAt: key.expiresAt,
                    accessKeyNonce: key.nonce,
                    keyId: key.id,
                    inviteNonce: nil
                )
            )
        }

        // Still-pending relay invites: issued, not yet redeemed (no key), and
        // not past expiry. Redeemed invites already appear above as their
        // minted key, so only surface the ones that haven't connected yet.
        for invite in invites
        where invite.displayStatus == .active && invite.accessKeyId == nil {
            result.append(
                ConnectionRow(
                    id: "invite-\(invite.nonce)",
                    title: L("Pending invite · \(String(invite.nonce.prefix(8)))…"),
                    status: .pending,
                    createdAt: invite.issuedAt,
                    expiresAt: invite.expirationDate,
                    accessKeyNonce: nil,
                    keyId: nil,
                    inviteNonce: invite.nonce
                )
            )
        }

        return result
    }
}

/// Owner-side view of who can reach a shared agent: the granted keys / invites,
/// their inbound usage (attributed via `RequestConnectionInfo.accessKeyId`), and
/// a per-peer Revoke. Gates itself to agents that have a shareable identity.
@MainActor
private struct AgentConnectionsSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var insights = InsightsService.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    let agent: Agent

    @State private var rows: [ConnectionRow] = []
    @State private var revokeConfirm: ConnectionRow?

    var body: some View {
        Group {
            if agent.agentAddress == nil {
                notShareableState
            } else if rows.isEmpty {
                noConnectionsState
            } else {
                connectionsList
            }
        }
        .onAppear(perform: reload)
        // Inbound attribution shows up as new Insights rows; the debounced
        // `totalRequestCount` is the cheapest "something changed" signal to
        // re-summarize per-key usage without polling.
        .onChange(of: insights.totalRequestCount) { _, _ in reload() }
        .onChange(of: agent.id) { _, _ in reload() }
        .themedAlert(
            L("Revoke access?"),
            isPresented: Binding(
                get: { revokeConfirm != nil },
                set: { if !$0 { revokeConfirm = nil } }
            ),
            message: revokeConfirm.map(revokeMessage(for:)) ?? "",
            primaryButton: .destructive(L("Revoke")) {
                if let target = revokeConfirm { revoke(target) }
                revokeConfirm = nil
            },
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    // MARK: States

    private var notShareableState: some View {
        AgentDetailSection(title: L("Remote Connections"), icon: "person.2.badge.key") {
            AgentSectionEmptyState(
                icon: "person.crop.circle.badge.xmark",
                title: "Not shared yet",
                hint:
                    "This agent has no shareable identity. Pair it over your network or generate a relay invite from the header Share button, then connected peers will appear here."
            )
        }
    }

    private var noConnectionsState: some View {
        AgentDetailSection(title: L("Remote Connections"), icon: "person.2.badge.key") {
            AgentSectionEmptyState(
                icon: "antenna.radiowaves.left.and.right.slash",
                title: "No connections yet",
                hint:
                    "Peers you pair with — or who redeem an invite to this agent — show up here with their usage and a way to revoke access."
            )
        }
    }

    private var connectionsList: some View {
        AgentDetailSection(title: L("Remote Connections"), icon: "person.2.badge.key") {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "Peers granted access to this agent. Revoking takes effect immediately.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)

                ForEach(rows) { row in
                    connectionRow(row)
                }
            }
        }
    }

    // MARK: Row

    @ViewBuilder
    private func connectionRow(_ row: ConnectionRow) -> some View {
        let activity = row.accessKeyNonce.map { insights.activity(forAccessKeyId: $0) }
        HStack(spacing: 10) {
            statusBadge(for: row.status)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                metaLine(row)

                if let activity, !activity.isEmpty {
                    usageLine(activity)
                } else if row.status == .pending {
                    Text("Waiting to be redeemed", bundle: .module)
                        .font(.system(size: 9))
                        .foregroundColor(theme.tertiaryText)
                } else {
                    Text("No requests yet", bundle: .module)
                        .font(.system(size: 9))
                        .foregroundColor(theme.tertiaryText)
                }
            }

            Spacer(minLength: 8)

            if activity?.isEmpty == false {
                Button {
                    viewInInsights(row)
                } label: {
                    HStack(spacing: 4) {
                        Text("Insights", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(theme.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .localizedHelp("View this connection's requests in Insights")
            }

            if row.canRevoke {
                Button {
                    revokeConfirm = row
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                        Text("Revoke", bundle: .module)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(theme.errorColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .localizedHelp("Revoke this peer's access")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground.opacity(0.5))
        )
    }

    private func metaLine(_ row: ConnectionRow) -> some View {
        HStack(spacing: 6) {
            if let created = row.createdAt {
                Text(
                    "Added \(created.formatted(date: .abbreviated, time: .omitted))",
                    bundle: .module
                )
            }
            if let expires = row.expiresAt {
                Text(verbatim: "·")
                Text(
                    "Expires \(expires.formatted(date: .abbreviated, time: .omitted))",
                    bundle: .module
                )
            } else if row.status != .pending {
                Text(verbatim: "·")
                Text("No expiry", bundle: .module)
            }
        }
        .font(.system(size: 9))
        .foregroundColor(theme.tertiaryText)
        .lineLimit(1)
    }

    private func usageLine(_ activity: ConnectionActivitySummary) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 8))
            Text("\(activity.requestCount) requests", bundle: .module)
            if let last = activity.lastUsed {
                Text(verbatim: "·")
                Text(
                    "Last \(last.formatted(.relative(presentation: .named)))",
                    bundle: .module
                )
            }
            if activity.averageSpeed > 0 {
                Text(verbatim: "·")
                Text(verbatim: String(format: "%.0f tok/s", activity.averageSpeed))
            }
        }
        .font(.system(size: 9))
        .foregroundColor(theme.secondaryText)
        .lineLimit(1)
    }

    private func statusBadge(for status: ConnectionRow.Status) -> some View {
        let (color, label, icon): (Color, String, String) = {
            switch status {
            case .active:
                return (theme.successColor, L("Active"), "checkmark.circle.fill")
            case .temporary:
                return (theme.accentColor, L("Temporary"), "clock.arrow.circlepath")
            case .pending:
                return (theme.warningColor, L("Pending"), "hourglass")
            case .expired:
                return (theme.tertiaryText, L("Expired"), "clock.badge.xmark.fill")
            case .revoked:
                return (theme.errorColor, L("Revoked"), "xmark.circle.fill")
            }
        }()
        return HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8))
            Text(label).font(.system(size: 9, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: Behaviour

    private func reload() {
        guard let address = agent.agentAddress else {
            rows = []
            return
        }
        rows = RemoteConnectionsModel.rows(
            keys: APIKeyManager.shared.listKeys(forAudience: address),
            invites: AgentInviteStore.list(for: agent.id),
            isTemporary: { TemporaryPairedKeyStore.shared.isTemporary(id: $0) }
        )
    }

    private func revoke(_ row: ConnectionRow) {
        if let keyId = row.keyId {
            // Mark revoked (keep the row so it flips to a "Revoked" badge and
            // preserves the audit trail) — takes effect immediately via the
            // validator epoch bump inside `revoke(id:)`.
            APIKeyManager.shared.revoke(id: keyId)
        } else if let nonce = row.inviteNonce {
            // Revoking an invite removes it from the ledger and, if it had
            // already minted a key, revokes that key too.
            let linkedKeyId = AgentInviteStore.revoke(nonce: nonce, for: agent.id)
            if let linkedKeyId {
                APIKeyManager.shared.revoke(id: linkedKeyId)
            }
        }
        reload()
    }

    /// Copy varies with what the peer is mid-flight: an active grant cuts a
    /// live connection, a pending invite just stops the link from working.
    private func revokeMessage(for row: ConnectionRow) -> String {
        switch row.status {
        case .pending:
            return L("The invite link will stop working. Anyone trying to use it will be turned away.")
        default:
            return L("This peer will lose access immediately. Their access key will be revoked.")
        }
    }

    private func viewInInsights(_ row: ConnectionRow) {
        if let nonce = row.accessKeyNonce {
            _ = InsightsService.shared.focus(accessKeyId: nonce)
        }
        ManagementStateManager.shared.selectedTab = .insights
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
    @State private var selectedAvatar: String? = nil
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
                            .frame(width: 500)
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
        .frame(width: 860, height: 580)
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
                avatarField
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
                    .lineLimit(1)
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
                placeholder: L("e.g., Code Assistant"),
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

    private var avatarField: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentSheetSectionLabel("Avatar")
            HStack(spacing: 10) {
                avatarChip(mascotId: nil)
                ForEach(AgentMascot.allCases) { mascot in
                    avatarChip(mascotId: mascot.id)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func avatarChip(mascotId: String?) -> some View {
        let isSelected = selectedAvatar == mascotId
        return Button {
            selectedAvatar = mascotId
        } label: {
            AgentAvatarView(
                mascotId: mascotId,
                name: name,
                tint: agentColor,
                diameter: 36,
                monogramFontSize: 14,
                borderWidth: 1.5
            )
            .overlay(
                Circle()
                    .strokeBorder(
                        isSelected ? theme.accentColor : Color.clear,
                        lineWidth: 2
                    )
                    .padding(-3)
            )
        }
        .buttonStyle(.plain)
        .help(Text(mascotId.map { "Mascot: \($0)" } ?? "Initial", bundle: .module))
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
                .localizedHelp("Pick which tools and skills this agent can use")
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
            ? L("Loaded on demand from your enabled set.")
            : L("All enabled items are sent every turn.")
        return L("\(toolCount) tools and \(skillCount) skills enabled · \(modeBlurb)")
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
                AgentAvatarView(
                    mascotId: selectedAvatar,
                    name: name,
                    tint: agentColor,
                    diameter: 36
                )
                .animation(.spring(response: 0.3), value: name)
                .animation(.spring(response: 0.3), value: selectedAvatar)

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
            autonomousExec: AgentManager.sandboxDefaultAutonomousExec,
            toolSelectionMode: draftMode,
            manualToolNames: Array(draftToolNames),
            manualSkillNames: Array(draftSkillNames),
            avatar: selectedAvatar
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

// MARK: - Agent Secret Entry

fileprivate struct AgentSecretEntry: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var value: String
    var isNew: Bool
}

// MARK: - Agent Secret Row

fileprivate struct AgentSecretRow: View {
    let entry: AgentSecretEntry
    let isEditing: Bool
    let theme: ThemeProtocol
    let onCommit: (_ key: String, _ value: String) -> Void
    let onDelete: () -> Void
    let onStartEditing: () -> Void

    @State private var editKey: String = ""
    @State private var editValue: String = ""
    @State private var showValue = false
    @State private var isHovering = false

    private var isEditable: Bool { isEditing || entry.isNew }

    var body: some View {
        HStack(spacing: 10) {
            if isEditable {
                editableContent
            } else {
                readOnlyContent
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isHovering ? theme.primaryBackground.opacity(0.5) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .onAppear {
            editKey = entry.key
            editValue = entry.value
        }
    }

    // MARK: - Subviews

    private var editableContent: some View {
        HStack(spacing: 10) {
            secretField(placeholder: "SECRET_NAME", text: $editKey, weight: .medium, secure: false)
                .frame(maxWidth: 200)
            secretField(placeholder: L("value"), text: $editValue, secure: !showValue)
            visibilityButton
            iconButton("checkmark", color: .white, bg: theme.accentColor) {
                onCommit(editKey, editValue)
            }
            deleteButton
        }
    }

    private var readOnlyContent: some View {
        HStack(spacing: 10) {
            Text(entry.key)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .frame(maxWidth: 200, alignment: .leading)

            Group {
                if showValue {
                    Text(entry.value)
                        .foregroundColor(theme.secondaryText)
                } else {
                    Text(String(repeating: "\u{2022}", count: min(entry.value.count, 24)))
                        .foregroundColor(theme.tertiaryText)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1)

            Spacer()
            visibilityButton

            if isHovering {
                iconButton(
                    "pencil",
                    color: theme.secondaryText,
                    bg: theme.tertiaryBackground,
                    action: onStartEditing
                )
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                deleteButton
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
    }

    // MARK: - Field & Button Helpers

    @ViewBuilder
    private func secretField(
        placeholder: String,
        text: Binding<String>,
        weight: Font.Weight = .regular,
        secure: Bool
    ) -> some View {
        Group {
            if secure {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 12, weight: weight, design: .monospaced))
        .foregroundColor(theme.primaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.accentColor.opacity(0.4), lineWidth: 1)
                )
        )
    }

    private var visibilityButton: some View {
        iconButton(
            showValue ? "eye.slash.fill" : "eye.fill",
            color: theme.tertiaryText,
            bg: theme.tertiaryBackground
        ) { showValue.toggle() }
        .help(showValue ? Text(localized: "Hide value") : Text(localized: "Show value"))
    }

    private var deleteButton: some View {
        iconButton(
            "trash",
            color: theme.errorColor,
            bg: theme.errorColor.opacity(0.1),
            action: onDelete
        )
        .localizedHelp("Delete secret")
    }

    private func iconButton(
        _ icon: String,
        color: Color,
        bg: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(bg))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        AgentsView()
    }
#endif
