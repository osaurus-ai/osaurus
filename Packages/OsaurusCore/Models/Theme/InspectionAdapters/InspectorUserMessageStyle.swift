import SwiftUI

enum UserMessageInspectionStyle {
    static let key = "component.library.28."
    static func metric(_ property: String, _ fallback: CGFloat, _ theme: any ThemeProtocol) -> CGFloat {
        theme.assignedMetric(key + property, fallback: fallback)
    }
    static func signature(_ theme: any ThemeProtocol) -> String {
        #if OSAURUS_DESIGN_SYSTEM
        return ["padding", "gap", "height"].map { "\(metric($0, 0, theme))" }.joined(separator: "|")
            + ["topGap", "attachmentTextGap", "editorActionsGap", "actionButtonsGap"].map { "|\(MessageBubbleInspectionStyle.layout(28, $0, fallback: 0, theme: theme))" }.joined()
            + "|\(theme.lineHeight(.body))|\(theme.nsFont(.body).fontName)|\(theme.nsFont(.body).pointSize)"
        #else
        return "original"
        #endif
    }
}


/// Unedited message cells retain the original app's zero-width outline.
/// A deliberate border assignment (including older saved non-default roles)
/// still resolves normally. No mapping or saved style is discarded.
enum MessageBubbleInspectionStyle {
    #if OSAURUS_DESIGN_SYSTEM
    static func hasBorderOverride(_ family: Int, snapshot: DesignThemeSnapshot?) -> Bool {
        guard let snapshot else { return false }
        let prefix = "component.library.\(family)."
        return ["border", "borderWidth"].contains { property in
            let root = prefix + property
            let element = CatalogElementAssignments.routed(root, mappings: snapshot.document.mappings)
            return snapshot.reassignedProperties.contains(root) || snapshot.reassignedProperties.contains(element)
        }
    }
    #endif
    static func borderWidth(_ family: Int, theme: any ThemeProtocol) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        guard hasBorderOverride(family, snapshot: DesignThemeOverlay.shared.current()) else { return 0 }
        return theme.assignedMetric("component.library.\(family).borderWidth", fallback: 0)
        #else
        return 0
        #endif
    }
    static func layout(_ family: Int, _ property: String, fallback: CGFloat, theme: any ThemeProtocol) -> CGFloat {
        theme.assignedMetric("component.library.\(family).elements.layout." + property, fallback: fallback)
    }
}
