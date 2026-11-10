//
//  ThemeTokens.swift
//  osaurus
//
//  Non-color semantic tokens: typography recipes, geometry, motion,
//  elevation and the single base-window material. Values are native points
//  and seconds. See ThemeRoles.swift for the dotted-name mapping.
//

import AppKit
import Foundation
import SwiftUI

// MARK: - Typography

/// Which shared family a text style draws from.
public enum ThemeFontFamilyRole: String, Codable, Sendable, CaseIterable {
    case ui
    case code
}

/// Font family names. `system` / `systemMonospaced` select the platform
/// fonts; anything else is treated as a custom family name.
public struct ThemeFontFamilies: Codable, Equatable, Hashable, Sendable {
    public static let systemUI = "system"
    public static let systemMonospaced = "systemMonospaced"

    public var ui: String
    public var code: String

    public init(ui: String = ThemeFontFamilies.systemUI, code: String = ThemeFontFamilies.systemMonospaced) {
        self.ui = ui
        self.code = code
    }

    public static var `default`: ThemeFontFamilies { ThemeFontFamilies() }
}

/// A complete text recipe: family, size, numeric design weight, target
/// line height and tracking. Line height is a minimum, never a clipping box.
public struct ThemeTextStyle: Codable, Equatable, Hashable, Sendable {
    public var family: ThemeFontFamilyRole
    public var size: Double
    /// Numeric design weight (400 regular, 500 medium, 600 semibold, 700 bold).
    public var weight: Int
    public var lineHeight: Double
    public var tracking: Double

    public init(family: ThemeFontFamilyRole = .ui, size: Double, weight: Int, lineHeight: Double, tracking: Double = 0) {
        self.family = family
        self.size = size
        self.weight = weight
        self.lineHeight = lineHeight
        self.tracking = tracking
    }

    /// Maps the numeric design weight onto the nearest SwiftUI weight.
    public var fontWeight: Font.Weight {
        switch weight {
        case ..<150: return .ultraLight
        case 150..<250: return .thin
        case 250..<350: return .light
        case 350..<450: return .regular
        case 450..<550: return .medium
        case 550..<650: return .semibold
        case 650..<750: return .bold
        case 750..<850: return .heavy
        default: return .black
        }
    }

    public var nsFontWeight: NSFont.Weight {
        switch weight {
        case ..<150: return .ultraLight
        case 150..<250: return .thin
        case 250..<350: return .light
        case 350..<450: return .regular
        case 450..<550: return .medium
        case 550..<650: return .semibold
        case 650..<750: return .bold
        case 750..<850: return .heavy
        default: return .black
        }
    }
}

public enum ThemeTextStyleRole: String, Codable, Sendable, CaseIterable {
    case display
    case title
    case heading
    case body
    case bodySmall
    case label
    case caption
    /// Dense secondary copy: row descriptions, meta lines, small identifiers.
    case footnote
    /// The smallest chrome text: chips, badges, timestamps.
    case micro
    case code
    // Library styles (design-library.json), seeded with its Light values.
    /// Conversation prose in the thread.
    case chatBody
    case bodyEmphasis
    case subheading
    case labelEmphasis
}

public struct ThemeTextStyles: Codable, Equatable, Hashable, Sendable {
    public var display: ThemeTextStyle
    public var title: ThemeTextStyle
    public var heading: ThemeTextStyle
    public var body: ThemeTextStyle
    public var bodySmall: ThemeTextStyle
    public var label: ThemeTextStyle
    public var caption: ThemeTextStyle
    public var footnote: ThemeTextStyle
    public var micro: ThemeTextStyle
    public var code: ThemeTextStyle
    public var chatBody: ThemeTextStyle
    public var bodyEmphasis: ThemeTextStyle
    public var subheading: ThemeTextStyle
    public var labelEmphasis: ThemeTextStyle

