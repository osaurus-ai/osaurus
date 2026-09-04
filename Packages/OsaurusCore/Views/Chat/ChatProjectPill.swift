//
//  ChatProjectPill.swift
//  osaurus
//
//  Project membership pill for a chat, shown at the top of the chat content
//  (it used to live in the title bar, but the session tabs own that space
//  now: a variable-width item ahead of the strip pushed the toolbar into
//  AppKit's overflow menu and took the tabs with it).
//

import SwiftUI

/// Outer view observes the window (which republishes when its session is
/// replaced by a tab switch / load); the inner view observes the session's
/// own `projectId`.
struct ChatProjectPill: View {
    @ObservedObject var windowState: ChatWindowState

    var body: some View {
        ChatProjectPillContent(windowState: windowState, session: windowState.session)
    }
}

private struct ChatProjectPillContent: View {
    @ObservedObject var windowState: ChatWindowState
    @ObservedObject var session: ChatSession
    @ObservedObject private var projectManager = ProjectManager.shared
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        if !windowState.isProjectPageVisible,
            let projectId = session.projectId,
            let project = projectManager.project(for: projectId)
        {
            Button(action: {
                NotificationCenter.default.post(
                    name: .chatToolbarBackToProject,
                    object: nil,
                    userInfo: ["windowId": windowState.windowId]
                )
            }) {
                HStack(spacing: 5) {
                    // A chevron retraces the user's path when they came from
                    // the project page; a folder signals new navigation when
                    // the chat was opened straight from history.
                    Image(systemName: windowState.enteredChatFromProjectPage ? "chevron.left" : "folder")
                        .font(.system(size: 12, weight: .medium))
                    Text(project.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: true, vertical: false)
                    if !windowState.enteredChatFromProjectPage {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .opacity(0.7)
                    }
                }
                .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .liquidGlassCapsule()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
            .help(
                Text(
                    LocalizedStringKey(
                        windowState.enteredChatFromProjectPage ? "Back to project" : "Open project"),
                    bundle: .module))
        }
    }
}
