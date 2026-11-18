//
//  SettingsPage.swift
//  osaurus
//
//  - `SettingsPage`           header + scroll + padding + search landing
//  - `SettingsPageHeader`     the only Management page header, in named slots
//  - `SettingsHeaderToolbar`  chips + search + filters, for the header `toolbar`
//  - `SettingsTabsRow`        tab selector + search + filters, for `toolbar`
//

import SwiftUI

// MARK: - Page

/// Standard scaffold for a Management page: a `SettingsPageHeader` above a
/// scrolling column of `SettingsSection`s. Owns the entrance animation and
/// the settings-search landing scroll.
///
/// Landing is anchor-agnostic: any control tagged `settingsLandingAnchor`
/// inside `content` registers itself via `SettingsLandingAnchorsKey`, and the
/// page scrolls to it when the coordinator publishes that id.
struct SettingsPage<Header: View, Content: View>: View {
    @Environment(\.theme) private var theme

    @ViewBuilder let header: Header
    @ViewBuilder let content: Content

    @State private var hasAppeared = false

    init(@ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.header = header()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            header
                .settingsHeaderEntrance(hasAppeared: hasAppeared)

            ScrollViewReader { proxy in
                ScrollView {
                    SettingsPageContent { content }
                }
                .opacity(hasAppeared ? 1 : 0)
                .settingsLandingScroll(proxy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.canvas)
        .onAppear {
            withAnimation(theme.motion.standard.delay(0.05)) {
                hasAppeared = true
            }
        }
    }
}

/// The padded section column of a page. Use directly inside a custom
/// `ScrollView` when a page can't use `SettingsPage`.
struct SettingsPageContent<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.settingsSectionGap) {
            content
        }
        .settingsPageInsets()
        .settingsBackDestination(nil)
    }
}

extension View {
    /// The page column's insets, for a lazy grid or list that is the whole
    /// scroll body and so can't sit inside `SettingsPageContent`.
    func settingsPageInsets() -> some View {
        modifier(SettingsPageInsetsModifier())
    }
}

private struct SettingsPageInsetsModifier: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, theme.settingsPageInset)
            .padding(.top, theme.settingsPageTop)
            .padding(.bottom, theme.settingsPageBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Header Entrance

extension View {
    /// The page-header entrance: fade + small downward settle, collapsing to
    /// an opacity-only fade under Reduce Motion.
    func settingsHeaderEntrance(hasAppeared: Bool) -> some View {
        modifier(SettingsHeaderEntranceModifier(hasAppeared: hasAppeared))
    }
}

private struct SettingsHeaderEntranceModifier: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let hasAppeared: Bool

    func body(content: Content) -> some View {
        content
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared || reduceMotion ? 0 : -10)
            .animation(theme.motion.springAnimation, value: hasAppeared)
    }
}

// MARK: - Back Destination

/// Where a pushed page's back line returns to. Set by whatever pushed the
/// page (`ManagementChildContainer`, `SettingsDrillInHost`, or a page that
/// swaps in a sub-page) and drawn by that page's `SettingsPageHeader`.
struct SettingsBackDestination {
    let title: String
    var verbatim: Bool = false
    let action: () -> Void
}

private struct SettingsBackDestinationKey: EnvironmentKey {
    static var defaultValue: SettingsBackDestination? { nil }
}

extension EnvironmentValues {
    var settingsBackDestination: SettingsBackDestination? {
        get { self[SettingsBackDestinationKey.self] }
        set { self[SettingsBackDestinationKey.self] = newValue }
    }
}

extension View {
    /// Gives this pushed page's header a "‹ Parent" back line.
    func settingsBackDestination(_ title: String, verbatim: Bool = false, action: @escaping () -> Void) -> some View {
        environment(\.settingsBackDestination, SettingsBackDestination(title: title, verbatim: verbatim, action: action))
    }

    /// Clears an inherited back line, for content below the header that
    /// hosts headers of its own.
    func settingsBackDestination(_ destination: SettingsBackDestination?) -> some View {
        environment(\.settingsBackDestination, destination)
    }
}

