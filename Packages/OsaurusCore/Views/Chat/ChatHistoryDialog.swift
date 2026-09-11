//
//  ChatHistoryDialog.swift
//  osaurus
//
//  "See History" dialog: the selected agent's conversations, presented as a
//  themed alert from the toolbar's overflow menu. Tapping a row loads that
//  conversation into the window and dismisses the dialog.
//

import AppKit
import SwiftUI

enum ChatHistoryDialog {
    /// Present the history dialog scoped to `windowState`'s window.
    @MainActor
    static func present(for windowState: ChatWindowState) {
        let scope = ThemedAlertScope.chat(windowState.windowId)
        let requestId = UUID()
        let dismiss = { ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId) }
        let content = ChatHistoryDialogContent(
            windowState: windowState,
            scope: scope,
            // Selecting a chat opens it in its own tab (or focuses the tab
            // that already shows it) rather than replacing the active chat.
            onSelect: { session in
                dismiss()
                windowState.openSessionInNewTab(session)
            },
            onOpenInNewTab: { session in
                dismiss()
                windowState.openSessionInNewTab(session)
            }
        )
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: "History",
                message: nil,
                showsHeaderIcon: false,
                buttons: [.cancel(L("Close"))],
                showsCloseButton: true,
                customContent: AnyView(content),
                width: 470,
                // Row actions raise their own alerts (delete confirmation,
                // export chooser + progress). Those stack over this dialog
                // and return to it, instead of replacing it.
                hostsNestedAlerts: true,
                onDismiss: dismiss
            ),
            scope: scope
        )
    }
}

private struct ChatHistoryDialogContent: View {
    @ObservedObject var windowState: ChatWindowState
    let scope: ThemedAlertScope
    let onSelect: (ChatSessionData) -> Void
    let onOpenInNewTab: (ChatSessionData) -> Void

    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var sessionsManager = ChatSessionsManager.shared
    @ObservedObject private var projectManager = ProjectManager.shared
    /// Names for the Workspaces submenu (sessions only carry the id).
    @ObservedObject private var workspacesService = WorkspacesService.shared

    /// Which agent's chats the list shows. nil until the user picks one,
    /// so the initial lens tracks the window's agent (see `activeFilter`).
    @State private var agentFilter: ChatHistoryAgentFilter?
    @State private var showAgentPicker = false
    @State private var isAgentButtonHovered = false

    /// Origin lens (Chat / Plugin / Schedule / ...), picked in the Filter
    /// popover. Composes with the agent lens and the archived chip.
    @State private var sourceFilter: ChatHistorySourceFilter = .all
    /// Project lens (a project id), picked in the Filter popover's submenu.
    @State private var projectFilter: UUID?
    /// Workspace lens (a router workspace id), likewise.
    @State private var workspaceFilter: String?
    /// Plugin lens (a plugin id; "" for plugin chats with no id), likewise.
    @State private var pluginFilter: String?
    /// Schedule / watcher lenses (the schedule or watcher id, which those
    /// runs stamp as the session's external key), likewise.
    @State private var scheduleFilter: String?
    @State private var watcherFilter: String?
    /// Capability lenses (Vision / Voice / Code / Search badges); a chat
    /// must carry every selected one.
    @State private var capabilityFilter: Set<SessionCapability> = []
    @State private var showSourcePicker = false
    @State private var isFilterButtonHovered = false
    /// Archived lens: on lists only archived chats, off hides them.
    @State private var showArchived = false
    @State private var isArchivedChipHovered = false

    /// The Default agent has always listed every conversation here
    /// (`sessions(for:)` returns all of them for Default), so it opens on
    /// "All Chats"; any other agent opens on its own chats.
    private var activeFilter: ChatHistoryAgentFilter {
        if let agentFilter { return agentFilter }
        return windowState.agentId == Agent.defaultId ? .all : .agent(windowState.agentId)
    }

    private var visibleSessions: [ChatSessionData] {
        switch activeFilter {
        case .all:
            return sessionsManager.sessions
        case .agent(let id):
            return sessionsManager.sessions.filter { ($0.agentId ?? Agent.defaultId) == id }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                agentDropdown
                if visibleSessions.contains(where: \.archived) {
                    archivedChip
                }
                Spacer()
                filterButton
                Button {
                    requestImport()
                } label: {
                    // The tray glyph sits low on its baseline; centre the
                    // icon on the text's cap height instead of the line box
                    // so the two read as one aligned unit.
                    HStack(alignment: .center, spacing: 5) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 11, weight: .medium))
                            .offset(y: -1)
                        Text("Import", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    // Cursor on the label: the button chrome itself has no
                    // hover surface inside the alert overlay.
                    .pointingHandCursor()
                }
                .buttonStyle(.plain)
                .localizedHelp("Import Conversations")
            }

