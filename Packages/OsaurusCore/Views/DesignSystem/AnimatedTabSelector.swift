//
//  AnimatedTabSelector.swift
//  osaurus
//
//  Modern animated tab selector with sliding indicator using matchedGeometryEffect.
//  Used for sub-navigation within Models and Tools views.
//

import SwiftUI

// MARK: - Tab Item Protocol

protocol AnimatedTabItem: Hashable, CaseIterable {
    var title: String { get }
}

// MARK: - Animated Tab Selector

struct AnimatedTabSelector<Tab: AnimatedTabItem>: View where Tab.AllCases: RandomAccessCollection {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(6, enabled: baseComponentEnabled) }
    @Binding var selection: Tab
    /// Tabs to render, in order. Defaults to every case; callers with a
    /// dynamic subset (e.g. Themes only shows filters that have results) pass
    /// their own list so empty tabs don't clutter the selector.
    let tabs: [Tab]
    let counts: [Tab: Int]?
    let badges: [Tab: Int]?

    @FocusState private var focused: Bool

    init(
        selection: Binding<Tab>,
        tabs: [Tab]? = nil,
        counts: [Tab: Int]? = nil,
        badges: [Tab: Int]? = nil
    ) {
        self._selection = selection
        self.tabs = tabs ?? Array(Tab.allCases)
        self.counts = counts
        self.badges = badges
    }

    var body: some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.6.elements.layout.animatedTabSelector.body.horizontalGap", inheriting: theme.space.s4)) {
            ForEach(tabs, id: \.self) { tab in
                AnimatedTabButton(
                    tab: tab,
                    isSelected: selection == tab,
                    count: counts?[tab],
                    badge: badges?[tab],
                    showsKeyboardFocus: focused && selection == tab
                ) {
                    select(tab)
                    focused = true
                }
            }
        }.catalogLayoutTarget("component.library.6.elements.layout.animatedTabSelector.body.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.6.elements.layout.animatedTabSelector.body.padding.horizontal", inheriting: theme.space.s4)).padding(.vertical, theme.catalogLayoutMetric("component.library.6.elements.layout.animatedTabSelector.body.padding.vertical", inheriting: theme.space.s4)).catalogLayoutTarget("component.library.6.elements.layout.animatedTabSelector.body.padding.horizontal").catalogLayoutTarget("component.library.6.elements.layout.animatedTabSelector.body.padding.vertical")
        .background(
            RoundedRectangle(cornerRadius: theme.segmentedTrackRadius, style: .continuous)
                .fill(theme.assignedColor("component.library.6.background", fallback: theme.surface.raised))
        )
        .focusable(baseComponentEnabled && !tabs.isEmpty)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
        .accessibilityRepresentation {
            Picker("", selection: $selection) {
                ForEach(tabs, id: \.self) { tab in
                    Text(verbatim: accessibleTitle(for: tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(Text("Tabs", bundle: .module))
        }
        .nativeCatalogTarget([NativeCatalogAssignment.key("component.library.6.background", theme: theme)], "Tab track")
    }

    private func select(_ tab: Tab) {
        withAnimation(reduceMotion ? nil : theme.motion.quick) { selection = tab }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard baseComponentEnabled, !tabs.isEmpty else { return .ignored }
        let next = tabs.firstIndex(of: selection).map { ($0 + delta + tabs.count) % tabs.count }
            ?? (delta > 0 ? 0 : tabs.count - 1)
        select(tabs[next])
        return .handled
    }

    private func accessibleTitle(for tab: Tab) -> String {
        var parts = [tab.title]
        if let count = counts?[tab] { parts.append(count.formatted()) }
        if let badge = badges?[tab], badge > 0 {
            parts.append(String(localized: "\(badge) need attention", bundle: .module))
        }
        return parts.joined(separator: ", ")
    }
}

extension ThemeProtocol {
    /// The segmented track and its selected segment, shared with
    /// `AssignedBaseSegmentedPicker` so tab rows and segmented controls match.
    var segmentedTrackRadius: CGFloat { assignedMetric("component.library.6.radius", fallback: radius.medium) }
    var segmentedSegmentRadius: CGFloat { max(0, segmentedTrackRadius - space.s4) }
    var segmentedSelectionBorder: Color {
        assignedColor("component.library.6.selectedBorder", fallback: border.strong)
    }

    /// The hairline that marks a selected row, chip or segment. Light themes
    /// paint `surface.selected` the same as `surface.hover` and barely apart
    /// from the surfaces around it, so the fill alone does not read; dark
    /// themes separate the fills and draw no line. Read from the unscoped
    /// theme: a component family scope remaps `border.strong` to the
    /// family's own border, which can be too faint to mark selection.
    var selectionBorder: Color { isDark ? .clear : unscopedTheme.border.strong }

    /// Line width for `selectionBorder`. A family scope can set
    /// `stroke.default` to zero, which would hide the hairline.
    var selectionStroke: CGFloat { isDark ? stroke.default : unscopedTheme.stroke.default }

    private var unscopedTheme: any ThemeProtocol {
        if let scoped = self as? CatalogResolvedTheme { return scoped.base.unscopedTheme }
        return self
    }

    /// The unfilled part of a slider, progress or level track. In light
    /// themes `surface.selected` is too close to raised cards to show how
    /// long the track is, so it takes the default border colour instead.
    func emptyTrack(_ assigned: Color) -> Color { isDark ? assigned : border.default }

    /// The hairline between rows of a group or under a table header.
    /// `border.subtle` nearly vanishes on light raised cards.
    var rowRule: Color { isDark ? border.subtle : border.default }
}

// MARK: - Animated Tab Button

private struct AnimatedTabButton<Tab: AnimatedTabItem>: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(6, enabled: baseComponentEnabled) }

    let tab: Tab
    let isSelected: Bool
    let count: Int?
    let badge: Int?
    let showsKeyboardFocus: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.catalogLayoutMetric("component.library.6.elements.layout.animatedTabButton.body.horizontalGap", inheriting: theme.catalogMetric("gap", fallback: theme.space.s6))) {
                Text(tab.title)
                    .assignedTypography("component.library.6.text", fallback: SettingsFont.rowTitle)
                    .foregroundColor(isSelected ? theme.text.primary : theme.text.secondary)

                if let count = count {
                    CountBadge(count, typographyKey: "component.library.6.caption")
                }

                if let badge = badge, badge > 0 {
                    CountBadge(badge, prominence: .attention, typographyKey: "component.library.6.caption")
                }
            }.catalogLayoutTarget("component.library.6.elements.layout.animatedTabButton.body.horizontalGap")
            .fixedSize()
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.6.elements.layout.animatedTabButton.body.paddingX", inheriting: theme.space.s12)).catalogLayoutTarget("component.library.6.elements.layout.animatedTabButton.body.paddingX")
            .padding(.vertical, theme.catalogLayoutMetric("component.library.6.elements.layout.animatedTabButton.body.paddingY", inheriting: theme.space.s4)).catalogLayoutTarget("component.library.6.elements.layout.animatedTabButton.body.paddingY")
            .background(
                RoundedRectangle(cornerRadius: theme.segmentedSegmentRadius, style: .continuous)
                    .fill(
                        isSelected
                            ? theme.assignedColor("component.library.6.selected", fallback: theme.surface.selected)
                            : (isHovering ? theme.surface.hover : Color.clear)
                    )
            )
            .overlay {
                if isSelected && baseComponentEnabled && !theme.isDark {
                    RoundedRectangle(cornerRadius: theme.segmentedSegmentRadius, style: .continuous)
                        .strokeBorder(theme.segmentedSelectionBorder, lineWidth: theme.stroke.default)
                        .allowsHitTesting(false)
                }
            }
            .nativeCatalogTarget(isSelected ? ["selected", "selectedBorder"].map {
                NativeCatalogAssignment.key("component.library.6." + $0, theme: theme)
            } : [], "Selected tab")
            .contentShape(RoundedRectangle(cornerRadius: theme.segmentedSegmentRadius, style: .continuous))
        }
        .assignedBasePlainButtonStyle()
        .focusable(false)
        .assignedBaseFocusRing(6, visible: showsKeyboardFocus && baseComponentEnabled, radius: theme.segmentedSegmentRadius)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : theme.motion.quick) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Tools Tab (for ToolsManagerView)