// MARK: - Page Header

/// The only Management page header. Callers fill named slots and the header
/// owns their order, so every page reads the same:
///
///     ‹ Parent
///     [leading] Title (count)   [status] [refresh] [utilities] [secondary] [primary] [⋯]
///     Subtitle
///     [toolbar: tabs or chips ………………………………… search, filter, sort]
///
/// - `back line`: drawn when a `settingsBackDestination` is in the environment.
/// - `leading`: icon or avatar, detail pages only.
/// - `count`: size of a library page's collection; hidden at zero.
/// - `status`: a passive indicator (save state, download progress).
/// - `onRefresh`: page-level reload of data fetched from outside the app.
/// - `utilities`: icon-only page tools (filter popover, reorder, diagnostics).
/// - `secondary`: up to two labeled buttons for related views of this page.
/// - `primary`: one creation action ("Add …"), or a primary menu when there
///   are several ways to add.
/// - `overflow`: rare and bulk actions, drawn as the trailing ⋯ menu.
/// - `toolbar`: `SettingsTabsRow` or `SettingsHeaderToolbar`.
///
/// When the window is too narrow for the title and actions on one line, the
/// actions wrap below the title instead of squeezing it (no mid-word title
/// breaks). The choice comes from measured widths, not `ViewThatFits`, which
/// crashed on macOS 15 (see `SettingsTabsRow`).
struct SettingsPageHeader<
    Leading: View, Status: View, Utilities: View, Secondary: View, Primary: View, Overflow: View, Toolbar: View
