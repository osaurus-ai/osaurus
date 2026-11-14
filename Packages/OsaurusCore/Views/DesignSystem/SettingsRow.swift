//
//  SettingsRow.swift
//  osaurus
//
//  The row family. Every row is a `SettingsRow` underneath:
//
//    leading slot (icon tile, avatar) · title + badge / description · trailing
//
//  - `SettingsRow`            generic title / description / trailing control
//  - `SettingsToggle`         switch (default) or checkbox
//  - `SettingsPickerRow`      segmented or menu picker
//  - `SettingsValueRow`       read-only label → value
//  - `SettingsLinkRow`        pointer to another page or the web
//  - `SettingsNavigationRow`  drill-in with icon tile and chevron
//
//  Flat inside a `SettingsGroup`; a self-contained card elsewhere.
//

import SwiftUI

// MARK: - Row

struct SettingsRow<Leading: View, Trailing: View, Description: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.baseAssignmentFamily) private var inheritedFamily
    private var family: Int { 14 }
    private var assignment: String { "component.library.\(family)." }

    let title: String
    /// Already-localized chip text beside the title ("Beta", "Default").
    var badge: String?
    /// Settings-search landing anchor for this row.
    var anchorId: String?
    /// Render `title` verbatim (user data such as an agent or model name).
    var verbatimTitle: Bool
    @ViewBuilder let leading: Leading
    @ViewBuilder let description: Description
    @ViewBuilder let trailing: Trailing

    init(
        title: String,
        badge: String? = nil,
        anchorId: String? = nil,
        verbatimTitle: Bool = false,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder description: () -> Description,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.badge = badge
        self.anchorId = anchorId
        self.verbatimTitle = verbatimTitle
        self.leading = leading()
        self.description = description()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: theme.catalogLayoutMetric("component.library.14.elements.layout.row.leadingGap", inheriting: theme.assignedMetric(assignment + "gap", fallback: theme.space.s12))) {
            leading
            SettingsRowText {
                HStack(spacing: theme.catalogLayoutMetric("component.library.14.elements.layout.row.titleBadgeGap", inheriting: theme.space.s6)) {
                    titleText
                    if let badge, !badge.isEmpty {
                        StatusChip(badge, tone: .accent, typographyKey: assignment + "caption")
                    }
                }
            } description: {
                description
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            // Controls keep their natural width; the text column wraps instead.
            trailing
                .settingsFieldAccessibility(verbatimTitle ? title : L(String.LocalizationValue(title)))
                .fixedSize(horizontal: true, vertical: false)
        }
        .catalogLayoutTarget("component.library.14.elements.layout.row.leadingGap")
        .catalogLayoutTarget("component.library.14.elements.layout.row.titleBadgeGap")
        .settingsRowChrome()
        .settingsLandingAnchor(anchorId)
    }

    @ViewBuilder
    private var titleText: some View {
        if verbatimTitle {
            Text(verbatim: title)
        } else {
            Text(LocalizedStringKey(title), bundle: .module)
        }
    }
}

extension SettingsRow where Leading == EmptyView {
    init(
        title: String,
        badge: String? = nil,
        anchorId: String? = nil,
        verbatimTitle: Bool = false,
        @ViewBuilder description: () -> Description,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            title: title,
            badge: badge,
            anchorId: anchorId,
            verbatimTitle: verbatimTitle,
            leading: { EmptyView() },
            description: description,
            trailing: trailing
        )
    }
}

extension SettingsRow where Description == SettingsRowDescription {
    /// Plain-string description. An empty description renders nothing.
    init(
        title: String,
        description: String,
        badge: String? = nil,
        anchorId: String? = nil,
        verbatimTitle: Bool = false,
        verbatimDescription: Bool = false,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            title: title,
            badge: badge,
            anchorId: anchorId,
            verbatimTitle: verbatimTitle,
            leading: leading,
            description: { SettingsRowDescription(text: description, verbatim: verbatimDescription) },
            trailing: trailing
        )
    }
}