enum ToolsTab: String, CaseIterable, AnimatedTabItem {
    /// MCP services: configured services + the browsable Directory. Default tab.
    case services = "Services"
    /// Every usable tool grouped by source, with per-tool permissions.
    case all = "All"
    /// Raw value predates the "Plugins" title; kept for deep-link stability.
    case nativePlugins = "Native Plugins"

    var title: String {
        switch self {
        case .services: return L("Services")
        case .all: return L("All Tools")
        case .nativePlugins: return L("Plugins")
        }
    }

    /// Resolves a deep-link raw value, accepting the legacy tab names
    /// ("Connections" / "MCP" / "Remote" / "Available" / "Sandbox") that
    /// pre-date the current Services / All Tools / Plugins information
    /// architecture. The retired Custom tab now lives as a section on the All
    /// Tools tab, so its deep links land there.
    static func resolved(from rawValue: String) -> ToolsTab? {
        if let tab = ToolsTab(rawValue: rawValue) { return tab }
        switch rawValue.lowercased() {
        case "connections", "connection", "mcp", "remote", "services", "service": return .services
        case "available", "all tools": return .all
        case "sandbox", "custom": return .all
        case "plugins", "native plugins": return .nativePlugins
        default: return nil
        }
    }
}

// MARK: - Skills Tab (for SkillsView)

/// Source-based filters for the Skills library. Every installed skill is
/// automatically available to custom agents, so the tabs slice by where a
/// skill came from rather than by an enablement state.
enum SkillsTab: String, CaseIterable, AnimatedTabItem {
    case all = "All"
    case custom = "Custom"
    case claudePlugins = "Claude Plugins"

    var title: String {
        switch self {
        case .all: return L("All")
        case .custom: return L("Custom")
        case .claudePlugins: return L("Claude Plugins")
        }
    }
}

// MARK: - Plugins Tab (for PluginsView)

enum PluginsTab: String, CaseIterable, AnimatedTabItem {
    case installed = "Installed"
    case browse = "Browse"
    case claude = "Claude Plugins"

    var title: String {
        switch self {
        case .installed: return L("Installed")
        case .browse: return L("Browse")
        case .claude: return L("Claude Plugins")
        }
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        struct PreviewWrapper: View {
            @Environment(\.theme) private var theme
            @State private var modelTab: ModelListTab = .all
            @State private var toolsTab: ToolsTab = .all
            @State private var pluginsTab: PluginsTab = .installed

            var body: some View {
                VStack(spacing: theme.space.s40) {
                    AnimatedTabSelector(
                        selection: $modelTab,
                        counts: [.all: 150, .downloaded: 3]
                    )

                    AnimatedTabSelector(
                        selection: $toolsTab
                    )

                    AnimatedTabSelector(
                        selection: $pluginsTab,
                        counts: [.installed: 3, .browse: 24],
                        badges: [.browse: 2]
                    )
                }
                .padding(theme.space.s40)
                .background(CustomizableTheme.light().surface.canvas)
            }
        }

        return PreviewWrapper()
    }
#endif