            ChatHistoryList(
                sessions: visibleSessions,
                currentSessionId: windowState.session.sessionId,
                scope: scope,
                onSelect: onSelect,
                onDelete: { id in
                    // Same semantics as the sidebar: cancel a registry-owned
                    // run, detach this window, then delete.
                    if let liveTask = BackgroundTaskManager.shared.liveTask(forSessionId: id) {
                        BackgroundTaskManager.shared.cancelTask(liveTask.id)
                    }
                    windowState.prepareForSessionDeletion(id: id)
                    ChatSessionsManager.shared.delete(id: id)
                    windowState.refreshSessions()
                },
                onRename: { id, title in
                    ChatSessionsManager.shared.rename(id: id, title: title)
                    if windowState.session.sessionId == id { windowState.session.title = title }
                    windowState.refreshSessions()
                },
                onSetArchived: { id, archived in
                    ChatSessionsManager.shared.setArchived(id: id, archived: archived)
                    if windowState.session.sessionId == id { windowState.session.archived = archived }
                    windowState.refreshSessions()
                },
                onSetPinned: { id, pinned in
                    ChatSessionsManager.shared.setPinned(id: id, pinned: pinned)
                    if windowState.session.sessionId == id { windowState.session.pinned = pinned }
                    windowState.refreshSessions()
                },
                onSetProject: { id, projectId in
                    ChatSessionsManager.shared.setProject(id: id, projectId: projectId)
                    if windowState.session.sessionId == id { windowState.session.projectId = projectId }
                    windowState.refreshSessions()
                },
                onExport: { metadata, format in
                    ChatSessionExportCoordinator.run(
                        metadataSession: metadata, format: format, scope: scope)
                },
                onStop: { id in
                    if windowState.session.sessionId == id {
                        windowState.session.stop()
                    } else {
                        SessionActivityMonitor.shared.stop(sessionId: id)
                    }
                },
                onOpenInNewWindow: { data in
                    ChatWindowManager.shared.createWindow(agentId: data.agentId, sessionData: data)
                },
                onOpenInNewTab: { data in
                    onOpenInNewTab(data)
                },
                sourceFilter: sourceFilter,
                showArchived: showArchived,
                projectFilter: projectFilter,
                workspaceFilter: workspaceFilter,
                pluginFilter: pluginFilter,
                scheduleFilter: scheduleFilter,
                watcherFilter: watcherFilter,
                capabilityFilter: capabilityFilter,
                onClearFilters: clearFilters
            )
        }
        // Switching the agent lens is a context change, like the sidebar's
        // agent switch: drop the origin lens so the new agent starts on
        // "All" instead of inheriting a bucket it may not even have.
        .onChange(of: activeFilter) { _, _ in
            sourceFilter = .all
        }
        // Unarchiving the last archived chat removes the chip; make sure the
        // lens does not stay stuck on an empty, now-uncontrollable state.
        .onChange(of: visibleSessions.contains(where: \.archived)) { _, hasArchived in
            if !hasArchived { showArchived = false }
        }
    }

    // MARK: - Archived chip

    /// Toggle for the archived lens, in the sidebar's chip idiom: ghost when
    /// off, accent-tinted when on. Only rendered while the current agent
    /// lens has at least one archived chat.
    private var archivedChip: some View {
        let shape = Capsule(style: .continuous)
        return Button {
            withAnimation(theme.animationQuick()) { showArchived.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: showArchived ? "archivebox.fill" : "archivebox")
                    .font(.system(size: 9.5, weight: .semibold))
                Text("Archived", bundle: .module)
                    .font(.system(size: 11, weight: showArchived ? .semibold : .medium))
            }
            .foregroundColor(showArchived ? theme.accentColor : theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                shape.fill(
                    showArchived
                        ? theme.accentColor.opacity(theme.isDark ? 0.28 : 0.18)
                        : (isArchivedChipHovered ? theme.secondaryBackground.opacity(0.5) : Color.clear)
                )
            )
            .contentShape(shape)
            .pointingHandCursor()
        }
        .buttonStyle(.plain)
        .onHover { isArchivedChipHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isArchivedChipHovered)
        .localizedHelp("Show archived chats")
    }

    // MARK: - Filter button

    /// Number of lenses the popover currently applies. Shown on the button
    /// so a narrowed list is never a surprise.
    private var activeFilterCount: Int {
        (sourceFilter != .all ? 1 : 0) + (pluginFilter != nil ? 1 : 0) + (projectFilter != nil ? 1 : 0)
            + (workspaceFilter != nil ? 1 : 0) + (scheduleFilter != nil ? 1 : 0)
            + (watcherFilter != nil ? 1 : 0) + capabilityFilter.count + (showArchived ? 1 : 0)
    }

    private func clearFilters() {
        sourceFilter = .all
        pluginFilter = nil
        projectFilter = nil
        workspaceFilter = nil
        scheduleFilter = nil
        watcherFilter = nil
        capabilityFilter = []
        showArchived = false
    }

    /// Opens the filter popover. Reads as the Import button's sibling, and
    /// switches to the accent tint + filled glyph while any lens is active.
    private var filterButton: some View {
        let isActive = activeFilterCount > 0
        let isRaised = isActive || isFilterButtonHovered || showSourcePicker
        return Button {
            showSourcePicker.toggle()
        } label: {
            HStack(alignment: .center, spacing: 5) {
                Image(
                    systemName: isActive
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle"
                )
                .font(.system(size: 11, weight: .medium))
                sourceFilterTitle
                    .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundColor(isActive ? theme.accentColor : (isRaised ? theme.primaryText : theme.secondaryText))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .pointingHandCursor()
        }
        .buttonStyle(.plain)
        .onHover { isFilterButtonHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isFilterButtonHovered)
        .localizedHelp("Filter chats by source, project, or archived state")
        .popover(isPresented: $showSourcePicker, arrowEdge: .bottom) {
            ChatHistoryFilterPicker(
                sessions: visibleSessions,
                projects: projectManager.projects,
                workspaces: workspacesService.workspaces,
                sourceFilter: $sourceFilter,
                pluginFilter: $pluginFilter,
                projectFilter: $projectFilter,
                workspaceFilter: $workspaceFilter,
                scheduleFilter: $scheduleFilter,
                watcherFilter: $watcherFilter,
                capabilityFilter: $capabilityFilter,
                showArchived: $showArchived,
                onClear: clearFilters
            )
        }
    }

    private var sourceFilterTitle: Text {
        if activeFilterCount == 0 { return Text("Filter", bundle: .module) }
        return Text("Filter (\(activeFilterCount))", bundle: .module)
    }

    // MARK: - Agent dropdown

    /// Avatar + name + chevron, opening the agent picker popover. Changing
    /// the lens only re-filters this list; the window's agent is untouched
    /// until the user opens a chat (which adopts that chat's agent).
    private var agentDropdown: some View {
        Button {
            showAgentPicker.toggle()
        } label: {
            // Pill: avatar flush to the leading edge, name, chevron. Reads
            // as a raised control (soft fill, hairline edge, faint shadow)
            // that lifts a touch more on hover / while the picker is open.
            let isRaised = isAgentButtonHovered || showAgentPicker
            HStack(spacing: 7) {
                ChatHistoryAgentFilterAvatar(filter: activeFilter, agentManager: agentManager, diameter: 20)
                activeFilterTitle
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isRaised ? theme.primaryText : theme.secondaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(isRaised ? theme.accentColor : theme.tertiaryText)
                    .rotationEffect(.degrees(showAgentPicker ? 180 : 0))
                    .padding(.trailing, 2)
            }
            .padding(.leading, 4)
            .padding(.trailing, 9)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(
                        isRaised
                            ? theme.secondaryBackground.opacity(theme.isDark ? 0.9 : 1.0)
                            : theme.secondaryBackground.opacity(theme.isDark ? 0.55 : 0.7)
                    )
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isRaised
                            ? theme.accentColor.opacity(0.35)
                            : theme.primaryBorder.opacity(theme.isDark ? 0.35 : 0.25),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: theme.shadowColor.opacity(isRaised ? 0.18 : 0.08),
                radius: isRaised ? 6 : 3,
                x: 0,
                y: isRaised ? 2 : 1
            )
            .contentShape(Capsule())
            .pointingHandCursor()
        }
        .buttonStyle(.plain)
        .onHover { isAgentButtonHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isAgentButtonHovered)
        .animation(.easeOut(duration: 0.15), value: showAgentPicker)
        .localizedHelp("Choose which agent's chats to show")
        .popover(isPresented: $showAgentPicker, arrowEdge: .bottom) {
            ChatHistoryAgentPicker(
                agents: agentManager.agents,
                sessions: sessionsManager.sessions,
                selected: activeFilter,
                onSelect: { filter in
                    agentFilter = filter
                    showAgentPicker = false
                }
            )
        }
    }

    private var activeFilterTitle: Text {
        switch activeFilter {
        case .all:
            return Text("All Chats", bundle: .module)
        case .agent(let id):
            return Text(verbatim: agentManager.agent(for: id)?.displayName ?? windowState.cachedAgentDisplayName)
        }
    }

    /// Same Import flow the old sidebar had: first-time provider guide,
    /// then the picker; scoped to the selected agent (Default agent imports
    /// unscoped). A single imported conversation opens immediately.
    private func requestImport() {
        let scope = self.scope
        let agentId = windowState.agentId
        let onOpen = onSelect
        let startImport = {
            ChatSessionImportCoordinator.run(
                agentId: agentId == Agent.defaultId ? nil : agentId,
                scope: scope,
                source: .sidebar,
                onOpen: { onOpen($0) }
            )
        }
        if ImportGuidePreference.shared.skip {
            startImport()
            return
        }
        let requestId = UUID()
        let sheet = ImportGuideSheet {
            ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
            startImport()
        }
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: "Import Conversations",
                message: nil,
                buttons: [.cancel(L("Cancel"))],
                showsCloseButton: true,
                customContent: AnyView(sheet),
                width: 470,
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }
}

