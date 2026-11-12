//
//  SettingsSection.swift
//  osaurus
//
//  The grouped-form surface (macOS System Settings): a Title Case title
//  above one flat rounded group whose rows carry no chrome of their own and
//  are separated by inset hairlines.
//
//  - `SettingsSection`        title + caption + accessory + group + footer
//  - `SettingsSectionHeader`  the header alone, for sections whose body is
//                             not a group (card grids, custom layouts)
//  - `SettingsGroup`          the bare group surface
//

import SwiftUI

// MARK: - Group Environment

private struct SettingsInGroupKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while rendering inside a `SettingsGroup`. Row chrome reads it to
    /// drop its standalone card.
    var settingsInGroup: Bool {
        get { self[SettingsInGroupKey.self] }
        set { self[SettingsInGroupKey.self] = newValue }
    }
}

// MARK: - Group

/// One flat grouped-form surface. Direct children become rows: each is inset
/// and separated from the next by an inset hairline.
struct SettingsGroup<Content: View>: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private static var inspectionDefaultFamily: Int {
        return 57
    }
    private var resolvedFamily: Int { baseTheme.inspectionProductFamily(for: "background", fallback: assignmentFamily == 13 ? (Self.inspectionDefaultFamily == 57 ? 57 : 13) : assignmentFamily) }
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(resolvedFamily, enabled: baseComponentEnabled) }
    var assignmentFamily: Int
    @ViewBuilder let content: Content

    init(assignmentFamily: Int = 13, @ViewBuilder content: () -> Content) {
        self.assignmentFamily = assignmentFamily
        self.content = content()
    }

    var body: some View {
        Group(subviews: content) { subviews in
            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.57.elements.layout.settingsGroup.body.verticalGap", inheriting: theme.catalogMetric("gap", fallback: theme.space.s0))) {
                ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                    subview
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, theme.catalogLayoutMetric("component.library.57.elements.layout.settingsGroup.body.paddingX", inheriting: theme.catalogMetric("padding", fallback: theme.space.s16))).catalogLayoutTarget("component.library.57.elements.layout.settingsGroup.body.paddingX")
                        .padding(.vertical, theme.catalogLayoutMetric("component.library.57.elements.layout.settingsGroup.body.paddingY", inheriting: theme.catalogMetric("padding", fallback: theme.space.s12))).catalogLayoutTarget("component.library.57.elements.layout.settingsGroup.body.paddingY")
                    if index < subviews.count - 1 {
                        SettingsGroupDivider()
                    }
                }
            }.catalogLayoutTarget("component.library.57.elements.layout.settingsGroup.body.verticalGap")
        }
        .environment(\.settingsInGroup, true)
        .assignedBaseChrome(resolvedFamily, fallback: .surface)
        .environment(\.theme, theme)
        .environment(\.baseAssignmentFamily, 14)
    }
}

/// The inset hairline between two rows of a group.
struct SettingsGroupDivider: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private static var inspectionDefaultFamily: Int {
        return 57
    }
    private var resolvedFamily: Int { baseTheme.inspectionProductFamily(for: "heading", fallback: Self.inspectionDefaultFamily) }
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(resolvedFamily, enabled: baseComponentEnabled) }

    var body: some View {
        ThemeHairlineDivider(color: theme.assignedColor("component.library.\(resolvedFamily).border", fallback: theme.rowRule))
            .padding(.leading, theme.space.s16)
    }
}

// MARK: - Section Header

/// Title, optional live caption beside it ("1 connected · 12 tools"),
/// optional subtitle beneath, and a trailing accessory (search, ⋯, button).
struct SettingsSectionHeader<Accessory: View>: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private static var inspectionDefaultFamily: Int {
        return 57
    }
    private var resolvedFamily: Int { baseTheme.inspectionProductFamily(for: "heading", fallback: Self.inspectionDefaultFamily) }
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(resolvedFamily, enabled: baseComponentEnabled) }

    let title: String
    /// Already-localized, dynamic caption; rendered verbatim.
    var caption: String?
    /// Catalog key for a one-line explanation beneath the title.
    var subtitle: String?
    /// Render `title` verbatim (plugin- or user-supplied).
    var verbatimTitle: Bool
    /// SF Symbol before the title, for sections that name a kind of thing
    /// (an automation's trigger, its action).
    var icon: String?
    @ViewBuilder let accessory: Accessory

    init(
        title: String,
        caption: String? = nil,
        subtitle: String? = nil,
        verbatimTitle: Bool = false,
        icon: String? = nil,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.caption = caption
        self.subtitle = subtitle
        self.verbatimTitle = verbatimTitle
        self.icon = icon
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: theme.catalogLayoutMetric("component.library.57.elements.layout.settingsSectionHeader.body.horizontalGap", inheriting: theme.catalogMetric("gap", fallback: theme.space.s8))) {
            VStack(alignment: .leading, spacing: theme.space.s2) {
                HStack(alignment: .firstTextBaseline, spacing: theme.catalogLayoutMetric("component.library.57.elements.layout.settingsSectionHeader.body.horizontalGap2", inheriting: theme.catalogMetric("gap", fallback: theme.space.s8))) {
                    if let icon {
                        Image(systemName: icon)
                            .font(SettingsFont.glyph)
                            .foregroundColor(theme.text.secondary)
                            .accessibilityHidden(true)
                    }
                    titleText
                        .assignedTypography("component.library.\(resolvedFamily).heading", fallback: SettingsFont.sectionTitle)
                        .foregroundColor(theme.text.primary)
                        .accessibilityAddTraits(.isHeader)
                    if let caption, !caption.isEmpty {
                        Text(verbatim: caption)
                            .assignedTypography("component.library.\(resolvedFamily).caption", fallback: SettingsFont.rowDescription)
                            .foregroundColor(theme.text.tertiary)
                            .lineLimit(1)
                    }
                }.catalogLayoutTarget("component.library.57.elements.layout.settingsSectionHeader.body.horizontalGap2")
                if let subtitle, !subtitle.isEmpty {
                    Text(LocalizedStringKey(subtitle), bundle: .module)
                        .assignedTypography("component.library.\(resolvedFamily).caption", fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: theme.space.s8)
            accessory
        }.catalogLayoutTarget("component.library.57.elements.layout.settingsSectionHeader.body.horizontalGap")
        .padding(.leading, theme.space.s2)
        .frame(minHeight: theme.catalogMetric("height", fallback: 22))
    }

    private var titleText: Text {
        verbatimTitle ? Text(verbatim: title) : Text(LocalizedStringKey(title), bundle: .module)
    }
}

