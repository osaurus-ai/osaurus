//
//  PickerCardStyle.swift
//  Osaurus
//
//  Shared surface, typography and row chrome for the composer's anchored
//  cards (model picker, context budget, credits) so they read as one family.
//

import SwiftUI

enum PickerCardMetrics {
    static let padding: CGFloat = 16
    static let rowHeight: CGFloat = 36
    static let rowSpacing: CGFloat = 2
    /// Leading/trailing inset of row content, section titles and footnotes
    /// inside a column; headings sit flush with the column edge.
    static let rowInset: CGFloat = 12
    /// Vertical gap between sections in a column.
    static let sectionSpacing: CGFloat = 10
    /// Height of a section sub-heading, including its bottom gap.
    static let sectionTitleHeight: CGFloat = 22
    /// Read-only label/value rows (token counts, balances) sit tighter than
    /// selectable rows.
    static let valueRowHeight: CGFloat = 26
    /// Width of the single-column info cards (context budget, credits).
    static let infoCardWidth: CGFloat = 300
    /// Gap between sections on the info cards, which have no dividers.
    static let infoSectionSpacing: CGFloat = 14
}

extension View {
    /// The flat themed card surface: `surface.overlay`, `radius.xlarge`
    /// continuous corners and `border.default`. Cards in their own panel get the
    /// window server's shadow; `elevated` adds one for cards drawn inside
    /// the chat window (composer popups, voice input).
    func pickerCardSurface(elevated: Bool = false, assignmentFamily: Int = 16) -> some View {
        modifier(PickerCardSurfaceModifier(elevated: elevated, assignmentFamily: assignmentFamily))
    }

    /// Row chrome: inset content, minimum row height, and the rounded fill
    /// shown for a selected, hovered or focused row.
    func pickerCardRowChrome(highlighted: Bool, minHeight: CGFloat = PickerCardMetrics.rowHeight) -> some View {
        modifier(PickerCardRowChromeModifier(highlighted: highlighted, minHeight: minHeight))
    }
}

private struct PickerCardSurfaceModifier: ViewModifier {
    let elevated: Bool
    let assignmentFamily: Int
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.anchoredCardMetrics) private var cardMetrics
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(assignmentFamily, enabled: enabled) }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.xlarge, style: .continuous)
        content
            .frame(minHeight: min(theme.catalogMetric("height", fallback: 0), cardMetrics?.visibleSize.height ?? .greatestFiniteMagnitude))
            .background(theme.surface.overlay, in: shape)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(theme.border.default, lineWidth: theme.stroke.default)
            }
            .themeElevation(elevated ? theme.elevation.overlay : theme.elevation.none)
            .assignedTypography("component.library.\(assignmentFamily).text", fallback: SettingsFont.body)
            .foregroundStyle(theme.text.primary)
            .nativeCatalogTarget(["background", "border", "borderWidth", "radius", "height"].map { "component.library.\(assignmentFamily).elements.container." + $0 }, "Picker container")
            .environment(\.theme, theme)
    }
}

/// Keyboard hints in a list card's heading ("↑↓ navigate  ↵ select  esc dismiss").
struct PickerCardKeyHints: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var enabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(9, enabled: enabled) }

    var body: some View {
        Text("↑↓ navigate  ↵ select  esc dismiss", bundle: .module)
            .assignedTypography("component.library.9.text", fallback: SettingsFont.rowDescription)
            .foregroundStyle(theme.text.tertiary)
            .lineLimit(1)
    }
}

private struct PickerCardRowChromeModifier: ViewModifier {
    let highlighted: Bool
    let minHeight: CGFloat
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, theme.assignedMetric("component.library.16.padding", fallback: PickerCardMetrics.rowInset))
            .frame(minHeight: minHeight)
            .contentShape(Rectangle())
            .background(
                highlighted ? theme.surface.hover : .clear,
                in: RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
            )
    }
}

