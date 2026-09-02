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
    /// Fallback for the width of the chrome preceding this item, used only
    /// until the first live measurement lands (see `measuredChromeX`).
    var leadingChromeWidth: CGFloat = 152

    /// The strip's actual leading x in WINDOW coordinates, measured from
    /// AppKit. Guessing this from constants proved fragile (toolbar
    /// inter-item spacing varies with the empty back slot and OS version);
    /// measuring makes the inset exact by construction.
    @State private var measuredChromeX: CGFloat?

    /// The window content width, measured alongside `measuredChromeX`. Used
    /// to give the strip a FIXED width: if the strip hugged its contents,
    /// its NSHostingView would snap to the new intrinsic width the instant a
    /// tab closes while the tabs inside are still sliding — the container
    /// jump reads as jank. A width that only changes on window resize keeps
    /// the toolbar item stable while the close animation plays inside it.
    @State private var windowContentWidth: CGFloat?

    /// Space reserved for the toolbar's trailing items (changes badge +
    /// new-chat + pin) so the fixed-width strip never runs under them.
    private static let trailingChromeReserve: CGFloat = 150

    private var stripWidth: CGFloat? {
        guard let windowContentWidth, let measuredChromeX else { return nil }
        let inset = needsSidebarInset ? sidebarOpenInset : 0
        let available = windowContentWidth - measuredChromeX - inset - Self.trailingChromeReserve
        return max(0, min(700, available))
    }

    /// Hover is tracked at strip level (not per item) so separators can
    /// hide beside the hovered tab, matching Chrome.
    @State private var hoveredTabId: UUID?

    /// The sidebar's user-chosen width, shared with the resizable sidebar
    /// via the same defaults key so the strip tracks the content edge.
    @AppStorage("chatSidebarWidth") private var storedSidebarWidth: Double = 240

    /// Leading inset that keeps the first tab at the CONTENT area's left
    /// edge while the sidebar is open — without it the tabs float over the
    /// sidebar. When the project back-pill is visible it already supplies
    /// this inset (and precedes the strip), so the strip adds none.
    private var sidebarOpenInset: CGFloat {
        let clamped = min(max(storedSidebarWidth, 260), 460)
        return max(0, CGFloat(clamped) - (measuredChromeX ?? leadingChromeWidth))
    }

    private var needsSidebarInset: Bool {
        windowState.showSidebar && windowState.session.projectId == nil
    }

    var body: some View {
        // Tabs are chat chrome; the project detail page hides them along
        // with the rest of the chat-specific toolbar items.
        if !windowState.isProjectPageVisible {
            // Inside the FIXED-width strip (see `stripWidth`), a plain
            // flexible row would expand every chip to its 260pt max — the
            // full proposed width turns `maxWidth` into an expansion
            // license. ViewThatFits keeps the hugging (ideal-size) layout,
            // where chips wrap their titles, for as long as it fits, and
            // only falls back to the space-sharing layout once the strip
            // is crowded enough that tabs must compress.
            ViewThatFits(in: .horizontal) {
                tabsRow(hugging: true)
                tabsRow(hugging: false)
            }
            // Tabs slide over when a neighbor closes (Chrome-like). Opening
            // stays un-animated: `newTab()` disables animations in its
            // transaction so the strip doesn't interpolate while ChatView
            // remounts for the fresh session.
            .animation(
                windowState.theme.animationQuick(),
                value: windowState.tabs.map(\.id)
            )
            // Fixed width once measured (see `stripWidth`): the toolbar item
            // must not resize mid-animation. Content-hugging is only the
            // pre-measurement fallback for the first layout pass.
            .frame(width: stripWidth, alignment: .leading)
            .frame(maxWidth: stripWidth == nil ? 700 : nil, alignment: .leading)
            .frame(height: 30)
            .padding(.leading, needsSidebarInset ? sidebarOpenInset : 0)
            // Anchored to the strip's OUTER leading edge (after the padding
            // modifier, so the padding lies inside the measured bounds and
            // the reading is the pre-inset chrome edge — no feedback loop).
            .background(alignment: .leading) {
                WindowXReader { x, contentWidth in
                    if abs((measuredChromeX ?? -1) - x) > 0.5 {
                        measuredChromeX = x
                    }
                    if abs((windowContentWidth ?? -1) - contentWidth) > 0.5 {
                        windowContentWidth = contentWidth
                    }
                }
                .frame(width: 0)
            }
            .animation(windowState.theme.animationQuick(), value: windowState.showSidebar)
            .environment(\.theme, windowState.theme)
        }
    }

    @ViewBuilder
    private func tabsRow(hugging: Bool) -> some View {
        let row = HStack(spacing: 0) {
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
        if hugging {
            // Ideal-size pass: every chip hugs its title (capped at 260).
            row.fixedSize(horizontal: true, vertical: false)
        } else {
            row
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

/// Reports the hosting SwiftUI view's leading x in WINDOW coordinates plus
/// the window's content width. SwiftUI's `.global` coordinate space bottoms
/// out at the enclosing `NSHostingView` (each toolbar item is its own), so
/// window-relative geometry needs an AppKit bridge.
private struct WindowXReader: NSViewRepresentable {
    var onChange: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> ReaderView {
        ReaderView(onChange: onChange)
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
        view.report()
    }

    final class ReaderView: NSView {
        var onChange: (CGFloat, CGFloat) -> Void
        // `nonisolated(unsafe)`: deinit is nonisolated and only removes the
        // observer; all writes happen on the main thread (same pattern as
        // ChatWindowState's notificationObservers).
        private nonisolated(unsafe) var resizeObserver: NSObjectProtocol?

        init(onChange: @escaping (CGFloat, CGFloat) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        deinit {
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
                self.resizeObserver = nil
            }
            if let window {
                resizeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in self?.report() }
            }
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        func report() {
            guard let window, let contentView = window.contentView else { return }
            let x = convert(CGPoint.zero, to: nil).x
            let width = contentView.bounds.width
            let callback = onChange
            // Defer: `layout` runs mid-layout-pass, and mutating SwiftUI
            // @State from inside it is undefined (AttributeGraph reentrancy).
            DispatchQueue.main.async { callback(x, width) }
        }
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
