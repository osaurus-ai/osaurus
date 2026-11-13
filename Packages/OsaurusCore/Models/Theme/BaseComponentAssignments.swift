import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Assignment chrome shared by the existing native app components. Its fallback
/// keeps ordinary app builds unchanged; no inspector specimen is embedded here.
private struct AssignedBaseChrome: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false
    let family: Int
    let fallback: SettingsChrome?
    let selected: Bool
    let invalid: Bool
    let element: String
    /// Chrome overrides live apart from the element's role mappings, which the
    /// scoped family theme reads; with none, the kit chrome paints.
    var key: String { "component.library.\(family).elements.chrome.\(element)." }
    @ViewBuilder func body(content: Content) -> some View {
        let prefix = key
        let hasOverride = DesignThemeOverlay.shared.memoized(.init(property: prefix, family: family, flags: 0, kind: 9)) { snapshot in
            snapshot?.document.mappings.keys.contains { $0.hasPrefix(prefix) } == true
        }
        if !hasOverride {
            content.settingsChrome(fallback).nativeCatalogTarget(["background", "border", "borderWidth", "radius"].map { key + $0 }, NativeCatalogAssignment.name(key))
        } else {
        let radius = theme.assignedMetric(key + "radius", fallback: theme.radius.medium)
        content.assignedInteractionBackground(key, state: !isEnabled ? "disabledBackground" : selected ? "selected" : hovered ? "hover" : "background", fallback: fallback == nil ? .clear : theme.surface.raised, in: RoundedRectangle(cornerRadius: radius, style: .continuous)).overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(theme.assignedColor(key + (invalid ? "error" : "border"), fallback: fallback == nil ? .clear : theme.border.default), lineWidth: theme.assignedMetric(key + "borderWidth", fallback: theme.stroke.default))
                .allowsHitTesting(false)
        }.onHover { hovered = $0 }
        .nativeCatalogTarget(["background", "disabledBackground", "selected", "hover", "error", "border", "borderWidth", "radius"].map { key + $0 }, NativeCatalogAssignment.name(key))
        }
    }
}
extension View {
    func assignedBaseChrome(_ family: Int, fallback: SettingsChrome? = .control, selected: Bool = false, invalid: Bool = false, element: String = "container") -> some View {
        modifier(AssignedBaseChrome(family: family, fallback: fallback, selected: selected, invalid: invalid, element: element))
    }
}

private struct AssignedBadgeSurface: ViewModifier {
    @Environment(\.theme) private var theme
    let fill: Color
    let stroke: Color
    @ViewBuilder func body(content: Content) -> some View {
        let pinned = DesignButtonBindings.value("component.library.10.elements.badge.radius", theme: theme)?.designNumber
        let shape = ThemePillShape(theme.radius.pill, pinned: pinned.map { CGFloat($0) })
        content.background(shape.fill(fill))
            .overlay(shape
                .strokeBorder(theme.assignedColor("component.library.10.elements.badge.border", fallback: stroke), lineWidth: theme.assignedMetric("component.library.10.elements.badge.borderWidth", fallback: theme.stroke.default)))
            .nativeCatalogTarget(["radius", "border", "borderWidth"].map { "component.library.10.elements.badge." + $0 }, "Badge shape")
    }
}
extension View {
    func assignedBadgeSurface(fill: Color, stroke: Color) -> some View { modifier(AssignedBadgeSurface(fill: fill, stroke: stroke)) }
}

private struct BaseDescriptionAssignmentKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct BaseAssignmentFamilyKey: EnvironmentKey { static let defaultValue = 14 }
private struct BaseAssignmentSelectedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var baseDescriptionAssignment: String? {
        get { self[BaseDescriptionAssignmentKey.self] }
        set { self[BaseDescriptionAssignmentKey.self] = newValue }
    }
    var baseAssignmentSelected: Bool {
        get { self[BaseAssignmentSelectedKey.self] }
        set { self[BaseAssignmentSelectedKey.self] = newValue }
    }
    var baseAssignmentFamily: Int {
        get { self[BaseAssignmentFamilyKey.self] }
        set { self[BaseAssignmentFamilyKey.self] = newValue }
    }
}
/// Tracks input for custom focus rings without changing the first responder.
/// AppKit retains the local monitor for the lifetime of the app.
@MainActor @Observable
final class DesignKeyboardFocus {
    static let shared = DesignKeyboardFocus()
    private weak var navigationWindow: NSWindow?

    var isVisible: Bool {
        navigationWindow != nil && navigationWindow === NSApp.keyWindow
    }

    private init() {
        _ = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.update(for: event)
            }
            return event
        }
    }

    private func update(for event: NSEvent) {
        guard event.type == .keyDown else {
            if navigationWindow != nil { navigationWindow = nil }
            return
        }
        let navigationKeys = [kVK_Tab, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                              kVK_Space, kVK_Return, kVK_ANSI_KeypadEnter]
        guard navigationKeys.contains(Int(event.keyCode)) else { return }
        let window = event.window ?? NSApp.keyWindow
        if navigationWindow !== window { navigationWindow = window }
    }
}

/// Reuses the catalog's existing switch/checkbox geometry in a ToggleStyle,
/// leaving the app's original bindings and enabled state in charge.
struct AssignedBaseToggleStyle: ToggleStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool
    let checkbox: Bool
    let showsLabel: Bool
    var mini = false
    private var family: Int { theme.inspectionProductFamily(for: "switchWidth", fallback: 4) }
    private var prefix: String { "component.library.\(family).elements.\(checkbox ? "checkbox" : "switch")." }
    private func n(_ property: String, _ fallback: CGFloat) -> CGFloat { theme.assignedMetric(prefix + property, fallback: fallback) }
    private func c(_ property: String, _ fallback: Color) -> Color { theme.assignedColor(prefix + property, fallback: fallback) }
    func makeBody(configuration: Configuration) -> some View {
        let scale: CGFloat = mini && !checkbox ? 0.625 : 1
        let radius = n("radius", checkbox ? 4 : 8) * scale
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: n("gap", 8)) {
                Group {
                    if checkbox {
                        RoundedRectangle(cornerRadius: radius)
                            .fill(c(!enabled ? "disabledBackground" : configuration.isOn ? "onBackground" : "offBackground", theme.surface.selected))
                            .frame(width: n("indicatorSize", 24), height: n("indicatorSize", 24))
                            .overlay {
                                if configuration.isOn {
                                    Image(systemName: "checkmark").foregroundStyle(c(enabled ? "onForeground" : "disabledForeground", theme.text.primary))
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(c("border", theme.border.default), lineWidth: n("borderWidth", 1)))
                    } else {
                        RoundedRectangle(cornerRadius: radius)
                            .fill(c(!enabled ? "disabledBackground" : configuration.isOn ? "onBackground" : "offBackground", theme.surface.selected))
                            .frame(width: max(n("switchWidth", 48), n("switchHeight", 24)) * scale, height: n("switchHeight", 24) * scale)
                            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                                Circle().fill(c(!enabled ? "disabledForeground" : configuration.isOn ? "onForeground" : "offForeground", c("onForeground", theme.text.primary)))
                                    .frame(width: n("thumbSize", 16) * scale, height: n("thumbSize", 16) * scale).padding(3 * scale)
                            }
                            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(c("border", theme.border.default), lineWidth: n("borderWidth", 1)))
                    }
                }
                .assignedBaseFocusRing(family, visible: focused && enabled, radius: radius)
                if showsLabel {
                    configuration.label.assignedTypography(prefix + "label", fallback: SettingsFont.rowTitle)
                        .foregroundStyle(c(enabled ? "foreground" : "disabledForeground", theme.text.primary))
                }
            }.contentShape(Rectangle())
        }.buttonStyle(AssignedBasePlainButtonStyle()).focusable(enabled).focused($focused).focusEffectDisabled()
            .onKeyPress(.space) {
                guard enabled else { return .ignored }
                configuration.isOn.toggle(); return .handled
            }
            .nativeCatalogTarget((["radius", "border", "borderWidth", "gap", "onBackground", "offBackground", "onForeground", "disabledBackground", "disabledForeground", "foreground"] + (checkbox ? ["indicatorSize"] : ["switchWidth", "switchHeight", "thumbSize", "offForeground"])).map { prefix + $0 }, checkbox ? "Checkbox" : "Switch")
            .accessibilityValue(configuration.isOn ? "On" : "Off")
            .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
    }
}
struct AssignedBasePlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