>: View {
    @Environment(\.theme) private var theme
    @Environment(\.settingsBackDestination) private var back

    let title: String
    let verbatimTitle: Bool
    let subtitle: String?
    let verbatimSubtitle: Bool
    let count: Int?
    let onRefresh: (() -> Void)?
    let refreshHelp: String
    let isRefreshing: Bool
    let overflowHelp: String
    let overflowAnchorId: String?
    @ViewBuilder let leading: Leading
    @ViewBuilder let status: Status
    @ViewBuilder let utilities: Utilities
    @ViewBuilder let secondary: Secondary
    @ViewBuilder let primary: Primary
    @ViewBuilder let overflow: () -> Overflow
    @ViewBuilder let toolbar: Toolbar

    @State private var availableWidth: CGFloat = 0
    @State private var fullActionsWidth: CGFloat = 0
    @State private var collapsedActionsWidth: CGFloat = 0
    @State private var titleWidth: CGFloat = 0

    init(
        title: String,
        verbatimTitle: Bool = false,
        subtitle: String? = nil,
        verbatimSubtitle: Bool = false,
        count: Int? = nil,
        onRefresh: (() -> Void)? = nil,
        refreshHelp: String = "Refresh",
        isRefreshing: Bool = false,
        overflowHelp: String = "More actions",
        overflowAnchorId: String? = nil,
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        @ViewBuilder status: () -> Status = { EmptyView() },
        @ViewBuilder utilities: () -> Utilities = { EmptyView() },
        @ViewBuilder secondary: () -> Secondary = { EmptyView() },
        @ViewBuilder primary: () -> Primary = { EmptyView() },
        @ViewBuilder overflow: @escaping () -> Overflow = { EmptyView() },
        @ViewBuilder toolbar: () -> Toolbar = { EmptyView() }
    ) {
        self.title = title
        self.verbatimTitle = verbatimTitle
        self.subtitle = subtitle
        self.verbatimSubtitle = verbatimSubtitle
        self.count = count
        self.onRefresh = onRefresh
        self.refreshHelp = refreshHelp
        self.isRefreshing = isRefreshing
        self.overflowHelp = overflowHelp
        self.overflowAnchorId = overflowAnchorId
        self.leading = leading()
        self.status = status()
        self.utilities = utilities()
        self.secondary = secondary()
        self.primary = primary()
        self.overflow = overflow
        self.toolbar = toolbar()
    }

    /// The title line never gets narrower than this before actions wrap.
    private static var minimumTitleWidth: CGFloat { 280 }

    private var hasLeading: Bool { Leading.self != EmptyView.self }
    private var hasOverflow: Bool { Overflow.self != EmptyView.self }
    private var hasActions: Bool {
        Status.self != EmptyView.self || onRefresh != nil || Utilities.self != EmptyView.self
            || Secondary.self != EmptyView.self || Primary.self != EmptyView.self || hasOverflow
    }
    private var hasSecondaryRow: Bool { Toolbar.self != EmptyView.self }

    private enum ActionsFit {
        /// Beside the title with full labels.
        case inline
        /// Beside the title, secondary buttons drawn as icons.
        case collapsed
        /// Below the title, full labels. Only when even icons don't fit.
        case stacked
    }

    /// Each width is measured while that form is on screen and remembered,
    /// so deciding never needs a hidden duplicate of the actions (which
    /// could present an action's popover twice).
    private var actionsFit: ActionsFit {
        guard hasActions, availableWidth > 0, fullActionsWidth > 0 else { return .inline }
        let titleNeed = min(max(titleWidth, Self.minimumTitleWidth), availableWidth)
        func fits(_ width: CGFloat) -> Bool {
            titleNeed + theme.space.s16 + width <= availableWidth
        }
        if fits(fullActionsWidth) { return .inline }
        if collapsedActionsWidth == 0 || fits(collapsedActionsWidth) { return .collapsed }
        return .stacked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s16) {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                if let back {
                    SettingsBackButton(title: back.title, verbatim: back.verbatim) {
                        withAnimation(theme.motion.quick) { back.action() }
                    }
                    // The chevron, not the hover wash, lines up with the title.
                    .padding(.leading, -theme.space.s8)
                }
                switch actionsFit {
                case .stacked:
                    VStack(alignment: .leading, spacing: theme.space.s12) {
                        identity
                        actionsRow(collapsed: false)
                    }
                case .inline, .collapsed:
                    if hasLeading {
                        HStack(alignment: .top, spacing: theme.space.s16) {
                            identity
                            Spacer(minLength: 0)
                            if hasActions { actionsRow(collapsed: actionsFit == .collapsed) }
                        }
                    } else {
                        // Only the title shares a line with the actions; the
                        // subtitle runs the full width below them.
                        VStack(alignment: .leading, spacing: theme.space.s4) {
                            HStack(alignment: .center, spacing: theme.space.s16) {
                                titleLine
                                Spacer(minLength: 0)
                                if hasActions { actionsRow(collapsed: actionsFit == .collapsed) }
                            }
                            subtitleText
                        }
                    }
                }
            }

            if hasSecondaryRow {
                toolbar
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .padding(.horizontal, theme.settingsPageInset)
        .padding(.top, back == nil ? theme.space.s24 : theme.space.s16)
        .padding(.bottom, theme.space.s16)
        .background(theme.surface.canvas)
    }

    @ViewBuilder
    private var identity: some View {
        if hasLeading {
            HStack(alignment: .center, spacing: theme.settingsInlineGap) {
                leading
                titleBlock
            }
            .layoutPriority(1)
        } else {
            titleBlock
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            titleLine
            subtitleText
        }
        .layoutPriority(1)
    }

    private var titleLine: some View {
        HStack(alignment: .center, spacing: theme.settingsInlineGap) {
            Group {
                if verbatimTitle {
                    Text(verbatim: title)
                } else {
                    Text(LocalizedStringKey(title), bundle: .module)
                }
            }
            .font(SettingsFont.pageTitle)
            .foregroundColor(theme.text.primary)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
            if let count, count > 0 {
                CountBadge(count)
            }
        }
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleWidth = $0 }
    }

    @ViewBuilder
    private var subtitleText: some View {
        if let subtitle, !subtitle.isEmpty {
            Group {
                if verbatimSubtitle {
                    Text(verbatim: subtitle)
                } else {
                    Text(LocalizedStringKey(subtitle), bundle: .module)
                }
            }
            .font(SettingsFont.pageSubtitle)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actionsRow(collapsed: Bool) -> some View {
        HStack(spacing: theme.settingsControlGap) {
            status
            if let onRefresh {
                SettingsIconButton("arrow.clockwise", isLoading: isRefreshing, help: refreshHelp, action: onRefresh)
            }
            utilities
            secondary
            primary
            if hasOverflow {
                SettingsOverflowMenu(help: overflowHelp, content: overflow)
                    .settingsLandingAnchor(overflowAnchorId)
            }
        }
        .environment(\.settingsCollapsesButtonLabels, collapsed)
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if collapsed { collapsedActionsWidth = width } else { fullActionsWidth = width }
        }
    }
}

