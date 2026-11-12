import SwiftUI

/// Uses the existing tab drawing for the app's segmented picker options, with
/// its original selection binding and a native accessibility representation.
enum BaseSegmentedSize: String { case standard, compact }

struct AssignedBaseSegmentedPicker<Value: Hashable>: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    @Binding var selection: Value
    let options: [SettingsPickerRow<Value>.Option]
    var size: BaseSegmentedSize = .standard
    var minimumOptionWidth: CGFloat? = nil
    var busyValue: Value? = nil
    /// A count beside an option's label; zero shows none.
    var badges: [Value: Int] = [:]
    /// Options whose badge asks for attention rather than just counting.
    var attentionBadges: Set<Value> = []
    @FocusState private var focused: Bool
    private let prefix = "component.library.6."
    private func metric(_ property: String, _ fallback: CGFloat) -> CGFloat { theme.assignedMetric(prefix + property, fallback: fallback) }
    private func layoutKey(_ field: String) -> String { prefix + "elements.layout." + size.rawValue + "." + field }
    private func layout(_ field: String, _ inherited: CGFloat) -> CGFloat { theme.catalogLayoutMetric(layoutKey(field), inheriting: inherited) }
    private func move(_ delta: Int) {
        guard enabled, !options.isEmpty else { return }
        let index = options.firstIndex { $0.value == selection } ?? 0
        selection = options[min(options.count - 1, max(0, index + delta))].value
    }
    @ViewBuilder private func text(_ option: SettingsPickerRow<Value>.Option) -> some View {
        Group {
            if option.verbatim { Text(verbatim: option.label) }
            else { Text(LocalizedStringKey(option.label), bundle: .module) }
        }.assignedTypography(prefix + "text", fallback: SettingsFont.rowTitle)
    }
    var body: some View {
        HStack(spacing: layout("optionGap", theme.space.s4)) {
            ForEach(options) { option in
                Button { selection = option.value; focused = true } label: {
                    HStack(spacing: layout("activityGap", theme.space.s8)) {
                        text(option)
                        if busyValue == option.value {
                            SettingsSpinner(size: .mini)
                                .accessibilityLabel(Text("In progress", bundle: .module))
                        }
                        if let badge = badges[option.value], badge > 0 {
                            CountBadge(badge, prominence: attentionBadges.contains(option.value) ? .attention : .neutral)
                        }
                    }
                        .foregroundStyle(theme.assignedColor(prefix + (!enabled ? (option.value == selection ? "secondary" : "disabledForeground") : option.value == selection ? "foreground" : "secondary"), fallback: theme.text.primary))
                        .padding(.horizontal, layout("optionPaddingX", size == .compact ? theme.space.s8 : theme.space.s12))
                        .padding(.vertical, layout("optionPaddingY", size == .compact ? theme.space.s2 : theme.space.s4))
                        .frame(minWidth: minimumOptionWidth)
                        .modifier(BaseSegmentedSurface(selected: option.value == selection))
                }.buttonStyle(AssignedBasePlainButtonStyle()).focusable(false)
            }
        }.padding(layout("outerPadding", theme.space.s4))
            .catalogLayoutTarget(layoutKey("outerPadding"))
            .catalogLayoutTarget(layoutKey("optionPaddingX"))
            .catalogLayoutTarget(layoutKey("optionPaddingY"))
            .catalogLayoutTarget(layoutKey("optionGap"))
            .catalogLayoutTarget(layoutKey("activityGap"))
            .modifier(BaseSegmentedSurface(selected: nil))
            .focusable(enabled).focused($focused).focusEffectDisabled()
            .assignedBaseFocusRing(6, visible: focused && enabled, radius: theme.segmentedTrackRadius)
            .onKeyPress(.leftArrow) { guard enabled else { return .ignored }; move(-1); return .handled }
            .onKeyPress(.rightArrow) { guard enabled else { return .ignored }; move(1); return .handled }
            .accessibilityRepresentation {
                Picker("", selection: $selection) {
                    ForEach(options) { option in
                        Group {
                            let count = badges[option.value] ?? 0
                            let label = option.verbatim ? option.label : L(String.LocalizationValue(option.label))
                            Text(verbatim: count > 0 ? "\(label), \(count)" : label)
                        }.tag(option.value)
                    }
                }.pickerStyle(.segmented).labelsHidden()
            }
    }
}
/// Both sizes share one look: a borderless track with the selected option
/// inset as a filled segment. Only the size recipe differs.
private struct BaseSegmentedSurface: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    let selected: Bool?
    @ViewBuilder func body(content: Content) -> some View {
        let prefix = "component.library.6."
        let radius = selected == nil ? theme.segmentedTrackRadius : theme.segmentedSegmentRadius
        if selected == false {
            content.contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            // A disabled control still shows which option is chosen, dimmed.
            let property = selected == true ? "selected" : !enabled ? "disabledBackground" : "background"
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            content.background {
                shape.fill(theme.assignedColor(prefix + property,
                    fallback: selected == true ? theme.surface.selected : theme.surface.raised))
                    .opacity(selected == true && !enabled ? 0.6 : 1)
            }
            .overlay {
                if selected == true && !theme.isDark {
                    shape.strokeBorder(theme.segmentedSelectionBorder, lineWidth: theme.stroke.default)
                        .opacity(enabled ? 1 : 0.6)
                        .allowsHitTesting(false)
                }
            }
            .nativeCatalogTarget(([property] + (selected == true && enabled ? ["selectedBorder"] : [])).map {
                NativeCatalogAssignment.key(prefix + $0, theme: theme)
            },
                                 selected == nil ? "Segment track" : "Selected segment")
        }
    }
}