/// Column heading ("Provider", "Model", "Context").
struct PickerCardHeading<Accessory: View>: View {
    let title: String
    var assignmentFamily = 16
    @ViewBuilder var accessory: () -> Accessory
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.assignedMetric("component.library.\(assignmentFamily).gap", fallback: theme.space.s8)) {
            Text(title)
                .assignedTypography("component.library.\(assignmentFamily)." + (assignmentFamily == 25 ? "label" : "heading"), fallback: SettingsFont.body)
                .foregroundStyle(theme.assignedColor("component.library.\(assignmentFamily)." + (enabled ? "foreground" : "disabledForeground"), fallback: theme.text.secondary))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            accessory()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        
        
        .padding(.bottom, assignmentFamily == 26 ? 0 : theme.assignedMetric("component.library.\(assignmentFamily).gap", fallback: theme.space.s4))
    }
}

extension PickerCardHeading where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title: title, accessory: { EmptyView() })
    }
}

/// Quiet sub-heading above a group of rows ("Thinking", "Sources").
struct PickerCardSectionTitle<Accessory: View>: View {
    let title: String
    var assignmentFamily = 16
    @ViewBuilder var accessory: () -> Accessory
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: theme.assignedMetric("component.library.\(assignmentFamily).gap", fallback: theme.space.s6)) {
            Text(title)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            accessory()
        }
        .assignedTypography("component.library.\(assignmentFamily).label", fallback: SettingsFont.rowTitle)
        .foregroundStyle(theme.assignedColor("component.library.\(assignmentFamily)." + (enabled ? "foreground" : "disabledForeground"), fallback: theme.text.tertiary))
        .padding(.horizontal, theme.assignedMetric("component.library.\(assignmentFamily).padding", fallback: PickerCardMetrics.rowInset))
        .frame(minHeight: PickerCardMetrics.sectionTitleHeight, alignment: .bottomLeading)
        .padding(.bottom, theme.assignedMetric("component.library.\(assignmentFamily).gap", fallback: theme.space.s2))
        
        
        
    }
}

extension PickerCardSectionTitle where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title: title, accessory: { EmptyView() })
    }
}

/// Small explanatory text under a section, aligned with row content.
struct PickerCardFootnote: View {
    let text: String
    var color: Color? = nil
    var assignmentFamily = 16
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Text(verbatim: text)
            .assignedTypography("component.library.\(assignmentFamily).caption", fallback: SettingsFont.caption)
            .foregroundStyle(enabled ? (color ?? theme.text.secondary) : theme.assignedColor("component.library.\(assignmentFamily).disabledForeground", fallback: color ?? theme.text.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, theme.assignedMetric("component.library.\(assignmentFamily).padding", fallback: PickerCardMetrics.rowInset))
        
    }
}

/// Quiet inline link with its icon beside the text ("More models →").
struct PickerCardTextLink: View {
    let title: String
    let icon: String
    var focused = false
    /// Accent for a primary action; nil keeps the quiet subdued link.
    var tint: Color? = nil
    /// False lets two links share a row instead of each claiming the width.
    var fillsWidth = true
    var assignmentFamily: Int? = nil
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    private var subduedTextColor: Color { theme.isDark ? theme.text.tertiary : theme.text.secondary }
    private var linkInk: Color {
        if let assignmentFamily {
            return theme.assignedColor("component.library.\(assignmentFamily)." + (enabled ? "accent" : "disabledForeground"), fallback: theme.text.link)
        }
        return tint ?? (hovered ? theme.text.primary : subduedTextColor)
    }
    private var glyphInk: Color {
        if assignmentFamily != nil { return linkInk }
        return tint ?? (hovered ? theme.text.primary : theme.text.tertiary)
    }
    private func metric(_ property: String, _ fallback: CGFloat) -> CGFloat {
        guard let assignmentFamily else { return fallback }
        return theme.assignedMetric("component.library.\(assignmentFamily)." + property, fallback: fallback)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: metric("gap", theme.space.s4)) {
                Text(title).underline(hovered)
                    .foregroundStyle(linkInk)
                Image(systemName: icon).glyphSize(.footnote).accessibilityHidden(true)
            }
            .modifier(PickerCardLinkTypography(family: assignmentFamily, tinted: tint != nil))
            .foregroundStyle(glyphInk)
            .padding(.horizontal, metric("padding", PickerCardMetrics.rowInset))
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: metric("height", 32), alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if focused { Rectangle().fill(theme.text.secondary).frame(height: 1) }
            }
        }
        .modifier(PickerCardLinkButtonStyle(family: assignmentFamily))
        .focusable()
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .onKeyPress(.return) {
            if assignmentFamily != nil && !enabled { return .ignored }
            action(); return .handled
        }
    }
}

