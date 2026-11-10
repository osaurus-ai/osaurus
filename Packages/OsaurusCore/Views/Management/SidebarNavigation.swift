//
//  SidebarNavigation.swift
//  osaurus
//
//  A reusable sidebar navigation component with collapsible state,
//  animated selection, hover effects, and search functionality.
//  Inspired by macOS System Settings.
//

import SwiftUI

// MARK: - Sidebar Item Data

/// Data model representing a single item in the sidebar navigation.
struct SidebarItemData: Identifiable, Hashable {
    let id: String
    let icon: String
    let label: String
    var badge: Int?
    var badgeHighlight: Bool = false

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: SidebarItemData, rhs: SidebarItemData) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Sidebar Section Data

/// A labeled group of sidebar items. Sections render a small uppercase
/// header when the sidebar is expanded and a thin divider when collapsed.
/// An empty `title` renders the items without a header.
struct SidebarSectionData: Identifiable {
    let id: String
    let title: String
    let items: [SidebarItemData]
    /// Collapsible sections render their header as a disclosure toggle and
    /// hide their items until switched on (Developer Tools). The expansion
    /// choice persists per section id across sessions.
    var isCollapsible: Bool = false
    /// Prominent sections (the pinned Agents / Workflows / Automations block)
    /// render their rows taller, with tinted icon tiles, so the window's
    /// primary destinations stand apart from the settings groups.
    var isProminent: Bool = false
}

/// Persistence for collapsible-section expansion (kept outside the generic
/// `SidebarNavigation` type, which cannot hold static stored properties).
///
/// The Developer Tools switch doubles as a "developer mode" signal: other
/// settings surfaces (provider connectivity card, memory diagnostics tab)
/// read `isDeveloperToolsOn` and re-check on `changed` to hide their
/// developer-grade chrome while the switch is off.
enum SidebarSectionExpansion {
    static let defaultsKey = "settingsSidebarExpandedSections"
    /// Posted after the expansion set persists, so open settings tabs can
    /// react to the Developer Tools switch without relaunching.
    static let changed = Notification.Name("sidebarSectionExpansionChanged")

    static var isDeveloperToolsOn: Bool {
        UserDefaults.standard.stringArray(forKey: defaultsKey)?
            .contains(ManagementSection.developers.rawValue) ?? false
    }
}

// MARK: - Layout Constants

private enum SidebarLayout {
    // Wide enough for the longest tab labels ("Local Models", "Cloud
    // Models") to render on one line next to their badges.
    static let expandedWidth: CGFloat = 240
    static let collapsedWidth: CGFloat = 64
    static let topPadding: CGFloat = 26
    static let bottomPadding: CGFloat = 16
    static let expandedHorizontalPadding: CGFloat = 12
    static let collapsedHorizontalPadding: CGFloat = 8
    static let expandedItemSpacing: CGFloat = 4
    static let collapsedItemSpacing: CGFloat = 6
}

// MARK: - Sidebar Navigation

/// A sidebar navigation container that displays a list of items with selection state,
/// optional badges, and a content area that changes based on selection.
struct SidebarNavigation<Content: View, Footer: View>: View {

    // MARK: Properties

    @Environment(\.theme) private var theme
    @Binding var selection: String
    @Binding var searchText: String
    let sections: [SidebarSectionData]
    let content: (String) -> Content
    let footer: () -> Footer
    /// A page that wants the whole window (the New Agent creator) collapses
    /// the sidebar while it shows; the person's own choice returns after.
    var focusCollapsed = false

    @State private var isCollapsed: Bool
    @State private var collapsedBeforeFocus: Bool?
    /// Off until the window's first layout settles. A width spring while a
    /// still-sparse window lays out moves every hosted view each frame until
    /// AppKit runs out of Update Constraints passes and raises.
    @State private var animatesCollapse = false
    @State private var canScrollDown = true
    @Namespace private var sidebarNamespace

