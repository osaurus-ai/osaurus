//
//  ThemeRoles.swift
//  osaurus
//
//  Semantic role groups shared by the persisted theme (`CustomTheme`, hex
//  strings) and the resolved runtime theme (`ThemeProtocol`, SwiftUI colors).
//
//  Each group is generic over its value type so the stored and resolved
//  shapes stay in lockstep: `ThemeSurfaceRoles<String>` is what gets written
//  to disk, `ThemeSurfaceRoles<Color>` is what views read. `map` converts.
//
//  Dotted handoff name → Swift spelling (see design/semantic-tokens.json):
//    color.surface.*            → colors.surface.*
//    color.text.*               → colors.text.*
//    color.chat.user.background → colors.chat.userBackground
//    color.action.<v>.<s>.*     → colors.action.<v>.<s>.*   (s: default/hover/pressed/disabled)
//    color.action.brand.<s>.*   → colors.action.brand?.<s>.* (library only)
//    color.action.border        → colors.action.border
//    color.border.*             → colors.border.*
//    color.selection.*          → colors.selection.*
//    color.cursor               → colors.cursor
//    color.status.<k>.*         → colors.status.<k>.*
//    color.danger.*             → colors.danger.*
//    color.scrim / color.shadow → colors.scrim / colors.shadow
//    material.window.*          → windowMaterial.*
//    type.<style>               → typography.styles.<style>
//    font.family.ui/code        → typography.families.ui/code
//    radius.*                   → radius.*          (radius.pill is a ThemeCornerShape)
//    stroke.hairline            → stroke.hairlineRule (formula, resolved per display)
//    stroke.*                   → stroke.*
//    focus.offset               → focusOffset
//    space.N                    → space.sN
//    size.control.*             → controlSize.compactHeight/defaultHeight
//    size.row.minimumHeight     → controlSize.rowMinimumHeight
//    size.chat.avatar           → controlSize.chatAvatar
//    motion.*                   → motion.*
//    elevation.*                → elevation.*
//    effect.<a>.<b>             → effects.<aB>      (effect.elevation.1 → effects.elevation1)
//

import Foundation

// MARK: - Surfaces

public struct ThemeSurfaceRoles<Value: Sendable>: Sendable {
    public var canvas: Value
    public var subtle: Value
    public var raised: Value
    public var overlay: Value
    public var sidebar: Value
    public var code: Value
    public var hover: Value
    public var pressed: Value
    public var selected: Value
    public var disabled: Value
    /// Library extensions (`color.surface.inverse`, `color.surface.none`);
    /// nil on the engineering seeds, set by the bundled design library.
    public var inverse: Value?
    public var none: Value?

    public init(
        canvas: Value, subtle: Value, raised: Value, overlay: Value, sidebar: Value,
        code: Value, hover: Value, pressed: Value, selected: Value, disabled: Value,
        inverse: Value? = nil, none: Value? = nil
    ) {
        self.canvas = canvas
        self.subtle = subtle
        self.raised = raised
        self.overlay = overlay
        self.sidebar = sidebar
        self.code = code
        self.hover = hover
        self.pressed = pressed
        self.selected = selected
        self.disabled = disabled
        self.inverse = inverse
        self.none = none
    }

    public func map<T: Sendable>(_ transform: (Value) throws -> T) rethrows -> ThemeSurfaceRoles<T> {
        ThemeSurfaceRoles<T>(
            canvas: try transform(canvas), subtle: try transform(subtle), raised: try transform(raised),
            overlay: try transform(overlay), sidebar: try transform(sidebar), code: try transform(code),
            hover: try transform(hover), pressed: try transform(pressed), selected: try transform(selected),
            disabled: try transform(disabled), inverse: try inverse.map(transform), none: try none.map(transform)
        )
    }
}

extension ThemeSurfaceRoles: Equatable where Value: Equatable {}
extension ThemeSurfaceRoles: Hashable where Value: Hashable {}
extension ThemeSurfaceRoles: Codable where Value: Codable {}

// MARK: - Text

