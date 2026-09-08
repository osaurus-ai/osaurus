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
        // `footFlare` keeps the active tab's outward-curving feet inside the
        // content area instead of over the sidebar edge / trailing buttons.
        let available = windowContentWidth - measuredChromeX - inset - trailingChromeReserve - 12 - 2 * Self.footFlare
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
    /// sidebar.
    private var sidebarOpenInset: CGFloat {
        let clamped = min(max(storedSidebarWidth, 260), 460)
        return max(0, CGFloat(clamped) - (measuredChromeX ?? leadingChromeWidth))
    }

    private var needsSidebarInset: Bool {
        windowState.showSidebar
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
            // Tour spotlight anchor (invisible; reports the strip's frame).
            .background(TourAnchorMarker(anchor: .tabStrip))
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
            .padding(.leading, (needsSidebarInset ? sidebarOpenInset : 0) + Self.footFlare)
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
        guard let stripWidth else { return Self.maxTabWidthCap }
        let count = CGFloat(max(visibleTabs.count, 1))
        let available = stripWidth - Self.plusButtonReserve - (count - 1)
            - (hiddenTabs.isEmpty ? 0 : Self.overflowButtonReserve)
        // Floor at the compact chip: below it a tab is unreadable, so tabs
        // that would push under the floor drop into the overflow menu
        // instead (see `visibleTabs`) — the row never exceeds the strip.
        return min(Self.maxTabWidthCap, max(Self.minTabWidth, available / count))
    }

    /// How far the active tab's feet flare beyond its slot (mirrors the
    /// item's `footRadius`); the strip is inset by this on both sides.
    static let footFlare: CGFloat = 8

    /// Narrowest chip: avatar only, no title (Chrome's pinned-tab size).
    /// Widest a tab grows with room to spare (Chrome caps around 240).
    static let maxTabWidthCap: CGFloat = 200
    static let minTabWidth: CGFloat = 56
    private static let plusButtonReserve: CGFloat = 30
    private static let overflowButtonReserve: CGFloat = 40

    /// How many tabs fit at the floor width, keeping the active tab visible.
    /// While unmeasured every tab is visible (the first layout pass).
    private var visibleTabs: [ChatTab] {
        let tabs = windowState.tabs
        guard let stripWidth else { return tabs }
        let fitsAll = stripWidth - Self.plusButtonReserve - CGFloat(tabs.count - 1)
            >= CGFloat(tabs.count) * Self.minTabWidth
        if fitsAll { return tabs }
        let budget = stripWidth - Self.plusButtonReserve - Self.overflowButtonReserve
        let capacity = max(1, Int(budget / (Self.minTabWidth + 1)))
        var shown = Array(tabs.prefix(capacity))
        // The active tab always stays in the strip: swap it in for the last
        // visible slot when it would otherwise be folded away.
        if let active = tabs.first(where: { $0.id == windowState.activeTabId }),
            !shown.contains(where: { $0.id == active.id })
        {
            shown[shown.count - 1] = active
        }
        return shown
    }

    private var hiddenTabs: [ChatTab] {
        let visibleIds = Set(visibleTabs.map(\.id))
        return windowState.tabs.filter { !visibleIds.contains($0.id) }
    }


    private func tabsRow() -> some View {
        HStack(spacing: 0) {
            let shown = visibleTabs
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, tab in
                // Hairline divider between adjacent tabs, suppressed
                // when either neighbor is active or hovered (their
                // background shape already provides the edge).
                if index > 0 {
                    separator(
                        hidden: isProminent(tab.id)
                            || isProminent(shown[index - 1].id)
                    )
                }
                ChatTabItemView(
                    session: tab.session,
                    isActive: tab.id == windowState.activeTabId,
                    isHovered: hoveredTabId == tab.id,
                    roundsLeading: index == 0 || shown[index - 1].id == windowState.activeTabId,
                    roundsTrailing: index == shown.count - 1
                        || shown[index + 1].id == windowState.activeTabId,
                    canClose: windowState.tabs.count > 1,
                    width: maxTabWidth,
                    isDragging: draggingTabId == tab.id,
                    dragOffset: draggingTabId == tab.id ? dragOffset : 0,
                    onSelect: { windowState.selectTab(id: tab.id) },
                    onClose: { windowState.closeTab(id: tab.id) },
                    onOpenProject: {
                        windowState.selectTab(id: tab.id)
                        NotificationCenter.default.post(
                            name: .chatToolbarBackToProject,
                            object: nil,
                            userInfo: ["windowId": windowState.windowId])
                    },
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

            if !hiddenTabs.isEmpty {
                overflowButton
                    .padding(.leading, 2)
            }

            newTabButton
                .padding(.leading, 6)
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

    /// Tabs that don't fit at the floor width, as a native menu (Chrome's
    /// tab-search chevron). Picking one selects it, which swaps it into the
    /// strip in place of the last visible tab.
    private var overflowButton: some View {
        Button(action: presentOverflowTabs) {
            HStack(spacing: 2) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                Text(verbatim: "\(hiddenTabs.count)")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(windowState.theme.secondaryText)
            // Wide enough that the capsule highlight reads as a pill, not a
            // squeezed circle around the chevron and count.
            .padding(.horizontal, 8)
            .frame(height: 22)
            .contentShape(Capsule())
        }
        .buttonStyle(ChromeHoverCapsuleButtonStyle(theme: windowState.theme))
        .help(Text(LocalizedStringKey("More Tabs"), bundle: .module))
    }

    private func presentOverflowTabs() {
        let menu = NSMenu()
        for tab in hiddenTabs {
            let item = NSMenuItem(
                title: tab.session.title.isEmpty ? L("New Chat") : tab.session.title,
                action: #selector(TabMenuTarget.select(_:)), keyEquivalent: "")
            let target = TabMenuTarget { [windowState] in windowState.selectTab(id: tab.id) }
            item.target = target
            item.representedObject = target  // keeps the target alive with the item
            menu.addItem(item)
        }
        let origin = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: NSPoint(x: origin.x - 8, y: origin.y - 16), in: nil)
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

/// Capsule variant of the hover highlight for the wider overflow button.
private struct ChromeHoverCapsuleButtonStyle: ButtonStyle {
    let theme: ThemeProtocol
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule()
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
    /// Inactive tabs share one continuous tinted band; only the ends of a
    /// run (strip edge, or beside the active tab) are rounded so adjacent
    /// inactive tabs merge into a single surface.
    var roundsLeading: Bool = true
    var roundsTrailing: Bool = true
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
    /// Open the project this tab's chat belongs to (folder glyph).
    let onOpenProject: () -> Void
    /// Horizontal translation since the press (≥ minimum distance).
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void
    let onHover: (Bool) -> Void

    @Environment(\.theme) private var theme
    /// Live activity for this tab's session — drives the avatar's spinning
    /// ring, the same signal the sidebar rows use.
    @ObservedObject private var activityMonitor = SessionActivityMonitor.shared
    @ObservedObject private var projectManager = ProjectManager.shared
    @ObservedObject private var agentManager = AgentManager.shared

    /// The feet of the active tab's shape; content is inset past them.
    private static let footRadius: CGFloat = 8
    private static let avatarDiameter: CGFloat = 16

    private var title: String {
        session.turns.isEmpty ? L("New Chat") : session.title
    }

    /// Below this width the title is dropped (avatar + × only).
    private var isNarrow: Bool { width < 110 }
    /// The floor chip: avatar only, centred; × replaces the avatar on hover.
    private var isCompact: Bool { width < 72 }

    private var agent: Agent {
        agentManager.agent(for: session.agentId ?? Agent.defaultId) ?? .default
    }

    private var activityStatus: SessionActivityMonitor.Status? {
        session.sessionId.flatMap { activityMonitor.statuses[$0] }
    }

    private var chipContent: some View {
        HStack(spacing: 6) {
            if isCompact, canClose, isHovered {
                // No room for both: the × takes the avatar's slot on hover.
                closeButton
            } else {
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
            }

            // Project membership: a folder glyph ahead of the title, which
            // doubles as the "back to project" control (the pill this replaces
            // lived in the title bar and collided with the strip).
            if !isNarrow, let project = projectManager.project(for: session.projectId) {
                Button(action: onOpenProject) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(isActive ? theme.accentColor : theme.secondaryText)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: project.name))
            }

            if !isNarrow {
            Text(title)
                .font(.system(size: 11.5, weight: .regular))
                // Optical centring: the label's x-height sits a hair above
                // the avatar's centre at this size.
                .offset(y: 0.5)
                .foregroundColor(isActive ? theme.primaryText : theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if canClose, !isCompact {
                closeButton
            }
        }
        .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
        .padding(.leading, isCompact ? 0 : Self.footRadius + 14 - (TabActivityRing.diameter - Self.avatarDiameter) / 2)
        .padding(.trailing, isCompact ? 0 : Self.footRadius + (isActive ? 14 : 10))
    }

    private var closeButton: some View {
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

    var body: some View {
        chipContent
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(alignment: .bottom) {
            if isActive {
                // The full Chrome tab silhouette, flush with the strip's
                // baseline so it reads as rising out of the content below.
                // The feet flare OUTSIDE the slot (negative inset) so the
                // body spans the full tab width like the inactive cards and
                // the curves overlap the neighbours' gaps, as in Chrome.
                ChromeTabShape(topRadius: 8, footRadius: Self.footRadius)
                    .fill(theme.tertiaryBackground.opacity(theme.isDark ? 0.95 : 0.85))
                    .padding(.horizontal, -Self.footRadius)
            } else {
                // Resting tint for inactive tabs, drawn as ONE continuous
                // band per run (no per-tab inset, corners only at the run's
                // ends) so the raised active tab's flared feet cover the
                // band edge and blend into it like Chrome. Hover brightens
                // just this tab's stretch of the band.
                UnevenRoundedRectangle(
                    topLeadingRadius: roundsLeading ? 7 : 0,
                    bottomLeadingRadius: roundsLeading ? 7 : 0,
                    bottomTrailingRadius: roundsTrailing ? 7 : 0,
                    topTrailingRadius: roundsTrailing ? 7 : 0,
                    style: .continuous
                )
                // Recessed below the raised active tab using the palette's own
                // shadow tone (each theme defines it), so the band follows a
                // theme's tint instead of a neutral black. Full height so it
                // sits flush with the active silhouette.
                .fill(theme.shadowColor.opacity(theme.isDark ? 0.2 : 0.06))
                .overlay(
                    UnevenRoundedRectangle(
                        topLeadingRadius: roundsLeading ? 7 : 0,
                        bottomLeadingRadius: roundsLeading ? 7 : 0,
                        bottomTrailingRadius: roundsTrailing ? 7 : 0,
                        topTrailingRadius: roundsTrailing ? 7 : 0,
                        style: .continuous
                    )
                    .fill(theme.tertiaryBackground.opacity(isHovered ? 0.4 : 0))
                )
            }
        }
        .contentShape(Rectangle())
        .offset(x: dragOffset)
        // Active above its neighbours so its flared feet draw over them.
        .zIndex(isDragging ? 2 : (isActive ? 1 : 0))
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
        // The title is hidden on narrow chips and truncated on medium ones,
        // so the tooltip is how a tab is recognised in a small window. It
        // carries the agent name too, since avatars alone don't identify a
        // chat once several tabs share an agent.
        .help(Text(verbatim: "\(title) · \(agent.displayName)"))
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
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
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
            guard let toolbar = observedWindow?.toolbar else { return nil }
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


/// Closure target for the overflow-tabs menu items.
private final class TabMenuTarget: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func select(_ sender: Any?) { handler() }
}
