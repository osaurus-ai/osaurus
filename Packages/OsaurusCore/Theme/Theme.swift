//
//  Theme.swift
//  osaurus
//
//  Modern minimalistic theme system with dark/light mode support
//  Extended with full customization support for backgrounds, glass effects, and typography
//

import AppKit
import SwiftUI

// MARK: - Theme Protocol

protocol ThemeProtocol {
    // Primary colors
    var primaryText: Color { get }
    var secondaryText: Color { get }
    var tertiaryText: Color { get }

    // Background colors
    var primaryBackground: Color { get }
    var secondaryBackground: Color { get }
    var tertiaryBackground: Color { get }

    // Sidebar colors
    var sidebarBackground: Color { get }
    var sidebarSelectedBackground: Color { get }

    // Accent colors
    var accentColor: Color { get }
    var accentColorLight: Color { get }

    // Border colors
    var primaryBorder: Color { get }
    var secondaryBorder: Color { get }
    var focusBorder: Color { get }

    // Status colors
    var successColor: Color { get }
    var warningColor: Color { get }
    var errorColor: Color { get }
    var infoColor: Color { get }

    // Component specific
    var cardBackground: Color { get }
    var cardBorder: Color { get }
    var buttonBackground: Color { get }
    var buttonBorder: Color { get }
    var inputBackground: Color { get }
    var inputBorder: Color { get }
    // Glass / Code styling
    var glassTintOverlay: Color { get }
    var codeBlockBackground: Color { get }

    // Glass specific
    var glassOpacityPrimary: Double { get }
    var glassOpacitySecondary: Double { get }
    var glassOpacityTertiary: Double { get }
    var glassBlurRadius: Double { get }
    var glassEdgeLight: Color { get }
    var glassMaterial: NSVisualEffectView.Material { get }
    var glassTintColor: Color? { get }
    var glassTintOpacity: Double { get }

    // Card shadows (enhanced)
    var cardShadowRadius: Double { get }
    var cardShadowRadiusHover: Double { get }
    var cardShadowY: Double { get }
    var cardShadowYHover: Double { get }

    // Animation timing
    var animationDurationQuick: Double { get }
    var animationDurationMedium: Double { get }
    var animationDurationSlow: Double { get }
    var animationSpring: Animation { get }

    // Shadows
    var shadowColor: Color { get }
    var shadowOpacity: Double { get }

    // Background customization
    var backgroundImage: NSImage? { get }
    var backgroundImageOpacity: Double { get }
    var backgroundOverlayColor: Color? { get }
    var backgroundOverlayOpacity: Double { get }

    // Typography
    var primaryFontName: String { get }
    var monoFontName: String { get }
    var titleSize: Double { get }
    var headingSize: Double { get }
    var bodySize: Double { get }
    var captionSize: Double { get }
    var codeSize: Double { get }

    // Custom theme reference (for editing)
    var customThemeConfig: CustomTheme? { get }
}

// MARK: - Default Protocol Extensions

extension ThemeProtocol {
    // Provide defaults for new properties so existing themes don't break
    var glassMaterial: NSVisualEffectView.Material { .hudWindow }
    var glassTintColor: Color? { nil }
    var glassTintOpacity: Double { 0 }

    var backgroundImage: NSImage? { nil }
    var backgroundImageOpacity: Double { 1.0 }
    var backgroundOverlayColor: Color? { nil }
    var backgroundOverlayOpacity: Double { 0 }

    var primaryFontName: String { "SF Pro" }
    var monoFontName: String { "SF Mono" }
    var titleSize: Double { 28 }
    var headingSize: Double { 18 }
    var bodySize: Double { 14 }
    var captionSize: Double { 12 }
    var codeSize: Double { 13 }

    var customThemeConfig: CustomTheme? { nil }

    // MARK: - Font Helpers