    public init(
        display: ThemeTextStyle = ThemeTextStyle(size: 40, weight: 700, lineHeight: 48),
        title: ThemeTextStyle = ThemeTextStyle(size: 26, weight: 600, lineHeight: 32),
        heading: ThemeTextStyle = ThemeTextStyle(size: 18, weight: 600, lineHeight: 24),
        body: ThemeTextStyle = ThemeTextStyle(size: 15, weight: 400, lineHeight: 22),
        bodySmall: ThemeTextStyle = ThemeTextStyle(size: 14, weight: 400, lineHeight: 20),
        label: ThemeTextStyle = ThemeTextStyle(size: 13, weight: 500, lineHeight: 18),
        caption: ThemeTextStyle = ThemeTextStyle(size: 12, weight: 400, lineHeight: 16),
        footnote: ThemeTextStyle = ThemeTextStyle(size: 11, weight: 400, lineHeight: 14),
        micro: ThemeTextStyle = ThemeTextStyle(size: 10, weight: 400, lineHeight: 13),
        code: ThemeTextStyle = ThemeTextStyle(family: .code, size: 13, weight: 400, lineHeight: 20),
        chatBody: ThemeTextStyle = ThemeTextStyle(size: 14, weight: 400, lineHeight: 22),
        bodyEmphasis: ThemeTextStyle = ThemeTextStyle(size: 15, weight: 600, lineHeight: 22),
        subheading: ThemeTextStyle = ThemeTextStyle(size: 16, weight: 600, lineHeight: 22),
        labelEmphasis: ThemeTextStyle = ThemeTextStyle(size: 13, weight: 500, lineHeight: 22)
    ) {
        self.display = display
        self.title = title
        self.heading = heading
        self.body = body
        self.bodySmall = bodySmall
        self.label = label
        self.caption = caption
        self.footnote = footnote
        self.micro = micro
        self.code = code
        self.chatBody = chatBody
        self.bodyEmphasis = bodyEmphasis
        self.subheading = subheading
        self.labelEmphasis = labelEmphasis
    }

    private enum CodingKeys: String, CodingKey {
        case display, title, heading, body, bodySmall, label, caption, footnote, micro, code
        case chatBody, bodyEmphasis, subheading, labelEmphasis
    }

    /// Themes saved before `footnote` and `micro` existed derive them from
    /// their own caption, so a theme that scaled its type keeps its ladder.
    /// Themes saved before the library styles existed take the seed values.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        display = try c.decode(ThemeTextStyle.self, forKey: .display)
        title = try c.decode(ThemeTextStyle.self, forKey: .title)
        heading = try c.decode(ThemeTextStyle.self, forKey: .heading)
        body = try c.decode(ThemeTextStyle.self, forKey: .body)
        bodySmall = try c.decode(ThemeTextStyle.self, forKey: .bodySmall)
        label = try c.decode(ThemeTextStyle.self, forKey: .label)
        caption = try c.decode(ThemeTextStyle.self, forKey: .caption)
        code = try c.decode(ThemeTextStyle.self, forKey: .code)
        footnote =
            try c.decodeIfPresent(ThemeTextStyle.self, forKey: .footnote)
            ?? Self.derived(from: caption, like: Self.default.footnote, captionDefault: Self.default.caption)
        micro =
            try c.decodeIfPresent(ThemeTextStyle.self, forKey: .micro)
            ?? Self.derived(from: caption, like: Self.default.micro, captionDefault: Self.default.caption)
        let seed = Self.default
        chatBody = try c.decodeIfPresent(ThemeTextStyle.self, forKey: .chatBody) ?? seed.chatBody
        bodyEmphasis = try c.decodeIfPresent(ThemeTextStyle.self, forKey: .bodyEmphasis) ?? seed.bodyEmphasis
        subheading = try c.decodeIfPresent(ThemeTextStyle.self, forKey: .subheading) ?? seed.subheading
        labelEmphasis = try c.decodeIfPresent(ThemeTextStyle.self, forKey: .labelEmphasis) ?? seed.labelEmphasis
    }

    /// Keeps `template`'s offset from the default caption, applied to `caption`.
    static func derived(
        from caption: ThemeTextStyle, like template: ThemeTextStyle, captionDefault: ThemeTextStyle
    ) -> ThemeTextStyle {
        var style = template
        style.size = max(6, caption.size - (captionDefault.size - template.size))
        style.lineHeight = max(style.size, caption.lineHeight - (captionDefault.lineHeight - template.lineHeight))
        return style
    }

    public static var `default`: ThemeTextStyles { ThemeTextStyles() }

    public subscript(role: ThemeTextStyleRole) -> ThemeTextStyle {
        get {
            switch role {
            case .display: return display
            case .title: return title
            case .heading: return heading
            case .body: return body
            case .bodySmall: return bodySmall
            case .label: return label
            case .caption: return caption
            case .footnote: return footnote
            case .micro: return micro
            case .code: return code
            case .chatBody: return chatBody
            case .bodyEmphasis: return bodyEmphasis
            case .subheading: return subheading
            case .labelEmphasis: return labelEmphasis
            }
        }
        set {
            switch role {
            case .display: display = newValue
            case .title: title = newValue
            case .heading: heading = newValue
            case .body: body = newValue
            case .bodySmall: bodySmall = newValue
            case .label: label = newValue
            case .caption: caption = newValue
            case .footnote: footnote = newValue
            case .micro: micro = newValue
            case .code: code = newValue
            case .chatBody: chatBody = newValue
            case .bodyEmphasis: bodyEmphasis = newValue
            case .subheading: subheading = newValue
            case .labelEmphasis: labelEmphasis = newValue
            }
        }
    }
}

