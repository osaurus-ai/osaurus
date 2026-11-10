import AppKit
import SwiftUI

enum ModelPickerInspectionStyle {
    static let key = "component.library.26."
    static func metric(_ property: String, _ fallback: CGFloat, _ theme: any ThemeProtocol) -> CGFloat {
        theme.assignedMetric(key + property, fallback: fallback)
    }
    static func color(_ property: String, _ fallback: Color, _ theme: any ThemeProtocol) -> Color {
        theme.assignedColor(key + property, fallback: fallback)
    }
    static func rowHeight(_ theme: any ThemeProtocol) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        return max(metric("height", 36, theme), theme.assignedLineHeight(key + "label", fallback: 20) + 2 * metric("padding", 0, theme))
        #else
        return 36
        #endif
    }
}

extension View {
    @ViewBuilder func modelPickerTextStyle(_ role: ThemeTextStyleRole, property: String, weight: Int? = nil) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        assignedTypography(ModelPickerInspectionStyle.key + property, fallback: SettingsFont(role: role, weightOverride: weight))
        #else
        textStyle(role, weight: weight)
        #endif
    }
    @ViewBuilder func modelPickerFont(_ font: SettingsFont, property: String) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        assignedTypography(ModelPickerInspectionStyle.key + property, fallback: font)
        #else
        self.font(font)
        #endif
    }
    @ViewBuilder func modelPickerInk(_ property: String, fallback: Color, muted: Bool = false) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        modifier(InspectorModelPickerInk(property: property, fallback: fallback, muted: muted))
        #else
        foregroundStyle(fallback)
        #endif
    }
    @ViewBuilder func modelPickerRowChrome(selected: Bool, hovered: Bool, focused: Bool) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        modifier(InspectorModelPickerRow(selected: selected, hovered: hovered, focused: focused))
        #else
        pickerCardRowChrome(highlighted: selected || hovered || focused)
        #endif
    }
}

#if OSAURUS_DESIGN_SYSTEM
private struct InspectorModelPickerInk: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    let property: String
    let fallback: Color
    let muted: Bool
    func body(content: Content) -> some View {
        content.foregroundStyle(ModelPickerInspectionStyle.color(!enabled || muted ? "disabledForeground" : property, fallback, theme))
    }
}
private struct InspectorModelPickerRow: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    let selected: Bool
    let hovered: Bool
    let focused: Bool
    func body(content: Content) -> some View {
        let key = ModelPickerInspectionStyle.key + "elements.row."
        let radius = theme.assignedMetric(key + "radius", fallback: theme.radius.medium)
        content.padding(theme.assignedMetric(key + "padding", fallback: 12))
            .frame(minHeight: theme.assignedMetric(key + "height", fallback: 36))
            .contentShape(Rectangle())
            .assignedInteractionBackground(key, state: !enabled ? "disabledBackground" : selected ? "selected" : hovered || focused ? "hover" : "background", fallback: theme.surface.overlay, in: RoundedRectangle(cornerRadius: radius))
            .assignedFocusRing(focused && enabled, radius: radius, keyboardOnly: true)
    }
}

