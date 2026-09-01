//
//  ChatTabStripView.swift
//  osaurus
//
//  Browser-style tab strip for chat windows. Lives in the toolbar's
//  centered slot (the space the agent pill vacated when it moved into the
//  sidebar) and in the themed full-screen header. Tabs compress as more
//  open, like a browser; each shows its conversation's live title, a
//  streaming indicator, and a close button.
//

import SwiftUI

struct ChatTabStripView: View {
    @ObservedObject var windowState: ChatWindowState

    var body: some View {
        // Tabs are chat chrome; the project detail page hides them along
        // with the rest of the chat-specific toolbar items.
        if !windowState.isProjectPageVisible {
            HStack(spacing: 4) {
                ForEach(windowState.tabs) { tab in
                    ChatTabItemView(
                        session: tab.session,
                        isActive: tab.id == windowState.activeTabId,
                        canClose: windowState.tabs.count > 1,
                        onSelect: { windowState.selectTab(id: tab.id) },
                        onClose: { windowState.closeTab(id: tab.id) }
                    )
                }

                Button(action: { windowState.newTab() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(windowState.theme.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(LocalizedStringKey("New Tab"), bundle: .module))
            }
            // Cap the strip so it never crowds the leading/trailing toolbar
            // items; tabs inside share the width and truncate their titles.
            .frame(maxWidth: 560)
            .environment(\.theme, windowState.theme)
        }
    }
}

/// A single tab. Observes its own session so the label tracks live title
/// changes (auto-titling, renames) and the run indicator tracks streaming.
private struct ChatTabItemView: View {
    @ObservedObject var session: ChatSession
    let isActive: Bool
    /// False while this is the window's only tab — `closeTab` refuses to
    /// close the last tab, so the × is hidden rather than dead.
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    private var title: String {
        session.turns.isEmpty ? L("New Chat") : session.title
    }

    var body: some View {
        HStack(spacing: 5) {
            if session.isStreaming {
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: 6, height: 6)
            }

            Text(title)
                .font(.system(size: 11.5, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? theme.primaryText : theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)

            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 14, height: 14)
                        .background(
                            Circle()
                                .fill(theme.tertiaryBackground)
                                .opacity(isHovered ? 1 : 0)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isHovered || isActive ? 1 : 0)
                .help(Text(LocalizedStringKey("Close Tab"), bundle: .module))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .frame(minWidth: 36, maxWidth: 180)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    isActive
                        ? theme.tertiaryBackground.opacity(theme.isDark ? 0.9 : 0.8)
                        : (isHovered ? theme.tertiaryBackground.opacity(0.45) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(theme.primaryBorder.opacity(isActive ? 0.5 : 0), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}
