//
//  OnboardingWalkthroughView.swift
//  osaurus
//
//  Optional 3-step walkthrough tutorial with polished animations.
//

import SwiftUI

// MARK: - Walkthrough Step

private struct WalkthroughStep {
    let title: String
    let body: String
    let suggestion: String?
    let icon: String
}

private let walkthroughSteps: [WalkthroughStep] = [
    WalkthroughStep(
        title: "Chat with AI",
        body: "Ask anything. Osaurus sends your message to your AI provider and streams the response.",
        suggestion: "Try: \"What can you help me with?\"",
        icon: "bubble.left.and.bubble.right"
    ),
    WalkthroughStep(
        title: "Skills",
        body:
            "Skills give your AI new abilities — like reading your calendar, drafting emails, or searching files.\n\nEnable them in Settings → Skills. Each one asks permission before accessing anything on your Mac.",
        suggestion: nil,
        icon: "wand.and.stars"
    ),
    WalkthroughStep(
        title: "Your data stays yours",
        body:
            "Conversations are stored on your Mac. Switch providers anytime — your history comes with you.\n\nThat's it. You're ready.",
        suggestion: nil,
        icon: "lock.shield"
    ),
]

// MARK: - Walkthrough View

struct OnboardingWalkthroughView: View {
    let onComplete: () -> Void

    @Environment(\.theme) private var theme
    @State private var currentStep = 0
    @State private var hasAppeared = false

    private var isLastStep: Bool {
        currentStep == walkthroughSteps.count - 1
    }

    private var step: WalkthroughStep {
        walkthroughSteps[currentStep]
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 35)

            // Step indicator
            OnboardingStepIndicator(current: currentStep + 1, total: walkthroughSteps.count)
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(0.1), value: hasAppeared)

            Spacer().frame(height: 8)

            // Step label
            Text("Step \(currentStep + 1) of \(walkthroughSteps.count)")
                .font(theme.font(size: 12, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(0.15), value: hasAppeared)

            Spacer().frame(height: 30)

            // Icon with glow
            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(0.15))
                    .frame(width: 90, height: 90)
                    .blur(radius: 20)

                Circle()
                    .fill(theme.cardBackground)
                    .frame(width: 80, height: 80)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        theme.accentColor.opacity(0.3),
                                        theme.primaryBorder.opacity(0.2),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )

                Image(systemName: step.icon)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }
            .id("icon-\(currentStep)")
            .transition(
                .asymmetric(
                    insertion: .scale(scale: 0.8).combined(with: .opacity),
                    removal: .scale(scale: 0.8).combined(with: .opacity)
                )
            )
            .opacity(hasAppeared ? 1 : 0)
            .animation(.easeOut(duration: 0.5).delay(0.2), value: hasAppeared)

            Spacer().frame(height: 24)

            // Title
            Text(step.title)
                .font(theme.font(size: 22, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .multilineTextAlignment(.center)
                .id("title-\(currentStep)")
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    )
                )
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(0.25), value: hasAppeared)

            Spacer().frame(height: 14)

            // Body
            Text(step.body)
                .font(theme.font(size: 13))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
                .id("body-\(currentStep)")
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    )
                )
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(0.3), value: hasAppeared)

            // Suggestion (if present)
            if let suggestion = step.suggestion {
                Spacer().frame(height: 18)

                HStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 13))
                        .foregroundColor(theme.accentColor)

                    Text(suggestion)
                        .font(theme.font(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText.opacity(0.9))
                        .italic()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                        .fill(theme.accentColor.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: OnboardingLayout.buttonCornerRadius, style: .continuous)
                                .strokeBorder(theme.accentColor.opacity(0.2), lineWidth: 1)
                        )
                )
                .id("suggestion-\(currentStep)")
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    )
                )
                .opacity(hasAppeared ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(0.35), value: hasAppeared)
            }

            Spacer()
                .frame(minHeight: 20)

            // Navigation buttons
            HStack(spacing: 12) {
                if currentStep > 0 {
                    OnboardingSecondaryButton(title: "Back") {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentStep -= 1
                        }
                    }
                    .frame(width: 120)
                }

                if isLastStep {
                    OnboardingShimmerButton(title: "Start using Osaurus") {
                        onComplete()
                    }
                    .frame(width: 200)
                } else {
                    OnboardingPrimaryButton(title: "Next") {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentStep += 1
                        }
                    }
                    .frame(width: 120)
                }
            }
            .opacity(hasAppeared ? 1 : 0)
            .animation(.easeOut(duration: 0.5).delay(0.4), value: hasAppeared)

            Spacer().frame(height: 40)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation {
                    hasAppeared = true
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingWalkthroughView_Previews: PreviewProvider {
        static var previews: some View {
            OnboardingWalkthroughView(onComplete: {})
                .frame(width: OnboardingLayout.windowWidth, height: OnboardingLayout.windowHeight)
        }
    }
#endif