    /// Ids of collapsible sections the user has toggled open, persisted so
    /// the choice survives relaunch.
    @State private var expandedCollapsibleSections: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: SidebarSectionExpansion.defaultsKey) ?? []
    )

    /// Widens with a larger Text Size so the labels, which scale too, keep
    /// fitting on one line.
    private var sidebarWidth: CGFloat {
        isCollapsed ? SidebarLayout.collapsedWidth : SidebarLayout.expandedWidth * max(1, CGFloat(theme.fontScale))
    }

    // MARK: Initialization

    init(
        selection: Binding<String>,
        searchText: Binding<String>,
        sections: [SidebarSectionData],
        focusCollapsed: Bool = false,
        @ViewBuilder content: @escaping (String) -> Content,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self._selection = selection
        self._searchText = searchText
        self.sections = sections
        self.focusCollapsed = focusCollapsed
        // A window opening straight onto a focused page starts collapsed.
        self._isCollapsed = State(initialValue: focusCollapsed)
        self._collapsedBeforeFocus = State(initialValue: focusCollapsed ? false : nil)
        self.content = content
        self.footer = footer
    }

    /// Convenience for a flat, unlabeled item list (previews, simple uses).
    init(
        selection: Binding<String>,
        searchText: Binding<String>,
        items: [SidebarItemData],
        @ViewBuilder content: @escaping (String) -> Content,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.init(
            selection: selection,
            searchText: searchText,
            sections: [SidebarSectionData(id: "main", title: "", items: items)],
            content: content,
            footer: footer
        )
    }

    // MARK: Body

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            divider
            contentArea
        }
        .ignoresSafeArea(edges: .top)
        .onAppear { DispatchQueue.main.async { animatesCollapse = true } }
        .onChange(of: focusCollapsed) { _, focused in
            withAnimation(animatesCollapse ? theme.motion.springAnimation : nil) {
                if focused {
                    collapsedBeforeFocus = isCollapsed
                    isCollapsed = true
                } else if let before = collapsedBeforeFocus {
                    isCollapsed = before
                    collapsedBeforeFocus = nil
                }
            }
        }
    }
}

// MARK: - Sidebar Components

private extension SidebarNavigation {

    var sidebar: some View {
        VStack(alignment: isCollapsed ? .center : .leading, spacing: 0) {
            collapseToggle
            if !isCollapsed { searchField }
            itemList
            if !isCollapsed {
                footer()
                    .padding(.top, 8)
                    .overlay(alignment: .top) { footerScrollShadow }
            }
        }
        .padding(.top, SidebarLayout.topPadding)
        .padding(.bottom, SidebarLayout.bottomPadding)
        .padding(
            .horizontal,
            isCollapsed ? SidebarLayout.collapsedHorizontalPadding : SidebarLayout.expandedHorizontalPadding
        )
        .frame(width: sidebarWidth)
        .background(theme.surface.sidebar)
        .animation(animatesCollapse ? theme.motion.springAnimation : nil, value: isCollapsed)
    }

