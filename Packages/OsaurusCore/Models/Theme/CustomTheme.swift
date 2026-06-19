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

// MARK: - Theme Library Metadata

/// Where a theme entered the local library. This is intentionally persisted
/// with custom themes so the library can distinguish hand-authored themes
/// from file imports and share-link installs after relaunch.
public enum ThemeLibrarySource: String, Codable, CaseIterable, Sendable {
    case builtIn
    case local
    case imported
    case shared
}

public struct ThemeLibraryInfo: Codable, Equatable, Sendable {
    public var source: ThemeLibrarySource
    public var importedAt: Date?
    public var sharedAt: Date?
    public var remoteHash: String?
    public var remoteURL: String?
    public var sourceDetail: String?

    public init(
        source: ThemeLibrarySource = .local,
        importedAt: Date? = nil,
        sharedAt: Date? = nil,
        remoteHash: String? = nil,
        remoteURL: String? = nil,
        sourceDetail: String? = nil
    ) {
        self.source = source
        self.importedAt = importedAt
        self.sharedAt = sharedAt
        self.remoteHash = remoteHash
        self.remoteURL = remoteURL
        self.sourceDetail = sourceDetail
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

    // Placeholder
    public var placeholderText: String?

    // Cursor
    public var cursorColor: String

    // Default dark theme colors - WCAG AA compliant
    public init(
        primaryText: String = "#f9fafb",  // ~17:1 contrast ✓
        secondaryText: String = "#a1a1aa",  // ~8:1 contrast ✓ (was #9ca3af)
        tertiaryText: String = "#8b8b94",  // ~5.5:1 contrast ✓ (was #6b7280, ~3.5:1)
        primaryBackground: String = "#0f0f10",
        secondaryBackground: String = "#18181b",
        tertiaryBackground: String = "#27272a",
        sidebarBackground: String = "#141416",
        sidebarSelectedBackground: String = "#2a2a2e",
        accentColor: String = "#60a5fa",  // Higher contrast for links (was #3b82f6)
        accentColorLight: String = "#93c5fd",
        primaryBorder: String = "#3f3f46",  // Improved visibility (was #27272a)
        secondaryBorder: String = "#52525b",  // Improved visibility (was #3f3f46)
        focusBorder: String = "#60a5fa",  // Matches accentColor for consistency
        successColor: String = "#22c55e",  // Good contrast on dark ✓
        warningColor: String = "#fbbf24",  // Brighter for dark bg ✓ (was #f59e0b)
        errorColor: String = "#f87171",  // Brighter for dark bg ✓ (was #ef4444)
        infoColor: String = "#60a5fa",  // Brighter blue for dark bg (was #3b82f6)
        cardBackground: String = "#18181b",
        cardBorder: String = "#3f3f46",
        buttonBackground: String = "#18181b",
        buttonBorder: String = "#3f3f46",
        inputBackground: String = "#18181b",
        inputBorder: String = "#52525b",  // Improved visibility (was #3f3f46)
        glassTintOverlay: String = "#00000030",
        codeBlockBackground: String = "#00000059",
        shadowColor: String = "#000000",
        selectionColor: String = "#3b82f680",
        cursorColor: String = "#3b82f6",
        placeholderText: String? = "#a1a1aa"  // Matches secondaryText for better visibility
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
        self.cursorColor = cursorColor
        self.placeholderText = placeholderText
    }

    /// Create colors from dark theme defaults
    public static var darkDefaults: ThemeColors { ThemeColors() }

    /// Create colors from light theme defaults - WCAG AA compliant
    public static var lightDefaults: ThemeColors {
        ThemeColors(
            primaryText: "#1a1a1a",  // ~17:1 contrast ✓
            secondaryText: "#525252",  // ~7:1 contrast ✓ (was #6b7280, ~5:1)
            tertiaryText: "#6b6b6b",  // ~5.5:1 contrast ✓ (was #9ca3af, ~2.7:1)
            primaryBackground: "#ffffff",
            secondaryBackground: "#f9fafb",
            tertiaryBackground: "#f3f4f6",
            sidebarBackground: "#f5f5f7",
            sidebarSelectedBackground: "#e8e8ed",
            accentColor: "#1d4ed8",  // Darker blue for better contrast (was #2563eb)
            accentColorLight: "#3b82f6",
            primaryBorder: "#d1d5db",  // Improved visibility (was #e5e7eb)
            secondaryBorder: "#e5e7eb",  // Decorative (was #f3f4f6)
            focusBorder: "#2563eb",
            successColor: "#15803d",  // ~4.5:1 on white ✓ (was #10b981, ~2.5:1)
            warningColor: "#a16207",  // ~4.5:1 on white ✓ (was #f59e0b, ~2.1:1)
            errorColor: "#dc2626",  // ~4.5:1 on white ✓ (was #ef4444, ~3.1:1)
            infoColor: "#1d4ed8",  // ~7:1 on white ✓ (was #3b82f6, ~3.8:1)
            cardBackground: "#ffffff",
            cardBorder: "#d1d5db",  // Improved visibility
            buttonBackground: "#ffffff",
            buttonBorder: "#9ca3af",  // ~3:1 for UI ✓ (was #d1d5db, ~1.5:1)
            inputBackground: "#ffffff",
            inputBorder: "#9ca3af",  // ~3:1 for UI ✓ (was #d1d5db, ~1.5:1)
            glassTintOverlay: "#0000001f",
            codeBlockBackground: "#00000014",
            shadowColor: "#000000",
            selectionColor: "#2563eb50",
            cursorColor: "#2563eb",
            placeholderText: "#525252"  // Matches secondaryText for better visibility
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

    /// Process-wide cache of decoded background images, keyed by their base64
    /// payload. `CustomizableTheme.backgroundImage` reads `decodedImage()` from
    /// SwiftUI body getters, so without this every render of a themed surface
    /// re-ran a full base64 + `NSImage(data:)` decode of a potentially
    /// wallpaper-sized image on the main thread — enough to trip the app-hang
    /// watchdog. Keying on the payload means edits (new base64) miss naturally;
    /// `NSCache` evicts under memory pressure so no manual invalidation is needed.
    /// `nonisolated(unsafe)` is sound here: `NSCache` performs its own internal
    /// locking, so concurrent `object(forKey:)` / `setObject(_:forKey:)` from any
    /// actor is safe despite the type not being `Sendable`.
    private nonisolated(unsafe) static let decodedImageCache = NSCache<NSString, NSImage>()

    /// Decode base64 image data to NSImage (memoized by payload).
    public func decodedImage() -> NSImage? {
        guard let imageData, !imageData.isEmpty else { return nil }
        let key = imageData as NSString
        if let cached = Self.decodedImageCache.object(forKey: key) { return cached }
        guard let data = Data(base64Encoded: imageData),
            let image = NSImage(data: data)
        else { return nil }
        Self.decodedImageCache.setObject(image, forKey: key)
        return image
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

    /// Whether glass effect is enabled for the chat area background.
    public var enabled: Bool
    /// Whether glass effect is enabled for the chat session sidebar.
    public var sidebarEnabled: Bool
    /// Whether glass effect is enabled for the prompt/input card.
    public var inputEnabled: Bool
    public var material: GlassMaterial
    public var blurRadius: Double
    public var opacityPrimary: Double
    public var opacitySecondary: Double
    public var opacityTertiary: Double
    public var tintColor: String?
    public var tintOpacity: Double?
    public var edgeLight: String
    public var edgeLightWidth: Double?
    public var windowBackingOpacity: Double

    public init(
        enabled: Bool = false,
        sidebarEnabled: Bool = false,
        inputEnabled: Bool = false,
        material: GlassMaterial = .hudWindow,
        blurRadius: Double = 30,
        opacityPrimary: Double = 0.10,
        opacitySecondary: Double = 0.08,
        opacityTertiary: Double = 0.05,
        tintColor: String? = nil,
        tintOpacity: Double? = nil,
        edgeLight: String = "#ffffff33",
        edgeLightWidth: Double? = nil,
        windowBackingOpacity: Double = 0.55
    ) {
        self.enabled = enabled
        self.sidebarEnabled = sidebarEnabled
        self.inputEnabled = inputEnabled
        self.material = material
        self.blurRadius = blurRadius
        self.opacityPrimary = opacityPrimary
        self.opacitySecondary = opacitySecondary
        self.opacityTertiary = opacityTertiary
        self.tintColor = tintColor
        self.tintOpacity = tintOpacity
        self.edgeLight = edgeLight
        self.edgeLightWidth = edgeLightWidth
        self.windowBackingOpacity = windowBackingOpacity
    }

    /// Dark theme glass defaults
    public static var darkDefaults: ThemeGlass { ThemeGlass() }

    /// Light theme glass defaults
    public static var lightDefaults: ThemeGlass {
        ThemeGlass(
            enabled: false,
            material: .hudWindow,
            blurRadius: 20,
            opacityPrimary: 0.15,
            opacitySecondary: 0.10,
            opacityTertiary: 0.05,
            edgeLight: "#ffffff4d",
            windowBackingOpacity: 0.65
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        sidebarEnabled = try container.decodeIfPresent(Bool.self, forKey: .sidebarEnabled) ?? false
        inputEnabled = try container.decodeIfPresent(Bool.self, forKey: .inputEnabled) ?? false
        material = try container.decode(GlassMaterial.self, forKey: .material)
        blurRadius = try container.decode(Double.self, forKey: .blurRadius)
        opacityPrimary = try container.decode(Double.self, forKey: .opacityPrimary)
        opacitySecondary = try container.decode(Double.self, forKey: .opacitySecondary)
        opacityTertiary = try container.decode(Double.self, forKey: .opacityTertiary)
        tintColor = try container.decodeIfPresent(String.self, forKey: .tintColor)
        tintOpacity = try container.decodeIfPresent(Double.self, forKey: .tintOpacity)
        edgeLight = try container.decode(String.self, forKey: .edgeLight)
        edgeLightWidth = try container.decodeIfPresent(Double.self, forKey: .edgeLightWidth)
        windowBackingOpacity = try container.decodeIfPresent(Double.self, forKey: .windowBackingOpacity) ?? 0.55
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

// MARK: - Theme Messages

/// Message bubble customization
public struct ThemeMessages: Codable, Equatable, Sendable {
    /// Corner radius for message bubbles
    public var bubbleCornerRadius: Double
    /// Opacity for user message bubble background
    public var userBubbleOpacity: Double
    /// Opacity for assistant message bubble background
    public var assistantBubbleOpacity: Double
    /// Override color for user bubbles (nil = use accentColor)
    public var userBubbleColor: String?
    /// Override color for assistant bubbles (nil = use secondaryBackground)
    public var assistantBubbleColor: String?
    /// Border width for message bubbles
    public var borderWidth: Double
    /// Whether to show edge light effect on bubbles
    public var showEdgeLight: Bool
    /// Whether the agent avatar is shown inline next to assistant messages.
    /// When false, the inline header drops the avatar and the name slides
    /// flush left.
    public var showInlineAvatar: Bool
    /// Diameter (in points) of the inline avatar shown beside assistant
    /// messages. Clamped at consumption time to a sensible range.
    public var inlineAvatarSize: Double
    /// Whether the agent's display name is shown next to the avatar.
    /// When false, only the avatar identifies the assistant in the header.
    public var showAgentName: Bool
    /// Font size (in points) of the agent's display name in the header.
    public var agentNameSize: Double

    public init(
        bubbleCornerRadius: Double = 20,
        userBubbleOpacity: Double = 0.3,
        assistantBubbleOpacity: Double = 0.85,
        userBubbleColor: String? = nil,
        assistantBubbleColor: String? = nil,
        borderWidth: Double = 0.5,
        showEdgeLight: Bool = true,
        showInlineAvatar: Bool = true,
        inlineAvatarSize: Double = 24,
        showAgentName: Bool = true,
        agentNameSize: Double = 13
    ) {
        self.bubbleCornerRadius = bubbleCornerRadius
        self.userBubbleOpacity = userBubbleOpacity
        self.assistantBubbleOpacity = assistantBubbleOpacity
        self.userBubbleColor = userBubbleColor
        self.assistantBubbleColor = assistantBubbleColor
        self.borderWidth = borderWidth
        self.showEdgeLight = showEdgeLight
        self.showInlineAvatar = showInlineAvatar
        self.inlineAvatarSize = inlineAvatarSize
        self.showAgentName = showAgentName
        self.agentNameSize = agentNameSize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bubbleCornerRadius = try c.decodeIfPresent(Double.self, forKey: .bubbleCornerRadius) ?? 20
        userBubbleOpacity = try c.decodeIfPresent(Double.self, forKey: .userBubbleOpacity) ?? 0.3
        assistantBubbleOpacity = try c.decodeIfPresent(Double.self, forKey: .assistantBubbleOpacity) ?? 0.85
        userBubbleColor = try c.decodeIfPresent(String.self, forKey: .userBubbleColor)
        assistantBubbleColor = try c.decodeIfPresent(String.self, forKey: .assistantBubbleColor)
        borderWidth = try c.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 0.5
        showEdgeLight = try c.decodeIfPresent(Bool.self, forKey: .showEdgeLight) ?? true
        showInlineAvatar = try c.decodeIfPresent(Bool.self, forKey: .showInlineAvatar) ?? true
        inlineAvatarSize = try c.decodeIfPresent(Double.self, forKey: .inlineAvatarSize) ?? 24
        showAgentName = try c.decodeIfPresent(Bool.self, forKey: .showAgentName) ?? true
        agentNameSize = try c.decodeIfPresent(Double.self, forKey: .agentNameSize) ?? 13
    }

    public static var `default`: ThemeMessages { ThemeMessages() }
}

// MARK: - Theme Borders

/// Border and corner radius customization
public struct ThemeBorders: Codable, Equatable, Sendable {
    /// Default border width for UI elements
    public var defaultWidth: Double
    /// Corner radius for card-style elements
    public var cardCornerRadius: Double
    /// Corner radius for input fields
    public var inputCornerRadius: Double
    /// Default border opacity applied to border colors
    public var borderOpacity: Double

    public init(
        defaultWidth: Double = 1.0,
        cardCornerRadius: Double = 12,
        inputCornerRadius: Double = 8,
        borderOpacity: Double = 0.3
    ) {
        self.defaultWidth = defaultWidth
        self.cardCornerRadius = cardCornerRadius
        self.inputCornerRadius = inputCornerRadius
        self.borderOpacity = borderOpacity
    }

    public static var `default`: ThemeBorders { ThemeBorders() }
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
    public var messages: ThemeMessages
    public var borders: ThemeBorders

    /// Syntax highlighting theme name (Highlightr). nil = auto (dark/light).
    public var codeHighlightTheme: String?

    /// Optional library provenance. Missing values are treated as local
    /// custom themes, while built-in presets are always classified as built-in.
    public var library: ThemeLibraryInfo?

    /// Whether this is a built-in theme (cannot be deleted)
    public var isBuiltIn: Bool
    public var isDark: Bool

    public init(
        metadata: ThemeMetadata = ThemeMetadata(),
        colors: ThemeColors = ThemeColors(),
        background: ThemeBackground = .default,
        glass: ThemeGlass = ThemeGlass(),
        typography: ThemeTypography = ThemeTypography(),
        animationConfig: ThemeAnimation = ThemeAnimation(),
        shadows: ThemeShadows = ThemeShadows(),
        messages: ThemeMessages = ThemeMessages(),
        borders: ThemeBorders = ThemeBorders(),
        codeHighlightTheme: String? = nil,
        library: ThemeLibraryInfo? = nil,
        isBuiltIn: Bool = false,
        isDark: Bool = true
    ) {
        self.metadata = metadata
        self.colors = colors
        self.background = background
        self.glass = glass
        self.typography = typography
        self.animationConfig = animationConfig
        self.shadows = shadows
        self.messages = messages
        self.borders = borders
        self.codeHighlightTheme = codeHighlightTheme
        self.library = library
        self.isBuiltIn = isBuiltIn
        self.isDark = isDark
    }

    /// Backward-compatible decoding: new fields fall back to defaults if missing
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decode(ThemeMetadata.self, forKey: .metadata)
        colors = try container.decode(ThemeColors.self, forKey: .colors)
        background = try container.decode(ThemeBackground.self, forKey: .background)
        glass = try container.decode(ThemeGlass.self, forKey: .glass)
        typography = try container.decode(ThemeTypography.self, forKey: .typography)
        animationConfig = try container.decode(ThemeAnimation.self, forKey: .animationConfig)
        shadows = try container.decode(ThemeShadows.self, forKey: .shadows)
        messages = try container.decodeIfPresent(ThemeMessages.self, forKey: .messages) ?? ThemeMessages()
        borders = try container.decodeIfPresent(ThemeBorders.self, forKey: .borders) ?? ThemeBorders()
        codeHighlightTheme = try container.decodeIfPresent(String.self, forKey: .codeHighlightTheme)
        library = try container.decodeIfPresent(ThemeLibraryInfo.self, forKey: .library)
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        isDark = try container.decode(Bool.self, forKey: .isDark)
    }

    /// Default dark theme
    public static var darkDefault: CustomTheme {
        CustomTheme(
            metadata: ThemeMetadata(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                name: "Dark",
                version: "1.1",
                author: "Osaurus"
            ),
            colors: ThemeColors(
                primaryText: "#ffffea",
                secondaryText: "#b8c4e8",
                tertiaryText: "#98a4d0",
                primaryBackground: "#0e1120",
                secondaryBackground: "#161a2c",
                tertiaryBackground: "#1e2238",
                sidebarBackground: "#0b0e1a",
                sidebarSelectedBackground: "#1c2035",
                accentColor: "#4a6de0",
                accentColorLight: "#7090f5",
                primaryBorder: "#2a3050",
                secondaryBorder: "#3a4260",
                focusBorder: "#4a6de0",
                successColor: "#68d735",
                warningColor: "#fbbf24",
                errorColor: "#ff5b32",
                infoColor: "#4a6de0",
                cardBackground: "#161a2c",
                cardBorder: "#2a3050",
                buttonBackground: "#1e2238",
                buttonBorder: "#3a4260",
                inputBackground: "#0e1120",
                inputBorder: "#3a4260",
                glassTintOverlay: "#0e112060",
                codeBlockBackground: "#0b0e1a",
                shadowColor: "#000000",
                selectionColor: "#4a6de040",
                cursorColor: "#ffffea",
                placeholderText: "#7888b8"
            ),
            background: .default,
            glass: ThemeGlass(
                enabled: false,
                material: .hudWindow,
                blurRadius: 30,
                opacityPrimary: 0.10,
                opacitySecondary: 0.08,
                opacityTertiary: 0.05,
                edgeLight: "#ffffff33",
                windowBackingOpacity: 0.55
            ),
            typography: .default,
            animationConfig: .default,
            shadows: ThemeShadows(
                shadowOpacity: 0.3,
                cardShadowRadius: 12,
                cardShadowRadiusHover: 20,
                cardShadowY: 4,
                cardShadowYHover: 8
            ),
            messages: ThemeMessages(
                bubbleCornerRadius: 20,
                userBubbleOpacity: 0.3,
                assistantBubbleOpacity: 0.85,
                borderWidth: 0.5,
                showEdgeLight: true
            ),
            borders: ThemeBorders(
                defaultWidth: 1,
                cardCornerRadius: 12,
                inputCornerRadius: 8,
                borderOpacity: 0.3
            ),
            isBuiltIn: true,
            isDark: true
        )
    }

    /// Default light theme
    public static var lightDefault: CustomTheme {
        CustomTheme(
            metadata: ThemeMetadata(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                name: "Light",
                version: "1.1",
                author: "Osaurus"
            ),
            colors: ThemeColors(
                primaryText: "#181e38",
                secondaryText: "#3d4f7a",
                tertiaryText: "#5a6b99",
                primaryBackground: "#ffffea",
                secondaryBackground: "#f5f5d8",
                tertiaryBackground: "#ebebc8",
                sidebarBackground: "#f8f8e0",
                sidebarSelectedBackground: "#ebebce",
                accentColor: "#214099",
                accentColorLight: "#3a5ab8",
                primaryBorder: "#8890aa",
                secondaryBorder: "#b8bcd0",
                focusBorder: "#214099",
                successColor: "#2d6e10",
                warningColor: "#a16207",
                errorColor: "#d44010",
                infoColor: "#214099",
                cardBackground: "#ffffea",
                cardBorder: "#8890aa",
                buttonBackground: "#214099",
                buttonBorder: "#214099",
                inputBackground: "#ffffff",
                inputBorder: "#8890aa",
                glassTintOverlay: "#ffffea50",
                codeBlockBackground: "#f0f0d4",
                shadowColor: "#214099",
                selectionColor: "#21409940",
                cursorColor: "#214099",
                placeholderText: "#8890aa"
            ),
            background: .default,
            glass: ThemeGlass(
                enabled: false,
                material: .hudWindow,
                blurRadius: 20,
                opacityPrimary: 0.15,
                opacitySecondary: 0.10,
                opacityTertiary: 0.05,
                edgeLight: "#ffffff4d",
                windowBackingOpacity: 0.65
            ),
            typography: .default,
            animationConfig: .default,
            shadows: ThemeShadows(
                shadowOpacity: 0.05,
                cardShadowRadius: 8,
                cardShadowRadiusHover: 16,
                cardShadowY: 2,
                cardShadowYHover: 6
            ),
            messages: ThemeMessages(
                bubbleCornerRadius: 20,
                userBubbleOpacity: 0.25,
                assistantBubbleOpacity: 0.9,
                borderWidth: 0.5,
                showEdgeLight: true
            ),
            borders: ThemeBorders(
                defaultWidth: 1,
                cardCornerRadius: 12,
                inputCornerRadius: 8,
                borderOpacity: 0.25
            ),
            isBuiltIn: true,
            isDark: false
        )
    }

    /// Cyberpunk Neon theme - vibrant colors on dark background (WCAG AA compliant)
    public static var neonPreset: CustomTheme {
        CustomTheme(
            metadata: ThemeMetadata(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                name: "Neon",
                author: "Osaurus"
            ),
            colors: ThemeColors(
                primaryText: "#f0f0f0",  // ~18:1 contrast ✓
                secondaryText: "#b0b0b0",  // ~9:1 contrast ✓ (was #a0a0a0)
                tertiaryText: "#909090",  // ~5.5:1 contrast ✓ (was #707070, ~3.2:1)
                primaryBackground: "#0a0a14",
                secondaryBackground: "#12121f",
                tertiaryBackground: "#1a1a2e",
                sidebarBackground: "#0e0e1a",
                sidebarSelectedBackground: "#1f1f35",
                accentColor: "#ff00ff",
                accentColorLight: "#ff66ff",
                primaryBorder: "#3a3a55",  // Improved visibility (was #2a2a40)
                secondaryBorder: "#4a4a65",  // Improved visibility (was #3a3a55)
                focusBorder: "#ff00ff",
                successColor: "#00ff88",  // High contrast on dark ✓
                warningColor: "#ffcc00",  // Brighter yellow ✓ (was #ffaa00)
                errorColor: "#ff6688",  // Brighter for visibility (was #ff3366)
                infoColor: "#00ddff",  // Brighter cyan (was #00ccff)
                cardBackground: "#12121f",
                cardBorder: "#3a3a55",  // Improved visibility
                buttonBackground: "#1a1a2e",
                buttonBorder: "#4a4a65",  // Improved visibility
                inputBackground: "#0e0e1a",
                inputBorder: "#3a3a55",  // Improved visibility (was #2a2a40)
                glassTintOverlay: "#ff00ff15",
                codeBlockBackground: "#00000050",
                shadowColor: "#ff00ff",
                selectionColor: "#ff00ff60",
                cursorColor: "#ff00ff"
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
            messages: ThemeMessages(
                bubbleCornerRadius: 24,
                userBubbleOpacity: 0.4,
                assistantBubbleOpacity: 0.8,
                borderWidth: 0.5,
                showEdgeLight: true
            ),
            borders: ThemeBorders(
                defaultWidth: 1.0,
                cardCornerRadius: 16,
                inputCornerRadius: 10,
                borderOpacity: 0.35
            ),
            isBuiltIn: true,
            isDark: true
        )
    }

    /// Nord theme - Arctic, north-bluish color palette (WCAG AA compliant)
    public static var nordPreset: CustomTheme {
        CustomTheme(
            metadata: ThemeMetadata(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                name: "Nord",
                author: "Osaurus"
            ),
            colors: ThemeColors(
                primaryText: "#eceff4",  // ~10:1 contrast ✓
                secondaryText: "#d8dee9",  // ~7:1 contrast ✓
                tertiaryText: "#b8c4d4",  // ~5:1 contrast ✓ (was #a3b1c2, ~4.2:1)
                primaryBackground: "#2e3440",
                secondaryBackground: "#3b4252",
                tertiaryBackground: "#434c5e",
                sidebarBackground: "#2e3440",
                sidebarSelectedBackground: "#434c5e",
                accentColor: "#88c0d0",  // Good contrast on Nord backgrounds
                accentColorLight: "#8fbcbb",
                primaryBorder: "#5c667a",  // Improved visibility (was #4c566a)
                secondaryBorder: "#4c566a",  // (was #434c5e)
                focusBorder: "#88c0d0",
                successColor: "#a3be8c",  // Good contrast ✓
                warningColor: "#ebcb8b",  // Good on dark ✓
                errorColor: "#d08770",  // Better contrast (was #bf616a)
                infoColor: "#88c0d0",  // Better visibility (was #81a1c1)
                cardBackground: "#3b4252",
                cardBorder: "#5c667a",  // Improved visibility
                buttonBackground: "#434c5e",
                buttonBorder: "#5c667a",  // Improved visibility
                inputBackground: "#3b4252",
                inputBorder: "#5c667a",  // Improved visibility (was #4c566a)
                glassTintOverlay: "#88c0d010",
                codeBlockBackground: "#2e344080",
                shadowColor: "#000000",
                selectionColor: "#88c0d060",
                cursorColor: "#88c0d0"
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
            messages: ThemeMessages(
                bubbleCornerRadius: 18,
                userBubbleOpacity: 0.3,
                assistantBubbleOpacity: 0.85,
                borderWidth: 0.5,
                showEdgeLight: true
            ),
            borders: .default,
            isBuiltIn: true,
            isDark: true
        )
    }

    /// Paper theme - Warm, sepia-toned light theme (WCAG AA compliant)
    public static var paperPreset: CustomTheme {
        CustomTheme(
            metadata: ThemeMetadata(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
                name: "Paper",
                author: "Osaurus"
            ),
            colors: ThemeColors(
                primaryText: "#3d3d3d",  // ~9:1 contrast ✓
                secondaryText: "#555555",  // ~7:1 contrast ✓ (was #6b6b6b, ~5:1)
                tertiaryText: "#737373",  // ~5:1 contrast ✓ (was #9a9a9a, ~2.8:1)
                primaryBackground: "#faf8f5",
                secondaryBackground: "#f5f2ed",
                tertiaryBackground: "#ebe7e0",
                sidebarBackground: "#f0ece5",
                sidebarSelectedBackground: "#e5e0d8",
                accentColor: "#9a7b30",  // Darker gold ~4.5:1 ✓ (was #c9a959, ~2.5:1)
                accentColorLight: "#b8923f",
                primaryBorder: "#c5c0b8",  // Improved visibility (was #e0dcd5)
                secondaryBorder: "#d5d0c8",  // (was #ebe7e0)
                focusBorder: "#9a7b30",
                successColor: "#4d7c3a",  // ~4.5:1 on cream ✓ (was #7fb069, ~2.5:1)
                warningColor: "#9a6a1a",  // ~4.5:1 on cream ✓ (was #e6a23c, ~2.3:1)
                errorColor: "#b54545",  // ~4.5:1 on cream ✓ (was #d56060, ~3.2:1)
                infoColor: "#4a7899",  // ~4.5:1 on cream ✓ (was #6b9bc3, ~3:1)
                cardBackground: "#ffffff",
                cardBorder: "#c5c0b8",  // Improved visibility
                buttonBackground: "#f5f2ed",
                buttonBorder: "#a5a099",  // ~3:1 for UI ✓ (was #d5d0c8, ~1.6:1)
                inputBackground: "#ffffff",
                inputBorder: "#a5a099",  // ~3:1 for UI ✓ (was #d5d0c8, ~1.6:1)
                glassTintOverlay: "#9a7b3010",
                codeBlockBackground: "#f0ece520",
                shadowColor: "#8b7355",
                selectionColor: "#9a7b3050",
                cursorColor: "#9a7b30"
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
            messages: ThemeMessages(
                bubbleCornerRadius: 16,
                userBubbleOpacity: 0.2,
                assistantBubbleOpacity: 0.9,
                borderWidth: 0.5,
                showEdgeLight: false
            ),
            borders: ThemeBorders(
                defaultWidth: 1.0,
                cardCornerRadius: 10,
                inputCornerRadius: 6,
                borderOpacity: 0.2
            ),
            isBuiltIn: true,
            isDark: false
        )
    }

    /// Terminal theme - Classic CRT terminal aesthetic with phosphor green on black
    public static var terminalPreset: CustomTheme {
        CustomTheme(
            metadata: ThemeMetadata(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
                name: "Terminal",
                author: "Osaurus"
            ),
            colors: ThemeColors(
                primaryText: "#00ff41",  // Classic phosphor green
                secondaryText: "#00cc33",  // Slightly dimmer green
                tertiaryText: "#00aa2a",  // Even dimmer for tertiary
                primaryBackground: "#0c0c0c",  // Rich black
                secondaryBackground: "#0f0f0f",  // Slightly lighter black
                tertiaryBackground: "#141414",  // Card/elevated surfaces
                sidebarBackground: "#0a0a0a",  // Deepest black for sidebar
                sidebarSelectedBackground: "#1a1a1a",  // Subtle highlight
                accentColor: "#00ff41",  // Phosphor green accent
                accentColorLight: "#33ff66",  // Brighter green for hover
                primaryBorder: "#1a3a1a",  // Dark green border
                secondaryBorder: "#0d1f0d",  // Subtle green border
                focusBorder: "#00ff41",  // Bright green focus
                successColor: "#00ff41",  // Green (matches theme)
                warningColor: "#ffb000",  // Amber (classic terminal warning)
                errorColor: "#ff3333",  // Red error
                infoColor: "#00cc33",  // Green info
                cardBackground: "#111111",  // Slightly elevated
                cardBorder: "#1a3a1a",  // Green-tinted border
                buttonBackground: "#0f0f0f",
                buttonBorder: "#00ff41",  // Green border for buttons
                inputBackground: "#0a0a0a",  // Deep black input
                inputBorder: "#1a3a1a",  // Green-tinted border
                glassTintOverlay: "#00ff4108",  // Subtle green tint
                codeBlockBackground: "#0a0a0a",  // Deep black for code
                shadowColor: "#00ff41",  // Green glow for shadows
                selectionColor: "#00ff4140",  // Green selection
                cursorColor: "#00ff41",  // Bright green cursor
                placeholderText: "#00aa2a"  // Dim green placeholder
            ),
            background: .default,
            glass: ThemeGlass(
                enabled: false,  // Solid backgrounds for authentic terminal look
                material: .hudWindow,
                blurRadius: 0,
                opacityPrimary: 0.0,
                opacitySecondary: 0.0,
                opacityTertiary: 0.0,
                tintColor: "#00ff41",
                tintOpacity: 0.02,
                edgeLight: "#00ff4120"  // Subtle green edge glow
            ),
            typography: ThemeTypography(
                primaryFont: "SF Mono",  // Monospace for all text
                monoFont: "SF Mono",
                titleSize: 24,
                headingSize: 16,
                bodySize: 14,
                captionSize: 12,
                codeSize: 14
            ),
            animationConfig: ThemeAnimation(
                durationQuick: 0.1,  // Snappy, instant feel
                durationMedium: 0.2,
                durationSlow: 0.3,
                springResponse: 0.3,
                springDamping: 0.9  // Minimal bounce
            ),
            shadows: ThemeShadows(
                shadowOpacity: 0.5,  // Stronger for glow effect
                cardShadowRadius: 12,  // Soft green glow
                cardShadowRadiusHover: 20,
                cardShadowY: 0,  // No vertical offset (glow, not drop shadow)
                cardShadowYHover: 0
            ),
            messages: ThemeMessages(
                bubbleCornerRadius: 4,
                userBubbleOpacity: 0.25,
                assistantBubbleOpacity: 0.7,
                borderWidth: 1.0,
                showEdgeLight: true
            ),
            borders: ThemeBorders(
                defaultWidth: 1.0,
                cardCornerRadius: 4,
                inputCornerRadius: 4,
                borderOpacity: 0.4
            ),
            isBuiltIn: true,
            isDark: true
        )
    }

    /// All built-in theme presets
    public static var allBuiltInPresets: [CustomTheme] {
        [.darkDefault, .lightDefault, .neonPreset, .nordPreset, .paperPreset, .terminalPreset]
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

        Color.themeHexCacheLock.lock()
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

        if includeAlpha && a < 255 {
            return String(format: "#%02X%02X%02X%02X", a, r, g, b)
        }
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
