//
//  CustomTheme.swift
//  osaurus
//
//  User-customizable theme model with full color palette, background, glass, and typography support
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
}

// MARK: - Theme Colors

/// All customizable colors in a theme
public struct ThemeColors: Codable, Equatable, Sendable {
    // Primary colors
    public var primaryText: String
    public var secondaryText: String
    public var tertiaryText: String

    // Background colors
    public var primaryBackground: String
    public var secondaryBackground: String
    public var tertiaryBackground: String

    // Sidebar colors
    public var sidebarBackground: String
    public var sidebarSelectedBackground: String

    // Accent colors
    public var accentColor: String
    public var accentColorLight: String

    // Border colors
    public var primaryBorder: String
    public var secondaryBorder: String
    public var focusBorder: String

    // Status colors
    public var successColor: String
    public var warningColor: String
    public var errorColor: String
    public var infoColor: String

    // Component specific
    public var cardBackground: String
    public var cardBorder: String
    public var buttonBackground: String
    public var buttonBorder: String
    public var inputBackground: String
    public var inputBorder: String
    public var glassTintOverlay: String
    public var codeBlockBackground: String

    // Shadow
    public var shadowColor: String

    // Selection (text highlight)
    public var selectionColor: String

    public init(
        primaryText: String = "#f9fafb",
        secondaryText: String = "#9ca3af",
        tertiaryText: String = "#6b7280",
        primaryBackground: String = "#0f0f10",
        secondaryBackground: String = "#18181b",
        tertiaryBackground: String = "#27272a",
        sidebarBackground: String = "#141416",
        sidebarSelectedBackground: String = "#2a2a2e",
        accentColor: String = "#3b82f6",
        accentColorLight: String = "#60a5fa",
        primaryBorder: String = "#27272a",
        secondaryBorder: String = "#3f3f46",
        focusBorder: String = "#3b82f6",
        successColor: String = "#10b981",
        warningColor: String = "#f59e0b",
        errorColor: String = "#ef4444",
        infoColor: String = "#3b82f6",
        cardBackground: String = "#18181b",
        cardBorder: String = "#3f3f46",
        buttonBackground: String = "#18181b",
        buttonBorder: String = "#3f3f46",
        inputBackground: String = "#18181b",
        inputBorder: String = "#3f3f46",
        glassTintOverlay: String = "#00000030",
        codeBlockBackground: String = "#00000059",
        shadowColor: String = "#000000",
        selectionColor: String = "#3b82f680"
    ) {
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.tertiaryText = tertiaryText
        self.primaryBackground = primaryBackground
        self.secondaryBackground = secondaryBackground
        self.tertiaryBackground = tertiaryBackground
        self.sidebarBackground = sidebarBackground
        self.sidebarSelectedBackground = sidebarSelectedBackground
        self.accentColor = accentColor
        self.accentColorLight = accentColorLight
        self.primaryBorder = primaryBorder
        self.secondaryBorder = secondaryBorder
        self.focusBorder = focusBorder
        self.successColor = successColor
        self.warningColor = warningColor
        self.errorColor = errorColor
        self.infoColor = infoColor
        self.cardBackground = cardBackground
        self.cardBorder = cardBorder
        self.buttonBackground = buttonBackground
        self.buttonBorder = buttonBorder
        self.inputBackground = inputBackground
        self.inputBorder = inputBorder
        self.glassTintOverlay = glassTintOverlay
        self.codeBlockBackground = codeBlockBackground
        self.shadowColor = shadowColor
        self.selectionColor = selectionColor
    }

    /// Create colors from dark theme defaults
    public static var darkDefaults: ThemeColors { ThemeColors() }