public struct ThemeTextRoles<Value: Sendable>: Sendable {
    public var primary: Value
    public var secondary: Value
    public var tertiary: Value
    public var placeholder: Value
    public var disabled: Value
    public var inverse: Value
    public var onDanger: Value
    public var link: Value
    public var linkHover: Value

    public init(
        primary: Value, secondary: Value, tertiary: Value, placeholder: Value, disabled: Value,
        inverse: Value, onDanger: Value, link: Value, linkHover: Value
    ) {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.placeholder = placeholder
        self.disabled = disabled
        self.inverse = inverse
        self.onDanger = onDanger
        self.link = link
        self.linkHover = linkHover
    }

    public func map<T: Sendable>(_ transform: (Value) throws -> T) rethrows -> ThemeTextRoles<T> {
        ThemeTextRoles<T>(
            primary: try transform(primary), secondary: try transform(secondary), tertiary: try transform(tertiary),
            placeholder: try transform(placeholder), disabled: try transform(disabled), inverse: try transform(inverse),
            onDanger: try transform(onDanger), link: try transform(link), linkHover: try transform(linkHover)
        )
    }
}

extension ThemeTextRoles: Equatable where Value: Equatable {}
extension ThemeTextRoles: Hashable where Value: Hashable {}
extension ThemeTextRoles: Codable where Value: Codable {}

// MARK: - Chat message surfaces

public struct ThemeChatRoles<Value: Sendable>: Sendable {
    public var userBackground: Value
    public var assistantBackground: Value

    public init(userBackground: Value, assistantBackground: Value) {
        self.userBackground = userBackground
        self.assistantBackground = assistantBackground
    }

    public func map<T: Sendable>(_ transform: (Value) throws -> T) rethrows -> ThemeChatRoles<T> {
        ThemeChatRoles<T>(
            userBackground: try transform(userBackground),
            assistantBackground: try transform(assistantBackground)
        )
    }
}

extension ThemeChatRoles: Equatable where Value: Equatable {}
extension ThemeChatRoles: Hashable where Value: Hashable {}
extension ThemeChatRoles: Codable where Value: Codable {}

// MARK: - Actions

/// Background + foreground pair for one interaction state of an action variant.
public struct ThemeActionState<Value: Sendable>: Sendable {
    public var background: Value
    public var foreground: Value
    /// Per-state border (`color.action.<v>.<s>.border`) where the library
    /// defines one; otherwise the variant uses the shared `action.border`.
    public var border: Value?

    public init(background: Value, foreground: Value, border: Value? = nil) {
        self.background = background
        self.foreground = foreground
        self.border = border
    }

    public func map<T: Sendable>(_ transform: (Value) throws -> T) rethrows -> ThemeActionState<T> {
        ThemeActionState<T>(
            background: try transform(background), foreground: try transform(foreground),
            border: try border.map(transform)
        )
    }
}

extension ThemeActionState: Equatable where Value: Equatable {}
extension ThemeActionState: Hashable where Value: Hashable {}
extension ThemeActionState: Codable where Value: Codable {}

/// Interaction state of an action; `focus` is independent and drawn with the
/// focus ring, so it is not a member here.
public enum ThemeActionInteraction: String, Codable, Sendable, CaseIterable {
    case `default`
    case hover
    case pressed
    case disabled
}

/// One action variant (primary / secondary / tertiary / destructive).
public struct ThemeActionVariant<Value: Sendable>: Sendable {
    public var `default`: ThemeActionState<Value>
    public var hover: ThemeActionState<Value>
    public var pressed: ThemeActionState<Value>
    public var disabled: ThemeActionState<Value>

    public init(
        default: ThemeActionState<Value>, hover: ThemeActionState<Value>,
        pressed: ThemeActionState<Value>, disabled: ThemeActionState<Value>
    ) {
        self.default = `default`
        self.hover = hover
        self.pressed = pressed
        self.disabled = disabled
    }