    var collapseToggle: some View {
        Button {
            withAnimation(theme.motion.springAnimation) {
                isCollapsed.toggle()
            }
        } label: {
            Image(systemName: "sidebar.left")
                .glyphSize(14, weight: .medium)
                .foregroundColor(theme.text.secondary)
                .frame(width: isCollapsed ? 44 : 28, height: 28)
                .settingsChrome(.inset)
        }
        .buttonStyle(.plain)
        .help(isCollapsed ? Text(localized: "Expand Sidebar") : Text(localized: "Collapse Sidebar"))
        .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .trailing)
        .padding(.bottom, isCollapsed ? 12 : 8)
    }

    var searchField: some View {
        SettingsSidebarSearchField(text: $searchText)
            .padding(.bottom, 8)
    }

    var itemList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // The settings inventory is small and bounded. Keeping every
                // row materialized gives off-screen destinations stable
                // accessibility frames while ScrollViewReader moves the
                // selection. A LazyVStack can repeatedly invalidate layout
                // when Accessibility inspects a row during the animated
                // scroll, leaving Settings in a 100% CPU AttributeGraph loop.
                VStack(
                    alignment: isCollapsed ? .center : .leading,
                    spacing: isCollapsed ? SidebarLayout.collapsedItemSpacing : SidebarLayout.expandedItemSpacing
                ) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        sectionHeader(for: section, isFirst: index == 0)

                        if showsItems(for: section) {
                            ForEach(section.items) { item in
                                SidebarItemView(
                                    item: item,
                                    isSelected: selection == item.id,
                                    isCollapsed: isCollapsed,
                                    isProminent: section.isProminent,
                                    namespace: sidebarNamespace
                                ) {
                                    withAnimation(theme.motion.quick) {
                                        selection = item.id
                                    }
                                }
                                .id(item.id)
                            }
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .onAppear { canScrollDown = false }
                        .onDisappear { canScrollDown = true }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
            .onChange(of: selection) { _, newValue in
                // No anchor: scroll only as far as it takes to show the row,
                // so a click on a visible row leaves the list where it is.
                withAnimation(theme.motion.springAnimation) {
                    proxy.scrollTo(newValue)
                }
            }
            .onChange(of: expandedCollapsibleSections) { oldValue, newValue in
                // Switching a collapsible group ON reveals rows that may sit
                // below the fold (Developer Tools is the last group), so
                // scroll its final row into view to show what the switch
                // unlocked. Collapsing scrolls nowhere.
                let opened = newValue.subtracting(oldValue)
                guard let sectionId = opened.first,
                    let lastItem = sections.first(where: { $0.id == sectionId })?.items.last
                else { return }
                // Let the switch's own knob animation and the row insertion
                // (0.2s easeOut) land first, then glide down in a gentle
                // ease — sequencing the two keeps the reveal readable
                // instead of the scroll fighting the toggle mid-flight.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    withAnimation(theme.motion.slow) {
                        proxy.scrollTo(lastItem.id, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                // Ensure initial selection is visible
                proxy.scrollTo(selection, anchor: .center)
            }
        }
    }

    /// Whether a section's items render. Non-collapsible sections always
    /// show; collapsible ones show while toggled on — or while the current
    /// selection lives inside them, so a search result / deeplink can never
    /// land on a hidden tab.
    func showsItems(for section: SidebarSectionData) -> Bool {
        guard section.isCollapsible else { return true }
        return expandedCollapsibleSections.contains(section.id)
            || section.items.contains { $0.id == selection }
    }

    func toggleSectionExpansion(_ section: SidebarSectionData) {
        withAnimation(theme.motion.quick) {
            if expandedCollapsibleSections.contains(section.id) {
                expandedCollapsibleSections.remove(section.id)
            } else {
                expandedCollapsibleSections.insert(section.id)
            }
        }
        UserDefaults.standard.set(
            Array(expandedCollapsibleSections).sorted(),
            forKey: SidebarSectionExpansion.defaultsKey
        )
        NotificationCenter.default.post(name: SidebarSectionExpansion.changed, object: nil)
    }

    /// Group label when expanded; a thin divider between groups when collapsed.
    @ViewBuilder
    func sectionHeader(for section: SidebarSectionData, isFirst: Bool) -> some View {
        if !section.title.isEmpty {
            if isCollapsed {
                if !isFirst {
                    Rectangle()
                        .fill(theme.border.subtle)
                        .frame(width: 24, height: 1)
                        .padding(.vertical, 4)
                }
            } else if section.isCollapsible {
                SidebarCollapsibleSectionHeader(
                    title: section.title,
                    isExpanded: showsItems(for: section),
                    topPadding: isFirst ? 4 : 16
                ) {
                    toggleSectionExpansion(section)
                }
            } else {
                SidebarSectionHeader(title: section.title, topPadding: isFirst ? 4 : 16)
            }
        }
    }

    var footerScrollShadow: some View {
        LinearGradient(
            stops: [
                .init(color: theme.shadow, location: 0),
                .init(color: .clear, location: 1),
            ],
            startPoint: .bottom,
            endPoint: .top
        )
        .frame(height: 24)
        .offset(y: -24)
        .opacity(canScrollDown ? theme.elevation.raised.opacity : 0)
        .animation(theme.motion.quick, value: canScrollDown)
        .allowsHitTesting(false)
    }

    var divider: some View {
        Rectangle()
            .fill(theme.border.subtle)
            .frame(width: 1)
            .ignoresSafeArea(edges: .top)
    }

    var contentArea: some View {
        ZStack {
            content(selection)
                .id(selection)
                .transition(.opacity.animation(theme.motion.quick))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(theme.motion.quick, value: selection)
    }
}

// MARK: - Convenience Initializer (No Footer)

extension SidebarNavigation where Footer == EmptyView {
    init(
        selection: Binding<String>,
        searchText: Binding<String>,
        items: [SidebarItemData],
        @ViewBuilder content: @escaping (String) -> Content
    ) {
        self.init(
            selection: selection,
            searchText: searchText,
            items: items,
            content: content,
            footer: { EmptyView() }
        )
    }
}

// MARK: - Sidebar Item View

/// Individual item row in the sidebar with selection and hover states.
private struct SidebarItemView: View {

    @Environment(\.theme) private var theme

