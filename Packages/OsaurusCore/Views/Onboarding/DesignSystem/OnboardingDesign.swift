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
    /// The "Picked for your Mac" badge.
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
    static let dinoGreen = BrandPalette.dinoGreen
    /// Dino green for text. `#68d735` is 1.2–1.7:1 on light glass, so light
    /// mode sets copy in a deep green `#24650f` (4.5:1 or better on the
    /// green washes and the dialog surface).
    static var dinoGreenText: Color {
        theme.isDark ? dinoGreen : BrandPalette.dinoGreenDeep
    }
    /// The local-model card's gradient tint, fading to clear.
    static let createGradientGreen = BrandPalette.dinoGreenGlow
    /// Glyphs on the link-colored checkbox.
    static let onAccent = FixedPalette.onMedia
    static let bubbleFill = BrandPalette.bubblePaper
    static let bubbleInk = BrandPalette.bubbleInk
    static func glassRim(_ strength: Double) -> Color { BrandPalette.glassLight.opacity(strength) }
    static let pointerLight = BrandPalette.glassLight
}

// MARK: - Typography

/// The onboarding type ramp, set on the shared text roles. The Figma
/// "Helper" name chip uses Inter Bold; SF Pro Bold stands in so the app
/// never bundles a webfont.
enum OnboardingTypography {
    /// `type.hero`. The greeting on the Hello chapter.
    static let greeting = SettingsFont(role: .hero)
    /// `type.footnote`, semibold. The chapter indicator label.
    static let chapter = SettingsFont(role: .footnote, weightOverride: 600)
    /// `type.display`. The chapter title.
    static let heroTitle = SettingsFont(role: .display)
    /// `type.bodySmall`. The line under the chapter title.
    static let subtitle = SettingsFont(role: .bodySmall)
    /// `type.bodyEmphasis`. Large pill labels.
    static let cta = SettingsFont(role: .bodyEmphasis)
    /// `type.label`. Compact pills and provider chips.
    static let chip = SettingsFont(role: .label)
    /// `type.micro`. The legal line and checkbox labels.
    static let footnote = SettingsFont(role: .micro)
    /// `type.lead`. Card and dialog titles.
    static let cardTitle = SettingsFont(role: .lead)
    /// `type.lead`, regular. Specialty card row titles.
    static let cardTitleRegular = SettingsFont(role: .lead, weightOverride: 400)
    /// `type.caption`. Card captions.
    static let cardCaption = SettingsFont(role: .caption)
    /// `type.title`, bold. The model name.
    static let modelTitle = SettingsFont(role: .title, weightOverride: 700)
    /// `type.footnote`, semibold. Badge labels.
    static let badge = SettingsFont(role: .footnote, weightOverride: 600)
    /// `type.label`, semibold. Option row titles.
    static let optionTitle = SettingsFont(role: .label, weightOverride: 600)
    /// `type.lead`, bold. The helper name chip.
    static let nameChip = SettingsFont(role: .lead, weightOverride: 700)
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
