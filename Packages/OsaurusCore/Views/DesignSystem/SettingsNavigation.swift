//
//  SettingsNavigation.swift
//  osaurus
//
//  Pushed pages and the structural groups that close a page:
//
//  - `SettingsBackButton`         "‹ Parent", the header back line's control
//                                 and the Workflows title bar's back button
//  - `SettingsDetailHeader`       icon/avatar + 18pt title + chips + actions
//  - `SettingsDrillInHost/List`   overview rows that push sub-pages
//  - `SettingsAdvancedDisclosure` collapsed power-user options
//  - `SettingsDestructiveZone`    reset / wipe actions, always last
//

import SwiftUI

// MARK: - Back Button

/// "‹ Parent" with hover tint and ⌘[ — the back affordance on every pushed
/// page and detail header bar.
struct SettingsBackButton: View {
    @Environment(\.theme) private var theme

    let title: String
    var verbatim: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.space.s4) {
                Image(systemName: "chevron.left")
                    .font(SettingsFont.glyph)
                titleText
            }
        }
        .assignedSettingsButtonStyle(.tertiary, size: .small)
        .keyboardShortcut("[", modifiers: .command)
        .accessibilityLabel(Text("Back to \(title)", bundle: .module))
    }

    @ViewBuilder
    private var titleText: some View {
        if verbatim {
            Text(verbatim: title)
        } else {
            Text(LocalizedStringKey(title), bundle: .module)
        }
    }
}

// MARK: - Detail Header

/// The title block of a pushed detail page (workflow, automation, plugin,
/// agent sub-page, setup wizard step): leading icon tile or avatar, 18pt
/// title, one-line subtitle, a chips row, and trailing actions. Actions wrap
/// under the title when the pane is narrow.
struct SettingsDetailHeader<Leading: View, Chips: View, Actions: View>: View {
    @Environment(\.theme) private var theme

    /// Verbatim: detail titles are usually user data.
    let title: String
    var subtitle: String?
    @ViewBuilder let leading: Leading
    @ViewBuilder let chips: Chips
    @ViewBuilder let actions: Actions

    @State private var availableWidth: CGFloat = 0
    @State private var actionsWidth: CGFloat = 0

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder chips: () -> Chips = { EmptyView() },
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.leading = leading()
        self.chips = chips()
        self.actions = actions()
    }

    private var hasActions: Bool { Actions.self != EmptyView.self }
    private var hasChips: Bool { Chips.self != EmptyView.self }

    private var stacksActions: Bool {
        guard hasActions, availableWidth > 0, actionsWidth > 0 else { return false }
        return 280 + theme.space.s16 + actionsWidth > availableWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            HStack(alignment: .top, spacing: theme.space.s12) {
                leading
                titleBlock
            }
            if hasActions && stacksActions { actionsRow }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }

    /// Only the title shares a line with the actions; the subtitle and chips
    /// run the full width below them.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            HStack(alignment: .top, spacing: theme.space.s16) {
                Text(verbatim: title)
                    .font(SettingsFont.detailTitle)
                    .foregroundColor(theme.text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if hasActions && !stacksActions { actionsRow }
            }
            if let subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(SettingsFont.body)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hasChips {
                HStack(spacing: theme.space.s6) { chips }
                    .padding(.top, theme.space.s2)
            }
        }
        .layoutPriority(1)
    }

    private var actionsRow: some View {
        HStack(spacing: theme.space.s8) { actions }
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { actionsWidth = $0 }
    }
}

extension SettingsDetailHeader where Leading == SettingsIconTile {
    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        tint: Color? = nil,
        @ViewBuilder chips: () -> Chips = { EmptyView() },
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            leading: { SettingsIconTile(icon: icon, size: 40, tint: tint) },
            chips: chips,
            actions: actions
        )
    }
}

// MARK: - Drill-in

/// One item of a page that splits into drill-in sub-pages.
protocol SettingsDrillInItem: Hashable, Identifiable {
    var title: String { get }
    var icon: String { get }
    /// One line under the row on the overview.
    var subtitle: String { get }
}

/// `selection == nil` shows `overview` (usually a `SettingsDrillInList`),
/// otherwise that item's page, whose `SettingsPageHeader` draws the
/// "‹ rootTitle" back line.
struct SettingsDrillInHost<Item: SettingsDrillInItem, Overview: View, Detail: View>: View {
    @Environment(\.theme) private var theme
    let rootTitle: String
    @Binding var selection: Item?
    @ViewBuilder let overview: () -> Overview
    @ViewBuilder let detail: (Item) -> Detail