extension SettingsRow where Leading == EmptyView, Description == SettingsRowDescription {
    init(
        title: String,
        description: String,
        badge: String? = nil,
        anchorId: String? = nil,
        verbatimTitle: Bool = false,
        verbatimDescription: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            title: title,
            description: description,
            badge: badge,
            anchorId: anchorId,
            verbatimTitle: verbatimTitle,
            verbatimDescription: verbatimDescription,
            leading: { EmptyView() },
            trailing: trailing
        )
    }
}

// MARK: - Row Text

/// The title-over-description column of every row. Rows that draw their own
/// chrome (list items, banners, selectable cards) use it directly, so they
/// keep the row's type roles, colors and gap. A `Text` inside either slot
/// may still set its own color or line limit.
struct SettingsRowText<Title: View, Description: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.baseDescriptionAssignment) private var descriptionAssignment
    private let assignment = "component.library.14."

    /// The denser title for rows inside cards and lists.
    var compact: Bool
    @ViewBuilder let title: Title
    @ViewBuilder let description: Description

    init(compact: Bool = false, @ViewBuilder title: () -> Title, @ViewBuilder description: () -> Description) {
        self.compact = compact
        self.title = title()
        self.description = description()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.14.elements.layout.row.titleDescriptionGap", inheriting: theme.settingsTitleToDescription)) {
            title
                .assignedTypography(assignment + "label", fallback: compact ? SettingsFont.compactLabel : SettingsFont.rowTitle)
                .foregroundStyle(theme.assignedColor(assignment + (isEnabled ? "foreground" : "disabledForeground"), fallback: theme.text.primary))
            description
                .assignedTypography(descriptionAssignment ?? assignment + "text", fallback: SettingsFont.rowDescription)
                .foregroundStyle(theme.assignedColor(assignment + (isEnabled ? "secondary" : "disabledForeground"), fallback: theme.text.tertiary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .catalogLayoutTarget("component.library.14.elements.layout.row.titleDescriptionGap")
    }
}

extension SettingsRowText where Title == Text, Description == SettingsRowDescription {
    /// Catalog-key strings; `verbatim` for user data such as a name.
    init(_ title: String, description: String, verbatim: Bool = false, compact: Bool = false) {
        self.init(compact: compact) {
            verbatim ? Text(verbatim: title) : Text(LocalizedStringKey(title), bundle: .module)
        } description: {
            SettingsRowDescription(text: description, verbatim: verbatim)
        }
    }
}

/// String description slot of `SettingsRow`; renders nothing when empty.
struct SettingsRowDescription: View {
    let text: String
    var verbatim: Bool = false

    var body: some View {
        if !text.isEmpty {
            if verbatim {
                Text(verbatim: text)
            } else {
                Text(LocalizedStringKey(text), bundle: .module)
            }
        }
    }
}

// MARK: - Row Chrome

extension View {
    /// The canonical row surface. Inside a `SettingsGroup` only a min-height
    /// (the group draws inset and dividers); on its own, a control card.
    /// Custom-layout rows apply it directly.
    func settingsRowChrome() -> some View {
        modifier(SettingsRowChrome())
    }
}

private struct SettingsRowChrome: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.settingsInGroup) private var inGroup
    @Environment(\.baseAssignmentFamily) private var inheritedFamily
    private var family: Int { 14 }
    @Environment(\.baseAssignmentSelected) private var selected
    private var assignment: String { "component.library.\(family).elements.row." }

    private func groupedMetric(_ property: String, fallback: CGFloat) -> CGFloat {
        theme.assignedMetric(assignment + property, fallback: fallback)
    }
    func body(content: Content) -> some View {
        if inGroup {
            content
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.14.elements.layout.row.groupedPaddingX", inheriting: groupedMetric("padding", fallback: 0))).padding(.vertical, theme.catalogLayoutMetric("component.library.14.elements.layout.row.groupedPaddingY", inheriting: groupedMetric("padding", fallback: 0))).catalogLayoutTarget("component.library.14.elements.layout.row.groupedPaddingX").catalogLayoutTarget("component.library.14.elements.layout.row.groupedPaddingY")
                .frame(maxWidth: .infinity, minHeight: groupedMetric("height", fallback: theme.settingsRowMinHeight), alignment: .leading)
                .assignedBaseChrome(family, fallback: nil, selected: selected, element: "row")
        } else {
            content
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.14.elements.layout.row.paddingX", inheriting: theme.assignedMetric(assignment + "padding", fallback: theme.space.s12))).padding(.vertical, theme.catalogLayoutMetric("component.library.14.elements.layout.row.paddingY", inheriting: theme.assignedMetric(assignment + "padding", fallback: theme.space.s12))).catalogLayoutTarget("component.library.14.elements.layout.row.paddingX").catalogLayoutTarget("component.library.14.elements.layout.row.paddingY")
                .frame(minHeight: theme.assignedMetric(assignment + "height", fallback: theme.settingsRowMinHeight))
                .assignedBaseChrome(family, selected: selected, element: "row")
        }
    }
}