private struct PickerCardLinkTypography: ViewModifier {
    let family: Int?
    let tinted: Bool
    @Environment(\.theme) private var theme
    @ViewBuilder func body(content: Content) -> some View {
        if let family {
            content.assignedTypography("component.library.\(family).caption", fallback: SettingsFont.body)
        } else { content.font(theme.font(size: theme.pointSize(.bodySmall), weight: tinted ? .medium : .regular)) }
    }
}

private struct PickerCardLinkButtonStyle: ViewModifier {
    let family: Int?
    @ViewBuilder func body(content: Content) -> some View {
        if family != nil { content.assignedBasePlainButtonStyle() }
        else { content.buttonStyle(.plain) }
    }
}

/// One shared assignment contract, independent of the component opening a menu.
enum ChatContextMenuAssignments {
    static let prefix = "component.contextMenu."
    static let defaults: [String: String] = [
        "container.background":"color.surface.raised", "container.border":"color.border.subtle",
        "container.borderWidth":"stroke.default", "container.radius":"radius.medium",
        "container.padding":"space.4", "container.gap":"space.4",
        "row.foreground":"color.text.primary", "row.disabledForeground":"color.text.disabled",
        "row.hover":"color.surface.hover", "row.radius":"radius.small", "row.label":"type.label",
        "row.paddingX":"space.4", "row.paddingTrailing":"space.8", "row.paddingY":"space.2",
        "row.height":"space.24", "row.gap":"space.8",
        "divider.border":"color.border.subtle", "divider.borderWidth":"stroke.default"
    ].reduce(into: [:]) { $0[prefix + $1.key] = $1.value }
    static func keys(_ element: String, _ properties: [String]) -> [String] {
        properties.map { prefix + element + "." + $0 }
    }
}

/// One opaque action-menu component for Chat, Settings, Workflows and agents.
/// Action owners supply rows; this owns the surface and layout recipe.
struct ChatContextMenu<Content: View>: View {
    @Environment(\.theme) private var inheritedTheme
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    private var theme: any ThemeProtocol {
        var base = inheritedTheme
        while let scoped = base as? CatalogResolvedTheme { base = scoped.base }
        return base
    }
    var body: some View {
        VStack(alignment: .leading, spacing: theme.inspectionNumber("component.contextMenu.container.gap", fallback: theme.space.s4)) { content }
            .padding(theme.inspectionNumber("component.contextMenu.container.padding", fallback: theme.space.s4)
                + theme.inspectionNumber("component.contextMenu.container.borderWidth", fallback: theme.stroke.default))
            .fixedSize(horizontal: true, vertical: true)
            .chatContextMenuSurface(usesAssignments: true)
            .nativeCatalogTarget(ChatContextMenuAssignments.keys("container", ["padding", "gap"]), "Menu layout")
            .environment(\.theme, theme)
    }
}

