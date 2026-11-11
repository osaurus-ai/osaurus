import SwiftUI

extension View {
    @ViewBuilder
    func assignedPopover<Card: View>(isPresented: Binding<Bool>, width: CGFloat,
        accessibilityLabel: String, arrowEdge: Edge? = nil, @ViewBuilder content: @escaping () -> Card) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        modifier(InspectorAssignedPopover(isPresented: isPresented, width: width,
            accessibilityLabel: accessibilityLabel, card: content()))
        #else
        popover(isPresented: isPresented, arrowEdge: arrowEdge, content: content)
        #endif
    }
}

extension ThemeProtocol {
    /// The native panel and its card surface must agree on the same minimum.
    /// Keep zero-height measurement phases invisible until content reports size.
    func assignedPickerCardSize(_ size: CGSize) -> CGSize {
        #if OSAURUS_DESIGN_SYSTEM
        guard size.height > 0 else { return size }
        return CGSize(width: size.width, height: max(size.height, assignedMetric("component.library.16.height", fallback: 0)))
        #else
        return size
        #endif
    }

    /// Development-only catalog assignments. Normal builds retain the original theme.
    func catalogFamily(_ id: Int, enabled: Bool = true, authoritative: Bool = false) -> any ThemeProtocol {
        #if OSAURUS_DESIGN_SYSTEM
        return CatalogResolvedTheme(base: self, family: id, enabled: enabled, authoritative: authoritative)
        #else
        return self
        #endif
    }
    func catalogMetric(_ property: String, fallback: CGFloat) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        if let scoped = self as? CatalogResolvedTheme { return scoped.metric(property, fallback: fallback) }
        #endif
        return fallback
    }
}

extension ThemeProtocol {
    func inspectionColor(_ key: String, fallback: Color) -> Color {
        #if OSAURUS_DESIGN_SYSTEM
        return DesignButtonBindings.color(key, theme: self, fallback: fallback)
        #else
        return fallback
        #endif
    }
    func inspectionNumber(_ key: String, fallback: CGFloat) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        return CGFloat(DesignButtonBindings.dimension(key, theme: self, fallback: Double(fallback)))
        #else
        return fallback
        #endif
    }
    func inspectionRole(_ key: String, fallback: ThemeTextStyleRole) -> ThemeTextStyleRole {
        #if OSAURUS_DESIGN_SYSTEM
        return ThemeTextStyleRole(rawValue: String(DesignButtonBindings.role(key).dropFirst(5))) ?? fallback
        #else
        return fallback
        #endif
    }
}

private struct InspectionTypography: ViewModifier {
    @Environment(\.theme) var theme
    let key: String
    let role: ThemeTextStyleRole
    let fallback: Font
    @ViewBuilder func body(content: Content) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        let selected = theme.inspectionRole(key, fallback: role)
        let style = theme.scaledTextStyle(selected)
        content.font(theme.font(for: style)).tracking(style.tracking)
            .lineSpacing(max(0, style.lineHeight - style.size * 1.2))
            .frame(minHeight: style.lineHeight)
        #else
        content.font(fallback)
        #endif
    }
}
extension View {
    func inspectionTypography(_ key: String, role: ThemeTextStyleRole, fallback: Font) -> some View {
        modifier(InspectionTypography(key: key, role: role, fallback: fallback))
    }
}

private struct CatalogTypographyModifier: ViewModifier {
    let theme: any ThemeProtocol
    let role: ThemeTextStyleRole
    let fallback: Font
    @ViewBuilder func body(content: Content) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        if (theme as? CatalogResolvedTheme)?.hasTypographyOverride(role) == true {
            let style = theme.scaledTextStyle(role)
            content.textStyle(role, theme: theme)
                .frame(minHeight: style.lineHeight)
        } else { content.font(fallback) }
        #else
        content.font(fallback)
        #endif
    }
}
extension View {
    func catalogTypography(_ role: ThemeTextStyleRole, theme: any ThemeProtocol, fallback: Font) -> some View {
        modifier(CatalogTypographyModifier(theme: theme, role: role, fallback: fallback))
    }

