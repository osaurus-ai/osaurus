//
//  ChatTabStripView.swift
//  osaurus
//
//  Tab strip for chat windows, hosted in the toolbar's centered slot (the
//  space the agent pill vacated when it moved into the sidebar) and in the
//  themed full-screen header. Follows Safari's compact-tab grammar in the
//  sidebar lens bar's palette: one recessed rounded track holds equal-width
//  tabs with centered titles, the active tab is an accent-tinted pill, and
//  inactive tabs are flat labels separated by hairline dividers that hide
//  next to the active/hovered tab. "+" and the overflow menu sit outside
//  the track.
//

import AppKit
import SwiftUI

struct ChatTabStripView: View {
    @ObservedObject var windowState: ChatWindowState
    /// Fallback for the width of the chrome preceding this item, used only
    /// until the first live measurement lands (see `measuredChromeX`).
    var leadingChromeWidth: CGFloat = 152

    /// The strip's actual leading x in WINDOW coordinates, measured from
    /// AppKit. Guessing this from constants proved fragile (toolbar
    /// inter-item spacing varies with the empty back slot and OS version);
    /// measuring makes the inset exact by construction. It only depends on
    /// the chrome BEFORE the strip, so it holds still during a window resize.
    @State private var measuredChromeX: CGFloat?

    /// Fallback for the width of the chrome AFTER this item (the inspector
    /// toggle and window pin, plus toolbar padding), used only until the
    /// first live measurement lands (see `measuredTrailingChrome`).
    var trailingChromeWidth: CGFloat = 80

    /// Distance from the strip's trailing edge to the window's trailing
    /// edge, measured from AppKit like `measuredChromeX`. Only depends on
    /// the chrome after the strip, so it too holds still during a resize.
    @State private var measuredTrailingChrome: CGFloat?

    /// Last laid-out strip width, for drag math that runs outside `body`.
    @State private var lastStripWidth: CGFloat = 0

    /// Width the tabs may use, given the space the container hands the
    /// strip. The strip does not size itself: the toolbar item is flexible
    /// (AppKit gives it whatever lies between the sidebar button and the
    /// trailing items, in the same layout pass as the window resize), so a
    /// fast resize can never race a measurement.
    private func stripWidth(in available: CGFloat) -> CGFloat {
        max(0, available - leadingInset - trailingInset)
    }

    /// How far the strip must start past its own leading edge so the first
    /// tab lands at the content area's left edge: the sidebar's width less
    /// the chrome (sidebar button, toolbar padding) already ahead of the
    /// strip. Zero when the sidebar is narrower than that chrome.
    static func leadingInset(sidebarWidth: CGFloat, chromeWidth: CGFloat) -> CGFloat {
        max(0, sidebarWidth - chromeWidth)
    }

    /// Mirror image for the right rail: the inspector's width less the
    /// chrome (rail toggle, pin, toolbar padding) already after the strip,
    /// so the last tab and "+" end at the chat column's trailing edge
    /// instead of running under the rail. Zero while the rail is closed or
    /// narrower than that chrome.
    static func trailingInset(inspectorWidth: CGFloat, chromeWidth: CGFloat) -> CGFloat {
        max(0, inspectorWidth - chromeWidth)
    }

    /// Hover is tracked at strip level (not per item) so separators can
    /// hide beside the hovered tab.
    @State private var hoveredTabId: UUID?

    /// Drag-to-reorder: the tab under the pointer and how far it has been
    /// pulled from its slot. Reordering happens LIVE as the pointer crosses
    /// a neighbour's midpoint, so the offset is re-based by one
    /// slot pitch on every swap to keep the chip glued to the pointer.
    @State private var draggingTabId: UUID?
    @State private var dragOffset: CGFloat = 0

    /// Keeps the first tab at the CONTENT area's left edge while the
    /// sidebar is open — without it the tabs float over the sidebar.
    /// `sidebarColumnWidth` is the rail's on-screen width as `ChatView`
    /// laid it out: 0 while hidden or pushed aside by the inspector at
    /// narrow widths (the tabs return to the window's left edge), and the
    /// LIVE value during a resize drag — reading the persisted defaults key
    /// here instead made the tabs lag the rail until the drag released.
    private var leadingInset: CGFloat {
        let inset = Self.leadingInset(
            sidebarWidth: windowState.sidebarColumnWidth,
            chromeWidth: measuredChromeX ?? leadingChromeWidth)
        return inset > 0 ? inset + Self.edgeGap : 0
    }