    /// Create colors from light theme defaults
    public static var lightDefaults: ThemeColors {
        ThemeColors(
            primaryText: "#1a1a1a",
            secondaryText: "#6b7280",
            tertiaryText: "#9ca3af",
            primaryBackground: "#ffffff",
            secondaryBackground: "#f9fafb",
            tertiaryBackground: "#f3f4f6",
            sidebarBackground: "#f5f5f7",
            sidebarSelectedBackground: "#e8e8ed",
            accentColor: "#3b82f6",
            accentColorLight: "#60a5fa",
            primaryBorder: "#e5e7eb",
            secondaryBorder: "#f3f4f6",
            focusBorder: "#3b82f6",
            successColor: "#10b981",
            warningColor: "#f59e0b",
            errorColor: "#ef4444",
            infoColor: "#3b82f6",
            cardBackground: "#ffffff",
            cardBorder: "#e5e7eb",
            buttonBackground: "#ffffff",
            buttonBorder: "#d1d5db",
            inputBackground: "#ffffff",
            inputBorder: "#d1d5db",
            glassTintOverlay: "#0000001f",
            codeBlockBackground: "#00000014",
            shadowColor: "#000000",
            selectionColor: "#3b82f650"
        )
    }
}

// MARK: - Theme Background

/// Background configuration for the theme
public struct ThemeBackground: Codable, Equatable, Sendable {
    public enum BackgroundType: String, Codable, Sendable {
        case solid
        case gradient
        case image
    }

    public enum ImageFit: String, Codable, Sendable {
        case fill
        case fit
        case stretch
        case tile
    }

    public var type: BackgroundType
    public var solidColor: String?
    public var gradientColors: [String]?
    public var gradientAngle: Double?
    public var imageData: String?  // Base64 encoded image data
    public var imageFit: ImageFit?
    public var imageOpacity: Double?
    public var overlayColor: String?
    public var overlayOpacity: Double?

    public init(
        type: BackgroundType = .solid,
        solidColor: String? = nil,
        gradientColors: [String]? = nil,
        gradientAngle: Double? = nil,
        imageData: String? = nil,
        imageFit: ImageFit? = nil,
        imageOpacity: Double? = nil,
        overlayColor: String? = nil,
        overlayOpacity: Double? = nil
    ) {
        self.type = type
        self.solidColor = solidColor
        self.gradientColors = gradientColors
        self.gradientAngle = gradientAngle
        self.imageData = imageData
        self.imageFit = imageFit
        self.imageOpacity = imageOpacity
        self.overlayColor = overlayColor
        self.overlayOpacity = overlayOpacity
    }

    /// Default solid background (uses theme's primary background)
    public static var `default`: ThemeBackground {
        ThemeBackground(type: .solid)
    }

    /// Decode base64 image data to NSImage
    public func decodedImage() -> NSImage? {
        guard let imageData = imageData,
            let data = Data(base64Encoded: imageData)
        else { return nil }
        return NSImage(data: data)
    }
}

// MARK: - Theme Glass

/// Glass effect configuration
public struct ThemeGlass: Codable, Equatable, Sendable {
    public enum GlassMaterial: String, Codable, Sendable {
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

    /// Whether glass effect is enabled (false = solid background)
    public var enabled: Bool
    public var material: GlassMaterial
    public var blurRadius: Double
    public var opacityPrimary: Double
    public var opacitySecondary: Double
    public var opacityTertiary: Double
    public var tintColor: String?
    public var tintOpacity: Double?
    public var edgeLight: String
    public var edgeLightWidth: Double?

    public init(
        enabled: Bool = true,
        material: GlassMaterial = .hudWindow,
        blurRadius: Double = 30,
        opacityPrimary: Double = 0.10,
        opacitySecondary: Double = 0.08,
        opacityTertiary: Double = 0.05,
        tintColor: String? = nil,
        tintOpacity: Double? = nil,
        edgeLight: String = "#ffffff33",
        edgeLightWidth: Double? = nil
    ) {
        self.enabled = enabled
        self.material = material
        self.blurRadius = blurRadius
        self.opacityPrimary = opacityPrimary
        self.opacitySecondary = opacitySecondary
        self.opacityTertiary = opacityTertiary
        self.tintColor = tintColor
        self.tintOpacity = tintOpacity
        self.edgeLight = edgeLight
        self.edgeLightWidth = edgeLightWidth
    }

    /// Dark theme glass defaults
    public static var darkDefaults: ThemeGlass { ThemeGlass() }

    /// Light theme glass defaults
    public static var lightDefaults: ThemeGlass {
        ThemeGlass(
            enabled: true,
            material: .hudWindow,
            blurRadius: 20,
            opacityPrimary: 0.15,
            opacitySecondary: 0.10,
            opacityTertiary: 0.05,
            edgeLight: "#ffffff4d"
        )
    }
}

// MARK: - Theme Typography

/// Typography configuration
public struct ThemeTypography: Codable, Equatable, Sendable {
    public var primaryFont: String
    public var monoFont: String
    public var titleSize: Double
    public var headingSize: Double
    public var bodySize: Double
    public var captionSize: Double
    public var codeSize: Double

