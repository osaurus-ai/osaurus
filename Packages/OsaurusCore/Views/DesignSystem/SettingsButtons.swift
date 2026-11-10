//
//  SettingsButtons.swift
//  osaurus
//
//  The one button vocabulary for Settings, sheets, and editors:
//
//    - `SettingsButtonStyle` / `.settings(_:size:isLoading:)` — four roles
//      (primary, secondary, tertiary, destructive) × two sizes. Every state
//      (default / hover / pressed / disabled) reads `theme.action` roles and
//      keyboard focus draws the shared focus ring.
//    - `SettingsButton` — title + optional SF Symbol on that style.
//    - `SettingsIconButton` — square icon-only button (refresh, close).
//    - `SettingsOverflowMenu` — icon-only menu (⋯ by default).
//    - `SettingsMenuButton` — titled menu on a button role (Import ▾).
//

import SwiftUI

// MARK: - Label Collapse

private struct SettingsCollapsesButtonLabelsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by `SettingsPageHeader` when its actions don't fit beside the
    /// title. Non-primary buttons and menus that have an icon then draw as
    /// icon buttons with the title as their tooltip, so the header keeps one
    /// line.
    var settingsCollapsesButtonLabels: Bool {
        get { self[SettingsCollapsesButtonLabelsKey.self] }
        set { self[SettingsCollapsesButtonLabelsKey.self] = newValue }
    }
}

// MARK: - Role & Size

/// The four action roles from the semantic token catalog. Every state reads
/// `theme.action.<role>.<state>`; nothing here mixes its own alpha.
enum SettingsButtonRole {
    /// Filled commit action. One per surface.
    case primary
    case brand
    /// Neutral filled + `action.border`. Everything that isn't the commit action.
    case secondary
    /// No chrome at rest; `surface.hover` wash on hover. Inline links, toolbar
    /// text actions.
    case tertiary
    /// Filled danger recipe. Remove / Revoke / Delete.
    case destructive

    var assignmentName: String { self == .brand ? "brand" : kind.rawValue }

    var kind: ThemeActionKind {
        switch self {
        case .primary, .brand: return .primary
        case .secondary: return .secondary
        case .tertiary: return .tertiary
        case .destructive: return .destructive
        }
    }
}

enum SettingsButtonSize: Hashable {
    /// Figma library sizes; legacy regular/compact calls retain saved geometry.
    case standard, small, extraSmall, extraExtraSmall
    var libraryName: String? {
        switch self {
        case .standard: return "default"
        case .small: return "small"
        case .extraSmall: return "extraSmall"
        case .extraExtraSmall: return "extraExtraSmall"
        case .regular, .compact: return nil
        }
    }
    func assignment(_ field: String) -> String {
        if let libraryName { return "component.button.size.\(libraryName).\(field)" }
        let legacy = self == .regular
            ? ["label":"label", "paddingX":"paddingX", "paddingY":"paddingY", "height":"minimumHeight"]
            : ["label":"compactLabel", "paddingX":"compactPaddingX", "paddingY":"compactPaddingY", "height":"compactHeight"]
        return "component.button." + (legacy[field] ?? field)
    }

    /// Page headers, sheet footers, empty states.
    case regular
    /// Inside rows, section accessories, and cards.
    case compact

    /// `type.label` for regular buttons, a medium-weight `type.caption` for compact.
    var font: SettingsFont {
        switch self {
        case .regular, .standard, .small: return SettingsFont.rowTitle
        case .compact, .extraSmall, .extraExtraSmall: return SettingsFont.compactLabel
        }
    }

    func horizontalPadding(_ theme: any ThemeProtocol) -> CGFloat {
        switch self {
        case .standard, .small: return theme.space.s8
        case .extraSmall: return theme.space.s6
        case .extraExtraSmall: return theme.space.s4
        case .regular: return theme.settingsButtonInsetRegular
        case .compact: return theme.settingsButtonInsetCompact
        }
    }

    /// `size.control.defaultHeight` / `size.control.compactHeight`.
    func minHeight(_ theme: any ThemeProtocol) -> CGFloat {
        switch self {
        case .regular, .standard: return theme.controlSize.defaultHeight
        case .compact, .small: return theme.controlSize.compactHeight
        case .extraSmall: return theme.space.s24
        case .extraExtraSmall: return theme.space.s16
        }
    }

    /// Square icon buttons are as tall as the matching text button.
    func iconSide(_ theme: any ThemeProtocol) -> CGFloat {
        minHeight(theme)
    }
}

