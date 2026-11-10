//
//  ChatInspectorPanel.swift
//  osaurus
//
//  The chat surface's context panel: a floating card at the top trailing
//  corner of the chat, over the content rather than beside it, so the
//  conversation keeps the whole window. It holds the chat's File Changes
//  and only exists once the chat has changed a file
//  (`ChatWindowState.contextPane`). The toolbar's context button shows
//  and hides it; the card grows from that corner and hugs its content up
//  to `maxHeight`. The Workflows and Draft panes are still drawn here for
//  hosts that pass them, but the chat surface does not route to them.
//

import SwiftUI

struct ChatInspectorPanel: View {
    @ObservedObject var windowState: ChatWindowState
    let pane: ChatInspectorPane
    let width: CGFloat
    /// Tallest the card may grow; its list scrolls past that.
    let maxHeight: CGFloat
    let sessionId: UUID?
    @Binding var focusSetId: UUID?
    /// First line of the user's request that produced a turn, for the File
    /// Changes timeline headers.
    var userPrompt: (UUID) -> String? = { _ in nil }

    @Environment(\.theme) private var theme

    /// Header and picker rows above the list, for the list's height cap.
    private static let chromeHeight: CGFloat = 96

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
        paneBody
            .frame(width: width)
            .background(theme.surface.raised)
            .clipShape(shape)
            .overlay { shape.strokeBorder(theme.border.subtle, lineWidth: theme.stroke.default) }
            .themeElevation(theme.elevation.overlay)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Inspector", bundle: .module))
    }

    // MARK: - Panes

    @ViewBuilder
    private var paneBody: some View {
        switch pane {
        case .fileChanges:
            FileChangesPanel(
                sessionId: sessionId,
                focusSetId: $focusSetId,
                userPrompt: userPrompt,
                maxListHeight: max(0, maxHeight - Self.chromeHeight)
            )
            .fixedSize(horizontal: false, vertical: true)
        case .workflows:
            WorkflowsPaneView(windowState: windowState)
        case .draft:
            ArchitectSidebarPanel(
                sessionId: sessionId,
                onAsk: { windowState.session.input = $0 },
                onSend: { windowState.session.send($0) },
                onBrowse: { windowState.showInspector(.workflows) })
        }
    }
}