// MARK: - Toggle

struct SettingsToggle: View {
    @Environment(\.theme) private var theme

    enum Style {
        /// Trailing switch: the default for every on/off setting.
        case `switch`
        /// Leading checkbox: multi-select lists and "Override" opt-ins.
        case checkbox
    }

    let title: String
    var description: String
    var badge: String?
    var anchorId: String?
    var icon: String?
    var style: Style
    var verbatim: Bool
    @Binding var isOn: Bool

    init(
        title: String,
        description: String = "",
        badge: String? = nil,
        anchorId: String? = nil,
        icon: String? = nil,
        style: Style = .switch,
        verbatim: Bool = false,
        isOn: Binding<Bool>
    ) {
        self.title = title
        self.description = description
        self.badge = badge
        self.anchorId = anchorId
        self.icon = icon
        self.style = style
        self.verbatim = verbatim
        self._isOn = isOn
    }

    var body: some View {
        Group {
        switch style {
        case .switch:
            SettingsRow(
                title: title,
                description: description,
                badge: badge,
                anchorId: anchorId,
                verbatimTitle: verbatim,
                verbatimDescription: verbatim,
                leading: { leadingIcon }
            ) {
                Toggle("", isOn: $isOn)
                    .settingsSwitch()
                    .accessibilityLabel(titleText)
            }
        case .checkbox:
            SettingsRow(
                title: title,
                description: description,
                badge: badge,
                anchorId: anchorId,
                verbatimTitle: verbatim,
                verbatimDescription: verbatim,
                leading: {
                    Toggle("", isOn: $isOn)
                        .settingsCheckbox(showsLabel: false)
                        .labelsHidden()
                        .accessibilityLabel(titleText)
                    leadingIcon
                }
            ) {
                EmptyView()
            }
            .contentShape(Rectangle())
            .onTapGesture { isOn.toggle() }
        }
        }.environment(\.baseAssignmentFamily, theme.inspectionProductFamily(for: "switchWidth", fallback: 4))
            .environment(\.baseAssignmentSelected, isOn)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if let icon {
            SettingsIconTile(icon: icon)
        }
    }

    private var titleText: Text {
        verbatim ? Text(verbatim: title) : Text(LocalizedStringKey(title), bundle: .module)
    }
}

extension View {
    /// The one switch style: small, accent-tinted. The label is hidden
    /// unless the toggle carries its own inline label (`showsLabel`).
    func settingsSwitch(showsLabel: Bool = false) -> some View {
        modifier(SettingsSwitchModifier(style: .switch, showsLabel: showsLabel))
    }

    /// A smaller switch for headers set in caption type (the sidebar's
    /// Developer Tools group).
    func settingsMiniSwitch() -> some View {
        modifier(SettingsSwitchModifier(style: .switch, showsLabel: false, mini: true))
    }

    /// The one checkbox style, for multi-select lists and inline opt-ins.
    func settingsCheckbox(showsLabel: Bool = true) -> some View {
        modifier(SettingsSwitchModifier(style: .checkbox, showsLabel: showsLabel))
    }
}

private struct SettingsSwitchModifier: ViewModifier {
    @Environment(\.theme) private var theme

    let style: SettingsToggle.Style
    let showsLabel: Bool
    var mini = false

    @ViewBuilder
    func body(content: Content) -> some View {
        content.toggleStyle(AssignedBaseToggleStyle(checkbox: style == .checkbox, showsLabel: showsLabel, mini: mini))
    }
}

// MARK: - Picker Row

/// A `SettingsRow` whose trailing control is a picker. Segmented for a few
/// short options, menu for longer lists.
struct SettingsPickerRow<Value: Hashable>: View {
    enum Style {
        case segmented
        case menu
    }