// MARK: - Style

struct SettingsButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var role: SettingsButtonRole
    var size: SettingsButtonSize
    var isLoading: Bool

    init(_ role: SettingsButtonRole = .secondary, isLoading: Bool = false, size: SettingsButtonSize = .regular) {
        self.role = role
        self.size = size
        self.isLoading = isLoading
    }

    func makeBody(configuration: Configuration) -> some View {
        SettingsButtonBody(
            role: role,
            size: size,
            isLoading: isLoading,
            isPressed: configuration.isPressed,
            isEnabled: isEnabled,
            label: configuration.label
        )
    }
}

extension ButtonStyle where Self == SettingsButtonStyle {
    static func settings(
        _ role: SettingsButtonRole = .secondary,
        isLoading: Bool = false,
        size: SettingsButtonSize = .regular
    ) -> SettingsButtonStyle {
        SettingsButtonStyle(role, isLoading: isLoading, size: size)
    }
}

/// Resolves the `ThemeActionState` for a role given interaction flags.
/// Disabled wins, then pressed, then hover.
func settingsActionState(
    _ theme: any ThemeProtocol,
    role: SettingsButtonRole,
    isEnabled: Bool,
    isPressed: Bool,
    isHovering: Bool
) -> ThemeActionState<Color> {
    let variant = theme.action[role.kind]
    if !isEnabled { return variant.disabled }
    if isPressed { return variant.pressed }
    if isHovering { return variant.hover }
    return variant.default
}

private struct SettingsButtonBody<Label: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.isFocused) private var isFocused
    @Environment(\.assignedButtonHasKeyboardFocus) private var assignedKeyboardFocus
    @Environment(\.assignedMenuButtonInteraction) private var menuInteraction

    let role: SettingsButtonRole
    let size: SettingsButtonSize
    let isLoading: Bool
    let isPressed: Bool
    let isEnabled: Bool
    let label: Label

    @State private var isHovering = false

    private var effectivePressed: Bool { menuInteraction?.pressed ?? isPressed }
    private var effectiveHover: Bool { menuInteraction?.hovered ?? isHovering }
    private var state: ThemeActionState<Color> {
        let original = settingsActionState(theme, role: role, isEnabled: isEnabled, isPressed: effectivePressed, isHovering: effectiveHover)
        let interaction = !isEnabled ? "disabled" : effectivePressed ? "pressed" : effectiveHover ? "hover" : "default"
        let prefix = "component.button.\(role.assignmentName).\(interaction)."
        return ThemeActionState(
            background: theme.assignedColor(prefix + "background", fallback: original.background),
            foreground: theme.assignedColor(prefix + "foreground", fallback: original.foreground))
    }

    private var interaction: String { !isEnabled ? "disabled" : effectivePressed ? "pressed" : effectiveHover ? "hover" : "default" }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.assignedMetric(size.assignment("radius"), fallback: theme.radius.medium), style: .continuous)
        HStack(spacing: theme.assignedMetric(size.assignment("gap"), fallback: theme.space.s6)) {
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .tint(state.foreground)
            }
            label
        }
        .assignedTypography(size.assignment("label"), fallback: size.font)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .foregroundColor(state.foreground)
        .frame(minWidth: size.libraryName != nil ? theme.assignedMetric(size.assignment("minimumLabelWidth"), fallback: theme.space.s40) : nil)
        .padding(.horizontal, theme.assignedMetric(size.assignment("paddingX"), fallback: role == .tertiary ? theme.space.s6 : size.horizontalPadding(theme)))
        .padding(.vertical, theme.assignedMetric(size.assignment("paddingY"), fallback: size.libraryName != nil ? 0 : theme.space.s2))
        .frame(minHeight: theme.assignedMetric(size.assignment("height"), fallback: size.minHeight(theme)))
        .background(shape.fill(state.background))
        #if OSAURUS_DESIGN_SYSTEM
        .assignedDesignEffect("component.button.\(role.assignmentName).\(interaction).effect", theme: theme, radius: theme.assignedMetric(size.assignment("radius"), fallback: theme.radius.medium))
        #endif
        .overlay(shape.strokeBorder(theme.assignedColor("component.button.\(role.assignmentName).\(interaction).border", fallback: theme.action.border), lineWidth: theme.assignedMetric(size.assignment("borderWidth"), fallback: size.libraryName != nil ? 0 : theme.stroke.default)))
        .assignedFocusRing((assignedKeyboardFocus ?? isFocused) && isEnabled, radius: theme.assignedMetric(size.assignment("radius"), fallback: theme.radius.medium), buttonKind: role.kind)
        .contentShape(shape)
        .animation(theme.motion.quick, value: isHovering)
        .animation(theme.motion.quick, value: isPressed)
        .onHover { hovering in
            guard isEnabled else { return }
            isHovering = hovering
        }
    }
}

