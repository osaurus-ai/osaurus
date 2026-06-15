//
//  OnboardingWelcomeView.swift
//  osaurus
//
//  Welcome step body + CTA — a single-column hero hosted in the chrome
//  shell. No wordmark or eyebrow on this screen; the dinosaur and the
//  headline carry the brand. Animation phases in over a tight cadence.
//

import SwiftUI

// MARK: - State

/// Welcome step state. Holds the anonymous-usage opt-in so the choice made
/// via the `WelcomeUsageOptIn` checkbox survives the slide transition and can
/// be read by the parent's "Get Started" CTA. Moving usage consent here (the
/// *first* step) is deliberate: `TelemetryService` buffers the onboarding
/// funnel until a decision is made, so opting in up front lets us capture the
/// drop-off point even when the user bails partway through.
@MainActor
final class WelcomeState: ObservableObject {
    /// Opt-OUT, so it defaults ON (consistent with crash reporting). The
    /// parent reads this on the "Get Started" CTA and, when on, calls
    /// `TelemetryService.setEnabled(true)` to flush the buffered funnel and
    /// send everything that follows live; unchecking it leaves telemetry
    /// undecided so `finishOnboarding` finalizes a decline.
    @Published var shareUsageData: Bool = true
}

// MARK: - Welcome Body

struct WelcomeBody: View {
    @ObservedObject var state: WelcomeState

    @Environment(\.theme) private var theme
    @State private var visible = false

    var body: some View {
        // The usage opt-in lives in the chrome footer caption slot (rendered by
        // `OnboardingView`, see `WelcomeUsageOptIn`) so it sits directly above
        // the CTA — consistent with the caption on the "Meet your dino" step.
        OnboardingHeroBody(
            illustrationAsset: "osaurus-main",
            headline: "Own your AI.",
            subtitle:
                "Runs on your Mac. Your chats, files, and keys stay with you. No account, no cloud required."
        )
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.98)
        .animation(.easeOut(duration: 0.5), value: visible)
        .onAppearAfter(0.05) { visible = true }
    }
}

// MARK: - Usage Opt-In

/// The anonymous-usage opt-in, surfaced in the footer caption slot just above
/// the "Get Started" CTA. Rendered as a custom checkbox row because the native
/// `.checkbox` toggle style was nearly invisible on the light hero — we draw
/// our own SF Symbol box with theme colors for reliable contrast.
struct WelcomeUsageOptIn: View {
    @ObservedObject var state: WelcomeState

    @Environment(\.theme) private var theme

    /// Drives the info popover. Local view state (not in `WelcomeState`) so it
    /// resets cleanly with the view and never outlives the step transition.
    @State private var showInfo = false

    var body: some View {
        HStack(spacing: 6) {
            toggleButton
            infoButton
        }
    }

    /// The checkbox + label that toggles the opt-in.
    private var toggleButton: some View {
        Button {
            state.shareUsageData.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: state.shareUsageData ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(state.shareUsageData ? theme.accentColor : theme.tertiaryText)
                Text("Share anonymous usage data to help improve Osaurus", bundle: .module)
                    .font(theme.font(size: 12))
                    .foregroundColor(theme.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(state.shareUsageData ? [.isSelected] : [])
    }

    /// A separate button (outside `toggleButton`) so tapping it opens the
    /// explainer popover without flipping the opt-in.
    private var infoButton: some View {
        Button {
            showInfo.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundColor(showInfo ? theme.accentColor : theme.tertiaryText)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Why we collect anonymous usage data", bundle: .module))
        .popover(isPresented: $showInfo, arrowEdge: .bottom) {
            infoPopover
        }
    }

    private var infoPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "We collect anonymous, aggregated usage data to learn which features are used so we can improve Osaurus. It's completely anonymous and never includes your chats, prompts, files, or keys. You can turn this off anytime in Settings.",
                bundle: .module
            )
            .font(theme.font(size: 12))
            .foregroundColor(theme.primaryText)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)

            // Ties this specific consent to the matching diagnostics disclosure.
            MarkdownLinkText(
                markdown: OsaurusWebLinks.usageDiagnosticsMarkdown,
                font: theme.font(size: 12),
                textColor: theme.secondaryText,
                linkColor: theme.accentColor
            )
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 280)
        // Fill an explicit themed surface so the text never renders dark-on-dark
        // against the system popover material.
        .background(theme.secondaryBackground)
    }
}

// MARK: - Legal Acceptance

/// First-run affirmative acceptance, surfaced in the footer caption slot
/// directly above the "Get Started" CTA: proceeding is the action that accepts
/// the Terms and Privacy Policy, which is more defensible than a passive footer
/// link alone.
struct WelcomeLegalNotice: View {
    @Environment(\.theme) private var theme

    var body: some View {
        MarkdownLinkText(
            markdown: OsaurusWebLinks.acceptanceMarkdown,
            font: theme.font(size: 11),
            textColor: theme.tertiaryText,
            linkColor: theme.accentColor,
            alignment: .center
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Welcome CTA

struct WelcomeCTA: View {
    let onContinue: () -> Void

    var body: some View {
        OnboardingBrandButton(title: "Get Started", action: onContinue)
            .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingWelcomeView_Previews: PreviewProvider {
        static var previews: some View {
            let state = WelcomeState()
            return VStack(spacing: 12) {
                WelcomeBody(state: state)
                    .frame(height: 420)
                WelcomeUsageOptIn(state: state)
                WelcomeCTA(onContinue: {})
            }
            .frame(width: OnboardingMetrics.windowWidth, height: 540)
        }
    }
#endif
