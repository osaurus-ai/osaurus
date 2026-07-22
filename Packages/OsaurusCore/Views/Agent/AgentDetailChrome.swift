//
//  AgentDetailChrome.swift
//  osaurus
//
//  Shared structural chrome for the two agent *detail* surfaces so the local
//  `AgentDetailView` and the paired `RemoteAgentDetailView` read as one
//  product:
//
//    - `AgentDetailHeaderBar` + `AgentDetailIdentityLabel` +
//      `AgentDetailHeaderActionButton` assemble the compact "back + identity +
//      actions" title bar both views share.
//    - `AgentDetailSection` is the icon + UPPERCASE-title card used for every
//      content block (Identity, Connection, Source, …), with an optional
//      trailing-action slot for per-section affordances (refresh / "View in
//      Insights").
//    - `AgentDetailMetadataRow` / `AgentDetailStatusRow` are the fixed-width
//      label/value rows used inside those cards.
//    - `AgentDetailGroupedTabStrip` is the shared two-level navigation:
//      folder-style group tabs whose selected tab opens into a tinted drawer
//      bar of sub-tab pills (single-tab groups render no drawer). The local
//      detail feeds it five groups; the remote detail feeds it
//      Overview/Activity as single-item groups.
//
//  Sheet-specific chrome (headers, footers, button styles, text fields) lives
//  in `AgentSheetChrome.swift`; this file is for the persistent detail panes.
//

import SwiftUI

// MARK: - Detail Header Bar

/// Compact identity bar shared by the local and remote agent detail views.
/// Owns the back button, hairline divider, padding rhythm (24h / 10v), and the
/// `secondaryBackground` + bottom-border treatment. Callers fill three slots:
///   - `identity`: the avatar + name block (often wrapped in a switcher button
///     or paired with a status badge),
///   - `status`: a transient indicator on the trailing edge (save pill /
///     connection state),
///   - `actions`: the trailing icon buttons (Share/Delete, Chat/Remove).
struct AgentDetailHeaderBar<Identity: View, Status: View, Actions: View>: View {
    @Environment(\.theme) private var theme

    let onBack: () -> Void
    var backTitle: LocalizedStringKey = "Agents"
    @ViewBuilder let identity: () -> Identity
    @ViewBuilder let status: () -> Status
    @ViewBuilder let actions: () -> Actions

    init(
        onBack: @escaping () -> Void,
        backTitle: LocalizedStringKey = "Agents",
        @ViewBuilder identity: @escaping () -> Identity,
        @ViewBuilder status: @escaping () -> Status,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.onBack = onBack
        self.backTitle = backTitle
        self.identity = identity
        self.status = status
        self.actions = actions
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text(backTitle, bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(theme.accentColor)
            }
            .buttonStyle(PlainButtonStyle())

            // Vertical hairline so the back button reads as distinct from the
            // identity block even when the agent name is long.
            Rectangle()
                .fill(theme.primaryBorder)
                .frame(width: 1, height: 16)
                .opacity(0.6)

            identity()

            Spacer(minLength: 8)

            status()

            actions()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(
            theme.secondaryBackground
                .overlay(
                    Rectangle()
                        .fill(theme.primaryBorder)
                        .frame(height: 1),
                    alignment: .bottom
                )
        )
    }
}

/// 28x28 circular icon button used by the detail header for Share / Delete /
/// Chat / Remove. Background is a 12% tint of the foreground color so
/// destructive vs. accent intent reads at a glance without shouting.
struct AgentDetailHeaderActionButton: View {
    @Environment(\.theme) private var theme

    let icon: String
    let tint: Color
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.12)))
        }
        .buttonStyle(PlainButtonStyle())
        .help(Text(help, bundle: .module))
    }
}

/// Small "this is a remote agent" antenna badge, designed to overlay the
/// bottom-trailing corner of an avatar. Matches the decoration on the remote
/// grid card so remote agents read the same way everywhere (header, switcher
/// rows, grid). The ring blends the badge into whatever surface hosts it.
struct RemoteAvatarBadge: View {
    @Environment(\.theme) private var theme

