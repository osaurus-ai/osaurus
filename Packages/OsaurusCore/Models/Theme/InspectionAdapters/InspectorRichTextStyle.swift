import SwiftUI
import AppKit

enum RichTextInspectionStyle {
    static let key = "component.library.31."
    static func scope(_ theme: any ThemeProtocol) -> any ThemeProtocol {
        if (theme as? CatalogResolvedTheme)?.family == 31 { return theme }
        return theme.catalogFamily(31)
    }
    static func parent(_ theme: any ThemeProtocol) -> any ThemeProtocol {
        if let scoped = theme as? CatalogResolvedTheme, scoped.family == 31 { return scoped.base }
        return theme
    }
    static func metric(_ property: String, _ fallback: CGFloat, _ theme: any ThemeProtocol) -> CGFloat {
        guard (theme as? CatalogResolvedTheme)?.family == 31 else { return fallback }
        return theme.assignedMetric(key + property, fallback: fallback)
    }
    static func spacing(before segment: ContentSegment, theme: any ThemeProtocol) -> CGFloat {
        let field: String
        switch segment.kind {
        case .textGroup: field = "textBlockGap"
        case .codeBlock: field = "codeBlockGap"
        case .image: field = "imageGap"
        case .math: field = "mathGap"
        case .table: field = "tableGap"
        }
        return theme.catalogLayoutMetric(key + "elements.layout." + field, inheriting: metric("gap", segment.spacingBefore, theme))
    }
    static func prepare(_ view: SelectableNSTextView, theme: any ThemeProtocol) {
        view.inspectedQuoteWidth = metric("borderWidth", 3, theme)
        view.inspectedQuoteRadius = metric("radius", 1.5, theme)
    }
}
