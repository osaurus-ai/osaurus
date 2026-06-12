//
//  ChatSessionSidebar.swift
//  osaurus
//
//  Sidebar showing chat session history
//

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
    let onSelect: (ChatSessionData) -> Void
    let onNewChat: () -> Void
    let onDelete: (UUID) -> Void
    let onRename: (UUID, String) -> Void
    let onSetArchived: (UUID, Bool) -> Void
    let onExport: (ChatSessionData, ExportFormat) -> Void
    /// Optional callback for opening a session in a new window
    var onOpenInNewWindow: ((ChatSessionData) -> Void)? = nil

    enum ExportFormat {
        case markdown
        case pdf
        case zip
    }

    @Environment(\.theme) private var theme
    @Environment(\.themedAlertScope) private var alertScope
    @ObservedObject private var agentManager = AgentManager.shared
    @State private var editingSessionId: UUID?
    @State private var editingBuffer: String = ""
    @State private var searchQuery: String = ""
    @State private var sourceFilter: SourceFilter = .all
    @State private var hoveredFilter: SourceFilter?
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
        .source(.schedule),
        .source(.watcher),
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
            return byFilter
        }
        return byFilter.filter { session in
            if SearchService.matches(query: searchQuery, in: session.title) { return true }
            if let key = session.externalSessionKey,
                SearchService.matches(query: searchQuery, in: key)
            {
                return true
            }
            // Match capability labels so "vision" / "code" finds tagged chats.
            return session.capabilities.contains { cap in
                SearchService.matches(query: searchQuery, in: cap.label)
            }
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
        SidebarContainer(attachedEdge: .leading, topPadding: 40) {
            // Header with New Chat button
            sidebarHeader

            // Search field
            SidebarSearchField(
                text: $searchQuery,
                placeholder: "Search conversations...",
                isFocused: $isSearchFocused
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            // Source filter chips — always visible while the agent has
            // any session, so the user can never "lose" the rail just
            // by selecting a filter (or by drilling into a single-source
            // agent via loadSession). The chip set itself still hides
            // sources the agent has never used.
            if !sessions.isEmpty {
                sourceFilterRail
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            Divider()
                .opacity(0.3)

            // Session list
            if sessions.isEmpty {
                emptyState
            } else if filteredSessions.isEmpty {
                SidebarNoResultsView(searchQuery: searchQuery) {
                    withAnimation(theme.animationQuick()) {
                        searchQuery = ""
                        sourceFilter = .all
                    }
                }
            } else {
                sessionList
            }
        }
        // Adopting a new agent (via the dropdown's switchAgent or the
        // sidebar's loadSession) is a context change — wipe per-window
        // filter state so the new agent starts on "All" with an empty
        // search instead of inheriting the previous agent's lens.
        .onChange(of: agentId) { _, _ in
            sourceFilter = .all
            searchQuery = ""
            hoveredFilter = nil
        }
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

    // MARK: - Header

    private var sidebarHeader: some View {
        HStack {
            Text("History", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Spacer()

            Button(action: onNewChat) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .localizedHelp("New Chat")
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Empty State

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

    // MARK: - Session List

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filteredSessions) { session in
                    SessionRow(
                        session: session,
                        agent: agentManager.agent(for: session.agentId ?? Agent.defaultId),
                        isSelected: session.id == currentSessionId,
                        isEditing: editingSessionId == session.id,
                        onSelect: {
                            handleSelect(session)
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
                        onExport: { format in
                            onExport(session, format)
                        },
                        onOpenInNewWindow: onOpenInNewWindow != nil
                            ? {
                                onOpenInNewWindow?(session)
                            } : nil
                    )
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Session Row

private struct SessionRow: View {
    let session: ChatSessionData
    let agent: Agent?
    let isSelected: Bool
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
    let onExport: (ChatSessionSidebar.ExportFormat) -> Void
    /// Optional callback for opening in a new window
    var onOpenInNewWindow: (() -> Void)? = nil

    @Environment(\.theme) private var theme
    @Environment(\.themedAlertScope) private var alertScope
    @State private var isHovered = false
    @State private var showActionsPopover = false
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
                // Agent indicator
                if isDefaultAgent {
                    defaultAgentIndicator
                } else if let agent = agent {
                    agentIndicatorView(agent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(session.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)

                        if session.source != .chat {
                            sourceBadge
                        }

                        if !session.capabilities.isEmpty {
                            capabilityBadges
                        }
                    }

                    Text(metadataLine)
                        .font(.system(size: 10))
                        .foregroundColor(theme.secondaryText.opacity(0.85))
                        .lineLimit(1)
                }
                Spacer()

                if isHovered || showActionsPopover {
                    SidebarRowActionButton(
                        icon: "ellipsis",
                        help: "Actions",
                        action: { showActionsPopover.toggle() }
                    )
                    .popover(isPresented: $showActionsPopover, arrowEdge: .trailing) {
                        actionsPopover
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(SidebarRowBackground(isSelected: isSelected, isHovered: isHovered))
            .clipShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
            .onTapGesture {
                onSelect()
            }
            .onHover { hovering in
                withAnimation(theme.springAnimation(responseMultiplier: 0.8)) {
                    isHovered = hovering
                }
            }
            .animation(theme.springAnimation(responseMultiplier: 0.8), value: isSelected)
            .contextMenu {
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

    // MARK: - Actions Popover

    private var actionsPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            ActionsPopoverButton(icon: "pencil", label: "Rename", isDestructive: false) {
                showActionsPopover = false
                onStartRename()
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
        case .schedule: return theme.warningColor
        case .watcher: return theme.successColor
        case .selfSchedule: return theme.warningColor.opacity(0.9)
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
        case .schedule:
            return Text("Schedule", bundle: .module)
        case .watcher:
            return Text("Watcher", bundle: .module)
        case .selfSchedule:
            return Text("Self-scheduled", bundle: .module)
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
                Text(LocalizedStringKey(label), bundle: .module)
                    .font(.system(size: 12, weight: .medium))
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
        if isDestructive { return isHovered ? .red : theme.primaryText }
        return isHovered ? theme.accentColor : theme.primaryText
    }

    private var hoverFill: Color {
        if isDestructive { return Color.red.opacity(0.12) }
        return theme.accentColor.opacity(0.12)
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
                onNewChat: {},
                onDelete: { _ in },
                onRename: { _, _ in },
                onSetArchived: { _, _ in },
                onExport: { _, _ in }
            )
            .frame(height: 400)
        }
    }
#endif
