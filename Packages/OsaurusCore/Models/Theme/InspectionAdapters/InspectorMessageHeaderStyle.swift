import AppKit
import SwiftUI

/// Geometry shared by the existing native header, footer and table estimator.
enum MessageHeaderInspectionStyle {
    static let key = "component.library.30."
    static func layout(_ field: String, _ legacy: String, _ fallback: CGFloat, _ theme: any ThemeProtocol) -> CGFloat {
        theme.catalogLayoutMetric(key + "elements.layout." + field, inheriting: metric(legacy, fallback, theme))
    }
    static func metric(_ property: String, _ fallback: CGFloat, _ theme: any ThemeProtocol) -> CGFloat {
        theme.assignedMetric(key + property, fallback: fallback)
    }
    static func side(_ theme: any ThemeProtocol) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        // Message actions reuse the actual Extra small icon-button component.
        return theme.assignedMetric("component.button.size.extraSmall.height", fallback: 28)
        #else
        return 28
        #endif
    }
    static func avatarSide(_ theme: any ThemeProtocol) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        return theme.assignedMetric("component.library.11.avatarSize", fallback: theme.controlSize.chatAvatar)
        #else
        return theme.controlSize.chatAvatar
        #endif
    }
    static func captionHeight(_ theme: any ThemeProtocol) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        return max(metric("height", 24, theme), theme.assignedLineHeight(key + "caption", fallback: 16))
        #else
        return 24
        #endif
    }
    static func text(_ value: String, property: String, color: NSColor, theme: any ThemeProtocol) -> NSAttributedString {
        let role: ThemeTextStyleRole = property == "label" ? .label : .caption
        #if OSAURUS_DESIGN_SYSTEM
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.minimumLineHeight = theme.assignedLineHeight(key + property, fallback: CGFloat(theme.lineHeight(role)))
        return NSAttributedString(string: value, attributes: [NSAttributedString.Key("OsaurusCatalogAssignment"): NativeCatalogAssignment.key(key + property, theme: theme), .font: theme.assignedNativeFont(key + property, fallback: theme.nsFont(role)), .foregroundColor: color, .kern: theme.assignedTracking(key + property) ?? 0, .paragraphStyle: paragraph])
        #else
        return NSAttributedString(string: value, attributes: [.font: theme.nsFont(role), .foregroundColor: color])
        #endif
    }
}
