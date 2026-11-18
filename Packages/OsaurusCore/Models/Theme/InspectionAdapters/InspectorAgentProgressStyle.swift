import SwiftUI

enum AgentProgressInspectionStyle {
    static let key = "component.library.35."
    static func metric(_ property: String, _ fallback: CGFloat, _ theme: any ThemeProtocol) -> CGFloat {
        theme.assignedMetric(key + property, fallback: fallback)
    }
    static func highlight(hovered: Bool, pinned: Bool, theme: any ThemeProtocol) -> Color? {
        return AgentContentSurfaceAssignments.color(35, "todo", theme, state: hovered ? "hover" : pinned ? "selected" : "background")
    }
    static func collapsedHeight(_ theme: any ThemeProtocol) -> CGFloat {
        return max(metric("height", 38, theme), max(theme.assignedLineHeight(key + "label", fallback: 18), theme.assignedLineHeight(key + "caption", fallback: 16), 16) + 2 * metric("padding", theme.space.s8, theme))
    }
}
extension View {
    @ViewBuilder
    func agentProgressText(_ role: ThemeTextStyleRole, fallback: ThemeTextStyleRole, weight: Int? = nil, family: ThemeFontFamilyRole? = nil, theme: any ThemeProtocol) -> some View {
        self.textStyle(role, theme: theme)
    }
}
