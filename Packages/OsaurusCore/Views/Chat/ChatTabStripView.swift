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

    /// Space reserved for the toolbar's trailing items so the fixed-width
    /// strip never runs under them (undershooting folds them into the
    /// toolbar overflow menu). MEASURED by the reader from the actual
    /// toolbar items after the strip — constants proved wrong twice: too
    /// big leaves a dead gap, too small hides the pin.
    @State private var measuredTrailingReserve: CGFloat?

    private var trailingChromeReserve: CGFloat {
        measuredTrailingReserve ?? 150
    }

    private var stripWidth: CGFloat? {
        // Prefer the delegate-fed width (survives the strip's toolbar item
        // being folded into overflow, when the reader below goes silent);
        // the reader's reading seeds the value before the first resize.
        let liveWidth = windowState.windowContentWidth ?? self.windowContentWidth
        guard let windowContentWidth = liveWidth, let measuredChromeX else { return nil }
        let inset = needsSidebarInset ? sidebarOpenInset : 0
        // No artificial cap: like Chrome, tabs may use the whole bar up to
        // the trailing buttons; the reserve is what keeps them clear. The
        // extra 12 covers the toolbar item's own ~8pt frame padding (log:
        // frame = fitting + 8) and live-resize rounding — budgeting to the
        // exact pixel folds the item on a 1pt overshoot.
        let available = windowContentWidth - measuredChromeX - inset - trailingChromeReserve - 12
        return max(0, available)
    }

    /// Hover is tracked at strip level (not per item) so separators can
    /// hide beside the hovered tab, matching Chrome.
    @State private var hoveredTabId: UUID?

    /// Drag-to-reorder: the tab under the pointer and how far it has been
    /// pulled from its slot. Reordering happens LIVE as the pointer crosses
    /// a neighbour's midpoint (Chrome), so the offset is re-based by one
    /// slot pitch on every swap to keep the chip glued to the pointer.
    @State private var draggingTabId: UUID?
    @State private var dragOffset: CGFloat = 0

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
            // The row is laid out at IDEAL size (fixedSize in `tabsRow`), so
            // chips hug their titles; crowding is handled by shrinking the
            // per-tab width cap (`maxTabWidth`) as tabs multiply, computed so
            // the row NEVER exceeds the strip. An overflowing row would push
            // the "+" button outside the toolbar item's bounds, where it
            // still draws but no longer hit-tests.
            tabsRow()
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
                WindowXReader { x, contentWidth, trailingReserve in
                    if abs((measuredChromeX ?? -1) - x) > 0.5 {
                        measuredChromeX = x
                    }
                    if abs((windowContentWidth ?? -1) - contentWidth) > 0.5 {
                        windowContentWidth = contentWidth
                    }
                    if let trailingReserve,
                        abs((measuredTrailingReserve ?? -1) - trailingReserve) > 0.5
                    {
                        measuredTrailingReserve = trailingReserve
                    }
                    TabStripDebugLog.log(
                        "strip: chromeX=\(String(describing: measuredChromeX)) "
                            + "contentWidth=\(String(describing: windowContentWidth)) "
                            + "trailingReserve=\(trailingChromeReserve) "
                            + "inset=\(needsSidebarInset ? sidebarOpenInset : 0) "
                            + "stripWidth=\(String(describing: stripWidth)) "
                            + "tabs=\(windowState.tabs.count) maxTab=\(maxTabWidth)"
                    )
                }
                .frame(width: 0)
            }
            .animation(windowState.theme.animationQuick(), value: windowState.showSidebar)
            .environment(\.theme, windowState.theme)
        }
    }

    /// Per-tab width cap, shrunk as tabs multiply so the whole row (tabs +
    /// separators + "+" button) always fits inside `stripWidth`.
    private var maxTabWidth: CGFloat {
        guard let stripWidth else { return 260 }
        let count = CGFloat(max(windowState.tabs.count, 1))
        let plusButtonReserve: CGFloat = 32
        let separators = count - 1
        let available = stripWidth - plusButtonReserve - separators
        // No hard floor: a floor that exceeds available/count makes the
        // row's minimum grow past the strip with many tabs, overflowing the
        // toolbar item — AppKit then folds the whole bar into the overflow
        // menu (the "disappears on small windows" bug). Cramped tabs beat
        // no tabs.
        return min(260, max(2, available / count))
    }


    private func tabsRow() -> some View {
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
                    width: maxTabWidth,
                    isDragging: draggingTabId == tab.id,
                    dragOffset: draggingTabId == tab.id ? dragOffset : 0,
                    onSelect: { windowState.selectTab(id: tab.id) },
                    onClose: { windowState.closeTab(id: tab.id) },
                    onDragChanged: { translation in
                        handleDragChanged(tab.id, translation: translation)
                    },
                    onDragEnded: { endDrag() },
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
                .padding(.leading, 2)
        }
        // Ideal-size pass: every chip hugs its title, clamped to the
        // computed min/max, so the row width is Σ(clamped hug widths) and
        // never exceeds the strip by construction.
        .fixedSize(horizontal: true, vertical: false)
    }

    private func isProminent(_ id: UUID) -> Bool {
        id == windowState.activeTabId || id == hoveredTabId
    }


    // MARK: Drag to reorder

    /// Distance between adjacent tab origins: tab width plus the 1pt
    /// separator laid out between neighbours.
    private var slotPitch: CGFloat { maxTabWidth + 1 }

    /// Cumulative pitch already absorbed by live swaps during this drag.
    @State private var swappedDistance: CGFloat = 0

    private func handleDragChanged(_ id: UUID, translation: CGFloat) {
        if draggingTabId != id {
            // Pressing a tab selects it (Chrome) before it starts moving.
            draggingTabId = id
            dragOffset = 0
            swappedDistance = 0
            windowState.selectTab(id: id)
        }
        guard var index = windowState.tabs.firstIndex(where: { $0.id == id }) else { return }
        let last = windowState.tabs.count - 1
        // `translation` is cumulative from the press; subtract the slots
        // already swapped so the chip stays glued to the pointer. Each
        // crossing of a neighbour's midpoint swaps one slot and re-bases.
        var offset = translation - swappedDistance
        while offset > slotPitch / 2, index < last {
            index += 1
            move(id, to: index)
            swappedDistance += slotPitch
            offset -= slotPitch
        }
        while offset < -slotPitch / 2, index > 0 {
            index -= 1
            move(id, to: index)
            swappedDistance -= slotPitch
            offset += slotPitch
        }
        // The end tabs can't be pulled past the strip edges.
        if index == 0 { offset = max(offset, 0) }
        if index == last { offset = min(offset, 0) }
        dragOffset = offset
    }

    private func move(_ id: UUID, to index: Int) {
        withAnimation(.easeOut(duration: 0.15)) {
            windowState.moveTab(id: id, to: index)
        }
    }

    private func endDrag() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            dragOffset = 0
        }
        draggingTabId = nil
        swappedDistance = 0
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
                .frame(width: 20, height: 20)
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
    /// Fixed width computed by the strip: every tab renders the SAME width
    /// (Chrome-style), shrinking together as tabs multiply, so the strip
    /// reads as a uniform band rather than a ragged row of hugged chips.
    let width: CGFloat
    /// Drag-to-reorder state owned by the strip: lifted above siblings and
    /// translated by `dragOffset` while the pointer holds it.
    let isDragging: Bool
    let dragOffset: CGFloat
    let onSelect: () -> Void
    let onClose: () -> Void
    /// Horizontal translation since the press (≥ minimum distance).
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void
    let onHover: (Bool) -> Void

    @Environment(\.theme) private var theme
    /// Live activity for this tab's session — drives the avatar's spinning
    /// ring, the same signal the sidebar rows use.
    @ObservedObject private var activityMonitor = SessionActivityMonitor.shared
    @ObservedObject private var agentManager = AgentManager.shared

    /// The feet of the active tab's shape; content is inset past them.
    private static let footRadius: CGFloat = 8
    private static let avatarDiameter: CGFloat = 16

    private var title: String {
        session.turns.isEmpty ? L("New Chat") : session.title
    }

    private var agent: Agent {
        agentManager.agent(for: session.agentId ?? Agent.defaultId) ?? .default
    }

    private var activityStatus: SessionActivityMonitor.Status? {
        session.sessionId.flatMap { activityMonitor.statuses[$0] }
    }

    var body: some View {
        HStack(spacing: 6) {
            AgentAvatarView(
                mascotId: agent.avatar,
                name: agent.displayName,
                tint: theme.accentColor,
                diameter: Self.avatarDiameter,
                customImageURL: agent.customAvatarURL,
                monogramFontSize: 9,
                borderWidth: 0
            )
            .frame(width: Self.avatarDiameter, height: Self.avatarDiameter)
            .overlay(
                Group {
                    if let activityStatus {
                        TabActivityRing(status: activityStatus)
                    }
                }
                .allowsHitTesting(false)
            )
            // Reserve the RING's footprint, not the avatar's: the ring is
            // drawn as an overlay and otherwise bleeds into the title gap
            // whenever it appears (and the title would shift with it).
            .frame(width: TabActivityRing.diameter, height: TabActivityRing.diameter)

            Text(title)
                .font(.system(size: 11.5, weight: .regular))
                // Optical centring: the label's x-height sits a hair above
                // the avatar's centre at this size.
                .offset(y: 0.5)
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
        // the curved corners. The leading inset is trimmed by the ring's
        // reserved halo so the AVATAR (not its invisible ring frame) sits
        // the same distance from the edge as the close button does.
        .padding(.leading, Self.footRadius + 14 - (TabActivityRing.diameter - Self.avatarDiameter) / 2)
        // Inactive tabs: the hover highlight is inset 2pt from the chip and
        // the × glyph sits inside its 15pt hit circle, so it reads further
        // from the edge than the avatar; pull it 4pt closer. The active
        // tab's full silhouette keeps the symmetric inset.
        .padding(.trailing, Self.footRadius + (isActive ? 14 : 10))
        .frame(width: width)
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
        .offset(x: dragOffset)
        .zIndex(isDragging ? 1 : 0)
        .onTapGesture(perform: onSelect)
        // A short travel threshold keeps plain clicks as taps; beyond it
        // the press becomes a reorder drag.
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { onDragChanged($0.translation.width) }
                .onEnded { _ in onDragEnded() }
        )
        .onHover(perform: onHover)
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }
}