public struct ThemeTypography: Codable, Equatable, Hashable, Sendable {
    public var families: ThemeFontFamilies
    public var styles: ThemeTextStyles

    public init(families: ThemeFontFamilies = .default, styles: ThemeTextStyles = .default) {
        self.families = families
        self.styles = styles
    }

    public static var `default`: ThemeTypography { ThemeTypography() }
}

// MARK: - Geometry

/// Corner geometry for `radius.pill`: half the shorter side (`"capsule"`),
/// or a fixed radius if the library ever pins one.
public enum ThemeCornerShape: Codable, Equatable, Hashable, Sendable {
    case capsule
    case radius(Double)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(Double.self) {
            self = .radius(value)
            return
        }
        let name = try c.decode(String.self)
        guard name == "capsule" else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown corner shape \(name)")
        }
        self = .capsule
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .capsule: try c.encode("capsule")
        case .radius(let value): try c.encode(value)
        }
    }

    /// The corner radius for a shape of `height`.
    public func cornerRadius(forHeight height: CGFloat) -> CGFloat {
        switch self {
        case .capsule: return height / 2
        case .radius(let value): return CGFloat(value)
        }
    }
}

/// The `radius.pill` shape: a capsule, or a rounded rect when a numeric
/// radius is pinned (by the token or by a component assignment).
struct ThemePillShape: InsettableShape {
    var cornerRadius: CGFloat?
    var insetAmount: CGFloat = 0

    init(_ shape: ThemeCornerShape, pinned: CGFloat? = nil) {
        if let pinned {
            cornerRadius = pinned
        } else if case .radius(let value) = shape {
            cornerRadius = CGFloat(value)
        } else {
            cornerRadius = nil
        }
    }

    func path(in rect: CGRect) -> Path {
        let inner = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard let cornerRadius else { return Capsule().path(in: inner) }
        return RoundedRectangle(cornerRadius: max(0, cornerRadius - insetAmount)).path(in: inner)
    }

    func inset(by amount: CGFloat) -> ThemePillShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

public struct ThemeRadii: Codable, Equatable, Hashable, Sendable {
    public var none: Double
    public var small: Double
    public var medium: Double
    public var large: Double
    public var xlarge: Double
    public var bubble: Double
    public var pill: ThemeCornerShape

    public init(
        none: Double = 0, small: Double = 4, medium: Double = 8, large: Double = 12, xlarge: Double = 16,
        bubble: Double = 18, pill: ThemeCornerShape = .capsule
    ) {
        self.none = none
        self.small = small
        self.medium = medium
        self.large = large
        self.xlarge = xlarge
        self.bubble = bubble
        self.pill = pill
    }

