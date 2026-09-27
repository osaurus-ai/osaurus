//
//  ProjectDetailView.swift
//  osaurus
//
//  A project, opened in the chat window's content area from the Projects
//  lens: a folder of chats. The header names the folder; the list below is
//  the same `ChatHistoryList` the inspector's History pane uses (same
//  rows, search and multi-select), scoped to the project's members. The
//  project's settings live in the right rail (`ProjectInspectorPanel`).
//

import SwiftUI

struct ProjectDetailView: View {
    let project: Project
    /// The hosting window: the chat list's row actions keep its live
    /// session in step, and New Chat starts inside this project there.
    @ObservedObject var windowState: ChatWindowState
    /// Open a conversation (the host closes this page and loads it).
    let onOpenSession: (ChatSessionData) -> Void
    /// Start a new chat inside this project.
    let onNewChat: () -> Void
    /// Delete the project (host detaches member chats and closes the page).
    /// Called after this view's own confirmation dialog.
    let onDelete: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.themedAlertScope) private var alertScope
    @ObservedObject private var sessionsManager = ChatSessionsManager.shared

    /// Readable width of the folder column, like a chat thread's.
    private let contentMaxWidth: CGFloat = 640

    /// The project's chats, both archived states; the list applies its
    /// own lenses.
    private var memberSessions: [ChatSessionData] {
        sessionsManager.sessions.filter { $0.projectId == project.id }
    }

    private var activeMemberCount: Int {
        memberSessions.filter { !$0.archived }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Same insets as the History pane: the header's folder circle
            // sits over the rows' avatars (12pt rail inset + 10pt row inset).
            header
                .padding(.horizontal, 22)
                .padding(.bottom, 16)

            // Same row the rails put their actions in: New Chat and Add
            // Chats on the right, nothing to summarise on the left (the
            // header already counts the chats).
            SidebarHeaderRow {
                SidebarHeaderIconButton(icon: "square.and.pencil", help: "New Chat", action: onNewChat)
                SidebarHeaderIconButton(icon: "text.badge.plus", help: "Add Chats") {
                    requestAddExistingChats()
                }
                .accessibilityLabel(Text("Add Chats", bundle: .module))
            }

            ChatHistoryList(
                sessions: memberSessions,
                currentSessionId: nil,
                scope: alertScope,
                onSelect: onOpenSession,
                onDelete: actions.delete,
                onRename: actions.rename,
                onSetArchived: actions.setArchived,
                onSetPinned: actions.setPinned,
                onSetProject: actions.setProject,
                onExport: actions.export,
                onStop: actions.stop,
                onOpenInNewWindow: actions.openInNewWindow,
                onOpenInNewTab: { data in
                    windowState.openProjectId = nil
                    windowState.enteredChatFromProjectPage = true
                    windowState.openSessionInNewTab(data)
                },
                listMaxHeight: nil,
                emptyHint: "Chats started here or added to the project appear here."
            )
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: contentMaxWidth)
        .padding(.horizontal, 20)
        .padding(.top, 40)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
    }

    private var actions: ChatHistoryWindowActions {
        ChatHistoryWindowActions(windowState: windowState, scope: alertScope)
    }

    // MARK: - Header

    /// The folder's identity, in the rail rows' anatomy one step up: 26pt
    /// folder circle, 15pt name, 11pt count, `ellipsis` for rename/delete.
    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(theme.isDark ? 0.16 : 0.12))
                    .frame(width: 26, height: 26)
                Image(systemName: "folder.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: project.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Text(L("\(activeMemberCount) chats"))
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer(minLength: 8)

            Menu {
                Button(action: requestRename) { Text("Rename", bundle: .module) }
                Divider()
                Button(role: .destructive, action: requestDelete) {
                    Text("Delete", bundle: .module)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: SidebarStyle.actionButtonSize, height: SidebarStyle.actionButtonSize)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .localizedHelp("More")
        }
    }

    // MARK: - Add Existing Chats

    /// Pop a multi-select picker of ungrouped chats so the user can pull
    /// several into the project at once, instead of moving them one by one
    /// from the History pane.
    private func requestAddExistingChats() {
        let requestId = UUID()
        let scope = alertScope
        let candidates = sessionsManager.sessions
            .filter { $0.projectId == nil && !$0.archived }
            .sorted { $0.updatedAt > $1.updatedAt }
        let sheet = AddChatsToProjectSheet(candidates: candidates) { ids in
            ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
            for id in ids {
                actions.setProject(id, project.id)
            }
        }
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: "Add Chats to Project",
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

    // MARK: - Rename / Delete

    private func requestRename() {
        let requestId = UUID()
        let scope = alertScope
        let sheet = ProjectNamePromptSheet(
            initialName: project.name,
            submitLabel: "Save"
        ) { name in
            ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
            var updated = project
            updated.name = name
            ProjectManager.shared.update(updated)
        }
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: "Rename Project",
                message: nil,
                buttons: [.cancel(L("Cancel"))],
                showsCloseButton: true,
                customContent: AnyView(sheet),
                width: 360,
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }

    private func requestDelete() {
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
                    .destructive(L("Delete")) { onDelete() },
                ],
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }
}
