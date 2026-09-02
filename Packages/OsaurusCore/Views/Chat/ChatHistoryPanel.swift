//
//  ChatHistoryPanel.swift
//  osaurus
//
//  Trailing side panel listing the selected agent's chat history
//  (agents-focused sidebar prototype). Opened by the toolbar's history
//  button; tapping a row loads that conversation into the window.
//

import SwiftUI

struct ChatHistoryPanel: View {
    @ObservedObject var windowState: ChatWindowState
    @Environment(\.theme) private var theme
    @Environment(\.themedAlertScope) private var alertScope

    static let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().opacity(0.3)

            if windowState.filteredSessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(theme.secondaryBackground)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.primaryBorder.opacity(0.4))
                .frame(width: 1)
        }
    }

    private var header: some View {
        // Title + import hug the panel's LEFT edge with a tight top inset:
        // only the panel's top-RIGHT corner sits under the floating toolbar
        // buttons (history toggle + pin), so nothing on the left needs to
        // clear them — the old full-width 48pt inset read as a dead gap.
        // The × is gone: the toolbar's history button toggles both ways.
        HStack(spacing: 10) {
            Text("History", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Spacer()

            Button {
                requestImport()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .localizedHelp("Import Conversations")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// Mirrors the old sidebar Import flow: first-time users get the themed
    /// provider guide; the persisted "don't show again" toggle skips
    /// straight to the picker. Imports scope to the selected agent (Default
    /// agent imports unscoped, matching the sidebar behavior).
    private func requestImport() {
        let scope = alertScope
        let agentId = windowState.agentId
        let startImport = {
            ChatSessionImportCoordinator.run(
                agentId: agentId == Agent.defaultId ? nil : agentId,
                scope: scope,
                source: .sidebar,
                onOpen: { windowState.loadSession($0) }
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

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(theme.secondaryText.opacity(0.6))
            Text("No chats yet", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(windowState.filteredSessions) { session in
                    HistoryRow(
                        session: session,
                        isSelected: session.id == windowState.session.sessionId,
                        onSelect: {
                            windowState.loadSession(session)
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

/// Minimal history row: title + relative timestamp, selection/hover
/// treatment matching the sidebar rows.
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
