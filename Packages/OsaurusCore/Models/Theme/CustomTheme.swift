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

    /// Default dark theme. Values are generated from `design-library.json` by
    /// `scripts/design-handoff/sync-theme-seeds.py`.
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

    /// Default light theme. Values are generated from `design-library.json` by
    /// `scripts/design-handoff/sync-theme-seeds.py`.
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
    /// Light palette, generated from the bundled design library.
    public static var lightDefaults: ThemeSemanticColors {
        ThemeSemanticColors(
            surface: ThemeSurfaceRoles(
                canvas: "#FBFAF9FF", subtle: "#ECEBE8FF", raised: "#F0EFEDFF", overlay: "#FBFAF9FF",
                sidebar: "#ECEBE8FF", code: "#F0EFEDFF", hover: "#453d3614", pressed: "#453d3626",
                selected: "#E5E5E1FF", disabled: "#E5E5E1FF"
            ),
            text: ThemeTextRoles(
                primary: "#2D2D2AFF", secondary: "#474543FF", tertiary: "#5A5852FF", placeholder: "#5A5852FF",
                disabled: "#888680FF", inverse: "#F0EFEDFF", onDanger: "#FBFAF9FF", link: "#181816FF",
                linkHover: "#2D2D2AFF"
            ),
            chat: ThemeChatRoles(userBackground: "#E5E5E1FF", assistantBackground: "#F0EFEDFF"),
            action: ThemeActionRoles(
                primary: ThemeActionVariant(
                    default: ThemeActionState(background: "#2D2D2AFF", foreground: "#FBFAF9FF"),
                    hover: ThemeActionState(background: "#181816FF", foreground: "#FBFAF9FF"),
                    pressed: ThemeActionState(background: "#474543FF", foreground: "#FBFAF9FF"),
                    disabled: ThemeActionState(background: "#ECEBE8FF", foreground: "#888680FF")
                ),
                secondary: ThemeActionVariant(
                    default: ThemeActionState(background: "#E5E5E1FF", foreground: "#2D2D2AFF"),
                    hover: ThemeActionState(background: "#D8D8D4FF", foreground: "#2D2D2AFF"),
                    pressed: ThemeActionState(background: "#E5E5E1FF", foreground: "#2D2D2AFF"),
                    disabled: ThemeActionState(background: "#ECEBE8FF", foreground: "#888680FF")
                ),
                tertiary: ThemeActionVariant(
                    default: ThemeActionState(background: "#00000000", foreground: "#2D2D2AFF"),
                    hover: ThemeActionState(background: "#E5E5E1FF", foreground: "#2D2D2AFF"),
                    pressed: ThemeActionState(background: "#D8D8D4FF", foreground: "#2D2D2AFF"),
                    disabled: ThemeActionState(background: "#00000000", foreground: "#888680FF")
                ),
                destructive: ThemeActionVariant(
                    default: ThemeActionState(background: "#D31B00FF", foreground: "#FBFAF9FF"),
                    hover: ThemeActionState(background: "#9B2208FF", foreground: "#FBFAF9FF"),
                    pressed: ThemeActionState(background: "#531609FF", foreground: "#FBFAF9FF"),
                    disabled: ThemeActionState(background: "#ECEBE8FF", foreground: "#888680FF")
                ),
                border: "#00000000"
            ),
            border: ThemeBorderRoles(
                subtle: "#D8D8D4FF", default: "#BAB9B5FF", strong: "#888680FF", focus: "#181816FF", error: "#D31B00FF"),
            selection: ThemeSelectionRoles(background: "#E5E5E1FF", foreground: "#2D2D2AFF"),
            cursor: "#181816FF",
            status: ThemeStatusRoles(
                success: ThemeStatusSet(foreground: "#227758FF", background: "#E3FCF4FF", border: "#40BF90FF", ink: "#227758FF"),
                warning: ThemeStatusSet(foreground: "#976000FF", background: "#FFEDD6FF", border: "#FFBA6BFF", ink: "#976000FF"),
                error: ThemeStatusSet(foreground: "#9B2208FF", background: "#FEEBE7FF", border: "#D31B00FF", ink: "#9B2208FF"),
                info: ThemeStatusSet(foreground: "#0E4F90FF", background: "#E5F5FFFF", border: "#2375C7FF", ink: "#0E4F90FF")
            ),
            danger: ThemeDangerRoles(default: "#D31B00FF", hover: "#9B2208FF", pressed: "#531609FF"),
            scrim: "#00000066",
            shadow: "#000000FF",
            data: [
                "1": ThemeDataSwatch(ink: "#1E40AFFF", wash: "#3B82F626"),
                "2": ThemeDataSwatch(ink: "#166534FF", wash: "#22C55E26"),
                "3": ThemeDataSwatch(ink: "#9A3412FF", wash: "#F9731626"),
                "4": ThemeDataSwatch(ink: "#6B21A8FF", wash: "#A855F726"),
                "5": ThemeDataSwatch(ink: "#115E59FF", wash: "#14B8A626"),
                "6": ThemeDataSwatch(ink: "#9D174DFF", wash: "#EC489926"),
                "7": ThemeDataSwatch(ink: "#4338CAFF", wash: "#6366F126"),
                "8": ThemeDataSwatch(ink: "#155E75FF", wash: "#06B6D426")
            ]
        )
    }

    /// Dark palette, generated from the bundled design library.
    public static var darkDefaults: ThemeSemanticColors {
        ThemeSemanticColors(
            surface: ThemeSurfaceRoles(
                canvas: "#181816FF", subtle: "#201F1DFF", raised: "#2A2928FF", overlay: "#353331FF",
                sidebar: "#201F1DFF", code: "#201F1DFF", hover: "#A1A09B1A", pressed: "#A1A09B26",
                selected: "#A1A09B40", disabled: "#2A2928FF"
            ),
            text: ThemeTextRoles(
                primary: "#FBFAF9FF", secondary: "#D8D8D4FF", tertiary: "#A1A09BFF", placeholder: "#A1A09BFF",
                disabled: "#54524FFF", inverse: "#201F1DFF", onDanger: "#201F1DFF", link: "#FBFAF9FF",
                linkHover: "#EEEEECFF"
            ),
            chat: ThemeChatRoles(userBackground: "#3F3D3BFF", assistantBackground: "#201F1DFF"),
            action: ThemeActionRoles(
                primary: ThemeActionVariant(
                    default: ThemeActionState(background: "#EEEEECFF", foreground: "#181816FF"),
                    hover: ThemeActionState(background: "#A1A09BFF", foreground: "#181816FF"),
                    pressed: ThemeActionState(background: "#EEEEECFF", foreground: "#181816FF"),
                    disabled: ThemeActionState(background: "#54524FFF", foreground: "#A1A09BFF")
                ),
                secondary: ThemeActionVariant(
                    default: ThemeActionState(background: "#353331FF", foreground: "#D8D8D4FF"),
                    hover: ThemeActionState(background: "#3F3D3BFF", foreground: "#D8D8D4FF"),
                    pressed: ThemeActionState(background: "#353331FF", foreground: "#FBFAF9FF"),
                    disabled: ThemeActionState(background: "#2A2928FF", foreground: "#54524FFF")
                ),
                tertiary: ThemeActionVariant(
                    default: ThemeActionState(background: "#00000000", foreground: "#D8D8D4FF"),
                    hover: ThemeActionState(background: "#A1A09B1A", foreground: "#D8D8D4FF"),
                    pressed: ThemeActionState(background: "#A1A09B40", foreground: "#D8D8D4FF"),
                    disabled: ThemeActionState(background: "#00000000", foreground: "#73726EFF")
                ),
                destructive: ThemeActionVariant(
                    default: ThemeActionState(background: "#AF290EFF", foreground: "#FBFAF9FF"),
                    hover: ThemeActionState(background: "#F2340DFF", foreground: "#000000FF"),
                    pressed: ThemeActionState(background: "#85230FFF", foreground: "#FBFAF9FF"),
                    disabled: ThemeActionState(background: "#353331FF", foreground: "#73726EFF")
                ),
                border: "#00000000"
            ),
            border: ThemeBorderRoles(
                subtle: "#353331FF", default: "#3F3D3BFF", strong: "#73726EFF", focus: "#FBFAF9FF", error: "#F2340DFF"),
            selection: ThemeSelectionRoles(background: "#3F3D3BFF", foreground: "#EEEEECFF"),
            cursor: "#FBFAF9FF",
            status: ThemeStatusRoles(
                success: ThemeStatusSet(foreground: "#4CE5ADFF", background: "#073120FF", border: "#106043FF", ink: "#4CE5ADFF"),
                warning: ThemeStatusSet(foreground: "#FFB35CFF", background: "#57370FFF", border: "#8A530FFF", ink: "#FFB35CFF"),
                error: ThemeStatusSet(foreground: "#F37358FF", background: "#5C180AFF", border: "#85230FFF", ink: "#F37358FF"),
                info: ThemeStatusSet(foreground: "#70B8FFFF", background: "#092E53FF", border: "#0F4D86FF", ink: "#70B8FFFF")
            ),
            danger: ThemeDangerRoles(default: "#F2340DFF", hover: "#F37358FF", pressed: "#F99B86FF"),
            scrim: "#00000080",
            shadow: "#000000FF",
            data: [
                "1": ThemeDataSwatch(ink: "#93C5FDFF", wash: "#60A5FA33"),
                "2": ThemeDataSwatch(ink: "#86EFACFF", wash: "#4ADE8033"),
                "3": ThemeDataSwatch(ink: "#FDBA74FF", wash: "#FB923C33"),
                "4": ThemeDataSwatch(ink: "#D8B4FEFF", wash: "#C084FC33"),
                "5": ThemeDataSwatch(ink: "#5EEAD4FF", wash: "#2DD4BF33"),
                "6": ThemeDataSwatch(ink: "#F9A8D4FF", wash: "#F472B633"),
                "7": ThemeDataSwatch(ink: "#A5B4FCFF", wash: "#818CF833"),
                "8": ThemeDataSwatch(ink: "#67E8F9FF", wash: "#22D3EE33")
            ]
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
