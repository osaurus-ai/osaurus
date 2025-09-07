//
//  Theme.swift
//  osaurus
//
//  Modern minimalistic theme system with dark/light mode support
//

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

  // Shadows
  var shadowColor: Color { get }
  var shadowOpacity: Double { get }
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

  // Shadows
  let shadowColor = Color.black
  let shadowOpacity: Double = 0.3
}

// MARK: - Theme Manager
class ThemeManager: ObservableObject {
  static let shared = ThemeManager()

  @Published var currentTheme: ThemeProtocol

  private init() {
    // Initialize currentTheme from system appearance
    currentTheme = (NSApp.effectiveAppearance.name == .darkAqua) ? DarkTheme() : LightTheme()

    // Observe system appearance changes (Distributed Notification)
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(systemAppearanceChanged),
      name: Notification.Name("AppleInterfaceThemeChangedNotification"),
      object: nil
    )
  }

  @objc private func systemAppearanceChanged() {
    let useDark = NSApp.effectiveAppearance.name == .darkAqua
    withAnimation(.easeInOut(duration: 0.3)) {
      currentTheme = useDark ? DarkTheme() : LightTheme()
    }
  }
}

// MARK: - Theme Environment Key
struct ThemeEnvironmentKey: EnvironmentKey {
  static let defaultValue: ThemeProtocol = LightTheme()
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
          themeManager.currentTheme.shadowOpacity),
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