    /// The one visual gap the strip keeps around its parts: from an open
    /// rail's divider to the track, from the track to "+", and from "+" to
    /// the right rail's divider.
    static let edgeGap: CGFloat = 12
    /// Transparent padding `HeaderActionButton` wraps around its circle;
    /// gaps beside the "+" button subtract it so the VISIBLE gap is `edgeGap`.
    private static let headerButtonPadding: CGFloat = 4

    /// Keeps the tabs clear of the right rail (chat inspector or Project
    /// Settings). `inspectorColumnWidth` is the rail's on-screen width as
    /// `ChatView` laid it out — squeezed at narrow windows, live during a
    /// resize drag — so the strip tracks it without a second computation.
    private var trailingInset: CGFloat {
        let inset = Self.trailingInset(
            inspectorWidth: windowState.inspectorColumnWidth,
            chromeWidth: measuredTrailingChrome ?? trailingChromeWidth)
        return inset > 0 ? inset + Self.edgeGap - Self.headerButtonPadding : 0
    }

    var body: some View {
        // Tabs are chat chrome; the project detail page hides them along
        // with the rest of the chat-specific toolbar items.
        if !windowState.isProjectPageVisible {
            GeometryReader { proxy in
                let width = stripWidth(in: proxy.size.width)
                // Every tab renders at `maxTabWidth`, computed so the tabs
                // fill the track and the row NEVER exceeds the strip. An
                // overflowing row would push the "+" button outside the
                // toolbar item's bounds, where it still draws but no longer
                // hit-tests.
                tabsRow(stripWidth: width)
                    // Tour spotlight anchor (invisible; reports the strip's frame).
                    .background(TourAnchorMarker(anchor: .tabStrip))
                    // Tabs slide over when a neighbor closes. Opening stays
                    // un-animated: `newTab()` disables animations in its
                    // transaction so the strip doesn't interpolate while
                    // ChatView remounts for the fresh session.
                    .animation(
                        windowState.theme.animationQuick(),
                        value: windowState.scopedTabs.map(\.id)
                    )
                    .frame(width: width, alignment: .leading)
                    .frame(height: Self.stripHeight)
                    .padding(.leading, leadingInset)
                    .onChange(of: width, initial: true) { _, newWidth in
                        lastStripWidth = newWidth
                    }
            }
            .frame(height: Self.stripHeight)
            // Anchored to the strip's OUTER leading edge (the inset lies
            // inside the measured bounds, so the reading is the pre-inset
            // chrome edge — no feedback loop).
            .background(alignment: .leading) {
                WindowEdgeReader(edge: .leading) { x in
                    if abs((measuredChromeX ?? -1) - x) > 0.5 {
                        measuredChromeX = x
                    }
                }
                .frame(width: 0)
            }
            // Same at the OUTER trailing edge: the distance from there to
            // the window's edge is the trailing chrome, whatever AppKit (or
            // the full-screen header) puts after the strip.
            .background(alignment: .trailing) {
                WindowEdgeReader(edge: .trailing) { gap in
                    if abs((measuredTrailingChrome ?? -1) - gap) > 0.5 {
                        measuredTrailingChrome = gap
                    }
                }
                .frame(width: 0)
            }
            // Rail open/close slides the tabs along with the rail; keyed on
            // presence, not width, so a live resize drag is not lagged by
            // the animation.
            .animation(windowState.theme.animationQuick(), value: windowState.sidebarColumnWidth > 0)
            .animation(windowState.theme.animationQuick(), value: windowState.inspectorColumnWidth > 0)
            // Leaving the strip ends a close streak: widths relax to fit.
            .onHover { inside in
                guard !inside, frozenTabWidth != nil else { return }
                withAnimation(windowState.theme.animationQuick()) { frozenTabWidth = nil }
            }
            .environment(\.theme, windowState.theme)
        }
    }

    /// Tab width pinned by a × close: closing a tab would otherwise widen
    /// the survivors and slide the next × out from under the cursor.
    /// Held until the pointer leaves the strip, at which point the tabs
    /// relax to `fittedTabWidth` in one animated pass.
    @State private var frozenTabWidth: CGFloat?

    /// The width every tab renders at: the pinned width while a close
    /// streak is in progress (never wider than what still fits, so a
    /// shrinking window or a new tab cannot overflow the strip), else the
    /// fitted width.
    private func maxTabWidth(stripWidth: CGFloat) -> CGFloat {
        min(frozenTabWidth ?? .infinity, fittedTabWidth(stripWidth: stripWidth))
    }

