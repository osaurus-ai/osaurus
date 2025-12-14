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

    // Selection (text highlight)
    var selectionColor: Color { get }

    // Glass specific
    var glassEnabled: Bool { get }
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
    var animationSpringResponse: Double { get }
    var animationSpringDamping: Double { get }
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
    var glassEnabled: Bool { true }
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
        // Use Font.custom with family name - SwiftUI handles weight variants
        return .custom(primaryFontName, size: size).weight(weight)
    }

    /// Creates a monospace font using the theme's mono font family
    func monoFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if monoFontName.lowercased().contains("sf mono") || monoFontName.isEmpty {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        // Use Font.custom with family name - SwiftUI handles weight variants
        return .custom(monoFontName, size: size).weight(weight)
    }

    // MARK: - Animation Helpers

    /// Quick animation using theme settings
    func animationQuick() -> Animation {
        .easeInOut(duration: animationDurationQuick)
    }

    /// Medium animation using theme settings
    func animationMedium() -> Animation {
        .easeInOut(duration: animationDurationMedium)
    }

    /// Slow animation using theme settings
    func animationSlow() -> Animation {
        .easeInOut(duration: animationDurationSlow)
    }

    /// Spring animation using theme settings
    func springAnimation() -> Animation {
        .spring(response: animationSpringResponse, dampingFraction: animationSpringDamping)
    }

    /// Spring animation with custom response multiplier
    func springAnimation(responseMultiplier: Double = 1.0, dampingMultiplier: Double = 1.0) -> Animation {
        .spring(
            response: animationSpringResponse * responseMultiplier,
            dampingFraction: min(1.0, animationSpringDamping * dampingMultiplier)
        )
    }
}

// MARK: - Light Theme

struct LightTheme: ThemeProtocol {
    // Primary colors - Warm, rich blacks
    let primaryText = Color(hex: "1a1a18")
    let secondaryText = Color(hex: "6b6b66")
    let tertiaryText = Color(hex: "9c9c96")

    // Background colors - Warm whites with depth
    let primaryBackground = Color(hex: "ffffff")
    let secondaryBackground = Color(hex: "f9f9f7")
    let tertiaryBackground = Color(hex: "f2f2ef")

    // Sidebar colors - Warm and inviting
    let sidebarBackground = Color(hex: "f7f7f5")
    let sidebarSelectedBackground = Color(hex: "eaeae6")

    // Accent colors - Rich warm black
    let accentColor = Color(hex: "1a1a18")
    let accentColorLight = Color(hex: "3d3d3a")

    // Border colors - Warm and subtle
    let primaryBorder = Color(hex: "e8e8e4")
    let secondaryBorder = Color(hex: "f0f0ec")
    let focusBorder = Color(hex: "4a4a46")

    // Status colors - Keep functional
    let successColor = Color(hex: "22c55e")
    let warningColor = Color(hex: "eab308")
    let errorColor = Color(hex: "ef4444")
    let infoColor = Color(hex: "6b6b66")

    // Component specific - Warm and layered
    let cardBackground = Color(hex: "ffffff")
    let cardBorder = Color(hex: "e8e8e4")
    let buttonBackground = Color(hex: "1a1a18")
    let buttonBorder = Color(hex: "1a1a18")
    let inputBackground = Color(hex: "ffffff")
    let inputBorder = Color(hex: "d8d8d4")
    let glassTintOverlay = Color(hex: "f5f5f2").opacity(0.6)
    let codeBlockBackground = Color(hex: "f5f5f2")

    // Selection - Light blue highlight
    let selectionColor = Color(hex: "3b82f6").opacity(0.3)

    // Glass specific - Rich depth
    let glassOpacityPrimary: Double = 0.12
    let glassOpacitySecondary: Double = 0.08
    let glassOpacityTertiary: Double = 0.05
    let glassBlurRadius: Double = 24
    let glassEdgeLight = Color.white.opacity(0.5)

    // Card shadows - Soft and diffuse
    let cardShadowRadius: Double = 12
    let cardShadowRadiusHover: Double = 20
    let cardShadowY: Double = 3
    let cardShadowYHover: Double = 8

    // Animation timing
    let animationDurationQuick: Double = 0.2
    let animationDurationMedium: Double = 0.3
    let animationDurationSlow: Double = 0.4
    let animationSpringResponse: Double = 0.4
    let animationSpringDamping: Double = 0.8
    var animationSpring: Animation {
        .spring(response: animationSpringResponse, dampingFraction: animationSpringDamping)
    }

    // Shadows - Warm and soft
    let shadowColor = Color(hex: "1a1a18")
    let shadowOpacity: Double = 0.08
}

// MARK: - Dark Theme

struct DarkTheme: ThemeProtocol {
    // Primary colors - Warm off-white
    let primaryText = Color(hex: "f5f5f2")
    let secondaryText = Color(hex: "a8a8a3")
    let tertiaryText = Color(hex: "6e6e6a")