    /// Creates a font using the theme's primary font family
    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if primaryFontName.lowercased().contains("sf pro") || primaryFontName.isEmpty {
            return .system(size: size, weight: weight)
        }
        let weightedName = resolveWeightedFontName(primaryFontName, weight: weight)
        return .custom(weightedName, size: size)
    }

    /// Creates a monospace font using the theme's mono font family
    func monoFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if monoFontName.lowercased().contains("sf mono") || monoFontName.isEmpty {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        let weightedName = resolveWeightedFontName(monoFontName, weight: weight)
        return .custom(weightedName, size: size)
    }

    private func resolveWeightedFontName(_ baseName: String, weight: Font.Weight) -> String {
        let weightSuffix: String
        switch weight {
        case .ultraLight: weightSuffix = "-UltraLight"
        case .thin: weightSuffix = "-Thin"
        case .light: weightSuffix = "-Light"
        case .regular: weightSuffix = ""
        case .medium: weightSuffix = "-Medium"
        case .semibold: weightSuffix = "-SemiBold"
        case .bold: weightSuffix = "-Bold"
        case .heavy: weightSuffix = "-Heavy"
        case .black: weightSuffix = "-Black"
        default: weightSuffix = ""
        }
        let cleanName = baseName.replacingOccurrences(of: " ", with: "")
        return cleanName + weightSuffix
    }
}

// MARK: - Light Theme

struct LightTheme: ThemeProtocol {
    // Primary colors
    let primaryText = Color(hex: "1a1a1a")
    let secondaryText = Color(hex: "6b7280")
    let tertiaryText = Color(hex: "9ca3af")

    // Background colors
    let primaryBackground = Color(hex: "ffffff")
    let secondaryBackground = Color(hex: "f9fafb")
    let tertiaryBackground = Color(hex: "f3f4f6")

    // Sidebar colors
    let sidebarBackground = Color(hex: "f5f5f7")
    let sidebarSelectedBackground = Color(hex: "e8e8ed")

    // Accent colors
    let accentColor = Color(hex: "3b82f6")
    let accentColorLight = Color(hex: "60a5fa")

    // Border colors
    let primaryBorder = Color(hex: "e5e7eb")
    let secondaryBorder = Color(hex: "f3f4f6")
    let focusBorder = Color(hex: "3b82f6")

    // Status colors
    let successColor = Color(hex: "10b981")
    let warningColor = Color(hex: "f59e0b")
    let errorColor = Color(hex: "ef4444")
    let infoColor = Color(hex: "3b82f6")

    // Component specific
    let cardBackground = Color(hex: "ffffff")
    let cardBorder = Color(hex: "e5e7eb")
    let buttonBackground = Color(hex: "ffffff")
    let buttonBorder = Color(hex: "d1d5db")
    let inputBackground = Color(hex: "ffffff")
    let inputBorder = Color(hex: "d1d5db")
    let glassTintOverlay = Color.black.opacity(0.12)
    let codeBlockBackground = Color.black.opacity(0.08)

    // Glass specific
    let glassOpacityPrimary: Double = 0.15
    let glassOpacitySecondary: Double = 0.10
    let glassOpacityTertiary: Double = 0.05
    let glassBlurRadius: Double = 20
    let glassEdgeLight = Color.white.opacity(0.3)

    // Card shadows (enhanced)
    let cardShadowRadius: Double = 8
    let cardShadowRadiusHover: Double = 16
    let cardShadowY: Double = 2
    let cardShadowYHover: Double = 6

    // Animation timing
    let animationDurationQuick: Double = 0.2
    let animationDurationMedium: Double = 0.3
    let animationDurationSlow: Double = 0.4
    let animationSpring = Animation.spring(response: 0.4, dampingFraction: 0.8)

    // Shadows
    let shadowColor = Color.black
    let shadowOpacity: Double = 0.05
}

// MARK: - Dark Theme

struct DarkTheme: ThemeProtocol {
    // Primary colors
    let primaryText = Color(hex: "f9fafb")
    let secondaryText = Color(hex: "9ca3af")
    let tertiaryText = Color(hex: "6b7280")

    // Background colors
    let primaryBackground = Color(hex: "0f0f10")
    let secondaryBackground = Color(hex: "18181b")
    let tertiaryBackground = Color(hex: "27272a")

    // Sidebar colors
    let sidebarBackground = Color(hex: "141416")
    let sidebarSelectedBackground = Color(hex: "2a2a2e")

