import SwiftUI

enum SharedChipSize: String, CaseIterable { case small, regular }
enum SharedChipVariant: String, CaseIterable { case selector, filter, removable }
private struct SharedChipSizeKey: EnvironmentKey { static let defaultValue = SharedChipSize.regular }
private struct SharedChipVariantKey: EnvironmentKey { static let defaultValue = SharedChipVariant.selector }
private struct ComposerInputSurfaceKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var sharedChipSize: SharedChipSize {
        get { self[SharedChipSizeKey.self] }
        set { self[SharedChipSizeKey.self] = newValue }
    }
    var sharedChipVariant: SharedChipVariant {
        get { self[SharedChipVariantKey.self] }
        set { self[SharedChipVariantKey.self] = newValue }
    }
    var isOnComposerInputSurface: Bool {
        get { self[ComposerInputSurfaceKey.self] }
        set { self[ComposerInputSurfaceKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder func composerChipButtonStyle() -> some View {
        buttonStyle(InspectorComposerChipButtonStyle())
    }
    @ViewBuilder func composerChipOriginalWeight(_ weight: Font.Weight) -> some View {
        self
    }
    /// Replace a chip's complete text recipe only in the design build.
    @ViewBuilder func composerChipTextStyle(_ role: ThemeTextStyleRole,
        monospacedDigit: Bool = false, weight: Int? = nil,
        family: ThemeFontFamilyRole? = nil, property: String = "label") -> some View {
        self.modifier(SharedChipTypography(property: property,
            fallback: SettingsFont(role: role, weightOverride: weight, familyOverride: family)))
            .monospacedDigitIfNeeded(monospacedDigit)
    }

    func composerChipInk(_ property: String, fallback: Color) -> some View {
        modifier(InspectorComposerChipInk(property: property, fallback: fallback))
    }

    @ViewBuilder func composerChipSurface(selected: Bool = false, invalid: Bool = false, capsule: Bool = false) -> some View {
        modifier(InspectorComposerChipSurface(selected: selected, invalid: invalid, capsule: capsule))
    }

    @ViewBuilder func composerChipFocus() -> some View {
        modifier(InspectorComposerChipFocus())
    }
}

/// PlainButtonStyle adds its own disabled opacity on macOS. The chip's ink
/// and surface already resolve explicit disabled assignments.
private struct InspectorComposerChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
private extension View {
    @ViewBuilder func monospacedDigitIfNeeded(_ value: Bool) -> some View {
        if value { monospacedDigit() } else { self }
    }
}
private struct InspectorComposerChipInk: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.sharedChipVariant) private var variant
    let property: String
    let fallback: Color
    func body(content: Content) -> some View {
        let key = "component.library.56.elements.\(variant.rawValue)." + (enabled ? property : "disabledForeground")
        content.foregroundStyle(theme.assignedColor(key, fallback: fallback))
            .nativeCatalogTarget([key], "Chip text and icon")
    }
}
private struct InspectorComposerChipFocusedKey: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
    var inspectorComposerChipFocused: Bool {
        get { self[InspectorComposerChipFocusedKey.self] }
        set { self[InspectorComposerChipFocusedKey.self] = newValue }
    }
}
private struct InspectorComposerChipFocus: ViewModifier {
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.focused($focused).focusEffectDisabled()
            .environment(\.inspectorComposerChipFocused, focused)
    }
}
private struct InspectorComposerChipSurface: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isOnComposerInputSurface) private var isOnComposerInputSurface
    @Environment(\.inspectorComposerChipFocused) private var focused
    @State private var hovered = false
    @Environment(\.sharedChipSize) private var size
    @Environment(\.sharedChipVariant) private var variant
    let selected: Bool
    let invalid: Bool
    let capsule: Bool
    func body(content: Content) -> some View {
        let key = "component.library.56.elements.\(variant.rawValue)."
        let sizeKey = "component.library.56.elements.\(size.rawValue)."
        let radius = theme.assignedMetric(key + "radius", fallback: theme.radius.medium)
        let shape = capsule ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        let needsComposerBoundary = isOnComposerInputSurface && !theme.isDark && enabled && !invalid
        let border = theme.assignedColor(key + (invalid ? "error" : selected ? "accent" : "border"), fallback: theme.border.default)
        let borderWidth = theme.assignedMetric(key + "borderWidth", fallback: theme.stroke.default)
        content
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.56.elements.layout.\(size.rawValue).paddingX", inheriting: theme.assignedMetric(sizeKey + "padding", fallback: theme.space.s10)))
            .padding(.vertical, theme.catalogLayoutMetric("component.library.56.elements.layout.\(size.rawValue).paddingY", inheriting: theme.assignedMetric(sizeKey + "gap", fallback: theme.space.s4)))
            .frame(minHeight: theme.assignedMetric(sizeKey + "height", fallback: 0))
            .assignedInteractionBackground(key, state: !enabled ? "disabledBackground" : selected ? "selected" : hovered ? "hover" : "background", fallback: theme.surface.subtle, in: shape)
            .clipShape(shape)
            .overlay(shape.stroke(
                needsComposerBoundary ? theme.assignedColor("color.border.control", fallback: theme.border.strong) : border,
                lineWidth: needsComposerBoundary ? max(theme.stroke.default, borderWidth) : borderWidth
            ))
            .assignedFocusRing(focused && enabled, radius: radius, keyboardOnly: true)
            .contentShape(shape)
            .onHover { hovered = $0 }
            .nativeCatalogTarget(["radius", "background", "hover", "selected", "disabledBackground", "border", "borderWidth", "accent", "error"].map { key + $0 }, "\(variant.rawValue.capitalized) chip")
            .nativeCatalogTarget([sizeKey + "height"], "\(size.rawValue.capitalized) chip size")
            .catalogLayoutTarget("component.library.56.elements.layout.\(size.rawValue).paddingX")
            .catalogLayoutTarget("component.library.56.elements.layout.\(size.rawValue).paddingY")
    }
}
private struct SharedChipTypography: ViewModifier {
    @Environment(\.sharedChipSize) private var size
    let property: String
    let fallback: SettingsFont
    func body(content: Content) -> some View {
        content.assignedTypography("component.library.56.elements.\(size.rawValue).label", fallback: fallback)
    }
}

struct SharedChipContent<Content: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.sharedChipSize) private var size
    let spacing: CGFloat
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.56.elements.layout.\(size.rawValue).contentGap", inheriting: spacing), content: content)
            .catalogLayoutTarget("component.library.56.elements.layout.\(size.rawValue).contentGap")
    }
}