struct AssignedMenuButtonInteraction: Sendable, Equatable {
    let hovered: Bool
    let pressed: Bool
    let focused: Bool
}
private struct AssignedMenuButtonInteractionKey: EnvironmentKey {
    static let defaultValue: AssignedMenuButtonInteraction? = nil
}
extension EnvironmentValues {
    var assignedMenuButtonInteraction: AssignedMenuButtonInteraction? {
        get { self[AssignedMenuButtonInteractionKey.self] }
        set { self[AssignedMenuButtonInteractionKey.self] = newValue }
    }
}

private struct AssignedButtonFocusKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private extension EnvironmentValues {
    var assignedButtonHasKeyboardFocus: Bool? {
        get { self[AssignedButtonFocusKey.self] }
        set { self[AssignedButtonFocusKey.self] = newValue }
    }
}

private struct AssignedButtonFocus: ViewModifier {
    @FocusState private var focused: Bool
    var forceKeyboardFocus: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if forceKeyboardFocus {
            content.focusable().focused($focused)
                .environment(\.assignedButtonHasKeyboardFocus, focused)
                .focusEffectDisabled()
        } else {
            content.focused($focused)
                .environment(\.assignedButtonHasKeyboardFocus, focused)
                .focusEffectDisabled()
        }
    }
}

extension View {
    /// Bind focus on the native control, then pass it into its shared style.
    /// Normal app builds retain the original settings button behavior.
    @ViewBuilder func assignedSettingsButtonStyle(
        _ role: SettingsButtonRole = .secondary,
        isLoading: Bool = false,
        size: SettingsButtonSize = .regular,
        forceKeyboardFocus: Bool = false
    ) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        self.buttonStyle(.settings(role, isLoading: isLoading, size: size))
            .modifier(AssignedButtonFocus(forceKeyboardFocus: forceKeyboardFocus))
        #else
        if forceKeyboardFocus {
            self.buttonStyle(.settings(role, isLoading: isLoading, size: size)).focusable()
        } else {
            self.buttonStyle(.settings(role, isLoading: isLoading, size: size))
        }
        #endif
    }

    @ViewBuilder func assignedSettingsIconButtonStyle(
        size: SettingsButtonSize = .regular,
        isActive: Bool = false,
        isDestructive: Bool = false,
        role: SettingsButtonRole? = nil
    ) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        self.buttonStyle(SettingsIconButtonStyle(size: size, isActive: isActive, isDestructive: isDestructive, role: role))
            .modifier(AssignedButtonFocus(forceKeyboardFocus: false))
        #else
        self.buttonStyle(SettingsIconButtonStyle(size: size, isActive: isActive, isDestructive: isDestructive, role: role))
        #endif
    }
}

// MARK: - Focus Ring

/// Where the focus ring sits around a control with corner radius
/// `controlRadius`: its inner edge `focus.offset` outside the control, its
/// outer corner concentric with the control's.
struct SettingsFocusRingGeometry: Equatable {
    let outset: CGFloat
    let cornerRadius: CGFloat
    let lineWidth: CGFloat

    init(theme: any ThemeProtocol, controlRadius: CGFloat) {
        lineWidth = theme.stroke.focus
        outset = theme.focusOffset + lineWidth
        cornerRadius = controlRadius + outset
    }
}

private struct SettingsFocusRingModifier: ViewModifier {
    @Environment(\.theme) private var theme
    let isVisible: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            if isVisible {
                let ring = SettingsFocusRingGeometry(theme: theme, controlRadius: radius)
                RoundedRectangle(cornerRadius: ring.cornerRadius, style: .continuous)
                    .strokeBorder(theme.border.focus, lineWidth: ring.lineWidth)
                    .padding(-ring.outset)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// The one keyboard focus ring: `border.focus` at `stroke.focus`, starting
    /// `focus.offset` outside the control's own shape. The control keeps its
    /// normal border underneath.
    func settingsFocusRing(_ isVisible: Bool, radius: CGFloat) -> some View {
        modifier(SettingsFocusRingModifier(isVisible: isVisible, radius: radius))
    }
}

// MARK: - Button

/// Title + optional SF Symbol on `SettingsButtonStyle`. `title` is a catalog
/// key; pass `verbatim: true` for already-localized text.
struct SettingsButton: View {
    @Environment(\.theme) private var theme
    @Environment(\.settingsCollapsesButtonLabels) private var collapsesLabel