    /// Per-tab width: the track's width shared equally (Safari), shrunk as
    /// tabs multiply so the whole row (track + "+" button) always fits
    /// inside the strip.
    private func fittedTabWidth(stripWidth: CGFloat) -> CGFloat {
        let visibleCount = visibleTabs(stripWidth: stripWidth).count
        let count = CGFloat(max(visibleCount, 1))
        let hasHidden = windowState.scopedTabs.count > visibleCount
        let available = tabsBudget(stripWidth: stripWidth) - (count - 1) * Self.separatorWidth
            - (hasHidden ? Self.overflowButtonReserve : 0)
        // Floor at the compact chip: below it a tab is unreadable, so tabs
        // that would push under the floor drop into the overflow menu
        // instead (see `visibleTabs`) — the row never exceeds the strip.
        return max(Self.minTabWidth, available / count)
    }

    /// Width left for tabs and their separators once the "+" button and
    /// the track's inner padding are taken out.
    private func tabsBudget(stripWidth: CGFloat) -> CGFloat {
        stripWidth - Self.plusButtonReserve - 2 * Self.trackPadding
    }

    static let stripHeight: CGFloat = 30
    /// Matches the toolbar's 28pt circle buttons so the track's top and
    /// bottom line up with theirs.
    static let trackHeight: CGFloat = 28
    /// Inset between the recessed track and the tabs it holds.
    static let trackPadding: CGFloat = 2

    /// Slot between adjacent tabs: keeps neighbouring pills from touching,
    /// with the hairline divider centred in it.
    static let separatorWidth: CGFloat = 4

    /// Narrowest chip: avatar only, no title.
    static let minTabWidth: CGFloat = 56
    /// Lead-in gap plus the 28pt circle and its transparent padding.
    private static let plusButtonReserve: CGFloat = (edgeGap - headerButtonPadding) + 28 + 2 * headerButtonPadding
    private static let overflowButtonReserve: CGFloat = 40

    /// Narrowest the toolbar item may get: one compact tab in its track,
    /// the overflow chevron and "+". AppKit folds the trailing buttons
    /// before it squeezes the strip below this.
    static let minimumItemWidth: CGFloat =
        minTabWidth + 2 * trackPadding + overflowButtonReserve + plusButtonReserve

