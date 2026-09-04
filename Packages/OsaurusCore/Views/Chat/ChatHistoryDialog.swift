//
//  ChatHistoryDialog.swift
//  osaurus
//
//  "See History" dialog: the selected agent's conversations, presented as a
//  themed alert from the toolbar's overflow menu. Tapping a row loads that
//  conversation into the window and dismisses the dialog.
//

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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                let agent = windowState.cachedActiveAgent
                AgentAvatarView(
                    mascotId: agent.avatar,
                    name: agent.displayName,
                    tint: agentColorFor(agent.name),
                    diameter: 20,
                    customImageURL: agent.customAvatarURL,
                    monogramFontSize: 9,
                    borderWidth: 0
                )
                Text(windowState.cachedAgentDisplayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Spacer()
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
                sessions: windowState.filteredSessions,
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
                }
            )
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