    private enum CodingKeys: String, CodingKey {
        case none, small, medium, large, xlarge, bubble, pill
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        none = try c.decode(Double.self, forKey: .none)
        small = try c.decode(Double.self, forKey: .small)
        medium = try c.decode(Double.self, forKey: .medium)
        large = try c.decode(Double.self, forKey: .large)
        xlarge = try c.decode(Double.self, forKey: .xlarge)
        bubble = try c.decode(Double.self, forKey: .bubble)
        pill = try c.decodeIfPresent(ThemeCornerShape.self, forKey: .pill) ?? .capsule
    }

    public static var `default`: ThemeRadii { ThemeRadii() }
}

/// `stroke.hairline`: a rule expressed in physical pixels
/// (`"N / backingScaleFactor"`), resolved per display.
public struct ThemeHairlineRule: Codable, Equatable, Hashable, Sendable {
    public var formula: String

    public init(formula: String = "1 / backingScaleFactor") {
        self.formula = formula
    }

    /// Physical pixels the rule spans: the numerator of the formula.
    public var pixels: Double {
        let numerator = formula.split(separator: "/").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return Double(numerator).flatMap { $0 > 0 ? $0 : nil } ?? 1
    }

    public func width(forBackingScale scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return CGFloat(pixels) }
        return CGFloat(pixels) / scale
    }
}

public struct ThemeStrokes: Codable, Equatable, Hashable, Sendable {
    public var none: Double
    public var `default`: Double
    public var focus: Double
    public var hairlineRule: ThemeHairlineRule

    public init(none: Double = 0, default: Double = 1, focus: Double = 2, hairlineRule: ThemeHairlineRule = .init()) {
        self.none = none
        self.default = `default`
        self.focus = focus
        self.hairlineRule = hairlineRule
    }

    private enum CodingKeys: String, CodingKey {
        case none, `default`, focus
        case hairlineRule = "hairline"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        none = try c.decode(Double.self, forKey: .none)
        `default` = try c.decode(Double.self, forKey: .default)
        focus = try c.decode(Double.self, forKey: .focus)
        hairlineRule = try c.decodeIfPresent(ThemeHairlineRule.self, forKey: .hairlineRule) ?? ThemeHairlineRule()
    }

    public static var `default`: ThemeStrokes { ThemeStrokes() }

    /// One physical pixel on the destination display, for callers without a theme.
    public static func hairline(forBackingScale scale: CGFloat) -> CGFloat {
        ThemeHairlineRule().width(forBackingScale: scale)
    }
}

public struct ThemeSpaceScale: Codable, Equatable, Hashable, Sendable {
    public var s0: Double
    public var s2: Double
    public var s4: Double
    public var s6: Double
    public var s8: Double
    public var s12: Double
    public var s16: Double
    public var s24: Double
    public var s32: Double
    public var s40: Double
    public var s48: Double
    public var s64: Double

    public init(
        s0: Double = 0, s2: Double = 2, s4: Double = 4, s6: Double = 6, s8: Double = 8, s12: Double = 12,
        s16: Double = 16, s24: Double = 24, s32: Double = 32, s40: Double = 40, s48: Double = 48, s64: Double = 64
    ) {
        self.s0 = s0
        self.s2 = s2
        self.s4 = s4
        self.s6 = s6
        self.s8 = s8
        self.s12 = s12
        self.s16 = s16
        self.s24 = s24
        self.s32 = s32
        self.s40 = s40
        self.s48 = s48
        self.s64 = s64
    }

    public static var `default`: ThemeSpaceScale { ThemeSpaceScale() }
}

public struct ThemeControlSizes: Codable, Equatable, Hashable, Sendable {
    public var compactHeight: Double
    public var defaultHeight: Double
    public var rowMinimumHeight: Double
    public var chatAvatar: Double

    public init(
        compactHeight: Double = 28, defaultHeight: Double = 32, rowMinimumHeight: Double = 36, chatAvatar: Double = 24
    ) {
        self.compactHeight = compactHeight
        self.defaultHeight = defaultHeight
        self.rowMinimumHeight = rowMinimumHeight
        self.chatAvatar = chatAvatar
    }