/// The same icon gutter and text layout for every action row.
struct ChatContextMenuLabel<Title: View, Icon: View>: View {
    @Environment(\.theme) private var theme
    let title: Title
    let icon: Icon
    var body: some View {
        HStack(spacing: theme.inspectionNumber("component.contextMenu.row.gap", fallback: theme.space.s8)) {
            icon.frame(width: 20, height: 20)
            title.lineLimit(1).fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }.nativeCatalogTarget(ChatContextMenuAssignments.keys("row", ["gap"]), "Menu icon-to-label gap")
    }
}

struct ChatContextMenuDivider: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Rectangle().fill(theme.inspectionColor("component.contextMenu.divider.border", fallback: theme.border.subtle))
            .frame(height: theme.inspectionNumber("component.contextMenu.divider.borderWidth", fallback: theme.stroke.default))
            .nativeCatalogTarget(ChatContextMenuAssignments.keys("divider", ["border", "borderWidth"]), "Menu divider")
    }
}

extension View {
    func chatContextMenuSurface(usesAssignments: Bool = false) -> some View { modifier(ChatContextMenuSurface(usesAssignments: usesAssignments)) }
}

private struct ChatContextMenuSurface: ViewModifier {
    var usesAssignments = false
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.inspectionNumber(usesAssignments ? "component.contextMenu.container.radius" : "radius.medium", fallback: theme.radius.medium), style: .continuous)
        content
            .background(theme.inspectionColor(usesAssignments ? "component.contextMenu.container.background" : "color.surface.raised", fallback: theme.surface.raised), in: shape)
            .clipShape(shape)
            .overlay { shape.strokeBorder(theme.inspectionColor(usesAssignments ? "component.contextMenu.container.border" : "color.border.subtle", fallback: theme.border.subtle),
                lineWidth: theme.inspectionNumber(usesAssignments ? "component.contextMenu.container.borderWidth" : "stroke.default", fallback: theme.stroke.default)) }
            .nativeCatalogTarget(usesAssignments ? ChatContextMenuAssignments.keys("container", ["background", "border", "borderWidth", "radius"]) : [], "Menu container")
    }
}

struct ChatContextMenuRowStyle: ButtonStyle {
    // nil uses a regular button's focus; menu renderers supply explicit
    // keyboard navigation so automatic initial focus is not a selection.
    var selected: Bool? = nil
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, selected: selected)
    }
    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool?
        @Environment(\.assignedMenuButtonInteraction) private var nativeInteraction
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @State private var hovered = false
        var body: some View {
            configuration.label
                .assignedTypography("component.contextMenu.row.label", fallback: SettingsFont.rowTitle)
                .foregroundStyle(theme.inspectionColor(enabled ? "component.contextMenu.row.foreground" : "component.contextMenu.row.disabledForeground",
                    fallback: enabled ? theme.text.primary : theme.text.disabled))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, theme.inspectionNumber("component.contextMenu.row.paddingX", fallback: theme.space.s4))
                .padding(.trailing, theme.inspectionNumber("component.contextMenu.row.paddingTrailing", fallback: theme.space.s8))
                .padding(.vertical, theme.inspectionNumber("component.contextMenu.row.paddingY", fallback: theme.space.s2))
                .frame(minHeight: theme.inspectionNumber("component.contextMenu.row.height", fallback: theme.space.s24))
                .background(RoundedRectangle(cornerRadius: theme.inspectionNumber("component.contextMenu.row.radius", fallback: theme.radius.small)).fill(
                    enabled && ((selected ?? (nativeInteraction?.focused ?? focused)) || (nativeInteraction?.hovered ?? hovered)
                        || (nativeInteraction?.pressed ?? configuration.isPressed))
                        ? theme.inspectionColor("component.contextMenu.row.hover", fallback: theme.surface.hover) : .clear))
                .contentShape(Rectangle())
                .focusEffectDisabled()
                .onHover { hovered = $0 }
                .nativeCatalogTarget(ChatContextMenuAssignments.keys("row", ["label", "foreground", "disabledForeground", "hover", "radius", "paddingX", "paddingTrailing", "paddingY", "height"]), "Menu action row")
        }
    }
}
