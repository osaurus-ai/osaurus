//
//  OnboardingDesign.swift
//  osaurus
//
//  Design tokens for the onboarding window. Chrome follows the app theme
//  (light or dark) and sits on frosted glass over the brand landscape, so
//  most tokens are theme roles; translucent fills are the theme's ink at a
//  fixed strength so they read on glass either way. The brand constants at
//  the bottom (dino green, the comic bubble, glass highlights) do not
//  change with the theme. Everything visual in Views/Onboarding reads from
//  here so the palette stays a single source of truth.
//

import SwiftUI

// MARK: - Palette

@MainActor
enum OnboardingPalette {
    private static var theme: any ThemeProtocol { ThemeManager.shared.currentTheme }

    /// The theme's primary ink at `strength`, for fills and rules on glass.
    private static func ink(_ strength: Double) -> Color {
        let primary = theme.text.primary
        return primary.opacity(strength)
    }

    static var windowBackground: Color { theme.surface.canvas }

    // Labels
    static var labelPrimary: Color { theme.text.primary }
    static var labelSecondary: Color { theme.text.secondary }
    /// Hero titles and model names.
    static var labelWhite: Color { theme.text.primary }

    // Translucent fills
    static var fill10: Color { ink(0.10) }
    static var fill8: Color { ink(0.08) }
    static var fill5: Color { ink(0.05) }
    static var fill3: Color { ink(0.03) }
    static var fill2: Color { ink(0.02) }

    // Accents
    /// Links and the checkbox.
    static var accentBlue: Color { theme.text.link }
    /// The "Recommended" model badge.
    static var accentCyan: Color { theme.status.info.foreground }

    // Primary button
    static var vibrantFill: Color { theme.action.primary.default.background }
    static var vibrantLabel: Color { theme.action.primary.default.foreground }

    /// Dialog surface for the connect / model dialogs.
    static var dialogSurface: Color { theme.surface.overlay }

    /// The dim behind dialogs.
    static func scrim(_ strength: Double) -> Color {
        let scrim = theme.scrim
        return scrim.opacity(strength)
    }

    /// Inline warning copy.
    static var warningLabel: Color { theme.status.error.foreground }
    /// A model that runs but may crowd other apps.
    static var fitTight: Color { theme.status.warning.foreground }

    // Brand constants

    /// Selection green `#68d735` (specialty card border, verified check).
    static let dinoGreen = Color(red: 0x68 / 255, green: 0xD7 / 255, blue: 0x35 / 255)
    /// Dino green for text. `#68d735` is 1.2–1.7:1 on light glass, so light
    /// mode sets copy in a deep green `#24650f` (4.5:1 or better on the
    /// green washes and the dialog surface).
    static var dinoGreenText: Color {
        theme.isDark ? dinoGreen : Color(red: 0x24 / 255, green: 0x65 / 255, blue: 0x0F / 255)
    }
    /// The local-model card's gradient tint, fading to clear.
    static let createGradientGreen = Color(red: 133 / 255, green: 212 / 255, blue: 82 / 255)
        .opacity(0.26)
    /// Glyphs on the link-colored checkbox.
    static let onAccent = Color.white
    /// The dino's comic speech bubble: white paper, black ink and outline.
    static let bubbleFill = Color.white
    static let bubbleInk = Color.black
    /// The specular rim on glass.
    static func glassRim(_ strength: Double) -> Color { Color.white.opacity(strength) }
    /// The soft light that follows the pointer across the landscape.
    static let pointerLight = Color.white
}

// MARK: - Typography

/// Type ramp from the Figma kit. The Figma "Helper" name chip uses Inter
/// Bold; we substitute the system SF Pro Bold — an intentional deviation so
/// the app never bundles a webfont.
enum OnboardingTypography {
    /// 46pt bold greeting on the Hello chapter.
    static let greeting = Font.system(size: 46, weight: .bold)
    /// 11pt semibold chapter indicator label.
    static let chapter = Font.system(size: 11, weight: .semibold)
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
    /// Corner radius of the window and the right panel.
    static let panelRadius: CGFloat = 16
    /// Card corner radius.
    static let cardRadius: CGFloat = 12
    /// Diameter of the overlay Back/Close glass circle buttons.
    static let glassButtonDiameter: CGFloat = 24
    /// Inset of the overlay Back/Close buttons from the window edge.
    static let glassButtonInset: CGFloat = 16

    /// Top inset of chapter content, below the chapter indicator row.
    static let stageTopInset: CGFloat = 64
    /// The stage dino's box on the Hello chapter.
    static let helloDinoSize: CGFloat = 200
    /// The stage dino's box beside the setup surface.
    static let brainDinoSize: CGFloat = 150
    /// Distance from the window's bottom edge to the dino's feet: the
    /// landscapes' ground sits in their lower third.
    static let groundInset: CGFloat = 36
    /// The Hello chapter's glass card.
    static let helloCardWidth: CGFloat = 380
    /// The greeting's wrap width.
    static let greetingWidth: CGFloat = 520
    /// The greeting's leading inset.
    static let greetingInset: CGFloat = 56
    /// The Brain chapter's left column, beside the setup surface.
    static let brainColumnWidth: CGFloat = 300
    /// The dino's explainer bubble, as wide as the Brain chapter's column.
    static let helpBubbleWidth: CGFloat = 300
    /// How far the comic bubble's tail hangs below its body.
    static let bubbleTailHeight: CGFloat = 14
}
