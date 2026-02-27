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
        VStack(spacing: 0) {
            // Back button
            OnboardingBackButton(action: onBack)
                .padding(.horizontal, OnboardingStyle.backButtonHorizontalPadding)
                .padding(.top, 14)
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.3).delay(0.1), value: hasAppeared)

            Spacer().frame(height: 10)

            switch phase {
            case .prompt, .error:
                promptContent
            case .generating:
                generatingContent
            case .recovery(let info):
                recoveryContent(info: info)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + OnboardingStyle.appearDelay) {
                hasAppeared = true
            }
        }
    }

    // MARK: - Prompt Content

    private var promptContent: some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(minHeight: 20, maxHeight: 40)

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

            Spacer().frame(height: 24)

            Text("Create Your Identity")
                .font(theme.font(size: 24, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .multilineTextAlignment(.center)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 15)
                .animation(.easeOut(duration: 0.5).delay(0.15), value: hasAppeared)

            Spacer().frame(height: 14)

            Text("Generate a cryptographic identity for you and your\nagents. Stored securely in iCloud Keychain.")
                .font(theme.font(size: 13))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 10)
                .animation(.easeOut(duration: 0.5).delay(0.25), value: hasAppeared)

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

            Spacer().frame(height: 32)

            OnboardingPrimaryButton(title: "Generate Identity", action: generateIdentity)
                .frame(maxWidth: 220)
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.95)
                .animation(theme.springAnimation().delay(0.35), value: hasAppeared)

            Spacer().frame(height: 16)

            OnboardingTextButton(title: "Skip for now", action: onSkip)
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.3).delay(0.4), value: hasAppeared)

            Spacer()
        }
        .padding(.horizontal, OnboardingStyle.backButtonHorizontalPadding + 5)
    }

    // MARK: - Generating Content

    private var generatingContent: some View {
        VStack(spacing: 0) {
            Spacer()

            ProgressView()
                .scaleEffect(1.2)

            Spacer().frame(height: 20)

            Text("Generating identity...")
                .font(theme.font(size: 15, weight: .medium))
                .foregroundColor(theme.secondaryText)

            Spacer()
        }
    }

    // MARK: - Recovery Content

    private func recoveryContent(info: IdentityInfo) -> some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(minHeight: 10, maxHeight: 30)

            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.warningColor)
                Text("Save this recovery code. It won't be shown again.")
                    .font(theme.font(size: 13, weight: .semibold))
                    .foregroundColor(theme.warningColor)
            }

            Spacer().frame(height: 16)

            OnboardingGlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("RECOVERY CODE")
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
                        Text("Master Address")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.tertiaryText)
                        Text(info.osaurusId)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        recoveryBullet("Single-use — consumed on recovery")
                        recoveryBullet("Store in a safe place")
                        recoveryBullet("Cannot be retrieved by Osaurus")
                    }
                    .padding(.top, 2)
                }
                .padding(18)
            }
            .padding(.horizontal, OnboardingStyle.backButtonHorizontalPadding + 5)

            Spacer().frame(height: 28)

            HStack(spacing: 12) {
                OnboardingSecondaryButton(title: "Copy Code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.recovery.code, forType: .string)
                }
                .frame(maxWidth: 140)

                OnboardingPrimaryButton(title: "Continue", action: onComplete)
                    .frame(maxWidth: 140)
            }
            .padding(.horizontal, OnboardingStyle.backButtonHorizontalPadding + 5)

            Spacer()
        }
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
            .frame(width: OnboardingLayout.windowWidth, height: OnboardingLayout.windowHeight)
        }
    }
#endif