    struct Option: Identifiable {
        let value: Value
        let label: String
        var verbatim: Bool = false
        var id: Value { value }

        init(_ value: Value, _ label: String, verbatim: Bool = false) {
            self.value = value
            self.label = label
            self.verbatim = verbatim
        }
    }

    let title: String
    var description: String
    var anchorId: String?
    var style: Style
    let options: [Option]
    @Binding var selection: Value

    init(
        title: String,
        description: String = "",
        anchorId: String? = nil,
        style: Style = .segmented,
        selection: Binding<Value>,
        options: [Option]
    ) {
        self.title = title
        self.description = description
        self.anchorId = anchorId
        self.style = style
        self.options = options
        self._selection = selection
    }

    var body: some View {
        SettingsRow(title: title, description: description, anchorId: anchorId) {
            switch style {
            case .segmented:
                AssignedBaseSegmentedPicker(selection: $selection, options: options)
                    .accessibilityLabel(Text(LocalizedStringKey(title), bundle: .module))
            case .menu:
                SettingsMenuPicker(selection: $selection, options: options)
                    .accessibilityLabel(Text(LocalizedStringKey(title), bundle: .module))
            }
        }
    }
}

extension View {
    /// A `SettingsMenuPicker` at its value's width, or at the width it is
    /// offered when its longest value would not fit there. Stretched any
    /// wider, the value floats in the middle of an empty box.
    func settingsPickerHugging() -> some View {
        SettingsHuggingLayout { self }
    }
}

/// Offers its one subview the subview's ideal width, capped at the width on
/// offer. A `Layout` rather than `ViewThatFits`, which builds every candidate
/// and re-sizes them in a re-entrant pass that crashed on macOS 15 (see
/// `SettingsTabsRow`).
struct SettingsHuggingLayout: Layout {
    var maximumWidth: CGFloat? = nil

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        return subview.sizeThatFits(childProposal(proposal, subview))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        subview.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }

    private func childProposal(_ proposal: ProposedViewSize, _ subview: LayoutSubview) -> ProposedViewSize {
        let measured = subview.sizeThatFits(.unspecified).width
        let ideal = maximumWidth.map { min($0, measured) } ?? measured
        return ProposedViewSize(width: proposal.width.map { min($0, ideal) } ?? ideal, height: nil)
    }
}

/// The pop-up menu control: the native menu `Picker`, label hidden, hugging
/// its value (a width frame may still compress it). Every "pick one value"
/// dropdown in settings uses this look. A `Menu` with a custom label is not a
/// substitute: macOS flattens the label to text + image and drops any chrome.
struct SettingsMenuPicker<Value: Hashable, Content: View>: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(5, enabled: baseComponentEnabled) }
    @State private var assignedFocus = false
    @Binding var selection: Value
    private let content: Content
    private let disabledValues: Set<Value>

    init(selection: Binding<Value>, disabledValues: Set<Value> = [], @ViewBuilder content: () -> Content) {
        self._selection = selection
        self.disabledValues = disabledValues
        self.content = content()
    }

    private var picker: some View {
        Picker(selection: $selection) {
            content
        } label: {
            EmptyView()
        }
        .labelsHidden()
    }

    private var nativePicker: some View { picker.pickerStyle(.menu) }

    var body: some View {
        Group {
            Group(subviews: content) { subviews in
                let indices = Set(subviews.enumerated().compactMap { index, subview in
                    disabledValues.contains(where: { subview.containerValues.hasTag($0) }) ? index : nil
                })
                AssignedNativePicker(content: nativePicker, theme: theme, enabled: baseComponentEnabled,
                    disabledMenuIndices: indices, onFocusChange: { assignedFocus = $0 },
                    inlineMenu: AnyView(picker.pickerStyle(.inline)))
            }
        }
        .assignedTypography("component.library.5.text", fallback: SettingsFont.compactLabel)
        .foregroundStyle(theme.text.primary)
        .tint(theme.border.focus)
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.5.elements.layout.settingsMenuPicker.body.paddingX", inheriting: theme.catalogMetric("padding", fallback: theme.space.s0))).catalogLayoutTarget("component.library.5.elements.layout.settingsMenuPicker.body.paddingX")
        .padding(.vertical, theme.catalogMetric("paddingY", fallback: theme.space.s0))
        .nativeCatalogTarget(["padding", "paddingY", "height", "gap"].map { "component.library.5.elements.container." + $0 }, "Select / picker")
        .frame(minHeight: theme.catalogMetric("height", fallback: 0))
        .assignedBaseChrome(5)
        .assignedBaseFocusRing(5, visible: assignedFocus && baseComponentEnabled, radius: theme.radius.medium)
        .settingsPickerHugging()
    }
}

