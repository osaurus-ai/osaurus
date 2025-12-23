//
//  ChatSessionSidebar.swift
//  osaurus
//
//  Sidebar showing chat session history
//

import SwiftUI

struct ChatSessionSidebar: View {
    /// Sessions to display (already filtered by persona if needed)
    let sessions: [ChatSessionData]
    let currentSessionId: UUID?
    let onSelect: (ChatSessionData) -> Void
    let onNewChat: () -> Void
    let onDelete: (UUID) -> Void
    let onRename: (UUID, String) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var editingSessionId: UUID?
    @State private var editingTitle: String = ""
    @State private var searchQuery: String = ""
    @FocusState private var isSearchFocused: Bool

    // MARK: - Computed Properties

    private var filteredSessions: [ChatSessionData] {
        guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            return sessions
        }
        let query = searchQuery.lowercased()
        return sessions.filter { session in
            session.title.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with New Chat button
            sidebarHeader

            // Search field
            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Divider()
                .opacity(0.3)

            // Session list
            if sessions.isEmpty {
                emptyState
            } else if filteredSessions.isEmpty {
                noResultsState
            } else {
                sessionList
            }
        }
        .frame(width: 240)
        .background(theme.secondaryBackground.opacity(colorScheme == .dark ? 0.85 : 0.9))
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
        .padding(.vertical, 12)
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isSearchFocused ? theme.primaryText : theme.secondaryText.opacity(0.7))

            TextField("Search conversations...", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .focused($isSearchFocused)

            if !searchQuery.isEmpty {
                Button(action: {
                    withAnimation(theme.animationQuick()) {
                        searchQuery = ""
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText.opacity(0.7))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.tertiaryBackground.opacity(colorScheme == .dark ? 0.6 : 0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isSearchFocused ? theme.accentColor.opacity(0.3) : Color.clear,
                    lineWidth: 1
                )
        )
        .animation(theme.animationQuick(), value: isSearchFocused)
        .animation(theme.animationQuick(), value: searchQuery.isEmpty)
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

    // MARK: - No Results State

    private var noResultsState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "magnifyingglass")
                .font(.system(size: 24, weight: .light))
                .foregroundColor(theme.secondaryText.opacity(0.4))

            VStack(spacing: 4) {
                Text("No matches found")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText.opacity(0.8))

                Text("for \"\(searchQuery)\"")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Button(action: {
                withAnimation(theme.animationQuick()) {
                    searchQuery = ""
                }
            }) {
                Text("Clear search")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.accentColor.opacity(0.1))
                    )
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    // MARK: - Session List

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filteredSessions) { session in
                    SessionRow(
                        session: session,
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
                        }
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
    let isSelected: Bool
    let isEditing: Bool
    @Binding var editingTitle: String
    let onSelect: () -> Void
    let onStartRename: () -> Void
    let onConfirmRename: () -> Void
    let onCancelRename: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        if isEditing {
            editingView
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(rowBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)

                    Text(relativeDate(session.updatedAt))
                        .font(.system(size: 10))
                        .foregroundColor(theme.secondaryText.opacity(0.7))
                }
                Spacer()

                // Action buttons (visible on hover)
                if isHovered {
                    HStack(spacing: 4) {
                        ActionButton(
                            icon: "pencil",
                            help: "Rename",
                            action: onStartRename
                        )

                        ActionButton(
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
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture {
                onSelect()
            }
            .onHover { hovering in
                withAnimation(theme.animationQuick()) {
                    isHovered = hovering
                }
            }
            .contextMenu {
                Button("Rename", action: onStartRename)
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
    }

    private var normalView: some View {
        EmptyView()  // Keeping for compilation but not used
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

    private var rowBackground: some View {
        Group {
            if isSelected {
                theme.accentColor.opacity(0.15)
            } else if isHovered {
                theme.secondaryBackground.opacity(0.5)
            } else {
                Color.clear
            }
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Action Button

private struct ActionButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovered ? theme.secondaryBackground : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
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