// MARK: - Source filter

/// Where the listed conversations started. Applies on top of the agent
/// lens and the archived chip.
enum ChatHistorySourceFilter: Equatable {
    /// Every origin.
    case all
    /// Only conversations tagged with this origin.
    case source(SessionSource)

    func matches(_ session: ChatSessionData) -> Bool {
        switch self {
        case .all: return true
        case .source(let source): return session.source == source
        }
    }
}

// MARK: - Agent filter

/// Which agent's conversations the History dialog lists.
enum ChatHistoryAgentFilter: Equatable {
    /// Every conversation, regardless of agent.
    case all
    /// Conversations tagged with this agent (untagged ones count as Default).
    case agent(UUID)
}

/// The avatar for a filter: the agent's own, or a tray glyph for "All Chats".
private struct ChatHistoryAgentFilterAvatar: View {
    let filter: ChatHistoryAgentFilter
    @ObservedObject var agentManager: AgentManager
    let diameter: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        switch filter {
        case .all:
            ZStack {
                Circle().fill(theme.accentColor.opacity(theme.isDark ? 0.18 : 0.12))
                Image(systemName: "tray.full")
                    .font(.system(size: diameter * 0.5, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }
            .frame(width: diameter, height: diameter)
        case .agent(let id):
            let agent = agentManager.agent(for: id)
            AgentAvatarView(
                mascotId: agent?.avatar,
                name: agent?.displayName ?? "",
                tint: agentColorFor(agent?.name ?? ""),
                diameter: diameter,
                customImageURL: agent?.customAvatarURL,
                monogramFontSize: diameter * 0.45,
                borderWidth: 0
            )
        }
    }
}

// MARK: - Agent picker popover

/// Agent chooser for the History dialog, in the model picker's idiom:
/// titled header with a count pill, search field, then one row per agent
/// with its chat count, the active lens marked with a checkmark. "All
/// Chats" is pinned first.
private struct ChatHistoryAgentPicker: View {
    let agents: [Agent]
    let sessions: [ChatSessionData]
    let selected: ChatHistoryAgentFilter
    let onSelect: (ChatHistoryAgentFilter) -> Void

    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared
    @State private var searchText = ""
    /// Tracks IME composition so the placeholder hides while composing.
    @State private var isSearchComposing = false

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredAgents: [Agent] {
        guard isSearching else { return agents }
        return agents.filter { SearchService.matches(query: searchText, in: $0.displayName) }
    }

