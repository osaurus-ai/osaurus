import SwiftUI
import AppKit

enum ActivityInspectionStyle {
    static let key = "component.library.34."
    static func layout(_ field: String, _ legacy: String, _ fallback: CGFloat, _ theme: any ThemeProtocol) -> CGFloat {
        theme.catalogLayoutMetric(key + "elements.layout." + field, inheriting: metric(legacy, fallback, theme))
    }
    static func metric(_ property: String, _ fallback: CGFloat, _ theme: any ThemeProtocol) -> CGFloat {
        theme.assignedMetric(key + property, fallback: fallback)
    }
    static func headerHeight(_ theme: any ThemeProtocol, fallback: CGFloat = 48, property: String = "label") -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        return max(metric("height", fallback, theme), max(28, fieldHeight(property, theme), fieldHeight("caption", theme)) + 2 * layout(property == "heading" ? "headerPaddingY" : "toolHeaderPaddingY", "padding", 0, theme))
        #else
        return fallback
        #endif
    }
    static func fieldHeight(_ property: String, _ theme: any ThemeProtocol, fallback: CGFloat = 18) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        let font = theme.assignedNativeFont(key + property, fallback: theme.nsFont(.caption))
        return max(ceil(font.ascender - font.descender + font.leading), theme.assignedLineHeight(key + property, fallback: fallback))
        #else
        return fallback
        #endif
    }
    static func label(_ field: NSTextField, property: String, theme: any ThemeProtocol) {
        #if OSAURUS_DESIGN_SYSTEM
        // Preserve semantic colors and links already present in composite titles.
        // The leading run is the title; trailing metadata (source, duration,
        // repeat count) keeps the caption face so it reads as secondary.
        let text = NSMutableAttributedString(attributedString: field.attributedStringValue)
        let range = NSRange(location: 0, length: text.length)
        var titleRange = range
        if text.length > 0 { _ = text.attributes(at: 0, effectiveRange: &titleRange) }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        paragraph.minimumLineHeight = theme.assignedLineHeight(key + property, fallback: 18)
        text.addAttributes([.font: theme.assignedNativeFont(key + "caption", fallback: theme.nsFont(.caption)), .kern: theme.assignedTracking(key + property) ?? 0, .paragraphStyle: paragraph], range: range)
        text.addAttribute(.font, value: theme.assignedNativeFont(key + property, fallback: theme.nsFont(.caption)), range: titleRange)
        field.attributedStringValue = text
        field.catalogAssignmentTarget([key + property], name: "Text “" + field.stringValue + "”", theme: theme)
        #endif
    }
}
#if OSAURUS_DESIGN_SYSTEM
/// Presentation behind the existing header hit target; it never handles clicks.
final class InspectorActivityHeaderSurface: NSView {
    private var theme: (any ThemeProtocol)?
    private var element = "toolHeader"
    private var selected = false
    private var hovered = false
    private var tracking: NSTrackingArea?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func configure(theme: any ThemeProtocol, selected: Bool, element: String = "toolHeader") {
        self.theme = theme; self.element = element; self.selected = selected; wantsLayer = true
        catalogAssignmentTarget(["background", "hover", "selected"].map { AgentContentSurfaceAssignments.key(34, element, $0) }, name: element == "activityHeader" ? "Grouped activity header surface" : "Tool result header surface", theme: theme)
        refresh()
    }
    private func refresh() {
        guard let theme else { return }
        layer?.cornerRadius = theme.radius.medium
        layer?.backgroundColor = NSColor(AgentContentSurfaceAssignments.color(34, element, theme, state: hovered ? "hover" : selected ? "selected" : "background")).cgColor
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); hovered = true; refresh() }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); hovered = false; refresh() }
}
#endif
