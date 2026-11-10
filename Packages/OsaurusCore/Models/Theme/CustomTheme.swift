//
//  CustomTheme.swift
//  osaurus
//
//  The Light and Dark seed documents, expressed as semantic roles: surfaces,
//  text, actions (with interaction states), borders, status, typography
//  recipes, geometry, motion, elevation and the single base-window material.
//  The bundled design library writes its token values onto these seeds
//  (`DesignLibraryDefinition.resolve`); they are not user-editable.
//

import AppKit
import Foundation
import SwiftUI

// MARK: - Theme Metadata

/// Metadata for a custom theme
public struct ThemeMetadata: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var version: String
    public var author: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String = "Custom Theme",
        version: String = "1.0",
        author: String = "User",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        author = try container.decode(String.self, forKey: .author)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

// MARK: - Custom Theme

/// Complete theme document (schema 7, semantic roles).
public struct CustomTheme: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 7

    public var schemaVersion: Int
    public var metadata: ThemeMetadata
    public var colors: ThemeSemanticColors
    public var typography: ThemeTypography
    public var radius: ThemeRadii
    public var stroke: ThemeStrokes
    /// Gap between control bounds and the outer focus ring (`focus.offset`).
    public var focusOffset: Double
    public var space: ThemeSpaceScale
    public var controlSize: ThemeControlSizes
    public var motion: ThemeMotion
    public var elevation: ThemeElevation
    /// Library effect recipes (`effect.*`); empty unless the design library supplies them.
    public var effects: ThemeEffects
    public var windowMaterial: ThemeWindowMaterial
    /// Product preferences that happen to live with the theme; not styling.
    public var messages: ThemeMessagePreferences

    /// Syntax highlighting theme name (Highlightr). nil = auto (dark/light).
    public var codeHighlightTheme: String?

    public var isBuiltIn: Bool
    public var isDark: Bool

    public init(
        metadata: ThemeMetadata = ThemeMetadata(),
        colors: ThemeSemanticColors? = nil,
        typography: ThemeTypography = .default,
        radius: ThemeRadii = .default,
        stroke: ThemeStrokes = .default,
        focusOffset: Double = 2,
        space: ThemeSpaceScale = .default,
        controlSize: ThemeControlSizes = .default,
        motion: ThemeMotion = .default,
        elevation: ThemeElevation? = nil,
        effects: ThemeEffects = .none,
        windowMaterial: ThemeWindowMaterial? = nil,
        messages: ThemeMessagePreferences = .default,
        codeHighlightTheme: String? = nil,
        isBuiltIn: Bool = false,
        isDark: Bool = true
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.metadata = metadata
        self.colors = colors ?? (isDark ? ThemeSemanticColors.darkDefaults : ThemeSemanticColors.lightDefaults)
        self.typography = typography
        self.radius = radius
        self.stroke = stroke
        self.focusOffset = focusOffset
        self.space = space
        self.controlSize = controlSize
        self.motion = motion
        self.elevation = elevation ?? (isDark ? .darkDefaults : .lightDefaults)
        self.effects = effects
        self.windowMaterial = windowMaterial ?? (isDark ? .darkDefaults : .lightDefaults)
        self.messages = messages
        self.codeHighlightTheme = codeHighlightTheme
        self.isBuiltIn = isBuiltIn
        self.isDark = isDark
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, metadata, colors, typography, radius, stroke, focusOffset, space, controlSize
        case motion, elevation, effects, windowMaterial, messages, codeHighlightTheme, isBuiltIn, isDark
    }

    /// Missing optional groups fall back to the mode defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion

        let isDark = try container.decode(Bool.self, forKey: .isDark)
        schemaVersion = version
        metadata = try container.decode(ThemeMetadata.self, forKey: .metadata)
        colors = try container.decode(ThemeSemanticColors.self, forKey: .colors)
        typography = try container.decodeIfPresent(ThemeTypography.self, forKey: .typography) ?? .default
        radius = try container.decodeIfPresent(ThemeRadii.self, forKey: .radius) ?? .default
        stroke = try container.decodeIfPresent(ThemeStrokes.self, forKey: .stroke) ?? .default
        focusOffset = try container.decodeIfPresent(Double.self, forKey: .focusOffset) ?? 2
        space = try container.decodeIfPresent(ThemeSpaceScale.self, forKey: .space) ?? .default
        controlSize = try container.decodeIfPresent(ThemeControlSizes.self, forKey: .controlSize) ?? .default
        motion = try container.decodeIfPresent(ThemeMotion.self, forKey: .motion) ?? .default
        elevation =
            try container.decodeIfPresent(ThemeElevation.self, forKey: .elevation)
            ?? (isDark ? .darkDefaults : .lightDefaults)
        effects = try container.decodeIfPresent(ThemeEffects.self, forKey: .effects) ?? .none
        windowMaterial =
            try container.decodeIfPresent(ThemeWindowMaterial.self, forKey: .windowMaterial)
            ?? (isDark ? .darkDefaults : .lightDefaults)
        messages = try container.decodeIfPresent(ThemeMessagePreferences.self, forKey: .messages) ?? .default
        codeHighlightTheme = try container.decodeIfPresent(String.self, forKey: .codeHighlightTheme)
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        self.isDark = isDark
    }

    // MARK: Built-in identifiers

    static let builtInDarkID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let builtInLightID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    /// Default dark theme — handoff wiring values (design/semantic-tokens.json).
    public static var darkDefault: CustomTheme {
        CustomTheme(
            metadata: ThemeMetadata(id: builtInDarkID, name: "Dark", version: "3.0", author: "Osaurus"),
            colors: .darkDefaults,
            typography: .default,
            elevation: .darkDefaults,
            windowMaterial: .darkDefaults,
            isBuiltIn: true,
            isDark: true
        )
    }

    /// Default light theme — handoff wiring values (design/semantic-tokens.json).
    public static var lightDefault: CustomTheme {
        CustomTheme(
            metadata: ThemeMetadata(id: builtInLightID, name: "Light", version: "3.0", author: "Osaurus"),
            colors: .lightDefaults,
            typography: .default,
            elevation: .lightDefaults,
            windowMaterial: .lightDefaults,
            isBuiltIn: true,
            isDark: false
        )
    }
}