    /// Chat count per agent id (untagged chats count as Default).
    private var countsByAgent: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for session in sessions {
            counts[session.agentId ?? Agent.defaultId, default: 0] += 1
        }
        return counts
    }

    private static let rowHeight: CGFloat = 40
    private static let chromeHeight: CGFloat = 96

    var body: some View {
        let rows = filteredAgents
        let counts = countsByAgent
        let rowCount = rows.count + (isSearching ? 0 : 1)
        VStack(spacing: 0) {
            header
            Divider().background(theme.primaryBorder.opacity(0.3))
            searchField
            Divider().background(theme.primaryBorder.opacity(0.3))

            if rows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if !isSearching {
                            row(
                                filter: .all,
                                title: Text("All Chats", bundle: .module),
                                count: sessions.count
                            )
                        }
                        ForEach(rows) { agent in
                            row(
                                filter: .agent(agent.id),
                                title: Text(verbatim: agent.displayName),
                                count: counts[agent.id] ?? 0
                            )
                        }
                    }
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(
            width: 300,
            height: min(CGFloat(max(rowCount, 1)) * Self.rowHeight + Self.chromeHeight + 12, 420)
        )
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.primaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [theme.glassEdgeLight.opacity(0.2), theme.primaryBorder.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: theme.shadowColor.opacity(0.15), radius: 12, x: 0, y: 6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Agents", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Text("\(agents.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(theme.secondaryBackground))

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)

            ZStack(alignment: .leading) {
                if searchText.isEmpty && !isSearchComposing {
                    Text("Search agents...", bundle: .module)
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                        .allowsHitTesting(false)
                }
                IMEAwareTextField(
                    text: $searchText,
                    isComposing: $isSearchComposing,
                    font: .systemFont(ofSize: 13),
                    textColor: NSColor(theme.primaryText)
                )
                .frame(height: 17)
            }

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.secondaryBackground.opacity(theme.isDark ? 0.4 : 0.5))
        .animation(.easeOut(duration: 0.15), value: searchText.isEmpty)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundColor(theme.tertiaryText)
            Text("No agents found", bundle: .module)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func row(filter: ChatHistoryAgentFilter, title: Text, count: Int) -> some View {
        AgentPickerRow(
            filter: filter,
            title: title,
            count: count,
            isSelected: filter == selected,
            agentManager: agentManager,
            action: { onSelect(filter) }
        )
    }

    /// One agent row; owns its hover state like the model picker's rows.
    private struct AgentPickerRow: View {
        let filter: ChatHistoryAgentFilter
        let title: Text
        let count: Int
        let isSelected: Bool
        @ObservedObject var agentManager: AgentManager
        let action: () -> Void

        @Environment(\.theme) private var theme
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    ChatHistoryAgentFilterAvatar(filter: filter, agentManager: agentManager, diameter: 22)
                    title
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? theme.accentColor : theme.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isSelected ? theme.accentColor.opacity(0.9) : theme.tertiaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule().fill(
                                isSelected ? theme.accentColor.opacity(0.12) : theme.secondaryBackground)
                        )
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(theme.accentColor)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            isSelected
                                ? theme.accentColor.opacity(0.12)
                                : (isHovering ? theme.tertiaryBackground.opacity(0.7) : Color.clear)
                        )
                )
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovering = hovering
                }
            }
        }
    }
}

// MARK: - Filter popover

/// Filter panel for the History dialog: one flat list of toggles. Origin
/// rows (API, Channel, Self-scheduled, ...) each select or clear the source
/// lens. "Chat" is the default and has no row; Plugin, Workspace, Schedule
/// and Watcher have none either, since the submenus below cover every chat
/// tagged with those origins per plugin / workspace / schedule / watcher.
/// Projects, Workspaces, Plugins and Others are always-present rows that
/// open a nested popover on hover listing the concrete choices. Others
/// holds the capability badges each chat already carries (Search is how a
/// web search chat is found; Vision, Voice, Code likewise; multi-select)
/// followed by every schedule and every watcher. Archived is a toggle at
/// the bottom. Rows carry chat counts. The panel stays open across picks
/// so lenses can be combined; click outside to close.
private struct ChatHistoryFilterPicker: View {
    /// Sessions already narrowed by the agent lens (both archived states).
    let sessions: [ChatSessionData]
    let projects: [Project]
    let workspaces: [OsaurusRouterWorkspaceSummary]
    @Binding var sourceFilter: ChatHistorySourceFilter
    @Binding var pluginFilter: String?
    @Binding var projectFilter: UUID?
    @Binding var workspaceFilter: String?
    @Binding var scheduleFilter: String?
    @Binding var watcherFilter: String?
    @Binding var capabilityFilter: Set<SessionCapability>
    @Binding var showArchived: Bool
    let onClear: () -> Void

