//
//  OnboardingConsentView.swift
//  osaurus
//
//  Final onboarding step — ask permission to collect anonymous usage data.
//
//  This is intentionally the *last* step: the whole point of the telemetry
//  is to find where people drop out of onboarding, so the funnel events fire
//  as the user moves through the earlier steps. `TelemetryService` buffers
//  those events in memory and only sends them once the user makes a choice
//  here — granting flushes the buffer, declining discards it. A user who
//  X-es out before reaching this screen never consents, so nothing is sent.
//
//  The toggle defaults ON: this is a clear, transparent opt-out rather than
//  an opt-in, chosen to keep funnel coverage high while still giving the user
//  an obvious, one-tap way to decline.
//

import SwiftUI

// MARK: - State

@MainActor
final class ConsentState: ObservableObject {
    /// Whether the user agrees to share anonymous usage data. Defaults ON —
    /// see the file header for the opt-out rationale. The parent reads this
    /// when the user taps the final CTA and forwards it to
    /// `TelemetryService.setEnabled(_:)`.
    @Published var shareUsageData: Bool = true
}

// MARK: - Body

struct ConsentBody: View {
    @ObservedObject var state: ConsentState

    @Environment(\.theme) private var theme

    var body: some View {
        OnboardingTwoColumnBody(
            illustrationAsset: "osaurus-data",
            leftHeadline: "Help shape Osaurus",
            leftBody:
                "Osaurus is brand new. Knowing which steps trip people up — and which features get used — is how we make it better for everyone.",
            subtitle: "Anonymous, on by default, and yours to turn off right here."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                toggleCard
                privacyCard
            }
        }
    }

    // MARK: - Toggle card

    private var toggleCard: some View {
        OnboardingGlassCard {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(theme.accentColor.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }

                Text("Share anonymous usage data", bundle: .module)
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Toggle("", isOn: $state.shareUsageData)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(theme.accentColor)
                    .accessibilityLabel(Text("Share anonymous usage data", bundle: .module))
            }
            .padding(14)
        }
    }

    // MARK: - Privacy reassurance

    private var privacyCard: some View {
        OnboardingGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                bulletRow(
                    icon: "eye.slash.fill",
                    title: L("Never your content"),
                    detail: L("Your chats, prompts, files, and keys never leave your Mac.")
                )
                bulletRow(
                    icon: "person.fill.questionmark",
                    title: L("No accounts, no profiles"),
                    detail: L("Data is aggregated and anonymous — it isn't tied to you.")
                )
            }
            .padding(14)
        }
    }

    private func bulletRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(theme.successColor.opacity(0.12))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.successColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(detail)
                    .font(theme.font(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - CTA

struct ConsentCTA: View {
    let onFinish: () -> Void

    var body: some View {
        OnboardingBrandButton(title: "Start using Osaurus", action: onFinish)
            .frame(width: OnboardingMetrics.ctaWidthCompact)
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingConsentView_Previews: PreviewProvider {
        static var previews: some View {
            let state = ConsentState()
            return VStack {
                ConsentBody(state: state).frame(height: 460)
                ConsentCTA(onFinish: {})
            }
            .frame(width: OnboardingMetrics.windowWidth, height: 620)
        }
    }
#endif