    public init(
        primaryFont: String = "SF Pro",
        monoFont: String = "SF Mono",
        titleSize: Double = 28,
        headingSize: Double = 18,
        bodySize: Double = 14,
        captionSize: Double = 12,
        codeSize: Double = 13
    ) {
        self.primaryFont = primaryFont
        self.monoFont = monoFont
        self.titleSize = titleSize
        self.headingSize = headingSize
        self.bodySize = bodySize
        self.captionSize = captionSize
        self.codeSize = codeSize
    }

    public static var `default`: ThemeTypography { ThemeTypography() }
}

// MARK: - Theme Animation

/// Animation timing configuration
public struct ThemeAnimation: Codable, Equatable, Sendable {
    public var durationQuick: Double
    public var durationMedium: Double
    public var durationSlow: Double
    public var springResponse: Double
    public var springDamping: Double

    public init(
        durationQuick: Double = 0.2,
        durationMedium: Double = 0.3,
        durationSlow: Double = 0.4,
        springResponse: Double = 0.4,
        springDamping: Double = 0.8
    ) {
        self.durationQuick = durationQuick
        self.durationMedium = durationMedium
        self.durationSlow = durationSlow
        self.springResponse = springResponse
        self.springDamping = springDamping
    }

    public static var `default`: ThemeAnimation { ThemeAnimation() }

    /// SwiftUI Animation from spring config
    public var spring: Animation {
        .spring(response: springResponse, dampingFraction: springDamping)
    }
}

// MARK: - Theme Shadows

/// Shadow configuration
public struct ThemeShadows: Codable, Equatable, Sendable {
    public var shadowOpacity: Double
    public var cardShadowRadius: Double
    public var cardShadowRadiusHover: Double
    public var cardShadowY: Double
    public var cardShadowYHover: Double

    public init(
        shadowOpacity: Double = 0.3,
        cardShadowRadius: Double = 12,
        cardShadowRadiusHover: Double = 20,
        cardShadowY: Double = 4,
        cardShadowYHover: Double = 8
    ) {
        self.shadowOpacity = shadowOpacity
        self.cardShadowRadius = cardShadowRadius
        self.cardShadowRadiusHover = cardShadowRadiusHover
        self.cardShadowY = cardShadowY
        self.cardShadowYHover = cardShadowYHover
    }

    /// Dark theme shadow defaults
    public static var darkDefaults: ThemeShadows { ThemeShadows() }

    /// Light theme shadow defaults
    public static var lightDefaults: ThemeShadows {
        ThemeShadows(
            shadowOpacity: 0.05,
            cardShadowRadius: 8,
            cardShadowRadiusHover: 16,
            cardShadowY: 2,
            cardShadowYHover: 6
        )
    }
}

// MARK: - Custom Theme

/// Complete custom theme configuration
public struct CustomTheme: Codable, Equatable, Sendable {
    public var metadata: ThemeMetadata
    public var colors: ThemeColors
    public var background: ThemeBackground
    public var glass: ThemeGlass
    public var typography: ThemeTypography
    public var animationConfig: ThemeAnimation
    public var shadows: ThemeShadows

    /// Whether this is a built-in theme (cannot be deleted)
    public var isBuiltIn: Bool

    public init(
        metadata: ThemeMetadata = ThemeMetadata(),
        colors: ThemeColors = ThemeColors(),
        background: ThemeBackground = .default,
        glass: ThemeGlass = ThemeGlass(),
        typography: ThemeTypography = ThemeTypography(),
        animationConfig: ThemeAnimation = ThemeAnimation(),
        shadows: ThemeShadows = ThemeShadows(),
        isBuiltIn: Bool = false
    ) {
        self.metadata = metadata
        self.colors = colors
        self.background = background
        self.glass = glass
        self.typography = typography
        self.animationConfig = animationConfig
        self.shadows = shadows
        self.isBuiltIn = isBuiltIn
    }