    @Environment(\.theme) private var theme
    /// Which submenu row (by id) has its nested popover open. Owned here,
    /// not per row, so hovering one submenu row closes the other first:
    /// two popovers presented from the same window at once is what made
    /// the projects list show up under the Workspaces arrow.
    @State private var openSubmenuId: String?

    /// One lens each row family controls. Counts for a family are taken
    /// with that family's own lens ignored, so a row's number is "how many
    /// chats you would see if you picked this", given every other lens.
    private enum Lens: Hashable {
        case source, plugin, project, workspace, schedule, watcher, capability
    }

    private func passes(_ session: ChatSessionData, ignoring lens: Lens? = nil) -> Bool {
        guard session.archived == showArchived else { return false }
        if lens != .source, !sourceFilter.matches(session) { return false }
        if lens != .plugin, let pluginFilter,
            !(session.source == .plugin && (session.sourcePluginId ?? "") == pluginFilter)
        {
            return false
        }
        if lens != .project, let projectFilter, session.projectId != projectFilter { return false }
        if lens != .workspace, let workspaceFilter, session.workspace?.workspaceId != workspaceFilter {
            return false
        }
        if lens != .schedule, let scheduleFilter,
            !(session.source == .schedule && session.externalSessionKey == scheduleFilter)
        {
            return false
        }
        if lens != .watcher, let watcherFilter,
            !(session.source == .watcher && session.externalSessionKey == watcherFilter)
        {
            return false
        }
        if lens != .capability, !capabilityFilter.isSubset(of: session.capabilities) { return false }
        return true
    }

    private var countsBySource: [SessionSource: Int] {
        var counts: [SessionSource: Int] = [:]
        for session in sessions where passes(session, ignoring: .source) {
            counts[session.source, default: 0] += 1
        }
        return counts
    }

    /// Plugin chats with no recorded id share the "" bucket.
    private var countsByPlugin: [String: Int] {
        var counts: [String: Int] = [:]
        for session in sessions where session.source == .plugin && passes(session, ignoring: .plugin) {
            counts[session.sourcePluginId ?? "", default: 0] += 1
        }
        return counts
    }

