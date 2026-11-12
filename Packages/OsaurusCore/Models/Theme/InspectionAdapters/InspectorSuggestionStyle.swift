import SwiftUI

enum SuggestionInspectionStyle {
    static let key = "component.library.25."
    static func metric(_ property: String, _ fallback: CGFloat, _ theme: any ThemeProtocol) -> CGFloat {
        theme.assignedMetric(key + property, fallback: fallback)
    }
    static func rowHeight(_ theme: any ThemeProtocol) -> CGFloat {
        let line = ["label", "text", "caption"].map {
            theme.assignedLineHeight(key + $0, fallback: theme.lineHeight(.label))
        }.max() ?? 18
        return max(metric("height", PickerCardMetrics.rowHeight, theme), line + 2 * metric("padding", theme.space.s0, theme))
    }
}
extension View {
    @ViewBuilder func suggestionTextStyle(_ role: ThemeTextStyleRole, property: String) -> some View {
        assignedTypography(SuggestionInspectionStyle.key + property, fallback: SettingsFont(role: role))
    }
    @ViewBuilder func suggestionInk(_ property: String, fallback: Color) -> some View {
        modifier(InspectorSuggestionInk(property: property, fallback: fallback))
    }
    @ViewBuilder func suggestionRowChrome(selected: Bool = false, hovered: Bool = false) -> some View {
        modifier(InspectorSuggestionRow(selected: selected, hovered: hovered))
    }
}
private struct InspectorSuggestionInk: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    let property: String
    let fallback: Color
    func body(content: Content) -> some View {
        content.foregroundStyle(theme.assignedColor(SuggestionInspectionStyle.key + (enabled ? property : "disabledForeground"), fallback: fallback))
    }
}
private struct InspectorSuggestionRow: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    let selected: Bool
    let hovered: Bool
    func body(content: Content) -> some View {
        let key = SuggestionInspectionStyle.key
        content.padding(theme.assignedMetric(key + "padding", fallback: PickerCardMetrics.rowInset))
            .frame(minHeight: theme.assignedMetric(key + "height", fallback: PickerCardMetrics.rowHeight))
            .contentShape(Rectangle())
            .assignedInteractionBackground(key, state: !enabled ? "disabledBackground" : selected ? "selected" : hovered ? "hover" : "background", fallback: theme.surface.overlay, in: RoundedRectangle(cornerRadius: theme.assignedMetric(key + "radius", fallback: theme.radius.medium)))
    }
}