    public subscript(interaction: ThemeActionInteraction) -> ThemeActionState<Value> {
        get {
            switch interaction {
            case .default: return `default`
            case .hover: return hover
            case .pressed: return pressed
            case .disabled: return disabled
            }
        }
        set {
            switch interaction {
            case .default: `default` = newValue
            case .hover: hover = newValue
            case .pressed: pressed = newValue
            case .disabled: disabled = newValue
            }
        }
    }

    public func map<T: Sendable>(_ transform: (Value) throws -> T) rethrows -> ThemeActionVariant<T> {
        ThemeActionVariant<T>(
            default: try `default`.map(transform), hover: try hover.map(transform),
            pressed: try pressed.map(transform), disabled: try disabled.map(transform)
        )
    }
}

extension ThemeActionVariant: Equatable where Value: Equatable {}
extension ThemeActionVariant: Hashable where Value: Hashable {}
extension ThemeActionVariant: Codable where Value: Codable {}

public enum ThemeActionKind: String, Codable, Sendable, CaseIterable {
    case primary
    case secondary
    case tertiary
    case destructive
}

public struct ThemeActionRoles<Value: Sendable>: Sendable {
    public var primary: ThemeActionVariant<Value>
    public var secondary: ThemeActionVariant<Value>
    public var tertiary: ThemeActionVariant<Value>
    public var destructive: ThemeActionVariant<Value>
    /// Border shared by every filled or text action. Transparent by spec; a
    /// separate focus ring handles keyboard focus.
    public var border: Value
    /// The library's brand action (`color.action.brand.*`); nil on the seeds.
    /// Not a `ThemeActionKind`: only components assigned to it draw it.
    public var brand: ThemeActionVariant<Value>?

    public init(
        primary: ThemeActionVariant<Value>, secondary: ThemeActionVariant<Value>,
        tertiary: ThemeActionVariant<Value>, destructive: ThemeActionVariant<Value>, border: Value,
        brand: ThemeActionVariant<Value>? = nil
    ) {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.destructive = destructive
        self.border = border
        self.brand = brand
    }

    /// The state's own border when the library defines one, else the shared border.
    public func border(_ kind: ThemeActionKind, _ interaction: ThemeActionInteraction) -> Value {
        self[kind][interaction].border ?? border
    }

    public subscript(kind: ThemeActionKind) -> ThemeActionVariant<Value> {
        get {
            switch kind {
            case .primary: return primary
            case .secondary: return secondary
            case .tertiary: return tertiary
            case .destructive: return destructive
            }
        }
        set {
            switch kind {
            case .primary: primary = newValue
            case .secondary: secondary = newValue
            case .tertiary: tertiary = newValue
            case .destructive: destructive = newValue
            }
        }
    }

    public func map<T: Sendable>(_ transform: (Value) throws -> T) rethrows -> ThemeActionRoles<T> {
        ThemeActionRoles<T>(
            primary: try primary.map(transform), secondary: try secondary.map(transform),
            tertiary: try tertiary.map(transform), destructive: try destructive.map(transform),
            border: try transform(border), brand: try brand.map { try $0.map(transform) }
        )
    }
}

extension ThemeActionRoles: Equatable where Value: Equatable {}
extension ThemeActionRoles: Hashable where Value: Hashable {}
extension ThemeActionRoles: Codable where Value: Codable {}

// MARK: - Borders

public struct ThemeBorderRoles<Value: Sendable>: Sendable {
    public var subtle: Value
    public var `default`: Value
    public var strong: Value
    public var focus: Value
    public var error: Value
    /// `color.border.none`, set by the bundled design library.
    public var none: Value?

    public init(subtle: Value, default: Value, strong: Value, focus: Value, error: Value, none: Value? = nil) {
        self.subtle = subtle
        self.default = `default`
        self.strong = strong
        self.focus = focus
        self.error = error
        self.none = none
    }

    public func map<T: Sendable>(_ transform: (Value) throws -> T) rethrows -> ThemeBorderRoles<T> {
        ThemeBorderRoles<T>(
            subtle: try transform(subtle), default: try transform(`default`), strong: try transform(strong),
            focus: try transform(focus), error: try transform(error), none: try none.map(transform)
        )
    }
}