    /// Default dark theme
    public static var darkDefault: CustomTheme {
        CustomTheme(
            metadata: ThemeMetadata(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                name: "Dark",
                author: "Osaurus"
            ),
            colors: .darkDefaults,
            background: .default,
            glass: .darkDefaults,
            typography: .default,
            animationConfig: .default,
            shadows: .darkDefaults,
            isBuiltIn: true
        )
    }

    /// Default light theme
    public static var lightDefault: CustomTheme {
        CustomTheme(
            metadata: ThemeMetadata(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                name: "Light",
                author: "Osaurus"
            ),
            colors: .lightDefaults,
            background: .default,
            glass: .lightDefaults,
            typography: .default,
            animationConfig: .default,
            shadows: .lightDefaults,
            isBuiltIn: true
        )
    }

    /// Cyberpunk Neon theme - vibrant colors on dark background
    public static var neonPreset: CustomTheme {
        CustomTheme(
            metadata: ThemeMetadata(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                name: "Neon",
                author: "Osaurus"
            ),
            colors: ThemeColors(
                primaryText: "#f0f0f0",
                secondaryText: "#a0a0a0",
                tertiaryText: "#707070",
                primaryBackground: "#0a0a14",
                secondaryBackground: "#12121f",
                tertiaryBackground: "#1a1a2e",
                sidebarBackground: "#0e0e1a",
                sidebarSelectedBackground: "#1f1f35",
                accentColor: "#ff00ff",
                accentColorLight: "#ff66ff",
                primaryBorder: "#2a2a40",
                secondaryBorder: "#3a3a55",
                focusBorder: "#ff00ff",
                successColor: "#00ff88",
                warningColor: "#ffaa00",
                errorColor: "#ff3366",
                infoColor: "#00ccff",
                cardBackground: "#12121f",
                cardBorder: "#2a2a40",
                buttonBackground: "#1a1a2e",
                buttonBorder: "#3a3a55",
                inputBackground: "#0e0e1a",
                inputBorder: "#2a2a40",
                glassTintOverlay: "#ff00ff15",
                codeBlockBackground: "#00000050",
                shadowColor: "#ff00ff",
                selectionColor: "#ff00ff60"
            ),
            background: .default,
            glass: ThemeGlass(
                material: .hudWindow,
                blurRadius: 35,
                opacityPrimary: 0.12,
                opacitySecondary: 0.08,
                opacityTertiary: 0.04,
                tintColor: "#ff00ff",
                tintOpacity: 0.03,
                edgeLight: "#ff00ff40"
            ),
            typography: .default,
            animationConfig: ThemeAnimation(
                durationQuick: 0.15,
                durationMedium: 0.25,
                durationSlow: 0.35,
                springResponse: 0.35,
                springDamping: 0.75
            ),
            shadows: ThemeShadows(
                shadowOpacity: 0.4,
                cardShadowRadius: 16,
                cardShadowRadiusHover: 24,
                cardShadowY: 6,
                cardShadowYHover: 10
            ),
            isBuiltIn: true
        )
    }

    /// Nord theme - Arctic, north-bluish color palette
    public static var nordPreset: CustomTheme {
        CustomTheme(
            metadata: ThemeMetadata(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                name: "Nord",
                author: "Osaurus"
            ),
            colors: ThemeColors(
                primaryText: "#eceff4",
                secondaryText: "#d8dee9",
                tertiaryText: "#a3b1c2",
                primaryBackground: "#2e3440",
                secondaryBackground: "#3b4252",
                tertiaryBackground: "#434c5e",
                sidebarBackground: "#2e3440",
                sidebarSelectedBackground: "#434c5e",
                accentColor: "#88c0d0",
                accentColorLight: "#8fbcbb",
                primaryBorder: "#4c566a",
                secondaryBorder: "#434c5e",
                focusBorder: "#88c0d0",
                successColor: "#a3be8c",
                warningColor: "#ebcb8b",
                errorColor: "#bf616a",
                infoColor: "#81a1c1",
                cardBackground: "#3b4252",
                cardBorder: "#4c566a",
                buttonBackground: "#434c5e",
                buttonBorder: "#4c566a",
                inputBackground: "#3b4252",
                inputBorder: "#4c566a",
                glassTintOverlay: "#88c0d010",
                codeBlockBackground: "#2e344080",
                shadowColor: "#000000",
                selectionColor: "#88c0d060"
            ),
            background: .default,
            glass: ThemeGlass(
                material: .hudWindow,
                blurRadius: 25,
                opacityPrimary: 0.12,
                opacitySecondary: 0.08,
                opacityTertiary: 0.05,
                tintColor: "#88c0d0",
                tintOpacity: 0.02,
                edgeLight: "#eceff420"
            ),
            typography: .default,
            animationConfig: .default,
            shadows: ThemeShadows(
                shadowOpacity: 0.25,
                cardShadowRadius: 10,
                cardShadowRadiusHover: 18,
                cardShadowY: 3,
                cardShadowYHover: 7
            ),
            isBuiltIn: true
        )
    }

