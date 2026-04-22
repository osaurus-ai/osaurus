//
//  OnboardingIdentitySetupView.swift
//  osaurus
//
//  Onboarding step for creating a cryptographic identity.
//  Handles key generation, recovery code display, and skip.
//

import AppKit
import SwiftUI

// MARK: - Identity Setup Phase

private enum IdentitySetupPhase {
    case prompt
    case generating
    case recovery(IdentityInfo)
    case error(String)
}

// MARK: - Identity Setup View

struct OnboardingIdentitySetupView: View {
    let onComplete: () -> Void
    let onSkip: () -> Void
    let onBack: () -> Void

    @Environment(\.theme) private var theme
    @State private var phase: IdentitySetupPhase = .prompt
    @State private var hasAppeared = false

    var body: some View {
        Group {
            switch phase {
            case .prompt, .error:
                promptScaffold
            case .generating:
                generatingScaffold
            case .recovery(let info):
                recoveryScaffold(info: info)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppearAfter(OnboardingMetrics.appearDelay) { hasAppeared = true }
    }

    // MARK: - Prompt Scaffold

    private var promptScaffold: some View {
        OnboardingScaffold(
            title: "Create Your Identity",
            subtitle: "Generate a cryptographic identity for you and your agents. Stored securely in iCloud Keychain.",
            onBack: onBack,
            content: {
                VStack(spacing: 0) {
                    ZStack {
                        Circle()
                            .fill(theme.accentColor)
                            .blur(radius: 40)
                            .frame(width: 80, height: 80)
                            .opacity(hasAppeared ? 0.35 : 0)

                        Image(systemName: "person.badge.key.fill")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(theme.accentColor)
                            .opacity(hasAppeared ? 1 : 0)
                            .scaleEffect(hasAppeared ? 1 : 0.7)
                            .animation(theme.springAnimation(), value: hasAppeared)
                    }
                    .padding(.bottom, 8)

                    if case .error(let message) = phase {
                        Text(message)
                            .font(theme.font(size: 12, weight: .medium))
                            .foregroundColor(theme.errorColor)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.errorColor.opacity(0.1))
                            )
                            .padding(.top, 12)
                    }
                }
            },
            cta: {
                VStack(spacing: 14) {
                    OnboardingPrimaryButton(title: "Generate Identity", action: generateIdentity)
                        .frame(width: OnboardingMetrics.ctaWidth)
                        .opacity(hasAppeared ? 1 : 0)
                        .scaleEffect(hasAppeared ? 1 : 0.95)
                        .animation(theme.springAnimation().delay(0.35), value: hasAppeared)

                    OnboardingTextButton(title: "Skip for now", action: onSkip)
                        .opacity(hasAppeared ? 1 : 0)
                        .animation(.easeOut(duration: 0.3).delay(0.4), value: hasAppeared)
                }
            }
        )
    }

    // MARK: - Generating Scaffold

    private var generatingScaffold: some View {
        VStack(spacing: 0) {
            Spacer()

            ProgressView()
                .scaleEffect(1.2)

            Spacer().frame(height: 20)

            Text("Generating identity...", bundle: .module)
                .font(theme.font(size: 15, weight: .medium))
                .foregroundColor(theme.secondaryText)

            Spacer()
        }
    }

    // MARK: - Recovery Scaffold

    private func recoveryScaffold(info: IdentityInfo) -> some View {
        OnboardingScaffold(
            content: {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.warningColor)
                        Text("Save this recovery code. It won't be shown again.", bundle: .module)
                            .font(theme.font(size: 13, weight: .semibold))
                            .foregroundColor(theme.warningColor)
                    }
                    .padding(.bottom, 16)

                    OnboardingGlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("RECOVERY CODE", bundle: .module)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(theme.tertiaryText)
                                .tracking(1)

                            Text(info.recovery.code)
                                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                                .foregroundColor(theme.primaryText)
                                .textSelection(.enabled)

                            Divider()
                                .background(theme.secondaryBorder)

                            HStack(spacing: 6) {
                                Text("Master Address", bundle: .module)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(theme.tertiaryText)
                                Text(info.osaurusId)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(theme.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                recoveryBullet(L("Single-use — consumed on recovery"))
                                recoveryBullet(L("Store in a safe place"))
                                recoveryBullet(L("Cannot be retrieved by Osaurus"))
                            }
                            .padding(.top, 2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    }
                }
            },
            cta: {
                HStack(spacing: 12) {
                    OnboardingSecondaryButton(title: "Copy Code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(info.recovery.code, forType: .string)
                    }
                    .frame(maxWidth: 140)

                    OnboardingPrimaryButton(title: "Continue", action: onComplete)
                        .frame(maxWidth: 140)
                }
            }
        )
    }

    // MARK: - Helpers

    private func recoveryBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
            Text(text)
                .font(theme.font(size: 11))
                .foregroundColor(theme.secondaryText)
        }
    }

    private func generateIdentity() {
        phase = .generating

        Task {
            do {
                let info = try await OsaurusIdentity.setup()
                await MainActor.run {
                    withAnimation(theme.springAnimation()) {
                        phase = .recovery(info)
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation(theme.springAnimation()) {
                        phase = .error(error.localizedDescription)
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingIdentitySetupView_Previews: PreviewProvider {
        static var previews: some View {
            OnboardingIdentitySetupView(
                onComplete: {},
                onSkip: {},
                onBack: {}
            )
            .frame(width: OnboardingMetrics.windowWidth, height: 640)
        }
    }
#endif