    public static var `default`: ThemeControlSizes { ThemeControlSizes() }
}

// MARK: - Motion

public struct ThemeSpringRecipe: Codable, Equatable, Hashable, Sendable {
    public var response: Double
    public var dampingFraction: Double

    public init(response: Double = 0.35, dampingFraction: Double = 0.82) {
        self.response = response
        self.dampingFraction = dampingFraction
    }
}

public enum ThemeEasing: String, Codable, Sendable, CaseIterable {
    case easeInOut
    case easeIn
    case easeOut
    case linear
}

public struct ThemeMotion: Codable, Equatable, Hashable, Sendable {
    public var durationQuick: Double
    public var durationStandard: Double
    public var durationSlow: Double
    public var spring: ThemeSpringRecipe
    public var easing: ThemeEasing

    public init(
        durationQuick: Double = 0.15, durationStandard: Double = 0.25, durationSlow: Double = 0.35,
        spring: ThemeSpringRecipe = ThemeSpringRecipe(), easing: ThemeEasing = .easeInOut
    ) {
        self.durationQuick = durationQuick
        self.durationStandard = durationStandard
        self.durationSlow = durationSlow
        self.spring = spring
        self.easing = easing
    }

    public static var `default`: ThemeMotion { ThemeMotion() }
}

// MARK: - Elevation

public struct ThemeElevationRecipe: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var blur: Double
    public var opacity: Double
    public var color: String

    public init(x: Double = 0, y: Double, blur: Double, opacity: Double, color: String = "#000000") {
        self.x = x
        self.y = y
        self.blur = blur
        self.opacity = opacity
        self.color = color
    }

    public static var none: ThemeElevationRecipe { ThemeElevationRecipe(y: 0, blur: 0, opacity: 0) }
}

public struct ThemeElevation: Codable, Equatable, Hashable, Sendable {
    public var none: ThemeElevationRecipe
    public var raised: ThemeElevationRecipe
    public var overlay: ThemeElevationRecipe

    public init(
        none: ThemeElevationRecipe = .none,
        raised: ThemeElevationRecipe,
        overlay: ThemeElevationRecipe
    ) {
        self.none = none
        self.raised = raised
        self.overlay = overlay
    }

    public static var lightDefaults: ThemeElevation {
        ThemeElevation(
            raised: ThemeElevationRecipe(y: 2, blur: 8, opacity: 0.12),
            overlay: ThemeElevationRecipe(y: 6, blur: 16, opacity: 0.12)
        )
    }

    public static var darkDefaults: ThemeElevation {
        ThemeElevation(
            raised: ThemeElevationRecipe(y: 3, blur: 10, opacity: 0.32),
            overlay: ThemeElevationRecipe(y: 6, blur: 16, opacity: 0.35)
        )
    }
}

// MARK: - Effects (design library)

/// One Figma effect layer: a drop or inner shadow.
public struct ThemeEffectLayer: Codable, Equatable, Hashable, Sendable {
    public var type: String
    public var visible: Bool
    public var blur: Double
    public var x: Double
    public var y: Double
    public var spread: Double
    public var blendMode: String
    public var color: String
    public var showShadowBehindNode: Bool

    public init(
        type: String, visible: Bool = true, blur: Double, x: Double = 0, y: Double, spread: Double = 0,
        blendMode: String = "NORMAL", color: String, showShadowBehindNode: Bool = false
    ) {
        self.type = type
        self.visible = visible
        self.blur = blur
        self.x = x
        self.y = y
        self.spread = spread
        self.blendMode = blendMode
        self.color = color
        self.showShadowBehindNode = showShadowBehindNode
    }
}

/// A stack of effect layers (`effect.*` in the design library).
public struct ThemeEffectRecipe: Codable, Equatable, Hashable, Sendable {
    public var layers: [ThemeEffectLayer]
    public var available: Bool

    public init(layers: [ThemeEffectLayer] = [], available: Bool = false) {
        self.layers = layers
        self.available = available
    }