    let item: SidebarItemData
    let isSelected: Bool
    let isCollapsed: Bool
    var isProminent: Bool = false
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            if isCollapsed {
                collapsedContent
            } else {
                expandedContent
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.motion.quick) {
                isHovering = hovering
            }
        }
    }

    // MARK: Collapsed State

    private var collapsedContent: some View {
        ZStack {
            Image(systemName: item.icon)
                .glyphSize(18, weight: .medium)
                .foregroundColor(isSelected ? theme.text.primary : theme.text.secondary)
                .symbolRenderingMode(.hierarchical)

            if item.badge != nil {
                collapsedBadge
            }
        }
        .frame(width: 44, height: 40)
        .background(collapsedBackground)
        .overlay(collapsedBorder)
        .contentShape(RoundedRectangle(cornerRadius: theme.radius.medium))
        .help(item.label)
    }

    private var collapsedBadge: some View {
        Circle()
            .fill(item.badgeHighlight ? theme.status.info.foreground : theme.surface.pressed)
            .overlay(
                Circle().stroke(
                    item.badgeHighlight ? theme.status.info.border : theme.border.default,
                    lineWidth: theme.hairline
                )
            )
            .frame(width: 8, height: 8)
            .offset(x: 12, y: -12)
    }

    private var collapsedBackground: some View {
        RoundedRectangle(cornerRadius: theme.radius.medium)
            .fill(
                isSelected
                    ? theme.surface.selected
                    : (isHovering ? theme.surface.hover : Color.clear)
            )
    }

    private var collapsedBorder: some View {
        RoundedRectangle(cornerRadius: theme.radius.medium)
            .stroke(isSelected ? theme.border.default : Color.clear, lineWidth: theme.stroke.default)
    }

    // MARK: Expanded State

    private var expandedContent: some View {
        HStack(spacing: 10) {
            if isProminent {
                SettingsIconTile(icon: item.icon, size: 26)
            } else {
                Image(systemName: item.icon)
                    .glyphSize(16, weight: .medium)
                    .foregroundColor(isSelected ? theme.text.primary : theme.text.secondary)
                    .frame(width: 24)
            }

            Text(item.label)
                .font(
                    .system(
                        size: (isProminent ? 14 : 13) * CGFloat(theme.fontScale),
                        weight: isSelected || isProminent ? .semibold : .regular,
                        design: .rounded
                    )
                )
                .foregroundColor(isSelected || isProminent ? theme.text.primary : theme.text.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .truncationMode(.tail)
                .help(item.label)

            Spacer(minLength: 4)

            if let badge = item.badge, badge > 0 {
                expandedBadge(count: badge)
            }
        }
        .padding(.horizontal, isProminent ? 10 : 12)
        .padding(.vertical, isProminent ? 8 : 10)
        .background(expandedBackground)
        .contentShape(RoundedRectangle(cornerRadius: theme.radius.medium))
    }

    private func expandedBadge(count: Int) -> some View {
        Text("\(count)", bundle: .module)
            .font(SettingsFont.chip)
            .foregroundColor(
                item.badgeHighlight ? theme.action.primary.default.foreground : theme.text.secondary
            )
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(
                    item.badgeHighlight ? theme.action.primary.default.background : theme.surface.pressed))
    }

    private var expandedBackground: some View {
        // Every `SidebarItemView` lives inside a parent `VStack` + `ForEach`
        // and was previously registering `.matchedGeometryEffect(id:"sidebar_selection",
        // in: namespace)` inside the `isSelected` branch. SwiftUI requires that
        // exactly one view own a given (id, namespace) pair at a time, but during
        // selection transitions the outgoing selected row and the incoming one
        // can briefly both be `isSelected == true`, tripping a Swift runtime
        // precondition in Debug builds (EXC_BREAKPOINT at the geometry-effect
        // source check). Release builds compile the precondition away, which is
        // why the DMG looked fine while Xcode builds crashed on Settings open.
        //
        // Switching to a plain conditional fill + `.animation()` keeps the
        // selected-highlight visual (cross-fade between selected / hover / none)
        // without the single-source invariant. We lose the cross-row pill slide,
        // which was subtle enough that it's not worth the crash surface.
        RoundedRectangle(cornerRadius: theme.radius.medium)
            .fill(
                isSelected
                    ? theme.surface.selected
                    : (isHovering ? theme.surface.hover : Color.clear)
            )
            .animation(theme.motion.standard, value: isSelected)
            .animation(theme.motion.quick, value: isHovering)
    }
}

// MARK: - Sidebar Section Header

/// Optional section header for grouping sidebar items.
struct SidebarSectionHeader: View {
    @Environment(\.theme) private var theme
    let title: String
    var topPadding: CGFloat = 16

    var body: some View {
        Text(title.uppercased())
            .font(SettingsFont.count)
            .foregroundColor(theme.text.tertiary)
            .padding(.horizontal, 12)
            .padding(.top, topPadding)
            .padding(.bottom, 4)
    }
}