// MARK: - Default semantic palettes

extension ThemeColorRoles where Value == String {
    /// Handoff light palette.
    public static var lightDefaults: ThemeSemanticColors {
        ThemeSemanticColors(
            surface: ThemeSurfaceRoles(
                canvas: "#F5F5F7", subtle: "#ECECF0", raised: "#FFFFFF", overlay: "#FFFFFF", sidebar: "#E9E9ED",
                code: "#F2F2F7", hover: "#E4E4E9", pressed: "#DADAE0", selected: "#E4E4E9", disabled: "#ECECF0"
            ),
            text: ThemeTextRoles(
                primary: "#1D1D1F", secondary: "#515154", tertiary: "#5F5F64", placeholder: "#5F5F64",
                disabled: "#8E8E93", inverse: "#F5F5F7", onDanger: "#FFFFFF", link: "#000000", linkHover: "#262626"
            ),
            chat: ThemeChatRoles(userBackground: "#E4E4E9", assistantBackground: "#F5F5F7"),
            action: ThemeActionRoles(
                primary: ThemeActionVariant(
                    default: ThemeActionState(background: "#000000", foreground: "#FFFFFF"),
                    hover: ThemeActionState(background: "#262626", foreground: "#FFFFFF"),
                    pressed: ThemeActionState(background: "#404040", foreground: "#FFFFFF"),
                    disabled: ThemeActionState(background: "#ECECF0", foreground: "#8E8E93")
                ),
                secondary: ThemeActionVariant(
                    default: ThemeActionState(background: "#ECECF0", foreground: "#1D1D1F"),
                    hover: ThemeActionState(background: "#E4E4E9", foreground: "#1D1D1F"),
                    pressed: ThemeActionState(background: "#DADAE0", foreground: "#1D1D1F"),
                    disabled: ThemeActionState(background: "#ECECF0", foreground: "#8E8E93")
                ),
                tertiary: ThemeActionVariant(
                    default: ThemeActionState(background: "#00000000", foreground: "#1D1D1F"),
                    hover: ThemeActionState(background: "#E4E4E9", foreground: "#1D1D1F"),
                    pressed: ThemeActionState(background: "#DADAE0", foreground: "#1D1D1F"),
                    disabled: ThemeActionState(background: "#00000000", foreground: "#8E8E93")
                ),
                destructive: ThemeActionVariant(
                    default: ThemeActionState(background: "#B42318", foreground: "#FFFFFF"),
                    hover: ThemeActionState(background: "#951D14", foreground: "#FFFFFF"),
                    pressed: ThemeActionState(background: "#7B180F", foreground: "#FFFFFF"),
                    disabled: ThemeActionState(background: "#ECECF0", foreground: "#8E8E93")
                ),
                border: "#00000000"
            ),
            border: ThemeBorderRoles(
                subtle: "#D1D1D6", default: "#C7C7CC", strong: "#85858B", focus: "#000000", error: "#B42318"),
            selection: ThemeSelectionRoles(background: "#E4E4E9", foreground: "#1D1D1F"),
            cursor: "#000000",
            status: ThemeStatusRoles(
                success: ThemeStatusSet(foreground: "#1B6D31", background: "#EAF7ED", border: "#39834B"),
                warning: ThemeStatusSet(foreground: "#805000", background: "#FFF4D6", border: "#976000"),
                error: ThemeStatusSet(foreground: "#B42318", background: "#FEEDEC", border: "#B42318"),
                info: ThemeStatusSet(foreground: "#005FCC", background: "#E6F0FF", border: "#005FCC")
            ),
            danger: ThemeDangerRoles(default: "#B42318", hover: "#951D14", pressed: "#7B180F"),
            scrim: "#00000066",
            shadow: "#000000"
        )
    }

