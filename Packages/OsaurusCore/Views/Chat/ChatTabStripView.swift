//
//  ChatTabStripView.swift
//  osaurus
//
//  Chrome-style tab strip for chat windows, hosted in the toolbar's
//  centered slot (the space the agent pill vacated when it moved into the
//  sidebar) and in the themed full-screen header. Follows modern Chrome's
//  visual grammar: only the ACTIVE tab draws the full tab shape (rounded
//  top corners, outward-curved "feet" at the bottom); inactive tabs are
//  flat labels that light up with a rounded rect on hover, separated by
//  hairline dividers that hide next to the active/hovered tab.
//

import SwiftUI

/// Chrome's tab silhouette: vertical sides with rounded top corners and
/// bottom corners that flare outward to a flat base, so the tab reads as
/// growing out of the surface below it.
struct ChromeTabShape: Shape {
    var topRadius: CGFloat = 8
    var footRadius: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let top = min(topRadius, h / 2)
        let foot = min(footRadius, h / 2)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: h))
        // Left foot: curve up and inward off the baseline.
        p.addQuadCurve(
            to: CGPoint(x: foot, y: h - foot),
            control: CGPoint(x: foot, y: h)
        )
        // Left side.
        p.addLine(to: CGPoint(x: foot, y: top))
        // Top-left corner.
        p.addQuadCurve(
            to: CGPoint(x: foot + top, y: 0),
            control: CGPoint(x: foot, y: 0)
        )
        // Top edge.
        p.addLine(to: CGPoint(x: w - foot - top, y: 0))
        // Top-right corner.
        p.addQuadCurve(
            to: CGPoint(x: w - foot, y: top),
            control: CGPoint(x: w - foot, y: 0)
        )
        // Right side.
        p.addLine(to: CGPoint(x: w - foot, y: h - foot))
        // Right foot: curve outward back to the baseline.
        p.addQuadCurve(
            to: CGPoint(x: w, y: h),
            control: CGPoint(x: w - foot, y: h)
        )
        p.closeSubpath()
        return p
    }
}

struct ChatTabStripView: View {
    @ObservedObject var windowState: ChatWindowState

    /// Hover is tracked at strip level (not per item) so separators can
    /// hide beside the hovered tab, matching Chrome.
    @State private var hoveredTabId: UUID?

    var body: some View {
        // Tabs are chat chrome; the project detail page hides them along
        // with the rest of the chat-specific toolbar items.
        if !windowState.isProjectPageVisible {
            HStack(spacing: 0) {
                ForEach(Array(windowState.tabs.enumerated()), id: \.element.id) { index, tab in
                    // Hairline divider between adjacent tabs, suppressed
                    // when either neighbor is active or hovered (their
                    // background shape already provides the edge).
                    if index > 0 {
                        separator(
                            hidden: isProminent(tab.id)
                                || isProminent(windowState.tabs[index - 1].id)
                        )
                    }
                    ChatTabItemView(
                        session: tab.session,
                        isActive: tab.id == windowState.activeTabId,
                        isHovered: hoveredTabId == tab.id,
                        canClose: windowState.tabs.count > 1,
                        onSelect: { windowState.selectTab(id: tab.id) },
                        onClose: { windowState.closeTab(id: tab.id) },
                        onHover: { hovering in
                            if hovering {
                                hoveredTabId = tab.id
                            } else if hoveredTabId == tab.id {
                                hoveredTabId = nil
                            }
                        }
                    )
                }

                newTabButton
                    .padding(.leading, 6)
            }
            // Cap the strip so it never crowds the leading/trailing toolbar
            // items; tabs inside share the width and truncate their titles.
            .frame(maxWidth: 700, alignment: .leading)
            .frame(height: 30)
            .environment(\.theme, windowState.theme)
        }
    }

    private func isProminent(_ id: UUID) -> Bool {
        id == windowState.activeTabId || id == hoveredTabId
    }

    private func separator(hidden: Bool) -> some View {
        Rectangle()
            .fill(windowState.theme.primaryBorder.opacity(hidden ? 0 : 0.55))
            .frame(width: 1, height: 14)
    }

    private var newTabButton: some View {
        Button(action: { windowState.newTab() }) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(windowState.theme.secondaryText)
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(ChromeHoverCircleButtonStyle(theme: windowState.theme))
        .help(Text(LocalizedStringKey("New Tab"), bundle: .module))
    }
}

/// Circular hover backplate for the "+" button, like Chrome's new-tab button.
private struct ChromeHoverCircleButtonStyle: ButtonStyle {
    let theme: ThemeProtocol
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(theme.tertiaryBackground)
                    .opacity(isHovered || configuration.isPressed ? 1 : 0)
            )
            .onHover { isHovered = $0 }
    }
}

/// A single tab. Observes its own session so the label tracks live title
/// changes (auto-titling, renames) and the run indicator tracks streaming.
private struct ChatTabItemView: View {
    @ObservedObject var session: ChatSession
    let isActive: Bool
    let isHovered: Bool
    /// False while this is the window's only tab — `closeTab` refuses to
    /// close the last tab, so the × is hidden rather than dead.
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    @Environment(\.theme) private var theme

    /// The feet of the active tab's shape; content is inset past them.
    private static let footRadius: CGFloat = 8

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
                .font(.system(size: 11.5, weight: .regular))
                .foregroundColor(isActive ? theme.primaryText : theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(isActive ? theme.primaryText : theme.secondaryText)
                        .frame(width: 15, height: 15)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ChromeCloseButtonStyle(theme: theme))
                // Chrome keeps the active tab's × always; inactive tabs
                // reveal it on hover.
                .opacity(isActive || isHovered ? 1 : 0)
                .help(Text(LocalizedStringKey("Close Tab"), bundle: .module))
            }
        }
        // Inset content past the active shape's feet so text never sits on
        // the curved corners.
        .padding(.horizontal, Self.footRadius + 10)
        .frame(minWidth: 44, maxWidth: 260)
        .frame(maxHeight: .infinity)
        .background(alignment: .bottom) {
            if isActive {
                // The full Chrome tab silhouette, flush with the strip's
                // baseline so it reads as rising out of the content below.
                ChromeTabShape(topRadius: 8, footRadius: Self.footRadius)
                    .fill(theme.tertiaryBackground.opacity(theme.isDark ? 0.95 : 0.85))
            } else if isHovered {
                // Inactive tabs hover-light with an inset rounded rect,
                // never the full shape — that's reserved for the active tab.
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(theme.tertiaryBackground.opacity(0.45))
                    .padding(.vertical, 3)
                    .padding(.horizontal, 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover(perform: onHover)
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }
}

/// Chrome-style close button: bare × that gains a circular backplate on its
/// own hover, sized so it never grows the tab.
private struct ChromeCloseButtonStyle: ButtonStyle {
    let theme: ThemeProtocol
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(theme.secondaryText.opacity(configuration.isPressed ? 0.35 : 0.22))
                    .opacity(isHovered || configuration.isPressed ? 1 : 0)
            )
            .onHover { isHovered = $0 }
    }
}
