//
//  OnboardingView.swift
//  osaurus
//
//  Main container view managing the onboarding flow state and navigation.
//
//  Architecture: a single `OnboardingChromeShell` is rendered at this level
//  with structural chrome (back button position, title slot, close button,
//  footer layout) that stays pixel-stable across step transitions. The six
//  animated slots — title, body, progress dots, footer caption, secondary
//  text, primary CTA — slide together as a single visual unit when the step
//  changes. Each step's mutable state lives in a `@StateObject` here so
//  values survive the slide-out / slide-in.
//

import SwiftUI

// MARK: - Onboarding Step

public enum OnboardingStep: Int, CaseIterable {
    case welcome
    case createAgent
    case configureAI
    case identitySetup
    case walkthrough
}

// MARK: - Navigation Direction

enum OnboardingDirection {
    case forward
    case backward
}

// MARK: - Onboarding View

public struct OnboardingView: View {
    let onComplete: () -> Void
    let onPreferredSizeChange: ((CGSize) -> Void)?
    let forceShowIdentity: Bool

    @Environment(\.theme) private var theme
    @State private var currentStep: OnboardingStep
    @State private var direction: OnboardingDirection = .forward

    @StateObject private var createAgentState = CreateAgentState()
    @StateObject private var configureAIState = ConfigureAIState()
    @StateObject private var identityState = IdentityState()
    @StateObject private var walkthroughState = WalkthroughState()

    private static let progressSteps: [OnboardingStep] = [
        .createAgent, .configureAI, .identitySetup, .walkthrough,
    ]

    public init(
        forceShowIdentity: Bool = false,
        onPreferredSizeChange: ((CGSize) -> Void)? = nil,
        onComplete: @escaping () -> Void
    ) {
        self.forceShowIdentity = forceShowIdentity
        self.onPreferredSizeChange = onPreferredSizeChange
        self.onComplete = onComplete
        _currentStep = State(initialValue: forceShowIdentity ? .identitySetup : .welcome)
    }

    public var body: some View {
        ZStack {
            glassBackground

            OnboardingChromeShell(
                onBack: chromeOnBack,
                onClose: finishOnboarding,
                title: { titleSlot },
                progressIndicator: { progressSlot },
                footerCaption: { footerCaptionSlot },
                secondary: { secondarySlot },
                body: { bodySlot },
                cta: { ctaSlot }
            )
        }
        .frame(width: OnboardingMetrics.windowWidth, height: OnboardingMetrics.windowHeight)
        .onAppear {
            onPreferredSizeChange?(
                CGSize(
                    width: OnboardingMetrics.windowWidth,
                    height: OnboardingMetrics.windowHeight
                )
            )
        }
    }

    // MARK: - Animated slots

    @ViewBuilder
    private var titleSlot: some View {
        ZStack {
            stepTitleText
                .id(currentStep)
                .transition(slideTransition)
        }
    }