    var glyphSize: CGFloat = 8
    var padding: CGFloat = 3
    /// Color of the 1.5pt ring around the badge — pass the host surface color
    /// (card vs. header background) so the badge reads as floating above it.
    var ringColor: Color? = nil

    var body: some View {
        Image(systemName: "antenna.radiowaves.left.and.right")
            .font(.system(size: glyphSize, weight: .bold))
            .foregroundColor(.white)
            .padding(padding)
            .background(Circle().fill(theme.accentColor))
            .overlay(Circle().strokeBorder(ringColor ?? theme.cardBackground, lineWidth: 1.5))
    }
}

/// Avatar + name (+ optional subtitle + optional switcher chevron) block used
/// inside the header's identity slot. Local wraps it in the agent-switcher
/// button; remote does too, and sets `showsRemoteGlyph` so the avatar carries
/// the antenna decoration instead of a free-floating "Remote" pill.
struct AgentDetailIdentityLabel: View {
    @Environment(\.theme) private var theme

    let mascotId: String?
    let name: String
    let tint: Color
    var subtitle: String? = nil
    var showsChevron: Bool = false
    var customImageURL: URL? = nil
    var diameter: CGFloat = 28
    var monogramFontSize: CGFloat = 13
    var maxWidth: CGFloat? = 260
    /// Overlays the small antenna badge on the avatar to mark a remote agent.
    var showsRemoteGlyph: Bool = false
    /// Surface color the avatar sits on, used for the remote badge ring so it
    /// blends with the header (`secondaryBackground`) vs. a card row.
    var glyphRingColor: Color? = nil

    var body: some View {
        HStack(spacing: 10) {
            AgentAvatarView(
                mascotId: mascotId,
                name: name,
                tint: tint,
                diameter: diameter,
                customImageURL: customImageURL,
                monogramFontSize: monogramFontSize,
                borderWidth: 1.5
            )
            .overlay(alignment: .bottomTrailing) {
                if showsRemoteGlyph {
                    RemoteAvatarBadge(
                        glyphSize: max(6, diameter * 0.26),
                        padding: max(2, diameter * 0.085),
                        ringColor: glyphRingColor
                    )
                    .offset(x: 2, y: 2)
                }
            }
            .animation(.spring(response: 0.3), value: name)
            .animation(.spring(response: 0.3), value: mascotId)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(name.isEmpty ? L("Untitled Agent") : name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if showsChevron {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                    }
                }
                if let subtitle,
                    !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
        }
    }
}

// MARK: - Detail Section Card

/// Icon + UPPERCASE-title card used for every content block on both detail
/// views. The optional `trailing` slot hosts per-section affordances (a refresh
/// button, a "Saved" pill, a "View in Insights" link) on the title row.
struct AgentDetailSection<Trailing: View, Content: View>: View {
    @Environment(\.theme) private var theme

    let title: String
    let icon: String
    var subtitle: String? = nil
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        icon: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.subtitle = subtitle
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 20)

                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.primaryText)
                    .tracking(0.5)

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }

                Spacer()

                trailing()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }
}

extension AgentDetailSection where Trailing == EmptyView {
    /// Convenience for the common case with no trailing action — keeps every
    /// existing `AgentDetailSection(title:icon:) { … }` call site working.
    init(
        title: String,
        icon: String,
        subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title,
            icon: icon,
            subtitle: subtitle,
            trailing: { EmptyView() },
            content: content
        )
    }
}

// MARK: - Rows

/// Fixed-width label + value row used inside detail cards (Mode, Encryption,
/// Model, Relay URL, …). `mono` renders the value in a monospaced font for
/// addresses / URLs.
struct AgentDetailMetadataRow: View {
    @Environment(\.theme) private var theme

    let label: String
    let value: String
    var mono: Bool = false
    var labelWidth: CGFloat = 80

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .frame(width: labelWidth, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 11, design: .monospaced) : .system(size: 11))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
        }
    }
}

/// Label + colored dot + value row, used for connection/health status inside a
/// detail card. Matches `AgentDetailMetadataRow`'s label column so a status row
/// and metadata rows line up in the same section.
struct AgentDetailStatusRow: View {
    @Environment(\.theme) private var theme

