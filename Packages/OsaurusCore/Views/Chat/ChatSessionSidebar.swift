//
//  ChatSessionSidebar.swift
//  osaurus
//
//  The chat window's left rail: Agents | Projects lenses.
//

import AppKit
import SwiftUI

/// In-memory toggle for the delete-conversation confirmation. Resets on
/// every app launch, matching the "for the rest of the session" semantic.
@MainActor
final class DeleteConfirmationPreference: ObservableObject {
    static let shared = DeleteConfirmationPreference()
    @Published var skipForSession: Bool = false
    private init() {}
}

struct ChatSessionSidebar: View {
    /// Sessions to display (already filtered by agent if needed)
    let sessions: [ChatSessionData]
    /// The window's currently-active agent: the highlighted Agents row.
    /// Switching it (row tap, tab switch, `loadSession`) marks the agent
    /// seen and, unless the user is browsing a project, returns the rail
    /// to the Agents lens.
    let agentId: UUID
    /// True while the active chat was entered from its project's detail
    /// page (or started there via ⌘N). The Projects lens stays put when the
    /// agent changes for that reason: the user is browsing a project, not
    /// picking an agent, so flipping to the Agents lens would lose their
    /// place. Explicit agent picks clear the flag before switching.
    var keepsProjectsLens: Bool = false
    /// Live width of the rail, driven by the parent's resize handle so the
    /// inner content (titles, chips, rows) reflows to fill the chosen width.
    var width: CGFloat = SidebarStyle.width
    /// Open a chat in the window's current tab (e.g. a workspace agent's
    /// row resuming its last conversation).
    let onSelect: (ChatSessionData) -> Void
    /// Delete a project: detaches member sessions, then removes the record.
    let onDeleteProject: (UUID) -> Void
    /// Open a project in the window's content area.
    var onOpenProject: ((Project) -> Void)? = nil
    /// The project on screen, if any: its row is the selected one on the
    /// Projects lens, the way the active agent's row is on Agents.
    var openProjectId: UUID? = nil
    /// Stop the live run driving the given session id. Rows only offer the
    /// control while `SessionActivityMonitor` reports the session active.
    var onStop: ((UUID) -> Void)? = nil
    /// Open a chat in a new tab of this window (browser-style).
    var onOpenInNewTab: ((ChatSessionData) -> Void)? = nil
    /// Select an agent for this window (agents-focused sidebar prototype —
    /// replaces the removed agent-selector pill; same effect as picking an
    /// agent from it).
    var onSelectAgent: ((UUID) -> Void)? = nil
    /// Start a fresh chat with a local agent straight from its row (hover
    /// "+" / context menu), without selecting the agent first.
    var onNewChatWithAgent: ((UUID) -> Void)? = nil
    /// Lowercased address of the workspace teammate's agent the window's
    /// active tab is chatting with, or nil for a local chat. While set, the
    /// matching team-agent row is the selected one (no local row is).
    var workspaceAgentAddress: String? = nil
    /// Workspace id stamped on the active team-agent tab, so that when the
    /// same agent is shared into two workspaces only the row under the tab's
    /// workspace highlights. Empty/nil = no workspace (direct share) or
    /// stamped before the roster loaded (then any matching row highlights).
    var workspaceAgentWorkspaceId: String?
    /// Select a workspace teammate's shared agent (by address) for this
    /// window — same effect as picking a local agent.
    var onSelectWorkspaceAgent: ((String, String) -> Void)? = nil
    /// LAN-discovered peers (Bonjour). Rendered under "On This Network" when
    /// a selection handler is wired — restoring the reach the removed toolbar
    /// agent pill's section provided.
    var discoveredAgents: [DiscoveredAgent] = []
    /// Id of the discovered agent the window's active tab is chatting with,
    /// or nil for a local/relay chat. While set, the matching network row is
    /// the selected one (no local row is).
    var activeDiscoveredAgentId: UUID? = nil
    /// Select a LAN-discovered agent: runs the pairing sheet on first pick,
    /// then connects — the same flow the removed agent pill drove.
    var onSelectDiscoveredAgent: ((DiscoveredAgent) -> Void)? = nil
    /// Export formats offered by chat rows; the type lives here because the
    /// sidebar has always been its home (`ChatSessionExportCoordinator`,
    /// `ExportChooserSheet` and `ChatHistoryList` share it).
    enum ExportFormat {
        case markdown
        case pdf
        case zip
    }

    @Environment(\.theme) private var theme
    @Environment(\.themedAlertScope) private var alertScope
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var projectManager = ProjectManager.shared
    /// Live "session id → working / waiting for input" map. Drives the
    /// animated avatar ring, the status metadata line, the per-row Stop
    /// control, and floating active rows to the top of the list.
    @ObservedObject private var activityMonitor = SessionActivityMonitor.shared
    /// Observed for the agent rows' live step text (registry `currentStep`
    /// changes ride the manager's `objectWillChange`).
    @ObservedObject private var taskManager = BackgroundTaskManager.shared
    /// Workspace rosters + presence for the team-agent sections. The store
    /// polls while any chat window is open (`ChatWindowState` holds the
    /// observer lease), so presence keeps flowing with the sidebar hidden.
    @ObservedObject private var rosterStore = WorkspaceRosterStore.shared
    /// Paired `RemoteAgent` records supply avatar / model for team rows.
    @ObservedObject private var remoteAgentManager = RemoteAgentManager.shared
    /// Auto-connect progress / failure per team agent.
    @ObservedObject private var connectService = WorkspaceAgentConnectService.shared
    /// Router on/off (the workspace sections explain themselves while off).
    @ObservedObject private var remoteProviderManager = RemoteProviderManager.shared
    /// Workspace list Settings knows (names for orphaned sections, and the
    /// "Router off but you have workspaces" explainer) + share/unshare.
    @ObservedObject private var workspacesService = WorkspacesService.shared
    /// Relay tunnel state for the user's own shared agents' rows.
    @ObservedObject private var relayManager = RelayTunnelManager.shared
    /// Agents that appeared during this app run and haven't been opened
    /// yet; their rows carry an accent ring and a "New" pill until tapped.
    @ObservedObject private var newAgentHighlight = NewAgentHighlightStore.shared
    /// Top-level sidebar lens: who (agents) or where (projects). Past
    /// chats live in the inspector on the right, scoped to the tab on
    /// screen.
    @State private var selectedTab: SidebarTab = .agents
    /// The lens's search query (row 3 of the rail, like History's search).
    /// Narrows the current lens by name; cleared when the lens changes.
    @State private var navigatorQuery: String = ""
    @FocusState private var isNavigatorSearchFocused: Bool

    enum SidebarTab: Hashable {
        case agents
        case projects
    }

