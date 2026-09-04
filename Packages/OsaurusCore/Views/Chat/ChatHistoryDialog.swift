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
            onSelect: { session in
                dismiss()
                windowState.loadSession(session)
            }
        )
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: "History",
                message: nil,
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

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(windowState.cachedAgentDisplayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Spacer()
                Button {
                    requestImport()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 11, weight: .medium))
                        Text("Import", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.secondaryText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .localizedHelp("Import Conversations")
            }

            if windowState.filteredSessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(windowState.filteredSessions) { session in
                            HistoryRow(
                                session: session,
                                isSelected: session.id == windowState.session.sessionId,
                                onSelect: { onSelect(session) }
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 360)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(theme.secondaryText.opacity(0.6))
            Text("No chats yet", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
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

/// History row: title + relative timestamp, selection/hover treatment
/// matching the sidebar rows.
private struct HistoryRow: View {
    let session: ChatSessionData
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(session.updatedAt, format: .relative(presentation: .named))
                .font(.system(size: 10))
                .foregroundColor(theme.secondaryText.opacity(0.85))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SidebarRowBackground(isSelected: isSelected, isHovered: isHovered))
        .clipShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous))
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            withAnimation(theme.springAnimation(responseMultiplier: 0.8)) {
                isHovered = hovering
            }
        }
    }
}