    /// Handoff dark palette.
    public static var darkDefaults: ThemeSemanticColors {
        ThemeSemanticColors(
            surface: ThemeSurfaceRoles(
                canvas: "#1C1C1E", subtle: "#2C2C2E", raised: "#2C2C2E", overlay: "#3A3A3C", sidebar: "#252527",
                code: "#1C1C1E", hover: "#3A3A3C", pressed: "#48484A", selected: "#48484A", disabled: "#2C2C2E"
            ),
            text: ThemeTextRoles(
                primary: "#F5F5F7", secondary: "#D1D1D6", tertiary: "#B8B8C0", placeholder: "#B8B8C0",
                disabled: "#727278", inverse: "#1D1D1F", onDanger: "#101012", link: "#FFFFFF", linkHover: "#E5E5E5"
            ),
            chat: ThemeChatRoles(userBackground: "#48484A", assistantBackground: "#1C1C1E"),
            action: ThemeActionRoles(
                primary: ThemeActionVariant(
                    default: ThemeActionState(background: "#FFFFFF", foreground: "#000000"),
                    hover: ThemeActionState(background: "#E5E5E5", foreground: "#000000"),
                    pressed: ThemeActionState(background: "#CCCCCC", foreground: "#000000"),
                    disabled: ThemeActionState(background: "#2C2C2E", foreground: "#727278")
                ),
                secondary: ThemeActionVariant(
                    default: ThemeActionState(background: "#2C2C2E", foreground: "#F5F5F7"),
                    hover: ThemeActionState(background: "#3A3A3C", foreground: "#F5F5F7"),
                    pressed: ThemeActionState(background: "#48484A", foreground: "#F5F5F7"),
                    disabled: ThemeActionState(background: "#2C2C2E", foreground: "#727278")
                ),
                tertiary: ThemeActionVariant(
                    default: ThemeActionState(background: "#00000000", foreground: "#F5F5F7"),
                    hover: ThemeActionState(background: "#3A3A3C", foreground: "#F5F5F7"),
                    pressed: ThemeActionState(background: "#48484A", foreground: "#F5F5F7"),
                    disabled: ThemeActionState(background: "#00000000", foreground: "#727278")
                ),
                destructive: ThemeActionVariant(
                    default: ThemeActionState(background: "#FF6B62", foreground: "#101012"),
                    hover: ThemeActionState(background: "#FF8982", foreground: "#101012"),
                    pressed: ThemeActionState(background: "#FFA59F", foreground: "#101012"),
                    disabled: ThemeActionState(background: "#2C2C2E", foreground: "#727278")
                ),
                border: "#00000000"
            ),
            border: ThemeBorderRoles(
                subtle: "#38383A", default: "#48484A", strong: "#85858D", focus: "#FFFFFF", error: "#FF6B62"),
            selection: ThemeSelectionRoles(background: "#48484A", foreground: "#F5F5F7"),
            cursor: "#FFFFFF",
            status: ThemeStatusRoles(
                success: ThemeStatusSet(foreground: "#60D980", background: "#15351F", border: "#60D980"),
                warning: ThemeStatusSet(foreground: "#FFC15C", background: "#3E2B0D", border: "#FFC15C"),
                error: ThemeStatusSet(foreground: "#FF6B62", background: "#401E1B", border: "#FF6B62"),
                info: ThemeStatusSet(foreground: "#80B9FF", background: "#173457", border: "#80B9FF")
            ),
            danger: ThemeDangerRoles(default: "#FF6B62", hover: "#FF8982", pressed: "#FFA59F"),
            scrim: "#00000080",
            shadow: "#000000"
        )
    }
}

