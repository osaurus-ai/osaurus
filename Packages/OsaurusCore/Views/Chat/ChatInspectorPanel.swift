//
//  ChatInspectorPanel.swift
//  osaurus
//
//  The chat window's right-hand rail, the mirror image of the session
//  sidebar on the left: the same `SidebarContainer` chrome (glass/card
//  background, gradient, border, rounded outer corners), the same window
//  control clearance, a lens bar at the top and a header row under it.
//  Where the left rail is about what you can open (Agents | Projects),
//  this rail is about the tab on screen: File Changes for this chat, and
//  History for the past chats of this chat's agent. Both are scoped by the
//  tab, so neither needs a picker. The toolbar's `sidebar.right` button
//  opens and closes the rail like `sidebar.left` does the sidebar, so
//  neither rail carries a close button of its own.
//

import SwiftUI

struct ChatInspectorPanel: View {
    @ObservedObject var windowState: ChatWindowState
    let pane: ChatInspectorPane
    /// Live width from `ChatView` (the user's persisted choice, squeezed
    /// when the window is tight).
    let width: CGFloat
    let sessionId: UUID?
    @Binding var focusSetId: UUID?
    /// First line of the user's request that produced a turn, for the File
    /// Changes timeline headers.
    var userPrompt: (UUID) -> String? = { _ in nil }
    /// A History row was picked: open that chat in the current tab (the
    /// same route a sidebar row takes; the host owns scroll pinning).
    var onSelectSession: (ChatSessionData) -> Void = { _ in }

    @Environment(\.theme) private var theme

    /// Same clearance the left rail uses: 40pt for the title bar, then the
    /// lens bar's own top padding. Together they clear the unified toolbar
    /// (and in full screen, where the toolbar is detached, the rails still
    /// match each other).
    static let topPadding: CGFloat = 40

    var body: some View {
        SidebarContainer(attachedEdge: .trailing, topPadding: Self.topPadding, width: width) {
            lensBar
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 12)

            paneBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Inspector", bundle: .module))
    }

    // MARK: - Lens bar

    private var lensBar: some View {
        SidebarLensBar(
            selection: Binding(
                get: { pane },
                set: { windowState.showInspector($0) }
            ),
            segments: [
                .init(
                    value: .fileChanges,
                    label: "File Changes",
                    icon: "plus.forwardslash.minus",
                    badge: showsFileChangesBadge ? windowState.fileChangesCount : nil,
                    accessibilityLabel: fileChangesAccessibilityLabel
                ),
                .init(value: .history, label: "History", icon: "clock.arrow.circlepath"),
            ]
        )
    }

    /// Remote-agent chats have no local file history to count.
    private var showsFileChangesBadge: Bool {
        windowState.selectedDiscoveredAgentProviderId == nil
    }

    private var fileChangesAccessibilityLabel: Text? {
        guard showsFileChangesBadge, windowState.fileChangesCount > 0 else { return nil }
        return Text("File Changes", bundle: .module) + Text(", ")
            + Text("\(windowState.fileChangesCount) files changed", bundle: .module)
    }

    // MARK: - Panes

    @ViewBuilder
    private var paneBody: some View {
        switch pane {
        case .fileChanges:
            FileChangesPanel(
                sessionId: sessionId,
                focusSetId: $focusSetId,
                userPrompt: userPrompt
            )
        case .history:
            ChatHistoryPaneView(
                windowState: windowState,
                scope: .chat(windowState.windowId),
                onSelect: onSelectSession,
                onOpenInNewTab: { windowState.openSessionInNewTab($0) }
            )
        }
    }
}
