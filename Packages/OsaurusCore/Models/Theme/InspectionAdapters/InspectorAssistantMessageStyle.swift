import SwiftUI

enum AssistantMessageInspectionStyle {
    static let key = "component.library.29."
    static func metric(_ property: String, _ fallback: CGFloat, _ theme: any ThemeProtocol) -> CGFloat {
        theme.assignedMetric(key + property, fallback: fallback)
    }
}