    public static var none: ThemeEffectRecipe { ThemeEffectRecipe() }
}

/// The library's effect recipes. Empty on the engineering seeds; the
/// bundled design library supplies the values. `elevation` above remains
/// the seed contract that existing surfaces draw.
public struct ThemeEffects: Codable, Equatable, Hashable, Sendable {
    public var elevationNone: ThemeEffectRecipe
    public var elevation1: ThemeEffectRecipe
    public var elevation2: ThemeEffectRecipe
    public var elevation3: ThemeEffectRecipe
    public var elevation4: ThemeEffectRecipe
    public var bevelRaisedNeutral: ThemeEffectRecipe
    public var bevelRaisedBrand: ThemeEffectRecipe
    public var bevelInsetNeutral: ThemeEffectRecipe
    public var bevelInsetBrand: ThemeEffectRecipe

    public init(
        elevationNone: ThemeEffectRecipe = .none, elevation1: ThemeEffectRecipe = .none,
        elevation2: ThemeEffectRecipe = .none, elevation3: ThemeEffectRecipe = .none,
        elevation4: ThemeEffectRecipe = .none, bevelRaisedNeutral: ThemeEffectRecipe = .none,
        bevelRaisedBrand: ThemeEffectRecipe = .none, bevelInsetNeutral: ThemeEffectRecipe = .none,
        bevelInsetBrand: ThemeEffectRecipe = .none
    ) {
        self.elevationNone = elevationNone
        self.elevation1 = elevation1
        self.elevation2 = elevation2
        self.elevation3 = elevation3
        self.elevation4 = elevation4
        self.bevelRaisedNeutral = bevelRaisedNeutral
        self.bevelRaisedBrand = bevelRaisedBrand
        self.bevelInsetNeutral = bevelInsetNeutral
        self.bevelInsetBrand = bevelInsetBrand
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ThemeEffectRole.self)
        var effects = ThemeEffects()
        for role in ThemeEffectRole.allCases {
            effects[role] = try c.decodeIfPresent(ThemeEffectRecipe.self, forKey: role) ?? .none
        }
        self = effects
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ThemeEffectRole.self)
        for role in ThemeEffectRole.allCases { try c.encode(self[role], forKey: role) }
    }

    public static var none: ThemeEffects { ThemeEffects() }

    public subscript(role: ThemeEffectRole) -> ThemeEffectRecipe {
        get {
            switch role {
            case .elevationNone: return elevationNone
            case .elevation1: return elevation1
            case .elevation2: return elevation2
            case .elevation3: return elevation3
            case .elevation4: return elevation4
            case .bevelRaisedNeutral: return bevelRaisedNeutral
            case .bevelRaisedBrand: return bevelRaisedBrand
            case .bevelInsetNeutral: return bevelInsetNeutral
            case .bevelInsetBrand: return bevelInsetBrand
            }
        }
        set {
            switch role {
            case .elevationNone: elevationNone = newValue
            case .elevation1: elevation1 = newValue
            case .elevation2: elevation2 = newValue
            case .elevation3: elevation3 = newValue
            case .elevation4: elevation4 = newValue
            case .bevelRaisedNeutral: bevelRaisedNeutral = newValue
            case .bevelRaisedBrand: bevelRaisedBrand = newValue
            case .bevelInsetNeutral: bevelInsetNeutral = newValue
            case .bevelInsetBrand: bevelInsetBrand = newValue
            }
        }
    }
}

/// A library effect token; the raw value is the stored key in `ThemeEffects`.
public enum ThemeEffectRole: String, CodingKey, CaseIterable, Sendable {
    case elevationNone, elevation1, elevation2, elevation3, elevation4
    case bevelRaisedNeutral, bevelRaisedBrand, bevelInsetNeutral, bevelInsetBrand

    /// `effect.elevation.1` → `.elevation1`, `effect.bevel.raised.brand` → `.bevelRaisedBrand`.
    public init?(token name: String) {
        let parts = name.split(separator: ".").map(String.init)
        guard parts.count >= 3, parts[0] == "effect" else { return nil }
        let key = parts[1] + parts.dropFirst(2).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        self.init(rawValue: key)
    }

