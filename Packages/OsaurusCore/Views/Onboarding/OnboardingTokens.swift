//
//  OnboardingTokens.swift
//  osaurus
//
//  Single source of truth for onboarding layout tokens, visual constants,
//  and per-step preferred sizing. The flow uses ONE fixed window size for
//  every step — internal scrolling absorbs any overflow — so the host
//  (`AppDelegate`) never resizes the window between steps.
//

import SwiftUI

// MARK: - Layout Tokens

enum OnboardingMetrics {
    // Window — fixed for every step
    static let windowWidth: CGFloat = 820
    static let windowHeight: CGFloat = 640
    static let minHeight: CGFloat = 540
    static let maxHeight: CGFloat = 780

    // Header
    /// Total height of the full-width header bar (back + title + close).
    /// The step indicator lives in its own strip above the footer, so the
    /// header is shorter than the title-only height suggests.
    static let headerHeight: CGFloat = 52
    /// Horizontal padding for header content (back/close hug the edges via this).
    static let headerHorizontal: CGFloat = 20

    /// How far the body's clip region extends above its top edge so soft hero
    /// glows / shadows render fully instead of being sheared off. Comfortably
    /// covers the largest onboarding glow blur radii.
    static let bodyGlowOverflow: CGFloat = 90

    // Footer
    /// Vertical padding above the footer's caption / action row.
    static let footerTopPadding: CGFloat = 18
    /// Vertical padding below the footer's action row — generous so the
    /// CTA never hugs the window's bottom edge.
    static let footerBottomPadding: CGFloat = 48
    /// Horizontal padding inside the footer.
    static let footerHorizontal: CGFloat = 28
    /// Spacing between the footer caption row and the action row.
    static let footerCaptionToCTA: CGFloat = 12

    // Body — shared
    /// Width of the left column in the two-column body layout.
    static let leftColumnWidth: CGFloat = 340
    /// Padding inside the left column.
    static let leftColumnPadding: CGFloat = 28
    /// Horizontal padding for right-column scroll content.
    static let rightColumnHorizontalPadding: CGFloat = 28
    /// Vertical padding shared by both columns of the two-column body so
    /// that the illustration and the form scroll content start at the
    /// same vertical position.
    static let bodyVerticalPadding: CGFloat = 16

    // Left column rhythm
    static let illustrationMaxHeight: CGFloat = 220
    static let illustrationToHeadline: CGFloat = 22
    static let leftHeadlineToBody: CGFloat = 8

    // Hero body
    static let heroIllustrationMaxHeight: CGFloat = 200
    static let heroIllustrationToHeadline: CGFloat = 24
    static let heroHeadlineToSubtitle: CGFloat = 12
    static let heroMaxTextWidth: CGFloat = 460
    static let heroBodyHorizontalPadding: CGFloat = 32
    static let heroBodyVerticalPadding: CGFloat = 18

    // Typography
    static let titleSize: CGFloat = 16
    static let subtitleSize: CGFloat = 13
    static let captionSize: CGFloat = 12
    static let leftHeadlineSize: CGFloat = 18
    static let leftBodySize: CGFloat = 12
    static let heroHeadlineSize: CGFloat = 30
    static let heroSubtitleSize: CGFloat = 14
    static let sectionLabelSize: CGFloat = 10

    // Cards & shapes
    static let cardCornerRadius: CGFloat = 12
    static let cardPaddingH: CGFloat = 14
    static let cardPaddingV: CGFloat = 12
    static let cardIcon: CGFloat = 40
    static let cardSpacing: CGFloat = 8
    /// Spacing between distinct form sections (label group → next label group).
    static let sectionSpacing: CGFloat = 18
    /// Spacing between a section label and its first input.
    static let labelToInput: CGFloat = 6