    let role: SettingsButtonRole
    let title: String
    var icon: String?
    var size: SettingsButtonSize
    var isLoading: Bool
    var verbatim: Bool
    var help: String?
    let action: () -> Void

    init(
        _ role: SettingsButtonRole,
        _ title: String,
        icon: String? = nil,
        isLoading: Bool = false,
        size: SettingsButtonSize = .regular,
        verbatim: Bool = false,
        help: String? = nil,
        action: @escaping () -> Void
    ) {
        self.role = role
        self.title = title
        self.icon = icon
        self.size = size
        self.isLoading = isLoading
        self.verbatim = verbatim
        self.help = help
        self.action = action
    }

    var body: some View {
        if collapsesLabel, role != .primary, let icon {
            Button(action: action) {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: icon)
                }
            }
            .assignedSettingsIconButtonStyle(size: size, isDestructive: role == .destructive)
            .disabled(isLoading)
            .help(help.map { Text(LocalizedStringKey($0), bundle: .module) } ?? titleText)
            .accessibilityLabel(titleText)
        } else {
            labeled
        }
    }

    private var titleText: Text {
        verbatim ? Text(verbatim: title) : Text(LocalizedStringKey(title), bundle: .module)
    }

    private var labeled: some View {
        Button(action: action) {
            HStack(spacing: theme.assignedMetric(size.assignment("gap"), fallback: theme.space.s6)) {
                if let icon, !isLoading {
                    Image(systemName: icon)
                        .font(size == .regular ? SettingsFont.glyph : SettingsFont.glyphSmall)
                }
                titleText
            }
        }
        .assignedSettingsButtonStyle(role, isLoading: isLoading, size: size)
        .settingsHelp(help)
    }
}

// MARK: - Icon Button

/// Square icon-only chrome shared by `SettingsIconButton` and the icon menus,
/// bordered like a secondary button so the two sit together in a header.
struct SettingsIconButtonStyle: ButtonStyle {
    var size: SettingsButtonSize = .regular
    /// Accent state for toggles and filter triggers with a filter applied.
    var isActive: Bool = false
    /// Error-tinted glyph for Delete / Remove.
    var isDestructive: Bool = false
    var role: SettingsButtonRole? = nil

    func makeBody(configuration: Configuration) -> some View {
        SettingsIconButtonBody(
            size: size,
            isActive: isActive,
            isDestructive: isDestructive,
            role: role,
            isPressed: configuration.isPressed,
            label: configuration.label
        )
    }
}