extension ThemeBorderRoles: Equatable where Value: Equatable {}
extension ThemeBorderRoles: Hashable where Value: Hashable {}
extension ThemeBorderRoles: Codable where Value: Codable {}

// MARK: - Selection

public struct ThemeSelectionRoles<Value: Sendable>: Sendable {
    public var background: Value
    public var foreground: Value

    public init(background: Value, foreground: Value) {
        self.background = background
        self.foreground = foreground
    }

    public func map<T: Sendable>(_ transform: (Value) throws -> T) rethrows -> ThemeSelectionRoles<T> {
        ThemeSelectionRoles<T>(background: try transform(background), foreground: try transform(foreground))
    }
}

extension ThemeSelectionRoles: Equatable where Value: Equatable {}
extension ThemeSelectionRoles: Hashable where Value: Hashable {}
extension ThemeSelectionRoles: Codable where Value: Codable {}

// MARK: - Status

public struct ThemeStatusSet<Value: Sendable>: Sendable {
    public var foreground: Value
    public var background: Value
    public var border: Value
    /// The tone drawn straight on the canvas or a card (glyphs, text,
    /// progress). `foreground` is for text on the status fill, which can be a
    /// pale tint that vanishes on a plain surface.
    public var ink: Value?

    public init(foreground: Value, background: Value, border: Value, ink: Value? = nil) {
        self.foreground = foreground
        self.background = background
        self.border = border
        self.ink = ink
    }

    public func map<T: Sendable>(_ transform: (Value) throws -> T) rethrows -> ThemeStatusSet<T> {
        ThemeStatusSet<T>(
            foreground: try transform(foreground), background: try transform(background),
            border: try transform(border), ink: try ink.map(transform)
        )
    }
}

extension ThemeStatusSet: Equatable where Value: Equatable {}
extension ThemeStatusSet: Hashable where Value: Hashable {}
extension ThemeStatusSet: Codable where Value: Codable {}

public enum ThemeStatusKind: String, Codable, Sendable, CaseIterable {
    case success
    case warning
    case urgentWarning
    case error
    case info
}

public struct ThemeStatusRoles<Value: Sendable>: Sendable {
    public var success: ThemeStatusSet<Value>
    public var warning: ThemeStatusSet<Value>
    public var urgentWarning: ThemeStatusSet<Value>?
    public var error: ThemeStatusSet<Value>
    public var info: ThemeStatusSet<Value>

    public init(
        success: ThemeStatusSet<Value>, warning: ThemeStatusSet<Value>,
        error: ThemeStatusSet<Value>, info: ThemeStatusSet<Value>,
        urgentWarning: ThemeStatusSet<Value>? = nil
    ) {
        self.success = success
        self.warning = warning
        self.urgentWarning = urgentWarning
        self.error = error
        self.info = info
    }

    public subscript(kind: ThemeStatusKind) -> ThemeStatusSet<Value> {
        get {
            switch kind {
            case .success: return success
            case .warning: return warning
            case .urgentWarning: return urgentWarning ?? warning
            case .error: return error
            case .info: return info
            }
        }
        set {
            switch kind {
            case .success: success = newValue
            case .warning: warning = newValue
            case .urgentWarning: urgentWarning = newValue
            case .error: error = newValue
            case .info: info = newValue
            }
        }
    }

    public func map<T: Sendable>(_ transform: (Value) throws -> T) rethrows -> ThemeStatusRoles<T> {
        ThemeStatusRoles<T>(
            success: try success.map(transform), warning: try warning.map(transform),
            error: try error.map(transform), info: try info.map(transform),
            urgentWarning: try urgentWarning?.map(transform)
        )
    }
}

extension ThemeStatusRoles: Equatable where Value: Equatable {}
extension ThemeStatusRoles: Hashable where Value: Hashable {}
extension ThemeStatusRoles: Codable where Value: Codable {}

// MARK: - Categorical data series

/// One slot of the categorical series: `ink` for glyphs, text, dots and chart
/// strokes, `wash` for the tinted tile or chip behind that ink.
public struct ThemeDataSwatch<Value: Sendable>: Sendable {
    public var ink: Value
    public var wash: Value