    // Background colors - Rich, warm blacks with depth
    let primaryBackground = Color(hex: "0c0c0b")
    let secondaryBackground = Color(hex: "161614")
    let tertiaryBackground = Color(hex: "1e1e1c")

    // Sidebar colors - Deep and warm
    let sidebarBackground = Color(hex: "111110")
    let sidebarSelectedBackground = Color(hex: "222220")

    // Accent colors - Warm cream
    let accentColor = Color(hex: "f0f0eb")
    let accentColorLight = Color(hex: "a8a8a3")

    // Border colors - Warm and subtle
    let primaryBorder = Color(hex: "2a2a28")
    let secondaryBorder = Color(hex: "363633")
    let focusBorder = Color(hex: "8a8a85")

    // Status colors - Keep functional
    let successColor = Color(hex: "22c55e")
    let warningColor = Color(hex: "eab308")
    let errorColor = Color(hex: "ef4444")
    let infoColor = Color(hex: "a8a8a3")

    // Component specific - Layered depth
    let cardBackground = Color(hex: "161614")
    let cardBorder = Color(hex: "2a2a28")
    let buttonBackground = Color(hex: "f0f0eb")
    let buttonBorder = Color(hex: "f0f0eb")
    let inputBackground = Color(hex: "1a1a18")
    let inputBorder = Color(hex: "363633")
    let glassTintOverlay = Color(hex: "1a1a18").opacity(0.7)
    let codeBlockBackground = Color(hex: "1a1a18")

    // Selection - Subtle warm highlight
    let selectionColor = Color(hex: "f0f0eb").opacity(0.25)

    // Glass specific - Rich and premium
    let glassOpacityPrimary: Double = 0.10
    let glassOpacitySecondary: Double = 0.07
    let glassOpacityTertiary: Double = 0.04
    let glassBlurRadius: Double = 28
    let glassEdgeLight = Color.white.opacity(0.08)

    // Card shadows - Soft glow
    let cardShadowRadius: Double = 16
    let cardShadowRadiusHover: Double = 24
    let cardShadowY: Double = 4
    let cardShadowYHover: Double = 10

    // Animation timing
    let animationDurationQuick: Double = 0.2
    let animationDurationMedium: Double = 0.3
    let animationDurationSlow: Double = 0.4
    let animationSpringResponse: Double = 0.4
    let animationSpringDamping: Double = 0.8
    var animationSpring: Animation {
        .spring(response: animationSpringResponse, dampingFraction: animationSpringDamping)
    }

    // Shadows - Deep and rich
    let shadowColor = Color.black
    let shadowOpacity: Double = 0.4
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

    // Selection
    var selectionColor: Color { Color(themeHex: config.colors.selectionColor) }

    // Glass specific
    var glassOpacityPrimary: Double { config.glass.opacityPrimary }
    var glassOpacitySecondary: Double { config.glass.opacitySecondary }
    var glassOpacityTertiary: Double { config.glass.opacityTertiary }
    var glassBlurRadius: Double { config.glass.blurRadius }
    var glassEdgeLight: Color { Color(themeHex: config.glass.edgeLight) }
    var glassEnabled: Bool { config.glass.enabled }
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
    var animationSpringResponse: Double { config.animationConfig.springResponse }
    var animationSpringDamping: Double { config.animationConfig.springDamping }
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
        print("[Osaurus] ThemeManager: Initializing...")

        // Install built-in themes if needed
        ThemeConfigurationStore.installBuiltInThemesIfNeeded()

        // Load installed themes into a local variable first
        let loadedThemes = ThemeConfigurationStore.listThemes()
        print("[Osaurus] ThemeManager: Found \(loadedThemes.count) installed themes")

        // Load saved appearance mode
        let config = ServerConfigurationStore.load() ?? ServerConfiguration.default

        // Initialize all stored properties before using self
        // Check for active custom theme (user-selected)
        if let customTheme = ThemeConfigurationStore.loadActiveTheme() {
            print("[Osaurus] ThemeManager: Restoring active theme '\(customTheme.metadata.name)'")
            self.activeCustomTheme = customTheme
            self.currentTheme = CustomizableTheme(config: customTheme)
        } else {
            // No user-selected theme - use the built-in Dark/Light theme based on appearance mode
            // Don't set activeCustomTheme so appearance mode changes will work
            let builtInTheme = Self.resolveBuiltInTheme(for: config.appearanceMode, from: loadedThemes)
            if let theme = builtInTheme {
                print("[Osaurus] ThemeManager: Using built-in '\(theme.metadata.name)' theme (auto)")
                self.currentTheme = CustomizableTheme(config: theme)
            } else {
                // Fallback to default CustomTheme if built-in themes aren't installed
                print("[Osaurus] ThemeManager: No built-in theme found, using fallback")
                let fallbackTheme =
                    Self.isDarkMode(for: config.appearanceMode) ? CustomTheme.darkDefault : CustomTheme.lightDefault
                self.currentTheme = CustomizableTheme(config: fallbackTheme)
            }
        }

