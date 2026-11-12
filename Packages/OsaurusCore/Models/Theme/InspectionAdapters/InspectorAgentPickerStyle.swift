import SwiftUI

enum AgentPickerInspectionStyle {
    static let key = "component.library.27."
    static func metric(_ property: String, _ fallback: CGFloat, _ theme: any ThemeProtocol) -> CGFloat {
        theme.assignedMetric(key + property, fallback: fallback)
    }
    static func color(_ property: String, _ fallback: Color, _ theme: any ThemeProtocol) -> Color {
        theme.assignedColor(key + property, fallback: fallback)
    }
}

extension View {
    @ViewBuilder func agentPickerInk(_ property: String, fallback: Color) -> some View {
        modifier(InspectorAgentPickerInk(property: property, fallback: fallback))
    }
    @ViewBuilder func agentPickerTextStyle(_ role: ThemeTextStyleRole, property: String, weight: Int? = nil) -> some View {
        assignedTypography(AgentPickerInspectionStyle.key + property, fallback: SettingsFont(role: role, weightOverride: weight))
    }
    @ViewBuilder func agentPickerFont(_ font: SettingsFont, property: String) -> some View {
        assignedTypography(AgentPickerInspectionStyle.key + property, fallback: font)
    }
    @ViewBuilder func agentPickerRowLayout(horizontal: CGFloat, vertical: CGFloat, selected: Bool = false, highlighted: Bool = false) -> some View {
        modifier(InspectorAgentPickerRow(selected: selected, highlighted: highlighted))
    }
    @ViewBuilder func agentPickerSurface() -> some View {
        modifier(InspectorAgentPickerSurface())
    }
    @ViewBuilder func agentPickerButtonStyle() -> some View {
        buttonStyle(AssignedBasePlainButtonStyle())
    }
}

private struct InspectorAgentPickerInk: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    let property: String
    let fallback: Color
    func body(content: Content) -> some View {
        content.foregroundColor(AgentPickerInspectionStyle.color(enabled ? property : "disabledForeground", fallback, theme))
    }
}
private struct InspectorAgentPickerRow: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    let selected: Bool
    let highlighted: Bool
    func body(content: Content) -> some View {
        let k = AgentPickerInspectionStyle.key + "elements.row."
        let radius = theme.assignedMetric(k + "radius", fallback: theme.radius.medium)
        content.padding(theme.assignedMetric(k + "padding", fallback: theme.space.s8))
            .frame(minHeight: theme.assignedMetric(k + "height", fallback: 32))
            .assignedInteractionBackground(k, state: !enabled ? "disabledBackground" : highlighted || hovered ? "hover" : selected ? "selected" : "background", fallback: theme.surface.raised, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(
                highlighted ? theme.assignedColor(k + "border", fallback: theme.border.strong) : .clear,
                lineWidth: theme.assignedMetric(k + "borderWidth", fallback: theme.stroke.default)))
            .contentShape(Rectangle()).onHover { hovered = $0 }
    }
}
private struct InspectorAgentPickerSurface: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View {
        let k = AgentPickerInspectionStyle.key + "elements.container."
        let shape = RoundedRectangle(cornerRadius: theme.assignedMetric(k + "radius", fallback: theme.radius.medium))
        content.background(shape.fill(theme.assignedColor(k + (enabled ? "background" : "disabledBackground"), fallback: theme.surface.raised)))
            .overlay(shape.strokeBorder(theme.assignedColor(k + "border", fallback: theme.border.default),
                lineWidth: theme.assignedMetric(k + "borderWidth", fallback: theme.stroke.default)).allowsHitTesting(false))
    }
}
