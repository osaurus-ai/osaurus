import SwiftUI

/// Inline Credits-tab entry for ongoing, first-time, and referral campaigns.
/// Eligibility remains entirely server-authoritative.
struct CreditsRedeemCodeCard: View {
    let isEnabled: Bool

    @Environment(\.theme) private var theme
    @StateObject private var redemption = RedeemCodeService(context: .credits)
    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 11) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Have a code?", bundle: .module)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(
                        "Enter it below and we’ll take it from here.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                }
                Spacer(minLength: 8)

                Text("Optional", bundle: .module)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.tertiaryBackground.opacity(0.7)))
            }

            if case .success(let response) = redemption.state {
                successView(response)
            } else {
                entryView
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.cardBackground)
                .overlay(
                    LinearGradient(
                        colors: [theme.accentColor.opacity(0.045), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.cardBorder, lineWidth: 1)
        )
    }

    private var entryView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                TextField(
                    text: $redemption.code,
                    prompt: Text("Enter your code", bundle: .module)
                ) {
                    Text("Enter your code", bundle: .module)
                }
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .frame(maxWidth: .infinity)
                .focused($codeFocused)
                .disabled(!isEnabled || redemption.isSubmitting)
                .onChange(of: redemption.code) { _, _ in
                    redemption.noteCodeEdited()
                }
                .onSubmit { submitIfPossible() }

                Rectangle()
                    .fill(theme.inputBorder.opacity(0.7))
                    .frame(width: 1, height: 22)
                    .padding(.horizontal, 8)

                redeemButton
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                codeFocused ? theme.accentColor : theme.inputBorder,
                                lineWidth: codeFocused ? 2 : 1
                            )
                    )
            )

            if !isEnabled {
                Text("Set up an Osaurus Identity to redeem codes.", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            } else if case .failure(let message) = redemption.state {
                Label {
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                .font(.system(size: 12))
                .foregroundColor(theme.errorColor)
            }

            if isEnabled, let retryDeadline = redemption.retryNotBefore {
                RedeemRetryCountdownHint(deadline: retryDeadline)
            }
        }
    }

    private var redeemButton: some View {
        let enabled = isEnabled && redemption.canSubmit
        return Button(action: submitIfPossible) {
            ZStack {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Redeem", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                }
                .opacity(redemption.isSubmitting ? 0 : 1)

                if redemption.isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.isDark ? theme.primaryBackground : .white)
                }
            }
            .foregroundColor(enabled ? (theme.isDark ? theme.primaryBackground : .white) : theme.tertiaryText)
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(enabled ? theme.accentColor : theme.tertiaryBackground.opacity(0.65))
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func successView(_ response: OsaurusRouterRedeemCodeResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.successColor)
                VStack(alignment: .leading, spacing: 4) {
                    Group {
                        if response.alreadyRedeemed {
                            Text("Code already redeemed", bundle: .module)
                        } else {
                            Text("Code redeemed", bundle: .module)
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    // Never interpret the administrator-controlled response.
                    Text(verbatim: response.redemptionMessage)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    redemption.resetForAnotherCode()
                    DispatchQueue.main.async { codeFocused = true }
                } label: {
                    Text("Redeem another code", bundle: .module)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if response.referralPending {
                Label {
                    Text(
                        "Referral linked. The reward is applied after the first paid top-up.",
                        bundle: .module
                    )
                } icon: {
                    Image(systemName: "person.2.fill")
                }
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.successColor.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.successColor.opacity(0.16), lineWidth: 1)
                )
        )
    }

    private func submitIfPossible() {
        guard isEnabled, redemption.canSubmit else { return }
        codeFocused = false
        Task { await redemption.submit() }
    }
}