    /// Preserve the management font descriptor in ordinary builds and use
    /// the inspector's complete assigned recipe in its isolated build.
    @ViewBuilder
    func catalogTypography(_ role: ThemeTextStyleRole, theme: any ThemeProtocol, fallback: SettingsFont) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        if (theme as? CatalogResolvedTheme)?.hasTypographyOverride(role) == true {
            self.textStyle(role, italic: fallback.isItalic, monospacedDigit: fallback.usesMonospacedDigits, theme: theme)
        } else { self.font(fallback) }
        #else
        self.font(fallback)
        #endif
    }
}

// The inspector document is authoritative in this isolated development build.
// Normal builds keep the app's implementation and semantic defaults.
extension ThemeProtocol {
    func assignedColor(_ key: String, fallback: Color) -> Color {
        #if OSAURUS_DESIGN_SYSTEM
        return DesignButtonBindings.color(key, theme: self, fallback: fallback)
        #else
        return fallback
        #endif
    }
    func assignedMetric(_ key: String, fallback: CGFloat) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        return CGFloat(DesignButtonBindings.dimension(key, theme: self, fallback: Double(fallback)))
        #else
        return fallback
        #endif
    }
}

private struct AssignedTypography: ViewModifier {
    @Environment(\.theme) private var theme
    let key: String
    let fallback: SettingsFont
    @ViewBuilder func body(content: Content) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        if case .object(let recipe)? = DesignButtonBindings.value(key, theme: theme) {
            let size = (recipe["size"]?.designNumber ?? 13) * theme.fontScale
            let line = (recipe["lineHeight"]?.designNumber ?? 18) * theme.fontScale
            let weight = Int(recipe["weight"]?.designNumber ?? 400)
            let style = ThemeTextStyle(size: size, weight: weight, lineHeight: line)
            let family = recipe["family"]?.designString ?? "system"
            let font = ThemeFontNameClassifier.font(family: family, size: size, weight: style.fontWeight)
            let nativeFont = ThemeFontNameClassifier.nsFont(family: family, size: size, weight: style.nsFontWeight)
            content.font(font).tracking((recipe["tracking"]?.designNumber ?? 0) * theme.fontScale)
                .lineSpacing(ThemeTextMetrics.extraLeading(for: nativeFont, lineHeight: line))
                .frame(minHeight: line)
                .nativeCatalogTarget([NativeCatalogAssignment.key(key, theme: theme)], NativeCatalogAssignment.name(NativeCatalogAssignment.key(key, theme: theme)))
        } else { content.font(fallback) }
        #else
        content.font(fallback)
        #endif
    }
}
extension View {
    func assignedFocusOutline(_ visible: Bool, radius: CGFloat, color: Color, width: CGFloat, offset: CGFloat) -> some View {
        let outset = offset + width
        return overlay {
            if visible {
                RoundedRectangle(cornerRadius: radius + outset, style: .continuous)
                    .strokeBorder(color, lineWidth: width)
                    .padding(-outset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct AssignedFocusRing: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.appearsActive) private var appearsActive
    let visible: Bool
    let radius: CGFloat
    let buttonKind: ThemeActionKind?
    let keyboardOnly: Bool
    @ViewBuilder func body(content: Content) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        let width = theme.assignedMetric("component.focus.width", fallback: theme.stroke.focus)
        let offset = theme.assignedMetric("component.focus.offset", fallback: theme.focusOffset)
        let color = buttonKind.map { DesignButtonBindings.focusColor($0, theme: theme) }
            ?? theme.assignedColor("component.focus.color", fallback: theme.border.focus)
        let keyboardFocus = DesignKeyboardFocus.shared
        content.focusEffectDisabled(buttonKind != nil && visible)
            .assignedFocusOutline(visible && (!(keyboardOnly || buttonKind != nil) || (appearsActive && keyboardFocus.isVisible)),
                                  radius: radius, color: color, width: width, offset: offset)
        #else
        content.settingsFocusRing(visible, radius: radius)
        #endif
    }
}
extension View {
    /// Normal builds retain their native style. The isolated design build
    /// connects standalone progress indicators to the existing base controls.
    @ViewBuilder func assignedProgressIndicator(tintOverride: Color? = nil) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        progressViewStyle(InspectorAssignedProgressStyle(tintOverride: tintOverride))
        #else
        self
        #endif
    }
    func assignedTypography(_ key: String, fallback: SettingsFont) -> some View {
        modifier(AssignedTypography(key: key, fallback: fallback))
    }
    func assignedFocusRing(_ visible: Bool, radius: CGFloat, buttonKind: ThemeActionKind? = nil,
                           keyboardOnly: Bool = false) -> some View {
        modifier(AssignedFocusRing(visible: visible, radius: radius, buttonKind: buttonKind, keyboardOnly: keyboardOnly))
    }
}

// AppKit-backed search inputs use the same recipe as SwiftUI inputs.
extension ThemeProtocol {
    func assignedNativeFont(_ key: String, fallback: NSFont) -> NSFont {
        #if OSAURUS_DESIGN_SYSTEM
        guard case .object(let recipe)? = DesignButtonBindings.value(key, theme: self) else { return fallback }
        let size = (recipe["size"]?.designNumber ?? 13) * fontScale
        let style = ThemeTextStyle(size: size, weight: Int(recipe["weight"]?.designNumber ?? 400), lineHeight: size)
        let family = recipe["family"]?.designString ?? "system"
        return ThemeFontNameClassifier.nsFont(family: family, size: size, weight: style.nsFontWeight)
        #else
        return fallback
        #endif
    }
    func assignedLineHeight(_ key: String, fallback: CGFloat) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        guard case .object(let recipe)? = DesignButtonBindings.value(key, theme: self) else { return fallback }
        return (recipe["lineHeight"]?.designNumber ?? Double(fallback)) * fontScale
        #else
        return fallback
        #endif
    }
    func assignedTracking(_ key: String) -> CGFloat? {
        #if OSAURUS_DESIGN_SYSTEM
        guard case .object(let recipe)? = DesignButtonBindings.value(key, theme: self) else { return nil }
        return (recipe["tracking"]?.designNumber ?? 0) * fontScale
        #else
        return nil
        #endif
    }
}