    /// How many tabs fit at the floor width, keeping the active tab visible.
    /// Only the active agent's tabs are candidates: the strip is scoped per
    /// agent (other agents' tabs stay live but out of sight until selected).
    private func visibleTabs(stripWidth: CGFloat) -> [ChatTab] {
        let tabs = windowState.scopedTabs
        let fitsAll = tabsBudget(stripWidth: stripWidth) - CGFloat(tabs.count - 1) * Self.separatorWidth
            >= CGFloat(tabs.count) * Self.minTabWidth
        if fitsAll { return tabs }
        let budget = tabsBudget(stripWidth: stripWidth) - Self.overflowButtonReserve
        let capacity = max(1, Int(budget / (Self.minTabWidth + Self.separatorWidth)))
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

    private func tabsRow(stripWidth: CGFloat) -> some View {
        let shown = visibleTabs(stripWidth: stripWidth)
        let visibleIds = Set(shown.map(\.id))
        let hiddenTabs = windowState.scopedTabs.filter { !visibleIds.contains($0.id) }
        let tabWidth = maxTabWidth(stripWidth: stripWidth)
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, tab in
                    // Hairline divider between adjacent tabs, suppressed
                    // when either neighbor is active or hovered (their
                    // pill already provides the edge).
                    if index > 0 {
                        separator(
                            hidden: isProminent(tab.id)
                                || isProminent(shown[index - 1].id)
                        )
                    }
                    tabItem(tab, hasSiblings: shown.count + hiddenTabs.count > 1, width: tabWidth)
                }
            }
            // The track spans the strip even while a close streak pins
            // the tab width, so "+" stays put at the trailing end.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(Self.trackPadding)
            .frame(height: Self.trackHeight)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(windowState.theme.secondaryBackground.opacity(windowState.theme.isDark ? 0.4 : 0.5))
            )
            // Tabs never draw outside the track, even for a frame mid-resize.
            // Only the track is clipped: clipping the whole row would cut
            // the "+" button's glass shadow into a hard-edged rectangle.
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if !hiddenTabs.isEmpty {
                overflowButton(hiddenTabs: hiddenTabs)
                    .padding(.leading, 6)
            }

            newTabButton
                .padding(.leading, Self.edgeGap - Self.headerButtonPadding)
        }
    }

    private func tabItem(_ tab: ChatTab, hasSiblings: Bool, width tabWidth: CGFloat) -> some View {
        ChatTabItemView(
            windowState: windowState,
            tabId: tab.id,
            session: tab.session,
            isActive: tab.id == windowState.activeTabId,
            isHovered: hoveredTabId == tab.id,
            hasSiblings: hasSiblings,
            isHibernated: tab.isHibernated,
            width: tabWidth,
            isDragging: draggingTabId == tab.id,
            dragOffset: draggingTabId == tab.id ? dragOffset : 0,
            onSelect: { windowState.selectTab(id: tab.id) },
            onClose: {
                // Pin the current width for the rest of this close
                // streak so the next tab's × lands under the cursor.
                if frozenTabWidth == nil { frozenTabWidth = tabWidth }
                windowState.closeTab(id: tab.id)
            },
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

    private func isProminent(_ id: UUID) -> Bool {
        id == windowState.activeTabId || id == hoveredTabId
    }


    // MARK: Drag to reorder

    /// Distance between adjacent tab origins: tab width plus the separator
    /// slot laid out between neighbours.
    private var slotPitch: CGFloat { maxTabWidth(stripWidth: lastStripWidth) + Self.separatorWidth }

    /// Cumulative pitch already absorbed by live swaps during this drag.
    @State private var swappedDistance: CGFloat = 0

    private func handleDragChanged(_ id: UUID, translation: CGFloat) {
        if draggingTabId != id {
            // Pressing a tab selects it before it starts moving.
            draggingTabId = id
            dragOffset = 0
            swappedDistance = 0
            windowState.selectTab(id: id)
        }
        // Slots are scoped-strip positions (what the user sees); `moveTab`
        // takes the same coordinate.
        let scoped = windowState.scopedTabs
        guard var index = scoped.firstIndex(where: { $0.id == id }) else { return }
        let last = scoped.count - 1
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
            .frame(width: Self.separatorWidth)
    }

    /// Tabs that don't fit at the floor width, as a native menu. Picking
    /// one selects it, which swaps it into the strip in place of the last
    /// visible tab.
    private func overflowButton(hiddenTabs: [ChatTab]) -> some View {
        Button(action: { presentOverflowTabs(hiddenTabs) }) {
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
        .buttonStyle(TabHoverCapsuleButtonStyle(theme: windowState.theme))
        .help(Text(LocalizedStringKey("More Tabs"), bundle: .module))
    }

    private func presentOverflowTabs(_ hiddenTabs: [ChatTab]) {
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

    /// Same circle as the toolbar's other buttons (sidebar, rail toggle,
    /// pin), so "+" reads as one of that row rather than part of the track.
    private var newTabButton: some View {
        HeaderActionButton(icon: "plus", help: "New Tab") { windowState.newTab() }
    }
}

/// Capsule variant of the hover highlight for the wider overflow button.
private struct TabHoverCapsuleButtonStyle: ButtonStyle {
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
    /// Owner of the tab; the right-click menu routes its actions here.
    let windowState: ChatWindowState
    let tabId: UUID
    @ObservedObject var session: ChatSession
    let isActive: Bool
    let isHovered: Bool
    /// Whether the active agent has other tabs. A lone tab can still be
    /// closed when it holds a conversation (it is replaced by a blank chat);
    /// a lone BLANK tab has nothing to close — `closeTab` refuses, so the ×
    /// is hidden rather than dead. Evaluated here (not in the strip) because
    /// the blank test reads session state only this view observes.
    let hasSiblings: Bool
    let isHibernated: Bool

    private var canClose: Bool {
        hasSiblings || isHibernated || !session.turns.isEmpty || session.isStreaming
            || session.awaitingClarify != nil
    }
    /// Fixed width computed by the strip: every tab renders the SAME width,
    /// sharing the track equally and shrinking together as tabs multiply.
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
    /// Workspace/shared agent tabs take their avatar and name from the shared
    /// agent's identity (a workspace tab is stamped with the Default agent
    /// locally, so the local agent would misrepresent it).
    @ObservedObject private var rosterStore = WorkspaceRosterStore.shared
    @ObservedObject private var remoteAgentManager = RemoteAgentManager.shared

    private static let avatarDiameter: CGFloat = 16
    private static let closeButtonSize: CGFloat = 15
    /// Gap between the tab's leading edge and its ×.
    private static let closeInset: CGFloat = 5
    /// Horizontal inset of the centred avatar + title on BOTH sides, so the
    /// group stays centred while clearing the leading ×.
    private static let contentInset: CGFloat = closeInset + closeButtonSize + 4

    private var title: String {
        let stored = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // A hibernated tab has no turns in memory but is a saved
        // conversation: show its title, not "New Chat".
        if isHibernated, !stored.isEmpty { return stored }
        // A dispatched run carries its task title (schedule name, channel
        // thread…) before its first turn lands; a user's untouched tab is a
        // "New Chat".
        if stored.isEmpty || (session.turns.isEmpty && session.source == .chat) {
            return L("New Chat")
        }
        return stored
    }

    /// Origin glyph for runs that didn't start from the composer (scheduled,
    /// via API / channel, delegated…), so a background run's tab reads as
    /// such at a glance. Nil for ordinary chats.
    private var originIconName: String? {
        if isFromPairedPhone { return "iphone" }
        return session.source == .chat ? nil : session.source.iconName
    }

    /// A chat from the paired iPhone: stored as a workspace row, but the
    /// owner's own, so its tab reads as the iPhone's, not a teammate's.
    private var isFromPairedPhone: Bool {
        session.workspaceContext.map(RemoteSessionContinuation.isFromPairedPhone) ?? false
    }

    private var originLabel: String? {
        guard session.source != .chat else { return nil }
        if isFromPairedPhone { return "via iPhone" }
        // A run hosted for a remote caller names them ("for Alice · Workspace").
        if session.source == .workspace, let context = session.workspaceContext, context.isServedForTeammate {
            return session.source.originLabel(workspace: context)
        }
        let pluginName = session.sourcePluginId.map(PluginDisplayNameResolver.displayName(for:))
        return session.source.originLabel(pluginDisplayName: pluginName)
    }

    /// Below this width the title is dropped (avatar + × only).
    private var isNarrow: Bool { width < 110 }
    /// The floor chip: avatar only, centred; × replaces the avatar on hover.
    private var isCompact: Bool { width < 72 }

    private var agent: Agent {
        agentManager.agent(for: session.agentId ?? Agent.defaultId) ?? .default
    }

    /// Identity of the shared agent this tab talks to, when it is one. Read-
    /// only teammate conversations are local transcripts and keep the local
    /// agent's chip.
    private var sharedAgent: SharedAgentIdentity? {
        guard let context = session.workspaceContext, !context.isServedForTeammate else { return nil }
        _ = rosterStore.rosters
        _ = remoteAgentManager.remoteAgents
        return SharedAgentIdentity.resolve(address: context.agentAddress)
    }

    private var avatarMascotId: String? { sharedAgent.map(\.avatar) ?? agent.avatar }
    private var avatarName: String { sharedAgent?.name ?? agent.displayName }
    private var avatarCustomImageURL: URL? {
        if let sharedAgent { return sharedAgent.customAvatarURL }
        return agent.customAvatarURL
    }

    private var activityStatus: SessionActivityMonitor.Status? {
        session.sessionId.flatMap { activityMonitor.statuses[$0] }
    }

    /// Safari's layout: the identity (avatar, glyphs, title) centred as a
    /// group, with the × pinned to the leading edge.
    private var chipContent: some View {
        ZStack {
            identity
                .frame(maxWidth: .infinity)
                .padding(.horizontal, isCompact ? 0 : Self.contentInset)

            if canClose, !isCompact {
                closeButton
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Self.closeInset)
            }
        }
    }

    private var avatar: some View {
        AgentAvatarView(
            mascotId: avatarMascotId,
            name: avatarName,
            tint: theme.accentColor,
            diameter: Self.avatarDiameter,
            customImageURL: avatarCustomImageURL,
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

    private var identity: some View {
        HStack(spacing: 6) {
            if isCompact, canClose, isHovered {
                // No room for both: the × takes the avatar's slot on hover.
                closeButton
            } else {
                avatar
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

            // Background-run origin ("scheduled", "via API"…) as a glyph
            // ahead of the title; the tooltip spells it out.
            if !isNarrow, let originIconName {
                Image(systemName: originIconName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(isActive ? theme.accentColor : theme.secondaryText)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
            }

            if !isNarrow {
                Text(title)
                    .font(.system(size: 11.5, weight: isActive ? .semibold : .medium))
                    // Optical centring: the label's x-height sits a hair above
                    // the avatar's centre at this size.
                    .offset(y: 0.5)
                    .foregroundColor(isActive ? theme.accentColor : theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(isActive ? theme.accentColor : theme.secondaryText)
                .frame(width: Self.closeButtonSize, height: Self.closeButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(TabCloseButtonStyle(theme: theme))
        // Safari reveals the × only while the pointer is over the tab.
        .opacity(isHovered ? 1 : 0)
        .help(Text(LocalizedStringKey("Close Tab"), bundle: .module))
    }

    /// Accent pill for the active tab (the sidebar lens bar's selected
    /// segment), a faint neutral pill on hover, nothing at rest.
    private var pillFill: Color {
        if isActive { return theme.accentColor.opacity(theme.isDark ? 0.28 : 0.18) }
        return theme.secondaryText.opacity(isHovered ? 0.08 : 0)
    }

    var body: some View {
        chipContent
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(pillFill)
        )
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
        // Same actions the History dialog / sidebar rows offer, plus Close
        // Tab, so a chat can be managed without leaving the strip.
        .overlay(
            TabRightClickCatcher {
                ChatTabContextMenu(
                    windowState: windowState,
                    session: session,
                    activityStatus: activityStatus,
                    canClose: canClose,
                    onClose: onClose
                ).makeMenu()
            }
        )
        // The title is hidden on narrow chips and truncated on medium ones,
        // so the tooltip is how a tab is recognised in a small window. It
        // carries the agent name too, since avatars alone don't identify a
        // chat once several tabs share an agent, and the origin for runs
        // that didn't start from the composer.
        .help(Text(verbatim: helpText))
    }

    private var helpText: String {
        var parts = [title, avatarName]
        if let workspace = sharedAgent?.workspaceName { parts.append(workspace) }
        if let originLabel { parts.append(originLabel) }
        return parts.joined(separator: " · ")
    }
}

/// Right-click menu for a tab chip: the sidebar / History row actions
/// (Stop, Open in New Window, Rename, Pin, Move to Project, Export,
/// Archive, Delete) applied to the tab's session, plus Close Tab. A blank
/// tab that has never been saved still gets a menu: Rename, Pin and Move
/// to Project act on the live `ChatSession` alone and ride along on its
/// first save (a user title also stops auto-titling), and Open in New
/// Window opens a blank window for the same agent. Export, Archive and
/// Delete need a stored row and are hidden until there is one. For a saved
/// chat, mutations go through `ChatSessionsManager` and are mirrored onto
/// the live `ChatSession` so its next auto-save does not clobber them,
/// exactly like the sidebar.
///
/// Built as an `NSMenu`, not a SwiftUI `.contextMenu`: the strip lives in
/// an `NSToolbarItem`, and the toolbar's own right-click handler (Icon and
/// Text / Icon Only) wins over SwiftUI's context menu there. The catcher
/// view below takes the right-click first and pops this menu.
@MainActor
private struct ChatTabContextMenu {
    let windowState: ChatWindowState
    let session: ChatSession
    let activityStatus: SessionActivityMonitor.Status?
    let canClose: Bool
    let onClose: () -> Void

    private var alertScope: ThemedAlertScope { .chat(windowState.windowId) }

    /// The persisted row for this tab, if the conversation has been saved.
    private var persisted: ChatSessionData? {
        session.sessionId.flatMap { ChatSessionsManager.shared.session(for: $0) }
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let session = self.session
        let windowState = self.windowState
        if activityStatus != nil {
            add(to: menu, L("Stop"), icon: "stop.circle") { session.stop() }
            menu.addItem(.separator())
        }
        // A blank tab is not saved, so there is nothing to open elsewhere;
        // a blank window for the same agent is the closest equivalent.
        let isBlank = session.turns.isEmpty && !session.isStreaming
        if let persisted {
            add(to: menu, L("Open in New Window"), icon: "macwindow.badge.plus") {
                ChatWindowManager.shared.createWindow(
                    agentId: persisted.agentId, sessionData: persisted)
            }
            menu.addItem(.separator())
        } else if isBlank {
            add(to: menu, L("Open in New Window"), icon: "macwindow.badge.plus") {
                _ = ChatWindowManager.shared.createWindow(agentId: session.agentId)
            }
            menu.addItem(.separator())
        }
        let id = session.sessionId
        // Rename / Pin / Move to Project work for a never-saved tab too: the
        // live session carries the values into its first save.
        if id != nil || isBlank {
            add(to: menu, L("Rename")) { requestRename() }
            add(to: menu, session.pinned ? L("Unpin") : L("Pin")) {
                let pinned = !session.pinned
                if let id { ChatSessionsManager.shared.setPinned(id: id, pinned: pinned) }
                session.pinned = pinned
                windowState.refreshSessions()
            }
            let projects = ProjectManager.shared.projects
            if !projects.isEmpty {
                let item = NSMenuItem(
                    title: session.projectId == nil ? L("Move to Project") : L("Change Project"),
                    action: nil, keyEquivalent: "")
                item.submenu = makeProjectSubmenu(projects: projects)
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        if let id {
            if persisted != nil {
                add(to: menu, L("Export…")) { requestExport() }
                menu.addItem(.separator())
            }
            add(to: menu, session.archived ? L("Unarchive") : L("Archive")) {
                let archived = !session.archived
                ChatSessionsManager.shared.setArchived(id: id, archived: archived)
                session.archived = archived
                windowState.refreshSessions()
            }
            add(to: menu, L("Delete")) { requestDelete() }
            menu.addItem(.separator())
        }
        if canClose {
            add(to: menu, L("Close Tab"), handler: onClose)
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        return menu
    }

    /// One row per project (checkmark on the current one) plus "Remove from
    /// Project" while the chat is in one. Mirrors the sidebar row's submenu.
    private func makeProjectSubmenu(projects: [Project]) -> NSMenu {
        let submenu = NSMenu()
        for project in projects {
            let item = add(to: submenu, project.name) { setProject(project.id) }
            item.state = project.id == session.projectId ? .on : .off
        }
        if session.projectId != nil {
            submenu.addItem(.separator())
            add(to: submenu, L("Remove from Project")) { setProject(nil) }
        }
        return submenu
    }

    @discardableResult
    private func add(
        to menu: NSMenu, _ title: String, icon: String? = nil, handler: @escaping () -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(TabMenuTarget.select(_:)), keyEquivalent: "")
        if let icon { item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) }
        let target = TabMenuTarget(handler)
        item.target = target
        item.representedObject = target  // keeps the target alive with the item
        menu.addItem(item)
        return item
    }

    private func setProject(_ projectId: UUID?) {
        if let id = session.sessionId {
            ChatSessionsManager.shared.setProject(id: id, projectId: projectId)
        }
        session.projectId = projectId
        // A blank active tab moved into a project also takes the project's
        // folder, the way a New Chat started from that project does.
        if session.sessionId == nil, session === windowState.session,
            let project = ProjectManager.shared.project(for: projectId)
        {
            windowState.adoptProjectFolder(project)
        }
        windowState.refreshSessions()
    }

    // MARK: - Rename

    /// The sidebar renames inline in its row; a tab chip has no room for a
    /// field, so the strip asks in the same single-field prompt the sidebar
    /// uses for project names.
    private func requestRename() {
        let id = session.sessionId
        let requestId = UUID()
        let scope = alertScope
        let windowState = self.windowState
        let session = self.session
        let sheet = ProjectNamePromptSheet(
            initialName: session.title,
            submitLabel: "Save",
            placeholder: "Chat Title"
        ) { title in
            ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
            if let id { ChatSessionsManager.shared.rename(id: id, title: title) }
            session.title = title
            windowState.refreshSessions()
        }
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: "Rename Chat",
                message: nil,
                buttons: [.cancel(L("Cancel"))],
                showsCloseButton: true,
                customContent: AnyView(sheet),
                width: 360,
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }

    // MARK: - Export

    /// Same chooser + coordinator the sidebar row uses.
    private func requestExport() {
        guard let metadata = persisted else { return }
        let requestId = UUID()
        let scope = alertScope
        let sheet = ExportChooserSheet(session: metadata) { format, options in
            ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
            ChatSessionExportCoordinator.run(
                metadataSession: metadata,
                format: format,
                options: options,
                scope: scope
            )
        }
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: "Export Conversation",
                message: nil,
                buttons: [.cancel(L("Cancel"))],
                showsCloseButton: true,
                customContent: AnyView(sheet),
                width: 420,
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }

    // MARK: - Delete

    /// Same confirmation (with the session-wide "don't ask again" toggle)
    /// and the same teardown order as the sidebar: cancel a registry-owned
    /// run, detach this window's tab, then delete the row.
    private func requestDelete() {
        guard let id = session.sessionId else { return }
        let scope = alertScope
        let windowState = self.windowState
        let perform = {
            if let liveTask = BackgroundTaskManager.shared.liveTask(forSessionId: id) {
                BackgroundTaskManager.shared.cancelTask(liveTask.id)
            }
            windowState.prepareForSessionDeletion(id: id)
            ChatSessionsManager.shared.delete(id: id)
            windowState.refreshSessions()
        }
        if DeleteConfirmationPreference.shared.skipForSession {
            perform()
            return
        }
        let requestId = UUID()
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: requestId,
                title: "Delete Conversation?",
                message: L("\"\(session.title)\" will be removed permanently. This can't be undone."),
                accessory: AnyView(DontAskAgainToggle()),
                buttons: [
                    .cancel(L("Cancel")),
                    .destructive(L("Delete")) { perform() },
                ],
                onDismiss: {
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }
}

/// Reports the hosting SwiftUI view's distance from one WINDOW edge: its
/// leading x for `.leading`, or the gap from its own x to the window's
/// trailing edge for `.trailing`. SwiftUI's `.global` coordinate space
/// bottoms out at the enclosing `NSHostingView` (each toolbar item is its
/// own), so window-relative geometry needs an AppKit bridge. Mount it as a
/// zero-width view on the edge to be measured.
private struct WindowEdgeReader: NSViewRepresentable {
    enum Edge { case leading, trailing }

    var edge: Edge
    var onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ReaderView {
        ReaderView(edge: edge, onChange: onChange)
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.edge = edge
        view.onChange = onChange
        view.report()
    }

    final class ReaderView: NSView {
        var edge: Edge
        var onChange: (CGFloat) -> Void
        // `nonisolated(unsafe)`: deinit is nonisolated and only removes the
        // observer; all writes happen on the main thread (same pattern as
        // ChatWindowState's notificationObservers).
        private nonisolated(unsafe) var resizeObserver: NSObjectProtocol?

        init(edge: Edge, onChange: @escaping (CGFloat) -> Void) {
            self.edge = edge
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
            // Entering or leaving full screen moves the leading chrome
            // without necessarily re-laying out this zero-width view.
            if let window {
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
            guard let window else { return }
            let x = convert(CGPoint.zero, to: nil).x
            let value: CGFloat
            switch edge {
            case .leading: value = x
            case .trailing: value = window.frame.width - x
            }
            let callback = onChange
            // Defer: `layout` runs mid-layout-pass, and mutating SwiftUI
            // @State from inside it is undefined (AttributeGraph reentrancy).
            // The value only depends on the chrome beside the strip, so the
            // one runloop of lag never shows during a resize.
            DispatchQueue.main.async { callback(value) }
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

/// Tab close button: bare × that gains a circular backplate on its own
/// hover, sized so it never grows the tab.
private struct TabCloseButtonStyle: ButtonStyle {
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


/// Invisible AppKit layer over a tab chip that pops the given menu on a
/// right-click (or control-click) landing on the chip. It never takes part
/// in hit testing (`hitTest` returns nil), so the tap, drag-to-reorder and
/// close button keep working. The click is caught with a local event
/// monitor rather than `rightMouseDown`: the strip lives in an
/// `NSToolbarItem`, and the toolbar claims right-clicks on its items for its
/// own display-mode menu (Icon and Text / Icon Only) before they are ever
/// routed to a subview. The monitor runs before the window dispatches the
/// event, and consuming it there keeps the toolbar menu from appearing.
private struct TabRightClickCatcher: NSViewRepresentable {
    let makeMenu: @MainActor () -> NSMenu

    func makeNSView(context: Context) -> CatcherView { CatcherView(makeMenu: makeMenu) }

    func updateNSView(_ view: CatcherView, context: Context) { view.makeMenu = makeMenu }

    final class CatcherView: NSView {
        var makeMenu: @MainActor () -> NSMenu
        // `nonisolated(unsafe)`: deinit is nonisolated and only removes the
        // monitor; all writes happen on the main thread (same pattern as
        // WindowEdgeReader's resize observer).
        private nonisolated(unsafe) var monitor: Any?

        init(makeMenu: @escaping @MainActor () -> NSMenu) {
            self.makeMenu = makeMenu
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) {
                [weak self] incoming in
                // Local monitors are delivered on the main thread; the
                // handler type is not annotated, so assert the isolation.
                // NSEvent is not Sendable, so it is rebound unchecked to
                // cross into the isolated block.
                nonisolated(unsafe) let event = incoming
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, self.shouldHandle(event) else { return false }
                    NSMenu.popUpContextMenu(self.makeMenu(), with: event, for: self)
                    return true
                }
                return handled ? nil : incoming
            }
        }

        /// A right-click (or control-click) in this view's window whose
        /// location falls inside the chip.
        private func shouldHandle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            switch event.type {
            case .rightMouseDown: break
            case .leftMouseDown where event.modifierFlags.contains(.control): break
            default: return false
            }
            let point = convert(event.locationInWindow, from: nil)
            return bounds.contains(point)
        }
    }
}

/// Closure target for the overflow-tabs menu items.
private final class TabMenuTarget: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func select(_ sender: Any?) { handler() }
}
