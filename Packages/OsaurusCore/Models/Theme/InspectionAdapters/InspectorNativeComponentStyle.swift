import SwiftUI
import AppKit

/// Shared native text adapter for existing product views. It changes styling,
/// never the underlying action, text value, selection or execution state.
enum NativeComponentInspectionStyle {
    static func key(_ family: Int, _ property: String) -> String { "component.library.\(family).\(property)" }
    static func metric(_ family: Int, _ property: String, _ fallback: CGFloat, _ theme: any ThemeProtocol) -> CGFloat {
        theme.assignedMetric(key(family, property), fallback: fallback)
    }
    static func label(_ field: NSTextField, family: Int, property: String, theme: any ThemeProtocol) {
        #if OSAURUS_DESIGN_SYSTEM
        let font = theme.assignedNativeFont(key(family, property), fallback: field.font ?? theme.nsFont(.body))
        field.font = font
        let text = NSMutableAttributedString(attributedString: field.attributedStringValue)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = field.lineBreakMode
        paragraph.minimumLineHeight = theme.assignedLineHeight(key(family, property), fallback: field.font?.pointSize ?? 16)
        text.addAttributes([.font: font, .kern: theme.assignedTracking(key(family, property)) ?? 0, .paragraphStyle: paragraph], range: NSRange(location: 0, length: text.length))
        field.attributedStringValue = text
        field.catalogAssignmentTarget([key(family, property)], name: "Text “" + field.stringValue + "”", theme: theme)
        #endif
    }
    static func button(_ button: NSButton, family: Int, property: String, theme: any ThemeProtocol) {
        #if OSAURUS_DESIGN_SYSTEM
        let field = NSTextField(labelWithString: button.title)
        field.font = button.font; field.textColor = button.contentTintColor ?? NSColor(theme.text.primary)
        label(field, family: family, property: property, theme: theme)
        button.attributedTitle = field.attributedStringValue
        button.font = theme.assignedNativeFont(key(family, property), fallback: button.font ?? theme.nsFont(.label))
        #endif
    }
}

extension View {
    @ViewBuilder
    func componentInspectionText(_ familyId: Int, role: ThemeTextStyleRole, fallback: ThemeTextStyleRole, italic: Bool = false, monospacedDigit: Bool = false, weight: Int? = nil, family: ThemeFontFamilyRole? = nil, lineBox: Bool = false, theme: any ThemeProtocol) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        let scoped = theme.catalogFamily(familyId, authoritative: true)
        let styled = self.textStyle(role, italic: italic, monospacedDigit: monospacedDigit, theme: scoped)
        if lineBox { styled.modifier(ThemeTextLineBoxModifier(role: role, theme: scoped)) }
        else { styled }
        #else
        let styled = self.textStyle(fallback, italic: italic, monospacedDigit: monospacedDigit, weight: weight, family: family, theme: theme)
        if lineBox { styled.modifier(ThemeTextLineBoxModifier(role: fallback, weight: weight, family: family, theme: theme)) }
        else { styled }
        #endif
    }
}

extension View {
    @ViewBuilder
    func componentInspectionSurface(_ family: Int, background: Color, border: Color? = nil, radius: CGFloat, width: CGFloat = 0, selected: Bool = false) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        self.assignedBaseChrome(family, fallback: nil, selected: selected)
        #else
        self.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(background))
            .overlay { if let border { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(border, lineWidth: width) } }
        #endif
    }
}