/// TEMPORARY debug logger for the strip-geometry investigation. Appends to
/// `<repo>/tmp/tabstrip-debug.log` (repo root derived from `#filePath` at
/// compile time). Remove before merge.
enum TabStripDebugLog {
    private static let file: URL = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Chat
            .deletingLastPathComponent()  // Views
            .deletingLastPathComponent()  // OsaurusCore
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
        let dir = root.appendingPathComponent("tmp")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tabstrip-debug.log")
    }()

    static func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        guard let data = "[\(ts)] \(message)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }
}

/// Reports the hosting SwiftUI view's leading x in WINDOW coordinates plus
/// the window's content width. SwiftUI's `.global` coordinate space bottoms
/// out at the enclosing `NSHostingView` (each toolbar item is its own), so
/// window-relative geometry needs an AppKit bridge.
private struct WindowXReader: NSViewRepresentable {
    /// (leading x, window content width, measured trailing-items reserve —
    /// nil when no toolbar is available, e.g. full screen).
    var onChange: (CGFloat, CGFloat, CGFloat?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        ReaderView(onChange: onChange)
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
        view.report()
    }

    final class ReaderView: NSView {
        var onChange: (CGFloat, CGFloat, CGFloat?) -> Void
        // `nonisolated(unsafe)`: deinit is nonisolated and only removes the
        // observer; all writes happen on the main thread (same pattern as
        // ChatWindowState's notificationObservers).
        private nonisolated(unsafe) var resizeObserver: NSObjectProtocol?
        /// The window whose resizes we track. Held (weakly) SEPARATELY from
        /// `self.window`: when the window shrinks enough that AppKit folds
        /// the strip's toolbar item into the overflow menu, this view is
        /// REMOVED from the window — if resize reporting stopped then, the
        /// strip's width state would freeze too wide and the item could
        /// never come back until the window regrew past the stale width.
        private weak var observedWindow: NSWindow?
        /// Last chrome-x reading, reused for resize reports that arrive
        /// while the view is detached (x can't be measured then, but it
        /// doesn't change with window width anyway).
        private var lastX: CGFloat?

