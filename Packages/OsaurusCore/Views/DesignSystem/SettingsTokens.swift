//
//  SettingsTokens.swift
//  osaurus
//
//  The design tokens every surface inside the Management window is built
//  from. Everything in `Views/DesignSystem` reads these; nothing outside it
//  should spell out a font size, corner radius, or fill + stroke pair by
//  hand. `SettingsKitLintTests` enforces that.
//
//  Kit rules (short form; the long form is `.cursor/rules/settings-kit.mdc`):
//  - A page is `SettingsPage { SettingsPageHeader … } content: { … }`.
//  - Content is a column of `SettingsSection`s. A section is a Title Case
//    title above one flat `SettingsGroup`; rows inside are `SettingsRow`
//    variants (toggle, picker, field, value, link, navigation, destructive,
//    ability) or `LibraryRow`s. Grids use `LibraryCard`.
//  - Labels: `StatusChip` / `CountBadge`. Buttons: `.assignedSettingsButtonStyle(…)`
//    or `SettingsButton`. Filters: `FilterChipRow`, `SearchField`.
//  - Inputs: `SettingsFieldRow` + `SettingsTextField` / `SettingsTextEditor`.
//    Toggles carry `.settingsSwitch()` or `.settingsCheckbox()`; one-of-few
//    choices are a segmented `Picker` or `SettingsPickerRow`.
//  - Metrics: `SettingsStatStrip`, `SettingsStatusHero`. Explainers:
//    `SettingsFeatureCards`. Check results: `SettingsFindingRow`.
//  - Empty: `SettingsEmptyState`. Pushed pages: `SettingsPageHeader` with a
//    back line from `.settingsBackDestination`. Snippets: `SettingsCodeBlock`. Loading: `SettingsSkeletonBar` +
//    `.settingsShimmer()`; progress: `SettingsProgressBar`.
//  - Chrome comes from `.settingsChrome(_:)`; type from `SettingsFont`
//    (aliases onto the theme's text roles); metrics from `theme.space` /
//    `theme.radius` / `theme.controlSize`.
//  - Motion reads `accessibilityReduceMotion` and stays still when it is on.
//  - Need a new variant? Extend the kit component and add it to
//    `SettingsKitGallery`; do not fork a local copy. The lint allowlist is
//    for surfaces that are not settings rows and only shrinks.
//

import SwiftUI

// MARK: - Type scale

/// Management's names for the theme's shared text styles. Each name is an
/// alias onto one of the eight `type.*` roles; size, weight, line height
/// and tracking all come from the active theme and the user's font zoom.
/// Apply with `.font(SettingsFont.x)`, which resolves through `textStyle(_:)`.
struct SettingsFont: Equatable, Sendable {
    let role: ThemeTextStyleRole
    /// Numeric design weight replacing the role's own.
    var weightOverride: Int?
    /// Sets the role in the other shared family (code-set identifiers).
    var familyOverride: ThemeFontFamilyRole?
    var isItalic = false
    var usesMonospacedDigits = false

    /// `type.title`. The one title at the top of a page.
    static let pageTitle = SettingsFont(role: .title)
    /// `type.bodySmall`, secondary colour. The line under a page title.
    static let pageSubtitle = SettingsFont(role: .bodySmall)
    /// `type.heading`. The name on a pushed detail page or wizard.
    static let detailTitle = SettingsFont(role: .heading)
    /// `type.label`, semibold, primary colour. Title Case section titles.
    static let sectionTitle = SettingsFont(role: .label, weightOverride: 600)
    /// `type.body`, semibold. The title on a library card.
    static let cardTitle = SettingsFont(role: .body, weightOverride: 600)
    /// `type.label`. Row titles, button labels, list row titles.
    static let rowTitle = SettingsFont(role: .label)
    /// `type.bodySmall`. Body copy inside a row.
    static let body = SettingsFont(role: .bodySmall)
    /// `type.footnote`, tertiary colour. Row descriptions, captions, footers.
    static let rowDescription = SettingsFont(role: .footnote)
    /// `type.footnote`, medium. Small action labels ("Open ↗", "Configure ›").
    static let smallLabel = SettingsFont(role: .footnote, weightOverride: 500)
    /// `type.caption`, medium. Compact button labels and menu-picker values.
    static let compactLabel = SettingsFont(role: .caption, weightOverride: 500)
    /// `type.caption`. Secondary copy on cards and list rows.
    static let caption = SettingsFont(role: .caption)
    /// `type.micro`, semibold. Chips.
    static let chip = SettingsFont(role: .micro, weightOverride: 600)
    /// `type.micro`. Fine print: timestamps, metadata under a meta line.
    static let footnote = SettingsFont(role: .micro)
    /// `type.footnote`, semibold. Count badges.
    static let count = SettingsFont(role: .footnote, weightOverride: 600)
    /// `type.code`. Values, URLs, identifiers in fields.
    static let mono = SettingsFont(role: .code)
    /// `type.footnote` set in the code family. Small identifiers, JSON, logs.
    static let monoSmall = SettingsFont(role: .footnote, familyOverride: .code)
    /// `type.caption`, semibold. Chevrons and glyphs sitting next to label text.
    static let glyph = SettingsFont(role: .caption, weightOverride: 600)
    /// `type.footnote`, semibold. Smaller glyphs (chevron.right on rows).
    static let glyphSmall = SettingsFont(role: .footnote, weightOverride: 600)