extension SettingsMenuPicker where Content == SettingsPickerOptions<Value> {
    init(selection: Binding<Value>, options: [SettingsPickerRow<Value>.Option], disabledValues: Set<Value> = []) {
        self.init(selection: selection, disabledValues: disabledValues) { SettingsPickerOptions(options: options) }
    }
}

struct SettingsPickerOptions<Value: Hashable>: View {
    let options: [SettingsPickerRow<Value>.Option]

    var body: some View {
        ForEach(options) { option in
            SettingsOptionLabel(option.label, verbatim: option.verbatim).tag(option.value)
        }
    }
}

/// Trigger for a picker that opens a popover (searchable model/agent lists,
/// date pickers) — anything a `SettingsMenuPicker` can't hold. `.compact`
/// sits trailing in a row and wears the native pop-up bezel so it matches
/// `SettingsMenuPicker`; `.field` fills a form column like a text field.
struct SettingsPopUpButton<Label: View>: View {
    enum Style {
        case compact
        case field
    }

    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(5, enabled: baseComponentEnabled) }

    private let style: Style
    private let isActive: Bool
    /// `.field` only: span the column (default) or hug the value.
    private let fillsWidth: Bool
    private let action: () -> Void
    private let label: Label

    @State private var isHovering = false

    init(
        style: Style = .compact,
        isActive: Bool = false,
        fillsWidth: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.style = style
        self.isActive = isActive
        self.fillsWidth = fillsWidth
        self.action = action
        self.label = label()
    }

    var body: some View {
        switch style {
        case .compact:
            Button(action: action) {
                HStack(spacing: theme.catalogLayoutMetric("component.library.5.elements.layout.settingsPopUpButton.body.horizontalGap", inheriting: theme.catalogMetric("gap", fallback: theme.space.s6))) {
                    label.assignedTypography("component.library.5.label", fallback: SettingsFont.rowTitle)
                        .foregroundColor(theme.text.primary).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .glyphSize(.tiny, weight: .semibold)
                        .foregroundColor(theme.text.secondary)
                }.catalogLayoutTarget("component.library.5.elements.layout.settingsPopUpButton.body.horizontalGap")
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.5.elements.layout.settingsPopUpButton.body.padding.horizontal", inheriting: theme.catalogMetric("padding", fallback: theme.space.s6))).padding(.vertical, theme.catalogLayoutMetric("component.library.5.elements.layout.settingsPopUpButton.body.padding.vertical", inheriting: theme.catalogMetric("padding", fallback: theme.space.s6))).catalogLayoutTarget("component.library.5.elements.layout.settingsPopUpButton.body.padding.horizontal").catalogLayoutTarget("component.library.5.elements.layout.settingsPopUpButton.body.padding.vertical")
                .frame(minHeight: theme.catalogMetric("height", fallback: 0))
                .assignedBaseChrome(5, selected: isActive)
                .contentShape(Rectangle())
            }
            .assignedBasePlainButtonStyle()
            .assignedBaseKeyboardButton(5, action: action)
            .fixedSize()
        case .field:
            Button(action: action) {
                HStack(spacing: theme.space.s6) {
                    label
                        .assignedTypography("component.library.5.label", fallback: SettingsFont.rowTitle)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                    if fillsWidth { Spacer(minLength: theme.space.s6) }
                    Image(systemName: "chevron.up.chevron.down")
                        .glyphSize(.tiny, weight: .semibold)
                        .foregroundColor(theme.text.tertiary)
                }
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.5.elements.layout.settingsPopUpButton.body.paddingX", inheriting: theme.catalogMetric("padding", fallback: theme.space.s12))).catalogLayoutTarget("component.library.5.elements.layout.settingsPopUpButton.body.paddingX")
                .padding(.vertical, theme.catalogLayoutMetric("component.library.5.elements.layout.settingsPopUpButton.body.paddingY", inheriting: theme.catalogMetric("gap", fallback: theme.space.s6))).catalogLayoutTarget("component.library.5.elements.layout.settingsPopUpButton.body.paddingY")
                .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: theme.catalogMetric("height", fallback: 36), alignment: .leading)
                .assignedBaseChrome(5, selected: isActive)
                .contentShape(Rectangle())
            }
            .assignedBasePlainButtonStyle()
            .assignedBaseKeyboardButton(5, action: action)
            .onHover { isHovering = $0 }
        }
    }
}