    @ViewBuilder
    private var stepTitleText: some View {
        if let title = chromeTitle {
            Text(title, bundle: .module)
                .font(theme.font(size: OnboardingMetrics.titleSize, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var progressSlot: some View {
        ZStack {
            stepProgressDots
                .id(currentStep)
                .transition(slideTransition)
        }
    }

    @ViewBuilder
    private var stepProgressDots: some View {
        if let index = progressIndex(for: currentStep) {
            OnboardingStepIndicator(current: index, total: Self.progressSteps.count)
        }
    }

    @ViewBuilder
    private var footerCaptionSlot: some View {
        ZStack {
            stepFooterCaptionText
                .id(currentStep)
                .transition(slideTransition)
        }
    }

    /// When a step has no caption we reserve the vertical footprint
    /// with a transparent `Color.clear` block (hidden from VoiceOver)
    /// so the action row's vertical position stays stable across
    /// step transitions.
    @ViewBuilder
    private var stepFooterCaptionText: some View {
        if let caption = chromeFooterCaption {
            Text(caption, bundle: .module)
                .font(theme.font(size: OnboardingMetrics.captionSize))
                .foregroundColor(theme.tertiaryText)
                .multilineTextAlignment(.center)
                .lineLimit(1)
        } else {
            Color.clear
                .frame(height: footerCaptionLineHeight)
                .accessibilityHidden(true)
        }
    }

    /// Approximate height of one caption line at
    /// `OnboardingMetrics.captionSize`.
    private var footerCaptionLineHeight: CGFloat {
        OnboardingMetrics.captionSize + 4
    }

    @ViewBuilder
    private var secondarySlot: some View {
        ZStack {
            stepSecondary
                .id(currentStep)
                .transition(slideTransition)
        }
    }

    @ViewBuilder
    private var bodySlot: some View {
        ZStack {
            stepBody
                .id(currentStep)
                .transition(slideTransition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var ctaSlot: some View {
        ZStack {
            stepCTA
                .id(currentStep)
                .transition(slideTransition)
        }
    }

    // MARK: - Step content dispatch

    @ViewBuilder
    private var stepBody: some View {
        switch currentStep {
        case .welcome:
            WelcomeBody()
        case .createAgent:
            CreateAgentBody(state: createAgentState)
        case .configureAI:
            ConfigureAIBody(state: configureAIState)
        case .identitySetup:
            IdentityBody(state: identityState)
        case .walkthrough:
            WalkthroughBody(state: walkthroughState)
        }
    }

    @ViewBuilder
    private var stepCTA: some View {
        switch currentStep {
        case .welcome:
            // Welcome doesn't fit the wizard pattern — center the CTA in
            // the action row by stretching it to fill the available width.
            HStack {
                Spacer(minLength: 0)
                WelcomeCTA(onContinue: { advance(to: .createAgent) })
                Spacer(minLength: 0)
            }
        case .createAgent:
            CreateAgentCTA(
                state: createAgentState,
                onContinue: { advance(to: .configureAI) }
            )
        case .configureAI:
            ConfigureAICTA(
                state: configureAIState,
                onComplete: { advance(to: .identitySetup) }
            )
        case .identitySetup:
            IdentityCTA(
                state: identityState,
                onComplete: { advance(to: .walkthrough) }
            )
        case .walkthrough:
            WalkthroughCTA(
                state: walkthroughState,
                onFinish: finishOnboarding
            )
        }
    }

    @ViewBuilder
    private var stepSecondary: some View {
        switch currentStep {
        case .welcome:
            EmptyView()
        case .createAgent:
            CreateAgentSecondary(onSkip: { advance(to: .configureAI) })
        case .configureAI:
            ConfigureAISecondary(state: configureAIState, onComplete: { advance(to: .identitySetup) })
        case .identitySetup:
            IdentitySecondary(state: identityState, onSkip: { advance(to: .walkthrough) })
        case .walkthrough:
            EmptyView()
        }
    }

    // MARK: - Chrome content (reads from per-step state)

    private var chromeTitle: LocalizedStringKey? {
        switch currentStep {
        case .welcome: return nil
        case .createAgent: return "Create your agent"
        case .configureAI: return "Configure your AI"
        case .identitySetup: return "Set up identity"
        case .walkthrough: return "How it works"
        }
    }

    private var chromeFooterCaption: LocalizedStringKey? {
        switch currentStep {
        case .welcome: return nil
        case .createAgent: return nil
        case .configureAI: return configureAIState.footerCaption
        case .identitySetup: return identityState.footerCaption
        case .walkthrough: return nil
        }
    }

    private var chromeOnBack: (() -> Void)? {
        switch currentStep {
        case .welcome:
            return nil
        case .createAgent:
            return { advance(to: .welcome, direction: .backward) }
        case .configureAI:
            return { configureAIState.handleBack { advance(to: .createAgent, direction: .backward) } }
        case .identitySetup:
            return { advance(to: .configureAI, direction: .backward) }
        case .walkthrough:
            return {
                walkthroughState.handleBack { advance(to: .identitySetup, direction: .backward) }
            }
        }
    }

    // MARK: - Step indicator

    /// 1-indexed position in the global progress dots, or `nil` to hide the
    /// indicator. Welcome has no progress (it's the title screen) and the
    /// Walkthrough has its own internal page indicator inside the body —
    /// showing both at once (global "4 of 4" plus internal "1 of 4") just
    /// reads as duplicated dots.
    private func progressIndex(for step: OnboardingStep) -> Int? {
        if step == .walkthrough { return nil }
        guard let idx = Self.progressSteps.firstIndex(of: step) else { return nil }
        return idx + 1
    }

    // MARK: - Slide Transition (pure horizontal)

    private var slideTransition: AnyTransition {
        let dx = OnboardingMetrics.slideOffset
        let inOffset = direction == .forward ? dx : -dx
        let outOffset = direction == .forward ? -dx : dx
        return .asymmetric(
            insertion: .offset(x: inOffset),
            removal: .offset(x: outOffset)
        )
    }

    // MARK: - Glass Background

    private var glassBackground: some View {
        ZStack {
            if theme.glassEnabled {
                Rectangle().fill(.ultraThinMaterial)
            }
            theme.primaryBackground.opacity(theme.glassEnabled ? 0.85 : 1.0)

            LinearGradient(
                colors: [
                    theme.accentColor.opacity(theme.isDark ? 0.08 : 0.04),
                    Color.clear,
                    theme.accentColor.opacity(theme.isDark ? 0.04 : 0.02),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [theme.accentColor.opacity(0.06), Color.clear],
                center: .top,
                startRadius: 0,
                endRadius: 400
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Navigation

    private func advance(to step: OnboardingStep, direction: OnboardingDirection = .forward) {
        self.direction = direction
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            currentStep = step
        }
    }

    private func finishOnboarding() {
        OnboardingService.shared.completeOnboarding()
        onComplete()
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingView_Previews: PreviewProvider {
        static var previews: some View {
            OnboardingView(onComplete: {})
                .frame(width: OnboardingMetrics.windowWidth, height: OnboardingMetrics.windowHeight)
        }
    }
#endif
