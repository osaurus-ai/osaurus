//
//  ChatHistoryPane.swift
//  osaurus
//
//  History pane of the chat inspector: the past chats of the agent behind
//  the tab on screen, with search, the Filter popover (origin, project,
//  workspace, plugin, capability, archived), New Chat and Import. Like the
//  File Changes pane beside it, it is scoped by the current tab — so it
//  needs no agent picker; the header names the scope instead. Tapping a
//  row loads that conversation in the current tab; the rail stays up.
//

import AppKit
import SwiftUI

/// The row actions a chat window gives a `ChatHistoryList`: the History
/// pane and the project view host the same list, so they share one set of
/// handlers that keep the window's live session in step with the store.
struct ChatHistoryWindowActions {
    let windowState: ChatWindowState
    let scope: ThemedAlertScope

    @MainActor
    func delete(_ id: UUID) {
        // Cancel a registry-owned run, detach this window, then delete.
        if let liveTask = BackgroundTaskManager.shared.liveTask(forSessionId: id) {
            BackgroundTaskManager.shared.cancelTask(liveTask.id)
        }
        windowState.prepareForSessionDeletion(id: id)
        ChatSessionsManager.shared.delete(id: id)
        windowState.refreshSessions()
    }

    @MainActor
    func rename(_ id: UUID, _ title: String) {
        ChatSessionsManager.shared.rename(id: id, title: title)
        if windowState.session.sessionId == id { windowState.session.title = title }
        windowState.refreshSessions()
    }

    @MainActor
    func setArchived(_ id: UUID, _ archived: Bool) {
        ChatSessionsManager.shared.setArchived(id: id, archived: archived)
        if windowState.session.sessionId == id { windowState.session.archived = archived }
        windowState.refreshSessions()
    }

    @MainActor
    func setPinned(_ id: UUID, _ pinned: Bool) {
        ChatSessionsManager.shared.setPinned(id: id, pinned: pinned)
        if windowState.session.sessionId == id { windowState.session.pinned = pinned }
        windowState.refreshSessions()
    }

    @MainActor
    func setProject(_ id: UUID, _ projectId: UUID?) {
        ChatSessionsManager.shared.setProject(id: id, projectId: projectId)
        if windowState.session.sessionId == id { windowState.session.projectId = projectId }
        windowState.refreshSessions()
    }

    @MainActor
    func export(_ metadata: ChatSessionData, _ format: ChatSessionSidebar.ExportFormat) {
        ChatSessionExportCoordinator.run(metadataSession: metadata, format: format, scope: scope)
    }

    @MainActor
    func stop(_ id: UUID) {
        if windowState.session.sessionId == id {
            windowState.session.stop()
        } else {
            SessionActivityMonitor.shared.stop(sessionId: id)
        }
    }

    @MainActor
    func openInNewWindow(_ data: ChatSessionData) {
        ChatWindowManager.shared.createWindow(agentId: data.agentId, sessionData: data)
    }
}

/// History pane content. Row actions raise their own alerts (delete
/// confirmation, export chooser + progress, import guide) through the
/// window's `ThemedAlertScope`, so they present over the whole window.
struct ChatHistoryPaneView: View {
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

    /// Origin lens (Chat / Plugin / Schedule / ...), picked in the Filter
    /// popover. Composes with the archived toggle there.
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

    /// The current tab's agent's chats (untagged ones count as the Default
    /// agent), both archived states; `ChatHistoryList` applies the lenses.
    private var visibleSessions: [ChatSessionData] {
        sessionsManager.sessions.filter { ($0.agentId ?? Agent.defaultId) == windowState.agentId }
    }

    private var agent: Agent? { agentManager.agent(for: windowState.agentId) }