    var body: some View {
        Group {
            if let item = selection {
                detail(item)
                    .settingsBackDestination(rootTitle) { selection = nil }
                    .id(item.id)
                    .transition(.opacity)
            } else {
                overview()
                    .transition(.opacity)
            }
        }
        .animation(theme.motion.quick, value: selection)
    }
}

/// A titled group of navigation rows, one per drill-in item.
struct SettingsDrillInList<Item: SettingsDrillInItem>: View {
    var title: String? = nil
    let items: [Item]
    var badges: [Item: Int] = [:]
    let onSelect: (Item) -> Void

    var body: some View {
        SettingsSection(title: title) {
            SettingsDrillInRows(items: items, badges: badges, onSelect: onSelect)
        }
    }
}

/// The rows of a `SettingsDrillInList` without their group, for a page that
/// puts every link it has in one group.
struct SettingsDrillInRows<Item: SettingsDrillInItem>: View {
    @Environment(\.theme) private var theme
    let items: [Item]
    var badges: [Item: Int] = [:]
    let onSelect: (Item) -> Void

    var body: some View {
        ForEach(items) { item in
            SettingsNavigationRow(
                icon: item.icon,
                title: item.title,
                subtitle: item.subtitle,
                badge: badges[item]
            ) {
                withAnimation(theme.motion.quick) { onSelect(item) }
            }
        }
    }
}

// MARK: - Advanced Disclosure

/// Collapsed-by-default home for power-user options. Opens automatically
/// when a settings-search result lands on one of `anchorIds`.
struct SettingsAdvancedDisclosure<Content: View>: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(15, enabled: baseComponentEnabled) }
    @Environment(\.settingsLandingPending) private var pendingLanding

    let title: String
    let anchorIds: Set<String>
    @ViewBuilder let content: Content

    @State private var isExpanded = false

    init(
        title: String = "Advanced",
        anchorIds: Set<String> = [],
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.anchorIds = anchorIds
        self.content = content()
    }

    var body: some View {
        SettingsGroup(assignmentFamily: 15) {
            Button {
                withAnimation(theme.motion.quick) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: theme.catalogLayoutMetric("component.library.15.elements.layout.settingsAdvancedDisclosure.body.horizontalGap", inheriting: theme.catalogMetric("gap", fallback: theme.space.s10))) {
                    Text(LocalizedStringKey(title), bundle: .module)
                        .assignedTypography("component.library.15.label", fallback: SettingsFont.rowTitle)
                        .foregroundColor(theme.text.primary)
                    Spacer(minLength: 0)
                    SettingsChevron()
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }.catalogLayoutTarget("component.library.15.elements.layout.settingsAdvancedDisclosure.body.horizontalGap")
                .frame(maxWidth: .infinity, minHeight: theme.catalogMetric("height", fallback: theme.settingsRowMinHeight))
                .contentShape(Rectangle())
            }
            .assignedBasePlainButtonStyle()
            .assignedBaseKeyboardButton(15, action: toggleExpansion)
            .pointingHandCursor()
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(isExpanded ? Text("Expanded", bundle: .module) : Text("Collapsed", bundle: .module))

            if isExpanded {
                content
            }
        }
        .onAppear { expandIfLanding(pendingLanding) }
        .onChange(of: pendingLanding) { _, id in expandIfLanding(id) }
    }

    private func expandIfLanding(_ id: String?) {
        guard let id, !isExpanded, anchorIds.contains(id) else { return }
        withAnimation(theme.motion.quick) {
            isExpanded = true
        }
    }

    private func toggleExpansion() {
        withAnimation(theme.motion.quick) { isExpanded.toggle() }
    }
}

// MARK: - Destructive Zone

/// The section that closes a page. Same surface as every other group; the
/// red lives on the action button.
struct SettingsDestructiveZone<Content: View>: View {
    let title: String
    var anchorId: String?
    @ViewBuilder let content: Content

    init(title: String = "Danger Zone", anchorId: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.anchorId = anchorId
        self.content = content()
    }

    var body: some View {
        SettingsSection(title: title, anchorId: anchorId) {
            content
        }
    }
}

/// One action inside a `SettingsDestructiveZone`.
struct SettingsDestructiveRow: View {
    enum Severity {
        case warning
        case destructive
    }

    let title: String
    let description: String
    let actionTitle: String
    var severity: Severity
    var anchorId: String?
    let action: () -> Void

    init(
        title: String,
        description: String,
        actionTitle: String,
        severity: Severity = .destructive,
        anchorId: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.description = description
        self.actionTitle = actionTitle
        self.severity = severity
        self.anchorId = anchorId
        self.action = action
    }

    var body: some View {
        SettingsRow(title: title, description: description, anchorId: anchorId) {
            SettingsButton(severity == .destructive ? .destructive : .secondary, actionTitle, size: .compact, action: action)
                .pointingHandCursor()
        }
    }
}
