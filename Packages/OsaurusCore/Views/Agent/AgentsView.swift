import AppKit
import OsaurusRepository
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared Helpers


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
    @MainActor fileprivate static var navTransition: Animation { ThemeManager.shared.currentTheme.motion.quick }

    /// Two-column grid layout reused by the main agent grid and the
    /// "Paired Remote Agents" section in the empty state.
    @MainActor fileprivate static var gridColumns: [GridItem] {
        let gap = ThemeManager.shared.currentTheme.libraryGridGap
        return [GridItem(.flexible(minimum: 300), spacing: gap), GridItem(.flexible(minimum: 300), spacing: gap)]
    }

    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var remoteAgentManager = RemoteAgentManager.shared
    @ObservedObject private var managementState = ManagementStateManager.shared
    /// Drives the landing glow when a settings-search result targets this
    /// screen (`agents.*` anchors). Also observed so an open detail view pops
    /// back to the grid, where the anchored controls live.
    @ObservedObject private var highlightCoordinator = SettingsHighlightCoordinator.shared

    private var theme: any ThemeProtocol { themeManager.currentTheme }

    /// One-shot deep-link target: when set on construction (e.g. from the chat
    /// header's gear button), the matching local agent is opened in detail
    /// view as soon as the tab appears. Consumed exactly once via
    /// `consumedDeeplinkAgentId` so subsequent navigation back to the grid
    /// doesn't re-fire the auto-select.
    let deeplinkAgentId: UUID?

    @State private var selectedAgent: Agent?
    @State private var selectedRemoteAgentId: UUID?
    @State private var isReordering = false
    @State private var hasAppeared = false
    @State private var successMessage: String?
    @State private var consumedDeeplinkAgentId: UUID?
    /// Agents | Templates switch under the header.
    @State private var section: AgentsSection = .agents
    /// Template library sheets. `templateImportText` is non-nil while the
    /// import sheet is up (empty string = open on the paste field).
    @State private var templateImportText: String?
    /// Where an install link downloaded the import sheet's text from, and
    /// the registry listing it names; nil for files and pastes.
    @State private var templateImportSourceHost: String?
    @State private var templateImportRegistry: RegistryImportSource?
    @State private var templateSourceAgent: Agent?
    @State private var templateToRename: AgentTemplate?
    @State private var templateHistory: AgentTemplate?
    @ObservedObject private var templateStore = TemplateStore.shared
    /// What the Set Up Agent wizard is working on: a saved agent (Run
    /// Setup, first-open prompt) or a template draft (Use Template).
    @State private var setupSubject: AgentSetupSubject?
    @ObservedObject private var setupState = SetupStateStore.shared
    /// One-shot inner-tab target paired with an agent id, set by the
    /// `.agentDetailDeeplink` handler so the detail view opens on a specific
    /// tab (e.g. Subagents). Kept as the RAW deep-link string (not a resolved
    /// `DetailTab`) so legacy database-surface values like `data` / `views`
    /// survive to `AgentDetailView`, which maps them onto the Database
    /// workspace section. Applied at `AgentDetailView` construction so it
    /// survives a cold window open; matched on id so it only affects the
    /// deep-linked agent, and cleared on back.
    @State private var deeplinkTab: (agentId: UUID, tabRaw: String)?
    @ObservedObject private var creator = AgentCreatorController.shared
    @ObservedObject private var draftStore = AgentDraftStore.shared
    /// The agent the creator just made: its page opens with a ready banner.
    @State private var newlyCreatedAgentId: UUID?

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

    /// The New Agent creator covers the grid and any open detail page.
    private var showsCreator: Bool { creator.isShowing && creator.chat != nil }

    var body: some View {
        ZStack {
            if showsCreator, let chat = creator.chat {
                AgentCreatorPage(
                    chat: chat,
                    onBack: { withAnimation(Self.navTransition) { creator.hide() } },
                    onDiscard: { withAnimation(Self.navTransition) { creator.discard() } },
                    onCreated: { landOnCreatedAgent($0) }
                )
                .id(ObjectIdentifier(chat))
                .transition(.opacity)
            }

            if !showsCreator && detailAgent == nil && selectedRemoteAgentId == nil {
                gridContent
                    .transition(.opacity)
            }

            if !showsCreator, let agent = detailAgent {
                // `.id(agent.id)` below makes SwiftUI tear down + recreate the
                // detail view when the user switches agents, so all editable
                // state reloads via onAppear without manual onChange wiring.
                AgentDetailView(
                    agent: agent,
                    initialTab: deeplinkTab?.agentId == agent.id ? deeplinkTab?.tabRaw : nil,
                    isNewlyCreated: newlyCreatedAgentId == agent.id,
                    onDismissNewlyCreated: { withAnimation(theme.motion.standard) { newlyCreatedAgentId = nil } },
                    onBack: {
                        deeplinkTab = nil
                        newlyCreatedAgentId = nil
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

            if !showsCreator, let remoteId = selectedRemoteAgentId {
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
                        .padding(.bottom, theme.space.s16)
                }
                .zIndex(100)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.canvas)
        .environment(\.theme, theme)
        .sheet(
            isPresented: Binding(
                get: { templateImportText != nil },
                set: { if !$0 { closeTemplateImport() } }
            )
        ) {
            TemplateImportSheet(
                initialText: templateImportText ?? "",
                sourceHost: templateImportSourceHost,
                expectedKind: .agent,
                onImported: { template, bundled in
                    let registry = templateImportRegistry
                    closeTemplateImport()
                    showSuccess("Imported \"\(template.name)\"")
                    Self.countInstall(registry, bundled: bundled)
                },
                onCancel: { closeTemplateImport() }
            )
            .environment(\.theme, theme)
        }
        .sheet(item: $templateSourceAgent) { agent in
            SaveAgentTemplateSheet(
                agent: agent,
                onSaved: { template in
                    templateSourceAgent = nil
                    showSuccess("Saved template \"\(template.name)\"")
                    withAnimation(Self.navTransition) { section = .templates }
                },
                onShare: { template in
                    templateSourceAgent = nil
                    managementState.pendingTemplateShare = template.id
                },
                onCancel: { templateSourceAgent = nil }
            )
            .environment(\.theme, theme)
        }
        .sheet(item: $templateToRename) { template in
            RenameAgentTemplateSheet(template: template, onDone: { templateToRename = nil })
                .environment(\.theme, theme)
        }
        .sheet(item: $templateHistory) { template in
            TemplateVersionHistorySheet(templateID: template.id, onDone: { templateHistory = nil })
                .environment(\.theme, theme)
        }
        .sheet(item: $setupSubject) { subject in
            AgentSetupWizardView(
                subject: subject,
                onClose: { setupSubject = nil },
                onFinished: { agent in
                    if subject.isDraft {
                        showSuccess("Created \"\(agent.name)\"")
                        withAnimation(Self.navTransition) { section = .agents }
                    }
                }
            )
            .environment(\.theme, theme)
        }
        .onReceive(managementState.$pendingAgentSetupId) { pending in
            guard let pending else { return }
            managementState.pendingAgentSetupId = nil
            withAnimation(Self.navTransition) {
                selectedAgent = nil
                section = .agents
            }
            setupSubject = .saved(pending)
        }
        .onReceive(managementState.$pendingSetupSubject) { _ in
            resumeParkedSetupIfNeeded()
        }
        .sheet(isPresented: $isReordering) {
            AgentReorderSheet()
                .environment(\.theme, theme)
        }
        .onAppear {
            agentManager.refresh()
            withAnimation(theme.motion.standard.delay(0.05)) {
                hasAppeared = true
            }
            consumeDeeplinkIfPossible()
            applyPendingRemoteAgentDetail()
            applyPendingAgentDetail()
            // The wizard parks itself here when it sends the user to another
            // tab. Coming back rebuilds this view, so the publisher has
            // already fired by now and the value has to be read directly.
            resumeParkedSetupIfNeeded()
            consumePendingTemplateImport()
            routeSettingsLanding(highlightCoordinator.pending)
        }
        .onReceive(managementState.$pendingTemplateImport) { _ in consumePendingTemplateImport() }
        .onReceive(managementState.$pendingTemplateShare) { pending in
            // Templates mounts and opens Share for it.
            guard pending != nil else { return }
            withAnimation(Self.navTransition) {
                selectedAgent = nil
                selectedRemoteAgentId = nil
                section = .templates
            }
        }
        // A deep link or search landing that opens an agent steps the
        // creator aside; it waits under the Agents list.
        .onChange(of: selectedAgent?.id) { _, id in
            if id != nil, creator.isShowing { creator.hide() }
        }
        .onChange(of: selectedRemoteAgentId) { _, id in
            if id != nil, creator.isShowing { creator.hide() }
        }
        .onChange(of: agentManager.agents) { _, _ in
            // Agent list may load asynchronously after the view appears.
            consumeDeeplinkIfPossible()
            applyPendingAgentDetail()
        }
        .onChange(of: remoteAgentManager.remoteAgents) { _, _ in
            // Paired remote agents can load after the view appears; retry the
            // pending deep-link once the target record is known.
            applyPendingRemoteAgentDetail()
        }
        .onReceive(managementState.$pendingRemoteAgentDetailId) { _ in
            applyPendingRemoteAgentDetail()
        }
        .onReceive(managementState.$pendingAgentDetailId) { _ in
            applyPendingAgentDetail()
        }
        .onChange(of: highlightCoordinator.pending) { _, pending in
            routeSettingsLanding(pending)
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
            // Legacy database-surface raws (`data`, `views`, …) resolve via
            // `DetailTab.fromDeeplink`; the raw string is preserved so the
            // detail view can also recover the target workspace section.
            if let tabRaw = info["tab"] as? String,
                DetailTab.fromDeeplink(tabRaw) != nil
            {
                deeplinkTab = (agentId, tabRaw)
            }
            withAnimation(Self.navTransition) {
                selectedRemoteAgentId = nil
                selectedAgent = target
            }
        }
    }

    /// Settings-search landing router. Also invoked from `onAppear`: the
    /// coordinator publishes the id BEFORE the Management tab switches, so a
    /// cold-mounted Agents tab never sees the `onChange`.
    private func routeSettingsLanding(_ pending: String?) {
        guard let pending, pending.hasPrefix("agents.") else { return }
        if (pending == "agents.description" || AgentAdvancedSettingsLanding.matches(pending)),
            let target = detailAgent ?? customAgents.first
        {
            selectedRemoteAgentId = nil
            deeplinkTab = (target.id, "configure")
            selectedAgent = target
            NotificationCenter.default.post(
                name: .agentDetailDeeplink, object: nil,
                userInfo: ["agentId": target.id, "tab": "configure"]
            )
            return
        }
        if let tabRaw = Self.customAgentLandingTabRaw(for: pending) {
            // The Apple app groups and the skill allow-list live inside a
            // custom agent's Abilities → Tools picker, not on the grid: route into the
            // first custom agent's Tools tab (or keep the currently open
            // custom agent) so the anchored group can scroll and glow.
            // With no custom agent yet there is nothing to land on; the
            // grid's onboarding CTA is the right place to be.
            guard let target = Self.appleAppsLandingAgent(open: detailAgent, all: agentManager.agents) else {
                withAnimation(Self.navTransition) {
                    selectedAgent = nil
                    selectedRemoteAgentId = nil
                }
                return
            }
            deeplinkTab = (target.id, tabRaw)
            if detailAgent?.id == target.id {
                // Already mounted: the detail view flips its own tab via
                // the deeplink notification.
                NotificationCenter.default.post(
                    name: .agentDetailDeeplink, object: nil,
                    userInfo: ["agentId": target.id, "tab": tabRaw]
                )
            } else {
                withAnimation(Self.navTransition) {
                    selectedRemoteAgentId = nil
                    selectedAgent = target
                }
            }
            return
        }
        // Publishing rows land on the Templates page, where the cards and
        // their share sheet carry the anchors.
        if pending.hasPrefix("agents.templates.") {
            withAnimation(Self.navTransition) {
                selectedAgent = nil
                selectedRemoteAgentId = nil
                section = .templates
            }
            return
        }
        // Other settings-search landings target the grid (header /
        // agent cards); pop any open detail so the anchored control is
        // actually on screen to glow.
        withAnimation(Self.navTransition) {
            selectedAgent = nil
            selectedRemoteAgentId = nil
        }
    }

    /// Detail tab raw value the `agents.appleApps*` landings open.
    static let appleAppsLandingTabRaw = "capabilities"

    /// Detail tab a custom-agent-only landing opens, or nil for grid landings.
    static func customAgentLandingTabRaw(for pending: String) -> String? {
        if pending.hasPrefix("agents.appleApps") || pending == "agents.skills" { return appleAppsLandingTabRaw }
        if pending == "agents.workflows" { return "abilities" }
        if pending.hasPrefix("agents.sandbox.") { return "sandbox" }
        if pending == "agents.automation.recentTasks" { return "automation" }
        if pending == "agents.followUpSuggestions" { return "configure" }
        return nil
    }

    /// Which custom agent an `agents.appleApps*` settings-search landing
    /// should open: the custom agent already on screen, else the first
    /// custom (non-built-in) agent in display order. `nil` when there is no
    /// custom agent (the Default agent has no Apple app groups).
    static func appleAppsLandingAgent(open: Agent?, all: [Agent]) -> Agent? {
        if let open, !open.isBuiltIn { return open }
        return all.first { !$0.isBuiltIn }
    }

    // MARK: - Grid Content

    private var gridContent: some View {
        VStack(spacing: theme.space.s0) {
            headerView
                .settingsHeaderEntrance(hasAppeared: hasAppeared)
                .settingsLandingAnchor("agents.overview")

            if section == .templates {
                templatesContent
                    .transition(.opacity)
            } else if customAgents.isEmpty {
                // First-agent onboarding stays reachable as long as the user has no
                // *local* agents — even if they've already paired a remote agent.
                // That way the "Create Your First Agent" CTA never silently
                // disappears just because someone else's agent is sitting in the
                // grid. When both lists exist, we fall through to the normal grid.
                ScrollView {
                    SettingsPageContent {
                        unfinishedDraftRow
                        builtInAgentRows
                        SettingsEmptyState(
                            icon: "theatermasks.fill",
                            title: "Create Your First Agent",
                            subtitle: "Custom AI assistants with unique prompts, tools, and styles.",
                            examples: [
                                exampleAgent("calendar", L("Daily Planner"), L("Manage your schedule")),
                                exampleAgent("message.fill", L("Message Assistant"), L("Draft and send texts")),
                                exampleAgent("map.fill", L("Local Guide"), L("Find places nearby")),
                            ],
                            primaryAction: .init(
                                title: L("New Agent"),
                                icon: "plus",
                                handler: { AgentCreatorLauncher.open(source: .agentsPage) }
                            ),
                            hasAppeared: hasAppeared
                        )

                        if !remoteAgents.isEmpty {
                            remoteAgentsSection
                        }
                    }
                }
                .opacity(hasAppeared ? 1 : 0)
            } else {
                ScrollView {
                    SettingsPageContent {
                        unfinishedDraftRow
                        builtInAgentRows
                        LazyVGrid(columns: Self.gridColumns, spacing: theme.libraryGridGap) {
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
                                    onSaveTemplate: { templateSourceAgent = agent },
                                    needsSetup: setupState.needsSetup(agent.id),
                                    onRunSetup: { setupSubject = .saved(agent.id) },
                                    onDelete: { deleteAgent(agent) },
                                    onOpenDatabase: { openDatabase(for: agent) }
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
                        .gridDiffAnimation(token: gridChangeToken)
                        // Landing target for the "Agent Database" settings-search
                        // entry: the grid glows, and each card's Database
                        // status/menu shortcut is the direct entry point.
                        .settingsLandingAnchor("agents.database")
                    }
                }
                .opacity(hasAppeared ? 1 : 0)
            }
        }
    }

    /// After the creator's Create: the new agent's page, with the setup
    /// wizard over it when something still needs the person.
    /// An onboarding example that opens the creator already asked to build it.
    private func exampleAgent(_ icon: String, _ title: String, _ description: String) -> SettingsEmptyState.Example {
        .init(icon: icon, title: title, description: description) {
            AgentCreatorLauncher.open(brief: L("Make me a \(title) agent: \(description)."), source: .agentsPage)
        }
    }

    private func landOnCreatedAgent(_ agentId: UUID) {
        newlyCreatedAgentId = agentId
        withAnimation(Self.navTransition) {
            creator.finish()
            section = .agents
            selectedRemoteAgentId = nil
            selectedAgent = agentManager.agent(for: agentId)
        }
        if let agent = agentManager.agent(for: agentId), SetupChecker.check(agent).hasBlockers {
            setupSubject = .saved(agentId)
        }
    }

    /// "Continue" for a New Agent draft left unfinished, above the list.
    @ViewBuilder
    private var unfinishedDraftRow: some View {
        if let draft = creator.resumableDraft {
            let name = draft.agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
            HStack(spacing: theme.space.s12) {
                AgentAvatarView(
                    mascotId: draft.agent.avatar, name: name.isEmpty ? "?" : name,
                    tint: theme.dataInk(seed: name), diameter: 32)
                SettingsRowText {
                    Text(name.isEmpty ? L("Untitled agent") : name)
                } description: {
                    Text("A new agent in progress. Nothing is created until you click Create Agent.", bundle: .module)
                }
                Spacer(minLength: theme.space.s8)
                SettingsButton(.tertiary, L("Discard"), verbatim: true) {
                    withAnimation(theme.motion.standard) { creator.discard(draft) }
                }
                SettingsButton(.secondary, L("Continue"), icon: "arrow.right", verbatim: true) {
                    withAnimation(Self.navTransition) { creator.resume(draft) }
                }
            }
            .padding(theme.space.s12)
            .settingsChrome(.card)
            .transition(.opacity)
        }
    }

    /// Opens `agent`'s detail view directly on the Database workspace —
    /// the same routing a `tab: "database"` deep-link takes, so the card
    /// shortcut and notification paths stay consistent.
    private func openDatabase(for agent: Agent) {
        deeplinkTab = (agent.id, "database")
        withAnimation(Self.navTransition) {
            selectedRemoteAgentId = nil
            selectedAgent = agent
        }
    }

    /// Standalone "Paired Remote Agents" group rendered below the empty-state
    /// CTA when the user has zero local agents but does have remotes paired.
    /// Keeps remotes discoverable without obscuring the create-first-agent
    /// onboarding above.
    private var remoteAgentsSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            HStack(spacing: theme.space.s6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .glyphSize(.footnote, weight: .semibold)
                    .foregroundColor(theme.text.tertiary)
                SettingsFieldLabel("Paired Remote Agents")
                Spacer()
            }

            LazyVGrid(columns: Self.gridColumns, spacing: theme.libraryGridGap) {
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

    @ViewBuilder
    private var headerView: some View {
        let totalCount = customAgents.count + remoteAgents.count
        switch section {
        case .agents:
            SettingsPageHeader(
                title: "Agents",
                subtitle: "Create custom assistant personalities with unique behaviors",
                count: totalCount,
                onRefresh: { agentManager.refresh() },
                refreshHelp: "Refresh agents",
                utilities: {
                    if !customAgents.isEmpty {
                        SettingsIconButton("list.bullet.indent", help: "Reorder agents") {
                            isReordering = true
                        }
                    }
                },
                secondary: {
                    SettingsButton(.secondary, "Templates", icon: AgentsSection.templates.icon) {
                        withAnimation(Self.navTransition) { section = .templates }
                    }
                    .settingsLandingAnchor("agents.templates")
                },
                primary: {
                    SettingsButton(.primary, "New Agent", icon: "plus") {
                        AgentCreatorLauncher.open(source: .agentsPage)
                    }
                }
            )
        case .templates:
            SettingsPageHeader(
                title: "Templates",
                subtitle: "Start a new agent from a ready-made setup, or share yours as a file or a page",
                count: templateStore.allTemplates(kind: .agent).count,
                onRefresh: { templateStore.reload() },
                refreshHelp: "Refresh templates",
                primary: {
                    SettingsButton(.primary, "Add Template", icon: "plus", help: "Import Template") {
                        openTemplateImport("")
                    }
                }
            )
            .settingsBackDestination(L("Agents"), verbatim: true) {
                withAnimation(Self.navTransition) { section = .agents }
            }
        }
    }

    /// Orchestrator, Architect and Configurator, pinned above the agent grid,
    /// then the Delegation page they and every agent share.
    private var builtInAgentRows: some View {
        VStack(alignment: .leading, spacing: theme.settingsSectionGap) {
            ManagementChildLinks(
                parent: .agents, title: L("Built-in"), tabs: [.orchestrator, .architect, .configurator]
            )
            .settingsLandingAnchor("agents.builtIn")
            ManagementChildLinks(parent: .agents, title: L("Working Together"), tabs: [.delegation])
        }
    }

    /// Templates tab body. Using a template builds an unsaved draft through
    /// the same mapping `osaurus_config apply` uses and opens the Create
    /// Agent sheet prefilled; unresolved requirements ride along as notices.
    private var templatesContent: some View {
        AgentTemplatesView(
            columns: Self.gridColumns,
            hasAppeared: hasAppeared,
            onUse: { template in useTemplate(template) },
            onImport: { openTemplateImport("") },
            onImportText: { text in openTemplateImport(text) },
            onRename: { template in templateToRename = template },
            onVersionHistory: { template in templateHistory = template },
            showSuccess: showSuccess,
            showError: { message in _ = ToastManager.shared.error(L("Template"), message: message) }
        )
    }

    /// Use Template: open the setup wizard on an UNSAVED draft. The agent
    /// is created only when the wizard's Create Agent passes the readiness
    /// check, so a template this Mac cannot honour never yields a broken
    /// agent. The template's requested model stays on the draft even when it
    /// is missing, so the Brain step can show it instead of silently falling
    /// back; a `preferred` policy makes that step advisory.
    private func useTemplate(_ template: AgentTemplate) {
        var entry = template.resolvedEntry()
        if case .available = template.modelResolution() {} else if let requested = template.agent.model.valueOrNil {
            entry.model = .value(requested)
        }
        var draft = ConfigApplier.draftAgent(from: entry).agent
        // The applier attaches a folder only when it can mint a bookmark;
        // keep the author's path as a hint so the Working Folder step shows.
        if let hint = entry.workingFolder.valueOrNil, draft.workingFolderPath == nil {
            draft.workingFolderPath = (hint as NSString).expandingTildeInPath
        }
        if let actions = template.quickActions { draft.chatQuickActions = actions }
        // Lets the setup check find the template's MCP servers and plugins,
        // which add no tool names to the draft when missing here.
        draft.sourceTemplateName = template.name
        setupSubject = .draft(draft, template: template)
    }

    // MARK: - Success Toast

    private func showSuccess(_ message: String) {
        withAnimation(theme.motion.springAnimation) {
            successMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(theme.motion.quick) {
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
    /// Reopen a wizard that stepped aside for another tab, with whatever
    /// the user had already filled in.
    private func resumeParkedSetupIfNeeded() {
        guard case .agent(let parked)? = managementState.pendingSetupSubject else { return }
        managementState.pendingSetupSubject = nil
        withAnimation(Self.navTransition) {
            selectedAgent = nil
            section = .agents
        }
        setupSubject = parked
    }

    private func consumePendingTemplateImport() {
        guard let pending = managementState.pendingTemplateImport, pending.kind == .agent else { return }
        managementState.pendingTemplateImport = nil
        withAnimation(Self.navTransition) {
            selectedAgent = nil
            section = .templates
        }
        guard templateImportText != nil || setupSubject != nil else {
            openTemplateImport(pending.text, sourceHost: pending.sourceHost, registry: pending.registry)
            return
        }
        // One sheet at a time: close what is up, then open the import.
        closeTemplateImport()
        setupSubject = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            openTemplateImport(pending.text, sourceHost: pending.sourceHost, registry: pending.registry)
        }
    }

    private func openTemplateImport(
        _ text: String, sourceHost: String? = nil, registry: RegistryImportSource? = nil
    ) {
        templateImportSourceHost = sourceHost
        templateImportRegistry = registry
        templateImportText = text
    }

    private func closeTemplateImport() {
        templateImportText = nil
        templateImportSourceHost = nil
        templateImportRegistry = nil
    }

    /// Tells the registry an agent template from one of its links was
    /// added, the same signed receipt a workflow install sends, and credits
    /// the pages of the workflows it brought into the library.
    private static func countInstall(_ registry: RegistryImportSource?, bundled: [Template]) {
        guard let registry else { return }
        Task { @MainActor in
            let counted = await WorkflowShareService.shared.recordAgentInstall(registry, bundled: bundled)
            for (id, value) in counted {
                print("[WorkflowsRegistry] install receipt \(id.uuidString.lowercased()) counted=\(String(describing: value))")
            }
        }
    }

    private func applyPendingAgentDetail() {
        guard let pendingId = managementState.pendingAgentDetailId,
            let target = agentManager.agents.first(where: { $0.id == pendingId })
        else { return }
        managementState.pendingAgentDetailId = nil
        withAnimation(Self.navTransition) {
            selectedRemoteAgentId = nil
            selectedAgent = target
        }
    }

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
        // Belt and braces behind the card/detail gates: a shared agent must
        // be unshared in its workspace before it can go, or teammates are
        // left with a roster row nobody can reach.
        if let address = agent.agentAddress,
            !WorkspaceRosterStore.shared.workspacesSharing(agentAddress: address).isEmpty
        {
            ToastManager.shared.errorLocalized(
                "Agent is shared", message: "Unshare it from its workspace before deleting."
            )
            return
        }
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

        let duplicated = AgentManager.duplicateRecord(from: agent, name: newName)

        AgentStore.save(duplicated)
        agentManager.refresh()
        agentManager.registerInDefaultSpawnPool(duplicated)
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
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var rosterStore = WorkspaceRosterStore.shared
    private var eventManager = EventManager.shared

    let agent: Agent
    let isActive: Bool
    let animationDelay: Double
    let hasAppeared: Bool
    let onSelect: () -> Void
    let onDuplicate: () -> Void
    /// Snapshots the agent into the template library (Templates tab).
    let onSaveTemplate: () -> Void
    /// First-run setup still pending (`SetupStateStore`).
    var needsSetup: Bool = false
    /// Opens the Set Up Agent wizard for this agent.
    var onRunSetup: () -> Void = {}
    let onDelete: () -> Void
    /// Opens the agent's detail view directly on the Database workspace
    /// (Knowledge › Database) — surfaced in the card menu so users can jump
    /// straight to their agent's data without hunting through tabs.
    let onOpenDatabase: () -> Void

    init(
        agent: Agent,
        isActive: Bool,
        animationDelay: Double,
        hasAppeared: Bool,
        onSelect: @escaping () -> Void,
        onDuplicate: @escaping () -> Void,
        onSaveTemplate: @escaping () -> Void,
        needsSetup: Bool = false,
        onRunSetup: @escaping () -> Void = {},
        onDelete: @escaping () -> Void,
        onOpenDatabase: @escaping () -> Void
    ) {
        self.needsSetup = needsSetup
        self.onRunSetup = onRunSetup
        self.agent = agent
        self.isActive = isActive
        self.animationDelay = animationDelay
        self.hasAppeared = hasAppeared
        self.onSelect = onSelect
        self.onDuplicate = onDuplicate
        self.onSaveTemplate = onSaveTemplate
        self.onDelete = onDelete
        self.onOpenDatabase = onOpenDatabase
    }

    @State private var showDeleteConfirm = false
    @State private var showDeleteBlockedByShare = false

    private var agentColor: Color { theme.dataInk(seed: agent.name) }

    private var automationCount: Int { eventManager.eventCount(forAgentId: agent.id) }

    /// Number of explicitly-enabled tools. `nil` when the agent has never
    /// engaged the capability picker (legacy / fresh agent that uses the
    /// global registry implicitly), so the UI can read "all" instead of "0".
    private var enabledToolCount: Int? {
        agentManager.effectiveEnabledToolNames(for: agent.id)?.count
    }

    var body: some View {
        LibraryCard(
            title: agent.name,
            subtitle: agent.routingDescription.isEmpty ? L("No description") : agent.routingDescription,
            subtitleIsPlaceholder: agent.routingDescription.isEmpty,
            isSelected: isActive,
            animationDelay: animationDelay,
            hasAppeared: hasAppeared,
            action: onSelect
        ) {
            AgentAvatarView(
                mascotId: agent.avatar,
                name: agent.name,
                tint: agentColor,
                diameter: 36,
                customImageURL: agent.customAvatarURL
            )
        } badges: {
            if isActive {
                StatusChip(L("Active"), tone: .success)
            }
            if needsSetup {
                StatusChip(
                    L("Needs setup"),
                    tone: .warning,
                    help: L("Run Setup from the card menu to finish configuring this agent")
                )
            }
        } content: {
            LibraryCardPreview(text: agent.systemPrompt, placeholder: "No system prompt")
        } footer: {
            VStack(alignment: .leading, spacing: theme.space.s6) {
                // Provenance sits on its own line above the stats: that band
                // is the same width on every card, so a long template name
                // can neither crowd the agent name nor squeeze the stat chips.
                if let source = agent.sourceTemplateName, !source.isEmpty {
                    StatusChip(
                        L("From the \(source) template"),
                        tint: theme.status.info.foreground,
                        icon: "square.on.square.dashed",
                        help: L("Created from the \(source) template")
                    )
                }
                compactStats
            }
        } menu: {
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
            Button(action: onSaveTemplate) {
                Label {
                    Text("Save as Template", bundle: .module)
                } icon: {
                    Image(systemName: "square.on.square.dashed")
                }
            }
            Button(action: onRunSetup) {
                Label {
                    Text("Run Setup", bundle: .module)
                } icon: {
                    Image(systemName: "checklist")
                }
            }
            Button(action: onOpenDatabase) {
                Label {
                    Text("Open Database", bundle: .module)
                } icon: {
                    Image(systemName: "cylinder.split.1x2")
                }
            }
            Divider()
            Button(role: .destructive) {
                if sharedWorkspaces.isEmpty {
                    showDeleteConfirm = true
                } else {
                    showDeleteBlockedByShare = true
                }
            } label: {
                Label {
                    Text("Delete", bundle: .module)
                } icon: {
                    Image(systemName: "trash")
                }
            }
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
        .themedAlert(
            L("Agent is shared"),
            isPresented: $showDeleteBlockedByShare,
            message: String(
                format: L(
                    "\"%@\" is shared with %@. Unshare it from the workspace first, then delete it. Teammates lose access when it's unshared."
                ),
                agent.name,
                ListFormatter.localizedString(byJoining: sharedWorkspaces.map(\.name))
            ),
            primaryButton: sharedWorkspaces.count == 1
                ? .primary(L("Open workspace"), action: {
                    if let workspace = sharedWorkspaces.first {
                        RemoteAgentWorkspaceAttribution.openWorkspace(id: workspace.id)
                    }
                })
                : .primary(L("OK"), action: {}),
            secondaryButton: sharedWorkspaces.count == 1 ? .cancel(L("OK")) : nil
        )
    }

    /// Workspaces this agent is shared into; delete is refused while any.
    private var sharedWorkspaces: [OsaurusRouterWorkspaceSummary] {
        AgentSharedWithSection.sharedWorkspaces(for: agent, rosterStore: rosterStore)
    }

    // MARK: - Compact Stats

    private var compactStats: some View {
        LibraryStatRow(stats: buildStatChips())
    }

    private func buildStatChips() -> [LibraryStat] {
        var chips: [LibraryStat] = []

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

        // Automation: events targeting this agent, shown when non-zero.
        if automationCount > 0 {
            chips.append(.init(icon: "clock.badge.checkmark", text: "\(automationCount)"))
        }

        // Database: status chip when the agent has its private database
        // enabled. The card menu's "Open Database" jumps straight into the
        // workspace.
        if agent.settings.dbEnabled {
            chips.append(.init(icon: "cylinder.split.1x2", text: L("Database")))
        }

        // Updated: relative time so it stays meaningful at a glance.
        chips.append(
            .init(icon: "clock", text: agent.updatedAt.formatted(.relative(presentation: .named)))
        )

        return chips
    }
}

// MARK: - Detail Tab

private enum DetailTab: String, CaseIterable {
    case configure
    /// Abilities → Overview: every capability switch in one place, paired
    /// with a live estimated-startup-context readout. Owns the primary
    /// on/off state that used to live in Configure → Features; deep
    /// configuration stays in the specialist tabs it links to.
    case abilities
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
    /// This agent's channel messaging surface: a read-only summary of
    /// where it replies to incoming messages (reply routing is configured
    /// per channel, in Settings → Channels) plus the destinations where it
    /// may start new messages of its own.
    case channels
    case sandbox
    case automation
    case memory
    /// The Database workspace (spec §5.5 / §7): Overview, Tables, Saved
    /// Views, and History as sections inside ONE tab. Always visible —
    /// when `Agent.settings.dbEnabled` is off the workspace shows an
    /// explanatory empty state with an Enable action, so the feature
    /// stays discoverable. Legacy deep links (`home` / `schema` / `data`
    /// / `views` / `activity`) map onto this tab's sections via
    /// `AgentDetailTabRoute`.
    case database

    /// Tabs visible for `agent`, in canonical order. Every built-in tab
    /// is visible for every custom agent — the Database tab included,
    /// so the feature is discoverable even before it's switched on.
    static func allTabsForAgent(_ agent: Agent) -> [DetailTab] {
        DetailTab.allCases
    }

    /// Resolve a deep-link tab string, including the legacy per-surface
    /// database tab raw values (`home`, `schema`, `data`, `views`,
    /// `activity`) that older callers still post.
    static func fromDeeplink(_ raw: String) -> (tab: DetailTab, dbSection: AgentDatabaseSection?)? {
        guard let route = AgentDetailTabRoute.resolve(raw),
            let tab = DetailTab(rawValue: route.tabRawValue)
        else { return nil }
        return (tab, route.databaseSection)
    }

    var label: String {
        switch self {
        case .configure: return L("Configure")
        case .abilities: return L("Overview")
        case .capabilities: return L("Tools")
        case .subagents: return L("Subagents")
        case .customization: return L("Appearance")
        case .network: return L("Sharing")
        case .connections: return L("Guests")
        case .channels: return L("Channels")
        case .sandbox: return L("Sandbox")
        case .automation: return L("Automation")
        case .memory: return L("Memory")
        case .database: return L("Database")
        }
    }

    /// Title of the tab's page and of its row on the agent's main page.
    /// Sharing, Guests and Channels share one page.
    var pageTitle: String {
        switch self {
        case .abilities: return L("Abilities")
        case .network, .connections, .channels: return L("Sharing & Channels")
        case .automation: return L("Automations")
        default: return label
        }
    }

    var icon: String {
        switch self {
        case .configure: return "gear"
        case .abilities: return "switch.2"
        case .capabilities: return "wrench.and.screwdriver"
        case .subagents: return "person.2.wave.2"
        case .customization: return "paintpalette.fill"
        case .network: return "network"
        case .connections: return "person.2.badge.key"
        case .channels: return "bubble.left.and.bubble.right"
        case .sandbox: return "shippingbox"
        case .automation: return "clock.badge.checkmark"
        case .memory: return "brain.head.profile"
        case .database: return "cylinder.split.1x2"
        }
    }

    var helperText: String {
        switch self {
        case .configure: return L("Identity, model, and behavior overrides.")
        case .abilities:
            return L(
                "Everything this agent can do. Context impact updates as you turn abilities on or off."
            )
        case .capabilities:
            return L("Pick which tools this agent can use. Skills come from the shared library and are always available.")
        case .subagents:
            return L(
                "Let this agent delegate work — control your Mac, delegate tasks to other agents or models, or generate images."
            )
        case .customization: return L("Avatar, empty state, and visual theme.")
        case .network: return L("Remote access, the workspaces this agent is shared with, and its guests.")
        case .connections:
            return L("Guests who can reach this agent — usage and revocation.")
        case .channels:
            return L(
                "The channels this agent is on. Edit who answers and who may post under Channels."
            )
        case .sandbox: return L("Sandboxed code execution.")
        case .automation: return L("Automations that run this agent on their own — schedules, folders, webhooks and channel messages.")
        case .memory: return L("Conversation history, pinned facts, and episode summaries.")
        case .database:
            return L("Everything this agent stores — browse tables, saved views, and history.")
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var recentFolders = RecentFoldersStore.shared
    private let eventManager = EventManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    let agent: Agent
    let onBack: () -> Void
    let onDelete: (Agent) -> Void
    let onSwitchAgent: (Agent) -> Void
    /// Switch the detail pane to a paired remote agent (selected from the
    /// shared agent switcher). The parent flips its `selectedRemoteAgentId`.
    let onSwitchRemoteAgent: (UUID) -> Void
    let showSuccess: (String) -> Void
    /// Just made by the New Agent creator: a ready banner offers a chat.
    let isNewlyCreated: Bool
    let onDismissNewlyCreated: () -> Void

    init(
        agent: Agent,
        // Raw value of a `DetailTab` (file-private), kept stringly-typed so this
        // internal init — constructed cross-file (e.g. `MemoryView`) — doesn't
        // expose a private type. Deep-links already carry the tab as a raw
        // string; unknown values fall back to `.configure`.
        initialTab: String? = nil,
        isNewlyCreated: Bool = false,
        onDismissNewlyCreated: @escaping () -> Void = {},
        onBack: @escaping () -> Void,
        onDelete: @escaping (Agent) -> Void,
        onSwitchAgent: @escaping (Agent) -> Void,
        onSwitchRemoteAgent: @escaping (UUID) -> Void,
        showSuccess: @escaping (String) -> Void
    ) {
        self.agent = agent
        self.isNewlyCreated = isNewlyCreated
        self.onDismissNewlyCreated = onDismissNewlyCreated
        self.onBack = onBack
        self.onDelete = onDelete
        self.onSwitchAgent = onSwitchAgent
        self.onSwitchRemoteAgent = onSwitchRemoteAgent
        self.showSuccess = showSuccess
        // Seed the inner tab at construction so a deep-link (e.g. to the
        // Subagents tab) lands on the right tab even on a cold
        // window open, where a post-mount notification would race the view.
        // Legacy database-surface raws (`home` / `schema` / `data` / `views` /
        // `activity`) resolve to the Database tab plus a workspace section.
        let resolved = initialTab.flatMap(DetailTab.fromDeeplink)
        _selectedTab = State(initialValue: .builtIn(resolved?.tab ?? .configure))
        _pendingDatabaseSection = State(initialValue: resolved?.dbSection)
    }

    // MARK: - Editable State

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var systemPrompt: String = ""
    @State private var temperature: String = ""
    @State private var maxTokens: String = ""
    @State private var generationSettings: AgentGenerationSettings?
    @State private var claudeCodeConfig: ClaudeCodeAgentConfig = .default
    @State private var agentRuntime: AgentRuntime = .builtIn
    @ObservedObject private var harnessRuntimeStore = HarnessRuntimeStore.shared
    @State private var chatQuickActions: [AgentQuickAction]?
    @State private var editingQuickActionId: UUID?
    @State private var pluginInstructionsMap: [String: String] = [:]
    /// Positive-polarity local mirrors of `Agent.toolsEnabled` /
    /// `Agent.memoryEnabled` (default true). The Abilities overview cards
    /// bind directly; `saveAgent` folds them back into the persisted agent.
    @State private var toolsEnabled: Bool = true
    /// Turning a tool-backed ability on while Tools is off (or tapping its
    /// "Inactive while Tools is off" chip) scrolls to the Tools card and
    /// pulses the shared search-highlight glow on it, pointing at the
    /// master switch that unlocks the ability. The nonce keys the scroll;
    /// the generation counter lets a pulse's delayed auto-clear detect
    /// that a newer tap superseded it.
    @State private var scrollToToolsNonce = 0
    @State private var toolsHighlightActive = false
    @State private var toolsHighlightGeneration = 0
    @State private var memoryEnabled: Bool = true
    /// Local mirror of `Agent.settings.dbEnabled` (spec §5.5). The
    /// Abilities overview binds a card to this; `debouncedSave`
    /// folds it back into the persisted `AgentSettings` block.
    @State private var dbEnabled: Bool = false
    /// Local mirrors of the per-agent built-in tool gates
    /// (`render_chart` / `speak` / `search_memory`). The Abilities
    /// overview binds individual cards to these; `saveAgent` folds
    /// them back into the persisted `AgentSettings` block.
    @State private var renderChartEnabled: Bool = false
    /// Specialist (`calculate`, redaction pair) and agent-loop
    /// (`todo`+`complete`, `clarify`, `share_artifact`) tool gates.
    @State private var calculatorEnabled: Bool = false
    @State private var redactionToolsEnabled: Bool = false
    @State private var taskChecklistEnabled: Bool = true
    @State private var clarifyEnabled: Bool = true
    @State private var artifactsEnabled: Bool = true
    /// The working folder is read only (`AgentSettings.workingFolderReadOnly`).
    @State private var workingFolderReadOnly: Bool = false
    @State private var showResponseMetrics: Bool = false
    @State private var speakEnabled: Bool = false
    @State private var searchMemoryEnabled: Bool = false
    /// Native `web_search` gate — default ON (free providers need no setup).
    @State private var webSearchEnabled: Bool = true
    @State private var followUpEnabled: Bool = true
    /// Per-agent follow-up model override (only active while the global switch
    /// is on). Empty inherits the shared core model. Model-only by design — a
    /// per-agent suggester prompt would bust the chat model's KV cache.
    @State private var followUpModel: String = ""
    @State private var selfSchedulingEnabled: Bool = false
    /// Local mirrors of the knowledge feature (`AgentSettings.knowledgeEnabled`
    /// + collection grants). The Features section binds these; `saveAgent`
    /// folds them back into the persisted `AgentSettings` block.
    @State private var knowledgeEnabled: Bool = false
    @State private var knowledgeCollectionIds: [UUID] = []
    @State private var knowledgeCuratorEnabled: Bool = false
    /// Registry of knowledge collections for the grants checklist.
    @ObservedObject private var knowledgeManager = KnowledgeManager.shared
    /// Per-agent subagent capability toggles, keyed by the capability
    /// registry's `PerAgentFlag` (computer_use, spawn, image). Hydrated in
    /// `loadAgent` by looping the registry and folded back into `AgentSettings`
    /// in `saveAgent`, so adding a per-agent kind needs no new `@State` here.
    /// Custom agents only; the Subagents tab renders one card per flag.
    @State private var subagentToggles: [SubagentCapability.PerAgentFlag: Bool] = [:]
    /// Convenience reads over `subagentToggles` so the save path and the
    /// inline config rows keep their existing call sites.
    private var computerUseEnabled: Bool { subagentToggles[.computerUse] ?? false }
    private var browserUseEnabled: Bool { subagentToggles[.browserUse] ?? false }
    private var spawnDelegationEnabled: Bool { subagentToggles[.spawn] ?? false }
    private var imageEnabled: Bool { subagentToggles[.image] ?? false }
    private var videoEnabled: Bool { subagentToggles[.video] ?? false }
    private var appleScriptEnabled: Bool { subagentToggles[.appleScript] ?? false }
    /// Per-agent `spawn_agent` allow-list (which agents this agent may spawn).
    /// Mirrored from / into `AgentSettings.spawnableAgentIDs`; empty hides the
    /// `spawn_agent` tool.
    @State private var spawnableAgentIDs: [UUID] = []
    /// Per-agent shared workspace agents this agent may delegate to. Mirrored
    /// from / into `AgentSettings.spawnableWorkspaceAgents`.
    @State private var spawnableWorkspaceAgents: [WorkspaceAgentRef] = []
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
    @State private var imageGenerationTarget: MediaModelTarget? = nil
    @State private var imageEditModelId: String? = nil
    @State private var textToVideoTarget: MediaModelTarget? = nil
    @State private var imageToVideoTarget: MediaModelTarget? = nil
    /// Per-agent AppleScript model bundle id (`nil` resolves to the first
    /// installed catalog model at run time) and execution mode (confirm each
    /// script vs auto-run with a warning). Mirrored from / into
    /// `AgentSettings.appleScriptModelId` / `appleScriptExecutionMode`.
    @State private var appleScriptModelId: String? = nil
    @State private var appleScriptExecutionMode: AppleScriptExecutionMode = .default
    /// Per-agent delegation permissions (spawn / image) + spawn budgets. Mirrored
    /// from / into `AgentSettings`.
    @State private var subagentPermissions: SubagentPermissionDefaults = SubagentPermissionDefaults()
    /// Permission snapshot loaded into this editor. Live approval prompts can
    /// update AgentManager while the view remains open; save performs a
    /// three-way merge against this baseline so unrelated edits do not restore
    /// stale permission values.
    @State private var loadedSubagentPermissions: SubagentPermissionDefaults =
        SubagentPermissionDefaults()
    @State private var subagentBudgets: SubagentBudgets = SubagentBudgets()
    /// Per-agent subagent model overrides keyed by capability id (computer_use /
    /// spawn). Empty/absent = inherit the kind's default model.
    /// Mirrored from / into `AgentSettings.subagentModelOverrides`.
    @State private var subagentModelOverrides: [String: String] = [:]
    /// Read-only snapshot of the global `SubagentConfiguration`, loaded in
    /// `loadAgentData`. The shared Spawn editor uses it to surface the Local
    /// Orchestrator Handoff state while configuring an agent's spawn pool; the
    /// handoff toggle itself lives in Settings → Subagents.
    @State private var globalSubagentConfig: SubagentConfiguration = .default

    /// Custom agents keep their own token / turn / tool / elapsed budgets, but
    /// parallel fan-out is one shared Server + Spawn setting. The binding makes
    /// the shared value visible immediately and routes an explicit agent-editor
    /// change through the live Server controller before the debounced agent save.
    private var sharedSpawnBudgetsBinding: Binding<SubagentBudgets> {
        Binding(
            get: {
                SpawnBatchConcurrencyContract.applyingSharedLimit(
                    from: globalSubagentConfig,
                    to: subagentBudgets
                )
            },
            set: { newValue in
                let normalized = newValue.normalized
                let requested = normalized.maxParallelSpawns
                subagentBudgets = normalized

                let live = SubagentConfigurationStore.snapshot()
                guard
                    SpawnBatchConcurrencyContract.configuredLimit(for: live)
                        != requested
                else {
                    if globalSubagentConfig != live {
                        globalSubagentConfig = live
                    }
                    return
                }

                let saved = SubagentConfigurationStore.mutate { configuration in
                    configuration.budgets.maxParallelSpawns = requested
                }
                globalSubagentConfig = saved
                Task { @MainActor in
                    await ServerController.applyAgentSpawnBatchLimit(requested)
                }
            }
        )
    }
    /// Display mirror of `Agent.workingFolderPath`. Drives the Working Folder
    /// row so the selected folder updates immediately after the user
    /// picks/clears it (the persisted bookmark on
    /// `Agent.workingFolderBookmark` is the real grant). `nil` means the
    /// agent has no working folder.
    @State private var workingFolderPath: String? = nil
    /// One live startup-context estimate shared by every Abilities sub-tab.
    /// Specialist editors report local values here before persistence lands.
    @State private var abilityContextPreview: AgentAbilityContextPreview?
    @State private var abilityContextDelta: Int?
    @State private var abilityContextDeltaDismissTask: Task<Void, Never>?
    @State private var abilityPreviewToolMode: ToolSelectionMode?
    @State private var abilityPreviewToolNames: Set<String>?
    @State private var abilityPreviewAppleApps: Set<AppleApp>?
    @Environment(\.settingsLandingPending) private var settingsLandingPending
    @State private var renderedSettingsAnchors: Set<String> = []
    @State private var abilityPreviewAutonomousConfig: AutonomousExecConfig?
    @State private var abilityPreviewRegistryRevision = 0
    /// Editable mirror of `AutonomousExecConfig.sandboxAllowedDomains`
    /// (comma-joined). Committed (normalized + persisted) on submit.
    @State private var sandboxAllowedDomainsText: String = ""
    /// Manual override for `Agent.chatGreeting`. Empty-after-trim becomes
    /// `nil` on save so the chat empty state falls through to the
    /// time-of-day default.
    @State private var chatGreetingDraft: String = ""
    /// Manual override for `Agent.chatSubtitle`. Uses the same
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
    @State private var shareMenuPresenter = AssignedMenuPanelPresenter()
    /// Drives the Save as Template sheet from the share menu.
    @State private var showingSaveTemplateSheet: Bool = false

    /// Local UI state: which tabs the user has dropped into the "Advanced" disclosure
    /// of the Configure tab. Persists only for the lifetime of this view (intentional —
    /// the disclosure defaults to collapsed each time the agent is opened so the
    /// primary settings always greet the user first).
    @State private var showAdvancedSettings: Bool = false

    // MARK: - UI State

    @State private var selectedTab: AgentTab = .builtIn(.configure)
    /// Optional saved-view name to focus when the user lands on the
    /// Database workspace via the notification deep-link (spec §3.3).
    /// Passed through to `DatabaseWorkspaceView`, which uses it as an
    /// initial selection. Cleared back to `nil` once the user navigates
    /// elsewhere so re-entering the tab manually doesn't keep snapping
    /// back to the old view.
    @State private var pendingFocusedViewName: String? = nil
    /// Optional table name to pre-select when the user lands on the
    /// Database workspace via a `tableRef` deep-link. Same lifecycle
    /// as `pendingFocusedViewName`.
    @State private var pendingFocusedTableName: String? = nil
    /// Workspace section the Database tab should open on, resolved from
    /// the deep-link raw tab value (legacy `home` / `schema` / `data` /
    /// `views` / `activity` map to sections). Cleared once the user
    /// navigates away so manual re-entry lands on the default section.
    @State private var pendingDatabaseSection: AgentDatabaseSection? = nil
    @State private var saveIndicator: String?
    @State private var saveDebounceTask: Task<Void, Never>?
    @State private var showDeleteConfirm = false
    /// Delete was requested while the agent is shared with a workspace:
    /// explains that it has to be unshared first instead of confirming.
    @State private var showDeleteBlockedByShare = false
    /// Observed so the delete gate follows roster changes (share / unshare
    /// from anywhere).
    @ObservedObject private var rosterStore = WorkspaceRosterStore.shared
    @State private var copiedRouteURL: String?
    @State private var pickerItems: [ModelPickerItem] = []
    @State private var selectedModel: String?
    @State private var eventEditor: EventEditorRequest?
    @State private var pinnedFacts: [PinnedFact] = []
    @State private var episodes: [Episode] = []
    @State private var sessionTurnCounts: [UUID: Int] = [:]
    @State private var showAllSummaries = false
    @State private var isInitialLoadComplete = false

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

    /// Routes the "Delete All Data" confirmation to the window's alert host.
    @Environment(\.themedAlertScope) private var alertScope

    /// Per-agent slices of the cross-manager data this detail screen
    /// renders. Refreshed by `refreshDetailCaches()` so the body
    /// doesn't have to re-filter the source arrays on every publish.
    @State private var linkedEvents: [OsaurusEvent] = []
    @State private var chatSessions: [ChatSessionData] = []
    @State private var agentPlugins: [PluginManager.LoadedPlugin] = []
    @State private var agentFailedPlugins: [PluginManager.FailedPlugin] = []

    private var currentAgent: Agent {
        agentManager.agent(for: agent.id) ?? agent
    }

    private var agentColor: Color { theme.dataInk(seed: name) }

    /// Recompute the per-agent caches consumed by the tab strip and
    /// sub-sections. Called from `.onAppear`, `.onChange(of: agent.id)`,
    /// `loadedPluginsRefreshNonce` flips, and the `.eventsChanged`
    /// notification.
    private func refreshDetailCaches() {
        linkedEvents = eventManager.events(targeting: agent.id)
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

    /// The Tools picker hosts every Apple app group, so it is the landing
    /// target for the group row and for each per-app catalog row. One anchor
    /// id at a time (stacked `.id()`s would shadow each other): whichever
    /// `agents.appleApps*` id is pending, else the group id.
    private var appleAppsLandingAnchorId: String {
        if let pending = settingsLandingPending, pending.hasPrefix("agents.appleApps") {
            return pending
        }
        return "agents.appleApps"
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .builtIn(.capabilities):
            AgentCapabilityManagerView(
                agentId: agent.id,
                onDismiss: nil,
                onSelectionChanged: { mode, names, appleApps in
                    abilityPreviewToolMode = mode
                    abilityPreviewToolNames = names
                    abilityPreviewAppleApps = appleApps
                }
            )
                .environment(\.theme, themeManager.currentTheme)
                // Built-in Apple apps live in this picker (one group per
                // app); the `agents.appleApps[.<app>]` catalog rows land here.
                .settingsLandingAnchor(appleAppsLandingAnchorId)
                .id(selectedTab)
        case .builtIn(.database):
            DatabaseWorkspaceView(
                agentId: agent.id,
                isEnabled: dbEnabled,
                isRemoteProvider: isUsingRemoteProvider,
                initialSection: pendingDatabaseSection,
                initialTableName: pendingFocusedTableName,
                initialViewName: pendingFocusedViewName,
                isBundleBusy: isBundleBusy,
                onEnable: {
                    dbEnabled = true
                    debouncedSave()
                },
                onExportBundle: { beginBundleExport() },
                onImportBundle: { beginBundleImport() },
                onDeleteData: { showDeleteDBConfirmation = true }
            )
            .environment(\.theme, themeManager.currentTheme)
            .id(selectedTab)
        default:
            ScrollViewReader { proxy in
                ScrollView {
                    SettingsPageContent {
                        scrollableTabContent
                    }
                }
                .id(selectedTab)
                .animation(nil, value: selectedTab)
                .onPreferenceChange(SettingsLandingAnchorsKey.self) { anchors in
                    renderedSettingsAnchors = anchors
                    scrollToSettingsLanding(settingsLandingPending, proxy: proxy)
                }
                .onChange(of: settingsLandingPending) { _, pending in
                    scrollToSettingsLanding(pending, proxy: proxy)
                }
                .onAppear {
                    scrollToSettingsLanding(settingsLandingPending, proxy: proxy)
                }
                .onChange(of: scrollToToolsNonce) { _, _ in
                    withAnimation(theme.motion.standard) {
                        proxy.scrollTo(Self.toolsToggleScrollId, anchor: .center)
                    }
                }
            }
        }
    }

    /// Use the same rendered-anchor contract as SettingsPage. Expanding Advanced
    /// adds its anchors after navigation; wait for layout before positioning.
    private func scrollToSettingsLanding(_ id: String?, proxy: ScrollViewProxy) {
        guard let id, id.hasPrefix("agents."), renderedSettingsAnchors.contains(id) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(theme.motion.standard) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    /// Context is an Abilities-group status, not destination content. Keep the
    /// same compact control visible for built-in and plugin tabs in the group.
    private var isAbilitiesGroupSelected: Bool {
        switch selectedTab {
        case .builtIn(.abilities), .builtIn(.capabilities), .builtIn(.subagents),
            .builtIn(.sandbox), .plugin, .failedPlugin:
            return true
        default:
            return false
        }
    }

    private var bodyCore: some View {
        VStack(spacing: theme.space.s0) {
            detailHeaderBar

            if isNewlyCreated {
                newlyCreatedBanner
                    .padding(.horizontal, theme.settingsPageInset)
                    .padding(.bottom, theme.space.s12)
                    .transition(.opacity)
            }

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

            VStack(alignment: .leading, spacing: theme.space.s0) {
                // Capabilities + the Database workspace host their own
                // scrolling (NSTableView / NSOutlineView). Rendering them
                // directly — without the outer ScrollView the other tabs
                // share — keeps their tables flush and avoids nested
                // scrolling.
                tabContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.canvas)
        // No internal fade-in here: the parent's navigation transition
        // (spring slide + opacity) already animates this view's entrance. A
        // second easeOut opacity curve on top read as an inconsistent
        // "slide-then-fade", unlike the rest of the app's detail navigations.
        .onAppear {
            loadAgentData()
            loadMemoryData()
            selectedModel = currentAgent.defaultModel
            if AgentAdvancedSettingsLanding.matches(settingsLandingPending) {
                showAdvancedSettings = true
            }
            refreshDetailCaches()
            DispatchQueue.main.async {
                isInitialLoadComplete = true
            }
        }
        .task(id: abilityDraft) {
            await refreshAbilityContextPreview()
        }
        .onChange(of: settingsLandingPending) { _, pending in
            if AgentAdvancedSettingsLanding.matches(pending) {
                selectedTab = .builtIn(.configure)
                showAdvancedSettings = true
            }
        }
        .onDisappear {
            abilityContextDeltaDismissTask?.cancel()
        }
        .onChange(of: agent.id) { _, _ in
            refreshDetailCaches()
        }
        .onChange(of: currentAgent.defaultModel) { _, value in
            selectedModel = value
        }
        .onChange(of: currentAgent.temperature) { _, value in
            temperature = value.map { String($0) } ?? ""
        }
        .onChange(of: currentAgent.maxTokens) { _, value in
            maxTokens = value.map { String($0) } ?? ""
        }
        .onChange(of: currentAgent.generationSettings) { _, value in
            generationSettings = value
        }
        .onChange(of: loadedPluginsRefreshNonce) { _, _ in
            refreshDetailCaches()
        }
        .onReceive(NotificationCenter.default.publisher(for: .eventsChanged)) { _ in
            refreshDetailCaches()
        }
        // The subagent editor reads "Swap local models for subagents" from the shared
        // global store. Keep an already-open custom agent in sync when the
        // setting changes elsewhere, matching ConfigurationView's
        // notification-driven refresh instead of requiring the user to close
        // and reopen this detail view.
        .onReceive(
            NotificationCenter.default.publisher(for: .subagentConfigurationChanged)
        ) { _ in
            let latest = SubagentConfigurationStore.snapshot()
            if latest != globalSubagentConfig { globalSubagentConfig = latest }
            let synchronized = SpawnBatchConcurrencyContract.applyingSharedLimit(
                from: latest,
                to: subagentBudgets
            )
            if synchronized != subagentBudgets {
                subagentBudgets = synchronized
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
            // Tab + entity deep-link handler. Used by `NotifyTool` taps
            // (`tab: "views"`, `viewRef: ...`) and legacy database-surface
            // callers (`tab: "data"`, `tableRef: ...`). AgentsView selects
            // the right agent via the same notification; this handler just
            // flips the inner tab (mapping legacy raws onto the Database
            // workspace) and stashes the entity name for the destination
            // to pick up on first load.
            guard let info = note.userInfo,
                let targetId = info["agentId"] as? UUID,
                targetId == agent.id
            else { return }
            if let tabRaw = info["tab"] as? String,
                let resolved = DetailTab.fromDeeplink(tabRaw)
            {
                pendingFocusedViewName = info["viewRef"] as? String
                pendingFocusedTableName = info["tableRef"] as? String
                pendingDatabaseSection = resolved.dbSection
                selectedTab = .builtIn(resolved.tab)
            }
        }
        .onChange(of: selectedTab) { _, newValue in
            // Drop any leftover notification-driven focus when the
            // user navigates away from the Database workspace. The
            // focused-name state is set together with `selectedTab`
            // in the deeplink handler above so it survives the
            // transition into the workspace exactly once.
            if newValue != .builtIn(.database) {
                pendingFocusedViewName = nil
                pendingFocusedTableName = nil
                pendingDatabaseSection = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toolsListChanged)) { _ in
            loadedPluginsRefreshNonce &+= 1
            abilityPreviewRegistryRevision &+= 1
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
            // Attached at the body level (not inside a tab) because the
            // Delete Data action is triggered from the Database workspace
            // as well as legacy call sites.
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
                message: deleteAgentMessage,
                primaryButton: .destructive(L("Delete")) { onDelete(currentAgent) },
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
            .sheet(item: $eventEditor) { request in
                EventEditorSheet(
                    request: request,
                    onSave: { event in
                        eventManager.create(event)
                        eventEditor = nil
                        showSuccess("Created automation \"\(event.name)\"")
                    },
                    onCancel: { eventEditor = nil }
                )
                .environment(\.theme, themeManager.currentTheme)
            }
    }

    // MARK: - Detail Header Bar

    /// Compact identity bar: back, avatar + name + optional description, actions.
    /// Tapping the identity block opens the agent switcher popover; editing the
    /// name / description happens inside the Configure tab's Identity section.
    private var newlyCreatedBanner: some View {
        HStack(spacing: theme.space.s12) {
            Image(systemName: "checkmark.circle.fill")
                .glyphSize(.medium, weight: .semibold)
                .foregroundColor(theme.status.success.foreground)
            SettingsRowText {
                Text("\(currentAgent.name) is ready", bundle: .module)
            } description: {
                Text("Everything below can be changed any time.", bundle: .module)
            }
            Spacer(minLength: theme.space.s8)
            SettingsButton(.primary, L("Start Chatting"), icon: "bubble.left", verbatim: true) {
                ChatWindowManager.shared.openChat(withAgentId: agent.id)
                onDismissNewlyCreated()
            }
            SettingsIconButton("xmark", help: "Dismiss", size: .small, role: .tertiary) {
                onDismissNewlyCreated()
            }
        }
        .padding(theme.space.s12)
        .settingsChrome(.status(.success))
    }

    private var detailHeaderBar: some View {
        let parent = pageParent
        return SettingsPageHeader(
            title: parent == nil ? (name.isEmpty ? L("Untitled Agent") : name) : pageTitle(for: selectedTab),
            verbatimTitle: true,
            subtitle: parent == nil && !description.isEmpty ? description : nil,
            verbatimSubtitle: true,
            leading: {
                AgentHeaderAvatar(mascotId: avatar, name: name, tint: agentColor) {
                    showingAgentSwitcher = true
                }
                .popover(isPresented: $showingAgentSwitcher, arrowEdge: .bottom) {
                    agentSwitcherPopover
                }
            },
            status: {
                if let indicator = saveIndicator {
                    StatusChip(indicator, tone: .success, showsDot: true)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else if let source = currentAgent.sourceTemplateName, !source.isEmpty {
                    StatusChip(L("From the \(source) template"))
                        .help(L("Created from the \(source) template"))
                }
            },
            utilities: {
                SettingsIconButton("square.and.arrow.up", help: "Share Agent") { presentShareMenu() }
            },
            overflow: {
                Button(role: .destructive, action: { requestDelete() }) {
                    Label(L("Delete"), systemImage: "trash")
                }
            },
            toolbar: {
                if parent != nil, isAbilitiesGroupSelected {
                    AgentAbilityContextPreviewBar(
                        preview: abilityContextPreview,
                        delta: abilityContextDelta,
                        enabledCount: abilityFlagValues.filter { $0 }.count,
                        totalCount: abilityFlagValues.count
                    )
                }
            }
        )
        .settingsBackDestination(parent.map { pageTitle(for: $0) } ?? L("Agents"), verbatim: true) {
            if let parent { selectedTab = parent } else { onBack() }
        }
        .themedAlert(
            L("Agent is shared"),
            isPresented: $showDeleteBlockedByShare,
            message: deleteBlockedMessage,
            primaryButton: sharedWorkspaces.count == 1
                ? .primary(L("Open workspace"), action: {
                    if let workspace = sharedWorkspaces.first {
                        RemoteAgentWorkspaceAttribution.openWorkspace(id: workspace.id)
                    }
                })
                : .primary(L("OK"), action: {}),
            secondaryButton: sharedWorkspaces.count == 1 ? .cancel(L("OK")) : nil
        )
        .sheet(isPresented: $showingShareSheet) {
            ShareAgentSheet(agent: currentAgent)
                .environment(\.theme, themeManager.currentTheme)
        }
        .sheet(isPresented: $showingSaveTemplateSheet) {
            SaveAgentTemplateSheet(
                agent: currentAgent,
                onSaved: { template in
                    showingSaveTemplateSheet = false
                    showSuccess("Saved template \"\(template.name)\"")
                },
                onShare: { template in
                    showingSaveTemplateSheet = false
                    ManagementStateManager.shared.pendingTemplateShare = template.id
                },
                onCancel: { showingSaveTemplateSheet = false }
            )
            .environment(\.theme, themeManager.currentTheme)
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
            case .configure, .abilities, .capabilities, .subagents, .customization, .network,
                .connections, .channels, .sandbox, .database:
                return nil
            case .automation:
                let count = linkedEvents.count
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

    /// Where the back bar on a sub-page returns to: Tools, Subagents,
    /// Sandbox and plugins sit under Abilities; every other page sits under
    /// the agent's main page (Configure). `nil` on the main page.
    private var pageParent: AgentTab? {
        switch selectedTab {
        case .builtIn(.configure):
            return nil
        case .builtIn(.capabilities), .builtIn(.subagents), .builtIn(.sandbox), .plugin, .failedPlugin:
            return .builtIn(.abilities)
        case .builtIn:
            return .builtIn(.configure)
        }
    }

    private func pageTitle(for tab: AgentTab) -> String {
        switch tab {
        case .builtIn(.configure): return currentAgent.name
        case .builtIn(let detail): return detail.pageTitle
        case .plugin(let pid):
            return agentPlugins.first { $0.plugin.id == pid }?.plugin.manifest.name ?? pid
        case .failedPlugin(let pid):
            return agentFailedPlugins.first { $0.pluginId == pid }.map(failedPluginTabLabel(for:)) ?? pid
        }
    }

    private func navigationRow(_ tab: AgentTab, subtitle: String? = nil) -> some View {
        let icon: String
        let help: String
        var isWarning = false
        switch tab {
        case .builtIn(let detail):
            icon = detail.icon
            help = detail.helperText
        case .plugin:
            icon = "puzzlepiece.extension"
            help = L("Settings this plugin adds for this agent.")
        case .failedPlugin:
            icon = "exclamationmark.triangle.fill"
            help = L("This plugin failed to load. Open for details and Retry.")
            isWarning = true
        }
        return SettingsNavigationRow(
            icon: icon,
            title: pageTitle(for: tab),
            subtitle: subtitle ?? help,
            badge: tabBadgeCount(for: tab),
            badgeHighlight: isWarning
        ) {
            withAnimation(theme.motion.quick) { selectedTab = tab }
        }
    }

    /// The rows that close the agent's main page: one per sub-page.
    private var mainPageNavigationRows: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            SettingsSectionHeader(title: "More Settings")
            SettingsGroup {
                navigationRow(
                    .builtIn(.abilities),
                    subtitle: agentFailedPlugins.isEmpty
                        ? nil : L("A plugin for this agent failed to load.")
                )
                navigationRow(.builtIn(.customization))
                navigationRow(.builtIn(.network))
                navigationRow(.builtIn(.automation))
                navigationRow(.builtIn(.memory))
                navigationRow(.builtIn(.database))
            }
        }
    }

    /// Tools, Subagents, Sandbox and this agent's plugins, under Abilities.
    private var abilitiesSubpageRows: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            SettingsSectionHeader(title: "Configure")
            SettingsGroup {
                navigationRow(.builtIn(.capabilities))
                navigationRow(.builtIn(.subagents))
                navigationRow(.builtIn(.sandbox))
                ForEach(agentPlugins, id: \.plugin.id) { loaded in
                    navigationRow(.plugin(loaded.plugin.id))
                }
                ForEach(agentFailedPlugins, id: \.pluginId) { failed in
                    navigationRow(.failedPlugin(failed.pluginId))
                }
            }
        }
    }

    private func tabHelperText(_ text: String) -> some View {
        HStack(spacing: theme.space.s6) {
            Image(systemName: "info.circle")
                .glyphSize(.micro)
                .foregroundColor(theme.text.tertiary)
            Text(text)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.tertiary)
        }
        .padding(.bottom, theme.space.s4)
    }

    // MARK: - Tab Content

    /// Configure tab content. The Capabilities, Customization, and Network
    /// tabs handle their own concerns now, so this tab leads with the three
    /// fields that DEFINE an agent and tucks the rarely-touched knobs behind
    /// the Advanced disclosure.
    ///
    ///   PRIMARY: Identity, Model, System Prompt, Voice.
    ///   ADVANCED: Generation overrides (Temperature, Max Tokens) and the
    ///   Disable Tools / Disable Memory toggles.
    @ViewBuilder
    private var configureTabContent: some View {
        tabHelperText(DetailTab.configure.helperText)
        // Ordered by how often each is touched from the chat menu: model
        // right after identity, voice further down.
        identitySection
        runtimeSection
        switch selectedHarness {
        case nil:
            defaultModelSection
        case .resolved(let runtime) where runtime.kind == .claudeCode:
            claudeCodeSection
        case .resolved, .missing:
            EmptyView()
        }
        systemPromptSection
        voiceSection
        // Follow-up model override is a custom-agent lever; the Default agent
        // always uses the shared core model.
        if agent.id != Agent.defaultId {
            followUpSection
        }
        // The schedule-mode picker is configuration for the self-scheduling
        // feature, so it only appears once that capability is switched on
        // (the master toggle lives in Abilities → Overview). With it off
        // the agent has no scheduler tools, so the bounds picker would be
        // dead UI.
        if agent.id != Agent.defaultId, selfSchedulingEnabled {
            scheduleSection
        }
        advancedSettingsDisclosure
        mainPageNavigationRows
        deleteAllDataSection
    }

    /// Routed by `selectedTab` from the body. Capabilities is rendered
    /// directly (it has its own scroll); every other tab body is enumerated
    /// here so the outer ScrollView can wrap it uniformly.
    @ViewBuilder
    private var scrollableTabContent: some View {
        switch selectedTab {
        case .builtIn(.configure):
            configureTabContent
        case .builtIn(.abilities):
            abilitiesTabContent
        case .builtIn(.subagents):
            subagentsTabContent
        case .builtIn(.customization):
            customizationTabContent
        case .builtIn(.network), .builtIn(.connections), .builtIn(.channels):
            networkTabContent
            connectionsTabContent
            channelsTabContent
        case .builtIn(.sandbox):
            sandboxTabContent
        case .builtIn(.automation):
            automationTabContent
        case .builtIn(.memory):
            memoryTabContent
        case .builtIn(.database):
            // Routed at the body level outside the ScrollView (the
            // Database workspace hosts its own scrolling); the
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

    /// The background-generated routing summary, shown as the description
    /// field's placeholder while the user has not written their own. Read
    /// from the live record so a summary that lands while this pane is open
    /// appears without reopening it.
    private var generatedDescriptionPlaceholder: String? {
        guard AgentDescriptionPolicy.normalized(description).isEmpty,
            let live = agentManager.agent(for: agent.id),
            AgentDescriptionPolicy.normalized(live.description).isEmpty
        else { return nil }
        let generated = AgentDescriptionPolicy.normalized(live.generatedDescription ?? "")
        return generated.isEmpty ? nil : generated
    }

    /// Editable identity card — name, description, and "Created" footer. Lives at
    /// the top of the Configure tab now that the title bar's avatar/dropdown is
    /// dedicated to switching between agents.
    private var identitySection: some View {
        SettingsSection(title: "editor.section.identity") {
            VStack(alignment: .leading, spacing: theme.space.s10) {
                SettingsTextField(
                    placeholder: L("e.g., Code Assistant"),
                    text: $name,
                    icon: "textformat"
                )

                SettingsTextField(
                    placeholder: generatedDescriptionPlaceholder ?? L("Brief description (optional)"),
                    text: $description,
                    icon: "text.alignleft"
                )
                .accessibilityIdentifier("agent.description")
                .settingsLandingAnchor("agents.description")
                if generatedDescriptionPlaceholder != nil {
                    Text("Auto-generated from the system prompt; type to override.", bundle: .module)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                }

                HStack(spacing: theme.space.s6) {
                    Image(systemName: "calendar")
                        .glyphSize(.tiny, weight: .medium)
                        .foregroundColor(theme.text.tertiary)
                    Text(
                        "Created \(agent.createdAt.formatted(date: .abbreviated, time: .omitted))",
                        bundle: .module
                    )
                    .font(SettingsFont.chip)
                    .foregroundColor(theme.text.tertiary)
                }
                .padding(.top, theme.space.s2)
            }
            .onChange(of: name) { debouncedSave() }
            .onChange(of: description) { debouncedSave() }
        }
    }

    private var advancedSettingsDisclosure: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            Button {
                withAnimation(theme.motion.quick) {
                    showAdvancedSettings.toggle()
                }
            } label: {
                HStack(spacing: theme.space.s10) {
                    Image(systemName: "chevron.right")
                        .glyphSize(.micro, weight: .semibold)
                        .foregroundColor(theme.text.tertiary)
                        .rotationEffect(.degrees(showAdvancedSettings ? 90 : 0))

                    Image(systemName: "wrench.adjustable")
                        .glyphSize(.footnote, weight: .semibold)
                        .foregroundColor(theme.text.secondary)

                    Text("Advanced Settings", bundle: .module)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)

                    Text(advancedSummary)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)

                    Spacer()
                }
                .padding(.horizontal, theme.space.s12)
                .padding(.vertical, theme.space.s12)
                .settingsChrome(.surface)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvancedSettings {
                VStack(alignment: .leading, spacing: theme.space.s16) {
                    generationOverridesSection
                    if agent.id != Agent.defaultId {
                        AgentResponseMetricsToggle(isOn: $showResponseMetrics)
                            .onChange(of: showResponseMetrics) { debouncedSave() }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// Tiny one-line summary shown next to "Advanced Settings" so users can see at
    /// a glance whether anything in there is overridden. The capability toggles
    /// live on Abilities → Overview; this disclosure holds generation overrides
    /// and optional response metrics.
    private var advancedSummary: String {
        var parts: [String] = []
        if !temperature.isEmpty || !maxTokens.isEmpty || generationSettings?.isEmpty == false {
            parts.append("generation")
        }
        if showResponseMetrics { parts.append(L("response metrics")) }
        return parts.isEmpty ? L("Defaults") : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var customizationTabContent: some View {
        tabHelperText(DetailTab.customization.helperText)
        avatarSection
        emptyStateSection
    }

    /// Customization → Empty State. Provides user-authored Greeting, Message,
    /// and Action Bar controls.
    private var emptyStateSection: some View {
        SettingsSection(title: "Empty State") {
            manualEmptyStateBody
                .onChange(of: chatGreetingDraft) { debouncedSave() }
                .onChange(of: chatSubtitleDraft) { debouncedSave() }
        }
    }

    /// Manual side: Greeting / Message / Action Bar. The Action Bar's
    /// own group header (icon + label + Default/Custom badge + enable
    /// toggle, rendered by `quickActionsModeGroup`) is the only header
    /// — we no longer wrap it in an outer "Action Bar" Text since
    /// there's just one quick-actions block now that work mode is gone.
    private var manualEmptyStateBody: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            VStack(alignment: .leading, spacing: theme.space.s6) {
                Text("Greeting", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                SettingsTextField(
                    placeholder: L("Welcome back, friend"),
                    text: $chatGreetingDraft,
                    icon: "text.cursor"
                )
            }

            VStack(alignment: .leading, spacing: theme.space.s6) {
                Text("Message", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                SettingsTextField(
                    placeholder: L("How can I help today?"),
                    text: $chatSubtitleDraft,
                    icon: "text.cursor"
                )
            }

            actionBarBlock
        }
    }

    private var avatarSection: some View {
        SettingsSection(title: "Avatar") {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                HStack(spacing: theme.space.s10) {
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
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
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
                    .strokeBorder(theme.action.primary.default.background, lineWidth: theme.stroke.focus)
                    .padding(-3)
            )
            .overlay(alignment: .topTrailing) {
                Image(systemName: "xmark.circle.fill")
                    .glyphSize(.body, weight: .semibold)
                    .foregroundColor(theme.text.secondary)
                    .background(Circle().fill(theme.surface.canvas))
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
                    .fill(theme.surface.subtle)
                Circle()
                    .strokeBorder(theme.border.strong, style: StrokeStyle(lineWidth: theme.stroke.default, dash: [3, 3]))
                Image(systemName: "photo.badge.plus")
                    .glyphSize(.body, weight: .semibold)
                    .foregroundColor(theme.text.secondary)
            }
            .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .localizedHelp("Upload custom image")
    }

    @MainActor
    private func presentCustomAvatarPicker() {
        Task { @MainActor in
            guard let pngData = await AvatarImageImport.choosePNG() else { return }
            agentManager.setCustomAvatar(pngData, ext: "png", for: agent.id)
            // Bust the cache for this agent's avatar URL so the new bytes show
            // up immediately in inline chat + sidebar without an mtime race.
            if let updated = agentManager.agent(for: agent.id), let newURL = updated.customAvatarURL {
                AvatarImageCache.shared.invalidate(url: newURL)
            }
        }
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
                        isSelected ? theme.action.primary.default.background : Color.clear,
                        lineWidth: theme.stroke.focus
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
        if currentAgent.agentAddress != nil, currentAgent.agentIndex != nil {
            RemoteAccessSection(agentId: agent.id)
        }
        if agent.id != Agent.defaultId {
            AgentSharedWithSection(agent: currentAgent)
        }
    }

    /// Workspaces this agent is shared into right now (roster-derived).
    /// Workspaces this agent is currently shared into.
    private var sharedWorkspaces: [OsaurusRouterWorkspaceSummary] {
        AgentSharedWithSection.sharedWorkspaces(for: currentAgent, rosterStore: rosterStore)
    }

    private var sharedWorkspaceNames: [String] { sharedWorkspaces.map(\.name) }

    /// The header Share button. "Share…" is the one Share Agent sheet
    /// (Workspace or Guest Link); "Save as Template" exports the setup.
    /// Popped as an AppKit menu so the button keeps the header's exact
    /// styling.
    private func presentShareMenu() {
        let menu = NSMenu()

        let share = NSMenuItem(
            title: L("Share…"), action: #selector(HeaderMenuTarget.fire(_:)), keyEquivalent: "")
        let shareTarget = HeaderMenuTarget { showingShareSheet = true }
        share.target = shareTarget
        share.representedObject = shareTarget  // keeps the target alive with the item
        share.isEnabled = !currentAgent.isBuiltIn
        menu.addItem(share)

        // Portable copy of the configuration (no data, no secrets): the
        // same action as the grid card's Save as Template.
        menu.addItem(.separator())
        let templateItem = NSMenuItem(
            title: L("Save as Template"), action: #selector(HeaderMenuTarget.fire(_:)), keyEquivalent: "")
        let templateTarget = HeaderMenuTarget { showingSaveTemplateSheet = true }
        templateItem.target = templateTarget
        templateItem.representedObject = templateTarget
        menu.addItem(templateItem)

        let origin = NSEvent.mouseLocation
        if let window = NSApp.keyWindow, let anchor = window.contentView {
            let point = anchor.convert(window.convertPoint(fromScreen: origin), from: nil)
            shareMenuPresenter.showContextMenu(menu, from: anchor, theme: theme, at: point)
        }
    }

    private var deleteAgentMessage: String {
        L(
            "Are you sure you want to delete \"\(currentAgent.name)\"? This action cannot be undone. Any sandbox resources provisioned for this agent will also be removed."
        )
    }

    /// Why delete is refused while shared: teammates would be cut off and
    /// the roster would keep a row nobody can reach. Unsharing is a
    /// deliberate step in the workspace, never a side effect of delete.
    private var deleteBlockedMessage: String {
        String(
            format: L(
                "\"%@\" is shared with %@. Unshare it from the workspace first, then delete it. Teammates lose access when it's unshared."
            ),
            currentAgent.name,
            ListFormatter.localizedString(byJoining: sharedWorkspaceNames)
        )
    }

    /// Trash button: a shared agent gets the explanation, anything else
    /// the usual confirmation.
    private func requestDelete() {
        if sharedWorkspaces.isEmpty {
            showDeleteConfirm = true
        } else {
            showDeleteBlockedByShare = true
        }
    }

    @ViewBuilder
    private var connectionsTabContent: some View {
        if currentAgent.agentAddress != nil {
            GuestAccessLedger(agents: [currentAgent])
        }
    }

    @ViewBuilder
    private var sandboxTabContent: some View {
        tabHelperText(DetailTab.sandbox.helperText)
        // Execution permissions (master switch + plugin creation, network,
        // background processes, secret reads). The master switch is also
        // surfaced as the Code Execution card on Abilities → Overview,
        // which links here for the full permission set.
        if agent.id != Agent.defaultId {
            SettingsSection(
                title: "Execution",
                subtitle: "What the agent may do inside the sandbox."
            ) {
                VStack(alignment: .leading, spacing: theme.space.s12) {
                    sandboxExecSubsection
                }
            }
        }
        sandboxSection
    }

    @ViewBuilder
    private var automationTabContent: some View {
        tabHelperText(DetailTab.automation.helperText)
        eventsSection
        recentTasksSection
    }

    /// The agent's last few tasks; See All opens Tasks → History for it.
    private var recentTasksSection: some View {
        SettingsSection(title: "Recent Tasks", subtitle: L("What this agent ran on its own, newest first")) {
            SettingsButton(.tertiary, "See All", size: .compact) {
                TaskControl.showHistory(.agent(agent.id))
            }
        } content: {
            RecentTasksList(query: TaskQuery(agentId: agent.id, limit: 5))
        }
        .settingsLandingAnchor("agents.automation.recentTasks")
    }

    /// The agent's channel presence, read-only: which channels it answers
    /// on and where it may post. Edited on the channel itself (Channels →
    /// platform → Routing / Sending).
    @ViewBuilder
    private var channelsTabContent: some View {
        tabHelperText(DetailTab.channels.helperText)
        onChannelsSection
    }

    private var onChannelsSection: some View {
        SettingsSection(
            title: "On Channels",
            subtitle: L(
                "Where this agent answers messages and where it may post on its own. Change it on the channel, under Channels."
            )
        ) {
            AgentChannelAgentOnChannelsSection(agentId: agent.id)
        }
        .settingsLandingAnchor("agents.channels.onChannels")
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
        SettingsSection(title: "System Prompt") {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                SettingsTextEditor(text: $systemPrompt, placeholder: L("Enter instructions for this agent..."), minHeight: 160, maxHeight: 300, monospaced: true)

                Text(
                    "Instructions that define this agent's behavior. Leave empty to use global settings.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
            }
            .onChange(of: systemPrompt) { debouncedSave() }
        }
    }

    /// Primary "what model does this agent use?" picker. Lives at the top of the
    /// Configure tab next to System Prompt and Capabilities — the three things users
    /// reach for most. Temperature / Max Tokens overrides moved into the Advanced
    /// disclosure below.
    private var defaultModelSection: some View {
        SettingsSection(title: "Model") {
            ModelSearchablePicker(
                items: pickerItems,
                selection: Binding(
                    get: { selectedModel },
                    set: { newModel in
                        selectedModel = newModel
                        agentManager.updateDefaultModel(for: agent.id, model: newModel)
                        showSaveIndicator()
                    }
                ),
                noneTitle: L("Default (from global settings)")
            )
        }
    }

    private var claudeCodeSection: some View {
        SettingsSection(title: "Claude Code Options") {
            VStack(alignment: .leading, spacing: theme.space.s14) {
                labeledSegmented(L("Claude model")) {
                    AssignedBaseSegmentedPicker(
                        selection: Binding(
                            get: { claudeCodeConfig.resolvedModel },
                            set: { model in updateClaudeCodeConfig { $0.model = model } }
                        ),
                        options: ClaudeCodeModel.allCases.map { .init($0.rawValue, $0.rawValue.capitalized, verbatim: true) }
                            + (ClaudeCodeModel(rawValue: claudeCodeConfig.resolvedModel) == nil
                                ? [.init(claudeCodeConfig.resolvedModel, claudeCodeConfig.resolvedModel, verbatim: true)] : [])
                    )
                }
                .settingsLandingAnchor("agents.claudeCode.model")

                Picker(
                    L("Claude effort"),
                    selection: Binding(
                        get: { claudeCodeConfig.resolvedEffort?.rawValue ?? "" },
                        set: { effort in updateClaudeCodeConfig { $0.effort = effort.isEmpty ? nil : effort } }
                    )
                ) {
                    Text("Default", bundle: .module).tag("")
                    ForEach(ClaudeCodeEffort.allCases, id: \.rawValue) { effort in
                        Text(verbatim: effort.displayName).tag(effort.rawValue)
                    }
                }
                .settingsLandingAnchor("agents.claudeCode.effort")

                labeledSegmented(L("Execution mode")) {
                    AssignedBaseSegmentedPicker(
                        selection: Binding(
                            get: { claudeCodeConfig.mode },
                            set: { mode in updateClaudeCodeConfig { $0.mode = mode } }
                        ),
                        options: [.init(ClaudeCodeMode.agent, "Agent"), .init(ClaudeCodeMode.textOnly, "Text only")]
                    )
                }

                Text(
                    claudeCodeConfig.mode == .agent
                        ? "Claude Code runs its own agent loop under your macOS account. Read, Grep, and Glob are allowed by default; every wider capability is opt-in."
                        : "Claude Code runs as a text generator with every built-in and MCP tool disabled.",
                    bundle: .module
                )
                .textStyle(.footnote)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)

                Toggle(
                    isOn: Binding(
                        get: { claudeCodeConfig.allowWrites },
                        set: { enabled in updateClaudeCodeConfig { $0.allowWrites = enabled } }
                    )
                ) {
                    claudeCodePermissionLabel(
                        title: "Allow file changes",
                        detail: "Auto-approve Edit, Write, and NotebookEdit inside the chat folder, or the chat's private scratch folder when none is set."
                    )
                }
                .settingsCheckbox()
                .disabled(claudeCodeConfig.mode != .agent)

                Toggle(
                    isOn: Binding(
                        get: { claudeCodeConfig.allowShell },
                        set: { enabled in updateClaudeCodeConfig { $0.allowShell = enabled } }
                    )
                ) {
                    claudeCodePermissionLabel(
                        title: "Allow shell commands",
                        detail: "Auto-approve Bash and Monitor under your macOS account. Osaurus can't confine shell commands to the chat folder, and this is not the Osaurus sandbox. When off, Claude isn't offered any tool that runs commands."
                    )
                }
                .settingsCheckbox()
                .disabled(claudeCodeConfig.mode != .agent)

                Toggle(
                    isOn: Binding(
                        get: { claudeCodeConfig.allowOsaurusTools },
                        set: { enabled in
                            updateClaudeCodeConfig {
                                $0.allowOsaurusTools = enabled
                                if !enabled { $0.allowOsaurusConfigWrites = false }
                            }
                        }
                    )
                ) {
                    claudeCodePermissionLabel(
                        title: "Allow Osaurus read tools",
                        detail: "Attach osaurus_inspect and osaurus_help over an MCP bridge scoped to this agent. Needs the Osaurus server running."
                    )
                }
                .settingsCheckbox()
                .disabled(claudeCodeConfig.mode != .agent)

                Toggle(
                    isOn: Binding(
                        get: { claudeCodeConfig.allowOsaurusConfigWrites && agent.id == Agent.defaultId },
                        set: { enabled in
                            updateClaudeCodeConfig { $0.allowOsaurusConfigWrites = enabled }
                        }
                    )
                ) {
                    claudeCodePermissionLabel(
                        title: "Allow Osaurus configuration changes",
                        detail: agent.id == Agent.defaultId
                            ? "Also attach osaurus_config, which changes agents, providers, models, plugins, and MCP servers."
                            : "Only the Default agent can change Osaurus configuration."
                    )
                }
                .settingsCheckbox()
                .disabled(
                    claudeCodeConfig.mode != .agent
                        || !claudeCodeConfig.allowOsaurusTools
                        || agent.id != Agent.defaultId
                )
            }
            .toggleStyle(.switch)
            .settingsLandingAnchor("agents.claudeCode")
        }
    }

    // MARK: - Runtime

    private var selectedHarness: HarnessSelection? {
        guard let id = agentRuntime.harnessId else { return nil }
        if let runtime = harnessRuntimeStore.runtimes.first(where: { $0.id == id }) {
            return .resolved(runtime)
        }
        return .missing(id)
    }

    private var runtimeSection: some View {
        SettingsSection(title: "Runtime") {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                SettingsRow(title: "Runs on", description: "", anchorId: "agents.runtime") {
                    SettingsMenuPicker(
                        selection: Binding(
                            get: { agentRuntime },
                            set: { runtime in
                                agentRuntime = runtime
                                agentManager.updateRuntime(runtime, for: agent.id)
                                showSaveIndicator()
                            }
                        )
                    ) {
                        Text("Osaurus (built-in)", bundle: .module).tag(AgentRuntime.builtIn)
                        ForEach(harnessRuntimeStore.runtimes) { runtime in
                            Text(verbatim: runtime.displayName).tag(AgentRuntime.harness(runtime.id))
                        }
                        if case .missing(let id) = selectedHarness {
                            Text("Missing runtime", bundle: .module).tag(AgentRuntime.harness(id))
                        }
                    }
                    .accessibilityLabel(Text("Runs on", bundle: .module))
                }

                runtimeExplanation

                SettingsButton(.tertiary, "Manage Runtimes", icon: "arrow.right", size: .compact) {
                    ManagementStateManager.shared.selectedTab = .agentRuntimes
                }
            }
        }
        .onAppear { harnessRuntimeStore.loadIfNeeded() }
    }

    @ViewBuilder
    private var runtimeExplanation: some View {
        switch selectedHarness {
        case nil:
            runtimeNote(
                L("Osaurus runs this agent itself, on its model, with its tools, memory, and sandbox.")
            )
        case .missing:
            runtimeNote(
                L("The runtime this agent used was deleted, so its chats can't start. Pick another runtime or switch back to built-in."),
                isWarning: true
            )
        case .resolved(let runtime):
            VStack(alignment: .leading, spacing: theme.space.s6) {
                runtimeNote(
                    String(
                        format: L(
                            "%@ runs this agent's chats as a process on this Mac, with its own model, tools, and conversation history. Osaurus sends each message and shows the reply; Osaurus abilities, memory, and the sandbox don't apply."
                        ),
                        runtime.displayName
                    )
                )
                if runtime.kind == .piRPC {
                    runtimeNote(
                        L("Osaurus can't confine this runtime's tools. Narrow them with --tools in the runtime's arguments.")
                    )
                }
            }
        }
    }

    private func runtimeNote(_ text: String, isWarning: Bool = false) -> some View {
        Text(text)
            .font(SettingsFont.footnote)
            .foregroundColor(isWarning ? theme.status.warning.foreground : theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func claudeCodePermissionLabel(
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s2) {
            Text(title, bundle: .module)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
            Text(detail, bundle: .module)
                .font(SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
        }
    }

    /// A segmented control with its label in front, where a labeled native
    /// `Picker` used to draw one. `title` is already localized.
    private func labeledSegmented<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: theme.settingsInlineGap) {
            Text(verbatim: title)
                .font(SettingsFont.rowTitle)
                .foregroundColor(theme.text.primary)
            control()
                .fixedSize()
                .accessibilityLabel(Text(verbatim: title))
        }
    }

    private func updateClaudeCodeConfig(
        _ mutate: (inout ClaudeCodeAgentConfig) -> Void
    ) {
        var next = claudeCodeConfig
        mutate(&next)
        claudeCodeConfig = next
        agentManager.updateClaudeCodeConfig(next, for: agent.id)
        showSaveIndicator()
    }

    /// Per-agent follow-up suggestions: an opt-out for this agent's chats and
    /// a model override. Both apply only while the global "Suggest Follow-Up
    /// Questions" switch is on. Model is the only generation knob by design —
    /// routing follow-ups to a separate model keeps them off the resident chat
    /// model so its KV cache survives.
    private var followUpSection: some View {
        SettingsSection(title: "Follow-Up Suggestions") {
            SettingsToggle(
                title: "Show Follow-Up Suggestions",
                description:
                    "Offer a few suggested next questions under this agent's replies. Turn off for agents that end their turns by asking you something. Applies only while Suggest Follow-Up Questions is on in Chat settings.",
                anchorId: "agents.followUpSuggestions",
                isOn: $followUpEnabled
            )
            .accessibilityIdentifier("agent.followUpSuggestions")
            .onChange(of: followUpEnabled) { debouncedSave() }

            if followUpEnabled {
                VStack(alignment: .leading, spacing: theme.space.s10) {
                    ModelSearchablePicker(
                        items: pickerItems,
                        selection: Binding(
                            get: { followUpModel.isEmpty ? nil : followUpModel },
                            set: { newModel in
                                followUpModel = newModel ?? ""
                                debouncedSave()
                            }
                        ),
                        noneTitle: L("Default (shared core model)")
                    )

                    Text(
                        "Generates this agent's follow-up questions on a separate, usually cheaper or faster model, so the chat model is never interrupted.",
                        bundle: .module
                    )
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
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
        SettingsSection(
            title: "Scheduling",
            subtitle:
                "How often this agent is allowed to run itself in the background. The agent picks its own next time within these bounds."
        ) {
            ForEach(Self.selectableScheduleModes, id: \.self) { mode in
                scheduleModeRow(mode: mode)
            }
        }
    }

    /// Schedule presets surfaced in the picker. Excludes `.manual` — the
    /// Self-scheduling master toggle owns the on/off state now, so a
    /// "Self-scheduling off" card inside an enabled section would be
    /// contradictory.
    private static let selectableScheduleModes: [AgentScheduleMode] =
        AgentScheduleMode.allCases.filter { $0 != .manual }

    /// One radio row in the schedule-mode list. Filled circle when
    /// selected; the body lays out title + tagline + concrete preset
    /// numbers so the user sees exactly what changing the mode does.
    private func scheduleModeRow(mode: AgentScheduleMode) -> some View {
        let isSelected = (currentAgent.settings.schedule.mode == mode)
        return LibraryRow(
            title: Self.scheduleModeTitle(mode),
            subtitle: Self.scheduleModeTagline(mode) + "\n" + Self.scheduleModePresetSummary(mode),
            isSelected: isSelected,
            action: { selectScheduleMode(mode) }
        ) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .glyphSize(.medium)
                .foregroundColor(isSelected ? theme.text.link : theme.text.tertiary)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
        // (DB and the built-in tool gates) is preserved across a mode change.
        current.settings.schedule = AgentScheduleSettings.defaults(for: newMode)
        current.updatedAt = Date()
        agentManager.update(current)
        showSaveIndicator()
    }

    private static func scheduleModeTitle(_ mode: AgentScheduleMode) -> String {
        switch mode {
        case .ambient: return L("Ambient")
        case .reactive: return L("Reactive")
        case .project: return L("Project")
        case .manual: return L("Manual")
        }
    }

    private static func scheduleModeTagline(_ mode: AgentScheduleMode) -> String {
        switch mode {
        case .ambient: return L("Background helper")
        case .reactive: return L("Quick reflexes")
        case .project: return L("Deep work")
        case .manual: return L("Self-scheduling off")
        }
    }

    /// Plain-English summary of the values written by
    /// `AgentScheduleSettings.defaults(for:)` so the user knows what
    /// changing modes actually does. Keep in sync with the presets in
    /// `Agent.swift`.
    private static func scheduleModePresetSummary(_ mode: AgentScheduleMode) -> String {
        switch mode {
        case .ambient:
            return L("Up to 6 runs/day · at most once an hour · quiet 10pm–7am.")
        case .reactive:
            return L("Up to 48 runs/day · as often as every 5 min · no quiet hours.")
        case .project:
            return L("Up to 4 runs/day · at most once an hour · quiet 10pm–7am.")
        case .manual:
            return L("The agent only runs when you ask. Scheduled API calls from the agent are rejected.")
        }
    }

    /// Power-user generation overrides. Tucked inside the Advanced disclosure so
    /// the Configure tab leads with model + capabilities + system prompt for the
    /// 90% case.
    private var generationOverridesSection: some View {
        SettingsSection(title: "Generation Overrides") {
            if agentRuntime != .builtIn {
                Text(
                    "These generation defaults apply to Osaurus (built-in). The selected external runtime owns its generation settings.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                AgentGenerationSettingsEditor(
                    modelID: generationModelID,
                    modelIsLocal: pickerItems.first(where: { $0.id == generationModelID })?.source == .local,
                    catalogCapabilities: pickerItems.first(where: { $0.id == generationModelID })?.reasoningCapabilities,
                    savedTemperature: Float(temperature), savedMaxTokens: Int(maxTokens),
                    savedSettings: generationSettings
                ) { values in
                    temperature = values.temperature.map { String($0) } ?? ""
                    maxTokens = values.maxTokens.map { String($0) } ?? ""
                    generationSettings = values.settings
                    saveAgent(generationValues: values)
                }
            }
        }
    }

    private var generationModelID: String? {
        var draftAgent = currentAgent
        draftAgent.defaultModel = selectedModel
        return agentManager.effectiveModel(for: draftAgent)
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

    // MARK: - Abilities Overview

    /// Abilities → Overview tab: every capability card. The primary on/off state
    /// lives here; the shared context card stays in the fixed tab chrome above.
    /// deep-link into the specialist tabs (Tools, Memory, Automation,
    /// Database, Sandbox) for detailed configuration.
    @ViewBuilder
    private var abilitiesTabContent: some View {
        tabHelperText(DetailTab.abilities.helperText)
        abilitiesSubpageRows
        AgentAbilitiesOverviewView {
            abilityCards
        }
        if agent.id != Agent.architectId {
            AgentWorkflowsSection(agentId: agent.id)
        }
    }

    /// The editor's complete LOCAL Abilities state, priced before any of the
    /// three persistence lanes (debounced agent, immediate tools, async
    /// sandbox) finish.
    private var abilityDraft: AgentAbilityContextPreview.Draft {
        let toolMode =
            abilityPreviewToolMode
            ?? agentManager.effectiveToolSelectionMode(for: agent.id)
        let toolNames =
            abilityPreviewToolNames
            ?? Set(agentManager.effectiveEnabledToolNames(for: agent.id) ?? [])
        // Apple apps are written by the Tools picker straight through
        // `AgentManager` (like `manualToolNames`); mirror the picker's
        // in-flight value first, then the persisted set.
        let enabledAppleApps =
            agent.id == Agent.defaultId
            ? [] : (abilityPreviewAppleApps ?? currentAgent.settings.enabledAppleApps)
        let autonomous =
            abilityPreviewAutonomousConfig
            ?? agentManager.effectiveAutonomousExec(for: agent.id)
            ?? .default
        let collectionIds = Set(knowledgeCollectionIds)
        let collections = knowledgeManager.collections
            .filter { collectionIds.contains($0.id) }
            .map(\.grantDescriptor)
        let spawnConfiguration = AgentSpawnConfigSnapshot(
            agentIDs: spawnableAgentIDs.filter { $0 != agent.id },
            budgets: SpawnBatchConcurrencyContract.applyingSharedLimit(
                from: globalSubagentConfig,
                to: subagentBudgets
            ),
            launcherModelOverride:
                subagentModelOverrides[SubagentCapabilityRegistry.spawn.id],
            workspaceAgents: spawnableWorkspaceAgents
        )

        return AgentAbilityContextPreview.Draft(
            toolsEnabled: toolsEnabled,
            memoryEnabled: memoryEnabled,
            dbEnabled: dbEnabled,
            renderChartEnabled: renderChartEnabled,
            speakEnabled: speakEnabled,
            searchMemoryEnabled: searchMemoryEnabled,
            webSearchEnabled: webSearchEnabled,
            selfSchedulingEnabled: selfSchedulingEnabled,
            knowledgeEnabled: knowledgeEnabled,
            knowledgeCuratorEnabled: knowledgeCuratorEnabled,
            codeExecutionEnabled: autonomous.enabled,
            model: selectedModel,
            toolMode: toolMode,
            manualToolNames: toolNames.sorted(),
            computerUseEnabled: computerUseEnabled,
            browserUseEnabled: browserUseEnabled,
            spawnDelegationEnabled: spawnDelegationEnabled,
            imageEnabled: imageEnabled,
            videoEnabled: videoEnabled,
            appleScriptEnabled: appleScriptEnabled,
            spawnableAgentIDs: spawnableAgentIDs,
            spawnConfiguration: spawnConfiguration,
            enabledAppleApps: enabledAppleApps,
            calculatorEnabled: calculatorEnabled,
            redactionToolsEnabled: redactionToolsEnabled,
            taskChecklistEnabled: taskChecklistEnabled,
            clarifyEnabled: clarifyEnabled,
            artifactsEnabled: artifactsEnabled,
            autonomousConfig: autonomous,
            knowledgeCollections: collections,
            registryRevision: abilityPreviewRegistryRevision
        )
    }

    /// Recompose only when a budget input changes. The short debounce keeps
    /// bulk tool/group flips and slider edits from opening the agent store on
    /// every intermediate state.
    @MainActor
    private func refreshAbilityContextPreview() async {
        try? await Task.sleep(nanoseconds: 140_000_000)
        guard !Task.isCancelled else { return }
        guard !StorageMutationGate.isRotationInFlight else { return }

        let next = AgentAbilityContextPreview.compute(agentId: agent.id, draft: abilityDraft)
        if let previous = abilityContextPreview {
            let delta = next.highTokens - previous.highTokens
            if delta != 0 {
                abilityContextDelta = delta
                abilityContextDeltaDismissTask?.cancel()
                abilityContextDeltaDismissTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_600_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(theme.motion.standard) {
                        abilityContextDelta = nil
                    }
                }
            }
        }

        withAnimation(theme.motion.springAnimation) {
            abilityContextPreview = next
        }
    }

    /// On/off values behind the hero's "N of M abilities on" counter, in
    /// card order. Working Folder counts as on when the agent has a folder.
    /// Apple apps are deliberately NOT counted: they have no Overview card
    /// (they are groups in the Tools tab), so counting them made the
    /// denominator disagree with the cards on screen.
    private var abilityFlagValues: [Bool] {
        var flags = [toolsEnabled]
        if agent.id != Agent.defaultId {
            flags += [
                memoryEnabled,
                renderChartEnabled,
                speakEnabled,
                artifactsEnabled,
                taskChecklistEnabled,
                clarifyEnabled,
                calculatorEnabled,
                redactionToolsEnabled,
                searchMemoryEnabled,
                knowledgeEnabled,
                webSearchEnabled,
                selfSchedulingEnabled,
                dbEnabled,
                abilityPreviewAutonomousConfig?.enabled
                    ?? agentManager.effectiveAutonomousExec(for: agent.id)?.enabled
                    ?? false,
                workingFolderPath != nil,
            ]
        }
        return flags
    }

    /// Per-collection grant checkmark row inside the Knowledge ability
    /// card. Grants are re-enforced at tool execution time, so this UI is
    /// the only way to widen an agent's knowledge scope.
    private func knowledgeGrantRow(_ collection: KnowledgeCollection) -> some View {
        let granted = knowledgeCollectionIds.contains(collection.id)
        return Button {
            if granted {
                knowledgeCollectionIds.removeAll { $0 == collection.id }
            } else {
                knowledgeCollectionIds.append(collection.id)
            }
            debouncedSave()
        } label: {
            HStack(spacing: theme.space.s8) {
                Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                    .glyphSize(.body)
                    .foregroundColor(granted ? theme.text.link : theme.text.tertiary)
                SettingsRowText(compact: true) {
                    Text(collection.name)
                } description: {
                    if !collection.summary.isEmpty {
                        Text(collection.summary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if !collection.isEnabled {
                    Text("Disabled", bundle: .module)
                        .font(SettingsFont.footnote)
                        .foregroundColor(theme.text.tertiary)
                }
            }
            .padding(theme.space.s8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Wrap a local `@State` flag binding so writes also schedule the
    /// debounced agent save — the same write path every other editor
    /// control in this view uses.
    private func abilitySaveBinding(_ source: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { source.wrappedValue },
            set: { newValue in
                source.wrappedValue = newValue
                debouncedSave()
            }
        )
    }

    /// Chip shown on tool-backed cards while the Tools master switch is
    /// off: those abilities keep their configured state but ship no tool
    /// schema until Tools comes back.
    private var toolsPausedNote: String? {
        let readiness = AgentCapabilityReadiness.resolve(
            configured: true,
            toolsEnabled: toolsEnabled
        )
        return readiness.isCallable ? nil : readiness.statusMessage
    }

    private var knowledgeReadinessNote: String? {
        let readiness = AgentCapabilityReadiness.resolve(
            configured: knowledgeEnabled,
            toolsEnabled: toolsEnabled,
            blockers: knowledgeCollectionIds.isEmpty ? [.noKnowledgeCollections] : []
        )
        return readiness.isCallable || !readiness.configured
            ? nil
            : readiness.statusMessage
    }

    /// Scroll anchor for the Tools master card in the Abilities overview.
    private static let toolsToggleScrollId = "abilities-tools-card"

    /// `abilitySaveBinding` for tool-backed abilities: while Tools is off
    /// the switch refuses to turn ON — the write is dropped so the toggle
    /// snaps back, and the view scrolls to and pulses the Tools master
    /// card instead. Turning OFF still lands, so a paused ability can be
    /// unconfigured without re-enabling Tools first.
    private func toolBackedSaveBinding(_ source: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { source.wrappedValue },
            set: { newValue in
                if newValue, !toolsEnabled {
                    // Re-assert false so the optimistic switch animation
                    // snaps back even though the value never changed.
                    source.wrappedValue = false
                    flashToolsToggle()
                    return
                }
                source.wrappedValue = newValue
                debouncedSave()
            }
        )
    }

    /// Scroll the Tools card into view and run one highlight breath on
    /// it. Dropping the flag first gives `settingsSearchHighlight` a
    /// fresh rising edge so a repeat tap re-fires; the delayed clear only
    /// lands if no newer tap has bumped the generation, so a rapid second
    /// tap can't cut its own glow short.
    private func flashToolsToggle() {
        scrollToToolsNonce += 1
        toolsHighlightGeneration += 1
        let generation = toolsHighlightGeneration
        toolsHighlightActive = false
        DispatchQueue.main.async {
            guard generation == toolsHighlightGeneration else { return }
            toolsHighlightActive = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            guard generation == toolsHighlightGeneration else { return }
            toolsHighlightActive = false
        }
    }

    @ViewBuilder
    private var abilityCards: some View {
        let isCustomAgent = agent.id != Agent.defaultId

        SettingsSection(title: "Model Access", subtitle: "What the model can draw on by default.") {
            SettingsAbilityRow(
                title: "Tools",
                description:
                    "Let the agent use tools to take actions and look things up. Turn off for a chat-only agent.",
                icon: "wrench.and.screwdriver",
                isOn: abilitySaveBinding($toolsEnabled),
                configureLabel: "Choose tools & skills",
                onConfigure: { selectedTab = .builtIn(.capabilities) }
            )
            .id(Self.toolsToggleScrollId)
            .settingsSearchHighlight(toolsHighlightActive)
            // The default agent has no per-agent memory flag: its memory is
            // governed globally (Settings > Enable memory), so a per-agent
            // toggle here would be a dead control.
            if isCustomAgent {
                SettingsAbilityRow(
                    title: "Memory",
                    description:
                        "Pull relevant memories into prompts and save new ones as you chat. Injected per turn, so it widens the context estimate into a range.",
                    icon: "brain.head.profile",
                    isOn: abilitySaveBinding($memoryEnabled),
                    configureLabel: "History, facts & episodes",
                    onConfigure: { selectedTab = .builtIn(.memory) }
                )
            } else {
                SettingsRow(
                    title: "Memory",
                    description:
                        "Memory for the default agent is controlled globally in Settings → Memory → Enable Memory."
                ) {
                    EmptyView()
                }
            }
        }

        // Custom-agent-only sections. The default agent is locked to its
        // fixed baseline (DB hard-off, no sandbox), so these would be
        // dead UI for it.
        if isCustomAgent {
            SettingsSection(title: "Output", subtitle: "Extra ways the agent can present results.") {
                SettingsAbilityRow(
                    title: "Charts",
                    description: "Render data as inline chart cards.",
                    icon: "chart.bar.xaxis",
                    isOn: toolBackedSaveBinding($renderChartEnabled),
                    pausedNote: toolsPausedNote,
                    onPausedNoteTap: flashToolsToggle
                )
                SettingsAbilityRow(
                    title: "Speak Tool",
                    description:
                        "Give the agent a tool it can call to read a reply aloud when you ask. For always-speak, use Auto Speak Responses in the Voice section.",
                    icon: "speaker.wave.2",
                    isOn: toolBackedSaveBinding($speakEnabled),
                    pausedNote: toolsPausedNote,
                    onPausedNoteTap: flashToolsToggle
                )
                SettingsAbilityRow(
                    title: "Share Artifacts",
                    description: "Let the agent post finished files, images, and reports as cards in the chat.",
                    icon: "square.and.arrow.up",
                    isOn: toolBackedSaveBinding($artifactsEnabled),
                    pausedNote: toolsPausedNote,
                    onPausedNoteTap: flashToolsToggle
                )
                .settingsLandingAnchor("agents.artifacts")
            }
            SettingsSection(title: "Task Tools", subtitle: "Built-in helpers for working through a task.") {
                SettingsAbilityRow(
                    title: "Task Checklist",
                    description: "Let the agent keep a visible checklist for multi-step work and close out a blocked task.",
                    icon: "checklist",
                    isOn: toolBackedSaveBinding($taskChecklistEnabled),
                    pausedNote: toolsPausedNote,
                    onPausedNoteTap: flashToolsToggle
                )
                .settingsLandingAnchor("agents.taskChecklist")
                SettingsAbilityRow(
                    title: "Clarifying Questions",
                    description: "Let the agent pause and ask you a question when a task is ambiguous.",
                    icon: "questionmark.bubble",
                    isOn: toolBackedSaveBinding($clarifyEnabled),
                    pausedNote: toolsPausedNote,
                    onPausedNoteTap: flashToolsToggle
                )
                .settingsLandingAnchor("agents.clarify")
                SettingsAbilityRow(
                    title: "Calculator",
                    description: "Exact arithmetic for agents that work with numbers: totals, percentages, budgets, conversions.",
                    icon: "function",
                    isOn: toolBackedSaveBinding($calculatorEnabled),
                    pausedNote: toolsPausedNote,
                    onPausedNoteTap: flashToolsToggle
                )
                .settingsLandingAnchor("agents.calculator")
                SettingsAbilityRow(
                    title: "Redaction Tools",
                    description: "Find and mask names, emails, phone numbers, and other personal data in files of the working folder.",
                    icon: "eye.slash",
                    isOn: toolBackedSaveBinding($redactionToolsEnabled),
                    pausedNote: toolsPausedNote,
                    onPausedNoteTap: flashToolsToggle
                )
                .settingsLandingAnchor("agents.redactionTools")
            }

            SettingsSection(title: "Memory & Recall", subtitle: "Active lookups into the agent's memory.") {
                SettingsAbilityRow(
                    title: "Memory Recall",
                    description:
                        "Let the agent search its own memory mid-conversation to pull up past details on demand. Separate from Memory above, which only auto-injects and saves.",
                    icon: "magnifyingglass",
                    isOn: toolBackedSaveBinding($searchMemoryEnabled),
                    pausedNote: toolsPausedNote,
                    onPausedNoteTap: flashToolsToggle
                )
            }

            SettingsSection(
                title: "Knowledge",
                subtitle: "Curated reference material the agent can consult on demand."
            ) {
                SettingsAbilityRow(
                    title: "Knowledge",
                    description:
                        "Let the agent search, read and update the knowledge collections granted below: curated guides, templates, and standards. The agent shows you every change and waits for your approval before saving, and you can undo anything it writes from the Knowledge section.",
                    icon: "books.vertical",
                    isOn: toolBackedSaveBinding($knowledgeEnabled),
                    pausedNote: knowledgeReadinessNote,
                    onPausedNoteTap: {
                        if !toolsEnabled { flashToolsToggle() }
                    }
                ) {
                    if knowledgeEnabled {
                        if knowledgeManager.collections.isEmpty {
                            Text(
                                "No knowledge collections yet. Add one in the Knowledge section of this window.",
                                bundle: .module
                            )
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(theme.text.tertiary)
                        } else {
                            VStack(alignment: .leading, spacing: theme.space.s2) {
                                ForEach(knowledgeManager.collections) { collection in
                                    knowledgeGrantRow(collection)
                                }
                            }
                        }
                    }
                }
            }
            // The Curator toggle is gone. It gated `propose_knowledge_update`,
            // which asked for consent twice and could never tell the agent
            // whether its own work had landed. Writing follows the collection
            // grant above, and each write is approved with a diff at call
            // time. `knowledgeCuratorEnabled` remains on the model only so
            // existing agent JSON still decodes; nothing reads it.

            SettingsSection(title: "Web", subtitle: "Live information from the internet.") {
                SettingsAbilityRow(
                    title: "Web Search",
                    description:
                        "Let the agent search the web through your search providers. Works out of the box with built-in sources; configure providers in Settings → Web Search.",
                    icon: "globe",
                    isOn: toolBackedSaveBinding($webSearchEnabled),
                    pausedNote: toolsPausedNote,
                    onPausedNoteTap: flashToolsToggle
                )
            }

            SettingsSection(title: "Autonomy", subtitle: "Let the agent act between your messages.") {
                SettingsAbilityRow(
                    title: "Self-scheduling",
                    description:
                        "Let the agent schedule its own follow-up runs and send you notifications. Run frequency and limits are under Scheduling on this agent's main page.",
                    icon: "calendar.badge.clock",
                    isOn: toolBackedSaveBinding($selfSchedulingEnabled),
                    pausedNote: toolsPausedNote,
                    onPausedNoteTap: flashToolsToggle,
                    configureLabel: "Automations",
                    onConfigure: { selectedTab = .builtIn(.automation) }
                )
            }

            SettingsSection(title: "Data", subtitle: "Durable storage for this agent.") {
                SettingsAbilityRow(
                    title: "Database",
                    description:
                        "Give this agent a private encrypted database to remember structured data across runs.",
                    icon: "cylinder.split.1x2",
                    isOn: toolBackedSaveBinding($dbEnabled),
                    pausedNote: toolsPausedNote,
                    onPausedNoteTap: flashToolsToggle,
                    configureLabel: "Open Database",
                    onConfigure: { selectedTab = .builtIn(.database) }
                ) {
                    if dbEnabled, isUsingRemoteProvider {
                        // Spec §5.5.5 / line 340: when the agent's effective
                        // model is a remote (cloud) provider, surface the
                        // schema-leak disclaimer right under the toggle so the
                        // user knows exactly what crosses the wire.
                        sandboxFeatureHint(
                            "Schema (table names and column types) is sent with each request. Row data is not."
                        )
                    }
                }
            }

            SettingsSection(title: "Code Execution", subtitle: "Run code and commands in an isolated sandbox.") {
                codeExecutionAbilityCard
            }

            SettingsSection(
                title: "Working Folder",
                subtitle:
                    "The one macOS folder this agent works inside. Remembered from the chat Folder chip or set here.",
                footer:
                    "Voice output is set under Voice on this agent's main page; the greeting text and personality are in Appearance → Empty State."
            ) {
                SettingsAbilityRow(
                    title: "Working Folder",
                    description:
                        "New chats with this agent open in this folder, and automations and other background runs that don't set their own folder work here too. Authenticated remote agent runs (Secure Channel, agent-scoped key) get file read/write confined to it; shell and git stay disabled for them. Picking or clearing the Folder chip in a chat updates this setting.",
                    icon: "folder.badge.person.crop",
                    isActive: workingFolderPath != nil
                ) {
                    workingFolderRow
                }
                SettingsAbilityRow(
                    title: "Read Only",
                    description:
                        "The agent can read and search its working folder but never writes, edits, copies, undoes, redacts, or runs commands there. Workflow steps that run as this agent follow the same rule.",
                    icon: "lock.doc",
                    isOn: Binding(
                        get: { workingFolderReadOnly },
                        set: { newValue in
                            workingFolderReadOnly = newValue
                            debouncedSave()
                        }
                    )
                )
                .settingsLandingAnchor("agents.workingFolderReadOnly")
            }
        }
    }

    /// Code Execution master switch. Writes through `updateAutonomousExec`
    /// immediately (no debounce) like the sandbox tab's toggles; the
    /// sub-permissions (plugin creation, network, background processes)
    /// stay in Abilities → Sandbox → Execution, which the card links into.
    @ViewBuilder
    private var codeExecutionAbilityCard: some View {
        let sandboxAvailable = SandboxManager.State.shared.availability.isAvailable
        let sandboxRunning = SandboxManager.State.shared.status == .running
        let execConfig =
            abilityPreviewAutonomousConfig
            ?? agentManager.effectiveAutonomousExec(for: agent.id)

        SettingsAbilityRow(
            title: "Autonomous Execution",
            description: "Allow the agent to run arbitrary commands in the sandbox.",
            icon: "terminal",
            isOn: Binding(
                get: { execConfig?.enabled ?? false },
                set: { enabled in
                    updateAutonomousExec(from: execConfig) { $0.enabled = enabled }
                }
            ),
            isInteractive: sandboxAvailable,
            configureLabel: "Sandbox permissions & secrets",
            onConfigure: { selectedTab = .builtIn(.sandbox) }
        ) {
            if !sandboxAvailable {
                sandboxFeatureHint("Sandboxed execution is unavailable on this device.")
            } else if !sandboxRunning {
                sandboxFeatureHint(
                    "This setting will apply when the sandbox starts."
                )
            }
            if sandboxAvailable, execConfig?.enabled == true {
                sandboxFolderSuspensionHint
            }
        }
    }

    /// The sandbox and a working folder are mutually exclusive, and the
    /// sandbox wins. Picking a folder (chat chip or project page) turns the
    /// sandbox off automatically, but turning it back on here silently
    /// suspends any folder those chats still show, so say so.
    private var sandboxFolderSuspensionHint: some View {
        sandboxFeatureHint(
            "While on, chats ignore their working folder. Picking a folder in a chat or project turns the sandbox off again."
        )
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
        VStack(alignment: .leading, spacing: theme.space.s14) {
            Text("Seal Bundle", bundle: .module)
                .font(SettingsFont.cardTitle)
                .foregroundColor(theme.text.primary)
            Text(
                "Choose a passphrase (≥ 8 characters) to encrypt this agent's bundle. You'll need the same passphrase to import it on another Mac.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            SettingsTextField(placeholder: L("Passphrase"), text: $bundlePassphraseInput, isSecure: true)
            SettingsTextField(
                placeholder: L("Confirm passphrase"),
                text: $bundleConfirmPassphraseInput,
                isSecure: true
            )
            HStack {
                Spacer()
                Button(localized: "Cancel") {
                    bundleExportDestination = nil
                    bundlePassphraseInput = ""
                    bundleConfirmPassphraseInput = ""
                }
                .assignedSettingsButtonStyle(.secondary, size: .compact)
                Button(localized: "Export") {
                    performBundleExport()
                }
                .assignedSettingsButtonStyle(.primary, size: .compact)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    bundlePassphraseInput.count < 8
                        || bundlePassphraseInput != bundleConfirmPassphraseInput
                )
            }
        }
        .padding(theme.space.s16)
        .frame(width: 380)
    }

    @ViewBuilder
    private var bundleImportPassphraseSheet: some View {
        VStack(alignment: .leading, spacing: theme.space.s14) {
            Text("Open Bundle", bundle: .module)
                .font(SettingsFont.cardTitle)
                .foregroundColor(theme.text.primary)
            if let url = bundleImportSource {
                Text(url.lastPathComponent)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
            }
            Text("Enter the passphrase used when the bundle was exported.", bundle: .module)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsTextField(placeholder: L("Passphrase"), text: $bundlePassphraseInput, isSecure: true)
            HStack {
                Spacer()
                Button(localized: "Cancel") {
                    bundleImportSource = nil
                    bundlePassphraseInput = ""
                }
                .assignedSettingsButtonStyle(.secondary, size: .compact)
                Button(localized: "Unlock") {
                    performBundleImport()
                }
                .assignedSettingsButtonStyle(.primary, size: .compact)
                .keyboardShortcut(.defaultAction)
                .disabled(bundlePassphraseInput.count < 8)
            }
        }
        .padding(theme.space.s16)
        .frame(width: 380)
    }

    @ViewBuilder
    private var bundleImportReviewSheet: some View {
        VStack(alignment: .leading, spacing: theme.space.s14) {
            Text("Review Bundle", bundle: .module)
                .font(SettingsFont.cardTitle)
                .foregroundColor(theme.text.primary)
            if let preview = bundleImportPreview {
                bundleManifestSummary(preview.manifest)
                if let note = preview.identityNote {
                    bundleIdentityNote(note)
                }
            }
            Text(
                "Activate copies the agent into ~/.osaurus/agents/<id>/, rekeys its database to your local key, and registers the agent for use. Discard wipes the unpacked scratch directory and changes nothing on disk.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
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
        .padding(theme.space.s16)
        .frame(width: 440)
    }

    @ViewBuilder
    private func bundleManifestSummary(_ manifest: AgentBundleManifest) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            HStack(spacing: theme.space.s6) {
                Text(localized: "Agent:").font(SettingsFont.smallLabel)
                Text(manifest.agentName).font(SettingsFont.rowDescription)
            }
            if !manifest.agentDescription.isEmpty {
                Text(manifest.agentDescription)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: theme.space.s12) {
                Text(localized: "Tables: \(manifest.schemaTables)").font(SettingsFont.rowDescription)
                Text(localized: "Views: \(manifest.savedViews)").font(SettingsFont.rowDescription)
                Spacer()
            }
            .foregroundColor(theme.text.secondary)
            Text(localized: "Exported on \(manifest.exportedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
        }
        .padding(theme.space.s8)
        .settingsChrome(.inset)
    }

    /// What activating will do to the bundled agent's address. Moving an
    /// agent between your own devices keeps its address (pairings and
    /// shares survive); a clash with a local agent re-mints it.
    @ViewBuilder
    private func bundleIdentityNote(_ note: AgentBundleService.IdentityNote) -> some View {
        let (symbol, text): (String, String) = {
            switch note {
            case .mintedOnAnotherDevice:
                return (
                    "laptopcomputer.and.iphone",
                    L(
                        "This agent's address was created on another device. It keeps that address, so existing pairings and workspace shares keep working — but if the other device is still serving it, the relay will route to whichever device connected last."
                    )
                )
            case .collidesWithLocalAgent(let name):
                return (
                    "exclamationmark.triangle",
                    L(
                        "Its address is already used by your agent “\(name)”. The imported copy gets a new address on activation; clients paired to the old one must pair again."
                    )
                )
            case .legacyV1:
                return (
                    "key",
                    L("This agent uses a legacy (non device-scoped) address. It is kept as-is; rotate the key later to move it to the current layout.")
                )
            }
        }()
        HStack(alignment: .top, spacing: theme.space.s6) {
            Image(systemName: symbol)
                .glyphSize(.footnote)
                .foregroundColor(theme.status.warning.foreground)
            Text(text)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                    title: "Delegate to subagents",
                    subtitle:
                        "Let this agent delegate a bounded task to an agent or model you allow below. The subagent runs it and returns only the result."
                )
            case .image:
                return PerAgentFeature(
                    flag: .image,
                    title: "Image",
                    subtitle:
                        "Let the agent generate images with a configured local or hosted model, and edit with a local model."
                )
            case .video:
                return PerAgentFeature(
                    flag: .video,
                    title: "Video",
                    subtitle:
                        "Let the agent generate local or cloud text-to-video and image-to-video jobs. Cloud jobs require a price quote."
                )
            case .appleScript:
                return PerAgentFeature(
                    flag: .appleScript,
                    title: "AppleScript",
                    subtitle:
                        "Let the agent automate this Mac by writing and running AppleScript with an on-device model. Each script is shown for your approval or auto-run with a warning, per the mode below."
                )
            case .browserUse:
                return PerAgentFeature(
                    flag: .browserUse,
                    title: "Browser Use",
                    subtitle:
                        "Let the agent browse the web in its own persistent browser session — sign-ins stick around between chats. Reads and navigation run automatically; typing and anything consequential pause for your approval."
                )
            }
        }
    }

    /// Two-way binding into `subagentToggles` for a per-agent flag, so a
    /// shared toggle row can drive the registry-keyed edit-state.
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

    /// Presentation truth for a Subagents card. The configured toggle remains
    /// intact when a prerequisite disappears; this resolver explains the same
    /// gates the composer will apply instead of presenting every ON switch as
    /// callable.
    private func subagentReadiness(
        for flag: SubagentCapability.PerAgentFlag
    ) -> AgentCapabilityReadiness {
        let configured = subagentToggles[flag] ?? false
        let capability = SubagentCapabilityRegistry.capability(forPerAgentFlag: flag)
        let override = capability.flatMap { subagentModelOverrides[$0.id] }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasResolvedModel =
            !(override?.isEmpty ?? true)
            || agentManager.effectiveModel(for: agent.id) != nil

        var configuredSpawnTargetCount = 0
        var runnableSpawnTargetCount = 0
        var checkingSpawnTargets = false
        if flag == .spawn {
            let configuredAgentIDs = spawnableAgentIDs.filter { $0 != agent.id }
            configuredSpawnTargetCount =
                configuredAgentIDs.count + spawnableWorkspaceAgents.count
            let availability = SpawnDescriptors.resolveForPreview(
                agentIDs: configuredAgentIDs,
                launcherModelOverride:
                    subagentModelOverrides[SubagentCapabilityRegistry.spawn.id],
                workspaceAgents: spawnableWorkspaceAgents
            )
            runnableSpawnTargetCount =
                availability.runnableAgentIDs.count
                + availability.runnableWorkspaceAgents.count
            checkingSpawnTargets =
                availability.agentTargets.contains { $0.state == .checking }
        }

        let permissionKindId: String = {
            switch flag {
            case .spawn: return SubagentCapabilityRegistry.spawn.id
            case .video: return SubagentCapabilityRegistry.video.id
            default: return SubagentCapabilityRegistry.image.id
            }
        }()
        let permission: SubagentPermissionPolicy =
            (flag == .spawn || flag == .image || flag == .video)
            ? subagentPermissions.policy(for: permissionKindId)
            : .ask

        return AgentCapabilityReadiness.subagent(
            flag: flag,
            configured: configured,
            toolsEnabled: toolsEnabled,
            hasResolvedModel: hasResolvedModel,
            configuredSpawnTargetCount: configuredSpawnTargetCount,
            runnableSpawnTargetCount: runnableSpawnTargetCount,
            isCheckingSpawnTargets: checkingSpawnTargets,
            hasReadyImageModel: ModelPickerItemCache.shared.hasReadyImageModel,
            hasReadyVideoModel: ModelPickerItemCache.shared.hasReadyVideoGenerationModel,
            hasReadyAppleScriptModel: ModelPickerItemCache.shared.hasReadyAppleScriptModel,
            permission: permission,
            // Computer Use's runtime floor is Accessibility (the registry
            // permission gate fails the first call without it). Only that
            // flag consults TCC; `AXIsProcessTrusted` is a cheap local read.
            hasRequiredSystemPermissions: flag != .computerUse
                || SystemPermissionService.shared.isGranted(.accessibility)
        )
    }

    private var configuredSubagentCount: Int {
        SubagentCapabilityRegistry.perAgentToggleFlags.count {
            subagentReadiness(for: $0).configured
        }
    }

    private var callableSubagentCount: Int {
        SubagentCapabilityRegistry.perAgentToggleFlags.count {
            subagentReadiness(for: $0).isCallable
        }
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
        SettingsSection(
            title: "Subagents",
            caption:
                "\(callableSubagentCount) \(L("callable")) · "
                + "\(configuredSubagentCount) \(L("configured"))"
        ) {
            VStack(alignment: .leading, spacing: theme.space.s16) {
                ForEach(perAgentFeatures, id: \.flag) { feature in
                    let isOn = subagentToggleBinding(feature.flag)
                    let readiness = subagentReadiness(for: feature.flag)
                    VStack(alignment: .leading, spacing: theme.space.s6) {
                        subagentCapabilityCard(
                            title: feature.title,
                            subtitle: feature.subtitle,
                            isOn: isOn,
                            readiness: readiness
                        )
                        if isOn.wrappedValue {
                            subagentConfigPanel {
                                // The standard model-override row is rendered from
                                // the registry flag (`supportsModelOverride`), so a
                                // new chat-driven kind gets the picker for free —
                                // the kind-specific config follows it.
                                if let capability = SubagentCapabilityRegistry.capability(
                                    forPerAgentFlag: feature.flag
                                ), capability.supportsModelOverride, feature.flag != .spawn {
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
    /// chrome so it matches the other toggle rows, but binds directly to the
    /// per-capability enable binding (which routes the right save) and tints its
    /// border with the accent color when on, so an active capability is
    /// scannable at a glance.
    private func subagentCapabilityCard(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        isOn: Binding<Bool>,
        readiness: AgentCapabilityReadiness
    ) -> some View {
        HStack(spacing: theme.space.s12) {
            SettingsRowText(compact: true) {
                Text(title, bundle: .module)
            } description: {
                Text(subtitle, bundle: .module)
                if readiness.configured, let status = readiness.statusMessage {
                    HStack(spacing: theme.space.s4) {
                        Image(systemName: readiness.isCallable ? "checkmark.circle.fill" : "info.circle.fill")
                            .glyphSize(.tiny, weight: .semibold)
                        Text(verbatim: status)
                            .font(SettingsFont.chip)
                    }
                    .foregroundColor(subagentReadinessColor(readiness.state))
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .settingsSwitch()
        }
        .padding(theme.space.s8)
        .background(
            roundedSurface(
                fill: theme.surface.raised,
                stroke:
                    isOn.wrappedValue
                    ? subagentReadinessBorder(readiness.state)
                    : theme.border.strong
            )
        )
    }

    private func subagentReadinessBorder(_ state: AgentCapabilityReadinessState) -> Color {
        switch state {
        case .disabled: return theme.border.strong
        case .active: return theme.status.success.border
        case .paused, .needsSetup: return theme.status.warning.border
        case .unavailable: return theme.status.error.border
        }
    }

    private func subagentReadinessColor(_ state: AgentCapabilityReadinessState) -> Color {
        switch state {
        case .disabled:
            return theme.text.tertiary
        case .active:
            return theme.status.success.foreground
        case .paused, .needsSetup:
            return theme.status.warning.foreground
        case .unavailable:
            return theme.status.error.foreground
        }
    }

    /// Calm, clearly subordinate container for a capability's expanded settings.
    /// Sits just under its toggle card, indented, with a quieter background and a
    /// single hairline border — so the controls read as "settings for this card"
    /// instead of more top-level cards.
    private func subagentConfigPanel<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.space.s12)
        .background(roundedSurface(fill: theme.surface.hover, stroke: theme.border.default))
        .padding(.leading, theme.space.s12)
    }

    /// Hairline separator between control clusters inside `subagentConfigPanel`.
    private var subagentPanelDivider: some View {
        Divider().overlay(theme.border.subtle)
    }

    /// Small footnote line (system-setting pointers, permission requirements)
    /// inside a subagent config panel.
    private func subagentFootnote(_ text: LocalizedStringKey) -> some View {
        Text(text, bundle: .module)
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Leading label (plus an optional one-line description) and a trailing
    /// control — the shared layout for every borderless row inside a
    /// `subagentConfigPanel` (permission, budget, model, autonomy ceiling).
    private func subagentControlRow<Control: View>(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: theme.space.s12) {
            SettingsRowText(compact: true) {
                Text(title, bundle: .module)
            } description: {
                if let subtitle {
                    Text(subtitle, bundle: .module)
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
                    .stroke(stroke, lineWidth: theme.stroke.default)
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
                "Requires Accessibility permission. Grant it and review status in Settings → Computer & Browser Use."
            )
        case .spawn:
            // This shared editor is also used for the built-in main chat's
            // Settings surface. Keeping the controls in one component prevents
            // its pools, notes, permission, worker tools, and limits from
            // drifting away from custom-agent behavior.
            SpawnConfigurationEditor(
                excludedAgentID: agent.id,
                localHandoffEnabled: globalSubagentConfig.localTextDelegationEnabled,
                modelOverride: spawnModelOverrideBinding,
                spawnableAgentIDs: $spawnableAgentIDs,
                spawnableWorkspaceAgents: $spawnableWorkspaceAgents,
                permissionDefaults: $subagentPermissions,
                budgets: sharedSpawnBudgetsBinding,
                onChange: debouncedSave
            )
            subagentFootnote(
                "Local model swapping and memory checks for subagents are system settings in Settings → Orchestrator."
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
        case .video:
            videoModelPickerRows
            subagentPanelDivider
            subagentPermissionRow(
                for: SubagentCapabilityRegistry.video.id,
                label: "Permission"
            )
            subagentFootnote(
                "Local jobs are free and cancellable. Cloud approval includes the current price; queued paid jobs continue recovery after Stop or relaunch."
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
        case .browserUse:
            // The model-override row is rendered generically above (registry
            // `supportsModelOverride`). Approval behavior follows the shared
            // Autonomy policy (same read/navigate/edit/consequential gate as
            // Computer Use), so there is no per-agent permission row here.
            subagentFootnote(
                "This agent gets its own isolated browser profile. View sessions and sign-in status in Settings → Browser."
            )
        }
    }

    // MARK: - Subagent inline config: model / permission / budget controls

    /// Generation + edit model pickers for the Image card. `nil` (Choose
    /// automatically) resolves to the first ready model at run time.
    private var imageModelPickerRows: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            SettingsFieldLabel("Models")
            subagentModelPicker(
                title: "Generation model",
                selection: imageGenerationModelSelection,
                candidates: pickerItems.imageGenerationDelegateCandidates
            )
            subagentModelPicker(
                title: "Edit Model",
                selection: imageEditModelSelection,
                candidates: pickerItems.imageEditDelegateCandidates
            )
        }
    }

    private var videoModelPickerRows: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            SettingsFieldLabel("Models")
            subagentModelPicker(
                title: "Text-to-video",
                selection: textToVideoModelSelection,
                candidates: videoCandidates(.textToVideo)
            )
            subagentModelPicker(
                title: "Image-to-video",
                selection: imageToVideoModelSelection,
                candidates: videoCandidates(.imageToVideo)
            )
        }
    }

    private func videoCandidates(_ kind: MediaGenerationKind) -> [ModelPickerItem] {
        pickerItems.videoGenerationDelegateCandidates.filter { $0.mediaModel?.kind == kind }
    }

    /// The installed AppleScript models this agent can pick. AppleScript bundles
    /// stay in the picker cache (only hidden from the chat picker), so they're
    /// filtered straight out of `pickerItems`.
    private var appleScriptModelCandidates: [ModelPickerItem] {
        pickerItems.filter(\.isAppleScriptCatalogModel)
    }

    /// AppleScript model picker for the AppleScript card. `nil` (Choose
    /// automatically) inherits the global Computer Use AppleScript model, then
    /// falls back to the first installed catalog model when no global model is
    /// configured. A stored id no longer on disk shows an "(unavailable)" row.
    private var appleScriptModelPickerRow: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            SettingsFieldLabel("Model")
            subagentModelPicker(
                title: "AppleScript Model",
                selection: appleScriptModelSelection,
                candidates: appleScriptModelCandidates
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
        VStack(alignment: .leading, spacing: theme.space.s6) {
            subagentControlRow("Script execution") {
                AssignedBaseSegmentedPicker(
                    selection: appleScriptExecutionModeSelection,
                    options: AppleScriptExecutionMode.allCases.map { .init($0, $0.displayName, verbatim: true) }
                )
                .fixedSize()
                .accessibilityLabel(Text("Script execution", bundle: .module))
            }
            Text(verbatim: appleScriptExecutionMode.caption)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A labeled model picker for the inline card: an empty choice ("Choose
    /// automatically") first, and a stored id no longer offered shown as
    /// "(unavailable)".
    private func subagentModelPicker(
        title: LocalizedStringKey,
        selection: Binding<String>,
        candidates: [ModelPickerItem],
        emptyLabel: String = L("Choose automatically")
    ) -> some View {
        subagentControlRow(title) {
            ModelSearchablePicker(
                items: candidates, selection: selection.emptyAsNil, noneTitle: emptyLabel, style: .compact)
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
        let inheritLabel =
            capability.modelSource == .agent ? L("Use the agent's model") : L("Inherit parent model")
        return subagentModelPicker(
            title: "Model",
            selection: subagentModelOverrideBinding(for: capability.id),
            candidates: pickerItems.chatModelCandidates,
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

    /// Optional form of the Spawn model override used by the shared
    /// `SpawnConfigurationEditor`. The other chat-driven capability rows keep
    /// the string picker binding above.
    private var spawnModelOverrideBinding: Binding<String?> {
        Binding(
            get: { subagentModelOverrides[SubagentCapabilityRegistry.spawn.id] },
            set: { newValue in
                if let value = newValue,
                    let trimmed = normalizedModelSelection(value)
                {
                    subagentModelOverrides[SubagentCapabilityRegistry.spawn.id] = trimmed
                } else {
                    subagentModelOverrides.removeValue(
                        forKey: SubagentCapabilityRegistry.spawn.id
                    )
                }
                debouncedSave()
            }
        )
    }

    /// Segmented Ask / Deny / Always permission picker for a delegation kind,
    /// bound per-agent. Borderless — it lives inside `subagentConfigPanel`.
    private func subagentPermissionRow(for kindId: String, label: LocalizedStringKey) -> some View {
        subagentControlRow(label) {
            AssignedBaseSegmentedPicker(
                selection: subagentPermissionBinding(for: kindId),
                options: SubagentPermissionPolicy.allCases.map { .init($0, $0.displayName) }
            )
            .fixedSize()
            .accessibilityLabel(Text(label, bundle: .module))
        }
    }

    // MARK: - Subagent inline config: bindings

    // These bind to `AgentSettings`; the global image settings (defaults,
    // permission, load policy) live in the Image Generation tab.
    private var imageGenerationModelSelection: Binding<String> {
        Binding(
            get: { mediaPickerID(for: imageGenerationTarget) ?? "" },
            set: {
                imageGenerationTarget = mediaTarget(
                    forPickerID: normalizedModelSelection($0),
                    candidates: pickerItems.imageGenerationDelegateCandidates
                )
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

    private var textToVideoModelSelection: Binding<String> {
        Binding(
            get: { mediaPickerID(for: textToVideoTarget) ?? "" },
            set: {
                textToVideoTarget = mediaTarget(
                    forPickerID: normalizedModelSelection($0),
                    candidates: videoCandidates(.textToVideo)
                )
                debouncedSave()
            }
        )
    }

    private var imageToVideoModelSelection: Binding<String> {
        Binding(
            get: { mediaPickerID(for: imageToVideoTarget) ?? "" },
            set: {
                imageToVideoTarget = mediaTarget(
                    forPickerID: normalizedModelSelection($0),
                    candidates: videoCandidates(.imageToVideo)
                )
                debouncedSave()
            }
        )
    }

    private func mediaPickerID(for target: MediaModelTarget?) -> String? {
        guard let target else { return nil }
        let item = pickerItems.first {
            ($0.mediaModel?.target ?? MediaModelTarget(backend: .local, modelID: $0.id))
                == target
        }
        return item?.id ?? target.modelID
    }

    private func mediaTarget(
        forPickerID pickerID: String?,
        candidates: [ModelPickerItem]
    ) -> MediaModelTarget? {
        guard let pickerID else { return nil }
        guard let item = candidates.first(where: { $0.id == pickerID }) else { return nil }
        return item.mediaModel?.target ?? MediaModelTarget(backend: .local, modelID: item.id)
    }

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

    private func normalizedModelSelection(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Plain toggle-row visual used by the Sandbox tab's execution
    /// permissions and the Appearance tab's greetings switch. The Abilities
    /// overview renders the richer `SettingsAbilityRow` instead.
    /// `interactive: false` dims and disables the switch (sandbox rows use
    /// it when the container isn't running) while keeping the copy
    /// readable. Subtitles wrap instead of truncating.
    private func featureCard(
        title: String,
        subtitle: String,
        isOn: Bool,
        interactive: Bool = true,
        anchorId: String? = nil,
        onChange: @escaping (Bool) -> Void
    ) -> some View {
        SettingsRow(title: title, description: subtitle, anchorId: anchorId) {
            Toggle("", isOn: Binding(get: { isOn }, set: onChange))
                .settingsSwitch()
                .disabled(!interactive)
        }
        .opacity(interactive ? 1 : 0.55)
    }

    /// Per-agent screen-context toggle, nested under Computer Use. Defaults on
    /// with Computer Use; the effective value is gated by Computer Use, so this
    /// row only shows (and only matters) while Computer Use is enabled. What it
    /// captures is described in the row subtitle, and the Preview link below
    /// shows exactly what a new chat would freeze and share.
    private var screenContextToggleRow: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
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
                .settingsSwitch()
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
            HStack(spacing: theme.space.s4) {
                Image(systemName: "eye")
                    .glyphSize(.micro)
                Text(L("Preview screen context"))
                    .font(SettingsFont.smallLabel)
            }
            .foregroundColor(theme.text.link)
        }
        .buttonStyle(PlainButtonStyle())
        .popover(isPresented: $showScreenContextPreview, arrowEdge: .bottom) {
            ScreenContextPreview(previewHeight: 220)
                .frame(width: 440)
                .padding(theme.space.s16)
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
            SettingsMenuPicker(
                selection: Binding<AutonomyPreset?>(
                    get: { computerUseCeiling?.matchingPreset },
                    set: { preset in
                        computerUseCeiling = preset.map { AutonomyCeiling.cappedAt($0) }
                        debouncedSave()
                    }
                )
            ) {
                if computerUseCeiling != nil, selectedPreset == nil {
                    Text("Custom", bundle: .module).tag(AutonomyPreset?.none)
                } else {
                    Text("No ceiling", bundle: .module).tag(AutonomyPreset?.none)
                }
                Divider()
                ForEach(AutonomyPreset.allCases) { preset in
                    Text(String(format: L("At most: %@"), preset.displayLabel)).tag(AutonomyPreset?.some(preset))
                }
            }
        }
    }

    private var ceilingMenuLabel: String {
        guard let ceiling = computerUseCeiling else { return L("No ceiling") }
        if let preset = ceiling.matchingPreset {
            return String(format: L("At most: %@"), preset.displayLabel)
        }
        return L("Custom")
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
                SettingsSection(title: "Configuration") {
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
            SettingsSection(title: "Diagnostics") {
                VStack(alignment: .leading, spacing: theme.space.s8) {
                    Text(
                        String(
                            format: L("Host emitted %d one-shot warning%@ for this plugin."),
                            entries.count,
                            entries.count == 1 ? "" : "s"
                        )
                    )
                    .textStyle(.footnote)
                    .foregroundColor(theme.text.secondary)
                    .padding(.horizontal, theme.space.s16)

                    // Most-recent first so the latest issue is at the
                    // top — matches how console viewers usually order.
                    ForEach(entries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: theme.space.s2) {
                            Text(entry.message)
                                .font(SettingsFont.monoSmall)
                                .foregroundColor(theme.text.primary)
                                .textSelection(.enabled)
                            Text(entry.date.formatted(date: .omitted, time: .standard))
                                .font(SettingsFont.footnote)
                                .foregroundColor(theme.text.tertiary)
                        }
                        .padding(.horizontal, theme.space.s16)
                        .padding(.vertical, theme.space.s8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .settingsChrome(.surface)
                        .padding(.horizontal, theme.space.s16)
                    }
                }
                .padding(.vertical, theme.space.s8)
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

        SettingsSection(title: "Plugin Failed to Load") {
            VStack(alignment: .leading, spacing: theme.space.s14) {
                failedPluginField(label: "Error") {
                    Text(error)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(theme.space.s12)
                        .settingsChrome(.surface)
                }

                failedPluginField(label: "Plugin id") {
                    Text(pid)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.secondary)
                        .textSelection(.enabled)
                }

                failedPluginField(
                    label: "Install path",
                    trailing: { revealInFinderButton(path: installPath) }
                ) {
                    Text(installPath)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                failedPluginField(label: "Most likely cause") {
                    Text(
                        "The plugin's `osr_host_api` mirror struct does not match the host's v6 layout — most often the v5 `log_structured` slot is skipped, which shifts every later slot by 8 bytes. The plugin then dispatches `host->free_string` to the wrong host trampoline and `libc free()` aborts on a non-malloc pointer, killing the host. See `docs/plugins/HOST_API.md → Mirror Struct Audit` and `docs/plugins/ABI_VERSIONS.md` for the pinned offsets and the documented v1..v6 evolution.",
                        bundle: .module
                    )
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: theme.space.s10) {
                    failedPluginActionButton(
                        title: "Retry Load",
                        icon: "arrow.clockwise",
                        role: .secondary,
                        helpText: "Re-load this plugin. Will crash again if the underlying bug is unfixed."
                    ) {
                        pendingFailedPluginRetry = pid
                    }

                    failedPluginActionButton(
                        title: "Uninstall Plugin",
                        icon: "trash",
                        role: .destructive,
                        helpText: "Permanently delete this plugin from disk so the host stops trying to load it."
                    ) {
                        pendingFailedPluginUninstall = pid
                    }

                    Spacer()
                }
                .padding(.horizontal, theme.space.s16)
                .padding(.bottom, theme.space.s8)
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
        VStack(alignment: .leading, spacing: theme.space.s6) {
            HStack(spacing: theme.space.s6) {
                Text(label, bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.tertiary)
                Spacer()
                trailing()
            }
            content()
        }
        .padding(.horizontal, theme.space.s16)
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
            HStack(spacing: theme.space.s4) {
                Image(systemName: "folder")
                    .glyphSize(.micro, weight: .semibold)
                Text("Reveal in Finder", bundle: .module)
                    .font(SettingsFont.smallLabel)
            }
            .foregroundColor(theme.text.link)
        }
        .buttonStyle(.plain)
    }

    private func failedPluginActionButton(
        title: LocalizedStringKey,
        icon: String,
        role: SettingsButtonRole,
        helpText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: theme.space.s6) {
                Image(systemName: icon)
                    .glyphSize(.footnote, weight: .semibold)
                Text(title, bundle: .module)
                    .font(SettingsFont.compactLabel)
            }
        }
        .assignedSettingsButtonStyle(role, size: .compact)
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

        SettingsSection(title: "Instructions") {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                HStack {
                    Text("Customize how the AI uses this plugin.", bundle: .module)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.secondary)

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
                                .font(SettingsFont.smallLabel)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(theme.text.link)
                    }
                }

                SettingsTextEditor(
                    text: Binding(
                        get: { pluginInstructionsMap[pid] ?? manifestDefault },
                        set: { pluginInstructionsMap[pid] = $0 }
                    ),
                    placeholder: L("Custom instructions for this plugin..."),
                    maxHeight: 160
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

        SettingsSection(title: "Route Endpoints") {
            VStack(alignment: .leading, spacing: theme.space.s16) {
                if let baseURL = tunnelBaseURL {
                    routeBaseURLRow(
                        label: "Public URL",
                        url: baseURL,
                        dotColor: theme.status.success.foreground
                    )
                } else {
                    HStack(spacing: theme.space.s6) {
                        Image(systemName: "info.circle")
                            .glyphSize(.micro)
                            .foregroundColor(theme.text.tertiary)
                        Text("Turn on remote access in Sharing → Access to get a public URL.", bundle: .module)
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(theme.text.tertiary)
                    }
                }

                VStack(alignment: .leading, spacing: theme.space.s0) {
                    ForEach(Array(loaded.routes.enumerated()), id: \.element.id) { idx, route in
                        if idx > 0 {
                            ThemeHairlineDivider()
                        }
                        routeRow(route: route, pluginId: pid, baseURL: tunnelBaseURL)
                    }
                }
                .settingsChrome(.subtle)
            }
        }
    }

    private func routeBaseURLRow(label: String, url: String, dotColor: Color) -> some View {
        HStack(spacing: theme.space.s8) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)

            Text(label)
                .font(SettingsFont.chip)
                .foregroundColor(theme.text.tertiary)
                .frame(width: 60, alignment: .leading)

            Text(url)
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.link)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 4)

            routeCopyButton(url: url)
        }
        .padding(theme.space.s8)
        .settingsChrome(.tinted(dotColor))
    }

    private func routeRow(route: PluginManifest.RouteSpec, pluginId: String, baseURL: String?) -> some View {
        let fullPath = "/plugins/\(pluginId)\(route.path)"
        let fullURL = baseURL.map { "\($0)\(route.path)" }

        return VStack(alignment: .leading, spacing: theme.space.s6) {
            HStack(spacing: theme.space.s8) {
                Text(route.methods.joined(separator: ", "))
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(routeMethodColor(route.methods.first ?? "GET"))
                    .padding(.horizontal, theme.space.s6)
                    .padding(.vertical, theme.space.s2)
                    .background(
                        RoundedRectangle(cornerRadius: theme.radius.small)
                            .fill(routeMethodWash(route.methods.first ?? "GET"))
                    )

                Text(fullPath)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)

                Spacer()

                StatusChip(route.auth.rawValue, tint: routeAuthColor(route.auth))

                if let url = fullURL {
                    routeCopyButton(url: url)
                }
            }

            if let desc = route.description, !desc.isEmpty {
                Text(desc)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s8)
    }

    private func routeCopyButton(url: String) -> some View {
        let isCopied = copiedRouteURL == url
        return SettingsIconButton(isCopied ? "checkmark" : "doc.on.doc", help: isCopied ? "Copied" : "Copy URL", size: .extraSmall) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
            copiedRouteURL = url
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if copiedRouteURL == url { copiedRouteURL = nil }
            }
        }
    }

    private func routeMethodColor(_ method: String) -> Color {
        DataInk.httpMethod(method).map(theme.dataInk) ?? theme.action.primary.default.background
    }

    private func routeMethodWash(_ method: String) -> Color {
        DataInk.httpMethod(method).map(theme.dataWash) ?? theme.surface.hover
    }

    private func routeAuthColor(_ auth: PluginManifest.RouteAuth) -> Color {
        switch auth {
        case .none: return theme.dataInk(.green)
        case .verify: return theme.dataInk(.orange)
        case .owner: return theme.dataInk(.blue)
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

        SettingsSection(title: "Sandbox", caption: subtitle) {
            VStack(alignment: .leading, spacing: theme.space.s16) {
                if !sandboxAvailable {
                    SettingsEmptyState(
                        inline: "shippingbox",
                        title: "Sandbox unavailable",
                        hint: "Sandboxed execution is unavailable on this device. Native plugins continue to work normally."
                    )
                } else if !sandboxRunning {
                    workspaceFolderRow
                    SettingsEmptyState(
                        inline: "shippingbox",
                        title: "Sandbox not running",
                        hint: "It starts on its own the first time this agent runs a command, once Autonomous Execution is on above."
                    )
                    AgentKeysSection(agentId: agent.id)
                } else {
                    workspaceFolderRow
                    AgentKeysSection(agentId: agent.id)
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

        return SettingsRow(
            title: "Workspace Folder",
            description: "Browse and edit files in this agent's /workspace/agents/… home."
        ) {
            SettingsButton(
                .secondary,
                "Open in Finder",
                icon: "folder",
                size: .compact,
                help: isProvisioned
                    ? "Reveal this agent's sandbox home folder in Finder."
                    : "Set up the sandbox to enable the workspace."
            ) {
                OsaurusPaths.revealInFinder(workspaceURL)
            }
            .disabled(!isProvisioned)
        }
        .environment(\.settingsInGroup, true)
        .settingsLandingAnchor("agents.sandbox.workspaceFolder")
    }

    /// Working Folder row (Abilities → Overview). Shows and edits the agent's
    /// sticky working folder (`Agent.workingFolderBookmark`) — the same record
    /// the chat Folder chip writes. Fresh chats for the agent open in it
    /// (`ChatWindowState.adoptAgentWorkingFolder`), folder-less background
    /// dispatches run in it (`BackgroundTaskManager.resolveDispatchFolder`),
    /// and an authenticated remote agent run (Secure Channel, agent-scoped
    /// key) mounts it as its confined file-tool root
    /// (`HTTPHandler.handleAgentRunEndpoint` →
    /// `ChatExecutionContext.authenticatedHostFolderRoot`) with shell/git
    /// denied on that surface.
    /// Independent of the Linux sandbox, so it renders regardless of sandbox
    /// availability.
    @ViewBuilder
    private var workingFolderRow: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            Text(
                "Applies to new chats and to background runs without a folder of their own. A project's folder still wins for chats started inside that project.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: theme.space.s12) {
                Text(workingFolderPath ?? L("No folder selected"))
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(
                        workingFolderPath == nil ? theme.text.tertiary : theme.text.primary
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("agentEditor.workingFolderPath")
                Spacer()
                SettingsButton(
                    .secondary,
                    workingFolderPath == nil ? "Choose…" : "Change…",
                    icon: "folder",
                    size: .compact,
                    action: chooseWorkingFolder
                )
                if workingFolderPath != nil {
                    SettingsIconButton("xmark", help: "Clear working folder", size: .compact) { clearWorkingFolder() }
                    .accessibilityIdentifier("agentEditor.clearWorkingFolder")
                }
            }
            if !recentFolders.entries.isEmpty {
                RecentFoldersList(activePath: workingFolderPath, showsPath: true, horizontalInset: 0) { entry in
                    applyRecentWorkingFolder(entry)
                }
                .environment(\.theme, theme)
                .padding(.top, theme.space.s4)
            }
        }
    }

    /// Present a folder picker, mint a security-scoped bookmark, and persist it
    /// as the agent's working folder — the same record the chat Folder chip
    /// writes, so the two surfaces always agree.
    private func chooseWorkingFolder() {
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.title = L("Select Working Folder")
            panel.message = L("Choose the folder this agent works inside.")
            panel.prompt = L("Select")

            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            guard let bookmark = FolderContextService.makeSecurityScopedBookmark(for: url) else {
                ToastManager.shared.error(L("Failed to grant folder access"))
                return
            }
            let path = url.standardizedFileURL.path
            agentManager.updateWorkingFolder(for: agent.id, bookmark: bookmark, path: path)
            RecentFoldersStore.shared.record(path: path, bookmark: bookmark)
            workingFolderPath = path
        }
    }

    /// Apply a remembered folder as the agent's working folder. Resolves the
    /// entry off the main actor and mints a fresh bookmark, then persists it
    /// exactly as a panel pick does. A folder that no longer resolves is
    /// dropped from the list and reported.
    private func applyRecentWorkingFolder(_ entry: RecentFoldersStore.Entry) {
        Task { @MainActor in
            guard let url = await RecentFoldersStore.resolveURL(for: entry) else {
                recentFolders.remove(path: entry.path)
                ToastManager.shared.error(L("Folder no longer available"), message: entry.path)
                return
            }
            let bookmark = await Task.detached(priority: .userInitiated) {
                FolderContextService.makeSecurityScopedBookmark(for: url)
            }.value
            guard let bookmark else {
                ToastManager.shared.error(L("Failed to grant folder access"))
                return
            }
            let path = url.standardizedFileURL.path
            agentManager.updateWorkingFolder(for: agent.id, bookmark: bookmark, path: path)
            workingFolderPath = path
            recentFolders.record(path: path, bookmark: bookmark)
        }
    }

    /// Forget the agent's working folder.
    private func clearWorkingFolder() {
        agentManager.clearWorkingFolder(for: agent.id)
        workingFolderPath = nil
    }

    /// Sandbox execution toggles, surfaced in the Sandbox tab's Execution
    /// section via the shared `featureCard` visual. `interactive` is false
    /// only when the sandbox is unavailable: users can configure execution
    /// before first provisioning without triggering a runtime start.
    @ViewBuilder
    private func sandboxExecToggles(
        execConfig: AutonomousExecConfig?,
        interactive: Bool = true
    ) -> some View {
        featureCard(
            title: "Autonomous Execution",
            subtitle: "Allow the agent to run arbitrary commands in the sandbox.",
            isOn: execConfig?.enabled ?? false,
            interactive: interactive,
            anchorId: "agents.sandbox.autonomousExecution"
        ) { enabled in
            updateAutonomousExec(from: execConfig) { $0.enabled = enabled }
        }

        if execConfig?.enabled == true {
            sandboxFolderSuspensionHint

            featureCard(
                title: "Plugin Creation",
                subtitle: "Let the agent create its own tools as plugins.",
                isOn: execConfig?.pluginCreate ?? false,
                interactive: interactive,
                anchorId: "agents.sandbox.pluginCreation"
            ) { create in
                updateAutonomousExec(from: execConfig) { $0.pluginCreate = create }
            }

            featureCard(
                title: "Sandbox Network",
                subtitle:
                    "Let this agent's sandbox commands reach the internet. Applies to this agent only; if the running sandbox has to change, it restarts once running commands finish.",
                isOn: execConfig?.sandboxNetworkEnabled ?? true,
                interactive: interactive,
                anchorId: "agents.sandbox.network"
            ) { networkOn in
                updateAutonomousExec(from: execConfig) { $0.sandboxNetworkEnabled = networkOn }
            }

            if execConfig?.sandboxNetworkEnabled ?? true {
                // The filtering egress proxy is a vmnet construct — on the
                // Seatbelt backend a domain allowlist would fail closed to
                // NO network, so don't offer the field there.
                if SandboxBackend.current == .virtualMachine {
                    sandboxAllowedDomainsField(execConfig: execConfig, interactive: interactive)
                } else {
                    Text(
                        "Per-domain network allowlists require the VM sandbox (macOS 26 or later). On this device sandbox network access is all-or-nothing — use the Sandbox Network toggle above.",
                        bundle: .module
                    )
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, theme.space.s2)
                }
            }

            featureCard(
                title: "Background Processes",
                subtitle:
                    "Let the agent run long-lived processes (servers, watchers) detached and manage them. Off by default to keep the tool surface lean.",
                isOn: execConfig?.backgroundProcessEnabled ?? false,
                interactive: interactive,
                anchorId: "agents.sandbox.backgroundProcesses"
            ) { backgroundOn in
                updateAutonomousExec(from: execConfig) { $0.backgroundProcessEnabled = backgroundOn }
            }

            featureCard(
                title: "Code Can Use Osaurus",
                subtitle:
                    "Let commands in this agent's sandbox run model completions, start agent tasks, and register plugins through Osaurus (osaurus-host inference, agent dispatch, plugin create). Off by default.",
                isOn: execConfig?.hostServicesEnabled ?? false,
                interactive: interactive,
                anchorId: "agents.sandbox.hostServices"
            ) { hostOn in
                updateAutonomousExec(from: execConfig) { $0.hostServicesEnabled = hostOn }
            }

            Text(
                "Sandbox execution cannot access a selected Mac folder. Disable Sandbox to resume the writable Trusted Folder.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, theme.space.s2)
        }
    }

    /// Sandbox execution rows for the Sandbox tab's Execution section.
    /// Shows the toggles in every sandbox state: disabled only when the
    /// sandbox is unavailable, and otherwise configurable before first
    /// provisioning. The tab gates this on
    /// `isCustomAgent`.
    @ViewBuilder
    private var sandboxExecSubsection: some View {
        let sandboxAvailable = SandboxManager.State.shared.availability.isAvailable
        let sandboxRunning = SandboxManager.State.shared.status == .running
        let execConfig =
            abilityPreviewAutonomousConfig
            ?? agentManager.effectiveAutonomousExec(for: agent.id)

        sandboxExecToggles(execConfig: execConfig, interactive: sandboxAvailable)
        if !sandboxAvailable {
            sandboxFeatureHint("Sandboxed execution is unavailable on this device.")
        } else if !sandboxRunning {
            sandboxFeatureHint(
                "Changes will apply when the sandbox starts."
            )
        }
    }

    /// Egress domain allowlist editor. Empty keeps unrestricted outbound
    /// (today's default); a non-empty comma-separated list switches the
    /// sandbox to host-only networking with the filtering proxy on the
    /// next boot, limiting outbound connections to the listed domains
    /// (`example.com` exact, `*.example.com` subdomains) plus domains the
    /// agent's plugins declare.
    @ViewBuilder
    private func sandboxAllowedDomainsField(
        execConfig: AutonomousExecConfig?,
        interactive: Bool
    ) -> some View {
        SettingsFieldRow(
            label: "Allowed Domains",
            hint:
                "Comma-separated (e.g. api.github.com, *.example.com). When set, this agent reaches only these domains and the ones its plugins declare, over HTTP and HTTPS through a filtering proxy. Other connections, such as SSH, are blocked."
        ) {
            SettingsTextField(
                placeholder: L("Leave empty for unrestricted outbound"),
                text: $sandboxAllowedDomainsText,
                onSubmit: { commitSandboxAllowedDomains(execConfig: execConfig) }
            )
            .disabled(!interactive)
            .onAppear {
                sandboxAllowedDomainsText =
                    execConfig?.sandboxAllowedDomains?.joined(separator: ", ") ?? ""
            }
        }
        .padding(.leading, theme.space.s2)
        .opacity(interactive ? 1 : 0.5)
        .settingsLandingAnchor("agents.sandbox.allowedDomains")
    }

    private func commitSandboxAllowedDomains(execConfig: AutonomousExecConfig?) {
        let raw = sandboxAllowedDomainsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalized = SandboxEgressPolicy.normalizedAllowlist(raw)
        updateAutonomousExec(from: execConfig) {
            $0.sandboxAllowedDomains = normalized.isEmpty ? nil : normalized
        }
        sandboxAllowedDomainsText = normalized.joined(separator: ", ")
    }

    /// Small explanatory line shown under the sandbox toggles when they're
    /// disabled because the sandbox isn't ready.
    private func sandboxFeatureHint(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: theme.space.s6) {
            Image(systemName: "info.circle")
                .glyphSize(.footnote)
                .foregroundColor(theme.text.tertiary)
            Text(text, bundle: .module)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.leading, theme.space.s2)
    }

    private func updateAutonomousExec(
        from current: AutonomousExecConfig?,
        _ mutate: (inout AutonomousExecConfig) -> Void
    ) {
        let previous = current
        var config = current ?? .default
        mutate(&config)
        abilityPreviewAutonomousConfig = config
        Task { @MainActor in
            do {
                try await agentManager.updateAutonomousExec(config, for: agent.id)
            } catch {
                abilityPreviewAutonomousConfig = previous
                ToastManager.shared.error(
                    L("Failed to update sandbox access"),
                    message: error.localizedDescription
                )
            }
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

        return VStack(alignment: .leading, spacing: theme.space.s10) {
            HStack {
                Image(systemName: icon)
                    .glyphSize(.footnote, weight: .semibold)
                    .foregroundColor(theme.text.link)
                    .frame(width: 16)
                Text(label)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)

                Text(!enabled ? "Hidden" : isCustomized ? "\(resolved.count) custom" : "Default")
                    .font(SettingsFont.chip)
                    .foregroundColor(theme.text.tertiary)

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
                .settingsSwitch()
            }

            if enabled {
                VStack(spacing: theme.space.s0) {
                    ForEach(Array(resolved.enumerated()), id: \.element.id) { index, action in
                        if index > 0 {
                            Divider().background(theme.border.subtle)
                        }
                        quickActionRow(
                            action: action,
                            index: index,
                            actions: actions,
                            isCustomized: isCustomized
                        )
                    }
                }
                .settingsChrome(.control)
                .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium))

                HStack(spacing: theme.space.s12) {
                    Button {
                        if actions.wrappedValue == nil {
                            actions.wrappedValue = defaults
                        }
                        let newAction = AgentQuickAction(icon: "star", text: "", prompt: "")
                        actions.wrappedValue!.append(newAction)
                        editingQuickActionId = newAction.id
                        debouncedSave()
                    } label: {
                        HStack(spacing: theme.space.s4) {
                            Image(systemName: "plus")
                                .glyphSize(.micro, weight: .semibold)
                            Text("Add", bundle: .module)
                                .font(SettingsFont.compactLabel)
                        }
                        .foregroundColor(theme.text.link)
                    }
                    .buttonStyle(PlainButtonStyle())

                    if isCustomized {
                        Button {
                            actions.wrappedValue = nil
                            editingQuickActionId = nil
                            debouncedSave()
                        } label: {
                            HStack(spacing: theme.space.s4) {
                                Image(systemName: "arrow.uturn.backward")
                                    .glyphSize(.micro)
                                Text("Reset to Defaults", bundle: .module)
                                    .font(SettingsFont.compactLabel)
                            }
                            .foregroundColor(theme.text.secondary)
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

        return VStack(spacing: theme.space.s0) {
            HStack(spacing: theme.space.s10) {
                Image(systemName: action.icon)
                    .glyphSize(.label, weight: .medium)
                    .foregroundColor(theme.text.link)
                    .frame(width: 20)

                SettingsRowText {
                    Text(action.text.isEmpty ? L("Untitled") : action.text)
                        .foregroundColor(action.text.isEmpty ? theme.text.placeholder : theme.text.primary)
                        .lineLimit(1)
                } description: {
                    Text(action.prompt.isEmpty ? L("No prompt") : action.prompt)
                        .lineLimit(1)
                }

                Spacer()

                if isCustomized {
                    HStack(spacing: theme.space.s4) {
                        Button {
                            editingQuickActionId = isEditing ? nil : action.id
                        } label: {
                            Image(systemName: "pencil")
                                .glyphSize(.footnote, weight: .medium)
                                .foregroundColor(isEditing ? theme.text.link : theme.text.tertiary)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(PlainButtonStyle())

                        if index > 0 {
                            Button {
                                moveQuickAction(in: actions, from: index, direction: -1)
                            } label: {
                                Image(systemName: "chevron.up")
                                    .glyphSize(.micro, weight: .semibold)
                                    .foregroundColor(theme.text.tertiary)
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        if index < (actions.wrappedValue?.count ?? 0) - 1 {
                            Button {
                                moveQuickAction(in: actions, from: index, direction: 1)
                            } label: {
                                Image(systemName: "chevron.down")
                                    .glyphSize(.micro, weight: .semibold)
                                    .foregroundColor(theme.text.tertiary)
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        SettingsIconButton("xmark", help: "Remove", size: .compact) { deleteQuickAction(in: actions, at: index) }
                    }
                }
            }
            .padding(.horizontal, theme.space.s12)
            .padding(.vertical, theme.space.s8)
            .contentShape(Rectangle())
            .onTapGesture {
                if isCustomized {
                    editingQuickActionId = isEditing ? nil : action.id
                }
            }

            if isEditing, isCustomized {
                VStack(spacing: theme.space.s10) {
                    Divider().background(theme.border.subtle)

                    HStack(spacing: theme.space.s10) {
                        SettingsTextField(
                            placeholder: L("SF Symbol name"),
                            text: quickActionBinding(in: actions, for: action.id, keyPath: \.icon),
                            icon: "star"
                        )
                        .frame(width: 160)

                        SettingsTextField(
                            placeholder: L("Display text"),
                            text: quickActionBinding(in: actions, for: action.id, keyPath: \.text),
                            icon: "textformat"
                        )
                    }

                    SettingsTextField(
                        placeholder: L("Prompt prefix (e.g. 'Explain ')"),
                        text: quickActionBinding(in: actions, for: action.id, keyPath: \.prompt),
                        icon: "text.cursor"
                    )
                }
                .padding(.horizontal, theme.space.s12)
                .padding(.bottom, theme.space.s8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(theme.motion.quick, value: isEditing)
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

    // MARK: - Automation Tab Sections

    private var eventsSection: some View {
        SettingsSection(
            title: "Automations",
            caption: linkedEvents.isEmpty ? L("None") : "\(linkedEvents.count)"
        ) {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                if linkedEvents.isEmpty {
                    SettingsEmptyState(
                        inline: "bolt.badge.clock",
                        title: "No automations yet",
                        hint: "Run this agent on a schedule, when files change, when a webhook is called, or when a channel message arrives.",
                        action: SettingsEmptyState.Action(title: L("Add Automation"), icon: "", handler: { eventEditor = EventEditorRequest(initialAgentId: agent.id) })
                    )
                } else {
                    ForEach(linkedEvents) { event in
                        eventRow(event)
                    }

                    HStack(spacing: theme.space.s16) {
                        Button {
                            eventEditor = EventEditorRequest(initialAgentId: agent.id)
                        } label: {
                            HStack(spacing: theme.space.s4) {
                                Image(systemName: "plus.circle")
                                    .glyphSize(.footnote)
                                Text("Add Automation", bundle: .module)
                                    .font(SettingsFont.smallLabel)
                            }
                            .foregroundColor(theme.text.link)
                        }
                        .buttonStyle(PlainButtonStyle())

                        Button {
                            AppDelegate.shared?.showManagementWindow(initialTab: .automations)
                        } label: {
                            Text("Manage in Automations", bundle: .module)
                                .font(SettingsFont.smallLabel)
                                .foregroundColor(theme.text.secondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
        }
    }

    private func eventRow(_ event: OsaurusEvent) -> some View {
        HStack(spacing: theme.space.s12) {
            Image(systemName: EventSourceTemplate.icon(for: event))
                .glyphSize(.footnote)
                .foregroundColor(event.isEnabled ? theme.status.success.foreground : theme.text.tertiary)
                .frame(width: 14)

            SettingsRowText {
                Text(event.name)
            } description: {
                HStack(spacing: theme.space.s8) {
                    Text(event.sourceSummary)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(1)

                    if let nextRun = event.nextRunDescription {
                        Text("Next: \(nextRun)", bundle: .module)
                    } else if let last = event.lastFiredAt {
                        Text("Last: \(last.formatted(date: .abbreviated, time: .shortened))", bundle: .module)
                    }
                }
            }

            Spacer()

            StatusChip(event.isEnabled ? L("Active") : L("Paused"), tone: event.isEnabled ? .success : .neutral)
        }
        .padding(theme.space.s8)
        .settingsChrome(.control)
    }

    // MARK: - Memory Tab Sections

    private var historySection: some View {
        SettingsSection(
            title: "History",
            subtitle: L("\(chatSessions.count) chat\(chatSessions.count == 1 ? "" : "s")")
        ) {
            VStack(alignment: .leading, spacing: theme.space.s16) {
                VStack(alignment: .leading, spacing: theme.space.s8) {
                    HStack {
                        HStack(spacing: theme.space.s6) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .glyphSize(.micro, weight: .medium)
                                .foregroundColor(theme.text.link)
                            Text("Recent chats", bundle: .module)
                                .font(SettingsFont.compactLabel)
                                .foregroundColor(theme.text.secondary)
                        }
                        Spacer()
                        Button {
                            ChatWindowManager.shared.createWindow(agentId: agent.id)
                        } label: {
                            HStack(spacing: theme.space.s2) {
                                Image(systemName: "plus")
                                    .glyphSize(.tiny, weight: .semibold)
                                Text("New Chat", bundle: .module)
                                    .font(SettingsFont.chip)
                            }
                            .foregroundColor(theme.text.link)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    if chatSessions.isEmpty {
                        SettingsEmptyState(
                            inline: "bubble.left.and.bubble.right.fill",
                            title: "No chats yet",
                            hint: "Start a conversation to build this agent's memory — history, pinned facts, and episode summaries all flow from here.",
                            action: SettingsEmptyState.Action(title: L("New Chat"), icon: "", handler: { ChatWindowManager.shared.createWindow(agentId: agent.id) })
                        )
                    } else {
                        ForEach(chatSessions.prefix(5)) { session in
                            ClickableHistoryRow {
                                ChatWindowManager.shared.createWindow(
                                    agentId: agent.id,
                                    sessionData: session
                                )
                            } content: {
                                HStack(spacing: theme.space.s10) {
                                    VStack(alignment: .leading, spacing: theme.space.s2) {
                                        Text(session.title)
                                            .font(SettingsFont.compactLabel)
                                            .foregroundColor(theme.text.primary)
                                            .lineLimit(1)

                                        Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(SettingsFont.footnote)
                                            .foregroundColor(theme.text.tertiary)
                                    }
                                    Spacer()
                                    HStack(spacing: theme.space.s4) {
                                        let turnCount =
                                            sessionTurnCounts[session.id]
                                            ?? session.turns.count
                                        Text(turnCount == 1 ? L("1 turn") : L("\(turnCount) turns"))
                                            .font(SettingsFont.footnote)
                                            .foregroundColor(theme.text.tertiary)
                                        Image(systemName: "arrow.up.right")
                                            .glyphSize(.tiny, weight: .medium)
                                            .foregroundColor(theme.text.tertiary)
                                    }
                                }
                            }
                        }
                        if chatSessions.count > 5 {
                            Text("and \(chatSessions.count - 5) more...", bundle: .module)
                                .font(SettingsFont.rowDescription)
                                .foregroundColor(theme.text.tertiary)
                                .padding(.leading, theme.space.s4)
                        }
                    }
                }

            }
        }
    }

    private var pinnedFactsSection: some View {
        SettingsSection(
            title: "Pinned Facts",
            caption: pinnedFacts.isEmpty ? L("None") : "\(pinnedFacts.count)"
        ) {
            if pinnedFacts.isEmpty {
                SettingsEmptyState(
                    inline: "pin.slash",
                    title: "No pinned facts yet",
                    hint: "Facts are promoted from session distillations once they accumulate enough salience. Keep chatting and they'll show up here."
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
        SettingsSection(
            title: "Episodes",
            caption: episodes.isEmpty ? L("None") : "\(episodes.count)"
        ) {
            if episodes.isEmpty {
                SettingsEmptyState(
                    inline: "doc.text.magnifyingglass",
                    title: "No episodes yet",
                    hint: "After each chat, the agent distills the conversation into a short summary. Episodes accumulate here so the agent can recall past sessions."
                )
            } else {
                VStack(alignment: .leading, spacing: theme.space.s0) {
                    let displayed = showAllSummaries ? episodes : Array(episodes.prefix(10))

                    ForEach(Array(displayed.enumerated()), id: \.element.id) { index, episode in
                        if index > 0 {
                            ThemeHairlineDivider()
                        }
                        EpisodeRow(episode: episode)
                    }

                    if episodes.count > 10 {
                        Button {
                            withAnimation(theme.motion.quick) {
                                showAllSummaries.toggle()
                            }
                        } label: {
                            Text(showAllSummaries ? "Show Less" : "View All \(episodes.count) Episodes")
                                .font(SettingsFont.smallLabel)
                                .foregroundColor(theme.text.link)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.top, theme.space.s8)
                    }
                }
            }
        }
    }

    /// Danger-zone card at the end of the General tab. Lets the user wipe the
    /// agent's accumulated data (chats, facts, episodes) without deleting the
    /// agent itself, which was previously the only way to start over.
    private var deleteAllDataSection: some View {
        SettingsSection(title: "Delete All Data") {
            Text("Remove this agent's chats and memory. The agent itself stays.", bundle: .module)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)

            Button {
                presentDeleteAllData()
            } label: {
                HStack(spacing: theme.space.s6) {
                    Image(systemName: "trash")
                        .glyphSize(.footnote, weight: .medium)
                    Text("Delete Data…", bundle: .module)
                        .font(SettingsFont.compactLabel)
                }
                .foregroundColor(theme.status.error.foreground)
                .padding(.horizontal, theme.space.s12)
                .padding(.vertical, theme.space.s8)
                .settingsChrome(.status(.error))
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    /// Confirmation alert with per-category checkboxes so the user picks
    /// exactly what to wipe instead of the app guessing. Uses the alert's
    /// `customContent` slot rather than plain `buttons` because the dialog
    /// stays up while the deletion runs: both buttons disable and the
    /// destructive one shows a spinner, which the fire-and-dismiss standard
    /// button row can't express.
    private func presentDeleteAllData() {
        let selection = AgentDataWipeSelection()
        let requestId = UUID()
        let scope = alertScope
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: L("Delete Agent Data"),
                message: nil,
                // Never rendered (customContent owns the button row). The
                // destructive entry keeps the warning-triangle header, and
                // the absence of a cancel-role button means clicking the
                // dimmed overlay can't dismiss the dialog mid-deletion.
                buttons: [.destructive(L("Delete Selected")) {}],
                customContent: AnyView(
                    AgentDataWipeDialogContent(
                        selection: selection,
                        message: L(
                            "Choose what to permanently delete for \"\(currentAgent.name)\". The agent itself stays. This can't be undone."
                        ),
                        chatCount: chatSessions.count,
                        factCount: pinnedFacts.count,
                        episodeCount: episodes.count,
                        onCancel: {
                            ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                        },
                        onDelete: {
                            await performDeleteAllData(selection)
                            ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                        }
                    )
                ),
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }

    private func performDeleteAllData(_ selection: AgentDataWipeSelection) async {
        let wipeChats = selection.chats
        let wipeFacts = selection.pinnedFacts
        let wipeEpisodes = selection.episodes
        guard wipeChats || wipeFacts || wipeEpisodes else { return }
        let agentId = agent.id
        let agentScope = agentId.uuidString
        if wipeChats {
            await ChatSessionsManager.shared.deleteAll(for: agentId)
        }
        // Memory DB deletes run off the main actor — same rationale as
        // `loadMemoryData`: these calls dispatch-sync onto the DB's
        // serial queue and can otherwise stall the appear path.
        await Task.detached(priority: .userInitiated) {
            let db = MemoryDatabase.shared
            if !db.isOpen { try? db.open() }
            if wipeFacts { try? db.deletePinnedFacts(forAgent: agentScope) }
            if wipeEpisodes { try? db.deleteEpisodes(forAgent: agentScope) }
            if wipeChats { try? db.deleteConversationMemory(forAgent: agentScope) }
        }.value
        if wipeFacts && wipeEpisodes && wipeChats {
            // Full wipe: the on-disk vector index has nothing left to
            // serve, so remove it rather than leaving deleted content
            // in the encrypted store.
            await MemorySearchService.shared.deleteAgentIndex(agentId: agentScope)
        } else if wipeFacts || wipeEpisodes {
            // Partial wipe: drop the in-memory instance; stale on-disk
            // vectors resolve to missing SQL rows and are filtered on
            // read, same as single-item deletes.
            await MemorySearchService.shared.evictAgent(agentId: agentScope)
        }
        guard agentId == agent.id else { return }
        refreshDetailCaches()
        loadMemoryData()
        showSuccess(L("Selected data deleted"))
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
        // The navigation selection can predate a change made in chat.
        let agent = currentAgent
        let globalSpawnConfiguration = SubagentConfigurationStore.snapshot()
        name = agent.name
        description = agent.description
        systemPrompt = agent.systemPrompt
        temperature = agent.temperature.map { String($0) } ?? ""
        maxTokens = agent.maxTokens.map { String($0) } ?? ""
        generationSettings = agent.generationSettings
        claudeCodeConfig = agentManager.effectiveClaudeCodeConfig(for: agent.id)
        agentRuntime = agentManager.effectiveRuntime(for: agent.id)
        chatQuickActions = agent.chatQuickActions
        chatGreetingDraft = agent.chatGreeting ?? ""
        chatSubtitleDraft = agent.chatSubtitle ?? ""
        toolsEnabled = agent.toolsEnabled
        memoryEnabled = agent.memoryEnabled
        dbEnabled = agent.settings.dbEnabled
        renderChartEnabled = agent.settings.renderChartEnabled
        calculatorEnabled = agent.settings.calculatorEnabled
        redactionToolsEnabled = agent.settings.redactionToolsEnabled
        taskChecklistEnabled = agent.settings.taskChecklistEnabled
        clarifyEnabled = agent.settings.clarifyEnabled
        artifactsEnabled = agent.settings.artifactsEnabled
        workingFolderReadOnly = agent.settings.workingFolderReadOnly
        showResponseMetrics = agent.settings.showResponseMetrics
        speakEnabled = agent.settings.speakEnabled
        searchMemoryEnabled = agent.settings.searchMemoryEnabled
        webSearchEnabled = agent.settings.webSearchEnabled
        followUpEnabled = agent.settings.followUp.enabled
        followUpModel = agent.settings.followUp.model
        selfSchedulingEnabled = agent.settings.selfSchedulingEnabled
        knowledgeEnabled = agent.settings.knowledgeEnabled
        knowledgeCollectionIds = agent.settings.knowledgeCollectionIds
        knowledgeCuratorEnabled = agent.settings.knowledgeCuratorEnabled
        subagentToggles = SubagentCapabilityRegistry.perAgentToggleFlags.reduce(into: [:]) {
            acc,
            flag in
            acc[flag] = flag.read(from: agent.settings)
        }
        computerUseCeiling = agent.settings.computerUseCeiling
        screenContextEnabled = agent.settings.screenContextEnabled
        spawnableAgentIDs = agent.settings.spawnableAgentIDs
        spawnableWorkspaceAgents = agent.settings.spawnableWorkspaceAgents
        imageGenerationTarget = agent.settings.imageGenerationTarget
        imageEditModelId = agent.settings.imageEditModelId
        textToVideoTarget = agent.settings.textToVideoTarget
        imageToVideoTarget = agent.settings.imageToVideoTarget
        appleScriptModelId = agent.settings.appleScriptModelId
        appleScriptExecutionMode = agent.settings.appleScriptExecutionMode
        subagentPermissions = agent.settings.subagentPermissions
        loadedSubagentPermissions = agent.settings.subagentPermissions
        subagentBudgets = SpawnBatchConcurrencyContract.applyingSharedLimit(
            from: globalSpawnConfiguration,
            to: agent.settings.subagentBudgets
        )
        subagentModelOverrides = agent.settings.subagentModelOverrides
        // Snapshot the global subagent config for the spawn-handoff warning.
        globalSubagentConfig = globalSpawnConfiguration
        workingFolderPath = agent.workingFolderPath
        abilityPreviewToolMode = agentManager.effectiveToolSelectionMode(for: agent.id)
        abilityPreviewToolNames = Set(agentManager.effectiveEnabledToolNames(for: agent.id) ?? [])
        abilityPreviewAutonomousConfig = agentManager.effectiveAutonomousExec(for: agent.id)
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
        // Every database call here dispatch-syncs onto the DB's serial queue;
        // when that queue is busy with background writes the wait has hung
        // the appear path. Read off the main actor and publish back.
        let agentId = agent.id
        Task {
            let (facts, loadedEpisodes, counts) = await Task.detached(priority: .userInitiated) {
                let db = MemoryDatabase.shared
                if !db.isOpen { try? db.open() }
                let facts = (try? db.loadPinnedFacts(agentId: agentId.uuidString, limit: 200)) ?? []
                let loadedEpisodes =
                    (try? db.loadEpisodes(agentId: agentId.uuidString, limit: 100)) ?? []
                // Counts come from the store's message counts so the row's
                // "N turns" label is accurate without hydrating each session's
                // turn array (which only happens on click — the prior root cause
                // of the persistent "0 turns" display).
                let agentFilter: UUID? = (agentId == Agent.defaultId) ? nil : agentId
                let counts = ConversationStores.current.turnCounts(forAgent: agentFilter)
                return (facts, loadedEpisodes, counts)
            }.value
            guard agentId == agent.id else { return }
            pinnedFacts = facts
            episodes = loadedEpisodes
            sessionTurnCounts = counts
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

    /// Preserve fields saved directly by pickers. Only the generation editor's
    /// explicit Save may replace live generation defaults; a rename must not
    /// write a stale snapshot back over a newer chat-picker choice.
    static func carryDirectlySavedFields(
        from current: Agent, into updated: inout Agent,
        generationValues: AgentGenerationDraft.Values? = nil
    ) {
        updated.workingFolderBookmark = current.workingFolderBookmark
        updated.workingFolderPath = current.workingFolderPath
        updated.defaultModel = current.defaultModel
        let values = generationValues ?? .init(
            temperature: current.temperature, maxTokens: current.maxTokens,
            settings: current.generationSettings
        )
        updated.temperature = values.temperature
        updated.maxTokens = values.maxTokens
        updated.generationSettings = values.settings
    }

    @MainActor
    private func saveAgent(generationValues: AgentGenerationDraft.Values? = nil) {
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
        let reconciledSubagentPermissions =
            SubagentPermissionDefaults.mergingEditorSnapshot(
                subagentPermissions,
                loadedBaseline: loadedSubagentPermissions,
                live: current.settings.subagentPermissions
            )
        // The tool picker writes `manualToolNames` and
        // `toolSelectionMode` directly via `AgentManager.update*` calls (so they
        // save instantly without going through this debounced path). We therefore
        // pass through `current.*` values rather than this view's local mirrors,
        // which only get refreshed via `loadAgentData()`. Otherwise the debounced
        // save could lose a picker change made between load and save.
        let trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // The background summary lives on the live record, not in this form;
        // carry it through so a save does not discard it and force a
        // regeneration. A summary of a different prompt is stale routing
        // metadata, so drop it and let `AgentDescriptionBackfill` redo it.
        let promptUnchanged =
            current.generatedDescriptionPromptHash == AgentDescriptionPolicy.promptHash(trimmedPrompt)
        var updated = Agent(
            id: agent.id,
            name: trimmedName,
            description: AgentDescriptionPolicy.normalized(description),
            generatedDescription: promptUnchanged ? current.generatedDescription : nil,
            generatedDescriptionPromptHash: promptUnchanged ? current.generatedDescriptionPromptHash : nil,
            systemPrompt: trimmedPrompt,
            defaultModel: selectedModel,
            temperature: Float(temperature),
            maxTokens: Int(maxTokens),
            generationSettings: generationSettings,
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
            agentDeviceScope: current.agentDeviceScope,
            autonomousExec: current.autonomousExec,
            claudeCode: current.claudeCode,
            runtime: current.runtime,
            pluginInstructions: effectivePluginInstructions,
            toolSelectionMode: current.toolSelectionMode,
            manualToolNames: current.manualToolNames,
            skillNames: current.skillNames,
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
                showResponseMetrics: showResponseMetrics,
                renderChartEnabled: renderChartEnabled,
                speakEnabled: speakEnabled,
                searchMemoryEnabled: searchMemoryEnabled,
                webSearchEnabled: webSearchEnabled,
                followUp: AgentFollowUpConfig(enabled: followUpEnabled, model: followUpModel),
                selfSchedulingEnabled: selfSchedulingEnabled,
                computerUseEnabled: computerUseEnabled,
                computerUseCeiling: computerUseEnabled ? computerUseCeiling : nil,
                screenContextEnabled: screenContextEnabled,
                browserUseEnabled: browserUseEnabled,
                spawnDelegationEnabled: spawnDelegationEnabled,
                imageEnabled: imageEnabled,
                videoEnabled: videoEnabled,
                // AppleScript enable + model + execution mode, declared right
                // after imageEnabled to match the AgentSettings initializer's
                // parameter order. Persist unconditionally (like the image
                // fields): a stored choice is ignored while the capability is
                // off, so a toggle round-trip keeps the user's pick.
                appleScriptEnabled: appleScriptEnabled,
                appleScriptModelId: appleScriptModelId,
                appleScriptExecutionMode: appleScriptExecutionMode,
                // Persist the configured pool even while Spawn is off. The
                // capability flag still hides/refuses the tool, while a later
                // re-enable restores the user's deliberate agents instead of
                // silently destroying them.
                spawnableAgentIDs: spawnableAgentIDs,
                // Image models / permissions / budgets persist unconditionally —
                // a stored model id is ignored while the capability is off, so a
                // toggle round-trip keeps the user's choices (unlike the spawn
                // allow-list, which gates tool visibility).
                imageGenerationTarget: imageGenerationTarget,
                imageEditModelId: imageEditModelId,
                textToVideoTarget: textToVideoTarget,
                imageToVideoTarget: imageToVideoTarget,
                subagentPermissions: reconciledSubagentPermissions,
                subagentBudgets: subagentBudgets,
                subagentModelOverrides: subagentModelOverrides,
                // Knowledge grants persist unconditionally (like the image
                // model picks): a toggle round-trip keeps the user's
                // selection, and the tools stay hidden while the feature is
                // off regardless.
                knowledgeEnabled: knowledgeEnabled,
                knowledgeCollectionIds: knowledgeCollectionIds,
                knowledgeCuratorEnabled: knowledgeCuratorEnabled,
                spawnableWorkspaceAgents: spawnableWorkspaceAgents,
                // Apple app families are written by the Tools picker through
                // `AgentManager.updateEnabledAppleApps` (instant save, like
                // `manualToolNames`), so pass the persisted value through.
                // The Default agent never carries any.
                enabledAppleApps: agent.id == Agent.defaultId ? [] : current.settings.enabledAppleApps,
                calculatorEnabled: calculatorEnabled,
                redactionToolsEnabled: redactionToolsEnabled,
                taskChecklistEnabled: taskChecklistEnabled,
                clarifyEnabled: clarifyEnabled,
                artifactsEnabled: artifactsEnabled,
                workingFolderReadOnly: agent.id == Agent.defaultId ? false : workingFolderReadOnly
            ),
            order: current.order
        )

        Self.carryDirectlySavedFields(from: current, into: &updated, generationValues: generationValues)
        agentManager.update(updated)
        // Advance both editor and baseline to the exact state just persisted.
        // A later unrelated save can now distinguish new local permission edits
        // from any future live permission-prompt update.
        subagentPermissions = reconciledSubagentPermissions
        loadedSubagentPermissions = reconciledSubagentPermissions
        showSaveIndicator()
    }

    @MainActor
    private func showSaveIndicator() {
        withAnimation(theme.motion.quick) {
            saveIndicator = "Saved"
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(theme.motion.standard) {
                saveIndicator = nil
            }
        }
    }
}

// MARK: - Agent Data Wipe Dialog

/// Selection state for the "Delete All Data" confirmation. A reference type
/// so the alert accessory (checkboxes) and the destructive button's closure
/// observe the same instance after `ThemedAlertCenter` captures the request.
private final class AgentDataWipeSelection: ObservableObject {
    @Published var chats = true
    @Published var pinnedFacts = true
    @Published var episodes = true
}

/// Body of the "Delete Agent Data" alert: message, per-category checkboxes,
/// and its own Cancel / Delete Selected row (mirroring the standard alert
/// button styling). Owns the in-progress state — while the deletion runs the
/// checkboxes and both buttons disable and the destructive button swaps its
/// label for a spinner, then `onDelete` dismisses the dialog when finished.
private struct AgentDataWipeDialogContent: View {
    @Environment(\.theme) private var theme
    @ObservedObject var selection: AgentDataWipeSelection
    let message: String
    let chatCount: Int
    let factCount: Int
    let episodeCount: Int
    let onCancel: () -> Void
    let onDelete: () async -> Void

    @State private var isDeleting = false
    private var nothingSelected: Bool {
        !selection.chats && !selection.pinnedFacts && !selection.episodes
    }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            Text(message)
                .font(SettingsFont.body)
                .foregroundColor(theme.text.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: theme.space.s12) {
                row(L("Chat history"), count: chatCount, isOn: $selection.chats)

                Text(L("Memory"))
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.secondary)
                    .padding(.top, theme.space.s8)

                row(L("Pinned facts"), count: factCount, isOn: $selection.pinnedFacts)
                row(L("Episodes"), count: episodeCount, isOn: $selection.episodes)

                Text(
                    "Chat history also removes the raw transcripts memory keeps for this agent.",
                    bundle: .module
                )
                .font(SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
                .padding(.top, theme.space.s2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, theme.space.s12)
            .disabled(isDeleting)
            .opacity(isDeleting ? 0.6 : 1)

            ThemeHairlineDivider()
                .padding(.top, theme.space.s16)

            HStack(spacing: theme.space.s8) {
                Spacer()
                cancelButton
                deleteButton
            }
            .padding(.top, theme.space.s16)
        }
    }

    private func row(_ title: String, count: Int, isOn: Binding<Bool>) -> some View {
        HStack(spacing: theme.space.s6) {
            Toggle(isOn: isOn) {
                Text(title)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.primary)
            }
            .settingsCheckbox()

            Spacer()

            Text(verbatim: "\(count)")
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var cancelButton: some View {
        SettingsButton(.secondary, "Cancel", action: onCancel)
            .keyboardShortcut(.cancelAction)
            .disabled(isDeleting)
    }

    private var deleteButton: some View {
        SettingsButton(.destructive, "Delete Selected", isLoading: isDeleting) {
            guard !isDeleting else { return }
            isDeleting = true
            Task { await onDelete() }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(isDeleting || nothingSelected)
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

    /// Downloaded is enough: the model loads on first speak, not here.
    private var voiceAvailable: Bool {
        ttsService.isModelReady || ttsService.modelFilesOnDisk
    }

    var body: some View {
        SettingsSection(title: "Voice") {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                HStack {
                    VStack(alignment: .leading, spacing: theme.space.s2) {
                        Text("Auto Speak Responses", bundle: .module)
                            .font(SettingsFont.compactLabel)
                            .foregroundColor(theme.text.primary)
                        Text(
                            voiceAvailable
                                ? "Read every reply aloud automatically after streaming completes. For on-request only, use the Speak Tool feature instead."
                                : "Download the PocketTTS model in Voice settings to enable.",
                            bundle: .module
                        )
                        .textStyle(.footnote)
                        .foregroundColor(theme.text.tertiary)
                    }
                    Spacer()
                    Toggle("", isOn: $autoSpeak)
                        .settingsSwitch()
                        .disabled(!voiceAvailable)
                        .onChange(of: autoSpeak) { onSave() }
                }
                .padding(theme.space.s8)
                .settingsChrome(.control)

                if !voiceAvailable {
                    Button {
                        NotificationCenter.default.post(
                            name: .openTTSSettingsRequested,
                            object: nil
                        )
                    } label: {
                        HStack(spacing: theme.space.s6) {
                            Image(systemName: "arrow.down.circle")
                                .glyphSize(.footnote, weight: .semibold)
                            Text("Open Voice Settings", bundle: .module)
                                .font(SettingsFont.smallLabel)
                        }
                        .foregroundColor(theme.text.link)
                    }
                    .buttonStyle(.plain)
                }

                if autoSpeak && voiceAvailable {
                    HStack {
                        Text("Voice", bundle: .module)
                            .font(SettingsFont.caption)
                            .foregroundColor(theme.text.secondary)
                        Spacer()
                        Picker("", selection: $ttsVoice) {
                            Text("Default (global)", bundle: .module).tag("")
                            ForEach(agentVoiceOptions, id: \.self) { voice in
                                Text(PocketTTSVoiceCatalog.displayName(for: voice))
                                    .tag(voice)
                            }
                        }
                        .assignedPickerPopupPresentation()
                        .labelsHidden()
                        .pickerStyle(MenuPickerStyle())
                        .frame(maxWidth: 200)
                        .onChange(of: ttsVoice) { onSave() }
                    }
                    .padding(theme.space.s8)
                    .settingsChrome(.control)
                }
            }
        }
        .onAppear { ttsService.probeModelFiles() }
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
                .padding(.horizontal, theme.space.s8)
                .padding(.vertical, theme.space.s6)
                .settingsChrome(.hover)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(theme.motion.quick) {
                isHovered = hovering
            }
        }
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        AgentsView()
    }
#endif

/// Closure-backed `NSMenuItem` target for header popup menus.
private final class HeaderMenuTarget: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire(_ sender: Any?) { handler() }
}