    private var actions: ChatHistoryWindowActions {
        ChatHistoryWindowActions(windowState: windowState, scope: scope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: the scope on the left (whose chats these are — the
            // agent of the tab on screen), New Chat and Import on the
            // right. Same row the File Changes pane puts its summary in.
            HStack(spacing: 4) {
                scopeLabel
                Spacer(minLength: 8)
                SidebarHeaderIconButton(icon: "square.and.pencil", help: "New Chat") {
                    windowState.startNewChat()
                }
                SidebarHeaderIconButton(icon: "square.and.arrow.down", help: "Import Conversations") {
                    requestImport()
                }
                .accessibilityLabel(Text("Import Conversations", bundle: .module))
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .padding(.bottom, 8)
            .frame(minHeight: 32)

            ChatHistoryList(
                sessions: visibleSessions,
                currentSessionId: windowState.session.sessionId,
                scope: scope,
                onSelect: onSelect,
                onDelete: actions.delete,
                onRename: actions.rename,
                onSetArchived: actions.setArchived,
                onSetPinned: actions.setPinned,
                onSetProject: actions.setProject,
                onExport: actions.export,
                onStop: actions.stop,
                onOpenInNewWindow: actions.openInNewWindow,
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
                onClearFilters: clearFilters,
                listMaxHeight: nil,
                searchAccessory: AnyView(filterButton)
            )
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        // Switching agents is a context change: the lenses belong to the
        // previous agent's list.
        .onChange(of: windowState.agentId) { _, _ in
            clearFilters()
        }
        // Unarchiving the last archived chat: make sure the lens does not
        // stay stuck on an empty, now-pointless state.
        .onChange(of: visibleSessions.contains(where: \.archived)) { _, hasArchived in
            if !hasArchived { showArchived = false }
        }
    }

    // MARK: - Scope label

    /// Avatar + agent name + "· N chats": a static indicator of what the
    /// list is scoped to, not a control (pick agents in the sidebar).
    private var scopeLabel: some View {
        HStack(spacing: 6) {
            AgentAvatarView(
                mascotId: agent?.avatar,
                name: agent?.displayName ?? "",
                tint: agentColorFor(agent?.name ?? ""),
                diameter: 16,
                customImageURL: agent?.customAvatarURL,
                monogramFontSize: 7,
                borderWidth: 0
            )
            Text(verbatim: agent?.displayName ?? windowState.cachedAgentDisplayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(verbatim: "· " + L("\(visibleSessions.filter { !$0.archived }.count) chats"))
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
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

    /// Opens the filter popover, beside the search field. Switches to the
    /// accent tint + filled glyph while any lens is active.
    private var filterButton: some View {
        let isActive = activeFilterCount > 0
        let isRaised = isActive || isFilterButtonHovered || showSourcePicker
        return Button {
            showSourcePicker.toggle()
        } label: {
            HStack(alignment: .center, spacing: 4) {
                Image(
                    systemName: isActive
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle"
                )
                .font(.system(size: 12, weight: .medium))
                if isActive {
                    Text(verbatim: "\(activeFilterCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                }
            }
            .foregroundColor(isActive ? theme.accentColor : (isRaised ? theme.primaryText : theme.secondaryText))
            .padding(.horizontal, 7)
            // Matches the search field's height so the row reads as one.
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: SidebarStyle.searchFieldCornerRadius, style: .continuous)
                    .fill(
                        isActive
                            ? theme.accentColor.opacity(theme.isDark ? 0.18 : 0.12)
                            : (theme.isDark
                                ? theme.primaryBackground.opacity(0.5) : theme.tertiaryBackground.opacity(0.8)))
            )
            .contentShape(Rectangle())
            .pointingHandCursor()
        }
        .buttonStyle(.plain)
        .onHover { isFilterButtonHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isFilterButtonHovered)
        .localizedHelp("Filter chats by source, project, or archived state")
        .accessibilityLabel(filterAccessibilityLabel)
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

    private var filterAccessibilityLabel: Text {
        if activeFilterCount == 0 { return Text("Filter", bundle: .module) }
        return Text("Filter (\(activeFilterCount))", bundle: .module)
    }

    /// Same Import flow the sidebar always had: first-time provider guide,
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

// MARK: - Filter popover

/// Filter panel for the History pane: one flat list of toggles. Origin
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
    /// The selected agent's sessions (both archived states).
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
    /// Tallest the list may grow before it scrolls.
    private static let maxListHeight: CGFloat = 400

    /// Measured heights of the header and the list content. The panel is
    /// sized from these rather than from an estimate: an estimate a few
    /// points short leaves the list scrollable by that much and shows a
    /// scroll bar for nothing.
    @State private var headerHeight: CGFloat = 0
    @State private var listHeight: CGFloat = 0

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
        let otherChoices = makeOtherChoices(
            sourceCounts: sourceCounts,
            capabilityCounts: capabilityCounts,
            scheduleCounts: scheduleCounts,
            watcherCounts: watcherCounts
        )
        let otherSelected = otherSelectedIds
        let rowCount = sources.count + 4 + 1
        // Estimate used only until the first measurement lands.
        let estimatedHeight = CGFloat(rowCount) * Self.rowHeight + Self.chromeHeight + 28
        let measuredHeight = headerHeight + 1 + min(listHeight, Self.maxListHeight)
        VStack(spacing: 0) {
            header
                .measureHeight($headerHeight)
            Divider().background(theme.primaryBorder.opacity(0.3))
            ScrollView {
                VStack(spacing: 2) {
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
                .measureHeight($listHeight)
            }
            .scrollIndicators(.automatic)
        }
        .frame(
            width: 260,
            height: listHeight > 0 && headerHeight > 0 ? measuredHeight : min(estimatedHeight, 460)
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
    private static let sourcePrefix = "source:"
    private static let schedulePrefix = "schedule:"
    private static let watcherPrefix = "watcher:"

    /// "Others", in one list: the capability badges (Web Search, Code,
    /// Vision, Voice), then the always-present "Scheduled" and "Watchers"
    /// origin toggles (any schedule / any watcher), then every schedule and
    /// every watcher by name for narrowing to one. Ids are prefixed so one
    /// submenu can drive four lenses.
    private func makeOtherChoices(
        sourceCounts: [SessionSource: Int],
        capabilityCounts: [SessionCapability: Int],
        scheduleCounts: [String: Int],
        watcherCounts: [String: Int]
    ) -> [ChatHistorySubmenuChoice] {
        var choices: [ChatHistorySubmenuChoice] = SessionCapability.allCases.map { cap in
            // The badge is called "Search" elsewhere (it is set by any search
            // tool); here it stands for web search, which is what users look for.
            let isWeb = cap == .search
            return ChatHistorySubmenuChoice(
                id: Self.capabilityPrefix + cap.rawValue,
                title: isWeb ? L("Web Search") : L(String.LocalizationValue(cap.label)),
                count: capabilityCounts[cap] ?? 0,
                icon: isWeb ? "globe" : cap.iconName
            )
        }
        choices.append(
            ChatHistorySubmenuChoice(
                id: Self.sourcePrefix + SessionSource.schedule.rawValue,
                title: L("Scheduled"),
                count: sourceCounts[.schedule] ?? 0,
                icon: SessionSource.schedule.iconName
            )
        )
        choices.append(
            ChatHistorySubmenuChoice(
                id: Self.sourcePrefix + SessionSource.watcher.rawValue,
                title: L("Watchers"),
                count: sourceCounts[.watcher] ?? 0,
                icon: SessionSource.watcher.iconName
            )
        )
        choices += ScheduleManager.shared.schedules.map { schedule in
            let key = schedule.id.uuidString
            return ChatHistorySubmenuChoice(
                id: Self.schedulePrefix + key,
                title: schedule.name,
                count: scheduleCounts[key] ?? 0,
                icon: SessionSource.schedule.iconName
            )
        }
        choices += WatcherManager.shared.watchers.map { watcher in
            let key = watcher.id.uuidString
            return ChatHistorySubmenuChoice(
                id: Self.watcherPrefix + key,
                title: watcher.name,
                count: watcherCounts[key] ?? 0,
                icon: SessionSource.watcher.iconName
            )
        }
        return choices
    }

    /// The "Others" entries currently applied, in the submenu's id space.
    private var otherSelectedIds: Set<String> {
        var ids = Set(capabilityFilter.map { Self.capabilityPrefix + $0.rawValue })
        if case .source(let source) = sourceFilter, source == .schedule || source == .watcher {
            ids.insert(Self.sourcePrefix + source.rawValue)
        }
        if let scheduleFilter { ids.insert(Self.schedulePrefix + scheduleFilter) }
        if let watcherFilter { ids.insert(Self.watcherPrefix + watcherFilter) }
        return ids
    }

    /// Routes an "Others" pick to its lens: capabilities accumulate, a
    /// schedule or watcher pick replaces (or clears) the one before.
    private func toggleOther(_ id: String) {
        if id.hasPrefix(Self.capabilityPrefix),
            let cap = SessionCapability(rawValue: String(id.dropFirst(Self.capabilityPrefix.count)))
        {
            if capabilityFilter.contains(cap) { capabilityFilter.remove(cap) } else { capabilityFilter.insert(cap) }
        } else if id.hasPrefix(Self.sourcePrefix),
            let source = SessionSource(rawValue: String(id.dropFirst(Self.sourcePrefix.count)))
        {
            sourceFilter = sourceFilter == .source(source) ? .all : .source(source)
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
        // Automatic, not hidden: the bar appears only when the list is
        // taller than the cap. The frame matches the content exactly (rows
        // + 2pt spacing between them + 6pt padding top and bottom), so a
        // list that fits never scrolls and never shows a bar.
        .scrollIndicators(.automatic)
        .frame(
            width: 240,
            height: min(Self.contentHeight(rows: max(choices.count, 1)), 360)
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

    /// Exact height of `rows` submenu rows as laid out by `submenu`.
    private static func contentHeight(rows: Int) -> CGFloat {
        CGFloat(rows) * rowHeight + CGFloat(max(rows - 1, 0)) * 2 + 12
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

// MARK: - Height measurement

extension View {
    /// Reports this view's laid-out height into `height` (initially and on
    /// every change) without affecting its layout.
    fileprivate func measureHeight(_ height: Binding<CGFloat>) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { height.wrappedValue = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, new in height.wrappedValue = new }
            }
        )
    }
}