    /// The same style set in italics (quoted or placeholder copy).
    func italic() -> SettingsFont {
        var copy = self
        copy.isItalic = true
        return copy
    }

    /// The same style with tabular digits, for live counters.
    func monospacedDigit() -> SettingsFont {
        var copy = self
        copy.usesMonospacedDigits = true
        return copy
    }

    /// The same style at another weight.
    func weight(_ weight: Font.Weight) -> SettingsFont {
        var copy = self
        copy.weightOverride = Self.designWeight(weight)
        return copy
    }

    static func designWeight(_ weight: Font.Weight) -> Int {
        switch weight {
        case .ultraLight: return 100
        case .thin: return 200
        case .light: return 300
        case .medium: return 500
        case .semibold: return 600
        case .bold: return 700
        case .heavy: return 800
        case .black: return 900
        default: return 400
        }
    }
}

extension View {
    /// Applies a Management text style: the full theme recipe for its role.
    func font(_ style: SettingsFont) -> some View {
        textStyle(
            style.role, italic: style.isItalic, monospacedDigit: style.usesMonospacedDigits,
            weight: style.weightOverride, family: style.familyOverride)
    }
}

extension Text {
    /// Applies a Management text style.
    func font(_ style: SettingsFont) -> some View {
        textStyle(
            style.role, italic: style.isItalic, monospacedDigit: style.usesMonospacedDigits,
            weight: style.weightOverride, family: style.familyOverride)
    }
}

// MARK: - Geometry

// Spacing, radii, strokes and control sizes are read live from the theme:
// `theme.space.s*`, `theme.radius.*`, `theme.stroke.*`, `theme.controlSize.*`.
// The named roles below are the only spacing a Management page uses; any
// other gap is a step of `theme.space`. Metrics that sit between two steps
// of the scale are built from it, so a theme that rescales its spacing
// moves them too.

extension ThemeProtocol {
    /// 24pt. Leading and trailing inset of every page header and page body.
    var settingsPageInset: CGFloat { space.s24 }
    /// 8pt. Between the page header and the first section.
    var settingsPageTop: CGFloat { space.s8 }
    /// 32pt. Below the last section of a page.
    var settingsPageBottom: CGFloat { space.s32 }
    /// 28pt. Between sections on a page or in a sheet body.
    var settingsSectionGap: CGFloat { space.s24 + space.s4 }
    /// 8pt. Between a section title block and its group.
    var settingsSectionHeaderGap: CGFloat { space.s8 }
    /// 16pt x 12pt. Inset of a row inside a group.
    var settingsRowInsetX: CGFloat { space.s16 }
    var settingsRowInsetY: CGFloat { space.s12 }
    /// 12pt. Between a row's text and its trailing control, and between
    /// inline items of one line.
    var settingsInlineGap: CGFloat { space.s12 }
    /// 8pt. Between sibling controls (buttons in a row, header actions).
    var settingsControlGap: CGFloat { space.s8 }
    /// 6pt. Between an icon and its label.
    var settingsIconLabelGap: CGFloat { space.s6 }
    /// 16pt. Inside a card or well that is not a row.
    var settingsCardPadding: CGFloat { space.s16 }
    /// Between library cards, across and down alike.
    var libraryGridGap: CGFloat { space.s16 }
    /// 20pt. Horizontal inset of sheet headers, bodies and footers, and the
    /// body's vertical inset.
    var settingsSheetInset: CGFloat { space.s16 + space.s4 }
    /// 3pt. Between a row title and its description.
    var settingsTitleToDescription: CGFloat { (space.s2 + space.s4) / 2 }
    /// 20pt. Row minimum height inside a group, so description-less rows
    /// keep a hit target without padding out to the chat row height.
    var settingsRowMinHeight: CGFloat { space.s16 + space.s4 }
    /// 14pt / 10pt. Horizontal label inset of regular and compact buttons.
    var settingsButtonInsetRegular: CGFloat { space.s12 + space.s2 }
    var settingsButtonInsetCompact: CGFloat { space.s8 + space.s2 }
    /// 10pt. Horizontal inset of text fields and the search field.
    var settingsFieldInset: CGFloat { space.s8 + space.s2 }
}

// MARK: - Chrome

