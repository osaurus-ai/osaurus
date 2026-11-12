import SwiftUI

/// The existing catalog slider drawing, connected to the app's original range,
/// step and value binding. Native Slider supplies accessibility semantics.
struct AssignedBaseSlider: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var label: String = "Value"
    var onEditingChanged: (Bool) -> Void = { _ in }
    @FocusState private var focused: Bool
    @State private var dragging = false
    private var family: Int { theme.inspectionProductFamily(for: "trackHeight", fallback: 7) }
    private var prefix: String { "component.library.\(family).elements.progress." }
    private var fraction: Double { range.upperBound > range.lowerBound ? min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound))) : 0 }
    private func number(_ property: String, _ fallback: CGFloat) -> CGFloat { theme.assignedMetric(prefix + property, fallback: fallback) }
    private func color(_ property: String, _ fallback: Color) -> Color { theme.assignedColor(prefix + (enabled ? property : property == "foreground" || property == "accent" ? "disabledForeground" : "disabledBackground"), fallback: fallback) }
    private func set(_ proposed: Double) {
        guard enabled, proposed.isFinite else { return }
        let quantized = step.flatMap { $0 > 0 ? range.lowerBound + ((proposed - range.lowerBound) / $0).rounded() * $0 : nil } ?? proposed
        value = min(range.upperBound, max(range.lowerBound, quantized))
    }
    private var accessibleValue: Binding<Double> { Binding(get: { value }, set: { set($0) }) }
    var body: some View {
        GeometryReader { geometry in
            let thumb = number("thumbSize", 16)
            let height = number("trackHeight", 6)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: number("radius", 4)).fill(enabled ? theme.emptyTrack(color("selected", theme.surface.selected)) : color("selected", theme.surface.selected)).frame(height: height)
                RoundedRectangle(cornerRadius: number("radius", 4)).fill(color("accent", theme.border.focus)).frame(width: geometry.size.width * fraction, height: height)
                Circle().fill(color("foreground", theme.text.primary))
                    .frame(width: thumb, height: thumb)
                    .overlay(Circle().strokeBorder(theme.assignedColor(prefix + "border", fallback: theme.border.default), lineWidth: number("borderWidth", 1)))
                    .offset(x: max(0, geometry.size.width - thumb) * fraction)
            }.frame(maxHeight: .infinity).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    guard enabled else { return }
                    if !dragging { dragging = true; onEditingChanged(true) }
                    set(range.lowerBound + max(0, min(1, event.location.x / max(1, geometry.size.width))) * (range.upperBound - range.lowerBound))
                }.onEnded { _ in
                    if dragging { dragging = false; onEditingChanged(false) }
                })
        }.frame(height: max(number("height", 32), number("thumbSize", 16)))
            .focusable(enabled).focused($focused).focusEffectDisabled()
            .assignedBaseFocusRing(family, visible: focused && enabled, radius: number("radius", 4))
            .onKeyPress(.leftArrow) { guard enabled else { return .ignored }; set(value - (step ?? (range.upperBound - range.lowerBound) / 100)); return .handled }
            .onKeyPress(.rightArrow) { guard enabled else { return .ignored }; set(value + (step ?? (range.upperBound - range.lowerBound) / 100)); return .handled }
            .accessibilityRepresentation {
                Group {
                    if let step, step > 0 { Slider(value: accessibleValue, in: range, step: step) }
                    else { Slider(value: accessibleValue, in: range) }
                }.accessibilityLabel(label)
            }
    }
}
