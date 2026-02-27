//
//  OnboardingView.swift
//  osaurus
//
//  Main container view managing the onboarding flow state and navigation.
//

import SwiftUI

// MARK: - Onboarding Step

/// Steps in the onboarding flow
public enum OnboardingStep: Int, CaseIterable {
    case welcome
    case choosePath
    case localDownload
    case apiSetup
    case complete
    case identitySetup
    case walkthrough
}

// MARK: - Navigation Direction

private enum NavigationDirection {
    case forward
    case backward
}

// MARK: - Onboarding View

public struct OnboardingView: View {
    /// Callback when onboarding is complete
    let onComplete: () -> Void

    @Environment(\.theme) private var theme
    @State private var currentStep: OnboardingStep = .welcome
    @State private var selectedPath: OnboardingSetupPath? = nil
    @State private var navigationDirection: NavigationDirection = .forward
    @State private var wantsWalkthrough = false

    public init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
    }

    public var body: some View {
        ZStack {
            // Glass background layers
            glassBackground

            // Content with staggered transitions
            contentView
                .transition(slideTransition)
                .id(currentStep)

            // Close button (top-right corner)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer()
                    OnboardingCloseButton(action: finishOnboarding)
                        .padding(.top, 14)
                        .padding(.trailing, 14)
                }
                Spacer()
            }
            .ignoresSafeArea()
        }
        .frame(width: OnboardingLayout.windowWidth, height: OnboardingLayout.windowHeight)
    }

    // MARK: - Content View

    @ViewBuilder
    private var contentView: some View {
        switch currentStep {
        case .welcome:
            OnboardingWelcomeView {
                navigateTo(.choosePath, direction: .forward)
            }

        case .choosePath:
            OnboardingChoosePathView(
                onSelectLocal: {
                    selectedPath = .local
                    navigateTo(.localDownload, direction: .forward)
                },
                onSelectAPI: {
                    selectedPath = .apiProvider
                    navigateTo(.apiSetup, direction: .forward)
                },
                onSelectFoundation: {
                    selectedPath = .appleFoundation
                    navigateTo(.complete, direction: .forward)
                }
            )

        case .localDownload:
            OnboardingLocalDownloadView(
                onComplete: {
                    navigateTo(.complete, direction: .forward)
                },
                onSkip: {
                    navigateTo(.complete, direction: .forward)
                },
                onBack: {
                    navigateTo(.choosePath, direction: .backward)
                }
            )

        case .apiSetup:
            OnboardingAPISetupView(
                onComplete: {
                    navigateTo(.complete, direction: .forward)
                },
                onBack: {
                    navigateTo(.choosePath, direction: .backward)
                }
            )

        case .complete:
            OnboardingCompleteView(
                onWalkthrough: {
                    wantsWalkthrough = true
                    navigateToIdentityOrNext()
                },
                onSkip: {
                    wantsWalkthrough = false
                    navigateToIdentityOrNext()
                },
                onSettings: {
                    finishOnboarding()
                    NotificationCenter.default.post(name: NSNotification.Name("ShowManagement"), object: nil)
                }
            )

        case .identitySetup:
            OnboardingIdentitySetupView(
                onComplete: proceedAfterIdentity,
                onSkip: proceedAfterIdentity,
                onBack: {
                    navigateTo(.complete, direction: .backward)
                }
            )

        case .walkthrough:
            OnboardingWalkthroughView {
                finishOnboarding()
            }
        }
    }

    // MARK: - Slide Transition

    private var slideTransition: AnyTransition {
        let offset: CGFloat = 40
        let insertionOffset = navigationDirection == .forward ? offset : -offset
        let removalOffset = navigationDirection == .forward ? -offset : offset

        return .asymmetric(
            insertion: .opacity
                .combined(with: .offset(x: insertionOffset))
                .combined(with: .scale(scale: 0.98)),
            removal: .opacity
                .combined(with: .offset(x: removalOffset))
                .combined(with: .scale(scale: 0.98))
        )
    }

    // MARK: - Glass Background

    private var glassBackground: some View {
        ZStack {
            // Base material layer
            if theme.glassEnabled {
                Rectangle()
                    .fill(.ultraThinMaterial)
            }

            // Semi-transparent background
            theme.primaryBackground
                .opacity(theme.glassEnabled ? 0.85 : 1.0)

            // Gradient overlay for depth
            LinearGradient(
                colors: [
                    theme.accentColor.opacity(theme.isDark ? 0.08 : 0.04),
                    Color.clear,
                    theme.accentColor.opacity(theme.isDark ? 0.04 : 0.02),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Subtle radial gradient for ambient glow
            RadialGradient(
                colors: [
                    theme.accentColor.opacity(0.06),
                    Color.clear,
                ],
                center: .top,
                startRadius: 0,
                endRadius: 400
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Navigation

    private func navigateTo(_ step: OnboardingStep, direction: NavigationDirection) {
        navigationDirection = direction
        withAnimation(theme.springAnimation(responseMultiplier: 0.8)) {
            currentStep = step
        }
    }

    private func navigateToIdentityOrNext() {
        if OsaurusIdentity.exists() {
            proceedAfterIdentity()
        } else {
            navigateTo(.identitySetup, direction: .forward)
        }
    }

    private func proceedAfterIdentity() {
        if wantsWalkthrough {
            navigateTo(.walkthrough, direction: .forward)
        } else {
            finishOnboarding()
        }
    }

    private func finishOnboarding() {
        OnboardingService.shared.completeOnboarding()
        onComplete()
    }
}

// MARK: - Onboarding Close Button

private struct OnboardingCloseButton: View {
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(theme.secondaryBackground.opacity(isHovered ? 0.9 : 0.5))

                if isHovered {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.red.opacity(0.15),
                                    Color.clear,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(isHovered ? Color.red.opacity(0.9) : theme.secondaryText)
            }
            .frame(width: 26, height: 26)
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                theme.glassEdgeLight.opacity(isHovered ? 0.3 : 0.15),
                                (isHovered ? Color.red : theme.primaryBorder).opacity(isHovered ? 0.2 : 0.1),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isHovered ? Color.red.opacity(0.2) : .clear,
                radius: 6,
                x: 0,
                y: 2
            )
            .scaleEffect(isHovered ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingView_Previews: PreviewProvider {
        static var previews: some View {
            OnboardingView(onComplete: {})
                .frame(width: OnboardingLayout.windowWidth, height: OnboardingLayout.windowHeight)
        }
    }
#endif
