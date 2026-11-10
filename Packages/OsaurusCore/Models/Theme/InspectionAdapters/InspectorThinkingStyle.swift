import SwiftUI
import AppKit

enum ThinkingInspectionStyle {
    static let key = "component.library.33."
    static func layout(_ field: String, _ legacy: String, _ fallback: CGFloat, _ theme: any ThemeProtocol) -> CGFloat {
        theme.catalogLayoutMetric(key + "elements.layout." + field, inheriting: metric(legacy, fallback, theme))
    }
    static func metric(_ property: String, _ fallback: CGFloat, _ theme: any ThemeProtocol) -> CGFloat {
        theme.assignedMetric(key + property, fallback: fallback)
    }
    static func headerHeight(_ theme: any ThemeProtocol) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        let font = theme.assignedNativeFont(key + "label", fallback: theme.nsFont(.label))
        let natural = ceil(font.ascender - font.descender + font.leading)
        return max(metric("height", 44, theme), max(28, natural, theme.assignedLineHeight(key + "label", fallback: 18), theme.assignedLineHeight(key + "caption", fallback: 16)) + 2 * layout("headerPaddingY", "padding", 0, theme))
        #else
        return 44
        #endif
    }
    static func statusHeight(_ theme: any ThemeProtocol) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        return max(metric("height", 22, theme), max(theme.assignedLineHeight(key + "label", fallback: 18), theme.assignedLineHeight(key + "caption", fallback: 16)) + 2 * layout("statusPaddingY", "padding", 0, theme))
        #else
        return 22
        #endif
    }
    static func label(_ label: NSTextField, property: String, color: NSColor, theme: any ThemeProtocol, monospacedDigit: Bool = false) {
        #if OSAURUS_DESIGN_SYSTEM
        label.catalogAssignmentTarget([key + property], name: "Text “" + label.stringValue + "”", theme: theme)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.minimumLineHeight = theme.assignedLineHeight(key + property, fallback: 18)
        let font = theme.assignedNativeFont(key + property, fallback: theme.nsFont(.caption))
        label.attributedStringValue = NSAttributedString(string: label.stringValue, attributes: [.font: monospacedDigit ? font.withMonospacedDigits() : font, .foregroundColor: color, .kern: theme.assignedTracking(key + property) ?? 0, .paragraphStyle: paragraph])
        #endif
    }
}
