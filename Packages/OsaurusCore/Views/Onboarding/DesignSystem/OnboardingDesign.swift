//
//  OnboardingDesign.swift
//  osaurus
//
//  Design tokens for the redesigned onboarding flow, named after the Figma
//  variables (Osaurus file, frames 1–3). The onboarding window is dark-only —
//  the host forces `.darkAqua` — so these are absolute colors, not theme
//  lookups. Everything visual in Views/Onboarding/DesignSystem reads from
//  here so the palette stays a single source of truth.
//

import SwiftUI

// MARK: - Palette

/// Dark-only color tokens from the Figma onboarding kit.
enum OnboardingPalette {
    /// Window background `#1e1e1e`.
    static let windowBackground = Color(red: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255)

    // Labels
    /// Primary label — `white 85%`.
    static let labelPrimary = Color.white.opacity(0.85)
    /// Secondary label — `white 55%`.
    static let labelSecondary = Color.white.opacity(0.55)
    /// Pure-white label (hero titles, model names).
    static let labelWhite = Color.white

    // Opaque-on-dark fills (white at fixed opacities)
    static let fill10 = Color.white.opacity(0.10)
    static let fill8 = Color.white.opacity(0.08)
    static let fill5 = Color.white.opacity(0.05)
    static let fill3 = Color.white.opacity(0.03)
    static let fill2 = Color.white.opacity(0.02)

    // Accents
    /// Link / checkbox blue `#0091ff`.
    static let accentBlue = Color(red: 0x00 / 255, green: 0x91 / 255, blue: 0xFF / 255)
    /// "Picked for your Mac" badge cyan `#3cd3fe`.
    static let accentCyan = Color(red: 0x3C / 255, green: 0xD3 / 255, blue: 0xFE / 255)
    /// Selection green `#68d735` (specialty card border, verified check).
    static let dinoGreen = Color(red: 0x68 / 255, green: 0xD7 / 255, blue: 0x35 / 255)

    // Vibrant (primary) button
    /// Primary pill fill `#f5f5f5`.
    static let vibrantFill = Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF5 / 255)
    /// Label on the vibrant fill `#111111`.
    static let vibrantLabel = Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255)

    /// Screen 2's right-panel gradient tint start — `rgba(133,212,82,0.26)`,
    /// fading to clear.
    static let createGradientGreen = Color(red: 133 / 255, green: 212 / 255, blue: 82 / 255)
        .opacity(0.26)

    /// Dialog surface for the connect / model dialogs (`#262626` over the
    /// black scrim, slightly lighter than the window).
    static let dialogSurface = Color(red: 0x26 / 255, green: 0x26 / 255, blue: 0x26 / 255)
}

// MARK: - Typography

/// Type ramp from the Figma kit. The Figma "Helper" name chip uses Inter
/// Bold; we substitute the system SF Pro Bold — an intentional deviation so
/// the app never bundles a webfont.
enum OnboardingTypography {
    /// 40pt bold hero title, tight leading.
    static let heroTitle = Font.system(size: 40, weight: .bold)
    /// 14pt regular subtitle under the hero title.
    static let subtitle = Font.system(size: 14)
    /// 15pt semibold CTA label (large pills).
    static let cta = Font.system(size: 15, weight: .semibold)
    /// 13pt label (compact pills, provider chips).
    static let chip = Font.system(size: 13)
    /// 10pt footnote (legal line, checkbox label).
    static let footnote = Font.system(size: 10)
    /// 17pt semibold card / dialog title.
    static let cardTitle = Font.system(size: 17, weight: .semibold)
    /// 17pt regular row title (specialty cards use Title 2/Regular).
    static let cardTitleRegular = Font.system(size: 17)
    /// 12pt card caption.
    static let cardCaption = Font.system(size: 12)
    /// 22pt bold model name.
    static let modelTitle = Font.system(size: 22, weight: .bold)
    /// 11pt semibold badge label.
    static let badge = Font.system(size: 11, weight: .semibold)
    /// 13pt semibold option-row title.
    static let optionTitle = Font.system(size: 13, weight: .semibold)
    /// 17pt bold name chip (SF Pro Bold standing in for Figma's Inter Bold).
    static let nameChip = Font.system(size: 17, weight: .bold)
}

// MARK: - Layout

/// Structural metrics of the 1000×640 onboarding shell.
enum OnboardingLayout {
    /// Content padding inside the window on all edges.
    static let contentPadding: CGFloat = 40
    /// Gap between the left column and the right panel.
    static let columnGap: CGFloat = 40
    /// Fixed left column width (including its trailing inset).
    static let leftColumnWidth: CGFloat = 400
    /// Trailing inset inside the left column (text wraps before it).
    static let leftColumnTrailingInset: CGFloat = 56
    /// Corner radius of the window and the right panel.
    static let panelRadius: CGFloat = 16
    /// Card corner radius.
    static let cardRadius: CGFloat = 12
    /// Diameter of the overlay Back/Close glass circle buttons.
    static let glassButtonDiameter: CGFloat = 24
    /// Inset of the overlay Back/Close buttons from the window edge.
    static let glassButtonInset: CGFloat = 16
}
