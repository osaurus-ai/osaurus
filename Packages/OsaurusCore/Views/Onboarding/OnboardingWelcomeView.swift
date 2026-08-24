//
//  OnboardingWelcomeView.swift
//  osaurus
//
//  Welcome step — Figma screen 1. Left column (bottom-aligned): 40pt hero
//  title, 14pt subtitle, white "Get started →" pill, 10pt legal acceptance
//  line, and the usage-data checkbox. Right: rounded panel with the
//  dino-team hero image.
//

import SwiftUI

// MARK: - State

/// Welcome step state. Holds the anonymous-usage opt-in so the choice made
/// via the checkbox survives the slide transition and can be read by the
/// parent's "Get started" CTA. Moving usage consent here (the *first* step)
/// is deliberate: `TelemetryService` buffers the onboarding funnel until a
/// decision is made, so opting in up front lets us capture the drop-off
/// point even when the user bails partway through.
@MainActor
final class WelcomeState: ObservableObject {
    /// Opt-OUT, so it defaults ON (consistent with crash reporting). The
    /// parent reads this on the "Get started" CTA and, when on, calls
    /// `TelemetryService.setEnabled(true)` to flush the buffered funnel and
    /// send everything that follows live; unchecking it leaves telemetry
    /// undecided so `finishOnboarding` finalizes a decline.
    @Published var shareUsageData: Bool = true
}

// MARK: - Step view

struct WelcomeStepView: View {
    @ObservedObject var state: WelcomeState
    let onGetStarted: () -> Void

    @State private var visible = false

    var body: some View {
        OnboardingStepLayout {
            leftColumn
        } right: {
            heroPanel
        }
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.5), value: visible)
        .onAppearAfter(0.05) { visible = true }
    }

    // MARK: Left column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("A Dino for every side of your work.", bundle: .module)
                .font(OnboardingTypography.heroTitle)
                .tracking(0.4)
                .foregroundColor(OnboardingPalette.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 16)

            Text(
                "Build your own team of Dinos for every side of your life. Your chats, files, and keys can stay private on your Mac. No account or cloud required.",
                bundle: .module
            )
            .font(OnboardingTypography.subtitle)
            .foregroundColor(OnboardingPalette.labelSecondary)
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 40)

            OnboardingPillButton(
                title: "Get started",
                style: .primary,
                size: .large,
                trailingSymbol: "arrow.right",
                action: onGetStarted
            )

            Spacer().frame(height: 16)

            legalNotice

            Spacer().frame(height: 10)

            OnboardingCheckboxRow(
                isOn: $state.shareUsageData,
                label: "Share anonymous usage data to help improve Osaurus"
            )
        }
    }

    /// First-run affirmative acceptance: proceeding is the action that
    /// accepts the Terms and Privacy Policy, which is more defensible than a
    /// passive footer link alone.
    private var legalNotice: some View {
        MarkdownLinkText(
            markdown: OsaurusWebLinks.acceptanceMarkdown,
            font: OnboardingTypography.footnote,
            textColor: OnboardingPalette.labelSecondary,
            linkColor: OnboardingPalette.accentBlue,
            alignment: .leading
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Right panel

    private var heroPanel: some View {
        OnboardingRightPanel {
            Image("osaurus-main", bundle: .module)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingWelcomeView_Previews: PreviewProvider {
        static var previews: some View {
            ZStack {
                OnboardingPalette.windowBackground
                WelcomeStepView(state: WelcomeState(), onGetStarted: {})
            }
            .frame(width: OnboardingMetrics.windowWidth, height: OnboardingMetrics.windowHeight)
        }
    }
#endif