    // Accent colors
    let accentColor = Color(hex: "3b82f6")
    let accentColorLight = Color(hex: "60a5fa")

    // Border colors
    let primaryBorder = Color(hex: "27272a")
    let secondaryBorder = Color(hex: "3f3f46")
    let focusBorder = Color(hex: "3b82f6")

    // Status colors
    let successColor = Color(hex: "10b981")
    let warningColor = Color(hex: "f59e0b")
    let errorColor = Color(hex: "ef4444")
    let infoColor = Color(hex: "3b82f6")

    // Component specific
    let cardBackground = Color(hex: "18181b")
    let cardBorder = Color(hex: "3f3f46")
    let buttonBackground = Color(hex: "18181b")
    let buttonBorder = Color(hex: "3f3f46")
    let inputBackground = Color(hex: "18181b")
    let inputBorder = Color(hex: "3f3f46")
    let glassTintOverlay = Color.black.opacity(0.18)
    let codeBlockBackground = Color.black.opacity(0.35)

    // Glass specific
    let glassOpacityPrimary: Double = 0.10
    let glassOpacitySecondary: Double = 0.08
    let glassOpacityTertiary: Double = 0.05
    let glassBlurRadius: Double = 30
    let glassEdgeLight = Color.white.opacity(0.2)

    // Card shadows (enhanced)
    let cardShadowRadius: Double = 12
    let cardShadowRadiusHover: Double = 20
    let cardShadowY: Double = 4
    let cardShadowYHover: Double = 8

    // Animation timing
    let animationDurationQuick: Double = 0.2
    let animationDurationMedium: Double = 0.3
    let animationDurationSlow: Double = 0.4
    let animationSpring = Animation.spring(response: 0.4, dampingFraction: 0.8)

    // Shadows
    let shadowColor = Color.black
    let shadowOpacity: Double = 0.3
}

// MARK: - Customizable Theme (Wraps CustomTheme)

/// A theme implementation that wraps a CustomTheme configuration
struct CustomizableTheme: ThemeProtocol {
    let config: CustomTheme

    init(config: CustomTheme) {
        self.config = config
    }

    // Primary colors
    var primaryText: Color { Color(themeHex: config.colors.primaryText) }
    var secondaryText: Color { Color(themeHex: config.colors.secondaryText) }
    var tertiaryText: Color { Color(themeHex: config.colors.tertiaryText) }

    // Background colors
    var primaryBackground: Color { Color(themeHex: config.colors.primaryBackground) }
    var secondaryBackground: Color { Color(themeHex: config.colors.secondaryBackground) }
    var tertiaryBackground: Color { Color(themeHex: config.colors.tertiaryBackground) }

    // Sidebar colors
    var sidebarBackground: Color { Color(themeHex: config.colors.sidebarBackground) }
    var sidebarSelectedBackground: Color { Color(themeHex: config.colors.sidebarSelectedBackground) }

    // Accent colors
    var accentColor: Color { Color(themeHex: config.colors.accentColor) }
    var accentColorLight: Color { Color(themeHex: config.colors.accentColorLight) }

    // Border colors
    var primaryBorder: Color { Color(themeHex: config.colors.primaryBorder) }
    var secondaryBorder: Color { Color(themeHex: config.colors.secondaryBorder) }
    var focusBorder: Color { Color(themeHex: config.colors.focusBorder) }

    // Status colors
    var successColor: Color { Color(themeHex: config.colors.successColor) }
    var warningColor: Color { Color(themeHex: config.colors.warningColor) }
    var errorColor: Color { Color(themeHex: config.colors.errorColor) }
    var infoColor: Color { Color(themeHex: config.colors.infoColor) }

    // Component specific
    var cardBackground: Color { Color(themeHex: config.colors.cardBackground) }
    var cardBorder: Color { Color(themeHex: config.colors.cardBorder) }
    var buttonBackground: Color { Color(themeHex: config.colors.buttonBackground) }
    var buttonBorder: Color { Color(themeHex: config.colors.buttonBorder) }
    var inputBackground: Color { Color(themeHex: config.colors.inputBackground) }
    var inputBorder: Color { Color(themeHex: config.colors.inputBorder) }
    var glassTintOverlay: Color { Color(themeHex: config.colors.glassTintOverlay) }
    var codeBlockBackground: Color { Color(themeHex: config.colors.codeBlockBackground) }

