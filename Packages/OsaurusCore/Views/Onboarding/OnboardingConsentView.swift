//
//  OnboardingConsentView.swift
//  osaurus
//
//  Final onboarding step — ask permission to send crash reports.
//
//  Usage analytics consent now lives on the *Welcome* step (the first
//  screen): `TelemetryService` buffers the onboarding funnel in memory, and
//  opting in up front is what lets us flush that buffer and capture the
//  drop-off point even when someone bails partway through. This screen is
//  therefore crash-reporting only.
//
//  Crash reports (Sentry) are opt-OUT — the switch defaults ON. Crashes carry
//  no PII, so reporting on by default maximises the signal that fixes real
//  bugs; one tap turns it off.
//

import SwiftUI

// MARK: - State

@MainActor
final class ConsentState: ObservableObject {
    /// Whether the user agrees to send crash reports. Opt-out, so it defaults
    /// ON. The parent forwards it to `CrashReportingService.setEnabled(_:)`.
    @Published var shareCrashReports: Bool = true
}

// MARK: - Body

struct ConsentBody: View {
    @ObservedObject var state: ConsentState

    @Environment(\.theme) private var theme

    var body: some View {
        OnboardingTwoColumnBody(
            illustrationAsset: "osaurus-data",
            leftHeadline: "Help us squash bugs",
            leftBody:
                "If Osaurus crashes, an anonymous report shows us what went wrong so we can fix it."
        ) {
            VStack(alignment: .leading, spacing: OnboardingMetrics.cardSpacing) {
                OnboardingRowCard(
                    icon: .symbol("ant"),
                    title: "Send crash reports",
                    subtitle: "No chats, prompts, files, or keys are ever included.",
                    accessory: .toggle(isOn: state.shareCrashReports),
                    isSelected: state.shareCrashReports
                ) {
                    state.shareCrashReports.toggle()
                }
                crashReportsLearnMore
                privacyCard
            }
        }
    }

    // MARK: - Diagnostics disclosure

    /// Ties the crash-report consent to the matching diagnostics disclosure.
    private var crashReportsLearnMore: some View {
        MarkdownLinkText(
            markdown: OsaurusWebLinks.crashDiagnosticsMarkdown,
            font: theme.font(size: 12),
            textColor: theme.secondaryText,
            linkColor: theme.accentColor
        )
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
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
                    detail: L("Data is aggregated and anonymous, so it isn't tied to you.")
                )
            }
            .padding(.horizontal, OnboardingMetrics.cardPaddingH)
            .padding(.vertical, OnboardingMetrics.cardPaddingV)
        }
    }

    private func bulletRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(theme.successColor.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.successColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(theme.font(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(detail)
                    .font(theme.font(size: 12))
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
            .fixedSize(horizontal: true, vertical: false)
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
