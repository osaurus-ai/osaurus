//
//  ChatSessionSidebar.swift
//  osaurus
//
//  The chat window's left rail: agents and their chats, then projects.
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
    /// seen.
    let agentId: UUID
    /// Live width of the rail, driven by the parent's resize handle so the
    /// inner content (titles, chips, rows) reflows to fill the chosen width.
    var width: CGFloat = SidebarStyle.width
    var activeSessionId: UUID? = nil
    var activeOpenTabId: UUID? = nil
    var openChats: [ChatTab] = []
    var onSelectOpenChat: ((UUID) -> Void)? = nil
    var onCloseOpenChat: ((UUID) -> Void)? = nil
    /// The window's chat selection. nil leaves rows without checkboxes.
    var chatSelection: Binding<ChatSelection>? = nil
    /// False while a page with its own batch bar (All chats) is on screen.
    var showsBatchBar = true
    /// Selectable chat ids in the order their rows sit on screen, for
    /// Shift-click ranges. Reported by the rows themselves.
    @State private var visibleChatOrder: [UUID] = []
    @State private var navigatorRenameId: UUID?
    @ObservedObject private var conversations = ChatSessionsManager.shared
    @State private var agentExpansion: [UUID: Bool] = [:]
    @State private var visibleChatCounts: [UUID: Int] = [:]
    /// The local Agents section folded to its header. Remembered across
    /// launches; a search ignores it so matches are never hidden.
    @AppStorage("chatSidebar.agentsCollapsed") private var agentsCollapsed = false
    /// The Pinned group folded to its header, remembered the same way.
    @AppStorage("chatSidebar.pinnedCollapsed") private var pinnedCollapsed = false
    /// Projects folded to their headers (comma-separated ids), remembered
    /// the same way.
    @AppStorage("chatSidebar.collapsedProjects") private var collapsedProjectsStorage = ""
    /// Workspaces folded to their headers (comma-separated ids).
    @AppStorage("chatSidebar.collapsedWorkspaces") private var collapsedWorkspacesStorage = ""
    /// "On <Mac>", "Shared with you" and the Workspaces explainer folded
    /// to their headers (comma-separated keys).
    @AppStorage("chatSidebar.collapsedSharedGroups") private var collapsedSharedGroupsStorage = ""
    /// Workspace agent rows folded open or closed, by `workspaceRowKey`.
    @State private var workspaceAgentExpansion: [String: Bool] = [:]
    @State private var visibleWorkspaceChatCounts: [String: Int] = [:]
    /// Open the All chats page. Archived chats are listed there only.
    var onShowAllChats: ((AllChatsRequest) -> Void)? = nil
    /// The All chats page is on screen: its row is the highlighted one.
    var isShowingAllChats = false
    /// Open a chat in the window's current tab (e.g. a workspace agent's
    /// row resuming its last conversation).
    let onSelect: (ChatSessionData) -> Void
    /// Start a fresh chat in a project from its row's New Chat.
    var onNewChatInProject: ((Project) -> Void)? = nil
    /// Stop the live run driving the given session id. Rows only offer the
    /// control while `SessionActivityMonitor` reports the session active.
    var onStop: ((UUID) -> Void)? = nil
    /// Open a chat in a new tab of this window (browser-style).
    var onOpenInNewTab: ((ChatSessionData) -> Void)? = nil
    /// Start a fresh chat with a local agent: its row's click (when
    /// closed), its `New chat` row and its menu's New Chat.
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
    /// The other Mac and agent the active tab's chat runs on, or nil. While
    /// set, that row is the selected one (no local row is).
    var activeHostedAgent: (device: String, agentId: UUID)? = nil
    /// Chat with one of the user's agents on another of their Macs.
    var onSelectHostedAgent: ((String, UUID) -> Void)? = nil
    /// Export formats offered by chat rows; the type lives here because the
    /// sidebar has always been its home (`ChatSessionExportCoordinator`,
    /// `ExportChooserSheet` and `AllChatsList` share it).
    enum ExportFormat {
        case markdown
        case pdf
        case zip
    }

    @Environment(\.theme) private var theme
    @Environment(\.themedAlertScope) private var alertScope
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var agentDirectory = SyncAgentDirectory.shared
    @ObservedObject private var hostedRunMonitor = SyncHostedRunMonitor.shared
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
    /// The rail's search query (row 3 of the rail, like History's search).
    /// Narrows every list by name and chat title. Trails `navigatorSearchText`
    /// (the field's text) by a short pause, because each change rescans
    /// every agent's history.
    @State private var navigatorQuery: String = ""
    @State private var navigatorSearchText: String = ""
    @FocusState private var isNavigatorSearchFocused: Bool

    var body: some View {
        SidebarContainer(attachedEdge: .leading, topPadding: 16, width: width, roundBottomCorners: false, showsBorder: false) {
            navigatorSearchRow
            ScrollView {
                VStack(spacing: theme.space.s2) {
                    if let onShowAllChats {
                        NavigatorLinkRow(
                            icon: "clock",
                            title: L("All chats"),
                            count: Self.allChatsCount(conversations.sessions),
                            isSelected: isShowingAllChats
                        ) { onShowAllChats(AllChatsRequest()) }
                        .padding(.bottom, theme.space.s8)
                    }
                    if let orchestrator = agentManager.agent(for: Agent.defaultId),
                        navigatorShows(orchestrator)
                    {
                        localAgentSection(orchestrator)
                    }
                    pinnedSection
                    if isFilteringNavigator && !hasAgentMatches && filteredPinnedItems.isEmpty {
                        SidebarEmptyState(icon: "magnifyingglass", title: "No agents or chats match")
                    }
                    if !isFilteringNavigator || !filteredLocalAgents.isEmpty {
                        sidebarHeader.padding(.top, theme.space.s14)
                    }
                    if !agentsCollapsed || isFilteringNavigator {
                        VStack(spacing: theme.space.s8) {
                            ForEach(filteredLocalAgents) { agent in
                                VStack(spacing: theme.space.s2) { localAgentSection(agent) }
                            }
                        }
                    }
                    ForEach(filteredProjects) { project in
                        VStack(spacing: theme.space.s2) { projectSection(project) }
                    }
                    ForEach(visibleHostedAgents) { host in
                        hostedAgentsSection(host)
                    }
                    workspaceSections
                    if !directlySharedAgents.isEmpty { sharedAgentsSection(directlySharedAgents) }
                    if isFilteringNavigator, let onShowAllChats {
                        NavigatorLinkRow(
                            icon: "text.magnifyingglass",
                            title: L("Search messages for “\(trimmedNavigatorQuery)”")
                        ) { onShowAllChats(AllChatsRequest(query: trimmedNavigatorQuery)) }
                        .padding(.top, theme.space.s8)
                    }
                }
                .padding(.horizontal, theme.space.s16)
                .padding(.bottom, theme.space.s16)
            }
            .sidebarScrollEdgeFade()
            .coordinateSpace(name: "agentList")
            .onPreferenceChange(AgentRowFramesKey.self) { agentRowFrames = $0 }
            .onPreferenceChange(VisibleChatOrderKey.self) { visibleChatOrder = Self.visibleChatOrder($0) }
            if showsBatchBar, let binding = chatSelection, binding.wrappedValue.isActive {
                ChatBatchBar(
                    placement: .sidebar,
                    selectedCount: binding.wrappedValue.count,
                    onArchive: {
                        ChatBatchActions.setArchived(binding.wrappedValue.selectedIds, archived: true)
                        binding.wrappedValue.clear()
                    },
                    onDelete: {
                        ChatBatchActions.requestDelete(binding.wrappedValue.selectedIds, scope: alertScope) {
                            binding.wrappedValue.clear()
                        }
                    },
                    onDone: { binding.wrappedValue.clear() }
                )
                .padding(theme.space.s8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(theme.motion.quick, value: chatSelection?.wrappedValue.isActive ?? false)
        .onChange(of: agentId) { _, newAgentId in
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

    @ViewBuilder
    private func localAgentSection(_ agent: Agent) -> some View {
                    let activity = activityStatus(for: agent)
                    AgentSidebarRow(
                        agent: agent,
                        isExpanded: isAgentExpanded(agent),
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
                            switch Self.agentRowClick(isOpen: isAgentExpanded(agent)) {
                            case .close:
                                agentExpansion[agent.id] = false
                            case .openToNewChat:
                                agentExpansion[agent.id] = true
                                showNewChat(with: agent)
                            }
                        },
                        onNewChat: onNewChatWithAgent.map { start in
                            {
                                newAgentHighlight.markSeen(localAgentId: agent.id)
                                start(agent.id)
                            }
                        },
                        onStop: activity == nil ? nil : { stopActivity(for: agent) },
                        onRename: agent.isBuiltIn ? nil : { AgentSidebarActions.rename(agent, to: $0) },
                        onDelete: agent.isBuiltIn ? nil : {
                            AgentSidebarActions.requestDelete(
                                agent, chatCount: Self.agentChatCount(conversations.sessions, agentId: agent.id),
                                scope: alertScope)
                        },
                        onShowAllChats: onShowAllChats.map { show in { show(AllChatsRequest(agentId: agent.id)) } },
                        onSelectChats: chatSelection.flatMap { binding in
                            onShowAllChats.map { show in
                                {
                                    binding.wrappedValue.select(
                                        Self.allChatsIds(conversations.sessions, agentId: agent.id))
                                    show(AllChatsRequest(agentId: agent.id))
                                }
                            }
                        },
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
        if isAgentExpanded(agent) {
            if !isFilteringNavigator {
                NavigatorLinkRow(
                    icon: "plus",
                    title: L("New chat"),
                    isSelected: navigatorHighlight == .newChat(agent.id)
                ) { showNewChat(with: agent) }
                .accessibilityLabel(Text(verbatim: L("New chat with \(agent.displayName)")))
            }
            let recent = navigatorChats(for: agent.id)
            let visible = Self.navigatorVisibleChats(
                recent, cap: Self.chatsPerAgent, activeIds: Set(activityMonitor.statuses.keys))
            ForEach(visible) { chat in
                navigatorConversationRow(chat, agent: agent)
            }
            let total = Self.allChatsCount(conversations.sessions, agentId: agent.id)
            if let onShowAllChats, recent.count > visible.count || (!isFilteringNavigator && total > visible.count) {
                Button {
                    onShowAllChats(AllChatsRequest(agentId: agent.id, query: trimmedNavigatorQuery))
                } label: {
                    Text(verbatim: L("All \(total) chats"))
                        .textStyle(.label)
                        .monospacedDigit()
                        .foregroundStyle(theme.text.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, NavigatorRowMetrics.textLeading)
                        .frame(height: NavigatorRowMetrics.rowHeight)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    /// The agent's new chat screen: its untouched chat when one is on
    /// screen, else a fresh one.
    private func showNewChat(with agent: Agent) {
        newAgentHighlight.markSeen(localAgentId: agent.id)
        keepAgentExpansion(for: [agentId, agent.id])
        if navigatorHighlight == .newChat(agent.id) { return }
        onNewChatWithAgent?(agent.id)
    }

    /// Chats listed under an open agent; the rest are on the All chats page.
    static let chatsPerAgent = 5

    /// Every saved chat of the agent, archived included: what deleting the
    /// agent removes.
    nonisolated static func agentChatCount(_ sessions: [ChatSessionData], agentId: UUID) -> Int {
        sessions.reduce(0) { $0 + (($1.agentId ?? Agent.defaultId) == agentId ? 1 : 0) }
    }

    /// Pure rule (testable): the chats the All chats page counts, archived
    /// ones aside, for one agent or (nil) everyone.
    nonisolated static func allChatsCount(_ sessions: [ChatSessionData], agentId: UUID? = nil) -> Int {
        allChatsIds(sessions, agentId: agentId).count
    }

    nonisolated static func allChatsIds(_ sessions: [ChatSessionData], agentId: UUID? = nil) -> [UUID] {
        sessions.filter { session in
            !session.archived && AllChatsModel.isListed(session)
                && (agentId.map { (session.agentId ?? Agent.defaultId) == $0 } ?? true)
        }.map(\.id)
    }

    /// Opening a chat can change the window's agent, which moves the
    /// default (the active agent open). Fixing the agents' current state
    /// first means a chat pick never folds or unfolds anything.
    private func keepAgentExpansion(for ids: [UUID]) {
        for id in ids where agentExpansion[id] == nil {
            agentExpansion[id] = id == agentId
        }
    }

    /// While searching, an agent opens on its matching chats and stays
    /// folded when only its name matched; otherwise the user's choice
    /// (default: the active agent open) holds.
    private func isAgentExpanded(_ agent: Agent) -> Bool {
        if isFilteringNavigator { return !navigatorChats(for: agent.id).isEmpty }
        return agentExpansion[agent.id] ?? (agent.id == agentId)
    }

    /// The agent's chats the rail lists: all of them, or the ones whose
    /// title matches the search.
    private func navigatorChats(for agentId: UUID) -> [HistoryItem] {
        Self.filterByName(historyItems(for: agentId), query: navigatorQuery, name: \.title)
    }

    /// The first `cap` chats, plus any live chat past the cap, in the
    /// incoming order: a running or waiting chat is never hidden behind
    /// "Show more", and rows never reorder when a run starts.
    nonisolated static func navigatorVisibleChats<Item: Identifiable>(
        _ items: [Item], cap: Int, activeIds: Set<UUID>
    ) -> [Item] where Item.ID == UUID {
        items.enumerated().filter { $0.offset < cap || activeIds.contains($0.element.id) }.map(\.element)
    }

    /// Whether a local agent's row survives the search: by its name or by
    /// any of its chats' titles.
    private func navigatorShows(_ agent: Agent) -> Bool {
        Self.navigatorShowsAgent(
            name: agent.displayName,
            chatTitles: isFilteringNavigator ? historyItems(for: agent.id).map(\.title) : [],
            query: navigatorQuery
        )
    }

    /// Pure rule (testable): an agent stays listed under a query when its
    /// name or one of its chats' titles matches, using the same matching
    /// as every other navigator list.
    nonisolated static func navigatorShowsAgent(name: String, chatTitles: [String], query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return !filterByName([name], query: trimmed, name: { $0 }).isEmpty
            || !filterByName(chatTitles, query: trimmed, name: { $0 }).isEmpty
    }

    /// Use the original conversation row's menu, rename and confirmation flows.
    /// Drafts stay in memory until the user explicitly performs a saved action.
    /// `agent` is nil for a chat with a teammate's agent; `sharedAvatar`
    /// is that agent, for rows that show an avatar. Workspace chats can't
    /// move into a project: they belong to their workspace's row.
    private func navigatorConversationRow(
        _ chat: HistoryItem, agent: Agent?, showsAgentAvatar: Bool = false,
        sharedAvatar: SharedAgentIdentity? = nil, workspaceRowKey: String? = nil
    ) -> some View {
        let live = openChats.first { $0.id == chat.openTabId }?.session
        let metadata = chat.saved ?? ChatSessionData(id: chat.id, title: chat.title,
            updatedAt: chat.updatedAt, agentId: agent?.id ?? chat.agentId, archived: live?.archived ?? false,
            pinned: live?.pinned ?? false, projectId: live?.projectId)
        let isWorkspaceChat = metadata.workspace != nil || live?.workspaceContext != nil
        let selection = rowSelection(for: chat)
        return SessionRow(session: metadata, agent: agent, isSelected: chat.isSelected,
            selection: selection,
            navigatorStyle: true, showsAgentAvatar: showsAgentAvatar, sharedAvatar: sharedAvatar,
            activityStatus: activityMonitor.statuses[chat.id],
            isEditing: navigatorRenameId == chat.id,
            onSelect: {
                keepAgentExpansion(for: [agentId] + (agent.map { [$0.id] } ?? []))
                if let workspaceRowKey { workspaceAgentExpansion[workspaceRowKey] = true }
                if let tabId = chat.openTabId { onSelectOpenChat?(tabId) }
                else if let saved = chat.saved { onSelect(saved) }
            },
            onStartRename: { navigatorRenameId = chat.id },
            onConfirmRename: { title in
                let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    _ = savedConversation(chat)
                    live?.title = title
                    conversations.rename(id: chat.id, title: title)
                }
                navigatorRenameId = nil
            },
            onCancelRename: { navigatorRenameId = nil },
            onDelete: {
                navigatorRenameId = nil
                if chat.saved != nil { ChatWindowManager.shared.deleteSession(id: chat.id) }
                else if let tabId = chat.openTabId { onCloseOpenChat?(tabId) }
            },
            onToggleArchive: {
                _ = savedConversation(chat)
                live?.archived = !metadata.archived
                conversations.setArchived(id: chat.id, archived: !metadata.archived)
            },
            onTogglePin: {
                _ = savedConversation(chat)
                live?.pinned = !metadata.pinned
                conversations.setPinned(id: chat.id, pinned: !metadata.pinned)
            },
            projects: isWorkspaceChat ? [] : projectManager.projects,
            onSetProject: { projectId in
                _ = savedConversation(chat)
                live?.projectId = projectId
                conversations.setProject(id: chat.id, projectId: projectId)
            },
            onExport: { format in
                ChatSessionExportCoordinator.run(metadataSession: savedConversation(chat), format: format, scope: alertScope)
            },
            prepareExport: { _ = savedConversation(chat) },
            onStop: onStop.map { stop in { stop(chat.id) } },
            onOpenInNewWindow: {
                let windowAgentId = agent?.id ?? chat.agentId
                let tab = openChats.first { $0.id == chat.openTabId }
                if let tab, !tab.isHibernated, tab.session.turns.isEmpty, !tab.session.isStreaming {
                    ChatWindowManager.shared.createWindow(agentId: windowAgentId)
                } else {
                    ChatWindowManager.shared.openSessionInNewWindow(
                        tab?.isHibernated == true ? metadata : savedConversation(chat), agentId: windowAgentId)
                }
            },
            onOpenInNewTab: onOpenInNewTab.map { open in { open(savedConversation(chat)) } })
            .preference(key: VisibleChatOrderKey.self, value: selection == nil ? [] : [chat.id])
    }

    /// A saved chat's part in the window's selection; drafts have none.
    private func rowSelection(for chat: HistoryItem) -> SessionRowSelection? {
        guard let binding = chatSelection, chat.saved != nil else { return nil }
        return SessionRowSelection.make(
            for: chat.id, in: binding, visibleOrder: visibleChatOrder, fallbackAnchor: activeSessionId,
            sessions: conversations.sessions, scope: alertScope)
    }

    /// The one sidebar row that reads as current.
    enum NavigatorHighlight: Equatable {
        case allChats
        /// The `New chat` row of this local agent.
        case newChat(UUID)
        /// A chat row, by its list id (session id, else tab id).
        case chat(UUID)
        case none
    }

    /// Pure rule (testable): All chats while the page is on screen, else
    /// the `New chat` row of the agent whose untouched chat is on screen,
    /// else the chat on screen. Agent rows are never highlighted.
    nonisolated static func highlightedRow(
        showingAllChats: Bool, activeChatId: UUID?, untouchedChatAgentId: UUID?
    ) -> NavigatorHighlight {
        if showingAllChats { return .allChats }
        if let untouchedChatAgentId { return .newChat(untouchedChatAgentId) }
        return activeChatId.map(NavigatorHighlight.chat) ?? .none
    }

    /// What clicking an agent row does.
    enum AgentRowClick: Equatable {
        /// Fold it; nothing on screen changes.
        case close
        /// Unfold it and show its new chat.
        case openToNewChat
    }

    nonisolated static func agentRowClick(isOpen: Bool) -> AgentRowClick {
        isOpen ? .close : .openToNewChat
    }

    private var navigatorHighlight: NavigatorHighlight {
        let activeTab = openChats.first { $0.id == activeOpenTabId }
        var untouchedAgentId: UUID?
        if let activeTab, Self.isUntouchedChat(activeTab),
            !(activeTab.session.projectId.map(existingProjectIds.contains) ?? false),
            case .local(let id) = ChatTabScope.of(activeTab.session)
        {
            untouchedAgentId = id
        }
        return Self.highlightedRow(
            showingAllChats: isShowingAllChats,
            activeChatId: activeSessionId ?? activeOpenTabId,
            untouchedChatAgentId: untouchedAgentId)
    }

    /// Pure rule (testable): the selectable rows' ids as reported top to
    /// bottom, each once. Rows of folded groups never render, so they
    /// never report.
    nonisolated static func visibleChatOrder(_ reported: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return reported.filter { seen.insert($0).inserted }
    }

    private func savedConversation(_ chat: HistoryItem) -> ChatSessionData {
        if let live = openChats.first(where: { $0.id == chat.openTabId })?.session {
            if live.sessionId == nil { live.sessionId = chat.id }
            let full = live.toSessionData()
            conversations.save(full)
            return full
        }
        return ChatSessionStore.load(id: chat.id) ?? chat.saved!
    }

    private struct HistoryItem: Identifiable {
        let id: UUID
        let title: String
        let updatedAt: Date
        let saved: ChatSessionData?
        let openTabId: UUID?
        let isSelected: Bool
        /// The agent the chat runs on; project rows show its avatar.
        let agentId: UUID
    }

    /// Projects that exist on this Mac. A chat tagged with any other id
    /// (deleted here, or synced from a Mac that has the project) stays
    /// under its agent.
    private var existingProjectIds: Set<UUID> {
        Set(projectManager.projects.map(\.id))
    }

    /// An agent's chats: disk history merged with live drafts, so removing
    /// tabs cannot hide an unsent chat. Pinned chats live in the Pinned
    /// group and project chats under their project, not under the agent.
    private func historyItems(for agentId: UUID) -> [HistoryItem] {
        let projectIds = existingProjectIds
        let served = servedWorkspaceIds(for: agentId)
        let saved = Self.agentHistorySessions(
            conversations.sessions, agentId: agentId,
            keepingArchived: Set(activityMonitor.statuses.keys), excludingProjects: projectIds,
            excludingServedIn: served)
        let live = openChats.filter {
            $0.kind == .chat && !$0.session.pinned && ChatTabScope.of($0.session) == .local(agentId)
                && !($0.session.projectId.map(projectIds.contains) ?? false)
                && !($0.session.workspaceContext.map { $0.isServedForTeammate && served.contains($0.workspaceId) } ?? false)
        }
        return mergedHistory(saved: saved, live: live, underAgent: true)
    }

    /// A project's chats, from every local agent, merged the same way.
    private func projectHistoryItems(for projectId: UUID) -> [HistoryItem] {
        let saved = Self.projectHistorySessions(
            conversations.sessions, projectId: projectId, keepingArchived: Set(activityMonitor.statuses.keys))
        let live = openChats.filter { tab in
            guard tab.kind == .chat, !tab.session.pinned, tab.session.projectId == projectId else { return false }
            if case .local = ChatTabScope.of(tab.session) { return true }
            return false
        }
        return mergedHistory(saved: saved, live: live)
    }

    static func isUntouchedChat(_ tab: ChatTab) -> Bool {
        let session = tab.session
        return tab.kind == .chat && !tab.isHibernated && session.sessionId == nil && session.turns.isEmpty
            && !session.isStreaming && session.awaitingClarify == nil
    }

    /// Pure rule (testable): whether a live tab gets its own row. An
    /// untouched chat under an agent is that agent's `New chat` row; in a
    /// project or workspace list, which has no such row, it is listed only
    /// while it is the chat on screen. Any chat with a message is listed.
    nonisolated static func listsLiveChat(isUntouched: Bool, isOnScreen: Bool, underAgent: Bool) -> Bool {
        guard isUntouched else { return true }
        return !underAgent && isOnScreen
    }

    private func mergedHistory(saved: [ChatSessionData], live: [ChatTab], underAgent: Bool = false) -> [HistoryItem] {
        let activeIds = Set(activityMonitor.statuses.keys)
        let highlight = navigatorHighlight
        var items = saved.map { data in
            let tab = live.first { $0.session.sessionId == data.id }
            return HistoryItem(id: data.id, title: data.title, updatedAt: data.updatedAt,
                saved: data, openTabId: tab?.id, isSelected: highlight == .chat(data.id),
                agentId: data.agentId ?? Agent.defaultId)
        }
        let savedIds = Set(saved.map(\.id))
        for tab in live where tab.session.sessionId.map({ !savedIds.contains($0) }) ?? true {
            guard Self.listsLiveChat(
                isUntouched: Self.isUntouchedChat(tab), isOnScreen: tab.id == activeOpenTabId, underAgent: underAgent)
            else { continue }
            // Archived sessions stay out of the recent list even if still
            // alive in memory, unless a run is live on them.
            if let id = tab.session.sessionId,
                conversations.sessions.contains(where: {
                    $0.id == id && (($0.archived && !activeIds.contains(id)) || $0.pinned)
                })
            { continue }
            let id = tab.session.sessionId ?? tab.id
            items.append(HistoryItem(id: id, title: tab.session.title,
                updatedAt: tab.session.updatedAt, saved: nil, openTabId: tab.id,
                isSelected: highlight == .chat(id), agentId: tab.session.agentId ?? Agent.defaultId))
        }
        return items.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
    }

    // MARK: - Pinned

    /// Pinned chats across local agents and workspaces, newest first, each
    /// with the agent its row shows: a local agent, or a teammate's.
    private var pinnedItems: [(item: HistoryItem, agent: Agent?, shared: SharedAgentIdentity?)] {
        let highlight = navigatorHighlight
        return Self.pinnedSessions(
            conversations.sessions, keepingArchived: Set(activityMonitor.statuses.keys))
            .compactMap { data in
                let tab = openChats.first { $0.kind == .chat && $0.session.sessionId == data.id }
                let item = HistoryItem(
                    id: data.id, title: data.title, updatedAt: data.updatedAt,
                    saved: data, openTabId: tab?.id, isSelected: highlight == .chat(data.id),
                    agentId: data.agentId ?? Agent.defaultId)
                if data.isWorkspaceAgentChat, let context = data.workspace {
                    let shared = SharedAgentIdentity.resolve(
                        address: context.agentAddress.lowercased(), workspaceId: context.workspaceId)
                    return (item, nil, shared)
                }
                guard let agent = agentManager.agent(for: data.agentId ?? Agent.defaultId) else { return nil }
                return (item, agent, nil)
            }
    }

    /// Saved chats listed under a local agent: its own, minus pinned (the
    /// Pinned group shows those), team-agent chats, chats in one of
    /// `excludingProjects` (their project lists them), chats it served for
    /// teammates in one of `excludingServedIn` (its row in that workspace
    /// lists them) and archived ones (All chats lists those). Archived
    /// chats in `keepingArchived` (live runs) stay listed regardless.
    nonisolated static func agentHistorySessions(
        _ sessions: [ChatSessionData], agentId: UUID,
        keepingArchived: Set<UUID> = [], excludingProjects: Set<UUID> = [],
        excludingServedIn servedWorkspaceIds: Set<String> = []
    ) -> [ChatSessionData] {
        sessions.filter {
            (!$0.archived || keepingArchived.contains($0.id))
                && !$0.pinned && !$0.isWorkspaceAgentChat
                && ($0.agentId ?? Agent.defaultId) == agentId
                && !($0.projectId.map(excludingProjects.contains) ?? false)
                && !($0.workspace.map { $0.isServedForTeammate && servedWorkspaceIds.contains($0.workspaceId) } ?? false)
        }
    }

    /// Saved chats listed under a project: its members from any local
    /// agent, with the same pinned, team-agent and archived rules as
    /// `agentHistorySessions`.
    nonisolated static func projectHistorySessions(
        _ sessions: [ChatSessionData], projectId: UUID,
        keepingArchived: Set<UUID> = []
    ) -> [ChatSessionData] {
        sessions.filter {
            (!$0.archived || keepingArchived.contains($0.id))
                && !$0.pinned && !$0.isWorkspaceAgentChat
                && $0.projectId == projectId
        }
    }

    /// The Pinned group's chats: pinned chats of any agent, local or a
    /// teammate's, newest first; archived ones only when listed in
    /// `keepingArchived` (live runs).
    nonisolated static func pinnedSessions(
        _ sessions: [ChatSessionData], keepingArchived: Set<UUID> = []
    ) -> [ChatSessionData] {
        sessions
            .filter { $0.pinned && (!$0.archived || keepingArchived.contains($0.id)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Pinned chats after the search, by title.
    private var filteredPinnedItems: [(item: HistoryItem, agent: Agent?, shared: SharedAgentIdentity?)] {
        Self.filterByName(pinnedItems, query: navigatorQuery, name: \.item.title)
    }

    /// The Pinned group: shown once a chat is pinned, between the
    /// Orchestrator (always first, never in a group) and Agents. Its rows carry their agent's avatar, since they come from
    /// several agents. A search opens it on its matches.
    @ViewBuilder
    private var pinnedSection: some View {
        let pinned = filteredPinnedItems
        if !pinned.isEmpty {
            let collapsed = pinnedCollapsed && !isFilteringNavigator
            NavigatorGroupHeader(
                title: L("Pinned"),
                isCollapsed: collapsed,
                isToggleEnabled: !isFilteringNavigator,
                help: collapsed ? L("Show pinned chats") : L("Hide pinned chats"),
                activityStatus: collapsed
                    ? SessionActivityMonitor.rollUp(pinned.compactMap { activityMonitor.statuses[$0.item.id] })
                    : nil,
                onToggle: { withAnimation(theme.motion.quick) { pinnedCollapsed.toggle() } }
            )
            .padding(.top, theme.space.s14)
            if !collapsed {
                ForEach(pinned, id: \.item.id) { entry in
                    navigatorConversationRow(
                        entry.item, agent: entry.agent, showsAgentAvatar: true, sharedAvatar: entry.shared)
                }
            }
        }
    }

    // MARK: - Projects

    /// Projects, sorted by name as in Settings → Projects, after the search.
    private var filteredProjects: [Project] {
        projectManager.projects
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .filter { project in
                Self.navigatorShowsAgent(
                    name: project.name,
                    chatTitles: isFilteringNavigator ? projectHistoryItems(for: project.id).map(\.title) : [],
                    query: navigatorQuery
                )
            }
    }

    /// One group per project below Agents, in the Agents header's anatomy:
    /// the name folds its chats open or closed, + starts a New Chat in it,
    /// and the hover gear opens its page in Settings → Projects, where
    /// projects are created and edited.
    @ViewBuilder
    private func projectSection(_ project: Project) -> some View {
        let collapsed = isProjectCollapsed(project)
        NavigatorGroupHeader(
            title: project.name,
            isCollapsed: collapsed,
            isToggleEnabled: !isFilteringNavigator,
            help: collapsed ? L("Expand chats") : L("Collapse chats"),
            activityStatus: collapsed ? projectActivityStatus(project) : nil,
            onToggle: { withAnimation(theme.motion.quick) { toggleProjectCollapsed(project) } }
        ) { isHovered in
            SettingsIconButton("gearshape", help: "Project settings", size: .extraSmall, role: .tertiary) {
                ProjectsSettingsLink.open(projectId: project.id)
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            if let start = onNewChatInProject {
                SettingsIconButton("plus", help: "New Chat", size: .extraSmall, role: .tertiary) {
                    start(project)
                }
            }
        }
        .assignedContextMenu {
            if let start = onNewChatInProject {
                Button { start(project) } label: {
                    Label(LCached("New Chat"), systemImage: "plus.bubble")
                }
            }
            Button { ProjectsSettingsLink.open(projectId: project.id) } label: {
                Label(LCached("Open Settings"), systemImage: "gearshape")
            }
        }
        .padding(.top, theme.space.s14)
        if !collapsed {
            let recent = navigatorProjectChats(for: project)
            let count = visibleChatCounts[project.id] ?? 5
            let visible = Self.navigatorVisibleChats(recent, cap: count, activeIds: Set(activityMonitor.statuses.keys))
            ForEach(visible) { chat in
                if let agent = agentManager.agent(for: chat.agentId) {
                    navigatorConversationRow(chat, agent: agent, showsAgentAvatar: true)
                }
            }
            if recent.count > visible.count {
                Button { visibleChatCounts[project.id] = count + 5 } label: {
                    Text("Show more", bundle: .module)
                        .textStyle(.label)
                        .foregroundStyle(theme.text.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, NavigatorRowMetrics.textLeading)
                        .frame(height: NavigatorRowMetrics.rowHeight)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    /// Projects start open, like Agents; a search opens every match.
    private func isProjectCollapsed(_ project: Project) -> Bool {
        !isFilteringNavigator && collapsedProjectIds.contains(project.id)
    }

    private var collapsedProjectIds: Set<UUID> {
        Set(collapsedProjectsStorage.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private func toggleProjectCollapsed(_ project: Project) {
        var ids = collapsedProjectIds.intersection(existingProjectIds)
        if ids.remove(project.id) == nil {
            ids.insert(project.id)
            visibleChatCounts.removeValue(forKey: project.id)
        }
        collapsedProjectsStorage = ids.map(\.uuidString).sorted().joined(separator: ",")
    }

    /// A search matching the project's name lists all its chats; otherwise
    /// only the chats whose titles match.
    private func navigatorProjectChats(for project: Project) -> [HistoryItem] {
        let chats = projectHistoryItems(for: project.id)
        if Self.filterByName([project], query: navigatorQuery, name: \.name).isEmpty == false { return chats }
        return Self.filterByName(chats, query: navigatorQuery, name: \.title)
    }

    private func projectActivityStatus(_ project: Project) -> SessionActivityMonitor.Status? {
        SessionActivityMonitor.rollUp(projectHistoryItems(for: project.id).compactMap { activityMonitor.statuses[$0.id] })
    }

    // MARK: - Footer

    /// Settings at the foot of the rail, in the row anatomy: the glyph sits
    /// in the 26pt avatar column so the label lines up with the row titles
    /// above, and a hairline separates it from the list.
    private var sidebarFooter: some View {
        VStack(spacing: theme.space.s0) {
            ThemeHairlineDivider().padding(.horizontal, theme.space.s12)
            SidebarFooterRow(icon: "gearshape", title: "Settings") {
                AppDelegate.shared?.showManagementWindow(initialTab: nil)
            }
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s8)
        }
    }

    // MARK: - Header and search rows

    /// The Agents group header: fold toggle, the list-level ⋯ on hover,
    /// and + for a new agent.
    private var sidebarHeader: some View {
        let collapsed = agentsCollapsed && !isFilteringNavigator
        return NavigatorGroupHeader(
            title: L("Agents"),
            isCollapsed: collapsed,
            isToggleEnabled: !isFilteringNavigator,
            help: collapsed ? L("Show agents") : L("Hide agents"),
            activityStatus: collapsed
                ? SessionActivityMonitor.rollUp(filteredLocalAgents.compactMap { activityStatus(for: $0) })
                : nil,
            onToggle: { withAnimation(theme.motion.quick) { agentsCollapsed.toggle() } }
        ) { isHovered in
            agentsHeaderMenu
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            SettingsIconButton("plus", help: "New Agent", size: .extraSmall, role: .tertiary) {
                AgentCreatorLauncher.open(source: .sidebar)
            }
        }
    }

    /// The Agents header's ⋯: the same hover-only trigger and plain-text
    /// menu as a chat row's, for the list-level actions.
    @ViewBuilder
    private var agentsHeaderMenu: some View {
        let size = theme.assignedMetric(SettingsButtonSize.extraSmall.assignment("height"), fallback: theme.space.s24)
        AssignedActionMenu(accessibilityLabel: L("More actions"), appearance: .chatContext) {
            agentsHeaderMenuItems
        } label: {
            Image(systemName: "ellipsis")
        }
        .buttonStyle(ConversationEllipsisStyle())
        .frame(width: size, height: size)
        .help(Text("More actions", bundle: .module))
    }

    @ViewBuilder
    private var agentsHeaderMenuItems: some View {
        Button {
            AgentCreatorLauncher.open(source: .sidebar)
        } label: {
            Label {
                Text("New Agent…", bundle: .module)
            } icon: {
                Image(systemName: "plus")
            }
        }
        Button {
            ConversationImportRequest.present(agentId: agentId, scope: alertScope, onOpen: onSelect)
        } label: {
            Label {
                Text("Import Conversations…", bundle: .module)
            } icon: {
                Image(systemName: "square.and.arrow.down")
            }
        }
        if let chatSelection {
            Button {
                chatSelection.wrappedValue.requestMode()
            } label: {
                Label {
                    Text("Select chats", bundle: .module)
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
            }
        }
        if let onShowAllChats {
            Button {
                onShowAllChats(AllChatsRequest(filter: .archived))
            } label: {
                Label {
                    Text("Archived chats", bundle: .module)
                } icon: {
                    Image(systemName: "archivebox")
                }
            }
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
        let hosted = visibleHostedAgents.reduce(0) { $0 + $1.agents.count }
        return local + teammates + orphaned + directlySharedAgents.count + hosted
    }

    /// Row 3: search, same field and insets as the History pane's.
    private var navigatorSearchRow: some View {
        SearchField(
            text: $navigatorSearchText,
            placeholder: "Search agents and chats",
            fillsAvailableWidth: true,
            onFocusChange: { isNavigatorSearchFocused = $0 }
        )
        .task(id: navigatorSearchText) {
            let text = navigatorSearchText
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                try? await Task.sleep(for: SearchDebounce.interval)
                guard !Task.isCancelled else { return }
            }
            if navigatorQuery != text { navigatorQuery = text }
        }
        .frame(minHeight: 32)
        .padding(.horizontal, theme.space.s16)
        .padding(.bottom, theme.space.s16)
    }

    // MARK: - Agent List

    /// Whether any row in any section survives the current query.
    private var hasAgentMatches: Bool {
        if !filteredLocalAgents.isEmpty || !directlySharedAgents.isEmpty || !visibleHostedAgents.isEmpty
            || !filteredProjects.isEmpty
        {
            return true
        }
        if let orchestrator = agentManager.agent(for: Agent.defaultId), navigatorShows(orchestrator) { return true }
        if rosterStore.rosters.contains(where: { !shownWorkspaceMembers($0).isEmpty }) { return true }
        return orphanedWorkspacePairings.values.contains { !$0.isEmpty }
    }

    /// Local agents after the query (drag order is only live unfiltered).
    private var filteredLocalAgents: [Agent] {
        displayedAgents.filter { $0.id != Agent.defaultId && $0.id != Agent.architectId && navigatorShows($0) }
    }

    // MARK: On My Other Macs

    /// Each other Mac's agents after the query; Macs left with none drop out.
    private var visibleHostedAgents: [SyncAgentDirectory.Host] {
        guard onSelectHostedAgent != nil else { return [] }
        return agentDirectory.hosts.compactMap { host in
            let agents = Self.filterByName(host.agents, query: navigatorQuery, name: \.name)
            guard !agents.isEmpty else { return nil }
            return SyncAgentDirectory.Host(device: host.device, name: host.name, agents: agents)
        }
    }

    @ViewBuilder
    private func hostedAgentsSection(_ host: SyncAgentDirectory.Host) -> some View {
        let key = "host:\(host.device)"
        let collapsed = isSharedGroupCollapsed(key)
        VStack(alignment: .leading, spacing: theme.space.s2) {
            NavigatorGroupHeader(
                title: String(format: L("On %@"), host.name),
                isCollapsed: collapsed,
                isToggleEnabled: !isFilteringNavigator,
                help: String(format: L("Your agents on %@. They run there, with its tools and files."), host.name),
                onToggle: { withAnimation(theme.motion.quick) { toggleSharedGroupCollapsed(key) } }
            )
            .padding(.top, theme.space.s14)

            if !collapsed { ForEach(host.agents, id: \.id) { entry in
                let agentId = UUID(uuidString: entry.id)
                HostedAgentSidebarRow(
                    entry: entry,
                    hostName: host.name,
                    isOnline: hostedRunMonitor.isConnected(host.device),
                    isSelected: !isShowingAllChats
                        && (activeHostedAgent.map { $0.device == host.device && $0.agentId == agentId } ?? false),
                    onSelect: {
                        guard let agentId else { return }
                        onSelectHostedAgent?(host.device, agentId)
                    }
                )
            } }
        }
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
        let collapsed = isSharedGroupCollapsed("shared")
        VStack(alignment: .leading, spacing: theme.space.s2) {
            NavigatorGroupHeader(
                title: L("Shared with you"),
                isCollapsed: collapsed,
                isToggleEnabled: !isFilteringNavigator,
                help: L("Agents shared with you directly, outside any workspace"),
                activityStatus: collapsed
                    ? SessionActivityMonitor.rollUp(agents.compactMap {
                        activityStatus(forRemoteAgentAddress: $0.agentAddress.lowercased(), workspaceId: "")
                    })
                    : nil,
                onToggle: { withAnimation(theme.motion.quick) { toggleSharedGroupCollapsed("shared") } }
            )
            .padding(.top, theme.space.s14)

            if !collapsed { ForEach(agents) { remote in
                let address = remote.agentAddress.lowercased()
                RemoteAgentSidebarRow(
                    agent: remote,
                    status: directShareStatus(remote),
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
            } }
        }
    }

    private func directShareStatus(_ remote: RemoteAgent) -> SharedAgentStatus {
        _ = remoteProviderManager.providerStates
        return SharedAgentStatus.forDirectShareRow(remote)
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
        // Snapshot once per body pass: the getter regroups every remote
        // agent, so re-reading it per workspace stalls the main thread.
        let orphaned = orphanedWorkspacePairings
        let workspaceNames = Dictionary(
            workspacesService.workspaces.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        ForEach(rosterStore.rosters) { roster in
            // While searching, a workspace with no matching member has no
            // reason to show its header.
            if !isFilteringNavigator || !shownWorkspaceMembers(roster).isEmpty {
                workspaceSection(roster)
            }
        }
        // Orphaned workspace pairings (no loaded roster): one section each,
        // named after the workspace when Settings knows it.
        ForEach(orphaned.keys.sorted(), id: \.self) { workspaceId in
            let pairings = orphaned[workspaceId] ?? []
            let name = workspaceNames[workspaceId]
            let collapsed = isWorkspaceCollapsed(workspaceId)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                workspaceGroupHeader(
                    workspaceId: workspaceId,
                    name: name ?? L("Workspace"),
                    collapsed: collapsed,
                    activity: collapsed
                        ? SessionActivityMonitor.rollUp(pairings.compactMap {
                            activityStatus(forRemoteAgentAddress: $0.agentAddress.lowercased(), workspaceId: workspaceId)
                        })
                        : nil,
                    roster: nil
                )
                if !collapsed, !routerOn, !isFilteringNavigator {
                    workspaceStateRow(
                        icon: "bolt.slash.fill",
                        text: L("Osaurus Router is off — shared agents can't be reached."),
                        actionTitle: L("Turn on"),
                        action: { remoteProviderManager.setOsaurusRouterEnabled(true) }
                    )
                }
                if !collapsed { ForEach(pairings) { remote in
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
                } }
            }
        }
        // Section-level states when there is no roster to show (explainers
        // are not search results, so they step aside while filtering).
        if isFilteringNavigator {
            EmptyView()
        } else if rosterStore.rosters.isEmpty {
            if !routerOn, !workspacesService.workspaces.isEmpty || !orphaned.isEmpty {
                // Router off but Settings knows workspaces: explain once
                // (orphan sections above already carry the row).
                if orphaned.isEmpty {
                    VStack(alignment: .leading, spacing: theme.space.s2) {
                        Self.workspacesStateHeader(theme: theme)
                        workspaceStateRow(
                            icon: "bolt.slash.fill",
                            text: L("Osaurus Router is off — shared agents can't be reached."),
                            actionTitle: L("Turn on"),
                            action: { remoteProviderManager.setOsaurusRouterEnabled(true) }
                        )
                    }
                }
            } else if routerOn, rosterStore.isLoading {
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Self.workspacesStateHeader(theme: theme)
                    HStack(spacing: theme.space.s8) {
                        SettingsSpinner(size: .mini)
                        Text("Loading workspaces…", bundle: .module)
                            .textStyle(.footnote)
                            .foregroundColor(theme.text.tertiary)
                    }
                    .padding(.horizontal, theme.space.s10)
                    .padding(.vertical, theme.space.s8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if routerOn, let error = rosterStore.lastError {
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Self.workspacesStateHeader(theme: theme)
                    workspaceStateRow(
                        icon: "exclamationmark.triangle.fill",
                        text: error,
                        tint: theme.status.warning.foreground,
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
                tint: theme.status.warning.foreground,
                actionTitle: L("Retry"),
                action: { Task { await rosterStore.refresh(reason: .manual) } }
            )
            .padding(.top, theme.space.s6)
        }
    }

    /// "Workspaces", over the loading / error / Router-off explainers that
    /// stand in for the groups. It keeps the group anatomy but has nothing
    /// to fold.
    private static func workspacesStateHeader(theme: any ThemeProtocol) -> some View {
        NavigatorGroupHeader(
            title: L("Workspaces"),
            isCollapsed: false,
            isToggleEnabled: false,
            help: L("Workspaces"),
            onToggle: {}
        )
        .padding(.top, theme.space.s14)
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
        Self.renderWorkspaceState(icon: icon, text: text, tint: tint, actionTitle: actionTitle, action: action,
            theme: theme.catalogFamily(42))
    }

    private static func renderWorkspaceState(icon: String, text: String, tint: Color? = nil,
        actionTitle: String? = nil, action: (() -> Void)? = nil, theme: any ThemeProtocol) -> some View {
        HStack(alignment: .top, spacing: theme.catalogLayoutMetric("component.library.42.elements.layout.chatSessionSidebar.content.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(42, "gap", theme.space.s8, theme))) {
            Image(systemName: icon)
                .glyphSize(.micro, weight: .semibold)
                .foregroundColor(tint ?? theme.text.tertiary)
                .frame(width: 14)
                .padding(.top, theme.space.s2)
            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.42.elements.layout.chatSessionSidebar.content.verticalGap", inheriting: NativeComponentInspectionStyle.metric(42, "gap", theme.space.s2, theme))) {
                Text(text)
                    .componentInspectionText(42, role: .bodySmall, fallback: .footnote, theme: theme)
                    .foregroundColor(tint == nil ? theme.text.tertiary : theme.text.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(action: action) {
                        Text(actionTitle)
                            .componentInspectionText(42, role: .label, fallback: .footnote, weight: 600, theme: theme)
                            .foregroundColor(theme.text.link)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }.catalogLayoutTarget("component.library.42.elements.layout.chatSessionSidebar.content.verticalGap")
            .frame(maxWidth: .infinity, alignment: .leading)
        }.catalogLayoutTarget("component.library.42.elements.layout.chatSessionSidebar.content.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.42.elements.layout.chatSessionSidebar.content.paddingX", inheriting: NativeComponentInspectionStyle.metric(42, "padding", theme.space.s10, theme))).catalogLayoutTarget("component.library.42.elements.layout.chatSessionSidebar.content.paddingX")
        .padding(.vertical, theme.catalogLayoutMetric("component.library.42.elements.layout.chatSessionSidebar.content.paddingY", inheriting: NativeComponentInspectionStyle.metric(42, "padding", theme.space.s8, theme))).catalogLayoutTarget("component.library.42.elements.layout.chatSessionSidebar.content.paddingY")
    }

    @ViewBuilder
    private func workspaceSection(_ roster: WorkspaceRosterStore.WorkspaceRoster) -> some View {
        let workspace = roster.workspace
        let members = shownWorkspaceMembers(roster)
        let collapsed = isWorkspaceCollapsed(workspace.id)
        workspaceGroupHeader(
            workspaceId: workspace.id,
            name: workspace.name,
            collapsed: collapsed,
            activity: collapsed ? workspaceActivityStatus(roster) : nil,
            roster: roster
        )
        if !collapsed {
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
                    workspaceMemberSection(agent, in: workspace)
                }
            }
        }
    }

    /// One shared agent and, folded open, the chats this user has in the
    /// workspace with it: their own chats with a teammate's agent, or the
    /// chats teammates started with one of the user's agents.
    @ViewBuilder
    private func workspaceMemberSection(
        _ agent: OsaurusRouterWorkspaceAgent, in workspace: OsaurusRouterWorkspaceSummary
    ) -> some View {
        let address = agent.agentAddress.lowercased()
        let identity = SharedAgentIdentity.resolve(address: address, workspaceId: workspace.id)
        let key = Self.workspaceRowKey(workspaceId: workspace.id, address: address)
        let chats = workspaceMemberChats(identity, workspaceId: workspace.id)
        let expanded = isWorkspaceMemberExpanded(key, identity: identity, workspaceId: workspace.id, chats: chats)
        let activity = SessionActivityMonitor.rollUp(chats.compactMap { activityMonitor.statuses[$0.id] })
        let toggle = {
            newAgentHighlight.markSeen(sharedAgentAddress: address)
            let wasExpanded = expanded
            workspaceAgentExpansion[key] = !wasExpanded
            if wasExpanded { visibleWorkspaceChatCounts.removeValue(forKey: key) }
        }
        if let mine = identity.localAgent {
            WorkspaceAgentSidebarRow(
                identity: identity,
                workspaceId: workspace.id,
                status: ownAgentStatus(mine),
                isSelected: false,
                isExpanded: expanded,
                activityStatus: activity,
                onSelect: toggle,
                onOpenSettings: {
                    AppDelegate.shared?.showManagementWindow(initialTab: .agents, deeplinkAgentId: mine.id)
                },
                onOpenWorkspace: { openWorkspaceInSettings(id: workspace.id) },
                onUnshare: { unshare(identity, from: workspace) },
                onTurnOnRelay: { RemoteAccessConsent.request(for: mine, scope: alertScope) }
            )
        } else {
            WorkspaceAgentSidebarRow(
                identity: identity,
                workspaceId: workspace.id,
                status: teammateAgentStatus(address: address, workspaceId: workspace.id),
                // Folded, the row stands in for its open chat.
                isSelected: !expanded && isWorkspaceRowSelected(address: address, workspaceId: workspace.id),
                isExpanded: expanded,
                activityStatus: activity,
                isNew: newAgentHighlight.isNew(sharedAgentAddress: address),
                onSelect: toggle,
                onNewChat: { startWorkspaceChat(address: address, workspaceId: workspace.id) },
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
        if expanded {
            let listed = isFilteringNavigator && !workspaceNameMatches(workspace.name)
                ? Self.filterByName(chats, query: navigatorQuery, name: \.title)
                : chats
            let count = visibleWorkspaceChatCounts[key] ?? 5
            let visible = Self.navigatorVisibleChats(listed, cap: count, activeIds: Set(activityMonitor.statuses.keys))
            if listed.isEmpty {
                Text(identity.localAgent == nil ? L("No chats yet") : L("No teammate chats yet"))
                    .textStyle(.label)
                    .foregroundStyle(theme.text.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, NavigatorRowMetrics.textLeading)
                    .frame(height: NavigatorRowMetrics.rowHeight)
            }
            ForEach(visible) { chat in
                navigatorConversationRow(chat, agent: identity.localAgent, workspaceRowKey: key)
            }
            if listed.count > visible.count {
                Button { visibleWorkspaceChatCounts[key] = count + 5 } label: {
                    Text("Show more", bundle: .module)
                        .textStyle(.label)
                        .foregroundStyle(theme.text.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, NavigatorRowMetrics.textLeading)
                        .frame(height: NavigatorRowMetrics.rowHeight)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    /// The workspace's group header, in the Projects header's anatomy: the
    /// name folds the group, the hover gear opens it in Settings, + starts
    /// a chat with one of its teammates' agents.
    private func workspaceGroupHeader(
        workspaceId: String,
        name: String,
        collapsed: Bool,
        activity: SessionActivityMonitor.Status?,
        roster: WorkspaceRosterStore.WorkspaceRoster?
    ) -> some View {
        let teammates = roster.map(chattableTeammates) ?? []
        let canShare = roster?.workspace.typedRole?.canShareAgents ?? false
        return NavigatorGroupHeader(
            title: name,
            isCollapsed: collapsed,
            isToggleEnabled: !isFilteringNavigator,
            help: collapsed ? L("Show workspace") : L("Hide workspace"),
            activityStatus: activity,
            onToggle: { withAnimation(theme.motion.quick) { toggleWorkspaceCollapsed(workspaceId) } }
        ) { isHovered in
            SettingsIconButton("gearshape", help: "Workspace settings", size: .extraSmall, role: .tertiary) {
                workspacesService.openInSettings(workspaceId: workspaceId)
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            if !teammates.isEmpty || canShare {
                workspaceNewChatMenu(workspaceId: workspaceId, teammates: teammates, canShare: canShare)
            }
        }
        .assignedContextMenu {
            if !teammates.isEmpty {
                Menu {
                    ForEach(teammates, id: \.address) { identity in
                        Button(identity.name) { startWorkspaceChat(address: identity.address, workspaceId: workspaceId) }
                    }
                } label: {
                    Label(L("New Chat with"), systemImage: "plus.bubble")
                }
            }
            Button { workspacesService.openInSettings(workspaceId: workspaceId) } label: {
                Label(L("Open Workspace"), systemImage: "rectangle.3.group")
            }
            Button { workspacesService.openInSettings(workspaceId: workspaceId, tab: .members) } label: {
                Label(L("Members"), systemImage: "person.2")
            }
            Button { workspacesService.openInSettings(workspaceId: workspaceId, tab: .sharedAgents) } label: {
                Label(L("Shared Agents"), systemImage: "person.crop.square")
            }
            Button { openWorkspaceWorkflows(workspaceId: workspaceId) } label: {
                Label(L("Workflows"), systemImage: "point.3.connected.trianglepath.dotted")
            }
        }
        .padding(.top, theme.space.s14)
    }

    /// The header's +: the same hover-free trigger and plain-text menu as
    /// the Agents header's ⋯.
    @ViewBuilder
    private func workspaceNewChatMenu(
        workspaceId: String, teammates: [SharedAgentIdentity], canShare: Bool
    ) -> some View {
        let size = theme.assignedMetric(SettingsButtonSize.extraSmall.assignment("height"), fallback: theme.space.s24)
        AssignedActionMenu(accessibilityLabel: L("New Chat"), appearance: .chatContext) {
            workspaceNewChatItems(workspaceId: workspaceId, teammates: teammates, canShare: canShare)
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(ConversationEllipsisStyle())
        .frame(width: size, height: size)
        .help(Text("New Chat", bundle: .module))
    }

    @ViewBuilder
    private func workspaceNewChatItems(
        workspaceId: String, teammates: [SharedAgentIdentity], canShare: Bool
    ) -> some View {
        ForEach(teammates, id: \.address) { identity in
            Button { startWorkspaceChat(address: identity.address, workspaceId: workspaceId) } label: {
                Label(String(format: L("New Chat with %@"), identity.name), systemImage: "plus.bubble")
            }
        }
        if canShare {
            if !teammates.isEmpty { Divider() }
            Button { openWorkspaceInSettings(id: workspaceId) } label: {
                Label(L("Share an Agent…"), systemImage: "person.2.fill")
            }
        }
    }

    /// Teammates' agents the user can start a chat with right now.
    private func chattableTeammates(_ roster: WorkspaceRosterStore.WorkspaceRoster) -> [SharedAgentIdentity] {
        roster.agents.compactMap { member in
            let address = member.agentAddress.lowercased()
            let identity = SharedAgentIdentity.resolve(address: address, workspaceId: roster.workspace.id)
            guard identity.localAgent == nil else { return nil }
            switch teammateAgentStatus(address: address, workspaceId: roster.workspace.id) {
            case .offline, .unavailable, .accessRevoked, .readOnlyTeammate: return nil
            case .ready, .checking, .connecting, .notConnected: return identity
            }
        }
    }

    private func startWorkspaceChat(address: String, workspaceId: String) {
        newAgentHighlight.markSeen(sharedAgentAddress: address)
        workspaceAgentExpansion[Self.workspaceRowKey(workspaceId: workspaceId, address: address)] = true
        onSelectWorkspaceAgent?(address, workspaceId)
    }

    private func openWorkspaceWorkflows(workspaceId: String) {
        ChatWindowManager.shared.showWorkflowsSurface(destination: .workspace(workspaceId))
    }

    /// A folded workspace's header rolls up every chat it hides.
    private func workspaceActivityStatus(_ roster: WorkspaceRosterStore.WorkspaceRoster) -> SessionActivityMonitor.Status? {
        let statuses = activityMonitor.statuses
        guard !statuses.isEmpty else { return nil }
        return SessionActivityMonitor.rollUp(
            roster.agents.flatMap { member in
                workspaceMemberChats(
                    SharedAgentIdentity.resolve(address: member.agentAddress.lowercased(), workspaceId: roster.workspace.id),
                    workspaceId: roster.workspace.id
                )
            }
            .compactMap { statuses[$0.id] }
        )
    }

    /// The chats listed under a workspace's agent row.
    private func workspaceMemberChats(_ identity: SharedAgentIdentity, workspaceId: String) -> [HistoryItem] {
        if let mine = identity.localAgent {
            return servedHistoryItems(agentId: mine.id, workspaceId: workspaceId)
        }
        return workspaceHistoryItems(address: identity.address, workspaceId: workspaceId)
    }

    /// The user's chats with a teammate's agent in one workspace.
    private func workspaceHistoryItems(address: String, workspaceId: String) -> [HistoryItem] {
        let saved = Self.workspaceAgentSessions(
            conversations.sessions, address: address, workspaceId: workspaceId,
            keepingArchived: Set(activityMonitor.statuses.keys))
        let live = openChats.filter {
            $0.kind == .chat && !$0.session.pinned
                && ChatTabScope.of($0.session) == .workspace(address, workspaceId: workspaceId)
        }
        return mergedHistory(saved: saved, live: live)
    }

    /// Chats teammates started with one of the user's agents in one
    /// workspace, as this Mac served them.
    private func servedHistoryItems(agentId: UUID, workspaceId: String) -> [HistoryItem] {
        let saved = Self.servedSessions(
            conversations.sessions, agentId: agentId, workspaceId: workspaceId,
            keepingArchived: Set(activityMonitor.statuses.keys))
        let live = openChats.filter { tab in
            guard tab.kind == .chat, !tab.session.pinned, let context = tab.session.workspaceContext else { return false }
            return context.isServedForTeammate && context.workspaceId == workspaceId
                && (tab.session.agentId ?? Agent.defaultId) == agentId
        }
        return mergedHistory(saved: saved, live: live)
    }

    /// Saved chats under a teammate's agent row: the user's own chats with
    /// it in that workspace, minus pinned (the Pinned group shows those)
    /// and archived ones. Archived chats in `keepingArchived` (live runs)
    /// stay listed regardless.
    nonisolated static func workspaceAgentSessions(
        _ sessions: [ChatSessionData], address: String, workspaceId: String,
        keepingArchived: Set<UUID> = []
    ) -> [ChatSessionData] {
        let address = address.lowercased()
        return sessions.filter { session in
            guard session.isWorkspaceAgentChat, let context = session.workspace,
                context.agentAddress.lowercased() == address, context.workspaceId == workspaceId
            else { return false }
            return !session.pinned
                && (!session.archived || keepingArchived.contains(session.id))
        }
    }

    /// Saved chats under the user's own agent's row in a workspace: the
    /// ones it served for teammates there, with the same pinned and
    /// archived rules.
    nonisolated static func servedSessions(
        _ sessions: [ChatSessionData], agentId: UUID, workspaceId: String,
        keepingArchived: Set<UUID> = []
    ) -> [ChatSessionData] {
        sessions.filter { session in
            guard let context = session.workspace, context.isServedForTeammate,
                !workspaceId.isEmpty, context.workspaceId == workspaceId,
                (session.agentId ?? Agent.defaultId) == agentId
            else { return false }
            return !session.pinned
                && (!session.archived || keepingArchived.contains(session.id))
        }
    }

    /// Workspaces where one of the user's agents has a row, so the chats
    /// teammates started there list under that row instead of under Agents.
    private func servedWorkspaceIds(for agentId: UUID) -> Set<String> {
        guard let address = agentManager.agent(for: agentId)?.agentAddress?.lowercased() else { return [] }
        return Set(rosterStore.rosters.filter { roster in
            roster.agents.contains { $0.agentAddress.lowercased() == address }
        }.map(\.id))
    }

    /// A search matching the workspace's name lists every agent; otherwise
    /// the agents whose names or chats match.
    private func shownWorkspaceMembers(_ roster: WorkspaceRosterStore.WorkspaceRoster) -> [OsaurusRouterWorkspaceAgent] {
        guard isFilteringNavigator else { return roster.agents }
        return roster.agents.filter { member in
            let identity = SharedAgentIdentity.resolve(
                address: member.agentAddress.lowercased(), workspaceId: roster.workspace.id)
            return Self.workspaceListsMember(
                workspaceName: roster.workspace.name,
                agentName: identity.name,
                chatTitles: workspaceMemberChats(identity, workspaceId: roster.workspace.id).map(\.title),
                query: navigatorQuery
            )
        }
    }

    /// Pure rule (testable): under a query, a workspace agent stays listed
    /// when the workspace's name, its own name or one of its chats' titles
    /// matches.
    nonisolated static func workspaceListsMember(
        workspaceName: String, agentName: String, chatTitles: [String], query: String
    ) -> Bool {
        navigatorShowsAgent(name: workspaceName, chatTitles: [], query: query)
            || navigatorShowsAgent(name: agentName, chatTitles: chatTitles, query: query)
    }

    private func workspaceNameMatches(_ name: String) -> Bool {
        !Self.filterByName([name], query: navigatorQuery, name: { $0 }).isEmpty
    }

    /// While searching, a row opens on its matching chats; otherwise the
    /// user's choice holds (default: open on the active tab's agent).
    private func isWorkspaceMemberExpanded(
        _ key: String, identity: SharedAgentIdentity, workspaceId: String, chats: [HistoryItem]
    ) -> Bool {
        if isFilteringNavigator {
            return !Self.filterByName(chats, query: navigatorQuery, name: \.title).isEmpty
        }
        if let choice = workspaceAgentExpansion[key] { return choice }
        return identity.localAgent == nil && isWorkspaceRowSelected(address: identity.address, workspaceId: workspaceId)
    }

    nonisolated static func workspaceRowKey(workspaceId: String, address: String) -> String {
        "\(workspaceId)|\(address.lowercased())"
    }

    /// Workspaces start open, like projects; a search opens every match.
    private func isWorkspaceCollapsed(_ workspaceId: String) -> Bool {
        !isFilteringNavigator && Self.groupKeys(collapsedWorkspacesStorage).contains(workspaceId)
    }

    private func toggleWorkspaceCollapsed(_ workspaceId: String) {
        let known = Set(rosterStore.rosters.map(\.id))
            .union(workspacesService.workspaces.map(\.id))
            .union(remoteAgentManager.remoteAgents.compactMap(\.workspaceId))
        collapsedWorkspacesStorage = Self.toggling(workspaceId, in: collapsedWorkspacesStorage, keeping: known)
    }

    /// "On <Mac>", "Shared with you" and the Workspaces explainer fold the
    /// same way, each under its own key.
    private func isSharedGroupCollapsed(_ key: String) -> Bool {
        !isFilteringNavigator && Self.groupKeys(collapsedSharedGroupsStorage).contains(key)
    }

    private func toggleSharedGroupCollapsed(_ key: String) {
        collapsedSharedGroupsStorage = Self.toggling(key, in: collapsedSharedGroupsStorage)
    }

    nonisolated static func groupKeys(_ storage: String) -> Set<String> {
        Set(storage.split(separator: ",").map(String.init))
    }

    /// Pure rule (testable): `storage` with `key` folded or unfolded, and
    /// keys outside `keeping` (groups that no longer exist) dropped.
    nonisolated static func toggling(_ key: String, in storage: String, keeping: Set<String>? = nil) -> String {
        var keys = groupKeys(storage)
        if let keeping { keys.formIntersection(keeping.union([key])) }
        if keys.remove(key) == nil { keys.insert(key) }
        return keys.sorted().joined(separator: ",")
    }

    /// Only the row whose workspace matches the active tab's stamped
    /// workspace highlights when an agent is shared into several.
    private func isWorkspaceRowSelected(address: String, workspaceId: String) -> Bool {
        guard !isShowingAllChats, workspaceAgentAddress == address else { return false }
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
        return SessionActivityMonitor.rollUp(
            ChatSessionsManager.shared.sessions(forRemoteAgentAddress: address).lazy
                .filter { $0.workspace?.workspaceId == workspaceId }
                .compactMap { statuses[$0.id] }
        )
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
        withAnimation(theme.motion.springAnimation(responseMultiplier: 0.8)) {
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
        let helper: SessionActivityMonitor.Status? = mirrorTask(for: agent) != nil ? .working : nil
        let statuses = activityMonitor.statuses
        guard !statuses.isEmpty else { return helper }
        // Chats with a teammate's shared agent roll up to that agent's row,
        // not to the local agent whose tab hosted them.
        let sessions = ChatSessionsManager.shared.sessions.lazy
            .filter { !$0.isWorkspaceAgentChat && ($0.agentId ?? Agent.defaultId) == agent.id }
            .compactMap { statuses[$0.id] }
        return SessionActivityMonitor.rollUp(sessions + [helper].compactMap { $0 })
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

/// One grid for the navigator's rows, so agent rows, their chats, group
/// headers and Show more line up: every row is 32 tall, content starts 8
/// in, a 24-point icon column (an avatar, or empty under an agent), then
/// the text 8 after it.
enum NavigatorRowMetrics {
    static let rowHeight: CGFloat = 32
    static let leadingInset: CGFloat = 8
    static let iconColumn: CGFloat = 24
    static let iconGap: CGFloat = 8
    static let textLeading: CGFloat = leadingInset + iconColumn + iconGap
    static let trailingInset: CGFloat = 8
}

/// A navigator row that opens a page: glyph in the icon column, a title,
/// and an optional count where a chat row shows its age, or a trailing
/// accessory (a status chip, an external-link arrow) in the same place.
/// Every sidebar's one-line destinations use it.
struct NavigatorLinkRow<Trailing: View>: View {
    let icon: String
    let title: String
    var count: Int?
    var isSelected = false
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    init(
        icon: String, title: String, count: Int? = nil, isSelected: Bool = false,
        action: @escaping () -> Void, @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.count = count
        self.isSelected = isSelected
        self.action = action
        self.trailing = trailing
    }

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.space.s0) {
                Image(systemName: icon)
                    .glyphSize(.footnote)
                    .foregroundStyle(isSelected ? theme.text.primary : theme.text.secondary)
                    .frame(width: NavigatorRowMetrics.iconColumn)
                    .padding(.leading, NavigatorRowMetrics.leadingInset)
                    .padding(.trailing, NavigatorRowMetrics.iconGap)
                Text(verbatim: title)
                    .textStyle(.label)
                    .foregroundStyle(isSelected ? theme.text.primary : theme.text.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let count {
                    Text(verbatim: "\(count)")
                        .textStyle(.caption)
                        .monospacedDigit()
                        .foregroundStyle(theme.text.tertiary)
                        .padding(.trailing, NavigatorRowMetrics.trailingInset)
                } else {
                    trailing()
                        .padding(.trailing, NavigatorRowMetrics.trailingInset)
                }
            }
            .frame(height: NavigatorRowMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidebarRowChrome(isSelected: isSelected, isHovered: isHovered, compactChatStyle: true)
        .onHover { isHovered = $0 }
        .help(Text(verbatim: title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension NavigatorLinkRow where Trailing == EmptyView {
    init(icon: String, title: String, count: Int? = nil, isSelected: Bool = false, action: @escaping () -> Void) {
        self.init(icon: icon, title: title, count: count, isSelected: isSelected, action: action) { EmptyView() }
    }
}

/// A collapsible group's header ("Pinned", "Agents"): the whole row is the
/// toggle, with optional actions on the trailing end that keep their own
/// clicks. The Workflows sidebar's sections use it too.
struct NavigatorGroupHeader<Trailing: View>: View {
    let title: String
    let isCollapsed: Bool
    var isToggleEnabled: Bool = true
    let help: String
    /// Rolled-up live activity of the rows a collapsed group hides; nil
    /// while expanded, since the rows show their own.
    var activityStatus: SessionActivityMonitor.Status?
    let onToggle: () -> Void
    /// Trailing actions, told whether the header is hovered so hover-only
    /// ones can reveal themselves.
    @ViewBuilder var trailing: (Bool) -> Trailing

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    init(
        title: String, isCollapsed: Bool, isToggleEnabled: Bool = true, help: String,
        activityStatus: SessionActivityMonitor.Status? = nil,
        onToggle: @escaping () -> Void,
        @ViewBuilder trailing: @escaping (Bool) -> Trailing = { _ in EmptyView() }
    ) {
        self.title = title
        self.isCollapsed = isCollapsed
        self.isToggleEnabled = isToggleEnabled
        self.help = help
        self.activityStatus = activityStatus
        self.onToggle = onToggle
        self.trailing = trailing
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onToggle) {
                HStack(spacing: theme.space.s4) {
                    Text(verbatim: title)
                        .textStyle(.caption)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .glyphSize(.tiny, weight: .semibold)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    if let activityStatus {
                        NavigatorActivityIndicator(status: activityStatus)
                            .padding(.leading, theme.space.s4)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.6)))
                    }
                    Spacer(minLength: 0)
                }
                .animation(theme.motion.springAnimation(responseMultiplier: 0.8), value: activityStatus)
                .foregroundStyle(isHovered && isToggleEnabled ? theme.text.secondary : theme.text.tertiary)
                .padding(.horizontal, NavigatorRowMetrics.leadingInset)
                .frame(maxWidth: .infinity, minHeight: NavigatorRowMetrics.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isToggleEnabled)
            .help(help)
            .accessibilityValue(isCollapsed ? Text("Collapsed", bundle: .module) : Text("Expanded", bundle: .module))
            HStack(spacing: theme.space.s4) { trailing(isHovered) }
                .padding(.trailing, max(0, NavigatorRowMetrics.trailingInset - trailingGlyphInset))
        }
        .onHover { isHovered = $0 }
    }

    /// The trailing actions are extra-small icon buttons whose glyph sits
    /// inside a padded square; pulling them out by that padding puts the
    /// glyph, not the button's empty edge, on the column the rows' ages end on.
    private var trailingGlyphInset: CGFloat {
        theme.assignedMetric(
            SettingsButtonSize.extraSmall.assignment("paddingX"),
            fallback: SettingsButtonSize.extraSmall.horizontalPadding(theme))
    }
}

/// Row in the agents-focused sidebar: avatar, name, and one hover-only ⋯
/// holding the agent's actions (Stop while a run is live). Never
/// highlighted: its `New chat` row or a chat row is.
private struct AgentSidebarRow: View {
    let agent: Agent
    var isExpanded: Bool = false
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
    /// Rename in place (custom agents only).
    var onRename: ((String) -> Void)? = nil
    /// Ask to delete the agent (custom agents only).
    var onDelete: (() -> Void)? = nil
    /// The All chats page filtered to this agent.
    var onShowAllChats: (() -> Void)? = nil
    /// The same page with every one of the agent's chats selected.
    var onSelectChats: (() -> Void)? = nil
    /// Drag-to-reorder (custom agents only; built-ins are pinned to the
    /// top). The list owns the state; the row just reports translation.
    var isReorderable: Bool = false
    var isDragging: Bool = false
    var dragOffset: CGFloat = 0
    var onDragChanged: ((CGFloat) -> Void)? = nil
    var onDragEnded: (() -> Void)? = nil

    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(41, enabled: componentEnabled) }
    @State private var isHovered = false
    @State private var hoverControlsWidth: CGFloat = 0
    @State private var isRenaming = false
    @State private var renameText = ""
    @FocusState private var isRenameFocused: Bool

    /// Stop while a run is live on this agent, otherwise the ⋯ menu. Always
    /// laid out and revealed on hover, so showing it never changes the
    /// row's layout.
    @ViewBuilder private var hoverControls: some View {
        if activityStatus != nil, let onStop {
            SessionStopButton(action: onStop)
        } else {
            let size = environmentTheme.assignedMetric(
                SettingsButtonSize.extraSmall.assignment("height"), fallback: environmentTheme.space.s24)
            AssignedActionMenu(accessibilityLabel: L("More actions"), appearance: .chatContext) {
                agentContextMenu
            } label: {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(ConversationEllipsisStyle())
            .frame(width: size, height: size)
            .help(Text("More actions", bundle: .module))
        }
    }

    private var renameField: some View {
        TextField(text: $renameText, prompt: Text("Name", bundle: .module)) {
            Text("Name", bundle: .module)
        }
        .textFieldStyle(.plain)
        .textStyle(.label, weight: 500)
        .foregroundStyle(environmentTheme.text.primary)
        .focused($isRenameFocused)
        .onSubmit(commitRename)
        .onExitCommand { isRenaming = false }
        .onChange(of: isRenameFocused) { _, focused in
            if !focused, isRenaming { commitRename() }
        }
        .onAppear {
            // After the menu that started the rename has closed, or AppKit
            // hands first responder back to the previous field.
            DispatchQueue.main.async { isRenameFocused = true }
        }
    }

    /// Return commits; an empty or unchanged name cancels.
    private func commitRename() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        isRenaming = false
        guard !name.isEmpty, name != agent.name else { return }
        onRename?(name)
    }

    var body: some View {
        HStack(spacing: theme.space.s8) {
            AgentAvatarView(
                mascotId: agent.avatar,
                name: agent.displayName,
                tint: theme.dataInk(seed: agent.name),
                diameter: 24,
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
            .animation(theme.motion.springAnimation(responseMultiplier: 0.8), value: activityStatus)

            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.41.elements.layout.agentSidebarRow.body.verticalGap", inheriting: NativeComponentInspectionStyle.metric(41, "gap", theme.space.s2, theme))) {
                // Baseline-aligned so the Orchestrator star sits on the
                // name's line like an inline glyph, not on the row's center.
                HStack(alignment: .firstTextBaseline, spacing: theme.catalogLayoutMetric("component.library.41.elements.layout.agentSidebarRow.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(41, "gap", theme.space.s4, theme))) {
                    if isRenaming {
                        renameField
                    } else {
                        Text(agent.displayName)
                            .componentInspectionText(41, role: .label, fallback: .caption, weight: 500, theme: theme)
                            .foregroundColor(theme.text.primary)
                            .lineLimit(1)
                    }
                    if agent.id == Agent.defaultId {
                        Image(systemName: "star.circle")
                            .componentInspectionText(41, role: .label, fallback: .label, theme: theme)
                            .foregroundColor(theme.text.secondary)
                            .accessibilityHidden(true)
                    }
                    if !sharedWorkspaceNames.isEmpty {
                        Image(systemName: "person.2.fill")
                            .glyphSize(.tiny, weight: .semibold)
                            .foregroundColor(theme.text.secondary)
                            .help(
                                String(
                                    format: L("Shared with %@"),
                                    sharedWorkspaceNames.joined(separator: ", ")
                                )
                            )
                            .accessibilityLabel(Text("Shared with workspace", bundle: .module))
                    }

                }.catalogLayoutTarget("component.library.41.elements.layout.agentSidebarRow.body.horizontalGap")
                .frame(maxWidth: .infinity, alignment: .leading)


            }.catalogLayoutTarget("component.library.41.elements.layout.agentSidebarRow.body.verticalGap")
            .frame(maxWidth: .infinity, alignment: .leading)
            // The name runs under the hover controls and fades out there
            // instead of re-truncating, so hovering never shifts the row.
            .mask(alignment: .leading) {
                HStack(spacing: theme.space.s0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: isHovered ? theme.space.s12 : 0)
                    Color.clear.frame(width: isHovered ? hoverControlsWidth : 0)
                }
            }
        }
        .overlay(alignment: .trailing) {
            hoverControls
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { hoverControlsWidth = $0 }
                .opacity(isHovered && !isRenaming ? 1 : 0)
                .allowsHitTesting(isHovered && !isRenaming)
        }
        .padding(.leading, NavigatorRowMetrics.leadingInset)
        .padding(.trailing, NavigatorRowMetrics.trailingInset)
        .frame(height: NavigatorRowMetrics.rowHeight)
        .sidebarRowChrome(isSelected: false, isHovered: isHovered, compactChatStyle: true)
        .help(
            activityStatus.map { liveStatusLine($0) }
                ?? agent.teammate.map { "\(agent.displayName) · \($0.role)" }
                ?? agent.displayName
        )
        .contentShape(RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous))
        .offset(y: dragOffset)
        .zIndex(isDragging ? 1 : 0)
        .onTapGesture { if !isRenaming { onSelect() } }
        .accessibilityAction(named: Text(isExpanded ? "Collapse chats" : "Expand chats"), onSelect)
        .assignedContextMenu { agentContextMenu }
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
            // Hover reveals controls; it must not animate the row's geometry.
            isHovered = hovering
        }
    }

    /// Where this agent is configured: a user agent's detail page under
    /// Settings → Agents, Settings → Architect for the Architect, or
    /// Settings → Orchestrator for the built-in
    /// Osaurus agent (which has no Agents row). Shared by the hover gear and
    /// the context menu so both land in the same place.
    private func openAgentSettings() {
        if agent.id == Agent.architectId {
            AppDelegate.shared?.showManagementWindow(initialTab: .architect)
        } else if agent.isBuiltIn {
            AppDelegate.shared?.showManagementWindow(initialTab: .orchestrator)
        } else {
            AppDelegate.shared?.showManagementWindow(initialTab: .agents, deeplinkAgentId: agent.id)
        }
    }

    /// The ⋯ and right-click menu: New Chat, Open Settings, the agent's
    /// chats, Rename, the share/unshare actions that otherwise live only
    /// in Settings, and Delete Agent… last.
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
        if onRename != nil {
            Button {
                renameText = agent.name
                isRenaming = true
            } label: {
                Label(LCached("Rename"), systemImage: "pencil")
            }
        }
        if let onShowAllChats {
            Button(action: onShowAllChats) {
                Label(L("All chats with \(agent.displayName)"), systemImage: "clock")
            }
        }
        if let onSelectChats {
            Button(action: onSelectChats) {
                Label(LCached("Select chats"), systemImage: "checkmark.circle")
            }
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
        if let onDelete {
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label(LCached("Delete Agent…"), systemImage: "trash")
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
    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(41, enabled: componentEnabled) }

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .stroke(isNew ? theme.border.focus : Color.clear, lineWidth: theme.stroke.focus)
                    .allowsHitTesting(false)
            )
            .animation(theme.motion.slow, value: isNew)
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
    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(41, enabled: componentEnabled) }

    var body: some View {
        Text("New", bundle: .module)
            .componentInspectionText(41, role: .caption, fallback: .micro, weight: 700, theme: theme)
            .textCase(.uppercase)
            .foregroundColor(theme.status.info.foreground)
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.41.elements.layout.newAgentPill.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(41, "padding", theme.space.s4, theme))).catalogLayoutTarget("component.library.41.elements.layout.newAgentPill.body.paddingX")
            .padding(.vertical, theme.space.s2)
            .background(Capsule().fill(theme.status.info.background))
            .accessibilityLabel(Text("New Agent", bundle: .module))
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
    /// Its chats in this workspace are listed under it.
    var isExpanded: Bool = false
    var activityStatus: SessionActivityMonitor.Status? = nil
    /// Appeared on the roster during this app run and not opened yet.
    var isNew: Bool = false
    /// Folds the row's chats open or closed; browsing never starts a chat.
    let onSelect: () -> Void
    /// Teammate agent: start a chat with it (hover + and Chat in the menu).
    var onNewChat: (() -> Void)?
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

    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(41, enabled: componentEnabled) }
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
        HStack(spacing: NavigatorRowMetrics.iconGap) {
            AgentAvatarView(
                mascotId: identity.avatar,
                name: identity.name,
                tint: theme.dataInk(seed: identity.localAgent?.name ?? identity.name),
                diameter: NavigatorRowMetrics.iconColumn,
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
                    .padding(theme.space.s2)
                    .background(Circle().fill(theme.surface.sidebar))
                    .offset(x: 2, y: 2)
                    .help(isMine ? ownPresenceHelp : status.shortLabel)
            }
            .opacity(isOffline ? 0.7 : 1)
            .animation(theme.motion.springAnimation(responseMultiplier: 0.8), value: activityStatus)

            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.41.elements.layout.workspaceAgentSidebarRow.body.verticalGap", inheriting: NativeComponentInspectionStyle.metric(41, "gap", theme.space.s2, theme))) {
                HStack(spacing: theme.catalogLayoutMetric("component.library.41.elements.layout.workspaceAgentSidebarRow.body.horizontalGap2", inheriting: NativeComponentInspectionStyle.metric(41, "gap", theme.space.s4, theme))) {
                    Text(identity.name)
                        .componentInspectionText(41, role: .label, fallback: .caption, weight: 500, theme: theme)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                    if isNew {
                        NewAgentPill()
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }.catalogLayoutTarget("component.library.41.elements.layout.workspaceAgentSidebarRow.body.horizontalGap2")
                .frame(maxWidth: .infinity, alignment: .leading)

                subtitle
                    .componentInspectionText(41, role: .caption, fallback: .micro, theme: theme)
                    .lineLimit(1)
            }.catalogLayoutTarget("component.library.41.elements.layout.workspaceAgentSidebarRow.body.verticalGap")
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isOffline ? 0.6 : 1)

            // Hover-only gear: own agent → its Agents detail; teammate agent →
            // Settings ▸ Workspaces on this workspace (the roster owns
            // connect / unshare; the chat only consumes).
            if isHovered {
                HStack(spacing: theme.space.s4) {
                    if let onNewChat {
                        SettingsIconButton(
                            "square.and.pencil", help: "New Chat", size: .extraSmall, role: .tertiary,
                            glyphNudge: CGSize(width: 0, height: -0.75), action: onNewChat)
                    }
                    if let open = isMine ? onOpenSettings : onOpenWorkspace {
                        SettingsIconButton(
                            "gearshape", help: isMine ? "Agent Settings" : "Open Workspace", size: .extraSmall,
                            role: .tertiary, action: open)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.leading, NavigatorRowMetrics.leadingInset)
        .padding(.trailing, NavigatorRowMetrics.trailingInset)
        .padding(.vertical, theme.space.s4)
        .frame(minHeight: NavigatorRowMetrics.rowHeight)
        .sidebarRowChrome(isSelected: isSelected, isHovered: isHovered)
        .newAgentHighlight(isNew)
        .contentShape(RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous))
        .onTapGesture(perform: onSelect)
        .accessibilityAction(
            named: Text(verbatim: isExpanded ? L("Hide workspace chats") : L("Show workspace chats")), onSelect)
        .assignedContextMenu { contextMenuItems }
        .onHover { hovering in
            withAnimation(theme.motion.springAnimation(responseMultiplier: 0.8)) {
                isHovered = hovering
            }
        }
        .animation(theme.motion.springAnimation(responseMultiplier: 0.8), value: isSelected)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(identity.name), \(accessibilityStatus)"))
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if let onNewChat {
            Button(action: onNewChat) {
                Label(L("Chat"), systemImage: "bubble.left")
            }
        }
        if isMine, let onOpenSettings {
            Button(action: onOpenSettings) {
                Label(L("Open Settings"), systemImage: "gearshape")
            }
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
                Label(L("Turn On Remote Access"), systemImage: "antenna.radiowaves.left.and.right")
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
                .foregroundColor(theme.text.secondary)
        case .checking, .connecting:
            Text(verbatim: isMine ? L("Remote access connecting…") : status.shortLabel)
                .foregroundColor(theme.text.secondary)
        case .notConnected(let reason, _):
            if isMine {
                Text("Remote access off — teammates can't reach it", bundle: .module)
                    .foregroundColor(theme.status.warning.foreground)
            } else if reason != nil {
                Text("Couldn't connect", bundle: .module)
                    .foregroundColor(theme.status.warning.foreground)
            } else {
                Text(verbatim: status.shortLabel)
                    .foregroundColor(theme.text.secondary)
            }
        case .unavailable:
            Text(verbatim: status.shortLabel)
                .foregroundColor(theme.text.secondary)
        case .accessRevoked:
            Text(verbatim: status.shortLabel)
                .foregroundColor(theme.status.error.foreground)
        case .ready, .readOnlyTeammate:
            Text(verbatim: isMine ? localLabel : ownerAndModelLabel)
                .foregroundColor(theme.text.secondary)
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
                : L("your agent, remote access off")
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
    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(41, enabled: componentEnabled) }
    let status: SharedAgentStatus

    var body: some View {
        Group {
            switch status {
            case .ready:
                Circle().fill(theme.status.success.foreground)
            case .checking, .connecting:
                Circle().fill(theme.status.info.foreground)
            case .notConnected(let reason, _):
                if reason == nil {
                    // The sidebar's family scope sets `stroke.default` to zero.
                    Circle().strokeBorder(theme.border.default, lineWidth: theme.unscopedTheme.stroke.default)
                } else {
                    Circle().fill(theme.status.warning.foreground)
                }
            case .accessRevoked:
                Circle().fill(theme.status.error.foreground)
            case .offline, .unavailable, .readOnlyTeammate:
                Circle().fill(theme.text.tertiary)
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
/// presence for these, so the dot reads the pairing's own connection
/// (`SharedAgentStatus.forDirectShareRow`), including a revoked guest link.
private struct RemoteAgentSidebarRow: View {
    let agent: RemoteAgent
    var status: SharedAgentStatus? = nil
    let isSelected: Bool
    var activityStatus: SessionActivityMonitor.Status? = nil
    /// Paired during this app run and not opened yet.
    var isNew: Bool = false
    let onSelect: () -> Void
    /// Direct share: forget the pairing.
    var onRemove: (() -> Void)?
    /// Workspace pairing: open its workspace in Settings.
    var onOpenWorkspace: (() -> Void)?

    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(41, enabled: componentEnabled) }
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.41.elements.layout.remoteAgentSidebarRow.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(41, "gap", theme.space.s10, theme))) {
            AgentAvatarView(
                mascotId: agent.avatar,
                name: agent.name,
                tint: theme.dataInk(seed: agent.name),
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
            .overlay(alignment: .bottomTrailing) {
                if let status {
                    SharedAgentStatusDot(status: status)
                        .padding(theme.space.s2)
                        .background(Circle().fill(theme.surface.sidebar))
                        .offset(x: 2, y: 2)
                }
            }
            .animation(theme.motion.springAnimation(responseMultiplier: 0.8), value: activityStatus)

            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.41.elements.layout.remoteAgentSidebarRow.body.verticalGap", inheriting: NativeComponentInspectionStyle.metric(41, "gap", theme.space.s2, theme))) {
                HStack(spacing: theme.catalogLayoutMetric("component.library.41.elements.layout.remoteAgentSidebarRow.body.horizontalGap2", inheriting: NativeComponentInspectionStyle.metric(41, "gap", theme.space.s4, theme))) {
                    Text(agent.name)
                        .componentInspectionText(41, role: .label, fallback: .caption, weight: 500, theme: theme)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                    if isNew {
                        NewAgentPill()
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }.catalogLayoutTarget("component.library.41.elements.layout.remoteAgentSidebarRow.body.horizontalGap2")
                .frame(maxWidth: .infinity, alignment: .leading)

                // The section header already says "Shared with you"; a row
                // with no note or model shows no subtitle, like a local
                // custom agent without a role caption.
                if let subtitleLabel {
                    Text(verbatim: subtitleLabel)
                        .componentInspectionText(41, role: .caption, fallback: .micro, theme: theme)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(1)
                }
            }.catalogLayoutTarget("component.library.41.elements.layout.remoteAgentSidebarRow.body.verticalGap")
            .frame(maxWidth: .infinity, alignment: .leading)

            // Hover-only gear → where the pairing is managed: Settings ▸
            // Agents (direct share) or Settings ▸ Workspaces (workspace).
            if isHovered {
                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                        .glyphSize(.footnote, weight: .semibold)
                        .foregroundColor(theme.text.secondary)
                        .frame(width: NativeComponentInspectionStyle.metric(41, "height", SidebarStyle.actionButtonSize, theme), height: NativeComponentInspectionStyle.metric(41, "height", SidebarStyle.actionButtonSize, theme))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(onOpenWorkspace == nil ? L("Agent Settings") : L("Open Workspace"))
                .transition(.opacity)
            }
        }.catalogLayoutTarget("component.library.41.elements.layout.remoteAgentSidebarRow.body.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.41.elements.layout.remoteAgentSidebarRow.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(41, "padding", theme.space.s10, theme))).catalogLayoutTarget("component.library.41.elements.layout.remoteAgentSidebarRow.body.paddingX")
        .padding(.vertical, theme.catalogLayoutMetric("component.library.41.elements.layout.remoteAgentSidebarRow.body.paddingY", inheriting: NativeComponentInspectionStyle.metric(41, "padding", theme.space.s8, theme))).catalogLayoutTarget("component.library.41.elements.layout.remoteAgentSidebarRow.body.paddingY")
        .frame(minHeight: NativeComponentInspectionStyle.metric(41, "height", 0, theme))
            .sidebarRowChrome(isSelected: isSelected, isHovered: isHovered)
        .newAgentHighlight(isNew)
        .contentShape(RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous))
        .onTapGesture(perform: onSelect)
        .assignedContextMenu {
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
            withAnimation(theme.motion.springAnimation(responseMultiplier: 0.8)) {
                isHovered = hovering
            }
        }
        .animation(theme.motion.springAnimation(responseMultiplier: 0.8), value: isSelected)
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

/// Row for one of the user's agents on another of their Macs, under
/// "On <Mac>". Same shape as `RemoteAgentSidebarRow`, with the Mac's
/// presence as the subtitle when it's offline.
private struct HostedAgentSidebarRow: View {
    let entry: SyncHostedRunContract.DirectoryEntry
    let hostName: String
    let isOnline: Bool
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(41, enabled: componentEnabled) }
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.41.elements.layout.discoveredAgentSidebarRow.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(41, "gap", theme.space.s10, theme))) {
            AgentAvatarView(
                mascotId: entry.avatar,
                name: entry.name,
                tint: theme.dataInk(seed: entry.name),
                diameter: 26,
                customImageURL: nil,
                monogramFontSize: 12,
                borderWidth: 0
            )
            .opacity(isOnline ? 1 : 0.6)

            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.41.elements.layout.discoveredAgentSidebarRow.body.verticalGap", inheriting: NativeComponentInspectionStyle.metric(41, "gap", theme.space.s2, theme))) {
                Text(entry.name)
                    .componentInspectionText(41, role: .label, fallback: .caption, weight: 500, theme: theme)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .componentInspectionText(41, role: .caption, fallback: .micro, theme: theme)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(1)
                }
            }.catalogLayoutTarget("component.library.41.elements.layout.discoveredAgentSidebarRow.body.verticalGap")
            .frame(maxWidth: .infinity, alignment: .leading)
        }.catalogLayoutTarget("component.library.41.elements.layout.discoveredAgentSidebarRow.body.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.41.elements.layout.discoveredAgentSidebarRow.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(41, "padding", theme.space.s10, theme))).catalogLayoutTarget("component.library.41.elements.layout.discoveredAgentSidebarRow.body.paddingX")
        .padding(.vertical, theme.catalogLayoutMetric("component.library.41.elements.layout.discoveredAgentSidebarRow.body.paddingY", inheriting: NativeComponentInspectionStyle.metric(41, "padding", theme.space.s8, theme))).catalogLayoutTarget("component.library.41.elements.layout.discoveredAgentSidebarRow.body.paddingY")
        .frame(minHeight: NativeComponentInspectionStyle.metric(41, "height", 0, theme))
            .sidebarRowChrome(isSelected: isSelected, isHovered: isHovered)
        .contentShape(RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous))
        .onTapGesture(perform: onSelect)
        .assignedContextMenu {
            Button(action: onSelect) { Label(L("Chat"), systemImage: "bubble.left") }
        }
        .onHover { hovering in
            withAnimation(theme.motion.springAnimation(responseMultiplier: 0.8)) {
                isHovered = hovering
            }
        }
        .animation(theme.motion.springAnimation(responseMultiplier: 0.8), value: isSelected)
        .help(entry.description.map { "\(entry.name)\n\($0)" } ?? entry.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(entry.name), \(String(format: L("On %@"), hostName))"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect() }
    }

    private var subtitle: String? {
        if !isOnline { return L("Offline") }
        guard let description = entry.description, !description.isEmpty else { return nil }
        return description
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

    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(42) }
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarFooterRow.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(42, "gap", theme.space.s10, theme))) {
                Image(systemName: icon)
                    .glyphSize(.label, weight: .medium)
                    .foregroundColor(theme.text.secondary)
                    .frame(width: 26, height: 26)
                Text(title, bundle: .module)
                    .componentInspectionText(42, role: .label, fallback: .caption, weight: 500, theme: theme)
                    .foregroundColor(theme.text.primary)
                Spacer(minLength: 0)
            }.catalogLayoutTarget("component.library.42.elements.layout.sidebarFooterRow.body.horizontalGap")
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarFooterRow.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(42, "padding", theme.space.s10, theme))).catalogLayoutTarget("component.library.42.elements.layout.sidebarFooterRow.body.paddingX")
            .padding(.vertical, theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarFooterRow.body.paddingY", inheriting: NativeComponentInspectionStyle.metric(42, "padding", theme.space.s6, theme))).catalogLayoutTarget("component.library.42.elements.layout.sidebarFooterRow.body.paddingY")
            .sidebarRowChrome(isSelected: false, isHovered: isHovered, family: 42)
            .contentShape(RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(theme.motion.springAnimation(responseMultiplier: 0.8)) { isHovered = hovering }
        }
        .onChange(of: controlActiveState) { _, state in
            if state != .key { isHovered = false }
        }
        .localizedHelp(title)
    }
}

// MARK: - Session Row

/// A chat row's part in the window's selection: its checkbox, its
/// modifier clicks, and the menu that acts on several chats at once.
struct SessionRowSelection {
    var isChecked: Bool
    var isModeActive: Bool
    /// Set when the row's menu acts on the selection: how many chats.
    var batchCount: Int?
    var allPinned = false
    var allArchived = false
    var onToggle: () -> Void
    var onExtend: () -> Void
    /// The row menu's Select: enters selection mode with this chat ticked.
    var onSelectThis: () -> Void
    var onBatchPin: () -> Void = {}
    var onBatchArchive: () -> Void = {}
    var onBatchDelete: () -> Void = {}

    /// Wires a row to the window's selection. `visibleOrder` is the rows on
    /// screen top to bottom (Shift-click ranges); `fallbackAnchor` is the
    /// chat on screen.
    @MainActor
    static func make(
        for id: UUID, in binding: Binding<ChatSelection>, visibleOrder: [UUID], fallbackAnchor: UUID?,
        sessions: [ChatSessionData], scope: ThemedAlertScope
    ) -> SessionRowSelection {
        let current = binding.wrappedValue
        var batchCount: Int?
        if case .batch(let count) = current.menuScope(for: id) { batchCount = count }
        let ids = current.selectedIds
        let allPinned = batchCount != nil && ChatBatchActions.allPinned(ids, in: sessions)
        let allArchived = batchCount != nil && ChatBatchActions.allArchived(ids, in: sessions)
        return SessionRowSelection(
            isChecked: current.contains(id),
            isModeActive: current.isActive,
            batchCount: batchCount,
            allPinned: allPinned,
            allArchived: allArchived,
            onToggle: { binding.wrappedValue.toggle(id) },
            onExtend: {
                binding.wrappedValue.selectRange(to: id, visibleOrder: visibleOrder, fallbackAnchor: fallbackAnchor)
            },
            onSelectThis: {
                if !binding.wrappedValue.contains(id) { binding.wrappedValue.toggle(id) }
            },
            onBatchPin: {
                ChatBatchActions.setPinned(ids, pinned: !allPinned)
                binding.wrappedValue.clear()
            },
            onBatchArchive: {
                ChatBatchActions.setArchived(ids, archived: !allArchived)
                binding.wrappedValue.clear()
            },
            onBatchDelete: {
                ChatBatchActions.requestDelete(ids, scope: scope) { binding.wrappedValue.clear() }
            }
        )
    }
}

private struct SessionRow: View {
    let session: ChatSessionData
    let agent: Agent?
    let isSelected: Bool
    /// Whether this row is part of an active multi-selection. Drives the
    /// accent background and the leading checkmark.
    var isMultiSelected: Bool = false
    /// The row's part in the window's chat selection. nil for rows that
    /// can't be selected (an unsaved draft).
    var selection: SessionRowSelection? = nil
    /// All chats rows: the first user message, under the title.
    var preview: String? = nil
    var navigatorStyle: Bool = false
    /// Navigator rows outside their agent's group (Pinned) show the agent's
    /// avatar in the icon column.
    var showsAgentAvatar: Bool = false
    /// A teammate's agent, for a pinned workspace chat's avatar.
    var sharedAvatar: SharedAgentIdentity? = nil
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
    var prepareExport: (() -> Void)? = nil
    /// Stop this row's live run. Only rendered while `activityStatus` is set.
    var onStop: (() -> Void)? = nil
    /// Optional callback for opening in a new window
    var onOpenInNewWindow: (() -> Void)? = nil
    /// Optional callback for opening in a new tab of the current window
    var onOpenInNewTab: (() -> Void)? = nil
    /// Open this chat with its File Changes inspector showing.
    var onShowFileChanges: (() -> Void)? = nil

    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(41, enabled: componentEnabled) }
    @Environment(\.themedAlertScope) private var alertScope
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var fileChanges = FileChangeSummaryStore.shared
    @State private var isHovered = false
    /// Local buffer for the rename TextField. Kept on the row (not the
    /// sidebar) so focus churn during popover dismissal cannot desync it
    /// from the focused row.
    @State private var editBuffer: String = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        if isEditing {
            editingView
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.41.elements.layout.sessionRow.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(41, "padding", theme.space.s10, theme))).catalogLayoutTarget("component.library.41.elements.layout.sessionRow.body.paddingX")
                .padding(.vertical, theme.catalogLayoutMetric("component.library.41.elements.layout.sessionRow.body.paddingY", inheriting: NativeComponentInspectionStyle.metric(41, "padding", theme.space.s8, theme))).catalogLayoutTarget("component.library.41.elements.layout.sessionRow.body.paddingY")
                .frame(minHeight: NativeComponentInspectionStyle.metric(41, "height", 0, theme))
            .sidebarRowChrome(isSelected: isSelected, isHovered: isHovered)
        } else if navigatorStyle {
            navigatorRow
        } else {
            pageRow
        }
    }

    private var navigatorActivityLine: String? {
        switch activityStatus {
        case .working: return LCached("Running…")
        case .waitingForInput: return LCached("Needs your input")
        case nil: return nil
        }
    }

    private var navigatorActivityTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.6))
    }

    private var navigatorActivityAnimation: Animation {
        environmentTheme.motion.springAnimation(responseMultiplier: 0.8)
    }

    /// An All chats row: checkbox, the agent's avatar, the title over the
    /// first message, the agent and age; the ⋯ replaces those on hover.
    private var pageRow: some View {
        let theme = environmentTheme
        let trailingControl = theme.assignedMetric(
            SettingsButtonSize.extraSmall.assignment("height"), fallback: theme.space.s24)
        let title = session.title.isEmpty ? L("New chat") : session.title
        return HStack(spacing: theme.space.s10) {
            if let selection {
                ZStack {
                    if showsCheckbox { selectionCheckbox(selection) }
                }
                .frame(width: NavigatorRowMetrics.iconColumn)
            } else if isMultiSelected {
                Image(systemName: "checkmark.circle.fill")
                    .glyphSize(.label, weight: .semibold)
                    .foregroundColor(theme.text.primary)
            }
            Group {
                if let agent {
                    agentIndicatorView(agent)
                } else {
                    defaultAgentIndicator
                }
            }
            .overlay {
                if let activityStatus { SessionActivityRing(status: activityStatus).allowsHitTesting(false) }
            }
            VStack(alignment: .leading, spacing: theme.space.s2) {
                HStack(spacing: theme.space.s4) {
                    Text(verbatim: title)
                        .textStyle(.label, weight: 500)
                        .foregroundStyle(session.archived ? theme.text.secondary : theme.text.primary)
                        .lineLimit(1)
                        .help(Text(verbatim: title))
                    if session.pinned {
                        Image(systemName: "pin.fill")
                            .glyphSize(.tiny, weight: .semibold)
                            .rotationEffect(.degrees(45))
                            .foregroundStyle(theme.text.tertiary)
                            .help(Text("Pinned", bundle: .module))
                            .accessibilityLabel(Text("Pinned", bundle: .module))
                    }
                    if session.source != .chat || isFromPairedPhone { sourceBadge }
                    if let summary = fileChanges.summary(for: session.id), summary.setCount > 0 {
                        fileChangesBadge(summary)
                    }
                    Spacer(minLength: 0)
                }
                Group {
                    switch activityStatus {
                    case .working:
                        Text("Running…", bundle: .module).foregroundStyle(theme.status.info.foreground)
                    case .waitingForInput:
                        Text("Needs your input", bundle: .module).foregroundStyle(theme.status.warning.foreground)
                    case nil:
                        Text(verbatim: preview ?? metadataLine).foregroundStyle(theme.text.secondary)
                    }
                }
                .textStyle(.caption)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if activityStatus != nil, let onStop {
                SessionStopButton(action: onStop)
            }
            ZStack(alignment: .trailing) {
                pageRowTrailingLabel
                    .opacity(showsHoverActions ? 0 : 1)
                AssignedActionMenu(accessibilityLabel: L("More actions"), appearance: .chatContext) {
                    conversationContextMenu
                } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(ConversationEllipsisStyle())
                .frame(width: trailingControl, height: trailingControl)
                .opacity(showsHoverActions ? 1 : 0)
                .allowsHitTesting(showsHoverActions)
            }
        }
        .padding(.leading, theme.space.s4)
        .padding(.trailing, theme.space.s10)
        .padding(.vertical, theme.space.s8)
        .background(checkedRowFill)
        .sidebarRowChrome(isSelected: isSelected || isMultiSelected, isHovered: isHovered, compactChatStyle: true)
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                .stroke(isImportHighlighted ? theme.border.focus : Color.clear, lineWidth: theme.stroke.focus)
                .allowsHitTesting(false)
        )
        .animation(theme.motion.slow, value: isImportHighlighted)
        .contentShape(RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous))
        .onTapGesture(perform: handleNavigatorClick)
        .onHover { isHovered = $0 }
        .assignedContextMenu(chatMenu: true) { conversationContextMenu }
        .environment(\.assignedMenuAppearance, .chatContext)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The agent and the age in two right-aligned columns, so both line up
    /// down the page.
    private var pageRowTrailingLabel: some View {
        HStack(spacing: environmentTheme.space.s12) {
            Text(verbatim: agent?.displayName ?? "")
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 104, alignment: .trailing)
            TimelineView(.everyMinute) { context in
                Text(verbatim: compactRelativeAge(session.updatedAt, now: context.date))
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: 32, alignment: .trailing)
            }
        }
        .textStyle(.caption)
        .foregroundStyle(environmentTheme.text.tertiary)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: formatRelativeDate(session.updatedAt)))
    }

    /// The checkbox takes the icon column on hover, while ticked, and for
    /// every row in selection mode.
    private var showsCheckbox: Bool {
        guard let selection else { return false }
        return isHovered || selection.isChecked || selection.isModeActive
    }

    private var showsHoverActions: Bool {
        isHovered && !(selection?.isModeActive ?? false)
    }

    /// A plain click always opens the chat; Command toggles it, Shift
    /// extends the selection to it.
    private func handleNavigatorClick() {
        guard let selection else { return onSelect() }
        let flags = NSEvent.modifierFlags
        switch ChatSelection.clickOutcome(command: flags.contains(.command), shift: flags.contains(.shift)) {
        case .open: onSelect()
        case .toggle: selection.onToggle()
        case .extendRange: selection.onExtend()
        }
    }

    private func selectionCheckbox(_ selection: SessionRowSelection) -> some View {
        let title = session.title.isEmpty ? L("New chat") : session.title
        return ChatSelectionCheckbox(
            isChecked: selection.isChecked,
            accessibilityLabel: selection.isChecked ? L("Deselect \(title)") : L("Select \(title)"),
            action: selection.onToggle
        )
        .transition(.opacity)
    }

    /// Ticked rows sit on the selected surface, a step above the hover wash
    /// that marks the chat on screen.
    @ViewBuilder private var checkedRowFill: some View {
        if selection?.isChecked == true {
            RoundedRectangle(cornerRadius: environmentTheme.radius.medium, style: .continuous)
                .fill(environmentTheme.surface.selected)
        }
    }

    private var navigatorAgeLabel: some View {
        TimelineView(.everyMinute) { context in
            Text(verbatim: compactRelativeAge(session.updatedAt, now: context.date))
                .textStyle(.caption)
                .monospacedDigit()
                .foregroundStyle(environmentTheme.text.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityHidden(true)
    }

    private var navigatorRow: some View {
        let trailingControl = environmentTheme.assignedMetric(
            SettingsButtonSize.extraSmall.assignment("height"), fallback: environmentTheme.space.s24)
        return HStack(spacing: theme.space.s0) {
            Button(action: handleNavigatorClick) {
                HStack(spacing: theme.space.s0) {
                    // A real view, so the column keeps its width when empty.
                    ZStack {
                        if showsCheckbox, let selection {
                            selectionCheckbox(selection)
                        } else if showsAgentAvatar, let sharedAvatar {
                            AgentAvatarView(
                                mascotId: sharedAvatar.avatar,
                                name: sharedAvatar.name,
                                tint: theme.dataInk(seed: sharedAvatar.localAgent?.name ?? sharedAvatar.name),
                                diameter: 18,
                                customImageURL: sharedAvatar.customAvatarURL,
                                monogramFontSize: 9,
                                borderWidth: 0
                            )
                            .overlay {
                                if let activityStatus {
                                    NavigatorActivityIndicator(status: activityStatus, ringsAvatar: true)
                                        .transition(navigatorActivityTransition)
                                }
                            }
                            .help(Text(verbatim: sharedAvatar.workspaceName.map { "\(sharedAvatar.name) · \($0)" } ?? sharedAvatar.name))
                        } else if showsAgentAvatar, let agent {
                            AgentAvatarView(
                                mascotId: agent.avatar,
                                name: agent.displayName,
                                tint: theme.dataInk(seed: agent.name),
                                diameter: 18,
                                customImageURL: agent.customAvatarURL,
                                monogramFontSize: 9,
                                borderWidth: 0
                            )
                            .overlay {
                                if let activityStatus {
                                    NavigatorActivityIndicator(status: activityStatus, ringsAvatar: true)
                                        .transition(navigatorActivityTransition)
                                }
                            }
                            .help(Text(verbatim: agent.displayName))
                        } else if let activityStatus {
                            NavigatorActivityIndicator(status: activityStatus)
                                .transition(navigatorActivityTransition)
                        }
                    }
                    .animation(navigatorActivityAnimation, value: showsCheckbox)
                    .frame(width: NavigatorRowMetrics.iconColumn)
                    .animation(navigatorActivityAnimation, value: activityStatus)
                    .padding(.leading, NavigatorRowMetrics.leadingInset)
                    .padding(.trailing, NavigatorRowMetrics.iconGap)
                    Text(session.title.isEmpty ? L("New chat") : session.title)
                        .textStyle(.label)
                        .foregroundStyle(
                            isSelected || activityStatus == .waitingForInput
                                ? environmentTheme.text.primary
                                : environmentTheme.text.secondary
                        )
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            .help(navigatorActivityLine ?? session.title)
            .accessibilityValue(Text(verbatim: [navigatorActivityLine, formatRelativeDate(session.updatedAt)]
                .compactMap { $0 }.joined(separator: ", ")))
            // The age and the ⋯ share one slot; the menu stays mounted so it
            // can present, and the age keeps its width while hidden so the
            // slot never resizes on hover. Selection mode hides the ⋯; the
            // right-click menu still opens.
            ZStack(alignment: .trailing) {
                navigatorAgeLabel
                    .opacity(showsHoverActions ? 0 : 1)
                AssignedActionMenu(accessibilityLabel: L("More actions"), appearance: .chatContext) {
                    conversationContextMenu
                } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(ConversationEllipsisStyle())
                .frame(width: trailingControl, height: trailingControl)
                .opacity(showsHoverActions ? 1 : 0)
                .allowsHitTesting(showsHoverActions)
            }
            .padding(.leading, environmentTheme.space.s4)
            .padding(.trailing, NavigatorRowMetrics.trailingInset)
        }
        .frame(height: NavigatorRowMetrics.rowHeight)
        .background(checkedRowFill)
        .sidebarRowChrome(isSelected: isSelected, isHovered: isHovered, compactChatStyle: true)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .assignedContextMenu(chatMenu: true) { conversationContextMenu }
        .environment(\.assignedMenuAppearance, .chatContext)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var conversationContextMenu: some View {
        if let selection, let count = selection.batchCount {
            batchContextMenu(selection, count: count)
        } else {
            singleContextMenu
        }
    }

    /// Opened on one of several selected rows: the menu acts on all of them.
    @ViewBuilder
    private func batchContextMenu(_ selection: SessionRowSelection, count: Int) -> some View {
        Section {
            Button(action: selection.onBatchPin) {
                Text(selection.allPinned ? "Unpin" : "Pin", bundle: .module)
            }
            Button(action: selection.onBatchArchive) {
                Text(selection.allArchived ? "Unarchive" : "Archive", bundle: .module)
            }
            Button(role: .destructive, action: selection.onBatchDelete) {
                Text(verbatim: ChatBatchActions.deleteButtonTitle(count: count))
            }
        } header: {
            Text(verbatim: L("\(count) chats selected"))
        }
    }

    @ViewBuilder private var singleContextMenu: some View {
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
                if TaskStore.shared.originSessionIds.contains(session.id) {
                    Button {
                        TaskControl.showHistory(.chat(session.id))
                    } label: {
                        Text("Tasks from This Chat", bundle: .module)
                    }
                }
                Button(action: requestExport) { Text("Export…", bundle: .module) }
                if let selection {
                    Button(action: selection.onSelectThis) { Text("Select", bundle: .module) }
                }
                Divider()
                Button(action: onToggleArchive) {
                    Text(session.archived ? "Unarchive" : "Archive", bundle: .module)
                }
                Button(role: .destructive, action: requestDelete) { Text("Delete", bundle: .module) }
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

    // MARK: - Export Format Chooser

    private func requestExport() {
        prepareExport?()
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
        if selection != nil {
            ChatBatchActions.requestDelete([session.id], scope: alertScope)
            return
        }
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

    /// File history badge: outstanding changed files (or a dimmed icon when
    /// every change was reverted). Opens the chat's File Changes inspector.
    private func fileChangesBadge(_ summary: FileChangeSessionSummary) -> some View {
        let active = summary.outstandingFiles > 0
        let color = active ? theme.text.link : theme.text.tertiary
        return Button {
            onShowFileChanges?()
        } label: {
            HStack(spacing: theme.catalogLayoutMetric("component.library.41.elements.layout.sessionRow.fileChangesBadge.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(41, "gap", theme.space.s2, theme))) {
                Image(systemName: "plus.forwardslash.minus")
                    .glyphSize(.tiny, weight: .bold)
                if active {
                    Text(verbatim: "\(summary.outstandingFiles)")
                        .componentInspectionText(41, role: .caption, fallback: .micro, monospacedDigit: true, weight: 600, theme: theme)
                }
            }.catalogLayoutTarget("component.library.41.elements.layout.sessionRow.fileChangesBadge.horizontalGap")
            .foregroundColor(color)
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.41.elements.layout.sessionRow.fileChangesBadge.paddingX", inheriting: NativeComponentInspectionStyle.metric(41, "padding", theme.space.s4, theme))).catalogLayoutTarget("component.library.41.elements.layout.sessionRow.fileChangesBadge.paddingX")
            .frame(height: 14)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.small, style: .continuous)
                    .fill(theme.wash(behind: color))
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

    // MARK: - Source Badge

    /// Compact icon-only badge that surfaces the session's `SessionSource`
    /// (plugin / http / schedule / watcher). Chat-source rows hide it.
    /// A chat from the paired iPhone: an ordinary chat the phone started, or
    /// an older `.workspace` row (from the shared-agent path), which is the
    /// owner's own chat, not a teammate's. Either is shown as the iPhone's.
    private var isFromPairedPhone: Bool {
        RemoteSessionContinuation.isFromPairedPhone(session)
    }

    private var sourceBadge: some View {
        Image(systemName: isFromPairedPhone ? "iphone" : session.runtimeSource.iconName)
            .glyphSize(.tiny, weight: .semibold)
            .foregroundColor(sourceBadgeColor)
            .frame(width: 14, height: 14)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.small, style: .continuous)
                    .fill(sourceBadgeColor.opacity(theme.isDark ? 0.16 : 0.12))
            )
            .help(sourceBadgeHelp)
    }

    /// Composes "<relative date> · via <plugin> · <key>" so the audit
    /// dimension is glanceable without expanding the row.
    private var metadataLine: String {
        var parts: [String] = [formatRelativeDate(session.updatedAt)]
        // A phone chat's key is the pairing key's nonce plus the phone's own
        // id: noise to a reader, so it names the device kind and stops there.
        if isFromPairedPhone {
            parts.append("via Mobile")
            return parts.joined(separator: " · ")
        }
        let pluginName = session.sourcePluginId.map(PluginDisplayNameResolver.displayName(for:))
        if let origin = session.runtimeSource.originLabel(pluginDisplayName: pluginName) {
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
        if !session.source.syncsAcrossDevices {
            parts.append(L("This Mac only"))
        }
        return parts.joined(separator: " · ")
    }

    private var sourceBadgeColor: Color {
        switch session.runtimeSource {
        case .chat: return theme.text.secondary
        case .plugin: return theme.text.link
        case .http: return theme.text.link
        case .channel: return theme.status.info.foreground
        case .schedule: return theme.status.warning.foreground
        case .watcher: return theme.status.success.foreground
        case .webhook, .email, .automation: return theme.text.link
        case .selfSchedule: return theme.status.warning.foreground
        case .imported: return theme.text.link
        case .delegation: return theme.status.info.foreground
        case .workspace: return theme.status.info.foreground
        }
    }

    private var sourceBadgeHelp: Text {
        switch session.runtimeSource {
        case .chat:
            if isFromPairedPhone {
                return Text("Mobile", bundle: .module)
            }
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
        case .webhook:
            return Text("Webhook", bundle: .module)
        case .email:
            return Text("Email", bundle: .module)
        case .automation:
            return Text("Automation", bundle: .module)
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
            RoundedRectangle(
                cornerRadius: AgentAvatarView.cornerRadius(side: 24, theme: environmentTheme, enabled: componentEnabled)
            )
            .fill(theme.surface.hover)
            .frame(width: 24, height: 24)

            Image(systemName: "person.fill")
                .glyphSize(.micro, weight: .medium)
                .foregroundColor(theme.text.secondary)
        }
        .localizedHelp("Default")
    }

    /// The agent's avatar as the rail draws it, so a page row and its
    /// sidebar row read as the same agent.
    @ViewBuilder
    private func agentIndicatorView(_ agent: Agent) -> some View {
        AgentAvatarView(
            mascotId: agent.avatar,
            name: agent.displayName,
            tint: theme.dataInk(seed: agent.name),
            diameter: 24,
            customImageURL: agent.customAvatarURL,
            monogramFontSize: 11,
            borderWidth: 0
        )
        .help(Text(verbatim: agent.displayName))
    }

    private var editingView: some View {
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.41.elements.layout.sessionRow.editingView.verticalGap", inheriting: NativeComponentInspectionStyle.metric(41, "gap", theme.space.s4, theme))) {
            HStack(spacing: theme.catalogLayoutMetric("component.library.41.elements.layout.sessionRow.editingView.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(41, "gap", theme.space.s6, theme))) {
                TextField(text: $editBuffer, prompt: Text("Title", bundle: .module)) {
                    Text("Title", bundle: .module)
                }
                .textFieldStyle(.plain)
                .componentInspectionText(41, role: .bodySmall, fallback: .caption, weight: 500, theme: theme)
                .foregroundColor(theme.text.primary)
                .submitLabel(.done)
                .onSubmit { onConfirmRename(editBuffer) }
                .focused($isTextFieldFocused)
                .onExitCommand(perform: onCancelRename)
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.41.elements.layout.sessionRow.editingView.paddingX", inheriting: NativeComponentInspectionStyle.metric(41, "padding", theme.space.s6, theme))).catalogLayoutTarget("component.library.41.elements.layout.sessionRow.editingView.paddingX")
                .padding(.vertical, theme.catalogLayoutMetric("component.library.41.elements.layout.sessionRow.editingView.paddingY", inheriting: NativeComponentInspectionStyle.metric(41, "padding", theme.space.s4, theme))).catalogLayoutTarget("component.library.41.elements.layout.sessionRow.editingView.paddingY")
                .background(
                    RoundedRectangle(cornerRadius: theme.radius.small, style: .continuous)
                        .fill(theme.surface.canvas)
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
            }.catalogLayoutTarget("component.library.41.elements.layout.sessionRow.editingView.horizontalGap")

            renameKeyboardHint
        }.catalogLayoutTarget("component.library.41.elements.layout.sessionRow.editingView.verticalGap")
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
        HStack(spacing: theme.catalogLayoutMetric("component.library.41.elements.layout.sessionRow.renameKeyboardHint.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(41, "gap", theme.space.s6, theme))) {
            keyHintChip(symbol: "return", label: "Save")
            Text("·")
                .componentInspectionText(41, role: .caption, fallback: .micro, theme: theme)
            keyHintChip(symbol: "escape", label: "Cancel")
        }.catalogLayoutTarget("component.library.41.elements.layout.sessionRow.renameKeyboardHint.horizontalGap")
        .foregroundColor(theme.text.secondary)
        .padding(.leading, theme.space.s6)
    }

    private func keyHintChip(symbol: String, label: String) -> some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.41.elements.layout.sessionRow.keyHintChip.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(41, "gap", theme.space.s2, theme))) {
            Image(systemName: symbol)
                .glyphSize(.tiny, weight: .semibold)
            Text(LocalizedStringKey(label), bundle: .module)
                .componentInspectionText(41, role: .caption, fallback: .micro, weight: 500, theme: theme)
        }.catalogLayoutTarget("component.library.41.elements.layout.sessionRow.keyHintChip.horizontalGap")
    }

}

// MARK: - Session Activity Ring

/// Ring drawn around a row's avatar while its run is live, in the avatar's
/// own outline (a rounded square stays a rounded square). `.working` sweeps
/// an angular gradient around the ring (a steady ring under Reduce Motion);
/// `.waitingForInput` renders a steady warning ring with a question-mark
/// badge, matching `BackgroundTaskStatus.waitingForInput`'s iconography.
struct SessionActivityRing: View {
    let status: SessionActivityMonitor.Status

    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(41, enabled: componentEnabled) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let gap: CGFloat = 3
    private static let lineWidth: CGFloat = 2
    private static let period: TimeInterval = 1.1

    var body: some View {
        AvatarActivityOutline(gap: Self.gap) { outline in
            ring(outline)
        }
    }

    @ViewBuilder
    private func ring(_ outline: RoundedRectangle) -> some View {
        switch status {
        case .working:
            if reduceMotion {
                outline.stroke(theme.status.info.foreground, lineWidth: Self.lineWidth)
            } else {
                // The gradient turns, not the shape: a rotating rounded
                // square would wobble at its corners.
                TimelineView(.animation) { context in
                    let turns = context.date.timeIntervalSinceReferenceDate / Self.period
                    let head = Angle.degrees(turns.truncatingRemainder(dividingBy: 1) * 360)
                    outline.stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                theme.status.info.background,
                                theme.status.info.foreground,
                            ]),
                            center: .center,
                            startAngle: head,
                            endAngle: head + .degrees(360)
                        ),
                        style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round)
                    )
                }
            }
        case .waitingForInput:
            outline.stroke(theme.status.warning.foreground, lineWidth: Self.lineWidth)
                .overlay(alignment: .bottomTrailing) {
                    ZStack {
                        // Mask the ring/backdrop behind the badge glyph so it
                        // stays legible at this size.
                        Circle()
                            .fill(theme.surface.canvas)
                            .frame(width: 11, height: 11)
                        Image(systemName: "questionmark.circle.fill")
                            .glyphSize(.micro, weight: .semibold)
                            .foregroundColor(theme.status.warning.foreground)
                    }
                    .offset(x: 2, y: 2)
                }
        }
    }
}

// MARK: - Avatar Activity Outline

/// Lays out a live-activity mark over an avatar (as its overlay): the
/// avatar's own outline grown by `gap` on every side, so the mark hugs a
/// rounded-square avatar the way a circle hugs a round one.
private struct AvatarActivityOutline<Content: View>: View {
    let gap: CGFloat
    @ViewBuilder let content: (RoundedRectangle) -> Content

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        GeometryReader { proxy in
            let avatarSide = min(proxy.size.width, proxy.size.height)
            let side = avatarSide + 2 * gap
            let radius = AgentAvatarView.cornerRadius(side: avatarSide, theme: theme, enabled: isEnabled) + gap
            content(RoundedRectangle(cornerRadius: radius))
                .frame(width: side, height: side)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }
}

// MARK: - Navigator Activity Indicator

/// Quiet live-run mark for compact navigator rows and collapsed group
/// headers: a short comet arc circling a faint track while the run works,
/// a warning dot when it waits on the user. `ringsAvatar` draws the same
/// states as a ring around the avatar it overlays instead.
struct NavigatorActivityIndicator: View {
    let status: SessionActivityMonitor.Status
    var ringsAvatar: Bool = false

    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(41, enabled: componentEnabled) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let diameter: CGFloat = 11
    private static let avatarGap: CGFloat = 2
    private static let lineWidth: CGFloat = 1.5
    private static let dotDiameter: CGFloat = 6

    var body: some View {
        Group {
            if ringsAvatar {
                AvatarActivityOutline(gap: Self.avatarGap) { outline in
                    mark(outline)
                }
            } else {
                mark(RoundedRectangle(cornerRadius: Self.diameter / 2))
                    .frame(width: Self.diameter, height: Self.diameter)
            }
        }
        .animation(reduceMotion ? nil : theme.motion.springAnimation(responseMultiplier: 0.8), value: status)
        .accessibilityHidden(true)
    }

    private func mark(_ outline: RoundedRectangle) -> some View {
        ZStack {
            switch status {
            case .working:
                NavigatorActivityComet(
                    color: theme.status.info.foreground,
                    outline: outline,
                    lineWidth: Self.lineWidth,
                    isStill: reduceMotion
                )
                .transition(transition)
            case .waitingForInput:
                if ringsAvatar {
                    NavigatorAttentionMark(color: theme.status.warning.foreground, ring: outline, lineWidth: Self.lineWidth)
                        .transition(transition)
                } else {
                    NavigatorAttentionMark(color: theme.status.warning.foreground)
                        .frame(width: Self.dotDiameter, height: Self.dotDiameter)
                        .transition(transition)
                }
            }
        }
    }

    private var transition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.6))
    }
}

/// Faint full track plus a ~90° arc that fades in from its tail. The angle
/// comes from the wall clock, so the spin never restarts on re-render and
/// every live row turns in phase. The gradient turns, not the outline, so a
/// rounded-square track stays put.
private struct NavigatorActivityComet: View {
    let color: Color
    let outline: RoundedRectangle
    let lineWidth: CGFloat
    let isStill: Bool

    @Environment(\.theme) private var theme

    private static let period: TimeInterval = 1.2
    private static let arcFraction: Double = 0.25

    var body: some View {
        if isStill {
            ZStack {
                track
                outline
                    .trim(from: 0, to: 0.75)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        } else {
            TimelineView(.animation) { context in
                let turns = context.date.timeIntervalSinceReferenceDate / Self.period
                let head = Angle.degrees(turns.truncatingRemainder(dividingBy: 1) * 360)
                ZStack {
                    track
                    outline.stroke(
                        AngularGradient(
                            stops: [
                                .init(color: color.opacity(0), location: 1 - Self.arcFraction),
                                .init(color: color, location: 1),
                            ],
                            center: .center,
                            startAngle: head,
                            endAngle: head + .degrees(360)
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                }
            }
        }
    }

    private var track: some View {
        outline.stroke(theme.rule(around: color), lineWidth: lineWidth)
    }
}

/// Warning dot (or ring, when `ring` is set) that settles in with one soft
/// pulse on arrival and then holds still: no looping blink.
private struct NavigatorAttentionMark: View {
    let color: Color
    var ring: RoundedRectangle? = nil
    var lineWidth: CGFloat = 1.5

    @Environment(\.theme) private var theme
    @State private var isPulsed = false

    var body: some View {
        Group {
            if let ring {
                ring.stroke(color, lineWidth: lineWidth)
            } else {
                Circle().fill(color)
            }
        }
        // A ring around an avatar is already large; it only breathes.
        .scaleEffect(isPulsed ? (ring == nil ? 1.35 : 1.1) : 1)
        .onAppear {
            guard let rise = theme.motion.timed(.easeOut, duration: 0.18),
                let settle = theme.motion.timed(.easeOut, duration: 0.32)
            else { return }
            withAnimation(rise) { isPulsed = true } completion: {
                withAnimation(settle) { isPulsed = false }
            }
        }
    }
}

// MARK: - Session Stop Button

/// Persistent (non-hover-gated) stop control for a row whose run is live.
/// Styled like `SidebarRowActionButton` but tinted with the error color on
/// hover to telegraph that it halts execution.
struct SessionStopButton: View {
    let action: () -> Void

    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(41, enabled: componentEnabled) }
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.circle.fill")
                .glyphSize(.label, weight: .semibold)
                .foregroundColor(isHovered ? theme.status.error.foreground : theme.text.secondary)
                .frame(width: SidebarStyle.actionButtonSize, height: SidebarStyle.actionButtonSize)
                .background(
                    RoundedRectangle(
                        cornerRadius: theme.radius.small, style: .continuous
                    )
                    .fill(isHovered ? theme.status.error.background : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .localizedHelp("Stop")
        .onHover { isHovered = $0 }
        .animation(theme.motion.quick, value: isHovered)
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
                .textStyle(.caption)
                .foregroundColor(theme.text.secondary)
        }
        .settingsCheckbox()
    }
}

// MARK: - Preview

#if DEBUG
    struct ChatSessionSidebar_Previews: PreviewProvider {
        static var previews: some View {
            ChatSessionSidebar(
                sessions: [],
                agentId: Agent.defaultId,
                onSelect: { _ in }
            )
            .frame(height: 400)
        }
    }
#endif

// MARK: - All chats list

/// The All chats page's rows (`AllChatsPage`): day groups of `SessionRow`s
/// with the sidebar's click rules and menus, each group with Select all.
/// Lives here because it reuses the sidebar's private row types.
struct AllChatsList: View {
    let groups: [AllChatsModel.Group]
    let hasMore: Bool
    let onLoadMore: () -> Void
    let currentSessionId: UUID?
    let selection: Binding<ChatSelection>
    /// First user message per chat, for the rows' second line.
    let previews: [UUID: String]
    let actions: ChatHistoryWindowActions
    let onSelect: (ChatSessionData) -> Void
    let onOpenInNewTab: (ChatSessionData) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.themedAlertScope) private var alertScope
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var projectManager = ProjectManager.shared
    @ObservedObject private var conversations = ChatSessionsManager.shared
    @ObservedObject private var activityMonitor = SessionActivityMonitor.shared
    @ObservedObject private var importHighlight = ChatSessionImportHighlight.shared
    @State private var editingSessionId: UUID?

    var body: some View {
        let order = groups.flatMap { $0.rows.map(\.id) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: theme.space.s2) {
                ForEach(groups) { group in
                    AllChatsGroupHeader(
                        title: AllChatsModel.title(for: group.key),
                        count: group.rows.count,
                        ids: group.rows.map(\.id),
                        selection: selection
                    )
                    ForEach(group.rows) { session in
                        row(session, order: order)
                            .id(session.id)
                    }
                }
                if hasMore {
                    SettingsSpinner()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, theme.space.s12)
                        .onAppear(perform: onLoadMore)
                }
            }
            .padding(.bottom, theme.space.s64)
        }
        .scrollIndicators(.automatic)
        .onChange(of: editingSessionId) { _, editing in
            guard case .chat(let windowId) = alertScope,
                let state = ChatWindowManager.shared.windowState(id: windowId) else { return }
            state.cancelHistoryRename = editing == nil ? nil : { editingSessionId = nil }
        }
        .onDisappear {
            guard case .chat(let windowId) = alertScope else { return }
            ChatWindowManager.shared.windowState(id: windowId)?.cancelHistoryRename = nil
        }
    }

    private func row(_ session: ChatSessionData, order: [UUID]) -> some View {
        SessionRow(
            session: session,
            agent: agentManager.agent(for: session.agentId ?? Agent.defaultId),
            isSelected: session.id == currentSessionId,
            selection: SessionRowSelection.make(
                for: session.id, in: selection, visibleOrder: order, fallbackAnchor: currentSessionId,
                sessions: conversations.sessions, scope: alertScope),
            preview: previews[session.id],
            isImportHighlighted: importHighlight.sessionIds.contains(session.id),
            activityStatus: activityMonitor.statuses[session.id],
            isEditing: editingSessionId == session.id,
            onSelect: { onSelect(session) },
            onStartRename: { editingSessionId = session.id },
            onConfirmRename: { newTitle in
                let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { actions.rename(session.id, trimmed) }
                editingSessionId = nil
            },
            onCancelRename: { editingSessionId = nil },
            onDelete: {
                editingSessionId = nil
                actions.delete(session.id)
            },
            onToggleArchive: { actions.setArchived(session.id, !session.archived) },
            onTogglePin: { actions.setPinned(session.id, !session.pinned) },
            projects: session.workspace == nil ? projectManager.projects : [],
            onSetProject: { actions.setProject(session.id, $0) },
            onExport: { actions.export(session, $0) },
            onStop: { actions.stop(session.id) },
            onOpenInNewWindow: { actions.openInNewWindow(session) },
            onOpenInNewTab: { onOpenInNewTab(session) },
            onShowFileChanges: {
                onSelect(session)
                FileChangeSummaryStore.requestPanel(sessionId: session.id.uuidString)
            }
        )
    }
}

/// A day group's header on the All chats page: its name and count, and
/// Select all / Deselect all on hover (the floating bar's Select all
/// covers the whole list).
private struct AllChatsGroupHeader: View {
    let title: String
    let count: Int
    let ids: [UUID]
    let selection: Binding<ChatSelection>
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        let current = selection.wrappedValue
        let allSelected = !ids.isEmpty && ids.allSatisfy(current.contains)
        let showsToggle = isHovered
        HStack(spacing: theme.space.s6) {
            Text(verbatim: title)
                .textStyle(.caption, weight: 600)
                .foregroundStyle(theme.text.secondary)
            Text(verbatim: "\(count)")
                .textStyle(.caption)
                .monospacedDigit()
                .foregroundStyle(theme.text.tertiary)
            Spacer(minLength: 0)
            SettingsButton(.tertiary, allSelected ? "Deselect all" : "Select all", size: .extraSmall) {
                if allSelected {
                    selection.wrappedValue.deselect(ids)
                } else {
                    selection.wrappedValue.select(ids)
                }
            }
            .opacity(showsToggle ? 1 : 0)
            .allowsHitTesting(showsToggle)
            .accessibilityHidden(!showsToggle)
        }
        .padding(.leading, theme.space.s10)
        .padding(.trailing, theme.space.s4)
        .padding(.top, theme.space.s16)
        .padding(.bottom, theme.space.s4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Row frames for the agent list's drag-to-reorder hit testing.
private struct AgentRowFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Selectable chat rows in view-tree order, which is top-to-bottom order
/// in the rail's stack.
private struct VisibleChatOrderKey: PreferenceKey {
    static let defaultValue: [UUID] = []
    static func reduce(value: inout [UUID], nextValue: () -> [UUID]) {
        value.append(contentsOf: nextValue())
    }
}

#if OSAURUS_DESIGN_INSPECTOR
/// Original conditional sidebar rows, with local display values and callbacks only.
@MainActor func inspectorSidebarSharingRow(action: @escaping (String) -> Void) -> some View {
    AgentSidebarRow(agent: Agent(name: "Local shared agent"), isSelected: false,
        sharedWorkspaceNames: ["Local existing workspace"],
        shareableWorkspaces: [.init(id: "local-new", name: "Local new workspace", role: "admin")],
        sharedWorkspaces: [.init(id: "local-existing", name: "Local existing workspace", role: "admin")],
        onShareToWorkspace: { action("Share local callback: \($0.name)") },
        onUnshareFromWorkspace: { action("Unshare local callback: \($0.name)") }, onSelect: { action("Local agent selected") })
}
struct InspectorSidebarRemainingVerification: View {
    @Environment(\.theme) private var theme
    @State private var state = "Working"
    @State private var callbacks = 0
    @Environment(\.inspectorVerificationWidth) private var width
    private var status: SessionActivityMonitor.Status? { state == "Working" ? .working : state == "Waiting" ? .waitingForInput : nil }
    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            Picker("Sidebar sample state", selection: $state) { ForEach(["Working", "Waiting", "Pinned", "Archived", "Multi-selected"], id: \.self) { Text($0) } }
            AgentSidebarRow(agent: Agent(name: "Local agent with a deliberately long descriptive name"), isSelected: state == "Multi-selected",
                activityStatus: status, activityStep: "Reading a local display sample", sharedWorkspaceNames: ["Local sample workspace"], isNew: true,
                onSelect: { callbacks += 1 })
            SessionRow(session: ChatSessionData(title: "Local history with a deliberately long descriptive title", archived: state == "Archived", pinned: state == "Pinned"),
                agent: nil, isSelected: false, isMultiSelected: state == "Multi-selected", activityStatus: status,
                isEditing: false, onSelect: { callbacks += 1 }, onStartRename: { callbacks += 1 }, onConfirmRename: { _ in callbacks += 1 },
                onCancelRename: {}, onDelete: { callbacks += 1 }, onToggleArchive: { callbacks += 1 }, onTogglePin: { callbacks += 1 }, onExport: { _ in callbacks += 1 })
        }.frame(width: min(width, 400))
    }
}
@MainActor @ViewBuilder func inspectorSidebarContextRow(_ kind: Int, hostedHere: Bool, action: @escaping (String) -> Void) -> some View {
    switch kind {
    case 1:
        WorkspaceAgentSidebarRow(identity: SharedAgentIdentity(address: "0x1111111111111111111111111111111111111111", name: "Local workspace menu", avatar: nil, customAvatarURL: nil, model: nil, ownerName: "Local sample", workspaceId: "local-menu", workspaceName: "Local sample", description: nil, isOwnedByMe: hostedHere, isHostedHere: hostedHere, localAgent: nil, paired: nil, rosterAgent: nil), workspaceId: "local-menu", status: hostedHere ? .notConnected(reason: nil, hasAttempted: true) : .ready, isSelected: false, onSelect: { action("Workspace select") }, onOpenSettings: { action("Workspace settings") }, onOpenInNewWindow: { action("Workspace window") }, onOpenWorkspace: { action("Workspace open") }, onUnshare: { action("Workspace unshare callback only") }, onTurnOnRelay: { action("Relay callback only") })
    case 2:
        RemoteAgentSidebarRow(agent: RemoteAgent(agentAddress: "0x2222222222222222222222222222222222222222", name: "Local paired menu", description: "Display only", relayBaseURL: "https://example.invalid", providerId: UUID()), isSelected: false, onSelect: { action("Paired select") }, onRemove: { action("Paired remove callback only") })
    case 3:
        HostedAgentSidebarRow(entry: SyncHostedRunContract.DirectoryEntry(id: "local-menu", address: "0x3333333333333333333333333333333333333333", name: "Local other-Mac menu", description: "Display only"), hostName: "Local sample Mac", isOnline: !hostedHere, isSelected: false, onSelect: { action("Hosted select") })
    default:
        NavigatorGroupHeader(title: "Local project menu", isCollapsed: false, help: "Collapse chats", onToggle: { action("Project toggle") }) { _ in
            SettingsIconButton("plus", help: "New Chat", size: .extraSmall, role: .tertiary) { action("Project new chat callback only") }
        }
        .assignedContextMenu {
            Button { action("Project new chat callback only") } label: { Label(LCached("New Chat"), systemImage: "plus.bubble") }
        }
    }
}
#endif

#if OSAURUS_DESIGN_INSPECTOR
extension ChatSessionSidebar {
    static func inspectionWorkspaceChrome(theme: any ThemeProtocol, action: @escaping () -> Void) -> some View {
        let theme = theme.catalogFamily(42)
        return VStack(alignment: .leading, spacing: theme.space.s8) {
            workspacesStateHeader(theme: theme)
            renderWorkspaceState(icon: "person.2.fill", text: "No shared agents yet", actionTitle: "Local action", action: action, theme: theme)
            renderWorkspaceState(icon: "exclamationmark.triangle.fill", text: "Local connection error display", tint: theme.status.error.foreground, theme: theme)
        }.environment(\.theme, theme)
    }
}
struct InspectorSidebarChromeVerification: View {
    @Environment(\.theme) private var theme
    @State private var count = 0
    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            Text("Chat sidebar · workspace section with sample data")
            ChatSessionSidebar.inspectionWorkspaceChrome(theme: theme) { count += 1 }
        }
    }
}
#endif

/// The sidebar's ⋯ triggers: the same extra-small tertiary icon button as
/// the + and gear beside them, so every hover action shares one hover
/// treatment.
private struct ConversationEllipsisStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsIconButtonStyle(size: .extraSmall, role: .tertiary)
            .makeBody(configuration: configuration)
    }
}