    var body: some View {
        SidebarContainer(attachedEdge: .leading, topPadding: 40, width: width) {
            // Agents | Projects lens switcher, above the section header so
            // the lens is the first thing the eye lands on. As the first
            // child it owns the window-control clearance the header used to
            // provide (the container's 40pt only clears the traffic lights).
            sidebarTabBar
                // Tour spotlight anchor (invisible; reports the lens bar's frame).
                .background(TourAnchorMarker(anchor: .sidebarLensBar))
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 12)

            // Header row (count + the lens's one action) and the search
            // row: the same two rows the inspector's panes have.
            sidebarHeader
            navigatorSearchRow

            switch selectedTab {
            case .agents:
                // One row per agent; tapping selects it for this window.
                // The window's tabs and the inspector's History follow.
                agentListView
            case .projects:
                // Project browser: one row per project; opening one shows
                // the project detail page in the window's content area.
                projectListView
            }

            // Settings lives at the foot of the sidebar (moved out of the
            // title bar so it stays tabs + chat controls).
            sidebarFooter
        }
        // Switching lenses is a context change: the query belonged to
        // the previous list.
        .onChange(of: selectedTab) { _, _ in
            navigatorQuery = ""
        }
        .onChange(of: agentId) { _, newAgentId in
            // Browsing a project keeps the Projects lens; otherwise the
            // rail returns to the agent just picked.
            if !keepsProjectsLens { selectedTab = .agents }
            // Opening an agent by any route (row tap, tab switch, deep link)
            // is "seen": the new-agent ring comes off.
            if workspaceAgentAddress == nil {
                newAgentHighlight.markSeen(localAgentId: newAgentId)
            }
        }
        .onChange(of: workspaceAgentAddress) { _, address in
            if let address {
                newAgentHighlight.markSeen(sharedAgentAddress: address)
            }
        }
        .onAppear {
            if let workspaceAgentAddress {
                newAgentHighlight.markSeen(sharedAgentAddress: workspaceAgentAddress)
            } else {
                newAgentHighlight.markSeen(localAgentId: agentId)
            }
        }
        // Deep link from the "What's New" projects announcement: flip the
        // lens to Projects so the user lands on the new feature. The mutation
        // is deferred to the next runloop tick: assigning `selectedTab`
        // synchronously inside an onChange driven by an ObservableObject
        // publish is a reentrant state change SwiftUI can silently drop.
        .onChange(of: projectManager.pendingRevealProjectsTab) { _, reveal in
            guard reveal else { return }
            revealProjectsTab()
        }
        .onAppear {
            if projectManager.pendingRevealProjectsTab {
                revealProjectsTab()
            }
        }
    }

    /// Trimmed query; empty means the lens shows everything.
    private var trimmedNavigatorQuery: String {
        navigatorQuery.trimmingCharacters(in: .whitespaces)
    }

    private var isFilteringNavigator: Bool { !trimmedNavigatorQuery.isEmpty }

    /// Pure name filter shared by every navigator list (testable): keeps
    /// the items whose name matches `query` the way the chat search does.
    nonisolated static func filterByName<T>(_ items: [T], query: String, name: (T) -> String) -> [T] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        return items.filter { SearchService.matches(query: trimmed, in: name($0)) }
    }

    private func revealProjectsTab() {
        DispatchQueue.main.async {
            selectedTab = .projects
            projectManager.pendingRevealProjectsTab = false
        }
    }

    // MARK: - Tab Bar

    /// Lens switcher shared with the right rail (`SidebarLensBar`):
    /// equal-width segments, accent-tinted when selected.
    private var sidebarTabBar: some View {
        SidebarLensBar(
            selection: $selectedTab,
            segments: [
                .init(value: .agents, label: "Agents", icon: "person.2"),
                .init(value: .projects, label: "Projects", icon: "folder"),
            ]
        )
    }

    // MARK: - Project List

    /// The Projects tab's top level: one row per project. Tapping a row
    /// drills into that project's chats.
    private var projectListView: some View {
        let projects = Self.filterByName(projectManager.projects, query: navigatorQuery, name: \.name)
        return Group {
            if projectManager.projects.isEmpty {
                projectsEmptyState
            } else if projects.isEmpty {
                SidebarEmptyState(icon: "magnifyingglass", title: "No projects match")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(projects) { project in
                            ProjectRow(
                                project: project,
                                sessionCount: sessions.filter { $0.projectId == project.id }.count,
                                isSelected: project.id == openProjectId,
                                onOpen: {
                                    onOpenProject?(project)
                                },
                                onRename: { requestRenameProject(project) },
                                onEditInstructions: { requestEditProjectInstructions(project) },
                                onDelete: { requestDeleteProject(project) }
                            )
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    /// Empty state for the Projects tab, in the rails' shared idiom; the
    /// explainer of what a project is lives in the New Project dialog.
    private var projectsEmptyState: some View {
        SidebarEmptyState(icon: "folder", title: "No projects yet")
    }

    // MARK: - Project CRUD

    private func requestNewProject() {
        presentProjectNamePrompt(
            title: "New Project",
            initialName: "",
            submitLabel: "Create",
            showsIntro: true
        ) { name in
            let project = ProjectManager.shared.create(name: name)
            // Land the user straight on the fresh project's page.
            onOpenProject?(project)
        }
    }

    private func requestRenameProject(_ project: Project) {
        presentProjectNamePrompt(
            title: "Rename Project",
            initialName: project.name,
            submitLabel: "Save"
        ) { name in
            var updated = project
            updated.name = name
            ProjectManager.shared.update(updated)
        }
    }

    private func presentProjectNamePrompt(
        title: String,
        initialName: String,
        submitLabel: LocalizedStringKey,
        showsIntro: Bool = false,
        onSubmit: @escaping (String) -> Void
    ) {
        let requestId = UUID()
        let scope = alertScope
        let sheet = ProjectNamePromptSheet(
            initialName: initialName,
            submitLabel: submitLabel,
            showsIntro: showsIntro
        ) { name in
            ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
            onSubmit(name)
        }
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: title,
                message: nil,
                buttons: [.cancel(L("Cancel"))],
                showsCloseButton: true,
                customContent: AnyView(sheet),
                width: showsIntro ? 400 : 360,
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }

    /// Edits the project's shared instructions (prepended to the system
    /// prompt of every chat in the project).
    private func requestEditProjectInstructions(_ project: Project) {
        let requestId = UUID()
        let scope = alertScope
        let sheet = ProjectInstructionsSheet(
            initialInstructions: project.instructions
        ) { instructions in
            ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
            var updated = project
            updated.instructions = instructions
            ProjectManager.shared.update(updated)
        }
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: "Project Instructions",
                message: nil,
                buttons: [.cancel(L("Cancel"))],
                showsCloseButton: true,
                customContent: AnyView(sheet),
                width: 440,
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }

    /// Confirms, then detaches member chats and deletes the project.
    /// Conversations themselves are never deleted by this flow.
    private func requestDeleteProject(_ project: Project) {
        let requestId = UUID()
        let scope = alertScope
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: "Delete Project?",
                message: L(
                    "\"\(project.name)\" will be removed. Its conversations are kept and move out of the project."
                ),
                buttons: [
                    .cancel(L("Cancel")),
                    .destructive(L("Delete")) {
                        onDeleteProject(project.id)
                    },
                ],
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }

    // MARK: - Footer

    /// Settings at the foot of the rail, in the row anatomy: the glyph sits
    /// in the 26pt avatar column so the label lines up with the row titles
    /// above, and a hairline separates it from the list.
    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4).padding(.horizontal, 12)
            SidebarFooterRow(icon: "gearshape", title: "Settings") {
                AppDelegate.shared?.showManagementWindow(initialTab: nil)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Header and search rows

    /// Row 2 of the rail, the same `SidebarHeaderRow` the inspector's panes
    /// use: what the lens holds on the left ("8 agents", "3 projects"),
    /// the lens's one create action on the right. Both lenses use the
    /// same `plus`; what it creates is the lens.
    private var sidebarHeader: some View {
        SidebarHeaderRow(summary: navigatorSummary) {
            switch selectedTab {
            case .agents:
                // Agent creation is a full form, so it opens in Settings ›
                // Agents. New Chat and Import live in the inspector's
                // History pane.
                SidebarHeaderIconButton(icon: "plus", help: "New Agent", size: 14) {
                    AppDelegate.shared?.showManagementWindow(
                        initialTab: .agents, deeplinkCreateAgent: true)
                }
            case .projects:
                SidebarHeaderIconButton(icon: "plus", help: "New Project", size: 14) {
                    requestNewProject()
                }
            }
        }
    }

    private var navigatorSummary: String {
        switch selectedTab {
        case .agents:
            let count = agentRowCount
            return L("\(count) agents")
        case .projects:
            let count = projectManager.projects.count
            return L("\(count) projects")
        }
    }

    /// Everyone the Agents lens lists: local agents, teammates' shared
    /// agents on loaded rosters (the user's own mirrors are already counted
    /// as local), orphaned workspace pairings, direct shares and network
    /// peers.
    private var agentRowCount: Int {
        let local = agentManager.agents.count
        let teammates = rosterStore.rosters.reduce(0) { total, roster in
            total + roster.agents.filter { localAgent(sharedAs: $0.agentAddress.lowercased()) == nil }.count
        }
        let orphaned = orphanedWorkspacePairings.values.reduce(0) { $0 + $1.count }
        return local + teammates + orphaned + directlySharedAgents.count + visibleDiscoveredAgents.count
    }

    /// Row 3: search, same field and insets as the History pane's.
    private var navigatorSearchRow: some View {
        SidebarSearchField(
            text: $navigatorQuery,
            placeholder: selectedTab == .agents ? "Search agents…" : "Search projects…",
            isFocused: $isNavigatorSearchFocused
        )
        .frame(minHeight: 28)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Agent List (prototype)

    /// Agents-focused sidebar: one row per local agent, active row
    /// highlighted, tap to make it this window's agent.
    private var agentListView: some View {
        Group {
            if isFilteringNavigator, !hasAgentMatches {
                SidebarEmptyState(icon: "magnifyingglass", title: "No agents match")
            } else {
                agentList
            }
        }
    }

    /// Whether any row in any section survives the current query.
    private var hasAgentMatches: Bool {
        if !filteredLocalAgents.isEmpty || !directlySharedAgents.isEmpty || !visibleDiscoveredAgents.isEmpty {
            return true
        }
        if rosterStore.rosters.contains(where: { !filteredRosterMembers($0).isEmpty }) { return true }
        return orphanedWorkspacePairings.values.contains { !$0.isEmpty }
    }

    /// Local agents after the query (drag order is only live unfiltered).
    private var filteredLocalAgents: [Agent] {
        Self.filterByName(displayedAgents, query: navigatorQuery, name: \.displayName)
    }

    /// A roster's members after the query, by the name their row shows.
    private func filteredRosterMembers(
        _ roster: WorkspaceRosterStore.WorkspaceRoster
    ) -> [OsaurusRouterWorkspaceAgent] {
        Self.filterByName(roster.agents, query: navigatorQuery) { member in
            SharedAgentIdentity.resolve(
                address: member.agentAddress.lowercased(), workspaceId: roster.workspace.id
            ).name
        }
    }

    private var agentList: some View {
        ScrollView {
            // Plain VStack: every row needs a live frame for drag-to-reorder
            // hit testing, and the agent list is small.
            VStack(spacing: 2) {
                // Background runs (scheduled / API / channel / delegated)
                // are tabs of their agent, not rows here; each agent row
                // rolls its live work up into a ring + status line.
                ForEach(filteredLocalAgents) { agent in
                    let activity = activityStatus(for: agent)
                    AgentSidebarRow(
                        agent: agent,
                        // A team-agent or network-agent tab owns the
                        // selection: no local row is highlighted while one
                        // is active.
                        isSelected: agent.id == agentId && workspaceAgentAddress == nil
                            && activeDiscoveredAgentId == nil,
                        activityStatus: activity,
                        activityStep: activity == nil ? nil : activityStep(for: agent),
                        sharedWorkspaceNames: sharedWorkspaceNames(for: agent),
                        shareableWorkspaces: shareableWorkspaces(for: agent),
                        sharedWorkspaces: sharedWorkspaces(for: agent),
                        onShareToWorkspace: { workspace in
                            RemoteAgentWorkspaceAttribution.shareAgent(agent.id, toWorkspace: workspace.id)
                        },
                        onUnshareFromWorkspace: { workspace in
                            guard let address = agent.agentAddress else { return }
                            unshare(SharedAgentIdentity.resolve(address: address, workspaceId: workspace.id), from: workspace)
                        },
                        isNew: newAgentHighlight.isNew(localAgentId: agent.id),
                        onSelect: {
                            newAgentHighlight.markSeen(localAgentId: agent.id)
                            onSelectAgent?(agent.id)
                        },
                        onNewChat: onNewChatWithAgent.map { start in
                            {
                                newAgentHighlight.markSeen(localAgentId: agent.id)
                                start(agent.id)
                            }
                        },
                        onStop: activity == nil ? nil : { stopActivity(for: agent) },
                        // A filtered list is not the real order: no reordering
                        // until the query clears.
                        isReorderable: !agent.isBuiltIn && !isFilteringNavigator,
                        isDragging: draggingAgentId == agent.id,
                        dragOffset: draggingAgentId == agent.id ? agentDragOffset : 0,
                        onDragChanged: { handleAgentDrag(agent.id, translation: $0) },
                        onDragEnded: { endAgentDrag() }
                    )
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: AgentRowFramesKey.self,
                                value: [agent.id: proxy.frame(in: .named("agentList"))])
                        }
                    )
                }

                // Workspaces: one section per team the user belongs to,
                // listing every shared agent — teammates' (chat over the
                // relay) and the user's own (badged "local", routed to the
                // local agent so the team roster reads complete). Before the
                // first roster lands / when the router can't be reached /
                // when Router is off, a single explanatory section stands in.
                workspaceSections

                // Agents shared with the user directly (an invite link, not a
                // workspace). They live in the same paired-agent store as
                // team agents but sit on no roster, so they get their own
                // section — otherwise the only way to reach them from a chat
                // window is Settings ▸ Agents.
                if !directlySharedAgents.isEmpty {
                    sharedAgentsSection(directlySharedAgents)
                }

                // Peers discovered over Bonjour that aren't already paired
                // (paired ones render under their workspace / "Shared with
                // you" row instead). Selecting one hands off to ChatView's
                // pairing/connect flow.
                if !visibleDiscoveredAgents.isEmpty {
                    discoveredAgentsSection(visibleDiscoveredAgents)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .coordinateSpace(name: "agentList")
            .onPreferenceChange(AgentRowFramesKey.self) { agentRowFrames = $0 }
            .animation(theme.animationQuick(), value: displayedAgents.map(\.id))
            .animation(theme.animationQuick(), value: rosterStore.rosters.map(\.id))
            .animation(theme.animationQuick(), value: directlySharedAgents.map(\.id))
            .animation(theme.animationQuick(), value: visibleDiscoveredAgents.map(\.id))
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Directly shared agents

    /// Paired remote agents shared through an invite link: no workspace
    /// attribution on the pairing (`workspaceId` nil), and not one of the
    /// user's own agents. Partitioned by the PERSISTED attribution, not by
    /// live roster membership, so a workspace agent never flashes under
    /// "Shared with you" before the roster loads or while Router is off.
    private var directlySharedAgents: [RemoteAgent] {
        let shared = remoteAgentManager.remoteAgents
            .filter { remote in
                let address = remote.agentAddress.lowercased()
                return Self.isDirectlyShared(
                    remote,
                    onRoster: rosterStore.agent(forAddress: address) != nil,
                    isOwn: localAgent(sharedAs: address) != nil
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return Self.filterByName(shared, query: navigatorQuery, name: \.name)
    }

    /// Pure partition rule (testable): a pairing is "shared with you"
    /// directly when it isn't attributed to a workspace, isn't currently on
    /// any roster (a roster-listed agent renders under its workspace even if
    /// its attribution is still being backfilled), and isn't the user's own.
    nonisolated static func isDirectlyShared(_ remote: RemoteAgent, onRoster: Bool, isOwn: Bool) -> Bool {
        !remote.isWorkspaceManaged && !onRoster && !isOwn
    }

    @ViewBuilder
    private func sharedAgentsSection(_ agents: [RemoteAgent]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sidebarSectionHeader(
                icon: "person.2.fill",
                title: L("Shared with you"),
                help: L("Agents shared with you directly, outside any workspace")
            )

            ForEach(agents) { remote in
                let address = remote.agentAddress.lowercased()
                RemoteAgentSidebarRow(
                    agent: remote,
                    isSelected: isWorkspaceRowSelected(address: address, workspaceId: ""),
                    activityStatus: activityStatus(forRemoteAgentAddress: address, workspaceId: ""),
                    isNew: newAgentHighlight.isNew(sharedAgentAddress: address),
                    // Same tab / history / connect flow as a team agent; the
                    // session context simply carries no workspace id.
                    onSelect: {
                        newAgentHighlight.markSeen(sharedAgentAddress: address)
                        onSelectWorkspaceAgent?(address, "")
                    },
                    onRemove: { removeDirectShare(remote) }
                )
            }
        }
    }

    // MARK: On This Network

    /// LAN-discovered peers that still need a sidebar row: the browser
    /// already excludes this device's own agents, so only peers with an
    /// existing pairing row (workspace roster or "Shared with you") drop
    /// out here.
    private var visibleDiscoveredAgents: [DiscoveredAgent] {
        guard onSelectDiscoveredAgent != nil else { return [] }
        let pairedAddresses = Set(
            remoteAgentManager.remoteAgents.map { $0.agentAddress.lowercased() }
        )
        let visible = discoveredAgents
            .filter { Self.isVisibleDiscovered($0, pairedAddresses: pairedAddresses) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return Self.filterByName(visible, query: navigatorQuery, name: \.name)
    }

    /// Pure partition rule (testable): a discovered peer renders under
    /// "On This Network" unless a pairing for its address already owns a
    /// row in another section. Addressless peers (pre-Secure-Channel) have
    /// nothing to match a pairing on, so they always render.
    nonisolated static func isVisibleDiscovered(
        _ agent: DiscoveredAgent, pairedAddresses: Set<String>
    ) -> Bool {
        guard let address = agent.address?.lowercased(), !address.isEmpty else { return true }
        return !pairedAddresses.contains(address)
    }

    @ViewBuilder
    private func discoveredAgentsSection(_ agents: [DiscoveredAgent]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sidebarSectionHeader(
                icon: "antenna.radiowaves.left.and.right",
                title: L("On This Network"),
                help: L("Osaurus agents discovered on your local network")
            )

            ForEach(agents) { agent in
                DiscoveredAgentSidebarRow(
                    agent: agent,
                    isSelected: activeDiscoveredAgentId == agent.id,
                    onSelect: { onSelectDiscoveredAgent?(agent) }
                )
            }
        }
    }

    private func removeDirectShare(_ remote: RemoteAgent) {
        ThemedAlertCenter.shared.confirmDestructive(
            scope: alertScope,
            title: L("Remove shared agent?"),
            message: String(
                format: L("%@ will disappear from this Mac. The owner can share it with you again with a new link."),
                remote.name
            ),
            destructiveTitle: L("Remove")
        ) {
            _ = RemoteAgentManager.shared.remove(id: remote.id)
        }
    }

    // MARK: Workspace sections

    /// Uppercase section header shared by every sidebar section.
    private func sidebarSectionHeader(icon: String, title: String, help: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .lineLimit(1)
        }
        .foregroundColor(theme.secondaryText.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help)
    }

    /// Workspace-managed pairings whose workspace isn't on a loaded roster
    /// yet (roster loading, router unreachable, Router off). Grouped under a
    /// section for their workspace so they stay reachable — never demoted to
    /// "Shared with you".
    private var orphanedWorkspacePairings: [String: [RemoteAgent]] {
        let grouped = Self.orphanedWorkspacePairings(
            remoteAgentManager.remoteAgents,
            loadedRosterIds: Set(rosterStore.rosters.map(\.id))
        )
        guard isFilteringNavigator else { return grouped }
        return grouped.compactMapValues { pairings in
            let kept = Self.filterByName(pairings, query: navigatorQuery, name: \.name)
            return kept.isEmpty ? nil : kept
        }
    }

    /// Pure partition rule (testable): workspace-attributed pairings grouped
    /// by workspace id, keeping only workspaces without a loaded roster.
    nonisolated static func orphanedWorkspacePairings(
        _ remotes: [RemoteAgent],
        loadedRosterIds: Set<String>
    ) -> [String: [RemoteAgent]] {
        var out: [String: [RemoteAgent]] = [:]
        for remote in remotes {
            guard let workspaceId = remote.workspaceId, !workspaceId.isEmpty,
                !loadedRosterIds.contains(workspaceId)
            else { continue }
            out[workspaceId, default: []].append(remote)
        }
        return out
    }

    @ViewBuilder
    private var workspaceSections: some View {
        let routerOn = remoteProviderManager.isOsaurusRouterEnabled
        ForEach(rosterStore.rosters) { roster in
            // While searching, a workspace with no matching member has no
            // reason to show its header.
            if !isFilteringNavigator || !filteredRosterMembers(roster).isEmpty {
                workspaceSection(roster)
            }
        }
        // Orphaned workspace pairings (no loaded roster): one section each,
        // named after the workspace when Settings knows it.
        ForEach(orphanedWorkspacePairings.keys.sorted(), id: \.self) { workspaceId in
            let pairings = orphanedWorkspacePairings[workspaceId] ?? []
            let name = workspacesService.workspaces.first { $0.id == workspaceId }?.name
            VStack(alignment: .leading, spacing: 2) {
                sidebarSectionHeader(
                    icon: "rectangle.3.group.fill",
                    title: name ?? L("Workspace"),
                    help: L("Workspace")
                )
                if !routerOn, !isFilteringNavigator {
                    workspaceStateRow(
                        icon: "bolt.slash.fill",
                        text: L("Osaurus Router is off — shared agents can't be reached."),
                        actionTitle: L("Turn on"),
                        action: { remoteProviderManager.setOsaurusRouterEnabled(true) }
                    )
                }
                ForEach(pairings) { remote in
                    let address = remote.agentAddress.lowercased()
                    RemoteAgentSidebarRow(
                        agent: remote,
                        isSelected: isWorkspaceRowSelected(address: address, workspaceId: workspaceId),
                        activityStatus: activityStatus(forRemoteAgentAddress: address, workspaceId: workspaceId),
                        isNew: newAgentHighlight.isNew(sharedAgentAddress: address),
                        onSelect: {
                            newAgentHighlight.markSeen(sharedAgentAddress: address)
                            onSelectWorkspaceAgent?(address, workspaceId)
                        },
                        onOpenWorkspace: { openWorkspaceInSettings(id: workspaceId) }
                    )
                }
            }
        }
        // Section-level states when there is no roster to show (explainers
        // are not search results, so they step aside while filtering).
        if isFilteringNavigator {
            EmptyView()
        } else if rosterStore.rosters.isEmpty {
            if !routerOn, !workspacesService.workspaces.isEmpty || !orphanedWorkspacePairings.isEmpty {
                // Router off but Settings knows workspaces: explain once
                // (orphan sections above already carry the row).
                if orphanedWorkspacePairings.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        sidebarSectionHeader(
                            icon: "rectangle.3.group.fill", title: L("Workspaces"), help: L("Workspaces")
                        )
                        workspaceStateRow(
                            icon: "bolt.slash.fill",
                            text: L("Osaurus Router is off — shared agents can't be reached."),
                            actionTitle: L("Turn on"),
                            action: { remoteProviderManager.setOsaurusRouterEnabled(true) }
                        )
                    }
                }
            } else if routerOn, rosterStore.isLoading {
                VStack(alignment: .leading, spacing: 2) {
                    sidebarSectionHeader(icon: "rectangle.3.group.fill", title: L("Workspaces"), help: L("Workspaces"))
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text("Loading workspaces…", bundle: .module)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if routerOn, let error = rosterStore.lastError {
                VStack(alignment: .leading, spacing: 2) {
                    sidebarSectionHeader(icon: "rectangle.3.group.fill", title: L("Workspaces"), help: L("Workspaces"))
                    workspaceStateRow(
                        icon: "exclamationmark.triangle.fill",
                        text: error,
                        tint: theme.warningColor,
                        actionTitle: L("Retry"),
                        action: { Task { await rosterStore.refresh(reason: .manual) } }
                    )
                }
            }
        } else if let error = rosterStore.lastError {
            // Rosters shown are stale: say so under them, with Retry.
            workspaceStateRow(
                icon: "exclamationmark.triangle.fill",
                text: error,
                tint: theme.warningColor,
                actionTitle: L("Retry"),
                action: { Task { await rosterStore.refresh(reason: .manual) } }
            )
            .padding(.top, 6)
        }
    }

    /// Compact explanatory row inside a workspace section (loading / error /
    /// Router off / empty) with one inline action.
    private func workspaceStateRow(
        icon: String,
        text: String,
        tint: Color? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(tint ?? theme.tertiaryText)
                .frame(width: 14)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundColor(tint == nil ? theme.tertiaryText : theme.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(action: action) {
                        Text(actionTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func workspaceSection(_ roster: WorkspaceRosterStore.WorkspaceRoster) -> some View {
        let members = filteredRosterMembers(roster)
        let workspace = roster.workspace
        VStack(alignment: .leading, spacing: 2) {
            sidebarSectionHeader(
                icon: "rectangle.3.group.fill",
                title: workspace.name,
                help: String(format: L("Workspace: %@"), workspace.name)
            )

            if members.isEmpty {
                let canShare = workspace.typedRole?.canShareAgents ?? false
                workspaceStateRow(
                    icon: "person.2.fill",
                    text: L("No shared agents yet"),
                    actionTitle: canShare ? L("Share an agent…") : nil,
                    action: canShare ? { openWorkspaceInSettings(id: workspace.id) } : nil
                )
            } else {
                ForEach(members) { agent in
                    let address = agent.agentAddress.lowercased()
                    let identity = SharedAgentIdentity.resolve(address: address, workspaceId: workspace.id)
                    if let mine = identity.localAgent {
                        // The user's own shared agent: same row shape, a
                        // "local" badge instead of relay presence, and
                        // selection routes to the local agent itself; this
                        // mirror highlights when the agent is active so both
                        // rows read as one selection.
                        WorkspaceAgentSidebarRow(
                            identity: identity,
                            workspaceId: workspace.id,
                            status: ownAgentStatus(mine),
                            isSelected: mine.id == agentId && workspaceAgentAddress == nil,
                            activityStatus: activityStatus(for: mine),
                            onSelect: { onSelectAgent?(mine.id) },
                            onOpenSettings: {
                                AppDelegate.shared?.showManagementWindow(
                                    initialTab: .agents, deeplinkAgentId: mine.id)
                            },
                            onOpenWorkspace: { openWorkspaceInSettings(id: workspace.id) },
                            onUnshare: { unshare(identity, from: workspace) },
                            onTurnOnRelay: { RelayTunnelManager.shared.setTunnelEnabled(true, for: mine.id) }
                        )
                    } else {
                        let selected = isWorkspaceRowSelected(address: address, workspaceId: workspace.id)
                        WorkspaceAgentSidebarRow(
                            identity: identity,
                            workspaceId: workspace.id,
                            status: teammateAgentStatus(address: address, workspaceId: workspace.id),
                            isSelected: selected,
                            activityStatus: activityStatus(forRemoteAgentAddress: address, workspaceId: workspace.id),
                            isNew: newAgentHighlight.isNew(sharedAgentAddress: address),
                            onSelect: {
                                newAgentHighlight.markSeen(sharedAgentAddress: address)
                                onSelectWorkspaceAgent?(address, workspace.id)
                            },
                            onOpenInNewWindow: {
                                ChatWindowManager.shared.openNewChatWindow(withWorkspaceAgentAddress: address,
                                    workspaceId: workspace.id
                                )
                            },
                            onOpenWorkspace: { openWorkspaceInSettings(id: workspace.id) },
                            // Unshare is an ownership right: an agent this
                            // identity shared from another device can be
                            // unshared from here too.
                            onUnshare: identity.isOwnedByMe ? { unshare(identity, from: workspace) } : nil
                        )
                    }
                }
            }
        }
    }

    /// Only the row whose workspace matches the active tab's stamped
    /// workspace highlights when an agent is shared into several.
    private func isWorkspaceRowSelected(address: String, workspaceId: String) -> Bool {
        guard workspaceAgentAddress == address else { return false }
        return (workspaceAgentWorkspaceId ?? "") == workspaceId
    }

    /// Status for a teammate's roster agent as the sidebar row shows it
    /// (shared with the Workspaces panel via `SharedAgentStatus`).
    private func teammateAgentStatus(address: String, workspaceId: String) -> SharedAgentStatus {
        // Read the observed stores so SwiftUI re-renders on pairing/presence
        // changes; the derivation itself lives on the status type.
        _ = remoteAgentManager.remoteAgents
        _ = rosterStore.rosters
        _ = connectService.connectingAddresses
        _ = remoteProviderManager.isOsaurusRouterEnabled
        return SharedAgentStatus.forTeammateRow(address: address, workspaceId: workspaceId)
    }

    /// The user's own shared agent is "ready" for teammates only while its
    /// relay tunnel is up; otherwise the row says so instead of a hard-coded
    /// online dot.
    private func ownAgentStatus(_ agent: Agent) -> SharedAgentStatus {
        SharedAgentStatus.forOwnAgent(relayStatus: relayManager.agentStatuses[agent.id])
    }

    /// Every workspace affordance in the sidebar is about its agents (open
    /// a teammate's agent row, share one of ours), so land on that
    /// workspace's Shared Agents tab, not the workspace list.
    private func openWorkspaceInSettings(id: String) {
        workspacesService.openInSettings(workspaceId: id, tab: .sharedAgents)
    }

    private func unshare(_ identity: SharedAgentIdentity, from workspace: OsaurusRouterWorkspaceSummary) {
        ThemedAlertCenter.shared.confirmDestructive(
            scope: alertScope,
            title: String(format: L("Unshare %@?"), identity.name),
            message: String(
                format: L("Teammates in %@ will lose access immediately; their conversations stay readable."),
                workspace.name
            ),
            destructiveTitle: L("Unshare")
        ) {
            Task {
                _ = await workspacesService.unshareAgent(
                    workspaceId: workspace.id, agentAddress: identity.address
                )
            }
        }
    }

    /// The local agent behind a roster entry when it is one of the user's
    /// own shared agents; nil for teammates' agents.
    private func localAgent(sharedAs address: String) -> Agent? {
        agentManager.agents.first { $0.agentAddress?.lowercased() == address }
    }

    /// Workspaces one of the user's own agents is shared into (for the
    /// "shared" glyph on its local row). Empty for unshared agents.
    private func sharedWorkspaceNames(for agent: Agent) -> [String] {
        sharedWorkspaces(for: agent).map(\.name)
    }

    private func sharedWorkspaces(for agent: Agent) -> [OsaurusRouterWorkspaceSummary] {
        guard let address = agent.agentAddress, rosterStore.hasWorkspaces else { return [] }
        return rosterStore.workspacesSharing(agentAddress: address)
    }

    /// Workspaces the agent could still be shared into (user's role allows
    /// it; not already shared there). Built-ins have no address to share.
    private func shareableWorkspaces(for agent: Agent) -> [OsaurusRouterWorkspaceSummary] {
        guard agent.agentAddress != nil, !agent.isBuiltIn else { return [] }
        let shared = Set(sharedWorkspaces(for: agent).map(\.id))
        return rosterStore.rosters.map(\.workspace).filter {
            !shared.contains($0.id) && ($0.typedRole?.canShareAgents ?? false) && $0.isActive
        }
    }

    /// Roll live activity up to a team agent: sessions this user has with
    /// that agent (by address) that are streaming / waiting.
    private func activityStatus(forRemoteAgentAddress address: String, workspaceId: String) -> SessionActivityMonitor.Status? {
        let statuses = activityMonitor.statuses
        guard !statuses.isEmpty else { return nil }
        var rolledUp: SessionActivityMonitor.Status?
        for session in ChatSessionsManager.shared.sessions(forRemoteAgentAddress: address) {
            guard session.workspace?.workspaceId == workspaceId,
                let status = statuses[session.id] else { continue }
            if status == .working { return .working }
            rolledUp = rolledUp ?? status
        }
        return rolledUp
    }

    // MARK: Agent drag-to-reorder

    /// Live order while a drag is in flight; nil otherwise (manager order).
    @State private var agentDragOrder: [Agent]?
    @State private var draggingAgentId: UUID?
    @State private var agentDragOffset: CGFloat = 0
    /// Cumulative pitch already absorbed by live swaps during this drag.
    @State private var agentSwappedDistance: CGFloat = 0
    @State private var agentRowFrames: [UUID: CGRect] = [:]

    private var displayedAgents: [Agent] { agentDragOrder ?? agentManager.agents }

    /// Built-ins (the orchestrator) stay pinned at the top: the movable
    /// range starts after the last built-in row.
    private var firstMovableIndex: Int {
        displayedAgents.lastIndex(where: { $0.isBuiltIn }).map { $0 + 1 } ?? 0
    }

    private func handleAgentDrag(_ id: UUID, translation: CGFloat) {
        if draggingAgentId != id {
            draggingAgentId = id
            agentDragOrder = agentManager.agents
            agentDragOffset = 0
            agentSwappedDistance = 0
        }
        guard var order = agentDragOrder,
            var index = order.firstIndex(where: { $0.id == id })
        else { return }
        let last = order.count - 1
        // Same scheme as the tab strip: `translation` is cumulative from
        // the press; subtract the distance already absorbed by swaps so the
        // row stays glued to the pointer. Each crossing of a neighbour's
        // midpoint swaps one slot and re-bases by that slot's pitch (the
        // neighbour's measured height plus the list spacing, since the
        // selected row is taller than the rest).
        var offset = translation - agentSwappedDistance
        while index < last, offset > pitch(of: order[index + 1]) / 2 {
            let p = pitch(of: order[index + 1])
            order.swapAt(index, index + 1)
            index += 1
            agentSwappedDistance += p
            offset -= p
        }
        while index > firstMovableIndex, offset < -pitch(of: order[index - 1]) / 2 {
            let p = pitch(of: order[index - 1])
            order.swapAt(index, index - 1)
            index -= 1
            agentSwappedDistance -= p
            offset += p
        }
        // The end rows can't be pulled past the movable range.
        if index == firstMovableIndex { offset = max(offset, 0) }
        if index == last { offset = min(offset, 0) }
        agentDragOrder = order
        agentDragOffset = offset
    }

    /// Distance the dragged row travels to take over `agent`'s slot.
    private func pitch(of agent: Agent) -> CGFloat {
        (agentRowFrames[agent.id]?.height ?? 40) + 2
    }

    private func endAgentDrag() {
        if let order = agentDragOrder {
            agentManager.reorder(orderedIds: order.filter { !$0.isBuiltIn }.map(\.id))
        }
        withAnimation(theme.springAnimation(responseMultiplier: 0.8)) {
            agentDragOffset = 0
        }
        draggingAgentId = nil
        agentDragOrder = nil
    }

    /// Roll the per-session activity up to the agent: `.working` wins over
    /// `.waitingForInput`; nil when none of the agent's sessions are live.
    private func activityStatus(for agent: Agent) -> SessionActivityMonitor.Status? {
        // Helper runs (spawned subagents whose launching chat is no longer
        // on screen): mirrors without a chat of their own. Inbound
        // shared-agent runs are ordinary session-backed tasks and roll up
        // through the per-session map below like any other run.
        if mirrorTask(for: agent) != nil { return .working }
        var rolledUp: SessionActivityMonitor.Status? = nil
        let statuses = activityMonitor.statuses
        guard !statuses.isEmpty else { return rolledUp }
        for session in ChatSessionsManager.shared.sessions {
            // Chats with a teammate's shared agent roll up to that agent's
            // row, not to the local agent whose tab hosted them.
            guard !session.isWorkspaceAgentChat,
                (session.agentId ?? Agent.defaultId) == agent.id,
                let status = statuses[session.id]
            else { continue }
            if status == .working { return .working }
            rolledUp = rolledUp ?? status
        }
        return rolledUp
    }

    /// Session ids of this agent's live (non-workspace-chat) sessions, in
    /// sidebar recency order.
    private func liveSessionIds(for agent: Agent) -> [UUID] {
        let statuses = activityMonitor.statuses
        guard !statuses.isEmpty else { return [] }
        return ChatSessionsManager.shared.sessions.compactMap { session in
            guard !session.isWorkspaceAgentChat,
                (session.agentId ?? Agent.defaultId) == agent.id,
                statuses[session.id] != nil
            else { return nil }
            return session.id
        }
    }

    /// An active spawned-helper mirror on this agent (a `spawn_agent`-style
    /// run whose launching chat isn't in any window). Mirrors have no chat
    /// and therefore no tab; the agent row is their only surface.
    private func mirrorTask(for agent: Agent) -> BackgroundTaskState? {
        taskManager.backgroundTasks.values.first {
            $0.isSubagentMirror && $0.agentId == agent.id && $0.status.isActive
        }
    }

    /// One-line current step for the agent row's live status line. Detached
    /// registry runs (including runs hosted for a remote caller, prefixed
    /// with the caller's name) expose their step; a windowed run in another
    /// window reports no step and falls back to "Working…".
    private func activityStep(for agent: Agent) -> String? {
        if let mirror = mirrorTask(for: agent) {
            if let step = mirror.currentStep, !step.isEmpty {
                return "\(mirror.taskTitle) · \(step)"
            }
            return mirror.taskTitle
        }
        for sessionId in liveSessionIds(for: agent) {
            guard let task = BackgroundTaskManager.shared.liveTask(forSessionId: sessionId) else { continue }
            let step = task.currentStep?.isEmpty == false ? task.currentStep : nil
            if task.isInboundRun {
                let caller = task.externalSessionKey ?? L("a teammate")
                return step.map { "\(caller) · \($0)" } ?? caller
            }
            if let step { return step }
        }
        return nil
    }

    /// Stop everything live on this agent: its windowed/detached sessions
    /// (via the monitor, which prefers the registry task — for a run hosted
    /// for a remote caller that ends the SSE run) and any helper mirror.
    private func stopActivity(for agent: Agent) {
        for sessionId in liveSessionIds(for: agent) {
            onStop?(sessionId)
        }
        if let mirror = mirrorTask(for: agent) {
            taskManager.cancelTask(mirror.id)
        }
    }
}

// MARK: - Agent Row (prototype)

/// Row in the agents-focused sidebar. Mirrors `SessionRow`'s hover and
/// selection treatment: avatar, name, hover-only gear to the agent's settings.
private struct AgentSidebarRow: View {
    let agent: Agent
    let isSelected: Bool
    /// Live activity rolled up from the agent's sessions: `.working`
    /// animates the avatar ring exactly like the old session rows.
    var activityStatus: SessionActivityMonitor.Status? = nil
    /// One-line current step for the live status subtitle ("Reading
    /// files…"); nil falls back to a generic "Working…".
    var activityStep: String? = nil
    /// Workspaces this agent is shared into. Non-empty draws a small
    /// "shared" glyph after the name (tooltip names the workspaces) so the
    /// user's own shared agents are recognisable without a duplicate row
    /// in the workspace section.
    var sharedWorkspaceNames: [String] = []
    /// Workspaces the user can share this agent into (role allows sharing,
    /// not yet shared there). Drives the "Share to Workspace" submenu.
    var shareableWorkspaces: [OsaurusRouterWorkspaceSummary] = []
    /// Workspaces this agent is currently shared into, for "Unshare from…".
    var sharedWorkspaces: [OsaurusRouterWorkspaceSummary] = []
    var onShareToWorkspace: ((OsaurusRouterWorkspaceSummary) -> Void)?
    var onUnshareFromWorkspace: ((OsaurusRouterWorkspaceSummary) -> Void)?
    /// Appeared during this app run and not opened yet: accent ring + pill.
    var isNew: Bool = false
    let onSelect: () -> Void
    /// Start a fresh chat with this agent. Shown as a hover "+" so the user
    /// can open a new chat without first selecting the agent and then
    /// reaching for the "+" in the tab strip.
    var onNewChat: (() -> Void)? = nil
    /// Stop every live run on this agent. Shown on hover while
    /// `activityStatus` is non-nil.
    var onStop: (() -> Void)? = nil
    /// Drag-to-reorder (custom agents only; built-ins are pinned to the
    /// top). The list owns the state; the row just reports translation.
    var isReorderable: Bool = false
    var isDragging: Bool = false
    var dragOffset: CGFloat = 0
    var onDragChanged: ((CGFloat) -> Void)? = nil
    var onDragEnded: (() -> Void)? = nil

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            AgentAvatarView(
                mascotId: agent.avatar,
                name: agent.displayName,
                tint: agentColorFor(agent.name),
                diameter: 26,
                customImageURL: agent.customAvatarURL,
                monogramFontSize: 12,
                borderWidth: 0
            )
            .overlay(
                Group {
                    if let activityStatus {
                        SessionActivityRing(status: activityStatus)
                    }
                }
                .allowsHitTesting(false)
            )
            .animation(theme.springAnimation(responseMultiplier: 0.8), value: activityStatus)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(agent.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    if !sharedWorkspaceNames.isEmpty {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(theme.accentColor.opacity(0.85))
                            .help(
                                String(
                                    format: L("Shared with %@"),
                                    sharedWorkspaceNames.joined(separator: ", ")
                                )
                            )
                            .accessibilityLabel(Text("Shared with workspace", bundle: .module))
                    }
                    if isNew {
                        NewAgentPill()
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Subtitle = live status, else the role caption. The chat
                // itself is named by the tab strip and the History pane,
                // so the row stays about the agent.
                if let activityStatus {
                    Text(liveStatusLine(activityStatus))
                        .font(.system(size: 10, weight: activityStatus == .waitingForInput ? .semibold : .regular))
                        .foregroundColor(
                            activityStatus == .waitingForInput ? theme.warningColor : theme.accentColor.opacity(0.9)
                        )
                        .lineLimit(1)
                        .contentTransition(.opacity)
                } else if agent.isBuiltIn {
                    Text("Orchestrator", bundle: .module)
                        .font(.system(size: 10))
                        .foregroundColor(theme.secondaryText.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Hover-only Stop while a run is live on this agent; takes the
            // gear's slot so the row doesn't widen.
            if isHovered, activityStatus != nil, let onStop {
                SessionStopButton(action: onStop)
                    .transition(.opacity)
            }
            // Hover-only gear opening this agent's settings in the
            // management window: the Agents detail page for a user agent,
            // Settings → Orchestrator for the built-in Osaurus agent (it has
            // no Agents row, but its identity and delegation helpers live
            // there). The selected row is already signalled by its
            // background, so no checkmark.
            else if isHovered {
                HStack(spacing: 2) {
                    if let onNewChat {
                        Button(action: onNewChat) {
                            Image(systemName: "plus.bubble")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(theme.secondaryText)
                                .frame(width: SidebarStyle.actionButtonSize, height: SidebarStyle.actionButtonSize)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .localizedHelp("New Chat")
                    }
                    Button(action: openAgentSettings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: SidebarStyle.actionButtonSize, height: SidebarStyle.actionButtonSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .localizedHelp(agent.isBuiltIn ? LocalizedStringKey("Orchestrator Settings") : LocalizedStringKey("Agent Settings"))
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(SidebarRowBackground(isSelected: isSelected, isHovered: isHovered))
        .clipShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
        .newAgentHighlight(isNew)
        .contentShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
        .offset(y: dragOffset)
        .zIndex(isDragging ? 1 : 0)
        .shadow(color: .black.opacity(isDragging ? 0.18 : 0), radius: 8, y: 2)
        .onTapGesture(perform: onSelect)
        .contextMenu { agentContextMenu }
        // Same threshold as the tab strip: a short travel keeps clicks as
        // taps; beyond it the press becomes a reorder drag.
        //
        // A non-reorderable row (the built-in Orchestrator) must keep every
        // gesture applied ABOVE this modifier alive: the tap that selects the
        // agent, the hover gear, and the context menu. `.subviews` disables
        // only the drag added here; `.none` would disable the whole subview
        // hierarchy's gestures too, which made the Orchestrator row
        // unselectable (#2729).
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { onDragChanged?($0.translation.height) }
                .onEnded { _ in onDragEnded?() },
            including: isReorderable ? .all : .subviews
        )
        .onHover { hovering in
            withAnimation(theme.springAnimation(responseMultiplier: 0.8)) {
                isHovered = hovering
            }
        }
        .animation(theme.springAnimation(responseMultiplier: 0.8), value: isSelected)
    }

    /// Where this agent is configured: a user agent's detail page under
    /// Settings → Agents, or Settings → Orchestrator for the built-in
    /// Osaurus agent (which has no Agents row). Shared by the hover gear and
    /// the context menu so both land in the same place.
    private func openAgentSettings() {
        if agent.isBuiltIn {
            AppDelegate.shared?.showManagementWindow(initialTab: .orchestrator)
        } else {
            AppDelegate.shared?.showManagementWindow(initialTab: .agents, deeplinkAgentId: agent.id)
        }
    }

    /// Parity with session / project rows: settings, address, and the
    /// share/unshare actions that otherwise live only in Settings.
    @ViewBuilder
    private var agentContextMenu: some View {
        if let onNewChat {
            Button(action: onNewChat) {
                Label(LCached("New Chat"), systemImage: "plus.bubble")
            }
        }
        Button(action: openAgentSettings) {
            Label(LCached("Open Settings"), systemImage: "gearshape")
        }
        if !shareableWorkspaces.isEmpty, let onShareToWorkspace {
            Menu {
                ForEach(shareableWorkspaces) { workspace in
                    Button(workspace.name) { onShareToWorkspace(workspace) }
                }
            } label: {
                Label(LCached("Share to Workspace…"), systemImage: "person.2.fill")
            }
        }
        if !sharedWorkspaces.isEmpty, let onUnshareFromWorkspace {
            Divider()
            ForEach(sharedWorkspaces) { workspace in
                Button(role: .destructive) {
                    onUnshareFromWorkspace(workspace)
                } label: {
                    Label(String(format: LCached("Unshare from %@"), workspace.name), systemImage: "person.2.slash")
                }
            }
        }
    }

    /// "Working · Reading files…" / "Working…" / "Needs your input".
    private func liveStatusLine(_ status: SessionActivityMonitor.Status) -> String {
        switch status {
        case .waitingForInput:
            return LCached("Needs your input")
        case .working:
            if let step = activityStep?.trimmingCharacters(in: .whitespacesAndNewlines), !step.isEmpty {
                return "\(LCached("Working")) · \(step)"
            }
            return LCached("Working…")
        }
    }
}

// MARK: - New Agent Highlight

/// Accent ring + soft glow around an agent row that appeared after the
/// sidebar first saw the agent list (created, imported, shared, or paired
/// during this app run). Same idiom as the session-import flash, but it
/// stays until the user opens the agent once (`NewAgentHighlightStore`).
private struct NewAgentRowHighlight: ViewModifier {
    let isNew: Bool
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous)
                    .stroke(theme.accentColor.opacity(isNew ? 0.75 : 0), lineWidth: 1.5)
                    .shadow(color: theme.accentColor.opacity(isNew ? 0.45 : 0), radius: 5)
                    .allowsHitTesting(false)
            )
            .animation(.easeOut(duration: 0.6), value: isNew)
    }
}

extension View {
    fileprivate func newAgentHighlight(_ isNew: Bool) -> some View {
        modifier(NewAgentRowHighlight(isNew: isNew))
    }
}

/// Small "New" capsule after an agent's name so the row reads as new even
/// where the ring is subtle (light themes, a row at the very edge).
private struct NewAgentPill: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Text("New", bundle: .module)
            .font(.system(size: 8, weight: .bold))
            .textCase(.uppercase)
            .foregroundColor(theme.accentColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(theme.accentColor.opacity(0.16)))
            .accessibilityLabel(Text("New agent", bundle: .module))
    }
}

// MARK: - Workspace Agent Row

/// Row for a shared agent on a workspace roster — a teammate's (chat over the
/// relay) or the user's own (routes to the local agent). Same shape as
/// `AgentSidebarRow` (avatar, name, subtitle, hover gear) plus a status dot on
/// the avatar driven by `SharedAgentStatus`, the same vocabulary the composer
/// lock and Workspaces roster use. Offline rows dim their text but stay
/// clickable so the user can read the history.
private struct WorkspaceAgentSidebarRow: View {
    let identity: SharedAgentIdentity
    let workspaceId: String
    let status: SharedAgentStatus
    let isSelected: Bool
    var activityStatus: SessionActivityMonitor.Status? = nil
    /// Appeared on the roster during this app run and not opened yet.
    var isNew: Bool = false
    let onSelect: () -> Void
    /// Own agent: open its Settings ▸ Agents detail (the gear).
    var onOpenSettings: (() -> Void)?
    /// Teammate agent: a second chat window on it.
    var onOpenInNewWindow: (() -> Void)?
    /// Settings ▸ Workspaces on this row's workspace (the gear for teammate
    /// rows; a menu item for own rows).
    var onOpenWorkspace: (() -> Void)?
    /// Own agent only: revoke the share.
    var onUnshare: (() -> Void)?
    /// Own agent whose relay is off: turn it on so teammates can reach it.
    var onTurnOnRelay: (() -> Void)?

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    /// Hosted on this Mac — the row reads relay reachability and opens the
    /// agent's Settings. Own agents on another device are remote from here
    /// and take the teammate affordances (Chat, pairing status).
    private var isMine: Bool { identity.isHostedHere }
    private var isOffline: Bool {
        if case .offline = status { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 10) {
            AgentAvatarView(
                mascotId: identity.avatar,
                name: identity.name,
                tint: agentColorFor(identity.localAgent?.name ?? identity.name),
                diameter: 26,
                customImageURL: identity.customAvatarURL,
                monogramFontSize: 12,
                borderWidth: 0
            )
            .overlay(
                Group {
                    if let activityStatus {
                        SessionActivityRing(status: activityStatus)
                    }
                }
                .allowsHitTesting(false)
            )
            // One presence dot for own and teammate rows alike — own rows
            // read relay reachability, teammate rows the connect verdict —
            // so the section scans as one list instead of two glyph systems.
            .overlay(alignment: .bottomTrailing) {
                SharedAgentStatusDot(status: status)
                    .padding(1.5)
                    .background(Circle().fill(theme.sidebarBackground))
                    .offset(x: 2, y: 2)
                    .help(isMine ? ownPresenceHelp : status.shortLabel)
            }
            .opacity(isOffline ? 0.7 : 1)
            .animation(theme.springAnimation(responseMultiplier: 0.8), value: activityStatus)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(identity.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    if isNew {
                        NewAgentPill()
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                subtitle
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isOffline ? 0.6 : 1)

            // Hover-only gear: own agent → its Agents detail; teammate agent →
            // Settings ▸ Workspaces on this workspace (the roster owns
            // connect / unshare; the chat only consumes).
            if isHovered, let open = isMine ? onOpenSettings : onOpenWorkspace {
                Button(action: open) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: SidebarStyle.actionButtonSize, height: SidebarStyle.actionButtonSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(isMine ? L("Agent Settings") : L("Open Workspace"))
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(SidebarRowBackground(isSelected: isSelected, isHovered: isHovered))
        .clipShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
        .newAgentHighlight(isNew)
        .contentShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
        .onTapGesture(perform: onSelect)
        .contextMenu { contextMenuItems }
        .onHover { hovering in
            withAnimation(theme.springAnimation(responseMultiplier: 0.8)) {
                isHovered = hovering
            }
        }
        .animation(theme.springAnimation(responseMultiplier: 0.8), value: isSelected)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(identity.name), \(accessibilityStatus)"))
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button(action: onSelect) {
            Label(isMine ? L("Open Settings") : L("Chat"), systemImage: isMine ? "gearshape" : "bubble.left")
        }
        if let onOpenInNewWindow {
            Button(action: onOpenInNewWindow) {
                Label(L("Open in New Window"), systemImage: "macwindow.badge.plus")
            }
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(identity.address, forType: .string)
        } label: {
            Label(L("Copy Address"), systemImage: "doc.on.doc")
        }
        if let onOpenWorkspace {
            Button(action: onOpenWorkspace) {
                Label(L("Open Workspace"), systemImage: "rectangle.3.group")
            }
        }
        if isMine, onTurnOnRelay != nil, status != .ready, status != .connecting, let onTurnOnRelay {
            Button(action: onTurnOnRelay) {
                Label(L("Turn On Relay"), systemImage: "antenna.radiowaves.left.and.right")
            }
        }
        if let onUnshare {
            Divider()
            Button(role: .destructive, action: onUnshare) {
                Label(
                    identity.workspaceName.map { String(format: L("Unshare from %@"), $0) } ?? L("Unshare"),
                    systemImage: "person.2.slash"
                )
            }
        }
    }

    /// Subtitle priority is status-first: offline → connecting → failed
    /// (short label; the full reason is in the tooltip) → the open chat's
    /// title → "owner · model" (teammate) / "Your agent · model" (own).
    @ViewBuilder
    private var subtitle: some View {
        switch status {
        case .offline:
            Text(verbatim: status.shortLabel)
                .foregroundColor(theme.secondaryText.opacity(0.85))
        case .checking, .connecting:
            Text(verbatim: isMine ? L("Relay connecting…") : status.shortLabel)
                .foregroundColor(theme.secondaryText.opacity(0.85))
        case .notConnected(let reason, _):
            if isMine {
                Text("Relay off — teammates can't reach it", bundle: .module)
                    .foregroundColor(theme.warningColor.opacity(0.9))
            } else if reason != nil {
                Text("Couldn't connect", bundle: .module)
                    .foregroundColor(theme.warningColor.opacity(0.9))
            } else {
                Text(verbatim: status.shortLabel)
                    .foregroundColor(theme.secondaryText.opacity(0.85))
            }
        case .unavailable:
            Text(verbatim: status.shortLabel)
                .foregroundColor(theme.secondaryText.opacity(0.85))
        case .ready, .readOnlyTeammate:
            Text(verbatim: isMine ? localLabel : ownerAndModelLabel)
                .foregroundColor(theme.secondaryText.opacity(0.85))
        }
    }

    private var ownerAndModelLabel: String {
        var parts: [String] = []
        if identity.isOwnedElsewhere {
            parts.append(L("Your agent · other device"))
        } else if let owner = identity.ownerName, !owner.isEmpty {
            parts.append(owner)
        }
        if let model = identity.modelLabel { parts.append(model) }
        if parts.isEmpty { parts.append(L("Shared agent")) }
        return parts.joined(separator: " · ")
    }

    /// "Your agent · model" for the user's own shared agent.
    private var localLabel: String {
        var parts: [String] = [L("Your agent")]
        if let model = identity.modelLabel { parts.append(model) }
        return parts.joined(separator: " · ")
    }

    private var accessibilityStatus: String {
        if isMine {
            return status == .ready
                ? L("your agent, runs on this Mac")
                : L("your agent, relay off")
        }
        return status.shortLabel
    }

    private var ownPresenceHelp: String {
        switch status {
        case .ready: return L("Your agent — runs on this Mac, reachable by teammates")
        case .connecting: return L("Your agent — relay connecting")
        default: return L("Your agent — relay off, teammates can't reach it")
        }
    }

    private var helpText: String {
        var lines: [String] = [identity.name]
        if isMine {
            lines.append(
                identity.workspaceName.map {
                    String(format: L("Your agent — shared with %@, runs on this Mac"), $0)
                } ?? L("Your agent — shared with this workspace, runs on this Mac")
            )
            if let sharedAs = identity.sharedAsName {
                lines.append(String(format: L("shared as “%@”"), sharedAs))
            }
        } else if identity.isOwnedElsewhere {
            lines.append(
                identity.workspaceName.map {
                    String(format: L("Your agent — shared with %@ from another of your devices"), $0)
                } ?? L("Your agent — shared from another of your devices")
            )
        } else if let owner = identity.ownerName, !owner.isEmpty {
            lines.append(String(format: L("Shared by %@"), owner))
        }
        if let description = identity.description, !description.isEmpty {
            lines.append(description)
        }
        if case .notConnected(let reason?, _) = status, !isMine {
            lines.append(reason)
        }
        lines.append(identity.shortAddress)
        return lines.joined(separator: "\n")
    }

    nonisolated static func offlineLabel(lastSeen: Date?, now: Date = Date()) -> String {
        guard let lastSeen else { return L("Offline") }
        return String(format: L("Offline · last seen %@"), SharedAgentStatus.relative(lastSeen, now: now))
    }

    nonisolated static func shortAddress(_ address: String) -> String {
        SharedAgentIdentity.shortAddress(address)
    }
}

/// Avatar corner dot for a teammate's shared agent: green when ready, accent
/// while connecting, warning when a connect failed, muted when offline /
/// unavailable, and an outline for unknown ("not connected yet, no
/// verdict"). One mapping with `SharedAgentStatus.tint`.
private struct SharedAgentStatusDot: View {
    @Environment(\.theme) private var theme
    let status: SharedAgentStatus

    var body: some View {
        Group {
            switch status {
            case .ready:
                Circle().fill(theme.successColor)
            case .checking, .connecting:
                Circle().fill(theme.accentColor)
            case .notConnected(let reason, _):
                if reason == nil {
                    Circle().strokeBorder(theme.tertiaryText.opacity(0.6), lineWidth: 1.5)
                } else {
                    Circle().fill(theme.warningColor)
                }
            case .offline, .unavailable, .readOnlyTeammate:
                Circle().fill(theme.tertiaryText.opacity(0.5))
            }
        }
        .frame(width: 8, height: 8)
        .help(status.shortLabel)
    }
}

// MARK: - Directly Shared Agent Row

/// Row for an agent someone shared with the user through an invite link
/// (paired, but on no workspace roster), and for a workspace pairing whose
/// roster isn't loaded. Same shape as the workspace rows; there is no router
/// presence for these, so the avatar carries no dot and the subtitle reads
/// "note · model" or falls back to "Shared with you".
private struct RemoteAgentSidebarRow: View {
    let agent: RemoteAgent
    let isSelected: Bool
    var activityStatus: SessionActivityMonitor.Status? = nil
    /// Paired during this app run and not opened yet.
    var isNew: Bool = false
    let onSelect: () -> Void
    /// Direct share: forget the pairing.
    var onRemove: (() -> Void)?
    /// Workspace pairing: open its workspace in Settings.
    var onOpenWorkspace: (() -> Void)?

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            AgentAvatarView(
                mascotId: agent.avatar,
                name: agent.name,
                tint: agentColorFor(agent.name),
                diameter: 26,
                customImageURL: nil,
                monogramFontSize: 12,
                borderWidth: 0
            )
            .overlay(
                Group {
                    if let activityStatus {
                        SessionActivityRing(status: activityStatus)
                    }
                }
                .allowsHitTesting(false)
            )
            .animation(theme.springAnimation(responseMultiplier: 0.8), value: activityStatus)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(agent.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    if isNew {
                        NewAgentPill()
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // The section header already says "Shared with you"; a row
                // with no note or model shows no subtitle, like a local
                // custom agent without a role caption.
                if let subtitleLabel {
                    Text(verbatim: subtitleLabel)
                        .font(.system(size: 10))
                        .foregroundColor(theme.secondaryText.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Hover-only gear → where the pairing is managed: Settings ▸
            // Agents (direct share) or Settings ▸ Workspaces (workspace).
            if isHovered {
                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: SidebarStyle.actionButtonSize, height: SidebarStyle.actionButtonSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(onOpenWorkspace == nil ? L("Agent Settings") : L("Open Workspace"))
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(SidebarRowBackground(isSelected: isSelected, isHovered: isHovered))
        .clipShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
        .newAgentHighlight(isNew)
        .contentShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button(action: onSelect) { Label(L("Chat"), systemImage: "bubble.left") }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(agent.agentAddress, forType: .string)
            } label: {
                Label(L("Copy Address"), systemImage: "doc.on.doc")
            }
            if let onOpenWorkspace {
                Button(action: onOpenWorkspace) {
                    Label(L("Open Workspace"), systemImage: "rectangle.3.group")
                }
            }
            if let onRemove {
                Divider()
                Button(role: .destructive, action: onRemove) {
                    Label(L("Remove"), systemImage: "trash")
                }
            }
        }
        .onHover { hovering in
            withAnimation(theme.springAnimation(responseMultiplier: 0.8)) {
                isHovered = hovering
            }
        }
        .animation(theme.springAnimation(responseMultiplier: 0.8), value: isSelected)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(agent.name), \(L("shared with you"))"))
    }

    private func openSettings() {
        if let onOpenWorkspace {
            onOpenWorkspace()
        } else {
            AppDelegate.shared?.showManagementWindow(initialTab: .agents, deeplinkRemoteAgentId: agent.id)
        }
    }

    /// "note · model", either alone, or nil when neither is known.
    private var subtitleLabel: String? {
        var parts: [String] = []
        if let note = agent.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            parts.append(note)
        }
        if let model = agent.model, !model.isEmpty {
            parts.append(RemoteAgent.shortModelLabel(model))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var helpText: String {
        var lines: [String] = [agent.name]
        let description = agent.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { lines.append(description) }
        lines.append(agent.shortAddress)
        return lines.joined(separator: "\n")
    }
}

// MARK: - Discovered Agent Row

/// Row for an unpaired LAN peer under "On This Network". Same shape as
/// `RemoteAgentSidebarRow` (avatar, name, subtitle) with a network badge on
/// the avatar; a Bonjour advertisement carries no mascot, so the avatar is
/// always a monogram. Tapping runs ChatView's pairing/connect flow — the
/// same handoff the removed toolbar agent pill made.
private struct DiscoveredAgentSidebarRow: View {
    let agent: DiscoveredAgent
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            AgentAvatarView(
                mascotId: nil,
                name: agent.name,
                tint: agentColorFor(agent.name),
                diameter: 26,
                customImageURL: nil,
                monogramFontSize: 12,
                borderWidth: 0
            )
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "network")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .padding(1.5)
                    .background(Circle().fill(theme.sidebarBackground))
                    .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(agent.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    if agent.supportsSecureChannel {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(theme.successColor)
                            .help(L("End-to-end encrypted"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !agent.supportsSecureChannel {
                    // Old peer: agent traffic hard-requires E2E, so chat will
                    // be refused until it upgrades. Say so up front.
                    Text("Needs upgrade for encrypted chat", bundle: .module)
                        .font(.system(size: 10))
                        .foregroundColor(theme.warningColor)
                        .lineLimit(1)
                } else if let subtitleLabel {
                    Text(verbatim: subtitleLabel)
                        .font(.system(size: 10))
                        .foregroundColor(theme.secondaryText.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(SidebarRowBackground(isSelected: isSelected, isHovered: isHovered))
        .clipShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button(action: onSelect) { Label(L("Chat"), systemImage: "bubble.left") }
            if let address = agent.address, !address.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address, forType: .string)
                } label: {
                    Label(L("Copy Address"), systemImage: "doc.on.doc")
                }
            }
        }
        .onHover { hovering in
            withAnimation(theme.springAnimation(responseMultiplier: 0.8)) {
                isHovered = hovering
            }
        }
        .animation(theme.springAnimation(responseMultiplier: 0.8), value: isSelected)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(agent.name), \(L("On This Network"))"))
    }

    /// "host · description", either alone, or nil when neither is known —
    /// the same composition the agent pill's network row used.
    private var subtitleLabel: String? {
        var parts: [String] = []
        if let host = agent.host, !host.isEmpty {
            // "device.local." → "device", as the agent pill rendered it.
            parts.append(
                host
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    .replacingOccurrences(of: "\\.local$", with: "", options: .regularExpression)
            )
        }
        if !agent.agentDescription.isEmpty {
            parts.append(agent.agentDescription)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var helpText: String {
        var lines: [String] = [agent.name]
        if !agent.agentDescription.isEmpty { lines.append(agent.agentDescription) }
        // The fingerprint lets the user verify the cryptographic identity,
        // not just the attacker-controllable display name.
        if let fingerprint = agent.addressFingerprint { lines.append(fingerprint) }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Project Row

/// Row in the Projects lens. Same anatomy as `AgentSidebarRow`: 26pt
/// circle, 12pt name, 10pt caption ("3 chats"), `SidebarRowBackground`
/// selected while the project is the one on screen.
private struct ProjectRow: View {
    let project: Project
    let sessionCount: Int
    let isSelected: Bool
    let onOpen: () -> Void
    let onRename: () -> Void
    let onEditInstructions: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(theme.isDark ? 0.16 : 0.12))
                    .frame(width: 26, height: 26)
                Image(systemName: "folder.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: project.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Text(L("\(sessionCount) chats"))
                    .font(.system(size: 10))
                    .foregroundColor(isSelected ? theme.accentColor.opacity(0.9) : theme.secondaryText.opacity(0.85))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(SidebarRowBackground(isSelected: isSelected, isHovered: isHovered))
        .clipShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { hovering in
            withAnimation(theme.springAnimation(responseMultiplier: 0.8)) {
                isHovered = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            Button(action: onRename) { Text("Rename", bundle: .module) }
            Button(action: onEditInstructions) { Text("Edit Instructions…", bundle: .module) }
            Divider()
            Button(role: .destructive, action: onDelete) { Text("Delete", bundle: .module) }
        }
    }
}

// MARK: - Footer Row

/// A row-shaped button (icon in the avatar column, 12pt label, the rows'
/// hover fill). Hover is cleared whenever the window stops being key, so
/// clicking through to another window never leaves the row lit.
private struct SidebarFooterRow: View {
    let icon: String
    let title: LocalizedStringKey
    let action: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 26, height: 26)
                Text(title, bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(SidebarRowBackground(isSelected: false, isHovered: isHovered))
            .clipShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(theme.springAnimation(responseMultiplier: 0.8)) { isHovered = hovering }
        }
        .onChange(of: controlActiveState) { _, state in
            if state != .key { isHovered = false }
        }
        .localizedHelp(title)
    }
}

// MARK: - Session Row

private struct SessionRow: View {
    let session: ChatSessionData
    let agent: Agent?
    let isSelected: Bool
    /// Whether this row is part of an active multi-selection. Drives the
    /// accent background and the leading checkmark.
    var isMultiSelected: Bool = false
    /// True while this session is in the freshly-imported flash window;
    /// renders a short accent glow so the row is findable in the list.
    var isImportHighlighted: Bool = false
    /// Live activity for this row's session: `.working` animates the avatar
    /// ring, `.waitingForInput` renders the warning ring + badge, and either
    /// state swaps the metadata line for a status line and surfaces Stop.
    var activityStatus: SessionActivityMonitor.Status? = nil
    let isEditing: Bool
    let onSelect: () -> Void
    let onStartRename: () -> Void
    /// Fires with the typed buffer when the user confirms the rename.
    /// Parent owns trim and persist.
    let onConfirmRename: (String) -> Void
    let onCancelRename: () -> Void
    var onBufferChange: ((String) -> Void)? = nil
    let onDelete: () -> Void
    let onToggleArchive: () -> Void
    let onTogglePin: () -> Void
    /// Projects available as move targets. Empty hides the move menu.
    var projects: [Project] = []
    /// Move this session into a project (nil = remove from its project).
    var onSetProject: ((UUID?) -> Void)? = nil
    let onExport: (ChatSessionSidebar.ExportFormat) -> Void
    /// Stop this row's live run. Only rendered while `activityStatus` is set.
    var onStop: (() -> Void)? = nil
    /// Optional callback for opening in a new window
    var onOpenInNewWindow: (() -> Void)? = nil
    /// Optional callback for opening in a new tab of the current window
    var onOpenInNewTab: (() -> Void)? = nil
    /// Open this chat with its File Changes inspector showing.
    var onShowFileChanges: (() -> Void)? = nil

    @Environment(\.theme) private var theme
    @Environment(\.themedAlertScope) private var alertScope
    @ObservedObject private var fileChanges = FileChangeSummaryStore.shared
    @State private var isHovered = false
    @State private var showActionsPopover = false
    /// Drill-in page state for the actions popover: false shows the main
    /// action list, true shows the project picker rows.
    @State private var showProjectPicker = false
    /// Local buffer for the rename TextField. Kept on the row (not the
    /// sidebar) so focus churn during popover dismissal cannot desync it
    /// from the focused row.
    @State private var editBuffer: String = ""
    @FocusState private var isTextFieldFocused: Bool

    /// Whether this is the default agent
    private var isDefaultAgent: Bool {
        guard let agent = agent else { return true }
        return agent.isBuiltIn
    }

    /// Get a consistent color for the agent based on its ID
    private var agentColor: Color {
        guard let agent = agent, !agent.isBuiltIn else { return theme.secondaryText }
        // Generate a consistent hue from the agent ID
        let hash = agent.id.hashValue
        let hue = Double(abs(hash) % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    var body: some View {
        if isEditing {
            editingView
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(SidebarRowBackground(isSelected: isSelected, isHovered: isHovered))
                .clipShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
        } else {
            HStack(spacing: 10) {
                // Multi-select check, shown in place of leading padding so the
                // row doesn't shift when selection toggles.
                if isMultiSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }

                // Agent indicator, ringed while the session's run is live.
                Group {
                    if isDefaultAgent {
                        defaultAgentIndicator
                    } else if let agent = agent {
                        agentIndicatorView(agent)
                    }
                }
                .overlay(
                    Group {
                        if let activityStatus {
                            SessionActivityRing(status: activityStatus)
                        }
                    }
                    .allowsHitTesting(false)
                )
                .animation(theme.springAnimation(responseMultiplier: 0.8), value: activityStatus)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if session.pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(theme.secondaryText.opacity(0.85))
                                .rotationEffect(.degrees(45))
                        }

                        Text(session.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                            // The Text itself must be greedy so it claims all
                            // free width and pushes the trailing badges to the
                            // right; putting maxWidth on the enclosing HStack
                            // instead let the text hug its ideal and truncate
                            // early while empty space sat after the badges.
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if session.source != .chat {
                            sourceBadge
                        }

                        if !session.capabilities.isEmpty {
                            capabilityBadges
                        }

                        if let summary = fileChanges.summary(for: session.id), summary.setCount > 0 {
                            fileChangesBadge(summary)
                        }
                    }

                    // Live status replaces the relative timestamp while the
                    // session's run is active so the state is glanceable.
                    Group {
                        switch activityStatus {
                        case .working:
                            Text("Running…", bundle: .module)
                                .foregroundColor(theme.accentColor)
                        case .waitingForInput:
                            Text("Needs your input", bundle: .module)
                                .foregroundColor(theme.warningColor)
                        case nil:
                            Text(metadataLine)
                                .foregroundColor(theme.secondaryText.opacity(0.85))
                        }
                    }
                    .font(.system(size: 10))
                    .lineLimit(1)
                }
                // Fill the row so the title uses the full available width
                // instead of hugging its ideal size and letting the trailing
                // Spacer eat the slack (which truncated titles prematurely).
                .frame(maxWidth: .infinity, alignment: .leading)

                // Persistent (not hover-gated) Stop for the live run, so an
                // active task can be halted straight from the sidebar.
                if activityStatus != nil, let onStop {
                    SessionStopButton(action: onStop)
                }

                if isHovered || showActionsPopover {
                    SidebarRowActionButton(
                        icon: "ellipsis",
                        help: "Actions",
                        action: {
                            // Always reopen on the main page, not a stale
                            // project-picker drill-in from last time.
                            showProjectPicker = false
                            showActionsPopover.toggle()
                        }
                    )
                    .popover(isPresented: $showActionsPopover, arrowEdge: .trailing) {
                        actionsPopover
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(SidebarRowBackground(isSelected: isSelected || isMultiSelected, isHovered: isHovered))
            .clipShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous)
                    .stroke(
                        theme.accentColor.opacity(isImportHighlighted ? 0.8 : 0),
                        lineWidth: 1.5
                    )
                    .shadow(
                        color: theme.accentColor.opacity(isImportHighlighted ? 0.5 : 0),
                        radius: 5
                    )
                    .allowsHitTesting(false)
            )
            .animation(.easeOut(duration: 0.6), value: isImportHighlighted)
            .contentShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
            .onTapGesture {
                onSelect()
            }
            .animation(theme.springAnimation(responseMultiplier: 0.8), value: isMultiSelected)
            .onHover { hovering in
                withAnimation(theme.springAnimation(responseMultiplier: 0.8)) {
                    isHovered = hovering
                }
            }
            .animation(theme.springAnimation(responseMultiplier: 0.8), value: isSelected)
            .contextMenu {
                if activityStatus != nil, let onStop {
                    Button {
                        onStop()
                    } label: {
                        Label {
                            Text("Stop", bundle: .module)
                        } icon: {
                            Image(systemName: "stop.circle")
                        }
                    }
                    Divider()
                }
                if onOpenInNewTab != nil || onOpenInNewWindow != nil {
                    if let openInNewTab = onOpenInNewTab {
                        Button {
                            openInNewTab()
                        } label: {
                            Label {
                                Text("Open in New Tab", bundle: .module)
                            } icon: {
                                Image(systemName: "plus.square.on.square")
                            }
                        }
                    }
                    if let openInNewWindow = onOpenInNewWindow {
                        Button {
                            openInNewWindow()
                        } label: {
                            Label {
                                Text("Open in New Window", bundle: .module)
                            } icon: {
                                Image(systemName: "macwindow.badge.plus")
                            }
                        }
                    }
                    Divider()
                }
                Button(action: onStartRename) { Text("Rename", bundle: .module) }
                Button(action: onTogglePin) {
                    Text(session.pinned ? "Unpin" : "Pin", bundle: .module)
                }
                if !projects.isEmpty, let onSetProject {
                    Menu {
                        moveToProjectItems(onMove: onSetProject)
                    } label: {
                        Text(
                            session.projectId == nil ? "Move to Project" : "Change Project",
                            bundle: .module)
                    }
                }
                Divider()
                Button(action: requestExport) { Text("Export…", bundle: .module) }
                Divider()
                Button(action: onToggleArchive) {
                    Text(session.archived ? "Unarchive" : "Archive", bundle: .module)
                }
                Button(role: .destructive, action: requestDelete) { Text("Delete", bundle: .module) }
            }
        }
    }

    // MARK: - Move to Project

    /// Menu rows for moving this session: one per project (checkmark on the
    /// current one) plus "Remove from Project" when the session is in one.
    @ViewBuilder
    private func moveToProjectItems(onMove: @escaping (UUID?) -> Void) -> some View {
        ForEach(projects) { project in
            Button {
                onMove(project.id)
            } label: {
                if project.id == session.projectId {
                    Label { Text(verbatim: project.name) } icon: { Image(systemName: "checkmark") }
                } else {
                    Text(verbatim: project.name)
                }
            }
        }
        if session.projectId != nil {
            Divider()
            Button(role: .destructive) {
                onMove(nil)
            } label: {
                Text("Remove from Project", bundle: .module)
            }
        }
    }

    // MARK: - Actions Popover

    @ViewBuilder
    private var actionsPopover: some View {
        if showProjectPicker {
            projectPickerPopoverPage
        } else {
            mainActionsPopoverPage
        }
    }

    /// Second page of the actions popover: one row per project, plus
    /// "Remove from Project" and a back row. Same `ActionsPopoverButton`
    /// styling as the main page.
    private var projectPickerPopoverPage: some View {
        VStack(alignment: .leading, spacing: 2) {
            ActionsPopoverButton(icon: "chevron.left", label: "Back", isDestructive: false) {
                showProjectPicker = false
            }
            Divider().padding(.vertical, 2)
            ForEach(projects) { project in
                ActionsPopoverButton(
                    icon: project.id == session.projectId ? "checkmark" : "folder",
                    label: project.name,
                    labelIsVerbatim: true,
                    isDestructive: false
                ) {
                    dismissProjectPicker()
                    onSetProject?(project.id)
                }
            }
            if session.projectId != nil {
                Divider().padding(.vertical, 2)
                ActionsPopoverButton(
                    icon: "folder.badge.minus", label: "Remove from Project", isDestructive: true
                ) {
                    dismissProjectPicker()
                    onSetProject?(nil)
                }
            }
        }
        .padding(6)
        .frame(minWidth: 180)
    }

    private func dismissProjectPicker() {
        showProjectPicker = false
        showActionsPopover = false
    }

    private var mainActionsPopoverPage: some View {
        VStack(alignment: .leading, spacing: 2) {
            ActionsPopoverButton(icon: "pencil", label: "Rename", isDestructive: false) {
                showActionsPopover = false
                onStartRename()
            }
            ActionsPopoverButton(
                icon: session.pinned ? "pin.slash" : "pin",
                label: session.pinned ? "Unpin" : "Pin",
                isDestructive: false
            ) {
                showActionsPopover = false
                onTogglePin()
            }
            if !projects.isEmpty, onSetProject != nil {
                ActionsPopoverButton(
                    icon: "folder",
                    label: session.projectId == nil ? "Move to Project" : "Change Project",
                    isDestructive: false
                ) {
                    showProjectPicker = true
                }
            }
            Divider().padding(.vertical, 2)
            ActionsPopoverButton(icon: "square.and.arrow.up", label: "Export…", isDestructive: false) {
                showActionsPopover = false
                requestExport()
            }
            Divider().padding(.vertical, 2)
            ActionsPopoverButton(
                icon: session.archived ? "tray.and.arrow.up" : "archivebox",
                label: session.archived ? "Unarchive" : "Archive",
                isDestructive: false
            ) {
                showActionsPopover = false
                onToggleArchive()
            }
            ActionsPopoverButton(icon: "trash", label: "Delete", isDestructive: true) {
                showActionsPopover = false
                requestDelete()
            }
        }
        .padding(6)
        .frame(minWidth: 180)
    }

    // MARK: - Export Format Chooser

    private func requestExport() {
        let requestId = UUID()
        let scope = alertScope
        let metadata = session
        let sheet = ExportChooserSheet(session: session) { format, options in
            ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
            ChatSessionExportCoordinator.run(
                metadataSession: metadata,
                format: format,
                options: options,
                scope: scope
            )
        }
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: "Export Conversation",
                message: nil,
                buttons: [.cancel(L("Cancel"))],
                showsCloseButton: true,
                customContent: AnyView(sheet),
                width: 420,
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }

    // MARK: - Delete Confirmation

    /// Entry point for both the context menu and the popover's Delete row.
    /// Skips the dialog if the user opted out earlier this app session.
    private func requestDelete() {
        if DeleteConfirmationPreference.shared.skipForSession {
            onDelete()
            return
        }
        let requestId = UUID()
        let accessory = AnyView(DontAskAgainToggle())
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: "Delete Conversation?",
                message: L("\"\(session.title)\" will be removed permanently. This can't be undone."),
                accessory: accessory,
                buttons: [
                    .cancel(L("Cancel")),
                    .destructive(L("Delete")) { onDelete() },
                ],
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: alertScope, id: requestId)
                }
            ),
            scope: alertScope
        )
    }

    // MARK: - Capability Badges

    /// Stable rendering order.
    private var orderedCapabilities: [SessionCapability] {
        SessionCapability.allCases.filter { session.capabilities.contains($0) }
    }

    /// Up to 3 icons, then a `+N` pill.
    private var capabilityBadges: some View {
        let visibleLimit = 3
        let ordered = orderedCapabilities
        let visible = Array(ordered.prefix(visibleLimit))
        let overflow = ordered.count - visible.count
        return HStack(spacing: 3) {
            ForEach(visible, id: \.self) { cap in
                capabilityIcon(cap)
            }
            if overflow > 0 {
                Text(verbatim: "+\(overflow)")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(theme.secondaryText.opacity(theme.isDark ? 0.16 : 0.12))
                    )
                    .help(Text(verbatim: ordered.dropFirst(visibleLimit).map(\.label).joined(separator: ", ")))
            }
        }
    }

    /// File history badge: outstanding changed files (or a dimmed icon when
    /// every change was reverted). Opens the chat's File Changes inspector.
    private func fileChangesBadge(_ summary: FileChangeSessionSummary) -> some View {
        let active = summary.outstandingFiles > 0
        let color = active ? theme.accentColor : theme.tertiaryText
        return Button {
            onShowFileChanges?()
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "plus.forwardslash.minus")
                    .font(.system(size: 7.5, weight: .bold))
                if active {
                    Text(verbatim: "\(summary.outstandingFiles)")
                        .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                }
            }
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .frame(height: 14)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(theme.isDark ? 0.16 : 0.12))
            )
        }
        .buttonStyle(.plain)
        .help(
            active
                ? (summary.outstandingFiles == 1
                    ? Text("1 file changed in this chat", bundle: .module)
                    : Text("\(summary.outstandingFiles) files changed in this chat", bundle: .module))
                : Text("File changes in this chat were reverted", bundle: .module)
        )
        .accessibilityLabel(Text("Show file changes", bundle: .module))
    }

    private func capabilityIcon(_ cap: SessionCapability) -> some View {
        Image(systemName: cap.iconName)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundColor(theme.secondaryText)
            .frame(width: 14, height: 14)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(theme.secondaryText.opacity(theme.isDark ? 0.16 : 0.12))
            )
            .help(Text(LocalizedStringKey(cap.label), bundle: .module))
    }

    // MARK: - Source Badge

    /// Compact icon-only badge that surfaces the session's `SessionSource`
    /// (plugin / http / schedule / watcher). Chat-source rows hide it.
    /// A chat from the paired iPhone. Stored as a `.workspace` row (it runs
    /// through the shared-agent path), but it is the owner's own chat, not a
    /// teammate's, and is shown as the iPhone's.
    private var isFromPairedPhone: Bool {
        RemoteSessionContinuation.isFromPairedPhone(session)
    }

    private var sourceBadge: some View {
        Image(systemName: isFromPairedPhone ? "iphone" : session.source.iconName)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundColor(sourceBadgeColor)
            .frame(width: 14, height: 14)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(sourceBadgeColor.opacity(theme.isDark ? 0.16 : 0.12))
            )
            .help(sourceBadgeHelp)
    }

    /// Composes "<relative date> · via <plugin> · <key>" so the audit
    /// dimension is glanceable without expanding the row.
    private var metadataLine: String {
        var parts: [String] = [formatRelativeDate(session.updatedAt)]
        // A phone chat's key is the pairing key's nonce plus the phone's own
        // id: noise to a reader, so it names the iPhone and stops there.
        if isFromPairedPhone {
            parts.append("via iPhone")
            return parts.joined(separator: " · ")
        }
        let pluginName = session.sourcePluginId.map(PluginDisplayNameResolver.displayName(for:))
        if let origin = session.source.originLabel(pluginDisplayName: pluginName) {
            parts.append(origin)
        }
        if let key = session.externalSessionKey,
            !key.trimmingCharacters(in: .whitespaces).isEmpty
        {
            // Truncate noisy external keys (e.g. long Telegram chat ids)
            // so the row doesn't overflow horizontally.
            let trimmed = key.count > 14 ? "\(key.prefix(12))…" : key
            parts.append("·\u{00A0}\(trimmed)")
        }
        return parts.joined(separator: " · ")
    }

    private var sourceBadgeColor: Color {
        switch session.source {
        case .chat: return theme.secondaryText
        case .plugin: return theme.accentColorLight
        case .http: return theme.accentColorLight.opacity(0.85)
        case .channel: return theme.accentColor
        case .schedule: return theme.warningColor
        case .watcher: return theme.successColor
        case .selfSchedule: return theme.warningColor.opacity(0.9)
        case .imported: return theme.accentColorLight.opacity(0.7)
        case .delegation: return theme.accentColor.opacity(0.8)
        case .workspace: return theme.accentColor
        }
    }

    private var sourceBadgeHelp: Text {
        switch session.source {
        case .chat:
            return Text("Chat", bundle: .module)
        case .plugin:
            if let pid = session.sourcePluginId {
                return Text(verbatim: "Plugin · \(PluginDisplayNameResolver.displayName(for: pid))")
            }
            return Text("Plugin", bundle: .module)
        case .http:
            return Text("HTTP API", bundle: .module)
        case .channel:
            return Text("Agent Channel", bundle: .module)
        case .schedule:
            return Text("Schedule", bundle: .module)
        case .watcher:
            return Text("Watcher", bundle: .module)
        case .selfSchedule:
            return Text("Self-scheduled", bundle: .module)
        case .imported:
            return Text("Imported", bundle: .module)
        case .delegation:
            return Text("Orchestrator", bundle: .module)
        case .workspace:
            if isFromPairedPhone {
                return Text("Mobile", bundle: .module)
            }
            if let caller = session.workspace?.callerLabel {
                return Text(verbatim: "Workspace · \(caller)")
            }
            return Text("Workspace", bundle: .module)
        }
    }

    /// Default agent indicator with person icon
    private var defaultAgentIndicator: some View {
        ZStack {
            Circle()
                .fill(theme.secondaryText.opacity(theme.isDark ? 0.12 : 0.08))
                .frame(width: 24, height: 24)

            Image(systemName: "person.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.secondaryText.opacity(0.8))
        }
        .localizedHelp("Default")
    }

    @ViewBuilder
    private func agentIndicatorView(_ agent: Agent) -> some View {
        AgentAvatarView(
            mascotId: agent.avatar,
            name: agent.name,
            tint: agentColor,
            diameter: 24,
            customImageURL: agent.customAvatarURL,
            monogramFontSize: 10,
            borderWidth: 1
        )
        .help(agent.name)
    }

    private var editingView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField(text: $editBuffer, prompt: Text("Title", bundle: .module)) {
                    Text("Title", bundle: .module)
                }
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)
                .submitLabel(.done)
                .onSubmit { onConfirmRename(editBuffer) }
                .focused($isTextFieldFocused)
                .onExitCommand(perform: onCancelRename)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(theme.primaryBackground.opacity(0.5))
                )

                // Mouse fallbacks for the Return and Esc shortcuts.
                SidebarRowActionButton(
                    icon: "checkmark",
                    help: "Save (Return)",
                    action: { onConfirmRename(editBuffer) }
                )
                SidebarRowActionButton(
                    icon: "xmark",
                    help: "Cancel (Esc)",
                    action: onCancelRename
                )
            }

            renameKeyboardHint
        }
        .onAppear {
            editBuffer = session.title
            onBufferChange?(session.title)
            // Defer focus until the context menu finishes dismissing,
            // otherwise AppKit restores first-responder to the search field
            // on a later tick and clobbers it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTextFieldFocused = true
            }
        }
        .onChange(of: editBuffer) { _, newValue in
            onBufferChange?(newValue)
        }
    }

    /// Low-contrast hint showing the Return and Esc shortcuts.
    private var renameKeyboardHint: some View {
        HStack(spacing: 6) {
            keyHintChip(symbol: "return", label: "Save")
            Text("·")
                .font(.system(size: 9))
            keyHintChip(symbol: "escape", label: "Cancel")
        }
        .foregroundColor(theme.secondaryText.opacity(0.75))
        .padding(.leading, 6)
    }

    private func keyHintChip(symbol: String, label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 9, weight: .medium))
        }
    }

}