/// Cached once per theme revision; native rows do not decode recipes on hover.
struct InspectorNativeModelPickerRecipe {
    let label: [NSAttributedString.Key: Any]
    let text: [NSAttributedString.Key: Any]
    let caption: [NSAttributedString.Key: Any]
    let labelHeight: CGFloat
    let textHeight: CGFloat
    let captionHeight: CGFloat
    let padding: CGFloat
    let gap: CGFloat
    let minimumHeight: CGFloat
    let radius: CGFloat
    let badgeAccent: NSColor
    let badgeSecondary: NSColor
    let badgeRadius: CGFloat
    let badgeBackground: NSColor
    let badgeBorder: NSColor
    let badgeBorderWidth: CGFloat
    let badgeCaption: [NSAttributedString.Key: Any]
    let badgeCaptionHeight: CGFloat
    let borderWidth: CGFloat
    let foreground: NSColor
    let secondary: NSColor
    let accent: NSColor
    let background: NSColor
    let selected: NSColor
    let hover: NSColor
    let disabledForeground: NSColor
    let disabledBackground: NSColor
    let border: NSColor
    init(theme: any ThemeProtocol) {
        let key = ModelPickerInspectionStyle.key + "elements.row."
        func attributes(_ property: String, _ role: ThemeTextStyleRole) -> [NSAttributedString.Key: Any] {
            var a = theme.textAttributes(role)
            let font = theme.assignedNativeFont(key + property, fallback: theme.nsFont(role))
            let p = NSMutableParagraphStyle()
            p.minimumLineHeight = max(font.boundingRectForFont.height, theme.assignedLineHeight(key + property, fallback: theme.lineHeight(role)))
            p.maximumLineHeight = p.minimumLineHeight
            p.lineBreakMode = .byTruncatingTail
            a[.font] = font; a[.paragraphStyle] = p; a[.kern] = theme.assignedTracking(key + property) ?? 0
            return a
        }
        let badgeKey = ModelPickerInspectionStyle.key + "elements.badge."
        badgeAccent = NSColor(theme.assignedColor(badgeKey + "accent", fallback: theme.border.focus))
        badgeSecondary = NSColor(theme.assignedColor(badgeKey + "secondary", fallback: theme.text.secondary))
        badgeRadius = theme.assignedMetric(badgeKey + "radius", fallback: theme.radius.medium)
        badgeBackground = NSColor(theme.assignedColor(badgeKey + "selected", fallback: theme.surface.raised))
        badgeBorder = NSColor(theme.assignedColor(badgeKey + "border", fallback: theme.border.default))
        badgeBorderWidth = theme.assignedMetric(badgeKey + "borderWidth", fallback: theme.stroke.default)
        var badgeAttributes = theme.textAttributes(.micro)
        let badgeFont = theme.assignedNativeFont(badgeKey + "caption", fallback: theme.nsFont(.micro))
        let badgeParagraph = NSMutableParagraphStyle()
        badgeParagraph.minimumLineHeight = theme.assignedLineHeight(badgeKey + "caption", fallback: theme.lineHeight(.micro))
        badgeParagraph.maximumLineHeight = badgeParagraph.minimumLineHeight
        badgeAttributes[.font] = badgeFont; badgeAttributes[.paragraphStyle] = badgeParagraph
        badgeAttributes[.kern] = theme.assignedTracking(badgeKey + "caption") ?? 0
        badgeCaption = badgeAttributes
        badgeCaptionHeight = max(badgeFont.boundingRectForFont.height, badgeParagraph.minimumLineHeight)
        label = attributes("label", .caption); text = attributes("text", .micro); caption = attributes("caption", .micro)
        func height(_ a: [NSAttributedString.Key: Any]) -> CGFloat { (a[.paragraphStyle] as? NSParagraphStyle)?.minimumLineHeight ?? 18 }
        labelHeight = height(label); textHeight = height(text); captionHeight = height(caption)
        padding = theme.assignedMetric(key + "padding", fallback: 12)
        gap = theme.assignedMetric(key + "gap", fallback: 4)
        minimumHeight = theme.assignedMetric(key + "height", fallback: 36)
        radius = theme.assignedMetric(key + "radius", fallback: theme.radius.medium)
        borderWidth = theme.assignedMetric(key + "borderWidth", fallback: theme.stroke.default)
        func c(_ name: String, _ fallback: Color) -> NSColor { NSColor(theme.assignedColor(key + name, fallback: fallback)) }
        foreground = c("foreground", theme.text.primary); secondary = c("secondary", theme.text.secondary)
        accent = c("accent", theme.border.focus); background = c("background", theme.surface.raised)
        selected = c("selected", theme.surface.selected); hover = c("hover", theme.surface.hover)
        disabledForeground = c("disabledForeground", theme.text.disabled)
        disabledBackground = c("disabledBackground", theme.surface.disabled); border = c("border", theme.border.default)
    }
    var metaHeight: CGFloat { max(textHeight, badgeCaptionHeight + 6) }
    func rowHeight(_ row: ModelPickerRow) -> CGFloat {
        let meta = row.description?.isEmpty == false || row.parameterCount != nil || row.quantization != nil || row.mediaPrivacy?.isEmpty == false || row.mediaPrice?.isEmpty == false
        let details = row.mediaKind != nil && row.description?.isEmpty == false
        return ceil(max(minimumHeight, 2 * padding + labelHeight + (meta ? gap + metaHeight : 0) + (details ? gap + textHeight : 0)))
    }
    func string(_ value: String, attributes: [NSAttributedString.Key: Any], color: NSColor) -> NSAttributedString {
        var a = attributes; a[.foregroundColor] = color
        return NSAttributedString(string: value, attributes: a)
    }
}
#endif
