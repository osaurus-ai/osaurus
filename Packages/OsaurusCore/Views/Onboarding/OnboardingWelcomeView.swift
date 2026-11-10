//
//  OnboardingWelcomeView.swift
//  osaurus
//
//  The Welcome chapter: the greeting over the landscape, and a glass card
//  with the pitch, "Get started", the legal line, and the usage-data
//  opt-in. The dino itself belongs to the window's stage (`OnboardingView`)
//  so it can walk into the next chapter.
//

import SwiftUI

// MARK: - State

/// Welcome step state. Holds the anonymous-usage opt-in so the choice made
/// via the switch survives the slide transition and can be read by the
/// parent's "Get started" CTA. Moving usage consent here (the *first* step)
/// is deliberate: `TelemetryService` buffers the onboarding funnel until a
/// decision is made, so opting in up front lets us capture the drop-off
/// point even when the user bails partway through.
@MainActor
final class WelcomeState: ObservableObject {
    /// Opt-OUT, so it defaults ON (consistent with crash reporting). The
    /// parent reads this on the "Get started" CTA and, when on, calls
    /// `TelemetryService.setEnabled(true)` to flush the buffered funnel and
    /// send everything that follows live; switching it off leaves telemetry
    /// undecided so `finishOnboarding` finalizes a decline.
    @Published var shareUsageData: Bool = true
}

// MARK: - Chapter view

struct HelloChapterView: View {
    @Environment(\.theme) private var theme

    @ObservedObject var state: WelcomeState
    @ObservedObject var stage: OnboardingStage
    let onGetStarted: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            greeting
                .padding(.leading, OnboardingLayout.greetingInset)
                .padding(.top, greetingTop)

            card
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(OnboardingLayout.contentPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Greeting

    /// The glow is pinned to the window's top edge, so it offsets by exactly this.
    private var greetingTop: CGFloat { OnboardingLayout.stageTopInset + theme.space.s16 }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(stage.greetingLines, id: \.self) { line in
                Text(verbatim: line)
                    .font(OnboardingTypography.greeting)
                    .foregroundColor(OnboardingPalette.labelPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: OnboardingLayout.greetingWidth, alignment: .leading)
        .onboardingEntrance(0)
        .background(alignment: .topLeading) { legibilityGlow }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: stage.greetingText))
        .accessibilityAddTraits(.isHeader)
    }

    /// A soft wash of the window canvas behind the greeting so it reads on
    /// every landscape, light or dark.
    private var legibilityGlow: some View {
        // Elliptical so it fades out exactly at the frame's edges.
        EllipticalGradient(
            colors: [OnboardingPalette.windowBackground, OnboardingPalette.windowBackground.opacity(0)],
            center: .topLeading,
            startRadiusFraction: 0,
            endRadiusFraction: 1
        )
        .opacity(0.55)
        .frame(width: OnboardingLayout.greetingWidth * 1.4, height: OnboardingLayout.greetingWidth * 0.7)
        .offset(x: -OnboardingLayout.greetingInset, y: -greetingTop)
        .allowsHitTesting(false)
    }

    // MARK: Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(
                "Build a team of AI agents for life and work. Your chats, files, and keys can stay private on your Mac. No account or cloud required.",
                bundle: .module
            )
            .font(OnboardingTypography.subtitle)
            .foregroundColor(OnboardingPalette.labelPrimary)
            #if !OSAURUS_DESIGN_SYSTEM
            .lineSpacing(1.5)
            #endif
            .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: theme.space.s24)

            OnboardingPillButton(
                title: "Get started",
                style: .primary,
                size: .large,
                trailingSymbol: "arrow.right",
                action: onGetStarted
            )

            Spacer().frame(height: theme.space.s12)

            legalNotice

            Divider()
                .overlay(OnboardingPalette.fill10)
                .padding(.vertical, theme.space.s16)

            OnboardingSwitchRow(
                isOn: $state.shareUsageData,
                title: "Share anonymous usage data",
                caption: "Optional. Helps improve Osaurus. Never includes your chats, prompts, files, or keys."
            )
        }
        .padding(theme.space.s24)
        .frame(width: OnboardingLayout.helloCardWidth, alignment: .leading)
        .background(OnboardingGlass(cornerRadius: OnboardingLayout.panelRadius))
        .onboardingEntrance(1)
    }

    /// First-run affirmative acceptance: proceeding is the action that
    /// accepts the Terms and Privacy Policy, which is more defensible than a
    /// passive footer link alone.
    private var legalNotice: some View {
        MarkdownLinkText(
            markdown: OsaurusWebLinks.acceptanceMarkdown,
            style: .caption,
            textColor: OnboardingPalette.labelSecondary,
            linkColor: OnboardingPalette.accentBlue,
            alignment: .leading
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}