/// The fill + stroke surfaces used inside Management. Pick by role, not by
/// colour; the theme decides the colours through its semantic roles.
enum SettingsChrome: Equatable {
    /// The grouped-form surface: `surface.raised` + `border.default`,
    /// `radius.large`, `elevation.raised`.
    case surface
    /// A raised library card: same recipe as `.surface`.
    case card
    /// A library card while hovered: `border.strong`. No hover elevation.
    case cardHover
    /// A card on a dot-grid canvas (Workflows, the Architect's draft):
    /// `surface.canvas` + `border.subtle`, `radius.medium`, flat, so the
    /// grid stops at its edge.
    case canvas
    /// A floating overlay (dialog, popover, menu card): `surface.overlay` +
    /// `border.default`, `radius.xlarge`, `elevation.overlay`.
    case overlay
    /// A control (field, menu button): `surface.raised` + `border.strong`, `radius.medium`.
    case control
    /// A quiet filled chip or secondary button: `surface.subtle` + `border.default`.
    case subtle
    /// A hover wash inside a flat list row: `surface.hover`, `radius.small`, no border.
    case hover
    /// A borderless well inside a group or card: previews, code, nested
    /// read-only blocks. `surface.subtle`, `radius.medium`.
    case inset
    /// A code block: `surface.code`, `radius.medium`, no border.
    case code
    /// A callout in a status tone: `status.<kind>.background` + `status.<kind>.border`.
    case status(ThemeStatusKind)
    /// A callout tinted by a data-driven colour (tool categories, agent
    /// colours). Theme-driven tones must use `.status(_)` or `.selected`.
    case tinted(Color)
    /// The chosen option in a set of option tiles or a selected list row:
    /// `surface.selected` + `border.default`, `radius.medium`.
    case selected
}

extension View {
    /// Applies one of the kit's surfaces. Replaces hand-written
    /// `RoundedRectangle(...).fill(...).overlay(...stroke(...))` stacks.
    /// `radius` overrides the role's corner radius (pass a `theme.radius` value).
    func settingsChrome(_ chrome: SettingsChrome, radius: CGFloat? = nil) -> some View {
        modifier(SettingsChromeModifier(chrome: chrome, radiusOverride: radius))
    }

    /// `nil` draws nothing, for states with no surface
    /// (`isHovering ? .hover : nil`, `isSelected ? .selected : nil`).
    func settingsChrome(_ chrome: SettingsChrome?, radius: CGFloat? = nil) -> some View {
        modifier(SettingsChromeModifier(chrome: chrome, radiusOverride: radius))
    }
}

private struct SettingsChromeModifier: ViewModifier {
    @Environment(\.theme) private var theme
    let chrome: SettingsChrome?
    let radiusOverride: CGFloat?

    private var radius: CGFloat {
        if let radiusOverride { return radiusOverride }
        guard let chrome else { return theme.radius.medium }
        switch chrome {
        case .surface, .card, .cardHover: return theme.radius.large
        case .overlay: return theme.radius.xlarge
        case .control, .subtle, .inset, .code, .status, .tinted, .selected, .canvas: return theme.radius.medium
        case .hover: return theme.radius.small
        }
    }

    private var fill: Color {
        guard let chrome else { return .clear }
        switch chrome {
        case .surface, .card, .cardHover: return theme.surface.raised
        case .overlay: return theme.surface.overlay
        case .canvas: return theme.surface.canvas
        case .control: return theme.surface.raised
        case .subtle, .inset: return theme.surface.subtle
        case .code: return theme.surface.code
        case .hover: return theme.surface.hover
        case .status(let kind): return theme.status[kind].background
        case .tinted(let color): return color.opacity(0.12)
        case .selected: return theme.surface.selected
        }
    }

    private var stroke: Color {
        guard let chrome else { return .clear }
        switch chrome {
        case .surface, .card, .overlay: return theme.border.default
        case .cardHover: return theme.border.strong
        case .canvas: return theme.border.subtle
        case .control: return theme.border.strong
        case .subtle: return theme.border.default
        case .hover, .inset, .code: return .clear
        case .status(let kind): return theme.status[kind].border
        case .tinted(let color): return color
        case .selected: return theme.border.default
        }
    }

    private var lineWidth: CGFloat { theme.stroke.default }

    private var elevation: ThemeElevationRecipe {
        switch chrome {
        case .surface, .card, .cardHover: return theme.elevation.raised
        case .overlay: return theme.elevation.overlay
        default: return theme.elevation.none
        }
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            // Rows inside a surface draw flat, never a card within a card.
            .transformEnvironment(\.settingsInGroup) { inGroup in
                if hostsRows { inGroup = true }
            }
            .background(
                shape
                    .fill(fill)
                    .overlay(shape.strokeBorder(stroke, lineWidth: lineWidth))
                    .themeElevation(elevation)
            )
    }

    private var hostsRows: Bool {
        switch chrome {
        case .surface, .card, .cardHover, .overlay, .canvas, .inset, .code, .status, .tinted, .selected: return true
        case .control, .subtle, .hover, nil: return false
        }
    }
}