    public init(ink: Value, wash: Value) {
        self.ink = ink
        self.wash = wash
    }

    public func map<T: Sendable>(_ transform: (Value) throws -> T) rethrows -> ThemeDataSwatch<T> {
        ThemeDataSwatch<T>(ink: try transform(ink), wash: try transform(wash))
    }
}

extension ThemeDataSwatch: Equatable where Value: Equatable {}
extension ThemeDataSwatch: Hashable where Value: Hashable {}
extension ThemeDataSwatch: Codable where Value: Codable {}

/// Slot number (`"1"` … `"8"`, matching `color.data.N`) to swatch.
public typealias ThemeDataSeries<Value: Sendable> = [String: ThemeDataSwatch<Value>]

// MARK: - Danger compatibility roles

public struct ThemeDangerRoles<Value: Sendable>: Sendable {
    public var `default`: Value
    public var hover: Value
    public var pressed: Value

    public init(default: Value, hover: Value, pressed: Value) {
        self.default = `default`
        self.hover = hover
        self.pressed = pressed
    }

    public func map<T: Sendable>(_ transform: (Value) throws -> T) rethrows -> ThemeDangerRoles<T> {
        ThemeDangerRoles<T>(
            default: try transform(`default`), hover: try transform(hover), pressed: try transform(pressed))
    }
}

extension ThemeDangerRoles: Equatable where Value: Equatable {}
extension ThemeDangerRoles: Hashable where Value: Hashable {}
extension ThemeDangerRoles: Codable where Value: Codable {}

// MARK: - All color roles

public struct ThemeColorRoles<Value: Sendable>: Sendable {
    public var surface: ThemeSurfaceRoles<Value>
    public var text: ThemeTextRoles<Value>
    public var chat: ThemeChatRoles<Value>
    public var action: ThemeActionRoles<Value>
    public var border: ThemeBorderRoles<Value>
    public var selection: ThemeSelectionRoles<Value>
    public var cursor: Value
    public var status: ThemeStatusRoles<Value>
    public var danger: ThemeDangerRoles<Value>
    public var scrim: Value
    public var shadow: Value
    /// Categorical series for things identified by kind rather than role
    /// (chart series, event categories, name-hashed avatars).
    public var data: ThemeDataSeries<Value>?

    public init(
        surface: ThemeSurfaceRoles<Value>, text: ThemeTextRoles<Value>, chat: ThemeChatRoles<Value>,
        action: ThemeActionRoles<Value>, border: ThemeBorderRoles<Value>, selection: ThemeSelectionRoles<Value>,
        cursor: Value, status: ThemeStatusRoles<Value>, danger: ThemeDangerRoles<Value>, scrim: Value, shadow: Value,
        data: ThemeDataSeries<Value>? = nil
    ) {
        self.surface = surface
        self.text = text
        self.chat = chat
        self.action = action
        self.border = border
        self.selection = selection
        self.cursor = cursor
        self.status = status
        self.danger = danger
        self.scrim = scrim
        self.shadow = shadow
        self.data = data
    }

    public func map<T: Sendable>(_ transform: (Value) throws -> T) rethrows -> ThemeColorRoles<T> {
        ThemeColorRoles<T>(
            surface: try surface.map(transform), text: try text.map(transform), chat: try chat.map(transform),
            action: try action.map(transform), border: try border.map(transform),
            selection: try selection.map(transform), cursor: try transform(cursor),
            status: try status.map(transform), danger: try danger.map(transform),
            scrim: try transform(scrim), shadow: try transform(shadow),
            data: try data?.mapValues { try $0.map(transform) }
        )
    }
}

extension ThemeColorRoles: Equatable where Value: Equatable {}
extension ThemeColorRoles: Hashable where Value: Hashable {}
extension ThemeColorRoles: Codable where Value: Codable {}

// MARK: - Enumeration by handoff token name

