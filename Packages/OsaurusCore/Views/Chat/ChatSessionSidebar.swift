//
//  ChatSessionSidebar.swift
//  osaurus
//
//  Sidebar showing chat session history
//

import SwiftUI

struct ChatSessionSidebar: View {
    /// Sessions to display (already filtered by agent if needed)
    let sessions: [ChatSessionData]
    let currentSessionId: UUID?
    let onSelect: (ChatSessionData) -> Void
    let onNewChat: () -> Void
    let onDelete: (UUID) -> Void
    let onRename: (UUID, String) -> Void
    /// Optional callback for opening a session in a new window
    var onOpenInNewWindow: ((ChatSessionData) -> Void)? = nil

    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared
    @State private var editingSessionId: UUID?
    @State private var editingTitle: String = ""
    @State private var searchQuery: String = ""
    @State private var sourceFilter: SourceFilter = .all
    @FocusState private var isSearchFocused: Bool

    // MARK: - Source Filter

    /// Sidebar-local filter for `SessionSource`. Composes with the search
    /// query and the agent filter applied by the caller.
    enum SourceFilter: Hashable {
        case all
        case source(SessionSource)

        var label: String {
            switch self {
            case .all: return "All"
            case .source(let s): return s.shortLabel
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
    ]

    // MARK: - Computed Properties

    /// Sessions after applying both source filter and search query.
    private var filteredSessions: [ChatSessionData] {
        let bySource: [ChatSessionData]
        switch sourceFilter {
        case .all:
            bySource = sessions
        case .source(let s):
            bySource = sessions.filter { $0.source == s }
        }
        guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            return bySource
        }
        return bySource.filter { session in
            SearchService.matches(query: searchQuery, in: session.title)
                || (session.externalSessionKey.map {
                    SearchService.matches(query: searchQuery, in: $0)
                } ?? false)
        }
    }

    /// Source-filter chips shown above the list — only includes filters
    /// that match at least one session in the current set, plus `.all`,
    /// so the chip rail doesn't render dead options for empty buckets.
    private var visibleSourceFilters: [SourceFilter] {
        let presentSources = Set(sessions.map(\.source))
        return Self.allSourceFilters.filter { filter in
            if case .source(let s) = filter { return presentSources.contains(s) }
            return true
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

            // Source filter chips — only show when there's mixed content;
            // a single-source list (typical default-agent / chat-only) hides
            // the rail entirely to avoid visual clutter.
            if visibleSourceFilters.count > 2 {
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
    }

    // MARK: - Source Filter Rail

    private var sourceFilterRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(visibleSourceFilters, id: \.self) { filter in
                    sourceFilterChip(filter)
                }
            }
        }
    }

    private func sourceFilterChip(_ filter: SourceFilter) -> some View {
        let isSelected = sourceFilter == filter
        return Button {
            withAnimation(theme.animationQuick()) {
                sourceFilter = filter
            }
        } label: {
            Text(LocalizedStringKey(filter.label), bundle: .module)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isSelected
                                ? theme.accentColorLight.opacity(theme.isDark ? 0.22 : 0.16)
                                : theme.secondaryBackground.opacity(0.5)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isSelected
                                ? theme.accentColorLight.opacity(0.45)
                                : theme.primaryBorder.opacity(0.18),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func dismissEditing() {
        guard let id = editingSessionId else { return }
        if !editingTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            onRename(id, editingTitle)
        }
        editingSessionId = nil
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
            .help(Text("New Chat", bundle: .module))
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
                        editingTitle: $editingTitle,
                        onSelect: {
                            // Dismiss any ongoing edit first
                            if editingSessionId != nil && editingSessionId != session.id {
                                dismissEditing()
                            }
                            onSelect(session)
                        },
                        onStartRename: {
                            // Dismiss any other editing first
                            if editingSessionId != nil && editingSessionId != session.id {
                                dismissEditing()
                            }
                            editingSessionId = session.id
                            editingTitle = session.title
                        },
                        onConfirmRename: {
                            if !editingTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                                onRename(session.id, editingTitle)
                            }
                            editingSessionId = nil
                        },
                        onCancelRename: {
                            editingSessionId = nil
                        },
                        onDelete: {
                            // Dismiss editing first
                            if editingSessionId != nil {
                                dismissEditing()
                            }
                            onDelete(session.id)
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
    @Binding var editingTitle: String
    let onSelect: () -> Void
    let onStartRename: () -> Void
    let onConfirmRename: () -> Void
    let onCancelRename: () -> Void
    let onDelete: () -> Void
    /// Optional callback for opening in a new window
    var onOpenInNewWindow: (() -> Void)? = nil

    @Environment(\.theme) private var theme
    @State private var isHovered = false
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
                    }

                    Text(metadataLine)
                        .font(.system(size: 10))
                        .foregroundColor(theme.secondaryText.opacity(0.85))
                        .lineLimit(1)
                }
                Spacer()

                // Action buttons (visible on hover)
                if isHovered {
                    HStack(spacing: 4) {
                        SidebarRowActionButton(
                            icon: "pencil",
                            help: "Rename",
                            action: onStartRename
                        )

                        SidebarRowActionButton(
                            icon: "trash",
                            help: "Delete",
                            action: onDelete
                        )
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
                Button(role: .destructive, action: onDelete) { Text("Delete", bundle: .module) }
            }
        }
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
        .help(Text("Default", bundle: .module))
    }

    @ViewBuilder
    private func agentIndicatorView(_ agent: Agent) -> some View {
        ZStack {
            Circle()
                .fill(agentColor.opacity(theme.isDark ? 0.14 : 0.10))
                .frame(width: 24, height: 24)

            Text(agent.name.prefix(1).uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(agentColor)
        }
        .help(agent.name)
    }

    private var editingView: some View {
        TextField(text: $editingTitle, prompt: Text("Title", bundle: .module)) {
            Text("Title", bundle: .module)
        }
        .onSubmit(onConfirmRename)
        .textFieldStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(theme.primaryText)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(theme.primaryBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .focused($isTextFieldFocused)
        .onExitCommand(perform: onCancelRename)
        .onAppear {
            isTextFieldFocused = true
        }
        .onChange(of: isTextFieldFocused) { _, focused in
            if !focused {
                // Clicked outside - confirm the rename
                onConfirmRename()
            }
        }
    }

}

// MARK: - Preview

#if DEBUG
    struct ChatSessionSidebar_Previews: PreviewProvider {
        static var previews: some View {
            ChatSessionSidebar(
                sessions: [],
                currentSessionId: nil,
                onSelect: { _ in },
                onNewChat: {},
                onDelete: { _ in },
                onRename: { _, _ in }
            )
            .frame(height: 400)
        }
    }
#endif