private struct SettingsIconButtonBody<Label: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.assignedButtonHasKeyboardFocus) private var assignedKeyboardFocus
    @Environment(\.assignedMenuButtonInteraction) private var menuInteraction

    let size: SettingsButtonSize
    let isActive: Bool
    let isDestructive: Bool
    let role: SettingsButtonRole?
    let isPressed: Bool
    let label: Label

    @State private var isHovering = false

    private var effectivePressed: Bool { menuInteraction?.pressed ?? isPressed }
    private var effectiveHover: Bool { menuInteraction?.hovered ?? isHovering }
    private var interaction: String { !isEnabled ? "disabled" : effectivePressed ? "pressed" : effectiveHover ? "hover" : "default" }
    private var assignmentRole: SettingsButtonRole { role ?? (isDestructive ? .destructive : .secondary) }
    private var assignmentKind: ThemeActionKind { assignmentRole.kind }
    private var assignmentPrefix: String { "component.button.\(assignmentRole.assignmentName).\(interaction)." }

    /// Icon buttons are secondary chrome; the glyph tint comes from intent.
    private var state: ThemeActionState<Color> {
        settingsActionState(theme, role: .secondary, isEnabled: isEnabled, isPressed: effectivePressed, isHovering: effectiveHover)
    }

    private var glyphColor: Color {
        if !isEnabled { return theme.text.disabled }
        if isActive { return theme.text.primary }
        return isDestructive ? theme.danger.default : theme.text.secondary
    }

    private var fill: Color {
        if isActive && isEnabled { return theme.surface.selected }
        return state.background
    }

    var body: some View {
        let radius = size.libraryName != nil ? theme.assignedMetric(size.assignment("height"), fallback: size.iconSide(theme)) / 2 : theme.assignedMetric("component.button.radius", fallback: theme.radius.medium)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        label
            .assignedTypography(size.libraryName != nil ? size.assignment("label") : "component.button.legacyIconLabel", fallback: size == .regular ? SettingsFont.glyph : SettingsFont.glyphSmall)
            .foregroundColor(theme.assignedColor(assignmentPrefix + "foreground", fallback: glyphColor))
            .frame(width: theme.assignedMetric(size.assignment("height"), fallback: size.iconSide(theme)), height: theme.assignedMetric(size.assignment("height"), fallback: size.iconSide(theme)))
            .background(shape.fill(theme.assignedColor(assignmentPrefix + "background", fallback: fill)))
            .overlay(shape.strokeBorder(theme.assignedColor(assignmentPrefix + "border", fallback: theme.action.border), lineWidth: theme.assignedMetric(size.assignment("borderWidth"), fallback: size.libraryName != nil ? 0 : theme.stroke.default)))
            .assignedFocusRing((assignedKeyboardFocus ?? isFocused) && isEnabled, radius: radius, buttonKind: assignmentKind)
            .contentShape(shape)
            .animation(theme.motion.quick, value: isHovering)
            .animation(theme.motion.quick, value: isPressed)
            .onHover { hovering in
                guard isEnabled else { return }
                isHovering = hovering
            }
    }
}

/// Square icon-only button for compact header and row actions.
struct SettingsIconButton: View {
    @Environment(\.theme) private var theme
    let icon: String
    var isLoading: Bool
    var help: String?
    var size: SettingsButtonSize
    var isActive: Bool
    var isDestructive: Bool
    var role: SettingsButtonRole?
    /// Optical correction for lopsided symbols. SF Symbols center their
    /// bounding box, so a glyph whose ink is weighted to one side (the
    /// compose square, a pin's head) reads off-center beside balanced ones;
    /// the tilt and nudge move its visual mass back to the middle.
    var glyphTilt: Angle
    var glyphNudge: CGSize
    let action: () -> Void

    init(
        _ icon: String,
        isLoading: Bool = false,
        help: String? = nil,
        size: SettingsButtonSize = .regular,
        isActive: Bool = false,
        isDestructive: Bool = false,
        role: SettingsButtonRole? = nil,
        glyphTilt: Angle = .zero,
        glyphNudge: CGSize = .zero,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.isLoading = isLoading
        self.help = help
        self.size = size
        self.isActive = isActive
        self.isDestructive = isDestructive
        self.role = role
        self.glyphTilt = glyphTilt
        self.glyphNudge = glyphNudge
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            if isLoading {
                ProgressView().controlSize(.mini)
            } else if size == .extraExtraSmall {
                // The smallest shared icon button must leave room around its
                // glyph instead of drawing a caption-sized X edge to edge.
                let side = theme.assignedMetric(size.assignment("height"), fallback: size.iconSide(theme))
                let inset = theme.assignedMetric(size.assignment("paddingX"), fallback: size.horizontalPadding(theme))
                let glyphSide = max(1, side - 2 * inset)
                Image(systemName: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: glyphSide, height: glyphSide)
            } else {
                Image(systemName: icon)
                    .rotationEffect(glyphTilt)
                    .offset(glyphNudge)
            }
        }
        .assignedSettingsIconButtonStyle(size: size, isActive: isActive, isDestructive: isDestructive, role: role)
        .disabled(isLoading)
        .settingsHelp(help)
        .settingsAccessibilityLabel(help)
    }
}

// MARK: - Menus

// A `Menu` with a custom label under `.menuStyle(.borderlessButton)` loses
// the label's background on macOS. These use `.menuStyle(.button)`, which
// honours the kit's button styles.

/// An icon-only menu sized like `SettingsIconButton`: the ⋯ menu for
/// secondary actions by default, or `icon: "plus"` for an add menu.
struct SettingsOverflowMenu<Content: View>: View {
    let icon: String
    let help: String
    var size: SettingsButtonSize
    @ViewBuilder let content: () -> Content

    init(
        icon: String = "ellipsis",
        help: String,
        size: SettingsButtonSize = .regular,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.icon = icon
        self.help = help
        self.size = size
        self.content = content
    }