// MARK: - Tabs Row

/// The header `toolbar` for a page without tabs: filter chips or a scope
/// control on the leading edge, then search, filter and sort on the
/// trailing edge, the same place `SettingsTabsRow` puts them.
struct SettingsHeaderToolbar<Leading: View, Trailing: View>: View {
    @Environment(\.theme) private var theme
    @Binding var searchText: String
    var searchPlaceholder: LocalizedStringKey
    var showSearch: Bool
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    init(
        searchText: Binding<String> = .constant(""),
        searchPlaceholder: LocalizedStringKey = "Search",
        showSearch: Bool = true,
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self._searchText = searchText
        self.searchPlaceholder = searchPlaceholder
        self.showSearch = showSearch
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: theme.settingsInlineGap) {
            leading
            Spacer(minLength: theme.settingsInlineGap)
            HStack(spacing: theme.settingsControlGap) {
                if showSearch {
                    SearchField(text: $searchText, placeholder: searchPlaceholder)
                }
                trailing
            }
            .fixedSize()
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

/// Tab selector with an optional search field, for a page header's
/// `toolbar`. `trailing` holds filter and sort controls after the search.
struct SettingsTabsRow<Tab: AnimatedTabItem, Trailing: View>: View where Tab.AllCases: RandomAccessCollection {
    @Environment(\.theme) private var theme
    @Binding var selection: Tab
    /// Optional subset of tabs to render (nil == all cases).
    var tabs: [Tab]?
    var counts: [Tab: Int]?
    var badges: [Tab: Int]?
    @Binding var searchText: String
    var searchPlaceholder: LocalizedStringKey
    var showSearch: Bool
    @ViewBuilder let trailing: Trailing

    init(
        selection: Binding<Tab>,
        tabs: [Tab]? = nil,
        counts: [Tab: Int]? = nil,
        badges: [Tab: Int]? = nil,
        searchText: Binding<String> = .constant(""),
        searchPlaceholder: LocalizedStringKey = "Search",
        showSearch: Bool = true,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self._selection = selection
        self.tabs = tabs
        self.counts = counts
        self.badges = badges
        self._searchText = searchText
        self.searchPlaceholder = searchPlaceholder
        self.showSearch = showSearch
        self.trailing = trailing()
    }

    private var hasTrailing: Bool { Trailing.self != EmptyView.self }

    @State private var availableWidth: CGFloat = 0
    @State private var selectorWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0

    /// Whether the selector and search field need to stack vertically.
    ///
    /// This used to be a `ViewThatFits(in: .horizontal)` over the two
    /// layouts. On macOS 15, ViewThatFits sizes its candidates in a deep
    /// re-entrant layout pass that can run on a background render thread;
    /// re-evaluating `AnimatedTabSelector`'s MainActor-isolated `ForEach`
    /// closure there tripped the Swift runtime's executor assertion
    /// (`_dispatch_assert_queue_fail`) and crashed the Images / Privacy /
    /// Server settings tabs (Sentry APPLE-MACOS-1H5, GitHub #2521).
    /// Choosing the layout from measured widths renders each view exactly
    /// once on the main thread, with no candidate sizing pass.
    private var needsStackedLayout: Bool {
        guard showSearch else { return false }
        guard availableWidth > 0, selectorWidth > 0 else { return false }
        let trailingNeed = trailingWidth > 0 ? theme.settingsControlGap + trailingWidth : 0
        return selectorWidth + theme.space.s12 + SearchField.standardWidth + trailingNeed > availableWidth
    }

    /// Tabs wider than the page scroll sideways rather than widening the
    /// window.
    private var selectorOverflows: Bool {
        availableWidth > 0 && selectorWidth > availableWidth
    }

    var body: some View {
        Group {
            if needsStackedLayout {
                VStack(alignment: .leading, spacing: theme.space.s8) {
                    tabSelector
                    HStack(spacing: theme.space.s0) {
                        SearchField(text: $searchText, placeholder: searchPlaceholder, fillsAvailableWidth: true)
                        measuredTrailing
                    }
                }
            } else {
                HStack(spacing: theme.settingsInlineGap) {
                    tabSelector
                    Spacer(minLength: theme.settingsInlineGap)
                    if showSearch || hasTrailing {
                        HStack(spacing: theme.space.s0) {
                            if showSearch {
                                SearchField(text: $searchText, placeholder: searchPlaceholder)
                            }
                            measuredTrailing
                        }
                        .fixedSize()
                    }
                }
            }
        }
        // `minWidth: 0` keeps the measured width at the page's width even
        // when the tabs are wider.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }

    @ViewBuilder
    private var tabSelector: some View {
        if selectorOverflows {
            ScrollView(.horizontal, showsIndicators: false) { measuredSelector }
                // Fades the cut-off edge so the hidden tabs read as scrollable.
                .mask(
                    HStack(spacing: theme.space.s0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 32)
                    }
                )
        } else {
            measuredSelector
        }
    }

    /// Measured at its natural width in both layouts, like the selector, so
    /// a trailing filter counts toward the stacking decision. The gap
    /// before it follows the measured width: a conditional trailing that
    /// renders nothing must not leave the search field short of the edge.
    private var measuredTrailing: some View {
        HStack(spacing: theme.settingsControlGap) { trailing }
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0 }
            .padding(.leading, showSearch && trailingWidth > 0 ? theme.settingsControlGap : 0)
    }

    private var measuredSelector: some View {
        AnimatedTabSelector(selection: $selection, tabs: tabs, counts: counts, badges: badges)
            // Natural width in every layout so the measurement is
            // layout-independent and the layout choice can't oscillate.
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { selectorWidth = $0 }
    }
}

extension SettingsTabsRow where Trailing == EmptyView {
    /// Tabs only, no search.
    init(
        selection: Binding<Tab>,
        tabs: [Tab]? = nil,
        counts: [Tab: Int]? = nil,
        badges: [Tab: Int]? = nil
    ) {
        self.init(selection: selection, tabs: tabs, counts: counts, badges: badges, showSearch: false)
    }
}

// MARK: - Landing Scroll

extension View {
    /// Scrolls this scroll view to a landed settings-search target. Apply to
    /// the `ScrollView` inside a `ScrollViewReader`; pages that don't use
    /// `SettingsPage` need this for search results below the fold.
    func settingsLandingScroll(_ proxy: ScrollViewProxy) -> some View {
        modifier(SettingsLandingScrollModifier(proxy: proxy))
    }
}

private struct SettingsLandingScrollModifier: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.settingsLandingPending) private var pendingLanding
    let proxy: ScrollViewProxy

    @State private var renderedAnchors: Set<String> = []

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(SettingsLandingAnchorsKey.self) { anchors in
                renderedAnchors = anchors
                scrollToLanding(pendingLanding)
            }
            .onChange(of: pendingLanding) { _, id in
                scrollToLanding(id)
            }
            .onAppear {
                scrollToLanding(pendingLanding)
            }
    }

    /// Scrolls a landed search target into view. The control glows itself via
    /// `settingsLandingAnchor`; this only positions it. Ids not rendered here
    /// (other pages' anchors) are no-ops.
    private func scrollToLanding(_ id: String?) {
        guard let id, renderedAnchors.contains(id) else { return }
        // Defer a beat so a freshly expanded disclosure / tab has laid out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(theme.motion.standard) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}
