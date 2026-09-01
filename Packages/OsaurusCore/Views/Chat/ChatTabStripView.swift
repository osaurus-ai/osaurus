//
//  ChatTabStripView.swift
//  osaurus
//
//  Browser-style tab strip for chat windows. Hidden while a window has a
//  single tab (the default look is unchanged); appears under the toolbar
//  once a second tab is opened. Each tab shows its conversation's live
//  title, a streaming indicator, and a close button.
//

import SwiftUI

struct ChatTabStripView: View {
    @ObservedObject var windowState: ChatWindowState
    @Environment(\.theme) private var theme

    var body: some View {
        if windowState.tabs.count > 1 {
            strip
        }
    }

    private var strip: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(windowState.tabs) { tab in
                            ChatTabItemView(
                                session: tab.session,
                                isActive: tab.id == windowState.activeTabId,
                                onSelect: { windowState.selectTab(id: tab.id) },
                                onClose: { windowState.closeTab(id: tab.id) }
                            )
                            .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .scrollIndicators(.hidden)
                .onChange(of: windowState.activeTabId) { _, id in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: nil)
                    }
                }
            }

            Button(action: { windowState.newTab() }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text(LocalizedStringKey("New Tab"), bundle: .module))
            .padding(.trailing, 8)
        }
        .frame(height: 34)
        .background(theme.secondaryBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.primaryBorder.opacity(0.4))
                .frame(height: 1)
        }
    }
}

/// A single tab. Observes its own session so the label tracks live title
/// changes (auto-titling, renames) and the run indicator tracks streaming.
private struct ChatTabItemView: View {
    @ObservedObject var session: ChatSession
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    private var title: String {
        session.turns.isEmpty ? L("New Chat") : session.title
    }

    var body: some View {
        HStack(spacing: 6) {
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

            // Close affordance keeps a fixed footprint so the tab doesn't
            // resize as the pointer enters it; it's just invisible until
            // hovered or active.
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
        .padding(.horizontal, 10)
        .frame(height: 26)
        .frame(minWidth: 60, maxWidth: 180)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    isActive
                        ? theme.primaryBackground
                        : (isHovered ? theme.tertiaryBackground.opacity(0.6) : Color.clear))
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