    var body: some View {
        SettingsActionMenu(accessibilityLabel: String(localized: .init(help), bundle: .module), content: content) {
            Image(systemName: icon)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text(LocalizedStringKey(help), bundle: .module))
        .accessibilityLabel(Text(LocalizedStringKey(help), bundle: .module))
        .assignedSettingsIconMenuStyle(size: size)
    }
}

/// A titled menu on `SettingsButtonStyle` with a trailing chevron: Import ▾,
/// Add Agent ▾. `title` is a catalog key; pass `verbatim: true` for
/// already-localized text.
struct SettingsMenuButton<Content: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.settingsCollapsesButtonLabels) private var collapsesLabel

    let role: SettingsButtonRole
    let title: String
    var icon: String?
    var size: SettingsButtonSize
    var verbatim: Bool
    @ViewBuilder let content: () -> Content

    init(
        _ role: SettingsButtonRole,
        _ title: String,
        icon: String? = nil,
        size: SettingsButtonSize = .regular,
        verbatim: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.role = role
        self.title = title
        self.icon = icon
        self.size = size
        self.verbatim = verbatim
        self.content = content
    }

    var body: some View {
        if collapsesLabel, role != .primary, let icon {
            SettingsActionMenu(accessibilityLabel: verbatim ? title : String(localized: .init(title), bundle: .module), content: content) {
                Image(systemName: icon)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(titleText)
            .accessibilityLabel(titleText)
            .assignedSettingsIconMenuStyle(size: size)
        } else {
            labeled
        }
    }

    private var titleText: Text {
        verbatim ? Text(verbatim: title) : Text(LocalizedStringKey(title), bundle: .module)
    }

    private var labeled: some View {
        SettingsActionMenu(accessibilityLabel: verbatim ? title : String(localized: .init(title), bundle: .module), content: content) {
            HStack(spacing: theme.assignedMetric(size.assignment("gap"), fallback: theme.space.s6)) {
                if let icon {
                    Image(systemName: icon)
                        .font(size == .regular ? SettingsFont.glyph : SettingsFont.glyphSmall)
                }
                titleText
                Image(systemName: "chevron.down")
                    .glyphSize(9, weight: .semibold)
            }
        }
        .menuStyle(.button)
        .assignedSettingsMenuStyle(role, size: size)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Help

extension View {
    /// Localized tooltip when `key` is non-nil; no-op otherwise.
    @ViewBuilder
    func settingsHelp(_ key: String?) -> some View {
        if let key, !key.isEmpty {
            help(Text(LocalizedStringKey(key), bundle: .module))
        } else {
            self
        }
    }

    /// Icon-only controls read their tooltip to VoiceOver; the SF Symbol
    /// name is not a label.
    @ViewBuilder
    func settingsAccessibilityLabel(_ key: String?) -> some View {
        if let key, !key.isEmpty {
            accessibilityLabel(Text(LocalizedStringKey(key), bundle: .module))
        } else {
            self
        }
    }
}

/// The original menu content is passed through in both builds. Only the
/// presentation changes in the isolated inspector build.
struct SettingsActionMenu<Content: View, Label: View>: View {
    let content: () -> Content
    let label: () -> Label
    let accessibilityLabel: String
    init(accessibilityLabel: String, @ViewBuilder content: @escaping () -> Content, @ViewBuilder label: @escaping () -> Label) {
        self.content = content; self.label = label; self.accessibilityLabel = accessibilityLabel
    }
    var body: some View {
        #if OSAURUS_DESIGN_SYSTEM
        AssignedActionMenu(accessibilityLabel: accessibilityLabel, content: content, label: label)
        #else
        Menu(content: content, label: label)
        #endif
    }
}

#if OSAURUS_DESIGN_SYSTEM
extension View {
    func assignedActionMenuVisualState(_ state: AssignedMenuButtonInteraction) -> some View {
        environment(\.assignedButtonHasKeyboardFocus, state.focused)
            .environment(\.assignedMenuButtonInteraction, state)
    }
}
#endif
private extension View {
    func assignedSettingsIconMenuStyle(size: SettingsButtonSize) -> some View {
        buttonStyle(SettingsIconButtonStyle(size: size))
    }
    func assignedSettingsMenuStyle(_ role: SettingsButtonRole, size: SettingsButtonSize) -> some View {
        buttonStyle(.settings(role, size: size))
    }
}