    // Buttons
    static let buttonCornerRadius: CGFloat = 10
    static let buttonHeight: CGFloat = 42
    /// Horizontal padding inside content-hugging CTAs so a `.fixedSize` pill
    /// keeps comfortable breathing room around its label instead of clamping
    /// tight to the text. Every onboarding footer CTA is now content-hugging
    /// (centered when the step has no secondary, wizard-pinned when it does).
    static let ctaContentPaddingH: CGFloat = 26
    /// Label size for the brand / stateful CTAs in the footer.
    static let ctaLabelSize: CGFloat = 15
    /// Label size for inline / compact buttons (in-card actions).
    static let compactLabelSize: CGFloat = 12
    /// Label size for tertiary text-link buttons (e.g. "Skip for now").
    static let linkLabelSize: CGFloat = 13

    // Compact / inline buttons (e.g. "Try again", "Use Apple Intelligence")
    /// Corner radius for small in-card action buttons.
    static let inlineButtonRadius: CGFloat = 8
    /// Horizontal padding for compact buttons.
    static let inlineButtonPaddingH: CGFloat = 12
    /// Vertical padding for compact buttons.
    static let inlineButtonPaddingV: CGFloat = 6

    // Segmented control (path picker, protocol toggle, starter chips)
    /// Outer track corner radius for `OnboardingSegmentedControl`.
    static let segmentControlRadius: CGFloat = 11
    /// Inset between the track and its segment fills.
    static let segmentControlInset: CGFloat = 3
    /// Corner radius of the selected-segment fill.
    static let segmentRadius: CGFloat = 8
    /// Default height of a single segment.
    static let segmentHeight: CGFloat = 30
    /// Height of the protocol pill toggle (taller than the standard
    /// segmented control because it pairs with a labelled form field).
    static let protocolToggleHeight: CGFloat = 36

    // Banners (warning / error / info / success callouts)
    /// Corner radius for inline banners and callouts.
    static let bannerCornerRadius: CGFloat = 8
    /// Horizontal padding inside banners.
    static let bannerPaddingH: CGFloat = 12
    /// Vertical padding inside banners.
    static let bannerPaddingV: CGFloat = 10

    // Scroll content buffer
    /// Insets applied to scroll content inside an onboarding body so
    /// card hover shadows (`OnboardingGlassCard` uses `radius:16, y:6`
    /// on hover) don't clip against the scroll-area / chrome body
    /// edges. Bottom buffer is heavier than top so the lifted-shadow
    /// of the bottom-most card has room to render.
    static var scrollContentBuffer: EdgeInsets {
        EdgeInsets(top: 8, leading: 6, bottom: 20, trailing: 6)
    }

    /// Horizontal offset used by step slide transitions. Sized to the full
    /// window width so views slide cleanly off-screen instead of overlapping.
    static let slideOffset: CGFloat = windowWidth

    /// Horizontal offset used by substate slide transitions inside a step
    /// (e.g. ConfigureAI's segmented-path body). Sized to the right column
    /// (window − left column) so substates slide off the column edge.
    static let substateSlideOffset: CGFloat = windowWidth - leftColumnWidth
}

// MARK: - Visual Style Tokens

/// Glass / accent tokens consumed by `OnboardingCards`. Centralised so
/// dark/light treatments stay paired.
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
}

// MARK: - Semantic Color Helpers

extension ThemeProtocol {
    /// Foreground color to use *on* `accentColor` fills. Returns
    /// `primaryBackground` so dark-on-light and light-on-dark stay
    /// readable — light mode accent is near-black, dark mode accent is
    /// cream, and `primaryBackground` flips to match.
    var onboardingOnAccent: Color { primaryBackground }
}

// MARK: - Per-Step Preferred Size (constant)

/// Preferred window width for a given onboarding step. Always returns the
/// uniform `OnboardingMetrics.windowWidth` — every step shares the same
/// window so the chrome never resizes between transitions.
func onboardingPreferredWidth(for step: OnboardingStep) -> CGFloat {
    OnboardingMetrics.windowWidth
}

/// Preferred window height for a given onboarding step. Always returns the
/// uniform `OnboardingMetrics.windowHeight`. Per-step content overflow is
/// handled by internal scrolling rather than window resizing.
func onboardingPreferredHeight(for step: OnboardingStep) -> CGFloat {
    OnboardingMetrics.windowHeight
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