private struct SettingsOptionLabel: View {
    let text: String
    let verbatim: Bool

    init(_ text: String, verbatim: Bool) {
        self.text = text
        self.verbatim = verbatim
    }

    var body: some View {
        if verbatim {
            Text(verbatim: text)
        } else {
            Text(LocalizedStringKey(text), bundle: .module)
        }
    }
}

// MARK: - Fact

/// Caption-over-value tile for detail grids. Both strings render verbatim;
/// `compact` sets the value in the compact label size.
struct SettingsFactText: View {
    @Environment(\.theme) private var theme

    let label: String
    let value: String
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s2) {
            Text(verbatim: label)
                .font(SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
                .lineLimit(1)
            Text(verbatim: value)
                .font(compact ? SettingsFont.compactLabel : SettingsFont.rowTitle)
                .foregroundColor(theme.text.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Value Row

/// Read-only label → value row (metadata, IDs, versions). The value renders
/// verbatim; `monospaced` for identifiers, `dot` for a status colour.
struct SettingsValueRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled

    let title: String
    let value: String
    var monospaced: Bool
    var dot: Color?
    var copyable: Bool
    var anchorId: String?
    var verbatimTitle: Bool

    @State private var copied = false

    init(
        title: String,
        value: String,
        monospaced: Bool = false,
        dot: Color? = nil,
        copyable: Bool = false,
        anchorId: String? = nil,
        verbatimTitle: Bool = false
    ) {
        self.verbatimTitle = verbatimTitle
        self.title = title
        self.value = value
        self.monospaced = monospaced
        self.dot = dot
        self.copyable = copyable
        self.anchorId = anchorId
    }

    var body: some View {
        SettingsRow(title: title, description: "", anchorId: anchorId, verbatimTitle: verbatimTitle) {
            HStack(spacing: theme.space.s6) {
                if let dot {
                    Circle()
                        .fill(theme.assignedColor("component.library.14." + (enabled ? "accent" : "disabledForeground"), fallback: dot))
                        .frame(width: 6, height: 6)
                }
                Text(verbatim: value)
                    .assignedTypography("component.library.14.text", fallback: monospaced ? SettingsFont.monoSmall : SettingsFont.body)
                    .foregroundColor(theme.assignedColor("component.library.14." + (enabled ? "secondary" : "disabledForeground"), fallback: theme.text.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if copyable {
                    Button(action: copyValue) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(SettingsFont.glyphSmall)
                            .foregroundColor(theme.assignedColor("component.library.14." + (!enabled ? "disabledForeground" : copied ? "accent" : "secondary"), fallback: copied ? theme.status.success.foreground : theme.text.tertiary))
                    }
                    .assignedBasePlainButtonStyle()
                    .assignedBaseKeyboardButton(14, action: copyValue)
                    .help(Text("Copy", bundle: .module))
                }
            }
        }
    }

    private func copyValue() {
        guard enabled else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

// MARK: - Link Row

/// A row that takes the user somewhere else: another settings page that owns
/// the control, or a web page.
struct SettingsLinkRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled

    let title: String
    var description: String
    var icon: String
    var actionTitle: String
    var anchorId: String?
    let action: () -> Void

    @State private var isHovering = false

    init(
        title: String,
        description: String = "",
        icon: String = "arrow.up.right.square",
        actionTitle: String = "Open",
        anchorId: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.description = description
        self.icon = icon
        self.actionTitle = actionTitle
        self.anchorId = anchorId
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            SettingsRow(title: title, description: description, anchorId: anchorId) {
                HStack(spacing: theme.space.s6) {
                    Text(LocalizedStringKey(actionTitle), bundle: .module)
                        .assignedTypography("component.library.14.caption", fallback: SettingsFont.smallLabel)
                    Image(systemName: icon)
                        .font(SettingsFont.glyphSmall)
                }
                .foregroundColor(theme.assignedColor("component.library.14." + (enabled ? "secondary" : "disabledForeground"), fallback: isHovering ? theme.text.linkHover : theme.text.link))
            }
            .contentShape(Rectangle())
        }
        .assignedBasePlainButtonStyle()
        .assignedBaseKeyboardButton(14, action: action)
        .pointingHandCursor()
        .onHover { isHovering = $0 }
    }
}

// MARK: - Navigation Row

/// A row that drills into a deeper page: icon tile, title, one-line
/// subtitle, optional count, chevron.
struct SettingsNavigationRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.settingsInGroup) private var inGroup

    let icon: String
    let title: String
    var subtitle: String
    var badge: Int?
    var badgeHighlight: Bool
    var anchorId: String?
    let action: () -> Void

    @State private var isHovering = false

    init(
        icon: String,
        title: String,
        subtitle: String = "",
        badge: Int? = nil,
        badgeHighlight: Bool = false,
        anchorId: String? = nil,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.badgeHighlight = badgeHighlight
        self.anchorId = anchorId
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            SettingsRow(
                title: title,
                description: subtitle,
                leading: { SettingsIconTile(icon: icon) }
            ) {
                HStack(spacing: theme.space.s8) {
                    if let badge, badge > 0 {
                        CountBadge(badge, prominence: badgeHighlight ? .attention : .neutral)
                    }
                    SettingsChevron(color: theme.assignedColor("component.library.14." + (enabled ? "secondary" : "disabledForeground"), fallback: theme.text.tertiary))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(inGroup ? theme.space.s6 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsNavigationRowButtonStyle(isHovering: isHovering))
        .assignedBaseKeyboardButton(14, action: action)
        .pointingHandCursor()
        .onHover { isHovering = $0 }
        .settingsLandingAnchor(anchorId)
        .accessibilityAddTraits(.isButton)
    }
}

/// Draw both interaction states around the complete padded button label.
private struct SettingsNavigationRowButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color =
            configuration.isPressed ? theme.surface.pressed : (isHovering ? theme.surface.hover : .clear)
        configuration.label
            .background(fill, in: RoundedRectangle(cornerRadius: theme.radius.small, style: .continuous))
            .animation(theme.motion.quick, value: configuration.isPressed)
    }
}

/// The trailing disclosure chevron of navigation rows and library rows.
struct SettingsChevron: View {
    @Environment(\.theme) private var theme
    var color: Color? = nil

    var body: some View {
        Image(systemName: "chevron.right")
            .font(SettingsFont.glyphSmall)
            .foregroundColor(color ?? theme.text.tertiary)
    }
}

/// The rounded, accent-tinted square an SF Symbol sits in on navigation
/// rows, ability rows, and the pinned sidebar block.
struct SettingsIconTile: View {
    @Environment(\.theme) private var theme

    let icon: String
    var size: CGFloat = 26
    var tint: Color?
    /// Brand gradient (channels, providers); overrides `tint`.
    var gradient: [Color]?

    var body: some View {
        Image(systemName: icon)
            .glyphSize(points: size * 0.5, weight: .semibold)
            .foregroundColor(glyph)
            .frame(width: size, height: size)
            .background(fill)
    }

    /// Brand gradients are saturated, so white reads on them; the default
    /// primary fill is monochrome in Dark/Light and needs its pair. A caller
    /// tint can be light (a pale status shade, the primary fill itself), so
    /// the glyph takes whichever of white and black contrasts more with it.
    private var glyph: Color {
        if gradient != nil { return FixedPalette.onMedia }
        guard let tint else { return theme.action.primary.default.foreground }
        return FixedPalette.glyph(on: tint)
    }

    @ViewBuilder
    private var fill: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        if let gradient, !gradient.isEmpty {
            shape.fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
        } else {
            shape.fill((tint ?? theme.action.primary.default.background).gradient)
        }
    }
}
