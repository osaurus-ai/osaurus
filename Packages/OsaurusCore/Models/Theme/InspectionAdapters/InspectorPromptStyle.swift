import SwiftUI

enum PromptInspectionStyle {
    static let key = "component.library.36."
    /// A shared badge uses the appearance's base colors, even inside a scoped prompt.
    static func badgeTheme(_ theme: any ThemeProtocol) -> any ThemeProtocol {
        var base = theme
        while let scoped = base as? CatalogResolvedTheme { base = scoped.base }
        return base
    }

    static func fill(hovered: Bool, enabled: Bool = true, selected: Bool = false, theme: any ThemeProtocol, fallback: Color) -> Color {
        let part = !enabled ? "disabledBackground" : selected ? "selected" : hovered ? "hover" : "background"
        return theme.assignedColor(key + part, fallback: fallback)
    }
    static func metric(_ property: String, _ fallback: CGFloat, _ theme: any ThemeProtocol) -> CGFloat {
        theme.assignedMetric(key + property, fallback: fallback)
    }
}
extension View {
    @ViewBuilder
    func promptText(_ role: ThemeTextStyleRole, fallback: ThemeTextStyleRole, weight: Int? = nil, family: ThemeFontFamilyRole? = nil, theme: any ThemeProtocol) -> some View {
        self.textStyle(role, theme: theme)
    }
}
extension ThemedAlertRequest {
    func promptInspectionScope() -> Self {
        var result = self; result.inspectionFamily = 36; return result
    }
}
