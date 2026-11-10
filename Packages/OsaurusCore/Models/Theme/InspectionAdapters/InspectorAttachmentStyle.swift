import AppKit
import SwiftUI

/// Assignment access shared by the existing pre-send and sent attachments.
/// Ordinary builds resolve every helper to its original fallback.
enum AttachmentInspectionStyle {
    static let key = "component.library.24."
    static func metric(_ property: String, _ fallback: CGFloat, _ theme: any ThemeProtocol) -> CGFloat {
        theme.assignedMetric(key + property, fallback: fallback)
    }
    static func color(_ property: String, _ fallback: Color, _ theme: any ThemeProtocol) -> Color {
        theme.assignedColor(key + property, fallback: fallback)
    }
    static func imageMetric(_ property: String, _ fallback: CGFloat, _ theme: any ThemeProtocol) -> CGFloat {
        theme.assignedMetric(key + "elements.image." + property, fallback: fallback)
    }
    static func imageColor(_ property: String, _ fallback: Color, _ theme: any ThemeProtocol) -> Color {
        theme.assignedColor(key + "elements.image." + property, fallback: fallback)
    }
    /// Space between attachments is independent of spacing inside a file pill.
    static func rowGap(_ theme: any ThemeProtocol) -> CGFloat {
        theme.assignedMetric(key + "elements.container.gap", fallback: 6)
    }
    static func documentHeight(_ theme: any ThemeProtocol) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        let line = max(theme.assignedLineHeight(key + "text", fallback: 16),
            theme.assignedLineHeight(key + "caption", fallback: 13))
        let fontHeight = max(theme.assignedNativeFont(key + "text", fallback: theme.nsFont(.footnote)).boundingRectForFont.height,
            theme.assignedNativeFont(key + "caption", fallback: theme.nsFont(.micro)).boundingRectForFont.height)
        let fileHeight = max(metric("height", 26, theme), max(20, line, fontHeight) + 2 * metric("padding", 5, theme))
        let imageHeight = imageMetric("height", 32, theme) + 2 * imageMetric("padding", 0, theme)
        return ceil(max(fileHeight, imageHeight))
        #else
        return 26
        #endif
    }
    static func imageHeight(_ theme: any ThemeProtocol, fallback: CGFloat = 96) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        return documentHeight(theme)
        #else
        return fallback
        #endif
    }
    static func geometrySignature(_ theme: any ThemeProtocol) -> String {
        #if OSAURUS_DESIGN_SYSTEM
        return "\(documentHeight(theme))|\(imageHeight(theme))|\(rowGap(theme))|\(metric("gap", 6, theme))|\(metric("padding", 8, theme))"
        #else
        return "original"
        #endif
    }
    static func text(_ string: String, property: String, role: ThemeTextStyleRole,
        color: Color, theme: any ThemeProtocol) -> NSAttributedString {
        var attributes = theme.textAttributes(role)
        #if OSAURUS_DESIGN_SYSTEM
        let font = theme.assignedNativeFont(key + property, fallback: theme.nsFont(role))
        let paragraph = NSMutableParagraphStyle()
        // These are single-line NSTextField labels. The chip's measured height
        // already reserves the assigned line height; forcing it into the cell
        // displaces glyphs differently for filename and metadata font sizes.
        paragraph.lineBreakMode = .byTruncatingMiddle
        attributes[.font] = font
        attributes[.paragraphStyle] = paragraph
        attributes[.kern] = theme.assignedTracking(key + property) ?? 0
        #endif
        attributes[.foregroundColor] = NSColor(color)
        return NSAttributedString(string: string, attributes: attributes)
    }
}

extension View {
    @ViewBuilder func attachmentTextStyle(_ role: ThemeTextStyleRole, property: String, weight: Int? = nil) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        assignedTypography(AttachmentInspectionStyle.key + property, fallback: SettingsFont(role: role, weightOverride: weight))
        #else
        textStyle(role, weight: weight)
        #endif
    }
    @ViewBuilder func attachmentInk(_ property: String, fallback: Color) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        modifier(InspectorAttachmentInk(property: property, fallback: fallback))
        #else
        foregroundColor(fallback)
        #endif
    }
}

#if OSAURUS_DESIGN_SYSTEM
private struct InspectorAttachmentInk: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    let property: String
    let fallback: Color
    func body(content: Content) -> some View {
        content.foregroundStyle(AttachmentInspectionStyle.color(enabled ? property : "disabledForeground", fallback, theme))
    }
}
#endif

struct AttachmentImageChrome: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        content.assignedBaseChrome(24, fallback: nil, element: "image")
        #else
        content
        #endif
    }
}

#if OSAURUS_DESIGN_INSPECTOR
/// Local attachment bytes for the existing composer and real native chat screen.
/// No file picker, model request, or account changes are needed for this state.
@MainActor enum InspectorAttachmentSamples {
    static var items: [Attachment] {
        var result: [Attachment] = [
            .document(filename: "A-long-local-attachment-filename-for-truncation.txt", content: "Local attachment preview.\nSecond line.", fileSize: 2048),
            .pastedContent("Local pasted content.\nSecond line.\nThird line.")
        ]
        let image = NSImage(size: NSSize(width: 80, height: 40), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill()
            NSColor.systemYellow.setFill(); NSRect(x: 10, y: 8, width: 20, height: 20).fill()
            return true
        }
        if let data = image.tiffRepresentation { result.append(.image(data)) }
        return result
    }
}
#endif
