import SwiftUI

/// Inline Credits-tab entry for ongoing, first-time, and referral campaigns.
/// Eligibility remains entirely server-authoritative.
struct CreditsRedeemCodeCard: View {
    let isEnabled: Bool

    @Environment(\.theme) private var theme
    @StateObject private var redemption = RedeemCodeService(context: .credits)
    @FocusState private var codeFocused: Bool

    var body: some View {
        SettingsSection(title: "Have a Code?", subtitle: "Enter it below and we’ll take it from here.") {
            StatusChip(L("Optional"), tone: .neutral)
        } content: {
            if case .success(let response) = redemption.state {
                successView(response)
            } else {
                entryView
            }
        }
    }

    private var entryView: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s6) {
                SettingsTextField(
                    placeholder: "Enter your code",
                    text: $redemption.code,
                    monospaced: true,
                    focus: $codeFocused,
                    onSubmit: submitIfPossible
                )
                .disabled(!isEnabled || redemption.isSubmitting)
                .onChange(of: redemption.code) { _, _ in
                    redemption.noteCodeEdited()
                }

                redeemButton
            }

            if !isEnabled {
                Text("Set up an Osaurus Identity to redeem codes.", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            } else if case .failure(let message) = redemption.state {
                Label {
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                .textStyle(.caption)
                .foregroundColor(theme.status.error.foreground)
            }

            if isEnabled, let retryDeadline = redemption.retryNotBefore {
                RedeemRetryCountdownHint(deadline: retryDeadline)
            }
        }
    }

    private var redeemButton: some View {
        SettingsButton(
            .primary,
            "Redeem",
            icon: "sparkles",
            isLoading: redemption.isSubmitting,
            size: .compact,
            action: submitIfPossible
        )
        .disabled(!(isEnabled && redemption.canSubmit))
    }

    private func successView(_ response: OsaurusRouterRedeemCodeResponse) -> some View {
        // Never interpret the administrator-controlled response.
        SettingsCallout(
            icon: "checkmark.circle.fill",
            title: response.alreadyRedeemed ? "Code already redeemed" : "Code redeemed",
            message: response.referralPending
                ? "Referral linked. The reward is applied after the first paid top-up." : "",
            tone: .success,
            quote: response.redemptionMessage.isEmpty ? nil : response.redemptionMessage
        ) {
            SettingsButton(.secondary, "Redeem another code", size: .compact) {
                redemption.resetForAnotherCode()
                DispatchQueue.main.async { codeFocused = true }
            }
        }
    }

    private func submitIfPossible() {
        guard isEnabled, redemption.canSubmit else { return }
        codeFocused = false
        Task { await redemption.submit() }
    }
}
