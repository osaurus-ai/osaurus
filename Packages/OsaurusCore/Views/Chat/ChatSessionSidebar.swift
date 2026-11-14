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
    /// The ⋯ menu's Show Archived filter: archived chats rejoin their
    /// agent's list, marked, instead of staying hidden.
    @AppStorage("chatSidebar.showArchived") private var showArchived = false
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
    /// The other Mac and agent the active tab's chat runs on, or nil. While
    /// set, that row is the selected one (no local row is).
    var activeHostedAgent: (device: String, agentId: UUID)? = nil
    /// Chat with one of the user's agents on another of their Macs.
    var onSelectHostedAgent: ((String, UUID) -> Void)? = nil
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
                }
                .padding(.horizontal, theme.space.s16)
                .padding(.bottom, theme.space.s16)
            }
            .sidebarScrollEdgeFade()
            .coordinateSpace(name: "agentList")
            .onPreferenceChange(AgentRowFramesKey.self) { agentRowFrames = $0 }
        }
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
                        // A team-agent or network-agent tab owns the
                        // selection: no local row is highlighted while one
                        // is active.
                        isSelected: agent.id == agentId && workspaceAgentAddress == nil
                            && activeHostedAgent == nil,
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
                            // An agent with no chats has nothing to browse, so
                            // the click starts one. Otherwise it only browses the
                            // history: it never selects the agent or starts a chat.
                            if historyItems(for: agent.id).isEmpty, let start = onNewChatWithAgent {
                                start(agent.id)
                                return
                            }
                            let wasExpanded = agentExpansion[agent.id] ?? (agent.id == agentId)
                            agentExpansion[agent.id] = !wasExpanded
                            if wasExpanded { visibleChatCounts.removeValue(forKey: agent.id) }
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
        if isAgentExpanded(agent) {
            let recent = navigatorChats(for: agent.id)
            let count = visibleChatCounts[agent.id] ?? 5
            let visible = Self.navigatorVisibleChats(recent, cap: count, activeIds: Set(activityMonitor.statuses.keys))
            ForEach(visible) { chat in
                navigatorConversationRow(chat, agent: agent)
            }
            if recent.count > visible.count {
                Button { visibleChatCounts[agent.id] = count + 5 } label: {
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
        return SessionRow(session: metadata, agent: agent, isSelected: chat.isSelected,
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
                ChatWindowManager.shared.createWindow(agentId: agent?.id ?? chat.agentId, sessionData: savedConversation(chat))
            },
            onOpenInNewTab: onOpenInNewTab.map { open in { open(savedConversation(chat)) } })
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
            conversations.sessions, agentId: agentId, includeArchived: showArchived,
            keepingArchived: Set(activityMonitor.statuses.keys), excludingProjects: projectIds,
            excludingServedIn: served)
        let live = openChats.filter {
            $0.kind == .chat && !$0.session.pinned && ChatTabScope.of($0.session) == .local(agentId)
                && !($0.session.projectId.map(projectIds.contains) ?? false)
                && !($0.session.workspaceContext.map { $0.isServedForTeammate && served.contains($0.workspaceId) } ?? false)
        }
        return mergedHistory(saved: saved, live: live)
    }

    /// A project's chats, from every local agent, merged the same way.
    private func projectHistoryItems(for projectId: UUID) -> [HistoryItem] {
        let saved = Self.projectHistorySessions(
            conversations.sessions, projectId: projectId, includeArchived: showArchived,
            keepingArchived: Set(activityMonitor.statuses.keys))
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

    private func mergedHistory(saved: [ChatSessionData], live: [ChatTab]) -> [HistoryItem] {
        let activeIds = Set(activityMonitor.statuses.keys)
        var items = saved.map { data in
            let tab = live.first { $0.session.sessionId == data.id }
            return HistoryItem(id: data.id, title: data.title, updatedAt: data.updatedAt,
                saved: data, openTabId: tab?.id, isSelected: data.id == activeSessionId,
                agentId: data.agentId ?? Agent.defaultId)
        }
        let savedIds = Set(saved.map(\.id))
        for tab in live where tab.session.sessionId.map({ !savedIds.contains($0) }) ?? true {
            // A New Chat nothing happened in is listed only while it is the
            // chat on screen.
            if Self.isUntouchedChat(tab), tab.id != activeOpenTabId { continue }
            // Archived sessions stay out of the recent list even if still
            // alive in memory, unless the Show Archived filter is on or a
            // run is live on them.
            if let id = tab.session.sessionId,
                conversations.sessions.contains(where: {
                    $0.id == id && (($0.archived && !showArchived && !activeIds.contains(id)) || $0.pinned)
                })
            { continue }
            items.append(HistoryItem(id: tab.session.sessionId ?? tab.id, title: tab.session.title,
                updatedAt: tab.session.updatedAt, saved: nil, openTabId: tab.id,
                isSelected: tab.id == activeOpenTabId, agentId: tab.session.agentId ?? Agent.defaultId))
        }
        return items.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
    }

    // MARK: - Pinned

    /// Pinned chats across local agents and workspaces, newest first, each
    /// with the agent its row shows: a local agent, or a teammate's.
    private var pinnedItems: [(item: HistoryItem, agent: Agent?, shared: SharedAgentIdentity?)] {
        Self.pinnedSessions(
            conversations.sessions, includeArchived: showArchived, keepingArchived: Set(activityMonitor.statuses.keys))
            .compactMap { data in
                let tab = openChats.first { $0.kind == .chat && $0.session.sessionId == data.id }
                let item = HistoryItem(
                    id: data.id, title: data.title, updatedAt: data.updatedAt,
                    saved: data, openTabId: tab?.id, isSelected: data.id == activeSessionId,
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
    /// lists them) and, unless `includeArchived`, archived ones. Archived
    /// chats in `keepingArchived` (live runs) stay listed regardless.
    nonisolated static func agentHistorySessions(
        _ sessions: [ChatSessionData], agentId: UUID, includeArchived: Bool = false,
        keepingArchived: Set<UUID> = [], excludingProjects: Set<UUID> = [],
        excludingServedIn servedWorkspaceIds: Set<String> = []
    ) -> [ChatSessionData] {
        sessions.filter {
            (includeArchived || !$0.archived || keepingArchived.contains($0.id))
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
        _ sessions: [ChatSessionData], projectId: UUID, includeArchived: Bool = false,
        keepingArchived: Set<UUID> = []
    ) -> [ChatSessionData] {
        sessions.filter {
            (includeArchived || !$0.archived || keepingArchived.contains($0.id))
                && !$0.pinned && !$0.isWorkspaceAgentChat
                && $0.projectId == projectId
        }
    }

    /// The Pinned group's chats: pinned chats of any agent, local or a
    /// teammate's, newest first; archived ones only when `includeArchived`
    /// or listed in `keepingArchived` (live runs).
    nonisolated static func pinnedSessions(
        _ sessions: [ChatSessionData], includeArchived: Bool = false, keepingArchived: Set<UUID> = []
    ) -> [ChatSessionData] {
        sessions
            .filter { $0.pinned && (includeArchived || !$0.archived || keepingArchived.contains($0.id)) }
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
            ConversationImportRequest.present(agentId: agentId, scope: alertScope, onOpen: onSelect)
        } label: {
            Label {
                Text("Import Conversations", bundle: .module)
            } icon: {
                Image(systemName: "square.and.arrow.down")
            }
        }
        Button {
            withAnimation(theme.motion.quick) { showArchived.toggle() }
        } label: {
            Label {
                Text(showArchived ? "Hide Archived" : "Show Archived", bundle: .module)
            } icon: {
                Image(systemName: showArchived ? "eye.slash" : "archivebox")
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

    private var agentList: some View {
        ScrollView {
            // Plain VStack: every row needs a live frame for drag-to-reorder
            // hit testing, and the agent list is small.
            VStack(spacing: theme.space.s2) {
                // Background runs (scheduled / API / channel / delegated)
                // are tabs of their agent, not rows here; each agent row
                // rolls its live work up into a ring + status line.
                ForEach(filteredLocalAgents) { agent in
                    let activity = activityStatus(for: agent)
                    AgentSidebarRow(
                        agent: agent,
                        // A team-agent or hosted-agent tab owns the
                        // selection: no local row is highlighted while one
                        // is active.
                        isSelected: agent.id == agentId && workspaceAgentAddress == nil
                            && activeHostedAgent == nil,
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

                // The user's agents on their other Macs, which run them.
                ForEach(visibleHostedAgents) { host in
                    hostedAgentsSection(host)
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
            }
            .padding(.vertical, theme.space.s8)
            .padding(.horizontal, theme.space.s8)
            .coordinateSpace(name: "agentList")
            .onPreferenceChange(AgentRowFramesKey.self) { agentRowFrames = $0 }
            .animation(theme.motion.quick, value: displayedAgents.map(\.id))
            .animation(theme.motion.quick, value: rosterStore.rosters.map(\.id))
            .animation(theme.motion.quick, value: directlySharedAgents.map(\.id))
            .animation(theme.motion.quick, value: visibleHostedAgents.map(\.id))
        }
        .scrollIndicators(.hidden)
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
                    isSelected: activeHostedAgent.map { $0.device == host.device && $0.agentId == agentId } ?? false,
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
            includeArchived: showArchived, keepingArchived: Set(activityMonitor.statuses.keys))
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
            includeArchived: showArchived, keepingArchived: Set(activityMonitor.statuses.keys))
        let live = openChats.filter { tab in
            guard tab.kind == .chat, !tab.session.pinned, let context = tab.session.workspaceContext else { return false }
            return context.isServedForTeammate && context.workspaceId == workspaceId
                && (tab.session.agentId ?? Agent.defaultId) == agentId
        }
        return mergedHistory(saved: saved, live: live)
    }

    /// Saved chats under a teammate's agent row: the user's own chats with
    /// it in that workspace, minus pinned (the Pinned group shows those)
    /// and, unless `includeArchived`, archived ones. Archived chats in
    /// `keepingArchived` (live runs) stay listed regardless.
    nonisolated static func workspaceAgentSessions(
        _ sessions: [ChatSessionData], address: String, workspaceId: String,
        includeArchived: Bool = false, keepingArchived: Set<UUID> = []
    ) -> [ChatSessionData] {
        let address = address.lowercased()
        return sessions.filter { session in
            guard session.isWorkspaceAgentChat, let context = session.workspace,
                context.agentAddress.lowercased() == address, context.workspaceId == workspaceId
            else { return false }
            return !session.pinned
                && (includeArchived || !session.archived || keepingArchived.contains(session.id))
        }
    }

    /// Saved chats under the user's own agent's row in a workspace: the
    /// ones it served for teammates there, with the same pinned and
    /// archived rules.
    nonisolated static func servedSessions(
        _ sessions: [ChatSessionData], agentId: UUID, workspaceId: String,
        includeArchived: Bool = false, keepingArchived: Set<UUID> = []
    ) -> [ChatSessionData] {
        sessions.filter { session in
            guard let context = session.workspace, context.isServedForTeammate,
                !workspaceId.isEmpty, context.workspaceId == workspaceId,
                (session.agentId ?? Agent.defaultId) == agentId
            else { return false }
            return !session.pinned
                && (includeArchived || !session.archived || keepingArchived.contains(session.id))
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

/// A collapsible group's header ("Pinned", "Agents"): the whole row is the
/// toggle, with optional actions on the trailing end that keep their own
/// clicks.
private struct NavigatorGroupHeader<Trailing: View>: View {
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
                .padding(.trailing, NavigatorRowMetrics.trailingInset)
        }
        .onHover { isHovered = $0 }
    }
}

/// Row in the agents-focused sidebar. Mirrors `SessionRow`'s hover and
/// selection treatment: avatar, name, hover-only gear to the agent's settings.
private struct AgentSidebarRow: View {
    let agent: Agent
    let isSelected: Bool
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

    /// Stop while a run is live on this agent, otherwise New Chat and the
    /// gear opening this agent's settings in Settings: the
    /// Agents detail page for a user agent, Settings → Orchestrator for the
    /// built-in Osaurus agent. Always laid out and revealed on hover, so
    /// showing them never changes the row's layout.
    @ViewBuilder private var hoverControls: some View {
        if activityStatus != nil, let onStop {
            SessionStopButton(action: onStop)
        } else {
            HStack(spacing: theme.space.s4) {
                if let onNewChat {
                    // The compose square carries its ink low and to the
                    // left; lifted, it lines up with the gear beside it.
                    SettingsIconButton("square.and.pencil", help: "New Chat",
                                       size: .extraSmall, role: .tertiary,
                                       glyphNudge: CGSize(width: 0, height: -0.75), action: onNewChat)
                }
                SettingsIconButton("gearshape", help: agent.id == Agent.defaultId ? "Orchestrator settings" : "Agent settings",
                                   size: .extraSmall, role: .tertiary, action: openAgentSettings)
            }
        }
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
                    Text(agent.displayName)
                        .componentInspectionText(41, role: .label, fallback: .caption, weight: 500, theme: theme)
                        .foregroundColor(isSelected ? theme.text.primary : theme.text.secondary)
                        .lineLimit(1)
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
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
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
        .onTapGesture(perform: onSelect)
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
        .animation(theme.motion.quick, value: isSelected)
    }

    private var settingsHelpKey: LocalizedStringKey {
        if agent.id == Agent.architectId { return "Architect Settings" }
        return agent.isBuiltIn ? "Orchestrator Settings" : "Agent Settings"
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
                    Circle().strokeBorder(theme.border.default, lineWidth: theme.stroke.default)
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

private struct SessionRow: View {
    let session: ChatSessionData
    let agent: Agent?
    let isSelected: Bool
    /// Whether this row is part of an active multi-selection. Drives the
    /// accent background and the leading checkmark.
    var isMultiSelected: Bool = false
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
    @State private var hoverControlsWidth: CGFloat = 0
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
        guard let agent = agent, !agent.isBuiltIn else { return theme.text.secondary }
        return theme.dataInk(seed: agent.id.uuidString)
    }

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
            HStack(spacing: theme.catalogLayoutMetric("component.library.41.elements.layout.sessionRow.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(41, "gap", theme.space.s10, theme))) {
                // Multi-select check, shown in place of leading padding so the
                // row doesn't shift when selection toggles.
                if isMultiSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .glyphSize(.label, weight: .semibold)
                        .foregroundColor(theme.text.primary)
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
                .animation(theme.motion.springAnimation(responseMultiplier: 0.8), value: activityStatus)

                VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.41.elements.layout.sessionRow.body.verticalGap", inheriting: NativeComponentInspectionStyle.metric(41, "gap", theme.space.s2, theme))) {
                    HStack(spacing: theme.catalogLayoutMetric("component.library.41.elements.layout.sessionRow.body.horizontalGap2", inheriting: NativeComponentInspectionStyle.metric(41, "gap", theme.space.s4, theme))) {
                        if session.pinned {
                            Image(systemName: "pin.fill")
                                .glyphSize(.tiny, weight: .semibold)
                                .foregroundColor(theme.text.secondary)
                                .rotationEffect(.degrees(45))
                        }

                        Text(session.title)
                            .componentInspectionText(41, role: .bodySmall, fallback: .caption, weight: 500, theme: theme)
                            .foregroundColor(theme.text.primary)
                            .lineLimit(1)
                            // The Text itself must be greedy so it claims all
                            // free width and pushes the trailing badges to the
                            // right; putting maxWidth on the enclosing HStack
                            // instead let the text hug its ideal and truncate
                            // early while empty space sat after the badges.
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if session.source != .chat || isFromPairedPhone {
                            sourceBadge
                        }

                        if !session.capabilities.isEmpty {
                            capabilityBadges
                        }

                        if let summary = fileChanges.summary(for: session.id), summary.setCount > 0 {
                            fileChangesBadge(summary)
                        }
                    }.catalogLayoutTarget("component.library.41.elements.layout.sessionRow.body.horizontalGap2")

                    // Live status replaces the relative timestamp while the
                    // session's run is active so the state is glanceable.
                    Group {
                        switch activityStatus {
                        case .working:
                            Text("Running…", bundle: .module)
                                .foregroundColor(theme.status.info.foreground)
                        case .waitingForInput:
                            Text("Needs your input", bundle: .module)
                                .foregroundColor(theme.status.warning.foreground)
                        case nil:
                            Text(metadataLine)
                                .foregroundColor(theme.text.secondary)
                        }
                    }
                    .componentInspectionText(41, role: .caption, fallback: .micro, theme: theme)
                    .lineLimit(1)
                }.catalogLayoutTarget("component.library.41.elements.layout.sessionRow.body.verticalGap")
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
                    .assignedPopover(isPresented: $showActionsPopover, width: 220, accessibilityLabel: L("Conversation actions"), arrowEdge: .trailing) {
                        actionsPopover
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }.catalogLayoutTarget("component.library.41.elements.layout.sessionRow.body.horizontalGap")
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.41.elements.layout.sessionRow.body.paddingX2", inheriting: NativeComponentInspectionStyle.metric(41, "padding", theme.space.s10, theme))).catalogLayoutTarget("component.library.41.elements.layout.sessionRow.body.paddingX2")
            .padding(.vertical, theme.catalogLayoutMetric("component.library.41.elements.layout.sessionRow.body.paddingY2", inheriting: NativeComponentInspectionStyle.metric(41, "padding", theme.space.s8, theme))).catalogLayoutTarget("component.library.41.elements.layout.sessionRow.body.paddingY2")
            .frame(minHeight: NativeComponentInspectionStyle.metric(41, "height", 0, theme))
            .sidebarRowChrome(isSelected: isSelected || isMultiSelected, isHovered: isHovered)
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .stroke(
                        isImportHighlighted ? theme.border.focus : Color.clear,
                        lineWidth: theme.stroke.focus
                    )
                    .allowsHitTesting(false)
            )
            .animation(theme.motion.slow, value: isImportHighlighted)
            .contentShape(RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous))
            .onTapGesture {
                onSelect()
            }
            .animation(theme.motion.springAnimation(responseMultiplier: 0.8), value: isMultiSelected)
            .onHover { hovering in
                withAnimation(theme.motion.springAnimation(responseMultiplier: 0.8)) {
                    isHovered = hovering
                }
            }
            .animation(theme.motion.springAnimation(responseMultiplier: 0.8), value: isSelected)
            .assignedContextMenu(chatMenu: true) { conversationContextMenu }
        }
    }

    /// Archived chats read as set aside: tertiary ink at rest (below the
    /// secondary titles around them, still legible), lifted to secondary on
    /// hover. Disabled ink is for unavailable controls, not readable titles.
    private var archivedInk: Color {
        isHovered ? environmentTheme.text.secondary : environmentTheme.text.tertiary
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
            Button(action: onSelect) {
                HStack(spacing: theme.space.s0) {
                    // A real view, so the column keeps its width when empty.
                    ZStack {
                        if showsAgentAvatar, let sharedAvatar {
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
                        } else if session.archived {
                            Image(systemName: "archivebox")
                                .glyphSize(.footnote)
                                .foregroundStyle(archivedInk)
                                .help(Text("Archived", bundle: .module))
                                .transition(.opacity)
                        }
                    }
                    .frame(width: NavigatorRowMetrics.iconColumn)
                    .animation(navigatorActivityAnimation, value: activityStatus)
                    .padding(.leading, NavigatorRowMetrics.leadingInset)
                    .padding(.trailing, NavigatorRowMetrics.iconGap)
                    Text(session.title.isEmpty ? L("New chat") : session.title)
                        .textStyle(.label)
                        .foregroundStyle(
                            isSelected || activityStatus == .waitingForInput
                                ? environmentTheme.text.primary
                                : session.archived ? archivedInk : environmentTheme.text.secondary
                        )
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // The title runs under Pin / Archive and fades out
                        // there instead of re-truncating, so hovering never
                        // shifts the row.
                        .mask(alignment: .leading) {
                            HStack(spacing: theme.space.s0) {
                                Rectangle()
                                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: isHovered ? environmentTheme.space.s12 : 0)
                                Color.clear.frame(width: isHovered ? hoverControlsWidth : 0)
                            }
                        }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            .help(navigatorActivityLine ?? "")
            .accessibilityValue(Text(verbatim: [navigatorActivityLine, formatRelativeDate(session.updatedAt)]
                .compactMap { $0 }.joined(separator: ", ")))
            .overlay(alignment: .trailing) {
                HStack(spacing: environmentTheme.space.s4) {
                    // Tilted like a pushpin: upright, the head-heavy glyph
                    // floats high and reads as an hourglass at this size.
                    SettingsIconButton(
                        session.pinned ? "pin.fill" : "pin",
                        help: session.pinned ? "Unpin" : "Pin",
                        size: .extraSmall, role: .tertiary,
                        glyphTilt: .degrees(45), glyphNudge: CGSize(width: -0.75, height: 1),
                        action: onTogglePin)
                    SettingsIconButton(
                        session.archived ? "tray.and.arrow.up" : "archivebox",
                        help: session.archived ? "Unarchive" : "Archive",
                        size: .extraSmall, role: .tertiary,
                        glyphNudge: CGSize(width: 0, height: session.archived ? -1.25 : 0.5),
                        action: onToggleArchive)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { hoverControlsWidth = $0 }
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            }
            // The age and the ⋯ share one slot; the menu stays mounted so it
            // can present, and the age keeps its width while hidden so the
            // slot never resizes on hover.
            ZStack(alignment: .trailing) {
                navigatorAgeLabel
                    .opacity(isHovered ? 0 : 1)
                AssignedActionMenu(accessibilityLabel: "Conversation actions for \(session.title)", appearance: .chatContext) {
                    conversationContextMenu
                } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(ConversationEllipsisStyle())
                .frame(width: trailingControl, height: trailingControl)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            }
            .padding(.leading, environmentTheme.space.s4)
            .padding(.trailing, NavigatorRowMetrics.trailingInset)
        }
        .frame(height: NavigatorRowMetrics.rowHeight)
        .sidebarRowChrome(isSelected: isSelected, isHovered: isHovered, compactChatStyle: true)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .assignedContextMenu(chatMenu: true) { conversationContextMenu }
        .environment(\.assignedMenuAppearance, .chatContext)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var conversationContextMenu: some View {
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
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.41.elements.layout.sessionRow.projectPickerPopoverPage.verticalGap", inheriting: NativeComponentInspectionStyle.metric(41, "gap", theme.space.s2, theme))) {
            ActionsPopoverButton(icon: "chevron.left", label: "Back", isDestructive: false) {
                showProjectPicker = false
            }
            Divider().padding(.vertical, theme.space.s2)
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
                Divider().padding(.vertical, theme.space.s2)
                ActionsPopoverButton(
                    icon: "folder.badge.minus", label: "Remove from Project", isDestructive: true
                ) {
                    dismissProjectPicker()
                    onSetProject?(nil)
                }
            }
        }.catalogLayoutTarget("component.library.41.elements.layout.sessionRow.projectPickerPopoverPage.verticalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.41.elements.layout.sessionRow.projectPickerPopoverPage.padding.horizontal", inheriting: NativeComponentInspectionStyle.metric(41, "padding", theme.space.s6, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.41.elements.layout.sessionRow.projectPickerPopoverPage.padding.vertical", inheriting: NativeComponentInspectionStyle.metric(41, "padding", theme.space.s6, theme))).catalogLayoutTarget("component.library.41.elements.layout.sessionRow.projectPickerPopoverPage.padding.horizontal").catalogLayoutTarget("component.library.41.elements.layout.sessionRow.projectPickerPopoverPage.padding.vertical")
        .frame(minWidth: 180)
    }

    private func dismissProjectPicker() {
        showProjectPicker = false
        showActionsPopover = false
    }

    private var mainActionsPopoverPage: some View {
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.41.elements.layout.sessionRow.mainActionsPopoverPage.verticalGap", inheriting: NativeComponentInspectionStyle.metric(41, "gap", theme.space.s2, theme))) {
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
            Divider().padding(.vertical, theme.space.s2)
            ActionsPopoverButton(icon: "square.and.arrow.up", label: "Export…", isDestructive: false) {
                showActionsPopover = false
                requestExport()
            }
            Divider().padding(.vertical, theme.space.s2)
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
        }.catalogLayoutTarget("component.library.41.elements.layout.sessionRow.mainActionsPopoverPage.verticalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.41.elements.layout.sessionRow.mainActionsPopoverPage.padding.horizontal", inheriting: NativeComponentInspectionStyle.metric(41, "padding", theme.space.s6, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.41.elements.layout.sessionRow.mainActionsPopoverPage.padding.vertical", inheriting: NativeComponentInspectionStyle.metric(41, "padding", theme.space.s6, theme))).catalogLayoutTarget("component.library.41.elements.layout.sessionRow.mainActionsPopoverPage.padding.horizontal").catalogLayoutTarget("component.library.41.elements.layout.sessionRow.mainActionsPopoverPage.padding.vertical")
        .frame(minWidth: 180)
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
        return HStack(spacing: theme.catalogLayoutMetric("component.library.41.elements.layout.sessionRow.capabilityBadges.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(41, "gap", theme.space.s2, theme))) {
            ForEach(visible, id: \.self) { cap in
                capabilityIcon(cap)
            }
            if overflow > 0 {
                Text(verbatim: "+\(overflow)")
                    .componentInspectionText(41, role: .caption, fallback: .micro, weight: 600, theme: theme)
                    .foregroundColor(theme.text.secondary)
                    .padding(.horizontal, theme.catalogLayoutMetric("component.library.41.elements.layout.sessionRow.capabilityBadges.paddingX", inheriting: NativeComponentInspectionStyle.metric(41, "padding", theme.space.s4, theme))).catalogLayoutTarget("component.library.41.elements.layout.sessionRow.capabilityBadges.paddingX")
                    .padding(.vertical, theme.space.s2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(theme.surface.pressed)
                    )
                    .help(Text(verbatim: ordered.dropFirst(visibleLimit).map(\.label).joined(separator: ", ")))
            }
        }.catalogLayoutTarget("component.library.41.elements.layout.sessionRow.capabilityBadges.horizontalGap")
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

    private func capabilityIcon(_ cap: SessionCapability) -> some View {
        Image(systemName: cap.iconName)
            .glyphSize(.tiny, weight: .semibold)
            .foregroundColor(theme.text.secondary)
            .frame(width: 14, height: 14)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.small, style: .continuous)
                    .fill(theme.surface.pressed)
            )
            .help(Text(LocalizedStringKey(cap.label), bundle: .module))
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
            Circle()
                .fill(theme.surface.hover)
                .frame(width: 24, height: 24)

            Image(systemName: "person.fill")
                .glyphSize(.micro, weight: .medium)
                .foregroundColor(theme.text.secondary)
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

    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(41, enabled: componentEnabled) }
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.catalogLayoutMetric("component.library.41.elements.layout.actionsPopoverButton.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(41, "gap", theme.space.s8, theme))) {
                Image(systemName: icon)
                    .glyphSize(.footnote, weight: .medium)
                    .frame(width: 14)
                Group {
                    if labelIsVerbatim {
                        Text(verbatim: label)
                    } else {
                        Text(LocalizedStringKey(label), bundle: .module)
                    }
                }
                .componentInspectionText(41, role: .label, fallback: .caption, weight: 500, theme: theme)
                .lineLimit(1)
                Spacer(minLength: 0)
            }.catalogLayoutTarget("component.library.41.elements.layout.actionsPopoverButton.body.horizontalGap")
            .foregroundColor(foreground)
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.41.elements.layout.actionsPopoverButton.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(41, "padding", theme.space.s8, theme))).catalogLayoutTarget("component.library.41.elements.layout.actionsPopoverButton.body.paddingX")
            .padding(.vertical, theme.catalogLayoutMetric("component.library.41.elements.layout.actionsPopoverButton.body.paddingY", inheriting: NativeComponentInspectionStyle.metric(41, "padding", theme.space.s6, theme))).catalogLayoutTarget("component.library.41.elements.layout.actionsPopoverButton.body.paddingY")
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .fill(isHovered ? hoverFill : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        if isDestructive { return theme.danger.default }
        return theme.text.primary
    }

    private var hoverFill: Color {
        if isDestructive { return theme.status.error.background }
        return theme.surface.hover
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

    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(41, enabled: componentEnabled) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSpinning = false

    private static let diameter: CGFloat = 30
    private static let lineWidth: CGFloat = 2

    var body: some View {
        switch status {
        case .working:
            if reduceMotion {
                ring(theme.status.info.foreground)
            } else {
                Circle()
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                theme.status.info.background,
                                theme.status.info.foreground,
                            ]),
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round)
                    )
                    .frame(width: Self.diameter, height: Self.diameter)
                    .rotationEffect(.degrees(isSpinning ? 360 : 0))
                    .animation(
                        theme.motion.loop(duration: 1.1),
                        value: isSpinning
                    )
                    .onAppear { isSpinning = true }
                    .onDisappear { isSpinning = false }
            }
        case .waitingForInput:
            ring(theme.status.warning.foreground)
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

    private func ring(_ color: Color) -> some View {
        Circle()
            .stroke(color, lineWidth: Self.lineWidth)
            .frame(width: Self.diameter, height: Self.diameter)
    }
}

// MARK: - Navigator Activity Indicator

/// Quiet live-run mark for compact navigator rows and collapsed group
/// headers: a short comet arc circling a faint track while the run works,
/// a warning dot when it waits on the user. `ringsAvatar` draws the same
/// states as a ring around an 18pt avatar instead.
struct NavigatorActivityIndicator: View {
    let status: SessionActivityMonitor.Status
    var ringsAvatar: Bool = false

    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(41, enabled: componentEnabled) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var diameter: CGFloat { ringsAvatar ? 22 : 11 }
    private static let lineWidth: CGFloat = 1.5
    private static let dotDiameter: CGFloat = 6

    var body: some View {
        ZStack {
            switch status {
            case .working:
                NavigatorActivityComet(
                    color: theme.status.info.foreground,
                    diameter: diameter,
                    lineWidth: Self.lineWidth,
                    isStill: reduceMotion
                )
                .transition(transition)
            case .waitingForInput:
                NavigatorAttentionMark(
                    color: theme.status.warning.foreground,
                    diameter: ringsAvatar ? diameter : Self.dotDiameter,
                    lineWidth: ringsAvatar ? Self.lineWidth : nil
                )
                .transition(transition)
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(reduceMotion ? nil : theme.motion.springAnimation(responseMultiplier: 0.8), value: status)
        .accessibilityHidden(true)
    }

    private var transition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.6))
    }
}

/// Faint full track plus a ~90° arc that fades in from its tail. The angle
/// comes from the wall clock, so the spin never restarts on re-render and
/// every live row turns in phase.
private struct NavigatorActivityComet: View {
    let color: Color
    let diameter: CGFloat
    let lineWidth: CGFloat
    let isStill: Bool

    @Environment(\.theme) private var theme

    private static let period: TimeInterval = 1.2
    private static let arcFraction: CGFloat = 0.25

    var body: some View {
        if isStill {
            ZStack {
                track
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: diameter, height: diameter)
        } else {
            TimelineView(.animation) { context in
                let turns = context.date.timeIntervalSinceReferenceDate / Self.period
                ZStack {
                    track
                    Circle()
                        .trim(from: 0, to: Self.arcFraction)
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(colors: [color.opacity(0), color]),
                                center: .center,
                                startAngle: .zero,
                                endAngle: .degrees(360 * Self.arcFraction)
                            ),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(turns.truncatingRemainder(dividingBy: 1) * 360))
                }
                .frame(width: diameter, height: diameter)
            }
        }
    }

    private var track: some View {
        Circle().stroke(theme.rule(around: color), lineWidth: lineWidth)
    }
}

/// Warning dot (or ring, when `lineWidth` is set) that settles in with one
/// soft pulse on arrival and then holds still: no looping blink.
private struct NavigatorAttentionMark: View {
    let color: Color
    let diameter: CGFloat
    var lineWidth: CGFloat? = nil

    @Environment(\.theme) private var theme
    @State private var isPulsed = false

    var body: some View {
        Group {
            if let lineWidth {
                Circle().stroke(color, lineWidth: lineWidth)
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: diameter, height: diameter)
        // A ring around an avatar is already large; it only breathes.
        .scaleEffect(isPulsed ? (lineWidth == nil ? 1.35 : 1.1) : 1)
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
                onSelect: { _ in }
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
    @Environment(\.themedAlertScope) private var alertScope
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
                    || (session.runtimeSource == .schedule && session.externalSessionKey == scheduleFilter))
                && (watcherFilter == nil
                    || (session.runtimeSource == .watcher && session.externalSessionKey == watcherFilter))
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
        VStack(spacing: theme.space.s12) {
            HStack(spacing: theme.space.s8) {
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
                VStack(spacing: theme.space.s8) {
                    placeholder(
                        icon: showArchived ? "archivebox" : "line.3.horizontal.decrease.circle",
                        text: showArchived ? "No archived chats" : "No chats match this filter"
                    )
                    if let onClearFilters {
                        Button {
                            withAnimation(theme.motion.quick) { onClearFilters() }
                        } label: {
                            Text("Clear Filters", bundle: .module)
                                .textStyle(.footnote, weight: 500)
                                .foregroundColor(theme.text.link)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .padding(.bottom, theme.space.s16)
                    }
                }
            } else if filteredSessions.isEmpty {
                SidebarNoResultsView(searchQuery: searchQuery) {
                    withAnimation(theme.motion.quick) { searchQuery = "" }
                }
                .frame(maxHeight: listMaxHeight ?? .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: theme.space.s2) {
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
                    .padding(.bottom, theme.space.s4)
                    .animation(
                        theme.motion.springAnimation(responseMultiplier: 0.9),
                        value: filteredSessions.map(\.id)
                    )
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: listMaxHeight ?? .infinity)
            }
        }
        .animation(theme.motion.quick, value: selectedIds)
        .onChange(of: searchQuery) { _, query in
            scheduleContentSearch(query)
        }
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
        HStack(spacing: theme.space.s8) {
            Text("\(selectedIds.count) selected", bundle: .module)
                .textStyle(.caption, weight: 600)
                .foregroundColor(theme.text.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if !projectManager.projects.isEmpty {
                SettingsOverflowMenu(icon: "folder.badge.plus", help: "Move to Project", size: .extraSmall) {
                    ForEach(projectManager.projects) { project in
                        Button { moveSelected(to: project.id) } label: { Text(verbatim: project.name) }
                    }
                    Divider()
                    Button { moveSelected(to: nil) } label: {
                        Text("Remove from Project", bundle: .module)
                    }
                }
            }
            SettingsIconButton("archivebox", help: "Archive", size: .extraSmall) {
                for id in selectedIds { onSetArchived(id, true) }
                clearSelection()
            }
            SettingsIconButton("trash", help: "Delete", size: .extraSmall, isDestructive: true) {
                requestDeleteSelected()
            }
            SettingsIconButton("xmark", help: "Clear Selection", size: .extraSmall) {
                clearSelection()
            }
        }
        .padding(.horizontal, theme.space.s10)
        .padding(.vertical, theme.space.s6)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                .fill(theme.surface.selected)
        )
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
                message: ids.count == 1
                    ? L("1 conversation will be removed permanently. This can't be undone.")
                    : L("\(ids.count) conversations will be removed permanently. This can't be undone."),
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
        VStack(spacing: theme.space.s6) {
            if let icon {
                Image(systemName: icon)
                    .glyphSize(.xlarge)
                    .foregroundColor(theme.text.tertiary)
            } else {
                SettingsSpinner()
            }
            Text(text, bundle: .module)
                .textStyle(.caption)
                .foregroundColor(theme.text.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, theme.space.s24)
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
