//
//  ChatSessionSidebar.swift
//  osaurus
//
//  Sidebar showing chat session history
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
    /// The window's currently-active agent. Tracked so the sidebar can
    /// reset its filter / search state when the user switches agents
    /// (or adopts a new one via `loadSession`); without this, a filter
    /// applied in agent A would persist into agent B and surface a
    /// confusing "no results" empty state.
    let agentId: UUID
    let currentSessionId: UUID?
    /// Live width of the rail, driven by the parent's resize handle so the
    /// inner content (titles, chips, rows) reflows to fill the chosen width.
    var width: CGFloat = SidebarStyle.width
    let onSelect: (ChatSessionData) -> Void
    /// Start a new chat. The argument is the sidebar's selected project id
    /// (nil when no project lens is active) so the fresh chat lands in the
    /// project the user is currently looking at.
    let onNewChat: (UUID?) -> Void
    let onDelete: (UUID) -> Void
    let onRename: (UUID, String) -> Void
    let onSetArchived: (UUID, Bool) -> Void
    let onSetPinned: (UUID, Bool) -> Void
    /// Move a session into a project (nil = remove from its project).
    let onSetProject: (UUID, UUID?) -> Void
    /// Delete a project: detaches member sessions, then removes the record.
    let onDeleteProject: (UUID) -> Void
    /// Open a project's detail page in the window's content area.
    var onOpenProject: ((Project) -> Void)? = nil
    let onExport: (ChatSessionData, ExportFormat) -> Void
    /// Stop the live run driving the given session id. Rows only offer the
    /// control while `SessionActivityMonitor` reports the session active.
    var onStop: ((UUID) -> Void)? = nil
    /// Optional callback for opening a session in a new window
    var onOpenInNewWindow: ((ChatSessionData) -> Void)? = nil
    /// Open the session in a new tab of this window (browser-style).
    var onOpenInNewTab: ((ChatSessionData) -> Void)? = nil
    /// Select an agent for this window (agents-focused sidebar prototype —
    /// replaces the removed agent-selector pill; same effect as picking an
    /// agent from it).
    var onSelectAgent: ((UUID) -> Void)? = nil

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
    /// Freshly imported session ids; their rows glow briefly and the list
    /// scrolls the first one into view so the user can see where the
    /// imports landed (they sort by original date, not to the top).
    @ObservedObject private var importHighlight = ChatSessionImportHighlight.shared
    @State private var editingSessionId: UUID?
    @State private var editingBuffer: String = ""
    /// IDs the user has multi-selected (⌘-click to toggle, ⇧-click to
    /// range-select). Empty means normal single-select navigation is active.
    @State private var selectedIds: Set<UUID> = []
    /// The row a ⇧-click range extends from. Set on every plain or ⌘ click.
    @State private var selectionAnchorId: UUID?
    @State private var searchQuery: String = ""
    @State private var isFooterHovered = false
    @State private var sourceFilter: SourceFilter = .all
    @State private var hoveredFilter: SourceFilter?
    /// Top-level sidebar lens: the flat chat list or the project browser.
    @State private var selectedTab: SidebarTab = .chats

    enum SidebarTab: Hashable {
        case chats
        case projects
    }
    /// Sessions whose message bodies match the current search query,
    /// resolved asynchronously against the chat-history database (debounced
    /// per keystroke). Merged with the synchronous title/metadata matching in
    /// `filteredSessions` so search covers conversation content, not just
    /// titles.
    @State private var contentMatchedSessionIds: Set<UUID> = []
    @State private var contentSearchTask: Task<Void, Never>?
    /// True from query change until its (debounced) database lookup returns.
    /// Drives the search field's trailing spinner.
    @State private var isContentSearchInFlight: Bool = false
    @FocusState private var isSearchFocused: Bool

    // MARK: - Source Filter

    /// Sidebar-local filter for `SessionSource` plus the archive lens.
    /// Composes with the search query and the agent filter applied by the
    /// caller. `.archived` is exclusive: it ignores source and shows only
    /// archived sessions; every other case hides archived sessions.
    enum SourceFilter: Hashable {
        case all
        case source(SessionSource)
        case archived

        var label: String {
            switch self {
            case .all: return "All"
            case .source(let s): return s.shortLabel
            case .archived: return "Archived"
            }
        }
    }

    private static let allSourceFilters: [SourceFilter] = [
        .all,
        .source(.chat),
        .source(.plugin),
        .source(.http),
        .source(.channel),
        .source(.schedule),
        .source(.watcher),
        .source(.selfSchedule),
        .source(.imported),
        .archived,
    ]

    // MARK: - Computed Properties

    /// Sessions after applying source/archive filter and search query.
    private var filteredSessions: [ChatSessionData] {
        let byFilter: [ChatSessionData]
        switch sourceFilter {
        case .all:
            byFilter = sessions.filter { !$0.archived }
        case .source(let s):
            byFilter = sessions.filter { $0.source == s && !$0.archived }
        case .archived:
            byFilter = sessions.filter { $0.archived }
        }
        guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            return orderedForDisplay(byFilter)
        }
        let matched = byFilter.filter { session in
            if SearchService.matches(query: searchQuery, in: session.title) { return true }
            if let key = session.externalSessionKey,
                SearchService.matches(query: searchQuery, in: key)
            {
                return true
            }
            // Full-text match over message bodies, resolved asynchronously
            // into `contentMatchedSessionIds`.
            if contentMatchedSessionIds.contains(session.id) { return true }
            // Match capability labels so "vision" / "code" finds tagged chats.
            return session.capabilities.contains { cap in
                SearchService.matches(query: searchQuery, in: cap.label)
            }
        }
        return orderedForDisplay(matched)
    }

    /// Stable partition floating active (running / waiting-for-input)
    /// sessions to the very top, then pinned sessions, while preserving the
    /// incoming (recency-descending) order within each group. Display-only:
    /// `updatedAt` and persistence are untouched. The `.archived` lens keeps
    /// its own order — pins/activity are a default-view concern — but
    /// partitioning there too is harmless and keeps the rule uniform.
    private func orderedForDisplay(_ list: [ChatSessionData]) -> [ChatSessionData] {
        SessionActivityOrdering.ordered(
            list,
            activeIds: Set(activityMonitor.statuses.keys)
        )
    }

    /// Debounced full-text lookup for the search query. The in-memory
    /// sessions carry metadata only (turns are never loaded for the list), so
    /// content matching goes to the chat-history database.
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
            // Debounce so fast typing doesn't scan the database per keystroke.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let ids = await ChatSessionStore.sessionIds(withContentContaining: trimmed)
            // A cancelled task must not clear the flag owned by its successor.
            guard !Task.isCancelled else { return }
            contentMatchedSessionIds = ids
            isContentSearchInFlight = false
        }
    }

    /// Source-filter chips shown above the list. Hides chips with no
    /// matching sessions so the rail does not render dead buckets.
    /// `.all` is always shown; `.archived` only when the agent has at
    /// least one archived session.
    private var visibleSourceFilters: [SourceFilter] {
        let activeSources = Set(sessions.filter { !$0.archived }.map(\.source))
        let hasArchived = sessions.contains { $0.archived }
        return Self.allSourceFilters.filter { filter in
            switch filter {
            case .all: return true
            case .source(let s): return activeSources.contains(s)
            case .archived: return hasArchived
            }
        }
    }

    var body: some View {
        SidebarContainer(attachedEdge: .leading, topPadding: 40, width: width) {
            // Chats | Projects lens switcher, above the section header so
            // the lens is the first thing the eye lands on. As the first
            // child it owns the window-control clearance the header used to
            // provide (the container's 40pt only clears the traffic lights).
            sidebarTabBar
                // Tour spotlight anchor (invisible; reports the lens bar's frame).
                .background(TourAnchorMarker(anchor: .sidebarLensBar))
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 12)

            // Header with New Chat button
            sidebarHeader

            if selectedTab == .projects {
                // Project browser: one row per project; opening one shows
                // the project detail page in the window's content area.
                projectListView
            } else {
                // Prototype: agents-focused sidebar. One row per agent;
                // tapping selects it for this window (what the removed
                // agent-selector pill used to do). The chat-history UI
                // (search, filters, session list) is parked, unreferenced,
                // pending the next iteration of this idea.
                agentListView
            }

            // Settings lives at the foot of the sidebar (moved out of the
            // title bar so it stays tabs + chat controls).
            sidebarFooter
        }
        // Adopting a new agent (via the dropdown's switchAgent or the
        // sidebar's loadSession) is a context change — wipe per-window
        // filter state so the new agent starts on "All" with an empty
        // search instead of inheriting the previous agent's lens.
        .animation(theme.animationQuick(), value: selectedIds)
        .onChange(of: searchQuery) { _, query in
            scheduleContentSearch(query)
        }
        .onChange(of: agentId) { _, _ in
            sourceFilter = .all
            searchQuery = ""
            hoveredFilter = nil
            selectedTab = .chats
            clearSelection()
        }
        // Switching lenses is a context change like an agent switch: the
        // inner filter/search/selection state belongs to the previous lens.
        .onChange(of: selectedTab) { _, _ in
            sourceFilter = .all
            searchQuery = ""
            hoveredFilter = nil
            clearSelection()
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

    private func revealProjectsTab() {
        DispatchQueue.main.async {
            selectedTab = .projects
            projectManager.pendingRevealProjectsTab = false
        }
    }

    // MARK: - Tab Bar

    /// Two-segment lens switcher styled like the source filter chips:
    /// equal-width segments, accent-tinted when selected.
    private var sidebarTabBar: some View {
        HStack(spacing: 4) {
            // Prototype: the primary lens lists AGENTS (the `.chats` case is
            // kept as the enum value to avoid churning all the lens-reset
            // logic while the idea is validated).
            tabSegment(.chats, label: "Agents", icon: "person.2")
            tabSegment(.projects, label: "Projects", icon: "folder")
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.secondaryBackground.opacity(theme.isDark ? 0.4 : 0.5))
        )
    }

    private func tabSegment(_ tab: SidebarTab, label: String, icon: String) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(theme.animationQuick()) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(LocalizedStringKey(label), bundle: .module)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
            }
            .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? theme.accentColor.opacity(theme.isDark ? 0.28 : 0.18) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Project List

    /// The Projects tab's top level: one row per project. Tapping a row
    /// drills into that project's chats.
    private var projectListView: some View {
        Group {
            if projectManager.projects.isEmpty {
                projectsEmptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(projectManager.projects) { project in
                            ProjectRow(
                                project: project,
                                sessionCount: sessions.filter { $0.projectId == project.id }.count,
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

    /// Empty state for the Projects tab. Mirrors the Chats tab's
    /// `emptyState` (centered icon + label) for visual consistency; the
    /// explainer of what a project is lives in the New Project dialog.
    private var projectsEmptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "folder")
                .font(.system(size: 28))
                .foregroundColor(theme.secondaryText.opacity(0.5))
            Text("No projects yet", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity)
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

    // MARK: - Source Filter Rail

    private var sourceFilterRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(visibleSourceFilters, id: \.self) { filter in
                    sourceFilterChip(filter)
                }
            }
        }
    }

    /// Capsule pill chip styled to match `AgentPill` in the chat header:
    /// ghost (transparent) when unselected, accent-tinted when selected,
    /// with a subtle hover fill to telegraph clickability. Source chips
    /// also surface their `SessionSource.iconName` so the rail is
    /// glanceable in the same way the per-row source badge is.
    private func sourceFilterChip(_ filter: SourceFilter) -> some View {
        let isSelected = sourceFilter == filter
        let isHovered = hoveredFilter == filter
        let shape = Capsule(style: .continuous)
        return Button {
            withAnimation(theme.animationQuick()) {
                sourceFilter = filter
            }
        } label: {
            chipLabel(filter, isSelected: isSelected)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(shape.fill(chipFill(isSelected: isSelected, isHovered: isHovered)))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredFilter = filter
            } else if hoveredFilter == filter {
                // Guard prevents a stale `false` callback (after the cursor
                // already moved onto another chip and set `hoveredFilter`
                // to that one) from clearing the new hover.
                hoveredFilter = nil
            }
        }
    }

    @ViewBuilder
    private func chipLabel(_ filter: SourceFilter, isSelected: Bool) -> some View {
        HStack(spacing: 4) {
            if case .source(let s) = filter {
                Image(systemName: s.iconName)
                    .font(.system(size: 9.5, weight: .semibold))
            } else if case .archived = filter {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 9.5, weight: .semibold))
            }
            Text(LocalizedStringKey(filter.label), bundle: .module)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
        }
        .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
    }

    /// Fill semantics for `sourceFilterChip` in one place so the design
    /// rule (selected wins over hovered, both win over the ghost default)
    /// stays obvious.
    private func chipFill(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return theme.accentColor.opacity(theme.isDark ? 0.28 : 0.18) }
        if isHovered { return theme.secondaryBackground.opacity(0.5) }
        return .clear
    }

    /// Exits edit mode without saving. The row's local buffer is dropped,
    /// matching the Esc behavior.
    private func dismissEditing() {
        editingSessionId = nil
        editingBuffer = ""
    }

    // MARK: - Multi-Select

    /// Routes a row tap by the modifier keys held at click time. ⌘ toggles
    /// the row in the multi-selection and ⇧ extends a contiguous range from
    /// the anchor. With no modifier: while a selection is active a plain click
    /// toggles the row (so a chat can be deselected as easily as it was
    /// selected); otherwise it navigates to the chat as usual.
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
            handleSelect(session)
        }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
        selectionAnchorId = id
    }

    /// Adds every row between the anchor and `id` (inclusive) in the
    /// currently-visible order. Falls back to a single toggle when there is
    /// no usable anchor yet.
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

    // MARK: - Navigate-Away Rename Guard

    private func handleSelect(_ session: ChatSessionData) {
        guard let editingId = editingSessionId, editingId != session.id else {
            onSelect(session)
            return
        }
        let original = sessions.first { $0.id == editingId }?.title ?? ""
        let trimmed = editingBuffer.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != original else {
            // No real change — drop the buffer and switch right away.
            dismissEditing()
            onSelect(session)
            return
        }
        presentUnsavedRenameAlert(
            editingId: editingId,
            oldTitle: original,
            newTitle: trimmed,
            pending: session
        )
    }

    private func presentUnsavedRenameAlert(
        editingId: UUID,
        oldTitle: String,
        newTitle: String,
        pending: ChatSessionData
    ) {
        let requestId = UUID()
        let scope = alertScope
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: "Save Renamed Title?",
                message: L(
                    "You were renaming a conversation titled \"\(oldTitle)\" to \"\(newTitle)\" but haven't saved it yet."
                ),
                buttons: [
                    .destructive(L("Discard")) {
                        dismissEditing()
                        onSelect(pending)
                    },
                    .primary(L("Save")) {
                        onRename(editingId, newTitle)
                        dismissEditing()
                        onSelect(pending)
                    },
                ],
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }

    // MARK: - Import Guide

    /// Entry point for the header's Import button. First-time users get a
    /// themed guide explaining how to obtain an export from each provider;
    /// the persisted "don't show again" toggle skips straight to the panel.
    private func requestImport() {
        let scope = alertScope
        let startImport = {
            ChatSessionImportCoordinator.run(
                agentId: agentId == Agent.defaultId ? nil : agentId,
                scope: scope,
                source: .sidebar,
                // A single-conversation import opens immediately so the
                // user isn't left hunting the list for it.
                onOpen: { onSelect($0) }
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

    // MARK: - Footer

    private var sidebarFooter: some View {
        Button {
            AppDelegate.shared?.showManagementWindow(initialTab: nil)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                Text("Settings", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .foregroundColor(theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(SidebarRowBackground(isSelected: false, isHovered: isFooterHovered))
            .clipShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(theme.springAnimation(responseMultiplier: 0.8)) { isFooterHovered = hovering }
        }
        .localizedHelp("Settings")
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    // MARK: - Header

    private var sidebarHeader: some View {
        HStack {
            // No title: the lens tab bar directly above already names the
            // list, so the header is just the trailing action button.
            Spacer()

            if selectedTab == .projects {
                Button {
                    requestNewProject()
                } label: {
                    // folder.badge.plus is a wider glyph than the square-based
                    // header icons; one point down keeps it optically equal.
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .localizedHelp("New Project")
            }

            // Agents lens: a single plus that opens agent creation in the
            // management window. Import moved to the chat-history panel;
            // New Chat is covered by picking an agent (fresh chat) and the
            // (currently hidden) tab strip's own plus.
            if selectedTab == .chats {
                Button {
                    AppDelegate.shared?.showManagementWindow(
                        initialTab: .agents, deeplinkCreateAgent: true)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .localizedHelp("New Agent")
            }
        }
        .padding(.horizontal, 16)
        // No top padding: the tab bar directly above already supplies the
        // spacing. A 20pt top here was leftover from when the header was the
        // first element and produced a dead gap under the tab bar.
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    // MARK: - Selection Action Bar

    /// Batch actions for the current multi-selection: archive, delete, and a
    /// trailing clear. Mirrors the per-row menu's destructive-delete flow but
    /// operates on every selected id at once.
    private var selectionActionBar: some View {
        HStack(spacing: 8) {
            Text("\(selectedIds.count) selected", bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)

            Spacer(minLength: 4)

            if !projectManager.projects.isEmpty {
                Menu {
                    moveToProjectButtons(currentProjectId: nil) { projectId in
                        moveSelected(to: projectId)
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
                // Menus tint their label with the control accent (blue) on
                // macOS regardless of the label's own foregroundColor; force
                // the same neutral tint the sibling buttons use.
                .tint(theme.secondaryText)
                .fixedSize()
                .localizedHelp("Move to Project")
            }
            selectionBarButton(icon: "archivebox", help: "Archive", tint: theme.secondaryText) {
                archiveSelected()
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
        icon: String,
        help: LocalizedStringKey,
        tint: Color,
        action: @escaping () -> Void
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

    // MARK: - Batch Operations

    /// Shared "move to project" menu items: one row per project plus a
    /// trailing "Remove from Project". `currentProjectId` marks the checked
    /// row when the menu acts on a single session (nil for batch menus).
    @ViewBuilder
    func moveToProjectButtons(
        currentProjectId: UUID?,
        onMove: @escaping (UUID?) -> Void
    ) -> some View {
        ForEach(projectManager.projects) { project in
            Button {
                onMove(project.id)
            } label: {
                if project.id == currentProjectId {
                    Label { Text(verbatim: project.name) } icon: { Image(systemName: "checkmark") }
                } else {
                    Text(verbatim: project.name)
                }
            }
        }
        Divider()
        Button {
            onMove(nil)
        } label: {
            Text("Remove from Project", bundle: .module)
        }
    }

    /// Moves every selected session into `projectId` and clears the
    /// selection. Non-destructive, so no confirm.
    private func moveSelected(to projectId: UUID?) {
        for id in selectedIds {
            onSetProject(id, projectId)
        }
        clearSelection()
    }

    /// Archives every selected session (idempotent per row) and clears the
    /// selection. Archiving is non-destructive, so it skips the confirm.
    private func archiveSelected() {
        for id in selectedIds {
            onSetArchived(id, true)
        }
        clearSelection()
    }

    /// Confirms once, then deletes every selected session. Honors the
    /// per-session "don't ask again" opt-out just like the single-row flow.
    private func requestDeleteSelected() {
        let ids = selectedIds
        guard !ids.isEmpty else { return }
        if DeleteConfirmationPreference.shared.skipForSession {
            performDelete(ids)
            return
        }
        let requestId = UUID()
        let scope = alertScope
        let accessory = AnyView(DontAskAgainToggle())
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: "Delete Conversations?",
                message: L("\(ids.count) conversations will be removed permanently. This can't be undone."),
                accessory: accessory,
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
        for id in ids {
            onDelete(id)
        }
        clearSelection()
    }

    // MARK: - Empty State

    /// Interim state while the async content lookup is still running and no
    /// title/metadata match is visible yet. Prevents a premature "No matches
    /// found" flash before the search process has actually finished.
    private var searchingPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text("Searching conversations…", bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.secondaryText.opacity(0.8))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .foregroundColor(theme.secondaryText.opacity(0.5))
            Text("No conversations yet", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Agent List (prototype)

    /// Agents-focused sidebar: one row per local agent, active row
    /// highlighted, tap to make it this window's agent.
    private var agentListView: some View {
        ScrollView {
            // Plain VStack: every row needs a live frame for drag-to-reorder
            // hit testing, and the agent list is small.
            VStack(spacing: 2) {
                ForEach(displayedAgents) { agent in
                    AgentSidebarRow(
                        agent: agent,
                        isSelected: agent.id == agentId,
                        // The selected agent's row reflects the session the
                        // window is showing (the active tab's chat), so the
                        // sidebar always answers "which chat is this?".
                        currentSessionTitle: agent.id == agentId
                            ? sessions.first(where: { $0.id == currentSessionId })?.title
                            : nil,
                        activityStatus: activityStatus(for: agent),
                        onSelect: { onSelectAgent?(agent.id) },
                        isReorderable: !agent.isBuiltIn,
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
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .coordinateSpace(name: "agentList")
            .onPreferenceChange(AgentRowFramesKey.self) { agentRowFrames = $0 }
            .animation(theme.animationQuick(), value: displayedAgents.map(\.id))
        }
        .scrollIndicators(.hidden)
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
        let statuses = activityMonitor.statuses
        guard !statuses.isEmpty else { return nil }
        var rolledUp: SessionActivityMonitor.Status?
        for session in ChatSessionsManager.shared.sessions {
            guard (session.agentId ?? Agent.defaultId) == agent.id,
                let status = statuses[session.id]
            else { continue }
            if status == .working { return .working }
            rolledUp = rolledUp ?? status
        }
        return rolledUp
    }

    // MARK: - Session List

    private var sessionList: some View {
        ScrollViewReader { proxy in
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
                            onSelect: {
                                handleTap(session)
                            },
                            onStartRename: {
                                if editingSessionId != nil && editingSessionId != session.id {
                                    dismissEditing()
                                }
                                editingSessionId = session.id
                                editingBuffer = session.title
                            },
                            onConfirmRename: { newTitle in
                                let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
                                if !trimmed.isEmpty {
                                    onRename(session.id, trimmed)
                                }
                                editingSessionId = nil
                            },
                            onCancelRename: {
                                editingSessionId = nil
                            },
                            onBufferChange: { editingBuffer = $0 },
                            onDelete: {
                                if editingSessionId != nil {
                                    dismissEditing()
                                }
                                onDelete(session.id)
                            },
                            onToggleArchive: {
                                onSetArchived(session.id, !session.archived)
                            },
                            onTogglePin: {
                                onSetPinned(session.id, !session.pinned)
                            },
                            projects: projectManager.projects,
                            onSetProject: { projectId in
                                onSetProject(session.id, projectId)
                            },
                            onExport: { format in
                                onExport(session, format)
                            },
                            onStop: onStop.map { stop in
                                { stop(session.id) }
                            },
                            onOpenInNewWindow: onOpenInNewWindow != nil
                                ? {
                                    onOpenInNewWindow?(session)
                                } : nil,
                            onOpenInNewTab: onOpenInNewTab != nil
                                ? {
                                    onOpenInNewTab?(session)
                                } : nil
                        )
                        .id(session.id)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
                // Rows glide (rather than teleport) when a run starts/ends
                // and the active-first partition reorders the list.
                .animation(theme.springAnimation(responseMultiplier: 0.9), value: filteredSessions.map(\.id))
            }
            .scrollIndicators(.hidden)
            .onChange(of: importHighlight.sessionIds) { _, ids in
                // Bring the topmost freshly imported row into view; the
                // glow only helps if the row is on screen.
                guard let target = filteredSessions.first(where: { ids.contains($0.id) })
                else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(target.id, anchor: .center)
                }
            }
        }
    }
}

// MARK: - Agent Row (prototype)

/// Row in the agents-focused sidebar. Mirrors `SessionRow`'s hover and
/// selection treatment: avatar, name, hover-only gear to the agent's settings.
private struct AgentSidebarRow: View {
    let agent: Agent
    let isSelected: Bool
    /// Title of the session currently open for this agent (selected row
    /// only); shown as the subtitle so the row tracks the active chat.
    var currentSessionTitle: String? = nil
    /// Live activity rolled up from the agent's sessions: `.working`
    /// animates the avatar ring exactly like the old session rows.
    var activityStatus: SessionActivityMonitor.Status? = nil
    let onSelect: () -> Void
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
                Text(agent.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let currentSessionTitle {
                    Text(currentSessionTitle)
                        .font(.system(size: 10))
                        .foregroundColor(theme.accentColor.opacity(0.9))
                        .lineLimit(1)
                } else if agent.isBuiltIn {
                    Text("Orchestrator", bundle: .module)
                        .font(.system(size: 10))
                        .foregroundColor(theme.secondaryText.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Hover-only gear opening this agent's detail page in the
            // management window. The selected row is already signalled by
            // its background, so no checkmark. Built-ins (the default
            // Osaurus agent) have no editable detail page, so no gear.
            if isHovered, !agent.isBuiltIn {
                Button {
                    AppDelegate.shared?.showManagementWindow(
                        initialTab: .agents, deeplinkAgentId: agent.id)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: SidebarStyle.actionButtonSize, height: SidebarStyle.actionButtonSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .localizedHelp("Agent Settings")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(SidebarRowBackground(isSelected: isSelected, isHovered: isHovered))
        .clipShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
        .offset(y: dragOffset)
        .zIndex(isDragging ? 1 : 0)
        .shadow(color: .black.opacity(isDragging ? 0.18 : 0), radius: 8, y: 2)
        .onTapGesture(perform: onSelect)
        // Same threshold as the tab strip: a short travel keeps clicks as
        // taps; beyond it the press becomes a reorder drag.
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { onDragChanged?($0.translation.height) }
                .onEnded { _ in onDragEnded?() },
            including: isReorderable ? .all : .none
        )
        .onHover { hovering in
            withAnimation(theme.springAnimation(responseMultiplier: 0.8)) {
                isHovered = hovering
            }
        }
        .animation(theme.springAnimation(responseMultiplier: 0.8), value: isSelected)
    }
}

// MARK: - Project Row

/// Row in the Projects tab's top-level list. Mirrors `SessionRow`'s hover
/// and background treatment; the trailing count keeps membership glanceable.
private struct ProjectRow: View {
    let project: Project
    let sessionCount: Int
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
                    .frame(width: 24, height: 24)
                Image(systemName: "folder.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: project.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                if !project.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Has instructions", bundle: .module)
                        .font(.system(size: 10))
                        .foregroundColor(theme.secondaryText.opacity(0.85))
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(verbatim: "\(sessionCount)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(theme.secondaryText.opacity(theme.isDark ? 0.16 : 0.12))
                )

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(theme.secondaryText.opacity(isHovered ? 0.9 : 0.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(SidebarRowBackground(isSelected: false, isHovered: isHovered))
        .clipShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { hovering in
            withAnimation(theme.springAnimation(responseMultiplier: 0.8)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            Button(action: onRename) { Text("Rename", bundle: .module) }
            Button(action: onEditInstructions) { Text("Edit Instructions…", bundle: .module) }
            Divider()
            Button(role: .destructive, action: onDelete) { Text("Delete", bundle: .module) }
        }
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

    @Environment(\.theme) private var theme
    @Environment(\.themedAlertScope) private var alertScope
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
    private var sourceBadge: some View {
        Image(systemName: session.source.iconName)
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
            return Text("Delegated", bundle: .module)
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
private struct SessionActivityRing: View {
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
private struct SessionStopButton: View {
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
/// across consecutive deletes within the same app run.
private struct DontAskAgainToggle: View {
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
                currentSessionId: nil,
                onSelect: { _ in },
                onNewChat: { _ in },
                onDelete: { _ in },
                onRename: { _, _ in },
                onSetArchived: { _, _ in },
                onSetPinned: { _, _ in },
                onSetProject: { _, _ in },
                onDeleteProject: { _ in },
                onExport: { _, _ in }
            )
            .frame(height: 400)
        }
    }
#endif

// MARK: - History List (dialog)

/// The chat list the sidebar used to show, hosted by the History dialog:
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

    private var filteredSessions: [ChatSessionData] {
        let visible = sessions.filter { !$0.archived }
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
            SidebarSearchField(
                text: $searchQuery,
                placeholder: "Search chats...",
                isFocused: $isSearchFocused,
                isSearching: isContentSearchInFlight
            )

            if !selectedIds.isEmpty {
                selectionActionBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if sessions.isEmpty {
                placeholder(icon: "bubble.left.and.bubble.right", text: "No chats yet")
            } else if filteredSessions.isEmpty, isContentSearchInFlight {
                placeholder(icon: nil, text: "Searching conversations…")
            } else if filteredSessions.isEmpty {
                SidebarNoResultsView(searchQuery: searchQuery) {
                    withAnimation(theme.animationQuick()) { searchQuery = "" }
                }
                .frame(maxHeight: 360)
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
                                onOpenInNewTab: onOpenInNewTab.map { open in { open(session) } }
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
                .frame(maxHeight: 360)
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