    // Glass specific
    var glassOpacityPrimary: Double { config.glass.opacityPrimary }
    var glassOpacitySecondary: Double { config.glass.opacitySecondary }
    var glassOpacityTertiary: Double { config.glass.opacityTertiary }
    var glassBlurRadius: Double { config.glass.blurRadius }
    var glassEdgeLight: Color { Color(themeHex: config.glass.edgeLight) }
    var glassMaterial: NSVisualEffectView.Material { config.glass.material.nsMaterial }
    var glassTintColor: Color? {
        guard let tint = config.glass.tintColor else { return nil }
        return Color(themeHex: tint)
    }
    var glassTintOpacity: Double { config.glass.tintOpacity ?? 0 }

    // Card shadows
    var cardShadowRadius: Double { config.shadows.cardShadowRadius }
    var cardShadowRadiusHover: Double { config.shadows.cardShadowRadiusHover }
    var cardShadowY: Double { config.shadows.cardShadowY }
    var cardShadowYHover: Double { config.shadows.cardShadowYHover }

    // Animation timing
    var animationDurationQuick: Double { config.animationConfig.durationQuick }
    var animationDurationMedium: Double { config.animationConfig.durationMedium }
    var animationDurationSlow: Double { config.animationConfig.durationSlow }
    var animationSpring: Animation { config.animationConfig.spring }

    // Shadows
    var shadowColor: Color { Color(themeHex: config.colors.shadowColor) }
    var shadowOpacity: Double { config.shadows.shadowOpacity }

    // Background customization
    var backgroundImage: NSImage? { config.background.decodedImage() }
    var backgroundImageOpacity: Double { config.background.imageOpacity ?? 1.0 }
    var backgroundOverlayColor: Color? {
        guard let overlay = config.background.overlayColor else { return nil }
        return Color(themeHex: overlay)
    }
    var backgroundOverlayOpacity: Double { config.background.overlayOpacity ?? 0 }

    // Typography
    var primaryFontName: String { config.typography.primaryFont }
    var monoFontName: String { config.typography.monoFont }
    var titleSize: Double { config.typography.titleSize }
    var headingSize: Double { config.typography.headingSize }
    var bodySize: Double { config.typography.bodySize }
    var captionSize: Double { config.typography.captionSize }
    var codeSize: Double { config.typography.codeSize }

    // Custom theme reference
    var customThemeConfig: CustomTheme? { config }
}

// MARK: - Theme Manager

