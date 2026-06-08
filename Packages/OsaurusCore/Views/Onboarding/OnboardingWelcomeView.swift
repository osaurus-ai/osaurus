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
/// via the checkbox in `WelcomeBody` survives the slide transition and can be
/// read by the parent's "Get Started" CTA. Moving usage consent here (the
/// *first* step) is deliberate: `TelemetryService` buffers the onboarding
/// funnel until a decision is made, so opting in up front lets us capture the
/// drop-off point even when the user bails partway through.
@MainActor
final class WelcomeState: ObservableObject {
    /// Opt-IN, so it defaults OFF. The parent reads this on the "Get Started"
    /// CTA and, when on, calls `TelemetryService.setEnabled(true)` to flush
    /// the buffered funnel and send everything that follows live.
    @Published var shareUsageData: Bool = false
}

// MARK: - Welcome Body

struct WelcomeBody: View {
    @ObservedObject var state: WelcomeState

    @Environment(\.theme) private var theme
    @State private var visible = false

    var body: some View {
        OnboardingHeroBody(
            illustrationAsset: "osaurus-main",
            headline: "Own your AI.",
            subtitle:
                "Runs on your Mac. Your chats, files, and keys stay with you. No account, no cloud required."
        ) {
            usageOptIn
        }
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.98)
        .animation(.easeOut(duration: 0.5), value: visible)
        .onAppearAfter(0.05) { visible = true }
    }

    /// Subtle opt-in rendered as a custom checkbox row. The native
    /// `.checkbox` toggle style was nearly invisible on the light hero, so we
    /// draw our own SF Symbol box with theme colors for reliable contrast.
    private var usageOptIn: some View {
        Button {
            state.shareUsageData.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: state.shareUsageData ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(
                        state.shareUsageData ? theme.accentColor : theme.tertiaryText
                    )
                Text("Share anonymous usage data to help improve Osaurus", bundle: .module)
                    .font(theme.font(size: 12))
                    .foregroundColor(theme.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(state.shareUsageData ? [.isSelected] : [])
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
            VStack(spacing: 12) {
                WelcomeBody(state: WelcomeState())
                    .frame(height: 420)
                WelcomeCTA(onContinue: {})
            }
            .frame(width: OnboardingMetrics.windowWidth, height: 540)
        }
    }
#endif