// Base components own their style regardless of which product embeds them.
// Keep this compatibility entry point while existing call sites are consolidated.
extension ThemeProtocol {
    func inspectionProductFamily(for property: String, fallback: Int) -> Int {
        fallback
    }
}

// These additive assignment controls inherit the exact old metric until edited.
// This avoids replacing different app defaults with one gallery spacing value.
extension ThemeProtocol {
    func catalogLayoutMetric(_ key: String, inheriting value: CGFloat) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        return CGFloat(CatalogLayoutAssignments.resolve(key, snapshot: DesignThemeOverlay.shared.current(), mode: isDark ? "dark" : "light", inheriting: Double(value)))
        #else
        return value
        #endif
    }
}
extension View {
    @ViewBuilder func catalogLayoutTarget(_ key: String) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        nativeCatalogTarget([key], CatalogLayoutAssignments.byKey[key]?.group ?? "Layout")
        #else
        self
        #endif
    }
}

#if OSAURUS_DESIGN_SYSTEM
private struct InspectorInputPreviewStateKey: EnvironmentKey { static let defaultValue = "default" }
extension EnvironmentValues {
    /// Catalog state specimen only; ordinary app fields always use real input.
    var inspectorInputPreviewState: String {
        get { self[InspectorInputPreviewStateKey.self] }
        set { self[InspectorInputPreviewStateKey.self] = newValue }
    }
}
#endif

#if OSAURUS_DESIGN_SYSTEM
/// Hover/selection tokens are overlays. Retain an opaque assigned base instead
/// of turning the component into glass; an explicit None base remains None.
private struct AssignedInteractionFill<Surface: Shape>: View {
    @Environment(\.theme) private var theme
    let key: String
    let state: String
    let fallback: Color
    let shape: Surface
    var body: some View {
        if state == "disabledBackground" {
            shape.fill(theme.assignedColor(key + state, fallback: fallback))
        } else {
            shape.fill(theme.assignedColor(key + "background", fallback: fallback))
                .overlay {
                    if state != "background" {
                        shape.fill(theme.assignedColor(key + state, fallback: .clear))
                    }
                }
        }
    }
}
extension View {
    func assignedInteractionBackground<Surface: Shape>(_ key: String, state: String, fallback: Color, in shape: Surface) -> some View {
        background(AssignedInteractionFill(key: key, state: state, fallback: fallback, shape: shape))
    }
}
#endif