    /// Paper theme - Warm, sepia-toned light theme
    public static var paperPreset: CustomTheme {
        CustomTheme(
            metadata: ThemeMetadata(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
                name: "Paper",
                author: "Osaurus"
            ),
            colors: ThemeColors(
                primaryText: "#3d3d3d",
                secondaryText: "#6b6b6b",
                tertiaryText: "#9a9a9a",
                primaryBackground: "#faf8f5",
                secondaryBackground: "#f5f2ed",
                tertiaryBackground: "#ebe7e0",
                sidebarBackground: "#f0ece5",
                sidebarSelectedBackground: "#e5e0d8",
                accentColor: "#c9a959",
                accentColorLight: "#d4b86a",
                primaryBorder: "#e0dcd5",
                secondaryBorder: "#ebe7e0",
                focusBorder: "#c9a959",
                successColor: "#7fb069",
                warningColor: "#e6a23c",
                errorColor: "#d56060",
                infoColor: "#6b9bc3",
                cardBackground: "#ffffff",
                cardBorder: "#e0dcd5",
                buttonBackground: "#f5f2ed",
                buttonBorder: "#d5d0c8",
                inputBackground: "#ffffff",
                inputBorder: "#d5d0c8",
                glassTintOverlay: "#c9a95910",
                codeBlockBackground: "#f0ece510",
                shadowColor: "#8b7355",
                selectionColor: "#c9a95950"
            ),
            background: .default,
            glass: ThemeGlass(
                enabled: false,
                material: .sheet,
                blurRadius: 18,
                opacityPrimary: 0.18,
                opacitySecondary: 0.12,
                opacityTertiary: 0.06,
                tintColor: "#c9a959",
                tintOpacity: 0.02,
                edgeLight: "#ffffff50"
            ),
            typography: ThemeTypography(
                primaryFont: "Georgia",
                monoFont: "Courier New",
                titleSize: 26,
                headingSize: 18,
                bodySize: 15,
                captionSize: 12,
                codeSize: 13
            ),
            animationConfig: ThemeAnimation(
                durationQuick: 0.25,
                durationMedium: 0.35,
                durationSlow: 0.5,
                springResponse: 0.45,
                springDamping: 0.85
            ),
            shadows: ThemeShadows(
                shadowOpacity: 0.08,
                cardShadowRadius: 6,
                cardShadowRadiusHover: 12,
                cardShadowY: 2,
                cardShadowYHover: 5
            ),
            isBuiltIn: true
        )
    }

    /// All built-in theme presets
    public static var allBuiltInPresets: [CustomTheme] {
        [.darkDefault, .lightDefault, .neonPreset, .nordPreset, .paperPreset]
    }
}

// MARK: - Color Parsing Extension

extension Color {
    /// Initialize from hex string with alpha support
    init(themeHex hex: String) {
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
        case 8:  // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
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
    }

    /// Convert Color to hex string
    func toHex(includeAlpha: Bool = false) -> String {
        guard let components = NSColor(self).cgColor.components else {
            return "#000000"
        }

        let r = Int((components[0] * 255).rounded())
        let g = Int(((components.count > 1 ? components[1] : components[0]) * 255).rounded())
        let b = Int(((components.count > 2 ? components[2] : components[0]) * 255).rounded())
        let a = Int(((components.count > 3 ? components[3] : 1.0) * 255).rounded())

        if includeAlpha && a < 255 {
            return String(format: "#%02X%02X%02X%02X", a, r, g, b)
        }
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