private struct AssignedBaseFocusRing: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.appearsActive) private var appearsActive
    let family: Int
    let visible: Bool
    let radius: CGFloat
    let keyboardOnly: Bool
    @ViewBuilder func body(content: Content) -> some View {
        let key = "component.library.\(family).accent"
        let role = DesignButtonBindings.role(key)
        let keyboardFocus = DesignKeyboardFocus.shared
        content.assignedFocusOutline(
            visible && (!keyboardOnly || (appearsActive && keyboardFocus.isVisible)),
            radius: radius,
            color: theme.assignedColor(role == "color.border.focus" ? "component.focus.color" : key, fallback: theme.border.focus),
            width: theme.assignedMetric("component.focus.width", fallback: theme.stroke.focus),
            offset: theme.assignedMetric("component.focus.offset", fallback: theme.focusOffset)
        )
    }
}
extension View {
    @ViewBuilder func assignedBasePlainButtonStyle() -> some View {
        buttonStyle(AssignedBasePlainButtonStyle())
    }
    func assignedBaseFocusRing(_ family: Int, visible: Bool, radius: CGFloat, keyboardOnly: Bool = true) -> some View {
        modifier(AssignedBaseFocusRing(family: family, visible: visible, radius: radius, keyboardOnly: keyboardOnly))
    }
}

struct AssignedDescendantFocusKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct AssignedBaseKeyboardButton: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool
    let family: Int
    let action: () -> Void
    var focusRequest = 0
    var onFocusRequestHandled: () -> Void = {}
    @State private var descendantFocused = false
    @ViewBuilder func body(content: Content) -> some View {
        content.onPreferenceChange(AssignedDescendantFocusKey.self) { descendantFocused = $0 }
            .focusable(enabled).focused($focused).focusEffectDisabled()
            .assignedBaseFocusRing(family, visible: focused && enabled && !descendantFocused,
                radius: theme.assignedMetric("component.library.\(family).radius", fallback: theme.radius.medium))
            .onKeyPress(.space) {
                guard enabled, !descendantFocused else { return .ignored }
                action()
                return .handled
            }
            .onAppear { restoreRequestedFocus() }
            .onChange(of: focusRequest) { _, _ in restoreRequestedFocus() }
            .preference(key: AssignedDescendantFocusKey.self, value: focused || descendantFocused)
            .onChange(of: enabled) { _, enabled in if !enabled { focused = false } }
    }
    private func restoreRequestedFocus() {
        guard enabled, focusRequest > 0 else { return }
        // A reused native table cell can retain a true binding after AppKit
        // drops its responder. Send a fresh request after the new view attaches.
        focused = false
        DispatchQueue.main.async {
            guard enabled else { return }
            focused = true
            onFocusRequestHandled()
        }
    }
}
extension View {
    func assignedBaseKeyboardButton(_ family: Int, focusRequest: Int = 0,
        onFocusRequestHandled: @escaping () -> Void = {}, action: @escaping () -> Void) -> some View {
        modifier(AssignedBaseKeyboardButton(family: family, action: action,
            focusRequest: focusRequest, onFocusRequestHandled: onFocusRequestHandled))
    }
}