/// The small caption below a group, explaining the group as a whole.
struct SettingsGroupFooter: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private static var inspectionDefaultFamily: Int {
        return 57
    }
    private var resolvedFamily: Int { baseTheme.inspectionProductFamily(for: "heading", fallback: Self.inspectionDefaultFamily) }
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(resolvedFamily, enabled: baseComponentEnabled) }

    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(LocalizedStringKey(text), bundle: .module)
            .assignedTypography("component.library.\(resolvedFamily).caption", fallback: SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, theme.space.s2)
    }
}

// MARK: - Section

/// The only section shape. `layout: .grouped` (default) wraps the content in
/// a `SettingsGroup`, so direct children become rows; `.plain` stacks the
/// content under the header as-is (library card grids, wide editors).
struct SettingsSection<Accessory: View, Content: View>: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private static var inspectionDefaultFamily: Int {
        return 57
    }
    private var resolvedFamily: Int { baseTheme.inspectionProductFamily(for: "heading", fallback: Self.inspectionDefaultFamily) }
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(resolvedFamily, enabled: baseComponentEnabled) }
    enum Layout {
        case grouped
        case plain
    }

    let title: String?
    var caption: String?
    var subtitle: String?
    var footer: String?
    /// Settings-search landing anchor for section-level results.
    var anchorId: String?
    var layout: Layout
    var verbatimTitle: Bool
    var icon: String?
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    init(
        title: String? = nil,
        caption: String? = nil,
        subtitle: String? = nil,
        footer: String? = nil,
        anchorId: String? = nil,
        layout: Layout = .grouped,
        verbatimTitle: Bool = false,
        icon: String? = nil,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.caption = caption
        self.subtitle = subtitle
        self.verbatimTitle = verbatimTitle
        self.icon = icon
        self.footer = footer
        self.anchorId = anchorId
        self.layout = layout
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.57.elements.layout.settingsSection.body.verticalGap", inheriting: theme.catalogMetric("gap", fallback: theme.space.s8))) {
            if let title {
                SettingsSectionHeader(
                    title: title,
                    caption: caption,
                    subtitle: subtitle,
                    verbatimTitle: verbatimTitle,
                    icon: icon
                ) { accessory }
            }
            switch layout {
            case .grouped:
                SettingsGroup { content }
            case .plain:
                VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.57.elements.layout.settingsSection.body.verticalGap2", inheriting: theme.catalogMetric("gap", fallback: theme.space.s12))) { content }.catalogLayoutTarget("component.library.57.elements.layout.settingsSection.body.verticalGap2")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let footer, !footer.isEmpty {
                SettingsGroupFooter(footer)
            }
        }.catalogLayoutTarget("component.library.57.elements.layout.settingsSection.body.verticalGap")
        .settingsLandingAnchor(anchorId)
        .environment(\.theme, theme)
        .environment(\.baseAssignmentFamily, 14)
    }
}

extension SettingsSection where Accessory == EmptyView {
    init(
        title: String? = nil,
        caption: String? = nil,
        subtitle: String? = nil,
        footer: String? = nil,
        anchorId: String? = nil,
        layout: Layout = .grouped,
        verbatimTitle: Bool = false,
        icon: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            caption: caption,
            subtitle: subtitle,
            footer: footer,
            anchorId: anchorId,
            layout: layout,
            verbatimTitle: verbatimTitle,
            icon: icon,
            accessory: { EmptyView() },
            content: content
        )
    }
}
