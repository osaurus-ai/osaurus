//
//  ThemeTextStyleModifier.swift
//  osaurus
//
//  Applies a complete named text style (family, size, weight, line height,
//  tracking) from the active theme, and the hairline stroke helpers.
//

import SwiftUI

/// Environment-propagating half of a text style: font, tracking and the
/// leading between wrapped lines. Safe on containers.
struct ThemeTextStyleModifier: ViewModifier {
    @Environment(\.theme) private var environmentTheme

    let role: ThemeTextStyleRole
    var italic = false
    var monospacedDigit = false
    /// Numeric design weight replacing the role's own (600 semibold, …).
    var weight: Int?
    /// Draws the role from the other shared family (a code-set footnote).
    var family: ThemeFontFamilyRole?
    var theme: ThemeProtocol?

    func body(content: Content) -> some View {
        let theme = theme ?? environmentTheme
        let style = ThemeTextStyleModifier.style(role, weight: weight, family: family, in: theme)
        content
            .font(resolvedFont(theme: theme, style: style))
            .tracking(CGFloat(style.tracking))
            .lineSpacing(resolvedLineSpacing(theme: theme, style: style))
            #if OSAURUS_DESIGN_SYSTEM
            .nativeCatalogTextTarget(role: role, theme: theme)
            #endif
    }

    static func style(
        _ role: ThemeTextStyleRole, weight: Int?, family: ThemeFontFamilyRole?, in theme: ThemeProtocol
    ) -> ThemeTextStyle {
        var style = theme.scaledTextStyle(role)
        if let weight { style.weight = weight }
        if let family { style.family = family }
        return style
    }

    static func lineSpacing(_ style: ThemeTextStyle, in theme: ThemeProtocol) -> CGFloat {
        ThemeTextMetrics.extraLeading(for: theme.nsFont(for: style), lineHeight: CGFloat(style.lineHeight))
    }

    private func resolvedLineSpacing(theme: ThemeProtocol, style: ThemeTextStyle) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        if let scoped = theme as? CatalogResolvedTheme, let assigned = scoped.nativeAssignedFont(role) {
            return ThemeTextMetrics.extraLeading(for: assigned, lineHeight: style.lineHeight)
        }
        #endif
        return Self.lineSpacing(style, in: theme)
    }

    private func resolvedFont(theme: ThemeProtocol, style: ThemeTextStyle) -> Font {
        var font = theme.font(for: style)
        #if OSAURUS_DESIGN_SYSTEM
        if let scoped = theme as? CatalogResolvedTheme, let assigned = scoped.nativeAssignedFont(role) {
            font = Font(assigned)
        }
        #endif
        if italic { font = font.italic() }
        if monospacedDigit { font = font.monospacedDigit() }
        return font
    }
}

/// Text-only, opt-in: splits the leading above and below a single line so a
/// one-line label occupies the style's full line height, like CSS line-height.
/// Chrome (chips, buttons, rows, fixed frames) must not use it; it is for
/// prose that has to line up with a neighbouring multi-line block.
struct ThemeTextLineBoxModifier: ViewModifier {
    @Environment(\.theme) private var environmentTheme

    let role: ThemeTextStyleRole
    var weight: Int?
    var family: ThemeFontFamilyRole?
    var theme: ThemeProtocol?

    @ViewBuilder func body(content: Content) -> some View {
        let theme = theme ?? environmentTheme
        let style = ThemeTextStyleModifier.style(role, weight: weight, family: family, in: theme)
        #if OSAURUS_DESIGN_SYSTEM
        if let scoped = theme as? CatalogResolvedTheme, let assigned = scoped.nativeAssignedFont(role) {
            content.padding(.vertical, ThemeTextMetrics.extraLeading(for: assigned, lineHeight: style.lineHeight) / 2)
        } else {
            content.padding(.vertical, ThemeTextStyleModifier.lineSpacing(style, in: theme) / 2)
        }
        #else
        content.padding(.vertical, ThemeTextStyleModifier.lineSpacing(style, in: theme) / 2)
        #endif
    }
}

extension View {
    /// Applies the named text style from the theme. Prefer this over
    /// `.font(...)` so line height and tracking travel with the font.
    func textStyle(
        _ role: ThemeTextStyleRole,
        italic: Bool = false,
        monospacedDigit: Bool = false,
        weight: Int? = nil,
        family: ThemeFontFamilyRole? = nil,
        theme: ThemeProtocol? = nil
    ) -> some View {
        modifier(
            ThemeTextStyleModifier(
                role: role, italic: italic, monospacedDigit: monospacedDigit, weight: weight, family: family,
                theme: theme))
    }
}

extension Text {
    /// Applies the named text style. `lineBox` reserves the role's full line
    /// height around a single line; leave it off for chrome.
    @ViewBuilder
    func textStyle(
        _ role: ThemeTextStyleRole,
        italic: Bool = false,
        monospacedDigit: Bool = false,
        weight: Int? = nil,
        family: ThemeFontFamilyRole? = nil,
        lineBox: Bool = false,
        theme: ThemeProtocol? = nil
    ) -> some View {
        let styled = modifier(
            ThemeTextStyleModifier(
                role: role, italic: italic, monospacedDigit: monospacedDigit, weight: weight, family: family,
                theme: theme))
        if lineBox {
            styled.modifier(ThemeTextLineBoxModifier(role: role, weight: weight, family: family, theme: theme))
        } else {
            styled
        }
    }
}

extension View {
    /// Sizes an SF Symbol or monogram glyph to the shape that holds it
    /// (avatar circles, badges). Glyphs are artwork, not text, so they track
    /// their container rather than a text style.
    func glyphSize(_ points: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        font(.system(size: points, weight: weight, design: design))
    }
}

// MARK: - Hairline

/// Strokes a shape's inside edge with exactly one physical pixel.
struct ThemeHairlineBorderModifier<S: InsettableShape>: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    let shape: S
    let color: Color

    func body(content: Content) -> some View {
        content.overlay(shape.strokeBorder(color, lineWidth: theme.hairline(forBackingScale: displayScale)))
    }
}

extension View {
    /// One-physical-pixel border (`stroke.hairline`) in `color`.
    func hairlineBorder<S: InsettableShape>(_ color: Color, in shape: S) -> some View {
        modifier(ThemeHairlineBorderModifier(shape: shape, color: color))
    }

    /// One-physical-pixel rounded border (`stroke.hairline`) in `color`.
    func hairlineBorder(_ color: Color, cornerRadius: CGFloat) -> some View {
        hairlineBorder(color, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// A divider drawn at one physical pixel in `border.subtle`.
struct ThemeHairlineDivider: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    var axis: Axis = .horizontal
    var color: Color? = nil

    var body: some View {
        let width = theme.hairline(forBackingScale: displayScale)
        Rectangle()
            .fill(color ?? theme.border.subtle)
            .frame(width: axis == .vertical ? width : nil, height: axis == .horizontal ? width : nil)
    }
}