extension ThemeColorRoles {
    /// Every color role paired with its handoff token name
    /// (`color.surface.canvas`, `color.action.primary.hover.background`, …).
    /// Order is stable and matches the handoff catalog grouping. Used by
    /// validation, the conformance test, and the theme editor. Optional
    /// library extensions are listed only when set.
    public var entries: [(name: String, value: Value)] {
        var out: [(String, Value)] = []
        func appendIfSet(_ name: String, _ value: Value?) {
            if let value { out.append((name, value)) }
        }
        out += [
            ("color.surface.canvas", surface.canvas), ("color.surface.subtle", surface.subtle),
            ("color.surface.raised", surface.raised), ("color.surface.overlay", surface.overlay),
            ("color.surface.sidebar", surface.sidebar), ("color.surface.code", surface.code),
            ("color.surface.hover", surface.hover), ("color.surface.pressed", surface.pressed),
            ("color.surface.selected", surface.selected), ("color.surface.disabled", surface.disabled),
        ]
        appendIfSet("color.surface.inverse", surface.inverse)
        appendIfSet("color.surface.none", surface.none)
        out += [
            ("color.text.primary", text.primary), ("color.text.secondary", text.secondary),
            ("color.text.tertiary", text.tertiary), ("color.text.placeholder", text.placeholder),
            ("color.text.disabled", text.disabled), ("color.text.inverse", text.inverse),
            ("color.text.onDanger", text.onDanger), ("color.text.link", text.link),
            ("color.text.linkHover", text.linkHover),
        ]
        out += [
            ("color.chat.user.background", chat.userBackground),
            ("color.chat.assistant.background", chat.assistantBackground),
        ]
        for kind in ThemeActionKind.allCases {
            let variant = action[kind]
            for interaction in ThemeActionInteraction.allCases {
                let state = variant[interaction]
                out.append(("color.action.\(kind.rawValue).\(interaction.rawValue).background", state.background))
                out.append(("color.action.\(kind.rawValue).\(interaction.rawValue).foreground", state.foreground))
                appendIfSet("color.action.\(kind.rawValue).\(interaction.rawValue).border", state.border)
            }
        }
        if let brand = action.brand {
            for interaction in ThemeActionInteraction.allCases {
                let state = brand[interaction]
                out.append(("color.action.brand.\(interaction.rawValue).background", state.background))
                out.append(("color.action.brand.\(interaction.rawValue).foreground", state.foreground))
                appendIfSet("color.action.brand.\(interaction.rawValue).border", state.border)
            }
        }
        out.append(("color.action.border", action.border))
        out += [
            ("color.border.subtle", border.subtle), ("color.border.default", border.default),
            ("color.border.strong", border.strong), ("color.border.focus", border.focus),
            ("color.border.error", border.error),
        ]
        appendIfSet("color.border.none", border.none)
        out += [
            ("color.selection.background", selection.background),
            ("color.selection.foreground", selection.foreground),
            ("color.cursor", cursor),
        ]
        for kind in ThemeStatusKind.allCases where kind != .urgentWarning || status.urgentWarning != nil {
            let set = status[kind]
            out.append(("color.status.\(kind.rawValue).foreground", set.foreground))
            out.append(("color.status.\(kind.rawValue).background", set.background))
            out.append(("color.status.\(kind.rawValue).border", set.border))
            appendIfSet("color.status.\(kind.rawValue).ink", set.ink)
        }
        out += [
            ("color.danger.default", danger.default), ("color.danger.hover", danger.hover),
            ("color.danger.pressed", danger.pressed),
            ("color.scrim", scrim), ("color.shadow", shadow),
        ]
        for slot in (data ?? [:]).keys.sorted(by: { Int($0) ?? 0 < Int($1) ?? 0 }) {
            out.append(("color.data.\(slot).ink", data![slot]!.ink))
            out.append(("color.data.\(slot).wash", data![slot]!.wash))
        }
        return out
    }
}

/// Persisted form: sRGB hex strings (`#RRGGBB`, or `#RRGGBBAA` for
/// intentional transparency).
public typealias ThemeSemanticColors = ThemeColorRoles<String>
