import SwiftUI

enum UserMessageInspectionStyle {
    static let key = "component.library.28."
    static func metric(_ property: String, _ fallback: CGFloat, _ theme: any ThemeProtocol) -> CGFloat {
        theme.assignedMetric(key + property, fallback: fallback)
    }
    static func signature(_ theme: any ThemeProtocol) -> String {
        return ["padding", "gap", "height"].map { "\(metric($0, 0, theme))" }.joined(separator: "|")
            + ["topGap", "attachmentTextGap", "editorActionsGap", "actionButtonsGap"].map { "|\(MessageBubbleInspectionStyle.layout(28, $0, fallback: 0, theme: theme))" }.joined()
            + "|\(theme.lineHeight(.body))|\(theme.nsFont(.body).fontName)|\(theme.nsFont(.body).pointSize)"
    }
}


/// Message cells keep the original app's zero-width outline unless the library
/// assigns the bubble a border. The bubble keys stand apart from the message's
/// container roles, which the scoped family theme reads for its own borders.
enum MessageBubbleInspectionStyle {
    static func key(_ family: Int, _ property: String) -> String { "component.library.\(family).elements.bubble." + property }
    static func hasBorderOverride(_ family: Int, snapshot: DesignThemeSnapshot?) -> Bool {
        guard let mappings = snapshot?.document.mappings else { return false }
        return mappings[key(family, "border")] != nil || mappings[key(family, "borderWidth")] != nil
    }
    static func borderWidth(_ family: Int, theme: any ThemeProtocol) -> CGFloat {
        theme.assignedMetric(key(family, "borderWidth"), fallback: 0)
    }
    static func layout(_ family: Int, _ property: String, fallback: CGFloat, theme: any ThemeProtocol) -> CGFloat {
        theme.assignedMetric("component.library.\(family).elements.layout." + property, fallback: fallback)
    }
}
