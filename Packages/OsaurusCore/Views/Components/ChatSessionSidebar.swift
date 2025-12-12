//
//  ChatSessionSidebar.swift
//  osaurus
//
//  Sidebar showing chat session history
//

import SwiftUI

struct ChatSessionSidebar: View {
    @ObservedObject var manager: ChatSessionsManager
    let currentSessionId: UUID?
    let onSelect: (ChatSessionData) -> Void
    let onNewChat: () -> Void
    let onDelete: (UUID) -> Void
    let onRename: (UUID, String) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var editingSessionId: UUID?
    @State private var editingTitle: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header with New Chat button
            sidebarHeader
                .onTapGesture {
                    dismissEditing()
                }

            Divider()
                .opacity(0.3)

            // Session list
            if manager.sessions.isEmpty {
                emptyState
                    .onTapGesture {
                        dismissEditing()
                    }
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
                ForEach(manager.sessions) { session in
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
        Group {
            if isEditing {
                editingView
            } else {
                normalView
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
                isHovered = hovering
            }
        }
    }

    private var normalView: some View {
        HStack(spacing: 8) {
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

            // Delete button (visible on hover)
            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Delete")
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .gesture(
            TapGesture(count: 2)
                .onEnded {
                    onStartRename()
                }
        )
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

// MARK: - Preview

#if DEBUG
    struct ChatSessionSidebar_Previews: PreviewProvider {
        static var previews: some View {
            ChatSessionSidebar(
                manager: ChatSessionsManager.shared,
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
