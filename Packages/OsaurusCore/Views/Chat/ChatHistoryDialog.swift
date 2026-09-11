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

    /// Which agent's chats the list shows. nil until the user picks one,
    /// so the initial lens tracks the window's agent (see `activeFilter`).
    @State private var agentFilter: ChatHistoryAgentFilter?
    @State private var showAgentPicker = false
    @State private var isAgentButtonHovered = false

    /// Origin lens (Chat / Plugin / Schedule / ...), picked in the Filter
    /// popover. Composes with the agent lens and the archived chip.
    @State private var sourceFilter: ChatHistorySourceFilter = .all
    /// Project lens, also picked in the Filter popover.
    @State private var projectFilter: ChatHistoryProjectFilter = .all
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
                onClearFilters: {
                    sourceFilter = .all
                    projectFilter = .all
                    showArchived = false
                }
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

    /// Number of lenses the popover currently applies (source, project,
    /// archived). Shown on the button so a narrowed list is never a surprise.
    private var activeFilterCount: Int {
        (sourceFilter != .all ? 1 : 0) + (projectFilter != .all ? 1 : 0) + (showArchived ? 1 : 0)
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
                sourceFilter: $sourceFilter,
                projectFilter: $projectFilter,
                showArchived: $showArchived
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

/// Which project the listed conversations belong to.
enum ChatHistoryProjectFilter: Equatable {
    /// Every conversation, in a project or not.
    case all
    /// Conversations not assigned to any project.
    case none
    /// Conversations in this project.
    case project(UUID)

    func matches(_ session: ChatSessionData) -> Bool {
        switch self {
        case .all: return true
        case .none: return session.projectId == nil
        case .project(let id): return session.projectId == id
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

/// Filter panel for the History dialog, in the agent picker's idiom: a
/// Source section ("All" + one row per origin present in the lens), a
/// Project section ("Any" + "No Project" + one row per project with
/// chats), and an Archived toggle. Rows carry chat counts; empty buckets
/// are hidden so the panel never offers dead choices. The popover stays
/// open across picks so lenses can be combined; click outside to close.
private struct ChatHistoryFilterPicker: View {
    /// Sessions already narrowed by the agent lens (both archived states).
    let sessions: [ChatSessionData]
    let projects: [Project]
    @Binding var sourceFilter: ChatHistorySourceFilter
    @Binding var projectFilter: ChatHistoryProjectFilter
    @Binding var showArchived: Bool

    @Environment(\.theme) private var theme

    /// Sessions in the archived lens; counts are taken against these so
    /// they match what the list will actually show.
    private var lensSessions: [ChatSessionData] {
        sessions.filter { $0.archived == showArchived }
    }

    private var countsBySource: [SessionSource: Int] {
        var counts: [SessionSource: Int] = [:]
        for session in lensSessions where projectFilter.matches(session) {
            counts[session.source, default: 0] += 1
        }
        return counts
    }

    private var countsByProject: [UUID?: Int] {
        var counts: [UUID?: Int] = [:]
        for session in lensSessions where sourceFilter.matches(session) {
            counts[session.projectId, default: 0] += 1
        }
        return counts
    }

    private var archivedCount: Int {
        sessions.filter { $0.archived && sourceFilter.matches($0) && projectFilter.matches($0) }.count
    }

    private var activeCount: Int {
        (sourceFilter != .all ? 1 : 0) + (projectFilter != .all ? 1 : 0) + (showArchived ? 1 : 0)
    }

    private static let rowHeight: CGFloat = 36
    private static let sectionHeaderHeight: CGFloat = 26
    private static let chromeHeight: CGFloat = 44

    var body: some View {
        let sourceCounts = countsBySource
        let projectCounts = countsByProject
        // Declaration order of `SessionSource` keeps the rows stable; a
        // selected bucket stays visible even when its count drops to zero so
        // the user can always deselect it.
        let sources = SessionSource.allCases.filter {
            (sourceCounts[$0] ?? 0) > 0 || sourceFilter == .source($0)
        }
        let visibleProjects = projects.filter {
            (projectCounts[$0.id] ?? 0) > 0 || projectFilter == .project($0.id)
        }
        let showNoProject = (projectCounts[nil] ?? 0) > 0 || projectFilter == .none
        let rowCount = 1 + sources.count + 1 + (showNoProject ? 1 : 0) + visibleProjects.count + 1
        VStack(spacing: 0) {
            header
            Divider().background(theme.primaryBorder.opacity(0.3))
            ScrollView {
                LazyVStack(spacing: 2) {
                    sectionHeader(Text("Source", bundle: .module))
                    FilterPickerRow(
                        icon: "tray.full",
                        title: Text("All", bundle: .module),
                        count: lensSessions.filter { projectFilter.matches($0) }.count,
                        isSelected: sourceFilter == .all,
                        action: { pickSource(.all) }
                    )
                    ForEach(sources, id: \.self) { source in
                        FilterPickerRow(
                            icon: source.iconName,
                            title: Text(LocalizedStringKey(source.shortLabel), bundle: .module),
                            count: sourceCounts[source] ?? 0,
                            isSelected: sourceFilter == .source(source),
                            action: { pickSource(.source(source)) }
                        )
                    }

                    sectionHeader(Text("Project", bundle: .module))
                        .padding(.top, 6)
                    FilterPickerRow(
                        icon: "folder",
                        title: Text("Any", bundle: .module),
                        count: lensSessions.filter { sourceFilter.matches($0) }.count,
                        isSelected: projectFilter == .all,
                        action: { pickProject(.all) }
                    )
                    if showNoProject {
                        FilterPickerRow(
                            icon: "folder.badge.minus",
                            title: Text("No Project", bundle: .module),
                            count: projectCounts[nil] ?? 0,
                            isSelected: projectFilter == .none,
                            action: { pickProject(.none) }
                        )
                    }
                    ForEach(visibleProjects) { project in
                        FilterPickerRow(
                            icon: "folder.fill",
                            title: Text(verbatim: project.name),
                            count: projectCounts[project.id] ?? 0,
                            isSelected: projectFilter == .project(project.id),
                            action: { pickProject(.project(project.id)) }
                        )
                    }

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
            height: min(
                CGFloat(rowCount) * Self.rowHeight + 2 * Self.sectionHeaderHeight + Self.chromeHeight + 28,
                460
            )
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

    private func pickSource(_ filter: ChatHistorySourceFilter) {
        withAnimation(theme.animationQuick()) { sourceFilter = filter }
    }

    private func pickProject(_ filter: ChatHistoryProjectFilter) {
        withAnimation(theme.animationQuick()) { projectFilter = filter }
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
                    withAnimation(theme.animationQuick()) {
                        sourceFilter = .all
                        projectFilter = .all
                        showArchived = false
                    }
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

    private func sectionHeader(_ title: Text) -> some View {
        title
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(theme.tertiaryText)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    /// One filter row; owns its hover state like the agent picker's rows.
    private struct FilterPickerRow: View {
        let icon: String
        let title: Text
        let count: Int
        let isSelected: Bool
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
                    if isSelected {
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
