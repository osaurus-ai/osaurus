import SwiftUI

enum PromptInspectionStyle {
    static let key = "component.library.36."
    /// A shared badge uses the appearance's base colors, even inside a scoped prompt.
    static func badgeTheme(_ theme: any ThemeProtocol) -> any ThemeProtocol {
        #if OSAURUS_DESIGN_SYSTEM
        var base = theme
        while let scoped = base as? CatalogResolvedTheme { base = scoped.base }
        return base
        #else
        return theme
        #endif
    }

    static func fill(hovered: Bool, enabled: Bool = true, selected: Bool = false, theme: any ThemeProtocol, fallback: Color) -> Color {
        #if OSAURUS_DESIGN_SYSTEM
        let part = !enabled ? "disabledBackground" : selected ? "selected" : hovered ? "hover" : "background"
        return theme.assignedColor(key + part, fallback: fallback)
        #else
        return fallback
        #endif
    }
    static func metric(_ property: String, _ fallback: CGFloat, _ theme: any ThemeProtocol) -> CGFloat {
        theme.assignedMetric(key + property, fallback: fallback)
    }
}
extension View {
    @ViewBuilder
    func promptText(_ role: ThemeTextStyleRole, fallback: ThemeTextStyleRole, weight: Int? = nil, family: ThemeFontFamilyRole? = nil, theme: any ThemeProtocol) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        self.textStyle(role, theme: theme)
        #else
        self.textStyle(fallback, weight: weight, family: family, theme: theme)
        #endif
    }
}
extension ThemedAlertRequest {
    func promptInspectionScope() -> Self {
        #if OSAURUS_DESIGN_SYSTEM
        var result = self; result.inspectionFamily = 36; return result
        #else
        return self
        #endif
    }
}