// MARK: - Actions Popover Button

/// Menu-style row used inside the actions popover. Owns its own hover state.
private struct ActionsPopoverButton: View {
    let icon: String
    let label: String
    /// True when `label` is user content (e.g. a project name) that must
    /// render verbatim instead of through the localization table.
    var labelIsVerbatim: Bool = false
    let isDestructive: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 14)
                Group {
                    if labelIsVerbatim {
                        Text(verbatim: label)
                    } else {
                        Text(LocalizedStringKey(label), bundle: .module)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundColor(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? hoverFill : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        if isDestructive { return .red }
        return isHovered ? theme.accentColor : theme.primaryText
    }

    private var hoverFill: Color {
        if isDestructive { return Color.red.opacity(0.12) }
        return theme.accentColor.opacity(0.12)
    }
}

// MARK: - Session Activity Ring

/// Ring drawn around a row's 24pt avatar while its run is live. `.working`
/// continuously rotates an angular-gradient stroke (a steady ring under
/// Reduce Motion); `.waitingForInput` renders a steady warning ring with a
/// question-mark badge, matching `BackgroundTaskStatus.waitingForInput`'s
/// iconography.
struct SessionActivityRing: View {
    let status: SessionActivityMonitor.Status

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSpinning = false

    private static let diameter: CGFloat = 30
    private static let lineWidth: CGFloat = 2

    var body: some View {
        switch status {
        case .working:
            if reduceMotion {
                ring(theme.accentColor.opacity(0.85))
            } else {
                Circle()
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                theme.accentColor.opacity(0.05),
                                theme.accentColor,
                            ]),
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round)
                    )
                    .frame(width: Self.diameter, height: Self.diameter)
                    .rotationEffect(.degrees(isSpinning ? 360 : 0))
                    .animation(
                        .linear(duration: 1.1).repeatForever(autoreverses: false),
                        value: isSpinning
                    )
                    .onAppear { isSpinning = true }
                    .onDisappear { isSpinning = false }
            }
        case .waitingForInput:
            ring(theme.warningColor.opacity(0.9))
                .overlay(alignment: .bottomTrailing) {
                    ZStack {
                        // Mask the ring/backdrop behind the badge glyph so it
                        // stays legible at this size.
                        Circle()
                            .fill(theme.primaryBackground)
                            .frame(width: 11, height: 11)
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.warningColor)
                    }
                    .offset(x: 2, y: 2)
                }
        }
    }

    private func ring(_ color: Color) -> some View {
        Circle()
            .stroke(color, lineWidth: Self.lineWidth)
            .frame(width: Self.diameter, height: Self.diameter)
    }
}