        // Now we can assign to self properties
        self.appearanceMode = config.appearanceMode
        self.installedThemes = loadedThemes

        // Observe system appearance changes (Distributed Notification)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )

        print("[Osaurus] ThemeManager: Initialization complete")
    }

    /// Find the appropriate built-in theme based on appearance mode
    private static func resolveBuiltInTheme(for mode: AppearanceMode, from themes: [CustomTheme]) -> CustomTheme? {
        // Find the built-in Dark or Light theme based on appearance
        let targetId =
            isDarkMode(for: mode)
            ? UUID(uuidString: "00000000-0000-0000-0000-000000000001")  // Dark theme ID
            : UUID(uuidString: "00000000-0000-0000-0000-000000000002")  // Light theme ID

        return themes.first { $0.metadata.id == targetId }
    }

    /// Update the appearance mode and apply the theme
    func setAppearanceMode(_ mode: AppearanceMode) {
        appearanceMode = mode

        // If a user-selected custom theme is active, don't change it based on appearance mode
        guard activeCustomTheme == nil else { return }

        // Apply the appropriate built-in theme
        if let builtInTheme = Self.resolveBuiltInTheme(for: mode, from: installedThemes) {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentTheme = CustomizableTheme(config: builtInTheme)
            }
        } else {
            // Fallback to default CustomTheme
            let fallbackTheme = Self.isDarkMode(for: mode) ? CustomTheme.darkDefault : CustomTheme.lightDefault
            withAnimation(.easeInOut(duration: 0.3)) {
                currentTheme = CustomizableTheme(config: fallbackTheme)
            }
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

        // Apply the appropriate built-in theme based on current appearance mode
        if let builtInTheme = Self.resolveBuiltInTheme(for: appearanceMode, from: installedThemes) {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentTheme = CustomizableTheme(config: builtInTheme)
            }
        } else {
            // Fallback to default CustomTheme
            let fallbackTheme =
                Self.isDarkMode(for: appearanceMode) ? CustomTheme.darkDefault : CustomTheme.lightDefault
            withAnimation(.easeInOut(duration: 0.3)) {
                currentTheme = CustomizableTheme(config: fallbackTheme)
            }
        }
    }

    /// Refresh the list of installed themes
    func refreshInstalledThemes() {
        installedThemes = ThemeConfigurationStore.listThemes()
        print("[Osaurus] ThemeManager: Refreshed themes, found \(installedThemes.count) themes")
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
    /// Returns true if deletion was successful
    @discardableResult
    func deleteTheme(id: UUID) -> Bool {
        // Check if theme exists and is not built-in
        if let theme = installedThemes.first(where: { $0.metadata.id == id }) {
            if theme.isBuiltIn {
                print("[Osaurus] Cannot delete built-in theme: \(theme.metadata.name)")
                return false
            }
        }

        let success = ThemeConfigurationStore.deleteTheme(id: id)
        if success {
            refreshInstalledThemes()

            // If this was the active theme, clear it
            if activeCustomTheme?.metadata.id == id {
                clearCustomTheme()
            }
        }
        return success
    }

    /// Force reinstall built-in themes (for recovery)
    func forceReinstallBuiltInThemes() {
        ThemeConfigurationStore.forceReinstallBuiltInThemes()
        refreshInstalledThemes()
    }

    /// Determine if dark mode should be used based on appearance mode
    private static func isDarkMode(for mode: AppearanceMode) -> Bool {
        switch mode {
        case .system:
            // Use UserDefaults to reliably detect system appearance during early app startup
            // NSApp.effectiveAppearance may not be ready yet when ThemeManager initializes
            if let app = NSApp, app.isRunning {
                return app.effectiveAppearance.name == .darkAqua
            } else {
                // Fall back to reading system preference directly
                return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
            }
        case .light:
            return false
        case .dark:
            return true
        }
    }

    @objc private func systemAppearanceChanged() {
        // Only update if we're following system appearance and no user-selected theme is active
        guard appearanceMode == .system, activeCustomTheme == nil else { return }

        // Apply the appropriate built-in theme
        if let builtInTheme = Self.resolveBuiltInTheme(for: .system, from: installedThemes) {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentTheme = CustomizableTheme(config: builtInTheme)
            }
        } else {
            // Fallback to default CustomTheme
            let fallbackTheme = Self.isDarkMode(for: .system) ? CustomTheme.darkDefault : CustomTheme.lightDefault
            withAnimation(.easeInOut(duration: 0.3)) {
                currentTheme = CustomizableTheme(config: fallbackTheme)
            }
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
