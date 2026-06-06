//
//  OnboardingChromeShell.swift
//  osaurus
//
//  The single chrome shell shared by every onboarding step. Owns the
//  full-width header (back + title + close), the body region, and the
//  full-width footer (caption row and macOS-wizard action row
//  [secondary | spacer | primary]).
//
//  All chrome is fully transparent (no fills, no rules) so the window's
//  blurred glass background shows through naturally. The body slides
//  horizontally between steps; the structural chrome stays put. The title,
//  footer caption, secondary, body and CTA are all caller-supplied
//  ViewBuilder slots so the parent can wrap them in animated containers that
//  slide together as a single visual unit.
//
//  Layout:
//
//      ┌────────────────────────────────────────────────────────┐
//      │ [< Back]          Title (centered)             [Close] │  ← header
//      ├────────────────────────────────────────────────────────┤
//      │                                                        │
//      │                       BODY SLOT                        │  ← caller-supplied
//      │                                                        │
//      ├────────────────────────────────────────────────────────┤
//      │                  caption (optional)                    │  ← footer caption
//      │ [Secondary]                              [Primary CTA] │  ← action row
//      └────────────────────────────────────────────────────────┘
//

import SwiftUI

// MARK: - Chrome Shell

struct OnboardingChromeShell<
    TitleSlot: View,
    FooterCaptionSlot: View,
    SecondarySlot: View,
    BodyContent: View,
    CTA: View
>: View {
    let onBack: (() -> Void)?
    let onClose: () -> Void

    let titleSlot: TitleSlot
    let footerCaptionSlot: FooterCaptionSlot
    let secondarySlot: SecondarySlot
    let bodyContent: BodyContent
    let cta: CTA

    init(
        onBack: (() -> Void)? = nil,
        onClose: @escaping () -> Void,
        @ViewBuilder title: () -> TitleSlot,
        @ViewBuilder footerCaption: () -> FooterCaptionSlot,
        @ViewBuilder secondary: () -> SecondarySlot,
        @ViewBuilder body: () -> BodyContent,
        @ViewBuilder cta: () -> CTA
    ) {
        self.onBack = onBack
        self.onClose = onClose
        self.titleSlot = title()
        self.footerCaptionSlot = footerCaption()
        self.secondarySlot = secondary()
        self.bodyContent = body()
        self.cta = cta()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header draws above the body so a body glow that bleeds up into
            // the header region renders *behind* the title/buttons (ambient),
            // not on top of them.
            header
                .zIndex(1)
            bodyRegion
            footerColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header (transparent, no rule)

    private var header: some View {
        ZStack {
            // Centered title (caller-supplied, animated)
            titleSlot

            // Edge cluster: back (leading) and close (trailing)
            HStack(spacing: 0) {
                if let onBack = onBack {
                    OnboardingBackButton(action: onBack)
                        .padding(.leading, OnboardingMetrics.headerHorizontal)
                }
                Spacer(minLength: 0)
                OnboardingCloseButton(action: onClose)
                    .padding(.trailing, OnboardingMetrics.headerHorizontal)
            }
        }
        .frame(height: OnboardingMetrics.headerHeight)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Body region

    /// The body is clipped **horizontally** so per-step horizontal slide
    /// transitions never bleed sideways over the chrome — but the clip is
    /// extended upward so soft hero glows / shadows aren't sheared off at the
    /// body's top edge (a plain `.clipped()` cut them flat). The bottom stays
    /// clipped so opaque body content can't spill into the footer.
    private var bodyRegion: some View {
        bodyContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(BodyClipShape(topOverflow: OnboardingMetrics.bodyGlowOverflow))
    }

    // MARK: - Footer (transparent, no rule)

    /// Footer chrome cluster. Vertically: footer caption → action row. The
    /// caption slot owns its own bottom spacing so a captionless step collapses
    /// flush against the action row instead of leaving a reserved gap.
    private var footerColumn: some View {
        VStack(spacing: 0) {
            footerCaptionSlot

            // Action row — wizard layout: secondary on the leading edge,
            // primary CTA on the trailing edge.
            HStack(spacing: 0) {
                secondarySlot
                Spacer(minLength: 0)
                cta
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, OnboardingMetrics.footerHorizontal)
        .padding(.top, OnboardingMetrics.footerTopPadding)
        .padding(.bottom, OnboardingMetrics.footerBottomPadding)
    }
}

// MARK: - Body Clip Shape

/// Clips the body to its bounds horizontally and at the bottom, but extends
/// the clip region upward by `topOverflow` so soft glows / drop shadows
/// around hero content render fully instead of being cut flat at the body's
/// top edge. Horizontal edges stay tight so slide transitions are contained.
private struct BodyClipShape: Shape {
    var topOverflow: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(
            CGRect(
                x: rect.minX,
                y: rect.minY - topOverflow,
                width: rect.width,
                height: rect.height + topOverflow
            )
        )
    }
}

// MARK: - Close Button

/// Compact close affordance pinned at the trailing edge of the header.
struct OnboardingCloseButton: View {
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(theme.secondaryBackground.opacity(isHovered ? 0.9 : 0.5))

                if isHovered {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.red.opacity(0.15), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(isHovered ? Color.red.opacity(0.9) : theme.secondaryText)
            }
            .frame(width: 26, height: 26)
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                theme.glassEdgeLight.opacity(isHovered ? 0.3 : 0.15),
                                (isHovered ? Color.red : theme.primaryBorder).opacity(isHovered ? 0.2 : 0.1),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isHovered ? Color.red.opacity(0.2) : .clear,
                radius: 6,
                x: 0,
                y: 2
            )
            .scaleEffect(isHovered ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
    }
}