// MARK: - Session Stop Button

/// Persistent (non-hover-gated) stop control for a row whose run is live.
/// Styled like `SidebarRowActionButton` but tinted with the error color on
/// hover to telegraph that it halts execution.
struct SessionStopButton: View {
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isHovered ? theme.errorColor : theme.secondaryText)
                .frame(width: SidebarStyle.actionButtonSize, height: SidebarStyle.actionButtonSize)
                .background(
                    RoundedRectangle(
                        cornerRadius: SidebarStyle.actionButtonCornerRadius, style: .continuous
                    )
                    .fill(isHovered ? theme.errorColor.opacity(0.12) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .localizedHelp("Stop")
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Don't Ask Again Toggle

/// Checkbox row rendered as the delete-confirmation accessory. Writes
/// straight to the session-scoped preference so the toggle survives
/// across consecutive deletes within the same app run. Shared with the tab
/// strip's Delete item.
struct DontAskAgainToggle: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var pref = DeleteConfirmationPreference.shared

    var body: some View {
        Toggle(isOn: $pref.skipForSession) {
            Text("Don't ask me again", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
        .toggleStyle(.checkbox)
    }
}

// MARK: - Preview

#if DEBUG
    struct ChatSessionSidebar_Previews: PreviewProvider {
        static var previews: some View {
            ChatSessionSidebar(
                sessions: [],
                agentId: Agent.defaultId,
                onSelect: { _ in },
                onDeleteProject: { _ in }
            )
            .frame(height: 400)
        }
    }
#endif

// MARK: - History List (inspector pane)

/// The chat list behind the inspector's History pane (`ChatHistoryPaneView`):
/// search (title, metadata and full-text over message bodies) above the
/// same `SessionRow`s with activity rings, capability badges and the
/// per-row actions popover. Reuses the sidebar's private row types.
struct ChatHistoryList: View {
    let sessions: [ChatSessionData]
    let currentSessionId: UUID?
    /// Alert scope for the batch-delete confirmation.
    let scope: ThemedAlertScope
    let onSelect: (ChatSessionData) -> Void
    let onDelete: (UUID) -> Void
    let onRename: (UUID, String) -> Void
    let onSetArchived: (UUID, Bool) -> Void
    let onSetPinned: (UUID, Bool) -> Void
    let onSetProject: (UUID, UUID?) -> Void
    let onExport: (ChatSessionData, ChatSessionSidebar.ExportFormat) -> Void
    var onStop: ((UUID) -> Void)? = nil
    var onOpenInNewWindow: ((ChatSessionData) -> Void)? = nil
    var onOpenInNewTab: ((ChatSessionData) -> Void)? = nil
    /// Origin lens chosen in the dialog's Filter popover.
    var sourceFilter: ChatHistorySourceFilter = .all
    /// Archived lens: true lists only archived chats, false hides them.
    var showArchived: Bool = false
    /// Project lens chosen in the dialog's Filter popover (nil = any).
    var projectFilter: UUID? = nil
    /// Workspace lens chosen in the dialog's Filter popover (nil = any).
    var workspaceFilter: String? = nil
    /// Plugin lens chosen in the dialog's Filter popover (nil = any; "" =
    /// plugin chats with no recorded plugin id).
    var pluginFilter: String? = nil
    /// Schedule / watcher lenses: the schedule or watcher id those runs
    /// stamp as the session's external key (nil = any).
    var scheduleFilter: String? = nil
    var watcherFilter: String? = nil
    /// Capability lenses; a chat must carry every selected badge.
    var capabilityFilter: Set<SessionCapability> = []
    /// Resets the dialog's source / archived lenses from the empty state.
    var onClearFilters: (() -> Void)? = nil
    /// Cap on the list's height. The dialog capped it at 360pt; the
    /// inspector's History pane passes nil so the list fills the rail.
    var listMaxHeight: CGFloat? = 360
    /// Control shown at the trailing end of the search row (the host's
    /// Filter button), so search and filter form one row.
    var searchAccessory: AnyView? = nil
    /// Hint under "No chats yet": whose chats the host lists.
    var emptyHint: LocalizedStringKey = "Chats with this agent appear here."

    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var projectManager = ProjectManager.shared
    @ObservedObject private var activityMonitor = SessionActivityMonitor.shared
    @ObservedObject private var importHighlight = ChatSessionImportHighlight.shared

    @State private var searchQuery: String = ""
    @State private var contentMatchedSessionIds: Set<UUID> = []
    @State private var contentSearchTask: Task<Void, Never>?
    @State private var isContentSearchInFlight = false
    @FocusState private var isSearchFocused: Bool
    @State private var editingSessionId: UUID?
    /// Multi-selection (⌘-click toggles, ⇧-click extends from the anchor).
    @State private var selectedIds: Set<UUID> = []
    @State private var selectionAnchorId: UUID?

    private var hasActiveFilter: Bool {
        showArchived || sourceFilter != .all || projectFilter != nil || workspaceFilter != nil
            || pluginFilter != nil || scheduleFilter != nil || watcherFilter != nil
            || !capabilityFilter.isEmpty
    }

    private var filteredSessions: [ChatSessionData] {
        let visible = sessions.filter { session in
            session.archived == showArchived && sourceFilter.matches(session)
                && (projectFilter == nil || session.projectId == projectFilter)
                && (workspaceFilter == nil || session.workspace?.workspaceId == workspaceFilter)
                && (pluginFilter == nil
                    || (session.source == .plugin && (session.sourcePluginId ?? "") == pluginFilter))
                && (scheduleFilter == nil
                    || (session.source == .schedule && session.externalSessionKey == scheduleFilter))
                && (watcherFilter == nil
                    || (session.source == .watcher && session.externalSessionKey == watcherFilter))
                && capabilityFilter.isSubset(of: session.capabilities)
        }
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        let matched: [ChatSessionData]
        if trimmed.isEmpty {
            matched = visible
        } else {
            matched = visible.filter { session in
                if SearchService.matches(query: searchQuery, in: session.title) { return true }
                if let key = session.externalSessionKey,
                    SearchService.matches(query: searchQuery, in: key)
                {
                    return true
                }
                if contentMatchedSessionIds.contains(session.id) { return true }
                return session.capabilities.contains { cap in
                    SearchService.matches(query: searchQuery, in: cap.label)
                }
            }
        }
        return SessionActivityOrdering.ordered(
            matched,
            activeIds: Set(activityMonitor.statuses.keys)
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                SidebarSearchField(
                    text: $searchQuery,
                    placeholder: "Search chats...",
                    isFocused: $isSearchFocused,
                    isSearching: isContentSearchInFlight
                )
                if let searchAccessory {
                    searchAccessory
                }
            }

            if !selectedIds.isEmpty {
                selectionActionBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if sessions.isEmpty {
                SidebarEmptyState(
                    icon: "bubble.left.and.bubble.right",
                    title: "No chats yet",
                    hint: emptyHint
                )
            } else if filteredSessions.isEmpty, isContentSearchInFlight {
                placeholder(icon: nil, text: "Searching conversations…")
            } else if filteredSessions.isEmpty, hasActiveFilter,
                searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
            {
                // Lens (not search) produced the empty list: offer a way
                // back instead of the search-flavored no-results view.
                VStack(spacing: 8) {
                    placeholder(
                        icon: showArchived ? "archivebox" : "line.3.horizontal.decrease.circle",
                        text: showArchived ? "No archived chats" : "No chats match this filter"
                    )
                    if let onClearFilters {
                        Button {
                            withAnimation(theme.animationQuick()) { onClearFilters() }
                        } label: {
                            Text("Clear Filters", bundle: .module)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.accentColor)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .padding(.bottom, 16)
                    }
                }
            } else if filteredSessions.isEmpty {
                SidebarNoResultsView(searchQuery: searchQuery) {
                    withAnimation(theme.animationQuick()) { searchQuery = "" }
                }
                .frame(maxHeight: listMaxHeight ?? .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredSessions) { session in
                            SessionRow(
                                session: session,
                                agent: agentManager.agent(for: session.agentId ?? Agent.defaultId),
                                isSelected: session.id == currentSessionId,
                                isMultiSelected: selectedIds.contains(session.id),
                                isImportHighlighted: importHighlight.sessionIds.contains(session.id),
                                activityStatus: activityMonitor.statuses[session.id],
                                isEditing: editingSessionId == session.id,
                                onSelect: { handleTap(session) },
                                onStartRename: { editingSessionId = session.id },
                                onConfirmRename: { newTitle in
                                    let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
                                    if !trimmed.isEmpty { onRename(session.id, trimmed) }
                                    editingSessionId = nil
                                },
                                onCancelRename: { editingSessionId = nil },
                                onDelete: {
                                    editingSessionId = nil
                                    onDelete(session.id)
                                },
                                onToggleArchive: { onSetArchived(session.id, !session.archived) },
                                onTogglePin: { onSetPinned(session.id, !session.pinned) },
                                projects: projectManager.projects,
                                onSetProject: { onSetProject(session.id, $0) },
                                onExport: { onExport(session, $0) },
                                onStop: onStop.map { stop in { stop(session.id) } },
                                onOpenInNewWindow: onOpenInNewWindow.map { open in { open(session) } },
                                onOpenInNewTab: onOpenInNewTab.map { open in { open(session) } },
                                onShowFileChanges: {
                                    onSelect(session)
                                    FileChangeSummaryStore.requestPanel(sessionId: session.id.uuidString)
                                }
                            )
                            .id(session.id)
                        }
                    }
                    .padding(.bottom, 4)
                    .animation(
                        theme.springAnimation(responseMultiplier: 0.9),
                        value: filteredSessions.map(\.id))
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: listMaxHeight ?? .infinity)
            }
        }
        .animation(theme.animationQuick(), value: selectedIds)
        .onChange(of: searchQuery) { _, query in
            scheduleContentSearch(query)
        }
    }

    // MARK: Multi-selection

    private func handleTap(_ session: ChatSessionData) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            toggleSelection(session.id)
        } else if flags.contains(.shift) {
            extendSelection(to: session.id)
        } else if !selectedIds.isEmpty {
            toggleSelection(session.id)
        } else {
            selectionAnchorId = session.id
            onSelect(session)
        }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
        selectionAnchorId = id
    }

    private func extendSelection(to id: UUID) {
        let ids = filteredSessions.map(\.id)
        guard
            let anchor = selectionAnchorId ?? currentSessionId,
            let anchorIndex = ids.firstIndex(of: anchor),
            let targetIndex = ids.firstIndex(of: id)
        else {
            selectedIds.insert(id)
            selectionAnchorId = id
            return
        }
        let range = anchorIndex <= targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
        selectedIds.formUnion(ids[range])
    }

    private func clearSelection() {
        selectedIds.removeAll()
        selectionAnchorId = nil
    }

    /// Batch bar for the selection: move to project, archive, delete, clear.
    private var selectionActionBar: some View {
        HStack(spacing: 8) {
            Text("\(selectedIds.count) selected", bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)

            Spacer(minLength: 4)

            if !projectManager.projects.isEmpty {
                Menu {
                    ForEach(projectManager.projects) { project in
                        Button { moveSelected(to: project.id) } label: { Text(verbatim: project.name) }
                    }
                    Divider()
                    Button { moveSelected(to: nil) } label: {
                        Text("Remove from Project", bundle: .module)
                    }
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: SidebarStyle.actionButtonSize, height: SidebarStyle.actionButtonSize)
                        .background(
                            RoundedRectangle(cornerRadius: SidebarStyle.actionButtonCornerRadius, style: .continuous)
                                .fill(theme.secondaryBackground.opacity(0.5))
                        )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(theme.secondaryText)
                .fixedSize()
                .localizedHelp("Move to Project")
            }
            selectionBarButton(icon: "archivebox", help: "Archive", tint: theme.secondaryText) {
                for id in selectedIds { onSetArchived(id, true) }
                clearSelection()
            }
            selectionBarButton(icon: "trash", help: "Delete", tint: .red) {
                requestDeleteSelected()
            }
            selectionBarButton(icon: "xmark", help: "Clear Selection", tint: theme.secondaryText) {
                clearSelection()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous)
                .fill(theme.accentColor.opacity(theme.isDark ? 0.16 : 0.10))
        )
    }

    private func selectionBarButton(
        icon: String, help: LocalizedStringKey, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: SidebarStyle.actionButtonSize, height: SidebarStyle.actionButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: SidebarStyle.actionButtonCornerRadius, style: .continuous)
                        .fill(theme.secondaryBackground.opacity(0.5))
                )
        }
        .buttonStyle(.plain)
        .localizedHelp(help)
    }

    private func moveSelected(to projectId: UUID?) {
        for id in selectedIds { onSetProject(id, projectId) }
        clearSelection()
    }

    /// Confirms once, then deletes every selected session; honors the
    /// "don't ask again" opt-out like the single-row flow.
    private func requestDeleteSelected() {
        let ids = selectedIds
        guard !ids.isEmpty else { return }
        if DeleteConfirmationPreference.shared.skipForSession {
            performDelete(ids)
            return
        }
        let requestId = UUID()
        let scope = self.scope
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: "Delete Conversations?",
                message: L("\(ids.count) conversations will be removed permanently. This can't be undone."),
                accessory: AnyView(DontAskAgainToggle()),
                buttons: [
                    .cancel(L("Cancel")),
                    .destructive(L("Delete")) { performDelete(ids) },
                ],
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }

    private func performDelete(_ ids: Set<UUID>) {
        for id in ids { onDelete(id) }
        clearSelection()
    }

    private func placeholder(icon: String?, text: LocalizedStringKey) -> some View {
        VStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(theme.secondaryText.opacity(0.6))
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text, bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    /// Debounced full-text lookup, mirroring the sidebar's implementation.
    private func scheduleContentSearch(_ query: String) {
        contentSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            contentMatchedSessionIds = []
            isContentSearchInFlight = false
            return
        }
        isContentSearchInFlight = true
        contentSearchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let ids = await ChatSessionStore.sessionIds(withContentContaining: trimmed)
            guard !Task.isCancelled else { return }
            contentMatchedSessionIds = ids
            isContentSearchInFlight = false
        }
    }
}

/// Row frames for the agent list's drag-to-reorder hit testing.
private struct AgentRowFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