    let label: String
    let value: LocalizedStringKey
    let dotColor: Color
    var labelWidth: CGFloat = 80

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .frame(width: labelWidth, alignment: .leading)
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(value, bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            Spacer()
        }
    }
}

// MARK: - Agent Switcher Popover

/// Shared "Switch Agent" popover surfaced from the identity block of BOTH
/// detail headers. Lists every local (non-built-in) agent and every paired
/// remote agent so the user can jump between them without going back to the
/// grid. The host header owns the `isPresented` binding and performs the
/// actual navigation; this view only renders rows and reports taps.
struct AgentSwitcherPopover: View {
    @Environment(\.theme) private var theme

    let localAgents: [Agent]
    let remoteAgents: [RemoteAgent]
    /// Marked with a checkmark when the popover is shown from that agent's own
    /// detail view. At most one of these is non-nil in practice.
    let currentLocalAgentId: UUID?
    let currentRemoteAgentId: UUID?
    let onSelectLocal: (Agent) -> Void
    let onSelectRemote: (RemoteAgent) -> Void
    let onDismiss: () -> Void

    private var totalCount: Int { localAgents.count + remoteAgents.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().opacity(0.5)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(localAgents, id: \.id) { agent in
                        row(
                            mascotId: agent.avatar,
                            name: agent.name,
                            subtitle: agent.description,
                            customImageURL: agent.customAvatarURL,
                            isRemote: false,
                            isCurrent: agent.id == currentLocalAgentId,
                            select: { onSelectLocal(agent) }
                        )
                    }

                    if !remoteAgents.isEmpty {
                        // Only label the remote group when local agents are
                        // also present — otherwise the single list speaks for
                        // itself and the header already says "Switch Agent".
                        if !localAgents.isEmpty {
                            sectionLabel("Remote")
                        }
                        ForEach(remoteAgents, id: \.id) { agent in
                            row(
                                mascotId: agent.avatar,
                                name: agent.name,
                                subtitle: agent.description,
                                customImageURL: nil,
                                isRemote: true,
                                isCurrent: agent.id == currentRemoteAgentId,
                                select: { onSelectRemote(agent) }
                            )
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 280)
        .background(theme.cardBackground)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
            Text("Switch Agent", bundle: .module)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(theme.tertiaryText)
                .tracking(0.5)
            Spacer()
            Text("\(totalCount)", bundle: .module)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(theme.inputBackground))
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func sectionLabel(_ key: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 8, weight: .bold))
            Text(key, bundle: .module)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.5)
        }
        .foregroundColor(theme.tertiaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    /// A single switcher row — avatar (with the antenna badge for remote
    /// agents) + name + optional subtitle, highlighted with a checkmark when
    /// it's the agent the popover was opened from. Tapping the current row just
    /// dismisses; any other row fires `select`.
    private func row(
        mascotId: String?,
        name: String,
        subtitle: String,
        customImageURL: URL?,
        isRemote: Bool,
        isCurrent: Bool,
        select: @escaping () -> Void
    ) -> some View {
        Button {
            if isCurrent { onDismiss() } else { select() }
        } label: {
            HStack(spacing: 10) {
                AgentAvatarView(
                    mascotId: mascotId,
                    name: name,
                    tint: agentColorFor(name),
                    diameter: 26,
                    customImageURL: customImageURL,
                    monogramFontSize: 11,
                    borderWidth: 1.5
                )
                .overlay(alignment: .bottomTrailing) {
                    if isRemote {
                        RemoteAvatarBadge(glyphSize: 6, padding: 2)
                            .offset(x: 2, y: 2)
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(name.isEmpty ? L("Untitled Agent") : name)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    if !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isCurrent ? theme.accentColor.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tab Strip

/// A single tab in `AgentDetailGroupedTabStrip`. `id` doubles as the
/// selection value.
struct AgentDetailTabItem<Tab: Hashable>: Identifiable {
    let id: Tab
    /// Already-localized display label (rendered verbatim).
    let label: String
    let icon: String
    var badgeCount: Int? = nil
    /// Renders the tab in the system warning color regardless of selection —
    /// used for failed-plugin tabs so they're spottable in a long strip.
    var isWarning: Bool = false
    /// Already-localized tooltip shown via `.help()` on hover, so users can
    /// learn what a destination holds before committing to a click.
    var help: String? = nil

    init(
        id: Tab,
        label: String,
        icon: String,
        badgeCount: Int? = nil,
        isWarning: Bool = false,
        help: String? = nil
    ) {
        self.id = id
        self.label = label
        self.icon = icon
        self.badgeCount = badgeCount
        self.isWarning = isWarning
        self.help = help
    }
}

// MARK: - Overflow Scroller

/// Shared horizontal-overflow chrome for the detail tab rows: edge fades +
/// floating "more" chevrons that appear only when the content overflows its
/// viewport, plus auto-scrolling the active selection into view.
private struct AgentDetailOverflowScroller<Selection: Hashable, Content: View>: View {
    @Environment(\.theme) private var theme

    /// Current selection; changes auto-scroll the matching `.id()` into view.
    let selection: Selection
    @ViewBuilder let content: () -> Content

    // Captured via GeometryReaders so the "scrollable" affordance (edge fade +
    // chevron) only renders when the content overflows the viewport AND the
    // user hasn't already scrolled to that edge.
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0

    private var overflowsTrailing: Bool {
        // 1pt fudge so pixel-aligned end-of-scroll positions don't leave a
        // phantom indicator on screen.
        contentWidth > viewportWidth + scrollOffset + 1
    }
    private var overflowsLeading: Bool {
        scrollOffset > 1
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                content()
                    .background(
                        GeometryReader { inner in
                            Color.clear.preference(
                                key: AgentDetailTabContentWidthKey.self,
                                value: inner.size.width
                            )
                        }
                    )
            }
            .background(
                GeometryReader { outer in
                    Color.clear.preference(
                        key: AgentDetailTabViewportWidthKey.self,
                        value: outer.size.width
                    )
                }
            )
            .onPreferenceChange(AgentDetailTabContentWidthKey.self) { contentWidth = $0 }
            .onPreferenceChange(AgentDetailTabViewportWidthKey.self) { viewportWidth = $0 }
            // `onScrollGeometryChange` is the canonical macOS 15+ way to observe
            // scroll offset; the older GeometryReader-in-named-coordinate-space
            // pattern is flaky on horizontal AppKit-backed scroll views.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x
            } action: { _, newOffset in
                scrollOffset = max(0, newOffset)
            }
            // Edge fades on whichever side has off-screen content. `mask` runs
            // before any overlay, so the chevrons sit ON TOP of the fades rather
            // than being faded themselves.
            .mask(fadeMask)
            .overlay(alignment: .leading) {
                if overflowsLeading { scrollMoreChevron(direction: .leading) }
            }
            .overlay(alignment: .trailing) {
                if overflowsTrailing { scrollMoreChevron(direction: .trailing) }
            }
            .animation(.easeOut(duration: 0.2), value: overflowsLeading)
            .animation(.easeOut(duration: 0.2), value: overflowsTrailing)
            // Auto-scroll the active tab into view when it changes (tap or programmatic).
            .onChange(of: selection) { _, newValue in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    /// Linear gradient used as the strip's mask. Fades whichever side has
    /// content scrolled off; both sides can fade at once mid-strip.
    private var fadeMask: LinearGradient {
        let fadeStart: CGFloat = 0.06  // ~6% of the strip on the leading edge
        let fadeEnd: CGFloat = 0.94  // ~6% on the trailing edge
        var stops: [Gradient.Stop] = []
        stops.append(.init(color: overflowsLeading ? .clear : .black, location: 0.0))
        if overflowsLeading {
            stops.append(.init(color: .black, location: fadeStart))
        }
        if overflowsTrailing {
            stops.append(.init(color: .black, location: fadeEnd))
        }
        stops.append(.init(color: overflowsTrailing ? .clear : .black, location: 1.0))
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }

    /// Floating "more →"/"← more" affordance pinned to whichever edge has
    /// off-screen content. Sits above the fade mask so it stays fully opaque,
    /// and is `allowsHitTesting(false)` so it never swallows tab taps.
    private func scrollMoreChevron(direction: HorizontalEdge) -> some View {
        Image(systemName: direction == .leading ? "chevron.left" : "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(theme.accentColor)
            .frame(width: 20, height: 20)
            .background(
                Circle()
                    .fill(theme.primaryBackground)
                    .overlay(Circle().strokeBorder(theme.accentColor.opacity(0.25), lineWidth: 1))
            )
            .shadow(
                color: Color.black.opacity(0.08),
                radius: 4,
                x: direction == .leading ? 1 : -1,
                y: 1
            )
            .padding(direction == .leading ? .leading : .trailing, 2)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.7)))
    }
}

// MARK: - Grouped Tab Strip

/// A named group of tabs for `AgentDetailGroupedTabStrip`. Groups render
/// on the top row; the active group's tabs render as pills on a second
/// row (skipped for single-tab groups).
struct AgentDetailTabGroup<Tab: Hashable>: Identifiable {
    let id: String
    /// Already-localized display label (rendered verbatim).
    let label: String
    let icon: String
    let items: [AgentDetailTabItem<Tab>]
    /// Aggregate badge surfaced on the group button (e.g. automation count).
    var badgeCount: Int? = nil
    /// Renders the group button in the warning color — used when the
    /// group contains a failed plugin so the problem is visible without
    /// opening the group.
    var isWarning: Bool = false

    init(
        id: String,
        label: String,
        icon: String,
        items: [AgentDetailTabItem<Tab>],
        badgeCount: Int? = nil,
        isWarning: Bool = false
    ) {
        self.id = id
        self.label = label
        self.icon = icon
        self.items = items
        self.badgeCount = badgeCount
        self.isWarning = isWarning
    }
}

/// Two-level navigation for the agent detail view: a top row of five-ish
/// stable groups rendered as folder-style tabs (rounded top corners, square
/// bottoms), and a tinted full-width drawer bar holding the active group's
/// tabs as pills. The selected tab and the drawer share the same fill, so
/// the tab visually opens INTO the bar — the second row reads as the
/// contents of the selected tab rather than an unrelated toolbar. Replaces
/// the old single strip of 14+ peers, which made every destination equally
/// (in)visible.
///
/// Selection stays a single `Tab` binding so deep links and programmatic
/// navigation keep working unchanged — the strip derives the active group
/// from the selected tab. Tapping a group restores the last tab the user
/// visited inside it (first tab on first visit).
///
/// Owns its own padding + the drawer's full-bleed background so the two
/// rows read as one navigation component; hosts should not pad it.
struct AgentDetailGroupedTabStrip<Tab: Hashable>: View {
    @Environment(\.theme) private var theme

    let groups: [AgentDetailTabGroup<Tab>]
    @Binding var selection: Tab

    /// Last tab visited per group id, so switching groups round-trips
    /// back to where the user was.
    @State private var lastSelectionByGroup: [String: Tab] = [:]

    private var activeGroup: AgentDetailTabGroup<Tab>? {
        groups.first { group in group.items.contains { $0.id == selection } } ?? groups.first
    }

    /// Shared fill for the selected tab AND the drawer bar — matching them
    /// exactly is what produces the "tab folds open into the bar" effect.
    private var drawerFill: Color {
        theme.secondaryBackground.opacity(0.6)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentDetailOverflowScroller(selection: activeGroup?.id ?? "") {
                groupTabRow
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            if let group = activeGroup, group.items.count > 1 {
                subTabRow(group)
            }
        }
        .onChange(of: selection) { _, newValue in
            if let group = groups.first(where: { $0.items.contains { $0.id == newValue } }) {
                lastSelectionByGroup[group.id] = newValue
            }
        }
    }

    /// Folder-style tab row: the selected tab's fill runs flush into the
    /// drawer bar directly below (no gap, no divider between them).
    private var groupTabRow: some View {
        HStack(spacing: 2) {
            ForEach(groupItems) { item in
                AgentDetailGroupSegment(
                    item: item,
                    isSelected: (activeGroup?.id ?? groups.first?.id) == item.id,
                    selectedFill: drawerFill
                ) {
                    selectGroup(item.id)
                }
                .id(item.id)
            }
        }
    }

    private var groupItems: [AgentDetailTabItem<String>] {
        groups.map { group in
            AgentDetailTabItem(
                id: group.id,
                label: group.label,
                icon: group.icon,
                badgeCount: group.badgeCount,
                isWarning: group.isWarning
            )
        }
    }

    private func selectGroup(_ groupId: String) {
        guard let group = groups.first(where: { $0.id == groupId }) else { return }
        if let remembered = lastSelectionByGroup[groupId],
            group.items.contains(where: { $0.id == remembered })
        {
            selection = remembered
        } else if let first = group.items.first {
            selection = first.id
        }
    }

    /// Full-width drawer bar: a distinctly tinted surface (same fill as the
    /// selected tab, so the two merge) holding the active group's tabs as
    /// pills.
    @ViewBuilder
    private func subTabRow(_ group: AgentDetailTabGroup<Tab>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(group.items) { item in
                    AgentDetailSubTabPill(item: item, isSelected: selection == item.id) {
                        selection = item.id
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 7)
        }
        .background(drawerFill)
    }
}

/// One folder-style tab of the grouped strip's top row: rounded top
/// corners, square bottom, and — when selected — the same fill as the
/// drawer bar below so the tab reads as folding open into it. Unselected
/// tabs get a soft hover wash in the same shape.
private struct AgentDetailGroupSegment: View {
    @Environment(\.theme) private var theme

    let item: AgentDetailTabItem<String>
    let isSelected: Bool
    /// Fill of the drawer bar the selected tab merges into.
    let selectedFill: Color
    let action: () -> Void

    @State private var isHovering = false

    private var tabShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 8,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: 8,
            style: .continuous
        )
    }

    var body: some View {
        // Warning groups keep the system warning color regardless of
        // selection so a failed plugin is spottable before its group is
        // opened; the icon-only accent marks the happy-path selection.
        let labelColor: Color =
            item.isWarning ? .orange : (isSelected ? theme.primaryText : theme.secondaryText)
        let iconColor: Color =
            item.isWarning ? .orange : (isSelected ? theme.accentColor : theme.secondaryText)
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: item.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(iconColor)

                // Constant weight so tabs don't change width (and shift
                // their neighbors) when the selection moves; the tab fill
                // carries the selected state.
                Text(item.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(labelColor)

                if let count = item.badgeCount {
                    Text("\(count)", bundle: .module)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(isSelected ? theme.accentColor : theme.tertiaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(
                                    isSelected
                                        ? theme.accentColor.opacity(0.12) : theme.inputBackground
                                )
                        )
                }
            }
            .fixedSize()
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                tabShape
                    .fill(
                        isSelected
                            ? selectedFill
                            : (isHovering ? theme.secondaryBackground.opacity(0.3) : Color.clear)
                    )
                    .animation(.easeOut(duration: 0.15), value: isSelected)
                    .animation(.easeOut(duration: 0.15), value: isHovering)
            )
            .contentShape(tabShape)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .optionalHelp(item.help)
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// One pill of the grouped strip's secondary row. Selected pills get the
/// accent fill + hairline stroke (matching the Database workspace's section
/// pills); unselected ones get a soft hover wash.
private struct AgentDetailSubTabPill<Tab: Hashable>: View {
    @Environment(\.theme) private var theme

    let item: AgentDetailTabItem<Tab>
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        let foreground: Color =
            item.isWarning ? .orange : (isSelected ? theme.accentColor : theme.secondaryText)
        let strokeColor: Color = {
            if isSelected {
                return item.isWarning
                    ? Color.orange.opacity(0.3) : theme.accentColor.opacity(0.25)
            }
            return Color.clear
        }()
        let fill: Color = {
            if isSelected {
                return item.isWarning
                    ? Color.orange.opacity(0.12) : theme.accentColor.opacity(0.14)
            }
            if item.isWarning { return Color.orange.opacity(0.08) }
            // Contrast against the tinted drawer bar in both light and dark
            // themes (secondary-on-secondary would be invisible).
            return isHovering ? theme.primaryBackground.opacity(0.5) : Color.clear
        }()
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: item.icon)
                    .font(.system(size: 10, weight: .medium))
                // Constant weight so pills don't change width (and shift
                // their neighbors) when the selection moves.
                Text(item.label)
                    .font(.system(size: 11, weight: .medium))
                if let count = item.badgeCount {
                    Text("\(count)", bundle: .module)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(isSelected ? theme.accentColor : theme.tertiaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(
                                    isSelected
                                        ? theme.accentColor.opacity(0.12) : theme.inputBackground
                                )
                        )
                }
            }
            .foregroundColor(foreground)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(fill)
                    .animation(.easeOut(duration: 0.15), value: isHovering)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 1)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .optionalHelp(item.help)
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

extension View {
    /// `.help()` only when a tooltip string exists — avoids registering
    /// empty tooltips for tabs (e.g. plugins) that don't provide one.
    @ViewBuilder
    fileprivate func optionalHelp(_ text: String?) -> some View {
        if let text {
            self.help(text)
        } else {
            self
        }
    }
}

// MARK: - Tab Strip Preference Keys

/// Natural width of the strip's HStack content (before horizontal clipping).
private struct AgentDetailTabContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Visible width of the strip's ScrollView container.
private struct AgentDetailTabViewportWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview("Grouped Tab Strip") {
        struct PreviewWrapper: View {
            @State private var selection: String = "general.configure"

            private var groups: [AgentDetailTabGroup<String>] {
                [
                    AgentDetailTabGroup(
                        id: "general",
                        label: "General",
                        icon: "gear",
                        items: [
                            .init(
                                id: "general.configure", label: "Configure", icon: "gear",
                                help: "Identity, model, and behavior overrides."),
                            .init(
                                id: "general.appearance", label: "Appearance",
                                icon: "paintpalette.fill",
                                help: "Avatar, empty state, and visual theme."),
                        ]
                    ),
                    AgentDetailTabGroup(
                        id: "abilities",
                        label: "Abilities",
                        icon: "wrench.and.screwdriver",
                        items: [
                            .init(id: "abilities.overview", label: "Overview", icon: "switch.2"),
                            .init(
                                id: "abilities.tools", label: "Tools",
                                icon: "wrench.and.screwdriver"),
                            .init(
                                id: "abilities.subagents", label: "Subagents",
                                icon: "person.2.wave.2"),
                            .init(
                                id: "abilities.broken", label: "Broken Plugin",
                                icon: "exclamationmark.triangle.fill", isWarning: true),
                        ],
                        isWarning: true
                    ),
                    AgentDetailTabGroup(
                        id: "connections",
                        label: "Connections",
                        icon: "network",
                        items: [
                            .init(id: "connections.network", label: "Network", icon: "network"),
                            .init(
                                id: "connections.remote", label: "Remote Connections",
                                icon: "person.2.badge.key"),
                        ]
                    ),
                    AgentDetailTabGroup(
                        id: "automation",
                        label: "Automation",
                        icon: "clock.badge.checkmark",
                        items: [
                            .init(
                                id: "automation.automation", label: "Automation",
                                icon: "clock.badge.checkmark")
                        ],
                        badgeCount: 3
                    ),
                    AgentDetailTabGroup(
                        id: "memory",
                        label: "Memory",
                        icon: "brain.head.profile",
                        items: [
                            .init(
                                id: "memory.memory", label: "Memory", icon: "brain.head.profile",
                                badgeCount: 359),
                            .init(
                                id: "memory.database", label: "Database",
                                icon: "cylinder.split.1x2"),
                        ],
                        badgeCount: 359
                    ),
                ]
            }

            var body: some View {
                VStack(alignment: .leading, spacing: 32) {
                    // Full width: two-row state (General has sub-tabs).
                    strip

                    // Narrow width: exercises the overflow fades + chevrons.
                    strip.frame(width: 380)
                }
                .padding(32)
                .frame(width: 760)
            }

            private var strip: some View {
                VStack(spacing: 0) {
                    AgentDetailGroupedTabStrip(groups: groups, selection: $selection)
                    Divider()
                }
            }
        }

        return PreviewWrapper()
    }
#endif
