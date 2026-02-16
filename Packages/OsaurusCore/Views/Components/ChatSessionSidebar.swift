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
    @FocusState private var isSearchFocused: Bool

    // MARK: - Computed Properties

    private var filteredSessions: [ChatSessionData] {
        guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            return sessions
        }
        return sessions.filter { session in
            SearchService.matches(query: searchQuery, in: session.title)
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
            .padding(.bottom, 8)

            Divider()
                .opacity(0.3)

            // Session list
            if sessions.isEmpty {
                emptyState
            } else if filteredSessions.isEmpty {
                SidebarNoResultsView(searchQuery: searchQuery) {
                    withAnimation(theme.animationQuick()) {
                        searchQuery = ""
                    }
                }
            } else {
                sessionList
            }
        }
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
            Text("History")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Spacer()

            Button(action: onNewChat) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("New Chat")
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
            Text("No conversations yet")
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
                    Text(session.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)

                    Text(formatRelativeDate(session.updatedAt))
                        .font(.system(size: 10))
                        .foregroundColor(theme.secondaryText.opacity(0.85))
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
                        Label("Open in New Window", systemImage: "macwindow.badge.plus")
                    }
                    Divider()
                }
                Button("Rename", action: onStartRename)
                Button("Delete", role: .destructive, action: onDelete)
            }
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
        .help("Default")
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
        TextField("Title", text: $editingTitle, onCommit: onConfirmRename)
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