        init(onChange: @escaping (CGFloat, CGFloat, CGFloat?) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        deinit {
            TabStripDebugLog.log("reader: DEINIT")
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            TabStripDebugLog.log(
                "reader: viewDidMoveToWindow window=\(window == nil ? "nil" : "set") "
                    + "observed=\(observedWindow == nil ? "nil" : "set")"
            )
            // Only rebind when landing in a NEW window; keep observing the
            // old one while detached (overflow-menu case above).
            if let window, window !== observedWindow {
                if let resizeObserver {
                    NotificationCenter.default.removeObserver(resizeObserver)
                }
                observedWindow = window
                resizeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    TabStripDebugLog.log("reader: didResize fired self=\(self == nil ? "nil" : "alive")")
                    self?.report()
                }
            }
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        func report() {
            guard let contentView = observedWindow?.contentView else { return }
            // A detached view can't measure x; fall back to the last live
            // reading so width-only updates still flow.
            if window != nil {
                lastX = convert(CGPoint.zero, to: nil).x
            }
            guard let x = lastX else { return }
            let width = contentView.bounds.width
            let trailing = measureTrailingReserve()
            TabStripDebugLog.log(
                "report: x=\(x) contentWidth=\(width) trailing=\(String(describing: trailing)) "
                    + "inWindow=\(window != nil) windowFrame=\(observedWindow?.frame.width ?? -1)"
            )
            let callback = onChange
            // Defer: `layout` runs mid-layout-pass, and mutating SwiftUI
            // @State from inside it is undefined (AttributeGraph reentrancy).
            DispatchQueue.main.async { callback(x, width, trailing) }
        }

        /// Sum the ACTUAL widths of the toolbar items after the tab strip
        /// (flexible space, action, pin) plus AppKit's inter-item spacing
        /// and trailing margin, so the strip's reserve matches whatever is
        /// really visible instead of a guessed constant.
        private func measureTrailingReserve() -> CGFloat? {
            guard let toolbar = observedWindow?.toolbar else {
                TabStripDebugLog.log("measureTrailing: no toolbar")
                return nil
            }
            // The key diagnostic: which items AppKit actually laid out vs.
            // folded into the overflow menu, and at what frames.
            let visible = toolbar.visibleItems?.map(\.itemIdentifier.rawValue) ?? []
            let allItems = toolbar.items.map { item -> String in
                let frame = item.view?.superview?.frame ?? .zero
                let fitting = item.view?.fittingSize ?? .zero
                return "\(item.itemIdentifier.rawValue): fitting=\(fitting.width) "
                    + "frame=(x:\(frame.origin.x) w:\(frame.width))"
            }
            TabStripDebugLog.log(
                "measureTrailing: visible=\(visible) items=[\(allItems.joined(separator: " | "))]"
            )
            var reserve: CGFloat = 12  // toolbar trailing margin + safety
            var pastStrip = false
            for item in toolbar.items {
                if item.itemIdentifier.rawValue == "ChatToolbar.tabs" {
                    pastStrip = true
                    continue
                }
                guard pastStrip else { continue }
                if item.itemIdentifier == .flexibleSpace {
                    reserve += 8  // its collapsed minimum
                    continue
                }
                // LAID-OUT width, not fittingSize: AppKit gives every item a
                // ~44pt minimum footprint even when its SwiftUI content
                // measures 0 (the log showed action fitting=0 / frame=44 —
                // the exact undershoot that folded the pin into overflow).
                let laidOut = item.view?.superview?.frame.width ?? 0
                let fitting = item.view?.fittingSize.width ?? 0
                reserve += max(laidOut, fitting, 44)
            }
            TabStripDebugLog.log("measureTrailing: reserve=\(reserve)")
            return reserve
        }
    }
}

/// Compact twin of the sidebar's `SessionActivityRing`, sized for the tab
/// avatar: spinning accent gradient while the agent works, steady warning
/// ring while the run waits for input.
private struct TabActivityRing: View {
    let status: SessionActivityMonitor.Status

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSpinning = false

    static let diameter: CGFloat = 21
    private static let lineWidth: CGFloat = 1.5

    var body: some View {
        switch status {
        case .working:
            if reduceMotion {
                ring(theme.accentColor.opacity(0.85))
            } else {
                Circle()
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                theme.accentColor.opacity(0.05),
                                theme.accentColor,
                            ]),
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round)
                    )
                    .frame(width: Self.diameter, height: Self.diameter)
                    .rotationEffect(.degrees(isSpinning ? 360 : 0))
                    .animation(
                        .linear(duration: 1.1).repeatForever(autoreverses: false),
                        value: isSpinning
                    )
                    .onAppear { isSpinning = true }
                    .onDisappear { isSpinning = false }
            }
        case .waitingForInput:
            ring(theme.warningColor.opacity(0.9))
        }
    }

    private func ring(_ color: Color) -> some View {
        Circle()
            .stroke(color, lineWidth: Self.lineWidth)
            .frame(width: Self.diameter, height: Self.diameter)
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

