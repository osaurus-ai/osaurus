//
//  OnboardingTokens.swift
//  osaurus
//
//  Single source of truth for onboarding layout tokens, visual constants,
//  per-step preferred heights and the height preference key used to drive
//  adaptive window sizing from the host (`AppDelegate`).
//

import SwiftUI

// MARK: - Layout Tokens

/// Layout, sizing and typography constants shared by every onboarding screen.
enum OnboardingMetrics {
    // Window
    static let windowWidth: CGFloat = 520
    static let minHeight: CGFloat = 520
    static let maxHeight: CGFloat = 760
    static let defaultHeight: CGFloat = 580

    // Layout
    /// Single horizontal inset used for content (back row, header, body, footer, CTA).
    static let contentHorizontal: CGFloat = 28
    /// Height of the top bar that hosts the back button (also used as top inset when no back).
    static let topBarHeight: CGFloat = 48
    /// Spacing between header (title + subtitle) and body content.
    static let headerToBody: CGFloat = 20
    /// Minimum spacing between body and footer caption (the surrounding flex spacer absorbs slack).
    static let bodyToFooter: CGFloat = 14
    /// Spacing between footer and CTA.
    static let footerToCTA: CGFloat = 18
    /// Bottom inset under the CTA.
    static let bottomInset: CGFloat = 28
    /// Spacing between title and subtitle.
    static let titleToSubtitle: CGFloat = 8

    // Typography
    static let titleSize: CGFloat = 22
    static let subtitleSize: CGFloat = 13
    static let captionSize: CGFloat = 12
    static let heroTitleSize: CGFloat = 28

    // Cards & shapes
    static let cardCornerRadius: CGFloat = 12
    static let cardPaddingH: CGFloat = 16
    static let cardPaddingV: CGFloat = 14
    static let cardIcon: CGFloat = 44
    static let cardSpacing: CGFloat = 10

    // Buttons
    static let buttonCornerRadius: CGFloat = 10
    static let buttonHeight: CGFloat = 44
    /// Default CTA width (single-action screens).
    static let ctaWidth: CGFloat = 200
    /// Compact CTA width (used by the hero Welcome shimmer button).
    static let ctaWidthCompact: CGFloat = 180

    // Animation
    static let appearDelay: Double = 0.1
}

// MARK: - Visual Style Tokens

/// Opacity and glow tokens for the glass background, borders and button glow.
enum OnboardingStyle {
    // Glass background
    static let glassOpacityDark: Double = 0.78
    static let glassOpacityLight: Double = 0.88

    // Accent gradient overlay
    static let accentGradientOpacityDark: Double = 0.08
    static let accentGradientOpacityLight: Double = 0.05

    // Border
    static let edgeLightOpacityDark: Double = 0.22
    static let edgeLightOpacityLight: Double = 0.35
    static let borderOpacityDark: Double = 0.18
    static let borderOpacityLight: Double = 0.28

    // Accent edge highlight
    static let accentEdgeHoverOpacity: Double = 0.18
    static let accentEdgeNormalOpacity: Double = 0.10

    // Button glow
    static let buttonGlowRadiusNormal: CGFloat = 12
    static let buttonGlowRadiusHover: CGFloat = 16
    static let buttonGlowOpacityNormal: Double = 0.25
    static let buttonGlowOpacityHover: Double = 0.4
}

// MARK: - Per-Step Preferred Height

/// Preferred window height for a given onboarding step, clamped to
/// `[OnboardingMetrics.minHeight, OnboardingMetrics.maxHeight]`. Heights are
/// tuned so the scaffold's flexible spacer leaves a natural amount of breathing
/// room — not so much that the screen looks empty.
func onboardingPreferredHeight(for step: OnboardingStep) -> CGFloat {
    let raw: CGFloat = {
        switch step {
        case .welcome: return 540
        case .choosePath: return 560
        case .localDownload: return 640
        case .apiSetup: return 660
        case .complete: return 580
        case .identitySetup: return 600
        case .walkthrough: return 620
        }
    }()
    return min(max(raw, OnboardingMetrics.minHeight), OnboardingMetrics.maxHeight)
}

// MARK: - Height Preference Key

/// Communicates the active step's preferred window height from `OnboardingView`
/// up to the host (`AppDelegate`), which animates the NSWindow accordingly.
struct OnboardingHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = OnboardingMetrics.defaultHeight
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Delayed Appear Helper

extension View {
    /// Runs `action` on the main actor after `delay` seconds when the view
    /// appears. Cancelled automatically if the view disappears before the
    /// delay elapses (unlike `DispatchQueue.main.asyncAfter`).
    func onAppearAfter(_ delay: Double, perform action: @escaping () -> Void) -> some View {
        task {
            let nanos = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            action()
        }
    }
}