// MARK: - Color Parsing Extension

extension Color {
    // Theme color accessors funnel through this initializer from view bodies
    // on every SwiftUI body evaluation, and each call pays for a CharacterSet
    // inversion plus a Scanner parse. Themes draw from a small fixed palette,
    // so parsed colors are memoized by their hex string.
    private static let themeHexCacheLock = NSLock()
    private nonisolated(unsafe) static var themeHexCache: [String: Color] = [:]

    /// Initialize from hex string with alpha support
    init(themeHex hex: String) {
        Color.themeHexCacheLock.lock()
        if let cached = Color.themeHexCache[hex] {
            Color.themeHexCacheLock.unlock()
            self = cached
            return
        }
        Color.themeHexCacheLock.unlock()

        let key = hex
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a: UInt64
        let r: UInt64
        let g: UInt64
        let b: UInt64
        switch hex.count {
        case 3:  // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:  // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:  // RGBA (32-bit) — theme colors are authored web-style with
            // trailing alpha ("#3b82f680", accent+"45"). This previously read
            // ARGB, so the leading red byte became the alpha and colors like
            // the system-accent selection "#007aff26" resolved fully
            // transparent (invisible selection highlight, issue #2129).
            // Mirrors the same fix in Color(hex:) (Theme.swift).
            (r, g, b, a) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )

        Color.themeHexCacheLock.lock()
        // Safety-net cap (reset-on-overflow): the theme palette is small and
        // fixed, but custom themes contribute arbitrary hex strings over time.
        if Color.themeHexCache.count >= 512 { Color.themeHexCache.removeAll() }
        Color.themeHexCache[key] = self
        Color.themeHexCacheLock.unlock()
    }

    /// Convert Color to hex string
    func toHex(includeAlpha: Bool = false) -> String {
        // Convert to sRGB color space first for consistent round-trip with Color(themeHex:)
        let nsColor: NSColor
        if let converted = NSColor(self).usingColorSpace(.sRGB) {
            nsColor = converted
        } else if let converted = NSColor(self).usingColorSpace(.deviceRGB) {
            nsColor = converted
        } else {
            return "#000000"
        }

        let r = Int((nsColor.redComponent * 255).rounded())
        let g = Int((nsColor.greenComponent * 255).rounded())
        let b = Int((nsColor.blueComponent * 255).rounded())
        let a = Int((nsColor.alphaComponent * 255).rounded())

        // Trailing alpha ("#RRGGBBAA") to match how Color(themeHex:) parses
        // 8-digit strings. This used to emit leading alpha, so every color
        // with opacity below 100% round-tripped with its channels shifted
        // (alpha became red), which made the theme editor's color picker
        // snap to a different color on every drag tick.
        if includeAlpha && a < 255 {
            return String(format: "#%02X%02X%02X%02X", r, g, b, a)
        }
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