    public var token: String {
        switch self {
        case .elevationNone: return "effect.elevation.none"
        case .elevation1: return "effect.elevation.1"
        case .elevation2: return "effect.elevation.2"
        case .elevation3: return "effect.elevation.3"
        case .elevation4: return "effect.elevation.4"
        case .bevelRaisedNeutral: return "effect.bevel.raised.neutral"
        case .bevelRaisedBrand: return "effect.bevel.raised.brand"
        case .bevelInsetNeutral: return "effect.bevel.inset.neutral"
        case .bevelInsetBrand: return "effect.bevel.inset.brand"
        }
    }
}

// MARK: - Window material

/// Native material candidates for the single base-window blur.
public enum ThemeNativeMaterial: String, Codable, Sendable, CaseIterable {
    case titlebar
    case selection
    case menu
    case popover
    case sidebar
    case headerView
    case sheet
    case windowBackground
    case hudWindow
    case fullScreenUI
    case toolTip
    case contentBackground
    case underWindowBackground
    case underPageBackground

    public var nsMaterial: NSVisualEffectView.Material {
        switch self {
        case .titlebar: return .titlebar
        case .selection: return .selection
        case .menu: return .menu
        case .popover: return .popover
        case .sidebar: return .sidebar
        case .headerView: return .headerView
        case .sheet: return .sheet
        case .windowBackground: return .windowBackground
        case .hudWindow: return .hudWindow
        case .fullScreenUI: return .fullScreenUI
        case .toolTip: return .toolTip
        case .contentBackground: return .contentBackground
        case .underWindowBackground: return .underWindowBackground
        case .underPageBackground: return .underPageBackground
        }
    }
}

public enum ThemeWindowBlending: String, Codable, Sendable, CaseIterable {
    case behindWindow
    case withinWindow

    public var nsBlendingMode: NSVisualEffectView.BlendingMode {
        switch self {
        case .behindWindow: return .behindWindow
        case .withinWindow: return .withinWindow
        }
    }
}

/// The one permitted blurred base: a native material behind the window,
/// a canvas-colored tint above it, and an opaque fallback for Reduce
/// Transparency or when the material is unavailable.
public struct ThemeWindowMaterial: Codable, Equatable, Hashable, Sendable {
    public var tint: String
    /// Applied to the tint fill only, never to the window or its content.
    public var tintOpacity: Double
    public var nativeMaterial: ThemeNativeMaterial
    public var blending: ThemeWindowBlending
    public var fallback: String

    public init(
        tint: String, tintOpacity: Double = 0.75, nativeMaterial: ThemeNativeMaterial = .underWindowBackground,
        blending: ThemeWindowBlending = .behindWindow, fallback: String
    ) {
        self.tint = tint
        self.tintOpacity = tintOpacity
        self.nativeMaterial = nativeMaterial
        self.blending = blending
        self.fallback = fallback
    }

    public static var lightDefaults: ThemeWindowMaterial { ThemeWindowMaterial(tint: "#F5F5F7", fallback: "#F5F5F7") }
    public static var darkDefaults: ThemeWindowMaterial { ThemeWindowMaterial(tint: "#1C1C1E", fallback: "#1C1C1E") }
}

// MARK: - Message preferences (product behavior, not styling)

public struct ThemeMessagePreferences: Codable, Equatable, Hashable, Sendable {
    /// Whether the agent avatar is shown inline next to assistant messages.
    public var showInlineAvatar: Bool
    /// Whether the agent's display name is shown next to the avatar.
    public var showAgentName: Bool

    public init(showInlineAvatar: Bool = true, showAgentName: Bool = true) {
        self.showInlineAvatar = showInlineAvatar
        self.showAgentName = showAgentName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showInlineAvatar = try c.decodeIfPresent(Bool.self, forKey: .showInlineAvatar) ?? true
        showAgentName = try c.decodeIfPresent(Bool.self, forKey: .showAgentName) ?? true
    }

    public static var `default`: ThemeMessagePreferences { ThemeMessagePreferences() }
}