/// Section header with a literal switch for collapsible groups (Developer
/// Tools): same typography as `SidebarSectionHeader`, plus a trailing mini
/// toggle that shows the group's tabs while on.
struct SidebarCollapsibleSectionHeader: View {
    @Environment(\.theme) private var theme
    let title: String
    let isExpanded: Bool
    var topPadding: CGFloat = 16
    let action: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(title.uppercased())
                .font(SettingsFont.count)
                .foregroundColor(theme.text.tertiary)
            Spacer(minLength: 0)
            Toggle(
                "",
                isOn: Binding(
                    get: { isExpanded },
                    set: { _ in action() }
                )
            )
            .settingsMiniSwitch()
            .localizedHelp("Show Developer Tools in the sidebar")
        }
        .padding(.horizontal, 12)
        .padding(.top, topPadding)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(
            isExpanded ? Text("Shown", bundle: .module) : Text("Hidden", bundle: .module)
        )
    }
}

// MARK: - Sidebar Search Field

/// Search field component for the settings sidebar.
private struct SettingsSidebarSearchField: View {
    @Environment(\.theme) private var theme
    @Binding var text: String
    @FocusState private var isFocused: Bool
    @State private var isClearHovering = false

    var body: some View {
        HStack(spacing: 8) {
            searchIcon
            textField
            if !text.isEmpty { clearButton }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(fieldBackground)
        .animation(theme.motion.quick, value: isFocused)
    }

    private var searchIcon: some View {
        Image(systemName: "magnifyingglass")
            .glyphSize(12, weight: .medium)
            .foregroundColor(isFocused ? theme.text.primary : theme.text.tertiary)
    }

    private var textField: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text("Search Settings", bundle: .module)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)
                    .allowsHitTesting(false)
            }
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .textStyle(.caption)
                .foregroundColor(theme.text.primary)
                .focused($isFocused)
        }
    }

    private var clearButton: some View {
        Button {
            text = ""
        } label: {
            Image(systemName: "xmark.circle.fill")
                .glyphSize(11)
                .foregroundColor(isClearHovering ? theme.text.secondary : theme.text.tertiary)
        }
        .buttonStyle(.plain)
        .onHover { isClearHovering = $0 }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: theme.radius.medium)
            .fill(theme.surface.raised)
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .stroke(
                        isFocused ? theme.border.focus : theme.border.strong,
                        lineWidth: isFocused ? theme.stroke.focus : theme.stroke.default
                    )
            )
    }
}

// MARK: - Sidebar Update Button

/// Footer button that shows update status and triggers update checks.
struct SidebarUpdateButton: View {
    @Environment(\.theme) private var theme

    let updateAvailable: Bool
    let availableVersion: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            if updateAvailable {
                updateAvailableContent
            } else {
                checkForUpdatesContent
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.motion.quick) {
                isHovering = hovering
            }
        }
        .help(updateAvailable ? Text(localized: "Install the latest update") : Text(localized: "Check for app updates"))
        .animation(theme.motion.quick, value: updateAvailable)
    }

    private var updateAvailableContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.circle.fill")
                .glyphSize(16, weight: .medium)

            VStack(alignment: .leading, spacing: 2) {
                Text("Update Available", bundle: .module)
                    .font(SettingsFont.compactLabel)
                if let version = availableVersion {
                    Text("v\(version)", bundle: .module)
                        .font(SettingsFont.monoSmall)
                        .opacity(0.8)
                }
            }

            Spacer()
        }
        .foregroundColor(
            isHovering ? theme.action.primary.hover.foreground : theme.action.primary.default.foreground
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.medium)
                .fill(isHovering ? theme.action.primary.hover.background : theme.action.primary.default.background)
        )
        .contentShape(RoundedRectangle(cornerRadius: theme.radius.medium))
    }

    private var checkForUpdatesContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.circle")
                .glyphSize(14, weight: .medium)

            Text("Check for Updates", bundle: .module)
                .font(SettingsFont.compactLabel)

            Spacer()
        }
        .foregroundColor(theme.text.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .settingsChrome(isHovering ? .hover : nil)
        .contentShape(RoundedRectangle(cornerRadius: theme.radius.medium))
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        struct PreviewWrapper: View {
            @State private var selection = "models"
            @State private var searchText = ""

            var body: some View {
                SidebarNavigation(
                    selection: $selection,
                    searchText: $searchText,
                    items: [
                        SidebarItemData(id: "models", icon: "cube.box.fill", label: "Models"),
                        SidebarItemData(id: "tools", icon: "wrench.and.screwdriver.fill", label: "Tools", badge: 2),
                        SidebarItemData(id: "settings", icon: "gearshape.fill", label: "Settings"),
                    ]
                ) { selected in
                    Text("Content for \(selected)", bundle: .module)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: 800, height: 600)
            }
        }

        return PreviewWrapper()
    }
#endif
