import SwiftUI

/// First-run code entry hosted at the onboarding window root so it blocks the
/// chrome and guarantees the wallet owner's explicit Redeem action.
struct OnboardingRedeemCodeModal: View {
    @ObservedObject var welcomeState: WelcomeState
    @ObservedObject private var redemption: RedeemCodeService

    @Environment(\.theme) private var theme
    @FocusState private var codeFocused: Bool

    private let dialogWidth: CGFloat = 440
    private let dialogCornerRadius: CGFloat = 22

    init(state: WelcomeState) {
        welcomeState = state
        redemption = state.redeemCode
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { welcomeState.closeRedeemCode() }

            VStack(spacing: 0) {
                header
                content
                footer
            }
            .frame(width: dialogWidth)
            .background(dialogSurface)
            .clipShape(RoundedRectangle(cornerRadius: dialogCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: dialogCornerRadius, style: .continuous)
                    .strokeBorder(theme.primaryBorder.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: theme.shadowColor.opacity(0.28), radius: 30, y: 14)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand { welcomeState.closeRedeemCode() }
        .onAppear {
            if !redemption.succeeded {
                DispatchQueue.main.async { codeFocused = true }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 9) {
            if redemption.succeeded {
                ZStack {
                    Circle()
                        .fill(theme.successColor.opacity(0.12))
                        .overlay(
                            Circle()
                                .strokeBorder(theme.successColor.opacity(0.18), lineWidth: 1)
                        )
                    Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(theme.successColor)
                }
                .frame(width: 46, height: 46)
            }

            headerTitleText
                .font(theme.font(size: 20, weight: .semibold))
                .foregroundColor(theme.primaryText)

            headerSubtitleText
                .font(theme.font(size: 12))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 44)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .overlay(alignment: .topTrailing) {
            OnboardingCloseButton { welcomeState.closeRedeemCode() }
                .disabled(redemption.isSubmitting)
                .padding(.top, 14)
                .padding(.trailing, 14)
        }
    }

    @ViewBuilder
    private var content: some View {
        if case .success(let response) = redemption.state {
            successContent(response)
        } else {
            entryContent
        }
    }

    private var entryContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                TextField(
                    text: $redemption.code,
                    prompt: Text("Enter your code", bundle: .module)
                ) {
                    Text("Enter your code", bundle: .module)
                }
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .focused($codeFocused)
                .disabled(redemption.isSubmitting)
                .onChange(of: redemption.code) { _, _ in
                    redemption.noteCodeEdited()
                }
                .onSubmit {
                    guard redemption.canSubmit else { return }
                    Task { await redemption.submit() }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                codeFocused ? theme.accentColor : theme.inputBorder,
                                lineWidth: codeFocused ? 2 : 1
                            )
                    )
            )

            if case .failure(let message) = redemption.state {
                Label {
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                .font(theme.font(size: 12))
                .foregroundColor(theme.errorColor)
            } else if redemption.retryNotBefore == nil {
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Your code is checked securely when you redeem.", bundle: .module)
                        .font(theme.font(size: 11))
                }
                .foregroundColor(theme.tertiaryText)
            }

            if let retryDeadline = redemption.retryNotBefore {
                RedeemRetryCountdownHint(deadline: retryDeadline)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }

    private func successContent(_ response: OsaurusRouterRedeemCodeResponse) -> some View {
        VStack(spacing: 10) {
            // Plain Text is intentional: the administrator-controlled
            // response must never be interpreted as Markdown or HTML.
            Text(verbatim: response.redemptionMessage)
                .font(theme.font(size: 12))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.successColor.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(theme.successColor.opacity(0.16), lineWidth: 1)
                        )
                )

            if response.referralPending {
                Label {
                    Text(
                        "Your referral is linked. The reward is applied after the first paid top-up.",
                        bundle: .module
                    )
                } icon: {
                    Image(systemName: "person.2.fill")
                }
                .font(theme.font(size: 11))
                .foregroundColor(theme.tertiaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var headerTitleText: some View {
        if case .success(let response) = redemption.state {
            if response.alreadyRedeemed {
                Text("Already redeemed", bundle: .module)
            } else {
                Text("You’re all set", bundle: .module)
            }
        } else {
            Text("Enter a code", bundle: .module)
        }
    }

    @ViewBuilder
    private var headerSubtitleText: some View {
        if redemption.succeeded {
            Text("Your code was accepted.", bundle: .module)
        } else {
            Text("We’ll take it from here.", bundle: .module)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if redemption.succeeded {
                OnboardingBrandButton(
                    title: "Done",
                    action: { welcomeState.closeRedeemCode() }
                )
                .frame(maxWidth: .infinity)
                .keyboardShortcut(.defaultAction)
            } else {
                OnboardingCompactButton(title: "Cancel", style: .ghost) {
                    welcomeState.closeRedeemCode()
                }
                .disabled(redemption.isSubmitting)
                .frame(width: 92)

                OnboardingStatefulButton(
                    state: onboardingButtonState,
                    idleTitle: "Redeem",
                    loadingTitle: "Redeeming…",
                    successTitle: "Redeemed",
                    errorTitle: "Try Again",
                    action: { Task { await redemption.submit() } },
                    isEnabled: redemption.canSubmit
                )
                .frame(maxWidth: .infinity)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
    }

    private var onboardingButtonState: OnboardingButtonState {
        switch redemption.state {
        case .idle:
            return .idle
        case .submitting:
            return .loading
        case .success:
            return .success
        case .failure(let message):
            return .error(message)
        }
    }

    private var dialogSurface: some View {
        ZStack {
            if theme.glassEnabled {
                Rectangle().fill(.ultraThinMaterial)
            }
            theme.cardBackground.opacity(theme.glassEnabled ? 0.94 : 1)
            LinearGradient(
                colors: [
                    theme.accentColor.opacity(theme.isDark ? 0.10 : 0.055),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .center
            )
        }
    }
}