@MainActor
class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var currentTheme: ThemeProtocol
    @Published private(set) var appearanceMode: AppearanceMode = .system
    @Published private(set) var activeCustomTheme: CustomTheme?
    @Published private(set) var installedThemes: [CustomTheme] = []

    /// Whether a custom theme is currently active
    var isCustomThemeActive: Bool { activeCustomTheme != nil }

    private init() {
        // Install built-in themes if needed
        ThemeConfigurationStore.installBuiltInThemesIfNeeded()

        // Load installed themes
        installedThemes = ThemeConfigurationStore.listThemes()

        // Load saved appearance mode
        let config = ServerConfigurationStore.load() ?? ServerConfiguration.default
        appearanceMode = config.appearanceMode

        // Check for active custom theme
        if let customTheme = ThemeConfigurationStore.loadActiveTheme() {
            activeCustomTheme = customTheme
            currentTheme = CustomizableTheme(config: customTheme)
        } else {
            // Initialize currentTheme based on appearance mode
            currentTheme = Self.resolveTheme(for: config.appearanceMode)
        }

        // Observe system appearance changes (Distributed Notification)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    /// Update the appearance mode and apply the theme
    func setAppearanceMode(_ mode: AppearanceMode) {
        appearanceMode = mode

        // If a custom theme is active, don't change it based on appearance mode
        guard activeCustomTheme == nil else { return }

        withAnimation(.easeInOut(duration: 0.3)) {
            currentTheme = Self.resolveTheme(for: mode)
        }
    }

    /// Apply a custom theme
    func applyCustomTheme(_ theme: CustomTheme) {
        activeCustomTheme = theme
        ThemeConfigurationStore.saveActiveThemeId(theme.metadata.id)

        withAnimation(.easeInOut(duration: 0.3)) {
            currentTheme = CustomizableTheme(config: theme)
        }
    }

    /// Clear custom theme and revert to system appearance
    func clearCustomTheme() {
        activeCustomTheme = nil
        ThemeConfigurationStore.saveActiveThemeId(nil)

        withAnimation(.easeInOut(duration: 0.3)) {
            currentTheme = Self.resolveTheme(for: appearanceMode)
        }
    }

    /// Refresh the list of installed themes
    func refreshInstalledThemes() {
        installedThemes = ThemeConfigurationStore.listThemes()
    }

    /// Save a theme and refresh the list
    func saveTheme(_ theme: CustomTheme) {
        ThemeConfigurationStore.saveTheme(theme)
        refreshInstalledThemes()

        // If this is the active theme, update it
        if activeCustomTheme?.metadata.id == theme.metadata.id {
            applyCustomTheme(theme)
        }
    }

    /// Delete a theme
    func deleteTheme(id: UUID) {
        ThemeConfigurationStore.deleteTheme(id: id)
        refreshInstalledThemes()

        // If this was the active theme, clear it
        if activeCustomTheme?.metadata.id == id {
            clearCustomTheme()
        }
    }

    /// Resolve the theme based on appearance mode
    private static func resolveTheme(for mode: AppearanceMode) -> ThemeProtocol {
        switch mode {
        case .system:
            return (NSApp.effectiveAppearance.name == .darkAqua) ? DarkTheme() : LightTheme()
        case .light:
            return LightTheme()
        case .dark:
            return DarkTheme()
        }
    }

    @objc private func systemAppearanceChanged() {
        // Only update if we're following system appearance and no custom theme is active
        guard appearanceMode == .system, activeCustomTheme == nil else { return }

        withAnimation(.easeInOut(duration: 0.3)) {
            currentTheme = Self.resolveTheme(for: .system)
        }
    }
}

// MARK: - Theme Environment Key

struct ThemeEnvironmentKey: EnvironmentKey {
    // Use a computed property to avoid storing a non-Sendable static globally
    static var defaultValue: ThemeProtocol { LightTheme() }
}

extension EnvironmentValues {
    var theme: ThemeProtocol {
        get { self[ThemeEnvironmentKey.self] }
        set { self[ThemeEnvironmentKey.self] = newValue }
    }
}

// MARK: - View Extension

extension View {
    func themedBackground(_ style: ThemedBackgroundStyle = .primary) -> some View {
        self.modifier(ThemedBackgroundModifier(style: style))
    }

    func themedCard() -> some View {
        self.modifier(ThemedCardModifier())
    }
}

// MARK: - Themed Background Styles

enum ThemedBackgroundStyle {
    case primary
    case secondary
    case tertiary
}

// MARK: - Modifiers

struct ThemedBackgroundModifier: ViewModifier {
    @StateObject private var themeManager = ThemeManager.shared
    let style: ThemedBackgroundStyle

    func body(content: Content) -> some View {
        content
            .background(backgroundColor)
            .environment(\.theme, themeManager.currentTheme)
    }

    private var backgroundColor: Color {
        switch style {
        case .primary:
            return themeManager.currentTheme.primaryBackground
        case .secondary:
            return themeManager.currentTheme.secondaryBackground
        case .tertiary:
            return themeManager.currentTheme.tertiaryBackground
        }
    }
}

struct ThemedCardModifier: ViewModifier {
    @StateObject private var themeManager = ThemeManager.shared

    func body(content: Content) -> some View {
        content
            .background(themeManager.currentTheme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(themeManager.currentTheme.cardBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(
                color: themeManager.currentTheme.shadowColor.opacity(
                    themeManager.currentTheme.shadowOpacity
                ),
                radius: 8,
                x: 0,
                y: 2
            )
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
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
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