    private var countsByProject: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for session in sessions where passes(session, ignoring: .project) {
            if let id = session.projectId { counts[id, default: 0] += 1 }
        }
        return counts
    }

    /// Invite-link shares stamp an empty workspace id and are skipped.
    private var countsByWorkspace: [String: Int] {
        var counts: [String: Int] = [:]
        for session in sessions where passes(session, ignoring: .workspace) {
            if let id = session.workspace?.workspaceId, !id.isEmpty {
                counts[id, default: 0] += 1
            }
        }
        return counts
    }

    private var countsBySchedule: [String: Int] {
        var counts: [String: Int] = [:]
        for session in sessions where session.source == .schedule && passes(session, ignoring: .schedule) {
            if let key = session.externalSessionKey { counts[key, default: 0] += 1 }
        }
        return counts
    }

    private var countsByWatcher: [String: Int] {
        var counts: [String: Int] = [:]
        for session in sessions where session.source == .watcher && passes(session, ignoring: .watcher) {
            if let key = session.externalSessionKey { counts[key, default: 0] += 1 }
        }
        return counts
    }

    /// Per-capability counts; a candidate must also carry the capabilities
    /// already selected, so the number reflects adding this one.
    private var countsByCapability: [SessionCapability: Int] {
        var counts: [SessionCapability: Int] = [:]
        for session in sessions
        where passes(session, ignoring: .capability) && capabilityFilter.isSubset(of: session.capabilities) {
            for cap in session.capabilities { counts[cap, default: 0] += 1 }
        }
        return counts
    }

    private var archivedCount: Int {
        sessions.filter { $0.archived && (showArchived ? passes($0) : passesIgnoringArchive($0)) }.count
    }

    /// `passes` with the archived lens flipped to "archived", for the
    /// Archived row's count while the lens is off.
    private func passesIgnoringArchive(_ session: ChatSessionData) -> Bool {
        var copy = session
        copy.archived = showArchived
        return passes(copy)
    }

    private var activeCount: Int {
        (sourceFilter != .all ? 1 : 0) + (pluginFilter != nil ? 1 : 0) + (projectFilter != nil ? 1 : 0)
            + (workspaceFilter != nil ? 1 : 0) + (scheduleFilter != nil ? 1 : 0)
            + (watcherFilter != nil ? 1 : 0) + capabilityFilter.count + (showArchived ? 1 : 0)
    }

    private static let rowHeight: CGFloat = 36
    private static let chromeHeight: CGFloat = 44

    var body: some View {
        let sourceCounts = countsBySource
        let pluginCounts = countsByPlugin
        let projectCounts = countsByProject
        let workspaceCounts = countsByWorkspace
        let scheduleCounts = countsBySchedule
        let watcherCounts = countsByWatcher
        let capabilityCounts = countsByCapability
        // Declaration order of `SessionSource` keeps the rows stable; a
        // selected bucket stays visible even when its count drops to zero so
        // the user can always deselect it.
        let submenuSources: Set<SessionSource> = [.chat, .plugin, .workspace, .schedule, .watcher]
        let sources = SessionSource.allCases.filter {
            !submenuSources.contains($0) && ((sourceCounts[$0] ?? 0) > 0 || sourceFilter == .source($0))
        }
        // The three submenus list what is installed / defined / joined, not
        // what the chats happen to reference: installed plugins, every
        // project, every workspace Settings knows. Counts may be zero.
        let pluginChoices: [ChatHistorySubmenuChoice] = PluginManager.shared.plugins.map { loaded in
            let id = loaded.plugin.id
            return ChatHistorySubmenuChoice(
                id: id,
                title: PluginDisplayNameResolver.displayName(for: id),
                count: pluginCounts[id] ?? 0
            )
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let projectChoices: [ChatHistorySubmenuChoice] = projects.map { project in
            ChatHistorySubmenuChoice(
                id: project.id.uuidString, title: project.name, count: projectCounts[project.id] ?? 0)
        }
        let workspaceChoices: [ChatHistorySubmenuChoice] = workspaces.map { workspace in
            ChatHistorySubmenuChoice(
                id: workspace.id, title: workspace.name, count: workspaceCounts[workspace.id] ?? 0)
        }
        // "Others": capability badges, then schedules, then watchers, in one
        // list. Ids are prefixed so one submenu can drive three lenses.
        var otherChoices: [ChatHistorySubmenuChoice] = SessionCapability.allCases.map { cap in
            ChatHistorySubmenuChoice(
                id: Self.capabilityPrefix + cap.rawValue,
                title: L(String.LocalizationValue(cap.label)),
                count: capabilityCounts[cap] ?? 0,
                icon: cap.iconName
            )
        }
        otherChoices += ScheduleManager.shared.schedules.map { schedule in
            let key = schedule.id.uuidString
            return ChatHistorySubmenuChoice(
                id: Self.schedulePrefix + key,
                title: schedule.name,
                count: scheduleCounts[key] ?? 0,
                icon: SessionSource.schedule.iconName
            )
        }
        otherChoices += WatcherManager.shared.watchers.map { watcher in
            let key = watcher.id.uuidString
            return ChatHistorySubmenuChoice(
                id: Self.watcherPrefix + key,
                title: watcher.name,
                count: watcherCounts[key] ?? 0,
                icon: SessionSource.watcher.iconName
            )
        }
        var otherSelected: Set<String> = Set(capabilityFilter.map { Self.capabilityPrefix + $0.rawValue })
        if let scheduleFilter { otherSelected.insert(Self.schedulePrefix + scheduleFilter) }
        if let watcherFilter { otherSelected.insert(Self.watcherPrefix + watcherFilter) }
        let rowCount = sources.count + 4 + 1
        VStack(spacing: 0) {
            header
            Divider().background(theme.primaryBorder.opacity(0.3))
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(sources, id: \.self) { source in
                        FilterPickerRow(
                            icon: source.iconName,
                            title: Text(LocalizedStringKey(source.shortLabel), bundle: .module),
                            count: sourceCounts[source] ?? 0,
                            isSelected: sourceFilter == .source(source),
                            action: {
                                withAnimation(theme.animationQuick()) {
                                    sourceFilter = sourceFilter == .source(source) ? .all : .source(source)
                                }
                            }
                        )
                    }


                    FilterSubmenuRow(
                        id: "projects",
                        openId: $openSubmenuId,
                        icon: "folder.fill",
                        title: Text("Projects", bundle: .module),
                        choices: projectChoices,
                        emptyText: Text("No projects yet", bundle: .module),
                        selectedIds: Set(projectFilter.map { [$0.uuidString] } ?? []),
                        onSelect: { id in
                            withAnimation(theme.animationQuick()) {
                                let picked = UUID(uuidString: id)
                                projectFilter = projectFilter == picked ? nil : picked
                            }
                        }
                    )

                    FilterSubmenuRow(
                        id: "workspaces",
                        openId: $openSubmenuId,
                        icon: "rectangle.3.group.fill",
                        title: Text("Workspaces", bundle: .module),
                        choices: workspaceChoices,
                        emptyText: Text("No workspaces joined", bundle: .module),
                        selectedIds: Set(workspaceFilter.map { [$0] } ?? []),
                        onSelect: { id in
                            withAnimation(theme.animationQuick()) {
                                workspaceFilter = workspaceFilter == id ? nil : id
                            }
                        }
                    )
                    FilterSubmenuRow(
                        id: "plugins",
                        openId: $openSubmenuId,
                        icon: SessionSource.plugin.iconName,
                        title: Text("Plugins", bundle: .module),
                        choices: pluginChoices,
                        emptyText: Text("No plugins installed", bundle: .module),
                        selectedIds: Set(pluginFilter.map { [$0] } ?? []),
                        onSelect: { id in
                            withAnimation(theme.animationQuick()) {
                                pluginFilter = pluginFilter == id ? nil : id
                            }
                        }
                    )
                    FilterSubmenuRow(
                        id: "others",
                        openId: $openSubmenuId,
                        icon: "ellipsis.circle.fill",
                        title: Text("Others", bundle: .module),
                        choices: otherChoices,
                        emptyText: Text("Nothing else to filter by", bundle: .module),
                        selectedIds: otherSelected,
                        onSelect: { id in
                            withAnimation(theme.animationQuick()) { toggleOther(id) }
                        }
                    )


                    Divider()
                        .background(theme.primaryBorder.opacity(0.3))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    FilterPickerRow(
                        icon: showArchived ? "archivebox.fill" : "archivebox",
                        title: Text("Archived", bundle: .module),
                        count: archivedCount,
                        isSelected: showArchived,
                        action: {
                            withAnimation(theme.animationQuick()) { showArchived.toggle() }
                        }
                    )
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
        }
        .frame(
            width: 260,
            height: min(CGFloat(rowCount) * Self.rowHeight + Self.chromeHeight + 28, 460)
        )
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.primaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [theme.glassEdgeLight.opacity(0.2), theme.primaryBorder.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: theme.shadowColor.opacity(0.15), radius: 12, x: 0, y: 6)
    }

    private static let capabilityPrefix = "cap:"
    private static let schedulePrefix = "schedule:"
    private static let watcherPrefix = "watcher:"

    /// Routes an "Others" pick to its lens: capabilities accumulate, a
    /// schedule or watcher pick replaces (or clears) the one before.
    private func toggleOther(_ id: String) {
        if id.hasPrefix(Self.capabilityPrefix),
            let cap = SessionCapability(rawValue: String(id.dropFirst(Self.capabilityPrefix.count)))
        {
            if capabilityFilter.contains(cap) { capabilityFilter.remove(cap) } else { capabilityFilter.insert(cap) }
        } else if id.hasPrefix(Self.schedulePrefix) {
            let key = String(id.dropFirst(Self.schedulePrefix.count))
            scheduleFilter = scheduleFilter == key ? nil : key
        } else if id.hasPrefix(Self.watcherPrefix) {
            let key = String(id.dropFirst(Self.watcherPrefix.count))
            watcherFilter = watcherFilter == key ? nil : key
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Filters", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Text("\(activeCount)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(activeCount > 0 ? theme.accentColor : theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(
                        activeCount > 0 ? theme.accentColor.opacity(0.12) : theme.secondaryBackground)
                )

            Spacer()

            if activeCount > 0 {
                Button {
                    withAnimation(theme.animationQuick()) { onClear() }
                } label: {
                    Text("Clear", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// One concrete choice inside a Projects / Workspaces submenu.
private struct ChatHistorySubmenuChoice: Identifiable, Equatable {
    let id: String
    let title: String
    let count: Int
    /// Row glyph; nil falls back to the submenu's own icon.
    var icon: String? = nil
}

/// Shared row chrome for the filter panel and its submenus: icon disc,
/// title, count pill, checkmark when selected. Owns its hover state like
/// the agent picker's rows. `trailing` lets the submenu rows swap the
/// checkmark slot for a chevron.
private struct FilterPickerRow: View {
    let icon: String
    let title: Text
    let count: Int
    let isSelected: Bool
    /// Overrides the trailing checkmark slot (used for the submenu chevron).
    var trailing: AnyView? = nil
    /// Externally forced hover (a submenu row stays lit while its popover
    /// is open, even though the cursor has moved into that popover).
    var isHighlighted: Bool = false
    var onHover: ((Bool) -> Void)? = nil
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(
                        isSelected
                            ? theme.accentColor.opacity(theme.isDark ? 0.18 : 0.12)
                            : theme.secondaryBackground
                    )
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                }
                .frame(width: 22, height: 22)
                title
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? theme.accentColor : theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isSelected ? theme.accentColor.opacity(0.9) : theme.tertiaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule().fill(
                            isSelected ? theme.accentColor.opacity(0.12) : theme.secondaryBackground)
                    )
                if let trailing {
                    trailing
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isSelected
                            ? theme.accentColor.opacity(0.12)
                            : ((isHovering || isHighlighted)
                                ? theme.tertiaryBackground.opacity(0.7) : Color.clear)
                    )
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
            onHover?(hovering)
        }
    }
}

/// A filter row that opens a nested popover of concrete choices (projects
/// or workspaces) when hovered, like a menu's submenu. The nested popover
/// is its own window, so leaving the row to enter it fires the row's
/// hover-off; a short grace timer keeps the submenu open unless neither
/// the row nor the submenu is hovered once it elapses. Clicking the row
/// toggles the submenu for users who prefer not to hover.
///
/// Two guards stop the "presents twice" flicker: opening waits for a short
/// hover dwell (a cursor passing through never presents), and a dismissal
/// that happens while the cursor is still on the row starts a reopen
/// cooldown, because the row re-reports hover the instant the popover
/// window goes away and would otherwise present it again. Dismissals with
/// the cursor elsewhere carry no cooldown, so moving between the submenu
/// rows always opens the one under the cursor.
private struct FilterSubmenuRow: View {
    /// This row's key in `openId`.
    let id: String
    /// The panel-wide "which submenu is open" slot; at most one row owns it.
    @Binding var openId: String?
    let icon: String
    let title: Text
    let choices: [ChatHistorySubmenuChoice]
    /// Shown in the submenu when there is nothing to choose from.
    let emptyText: Text
    /// Choices currently applied (one for single-lens submenus, any number
    /// for Others). The caller decides toggle semantics in `onSelect`.
    let selectedIds: Set<String>
    let onSelect: (String) -> Void

    @Environment(\.theme) private var theme
    @State private var isRowHovered = false
    @State private var isSubmenuHovered = false
    @State private var openTask: Task<Void, Never>?
    @State private var closeTask: Task<Void, Never>?
    /// Hover-driven opens are ignored until this instant (see above).
    @State private var reopenBlockedUntil: Date = .distantPast

    private var isOpen: Bool {
        get { openId == id }
        nonmutating set {
            if newValue {
                openId = id
            } else if openId == id {
                openId = nil
            }
        }
    }

    /// Binding for the popover: closing from the popover side (click
    /// outside, Esc) must only release the slot if this row still owns it.
    private var isOpenBinding: Binding<Bool> {
        Binding(get: { isOpen }, set: { isOpen = $0 })
    }

    private var selectedChoices: [ChatHistorySubmenuChoice] {
        choices.filter { selectedIds.contains($0.id) }
    }

    /// Row title: the single picked option's name, "Title (n)" for several,
    /// else the plain title.
    private var rowTitle: Text {
        let picked = selectedChoices
        if picked.count == 1, let only = picked.first { return Text(verbatim: only.title) }
        if picked.count > 1 { return title + Text(verbatim: " (\(picked.count))") }
        return title
    }

    /// Row pill: how many options the submenu offers, or the picked
    /// option's chat count once exactly one is selected.
    private var rowCount: Int {
        let picked = selectedChoices
        if picked.count == 1, let only = picked.first { return only.count }
        return picked.isEmpty ? choices.count : picked.count
    }

    private static let rowHeight: CGFloat = 36

    var body: some View {
        FilterPickerRow(
            icon: icon,
            title: rowTitle,
            count: rowCount,
            isSelected: !selectedIds.isEmpty,
            trailing: AnyView(
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(!selectedIds.isEmpty ? theme.accentColor : theme.tertiaryText)
            ),
            isHighlighted: isOpen,
            onHover: { hovering in
                isRowHovered = hovering
                if hovering {
                    cancelClose()
                    if !isOpen { scheduleOpen() }
                } else {
                    cancelOpen()
                    scheduleClose()
                }
            },
            action: {
                cancelOpen()
                cancelClose()
                isOpen.toggle()
            }
        )
        .popover(isPresented: isOpenBinding, arrowEdge: .trailing) {
            submenu
                .onHover { hovering in
                    isSubmenuHovered = hovering
                    if hovering { cancelClose() } else { scheduleClose() }
                }
        }
        .onChange(of: isOpen) { _, open in
            guard !open else { return }
            // Covers every dismissal path (grace timer, click outside,
            // choice picked, another submenu taking the slot): settle the
            // hover bookkeeping.
            cancelOpen()
            cancelClose()
            isSubmenuHovered = false
            // The reopen loop only happens when the popover goes away while
            // the cursor is still on this row (it re-reports hover at once).
            // A dismissal with the cursor elsewhere, such as sliding onto a
            // sibling submenu row, must not block coming straight back.
            if isRowHovered {
                reopenBlockedUntil = Date().addingTimeInterval(0.3)
            }
        }
    }

    private var submenu: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if choices.isEmpty {
                    emptyText
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
                        .padding(.horizontal, 12)
                }
                ForEach(choices) { choice in
                    FilterPickerRow(
                        icon: choice.icon ?? icon,
                        title: Text(verbatim: choice.title),
                        count: choice.count,
                        isSelected: selectedIds.contains(choice.id),
                        action: {
                            onSelect(choice.id)
                            isOpen = false
                        }
                    )
                }
            }
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .frame(
            width: 240,
            height: min(CGFloat(max(choices.count, 1)) * Self.rowHeight + 12, 360)
        )
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.primaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [theme.glassEdgeLight.opacity(0.2), theme.primaryBorder.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: theme.shadowColor.opacity(0.15), radius: 12, x: 0, y: 6)
    }

    private func cancelOpen() {
        openTask?.cancel()
        openTask = nil
    }

    private func cancelClose() {
        closeTask?.cancel()
        closeTask = nil
    }

    /// Presents after a short dwell, and only if the cursor is still on the
    /// row and no dismissal happened a moment ago.
    ///
    /// Taking the slot over from a sibling is sequenced: release it first,
    /// wait for that popover to finish dismissing, then present. Flipping
    /// one popover off and another on in the same SwiftUI transaction is
    /// unreliable on macOS: the new one is often dropped while the old one
    /// animates out, leaving the slot marked open with nothing on screen.
    private func scheduleOpen() {
        guard openTask == nil, Date() >= reopenBlockedUntil else { return }
        openTask = Task { @MainActor in
            // A cancelled task was already detached by cancelOpen (and the
            // handle may now belong to a newer task), so only a task that
            // ran to its own exit clears the handle.
            defer { if !Task.isCancelled { openTask = nil } }
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, isRowHovered, !isOpen else { return }
            if openId != nil {
                openId = nil
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled, isRowHovered, openId == nil else { return }
            }
            if Date() >= reopenBlockedUntil { isOpen = true }
        }
    }

    /// Closes the submenu unless the cursor lands on the row or the
    /// submenu within the grace period (it needs a moment to cross the
    /// gap between the two windows).
    private func scheduleClose() {
        closeTask?.cancel()
        closeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            if !isRowHovered && !isSubmenuHovered { isOpen = false }
        }
    }
}
