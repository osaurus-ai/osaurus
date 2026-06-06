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
    case sandboxSetup
    case choosePlugins
    case walkthrough
    case consent
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
    /// Guards the one-shot `onboarding_started` + first `stepViewed` emit.
    @State private var didTrackStart = false

    @StateObject private var createAgentState = CreateAgentState()
    @StateObject private var configureAIState = ConfigureAIState()
    @StateObject private var identityState = IdentityState()
    @StateObject private var sandboxSetupState = SandboxSetupState()
    @StateObject private var choosePluginsState = ChoosePluginsState()
    @StateObject private var walkthroughState = WalkthroughState()
    @StateObject private var consentState = ConsentState()

    // Identity and sandbox are no longer surfaced as their own steps —
    // they're configured implicitly on completion (see `finishOnboarding`).
    // The `.identitySetup` / `.sandboxSetup` cases are kept in the enum and
    // the step switches so the DEBUG `forceShowIdentity` reset flow still
    // works, but they're absent from the normal forward flow.

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
                onClose: { finishOnboarding(via: .closeButton) },
                title: { titleSlot },
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
            // `.onAppear` can fire more than once (window re-activation); the
            // flag keeps "started" and the first step-view to a single emit.
            if !didTrackStart {
                didTrackStart = true
                OnboardingTelemetry.started()
                OnboardingTelemetry.stepViewed(currentStep)
            }
        }
        .onChange(of: currentStep) { _, newStep in
            OnboardingTelemetry.stepViewed(newStep)
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
        case .sandboxSetup:
            SandboxSetupBody(state: sandboxSetupState)
        case .choosePlugins:
            ChoosePluginsBody(state: choosePluginsState)
        case .walkthrough:
            WalkthroughBody(state: walkthroughState)
        case .consent:
            ConsentBody(state: consentState)
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
            // Centered (like Welcome) — there's no secondary action on this
            // step, so a trailing-pinned CTA looked lopsided.
            HStack {
                Spacer(minLength: 0)
                CreateAgentCTA(
                    state: createAgentState,
                    onContinue: { advance(to: .configureAI) }
                )
                Spacer(minLength: 0)
            }
        case .configureAI:
            ConfigureAICTA(
                state: configureAIState,
                onComplete: { advance(to: .choosePlugins) }
            )
        case .identitySetup:
            IdentityCTA(
                state: identityState,
                onComplete: { advanceFromIdentity() }
            )
        case .sandboxSetup:
            SandboxSetupCTA(
                state: sandboxSetupState,
                onComplete: { advance(to: .choosePlugins) }
            )
        case .choosePlugins:
            ChoosePluginsCTA(
                state: choosePluginsState,
                onComplete: { advance(to: .walkthrough) }
            )
        case .walkthrough:
            WalkthroughCTA(
                state: walkthroughState,
                onContinue: { advance(to: .consent) }
            )
        case .consent:
            ConsentCTA(onFinish: {
                // Record both consent choices *before* finishing. For usage
                // data, granting flushes the funnel events buffered during
                // onboarding and declining drops them; `finishOnboarding` then
                // fires `onboarding_completed`, sent or dropped per that choice.
                // Crash reporting is independent (opt-out) and applied here too.
                TelemetryService.shared.setEnabled(consentState.shareUsageData)
                CrashReportingService.shared.setEnabled(consentState.shareCrashReports)
                finishOnboarding(via: .finishButton)
            })
        }
    }

    @ViewBuilder
    private var stepSecondary: some View {
        switch currentStep {
        case .welcome:
            EmptyView()
        case .createAgent:
            // Non-skippable by design — creating a dino is the whole point of
            // this step, and the CTA is always enabled so it's a single tap.
            EmptyView()
        case .configureAI:
            ConfigureAISecondary(state: configureAIState, onComplete: { advance(to: .choosePlugins) })
        case .identitySetup:
            IdentitySecondary(
                state: identityState,
                onSkip: {
                    OnboardingTelemetry.stepSkipped(.identitySetup)
                    advanceFromIdentity()
                }
            )
        case .sandboxSetup:
            SandboxSetupSecondary(onSkip: {
                OnboardingTelemetry.stepSkipped(.sandboxSetup)
                advance(to: .choosePlugins)
            })
        case .choosePlugins:
            ChoosePluginsSecondary(onSkip: {
                OnboardingTelemetry.stepSkipped(.choosePlugins)
                advance(to: .walkthrough)
            })
        case .walkthrough:
            EmptyView()
        case .consent:
            // No skip — the toggle (default on) is the choice, and the CTA
            // commits it. Closing via the X leaves consent undecided, so
            // nothing is sent.
            EmptyView()
        }
    }

    // MARK: - Chrome content (reads from per-step state)

    private var chromeTitle: LocalizedStringKey? {
        switch currentStep {
        case .welcome: return nil
        case .createAgent: return "Meet your dino"
        case .configureAI: return "Give your dino a brain"
        case .identitySetup: return "Make this yours"
        case .sandboxSetup: return "Add a safety net"
        case .choosePlugins: return "Add a few tools"
        case .walkthrough: return "A quick tour"
        case .consent: return "One last thing"
        }
    }

    private var chromeFooterCaption: LocalizedStringKey? {
        switch currentStep {
        case .welcome: return nil
        case .createAgent: return "You can rename and customize your dino anytime in Settings."
        case .configureAI: return configureAIState.footerCaption
        case .identitySetup: return identityState.footerCaption
        case .sandboxSetup: return nil
        case .choosePlugins: return nil
        case .walkthrough: return nil
        case .consent: return nil
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
        case .sandboxSetup:
            return { advance(to: .identitySetup, direction: .backward) }
        case .choosePlugins:
            return { advance(to: .configureAI, direction: .backward) }
        case .walkthrough:
            return {
                walkthroughState.handleBack { advance(to: .choosePlugins, direction: .backward) }
            }
        case .consent:
            return { advance(to: .walkthrough, direction: .backward) }
        }
    }

    // MARK: - Conditional sandbox step

    /// The sandbox step is sandboxed (heh) behind macOS 26+ /
    /// Containerization availability. On unsupported machines we skip
    /// straight from identity to plugins so the user never sees a
    /// dead-end "not available" card. `SandboxManager.State.shared`
    /// publishes this synchronously on app launch via its seeded
    /// `initialAvailability`, so the gate is always reliable by the
    /// time the user reaches identity.
    private var sandboxStepAvailable: Bool {
        SandboxManager.State.shared.availability.isAvailable
    }

    private func advanceFromIdentity() {
        advance(to: sandboxStepAvailable ? .sandboxSetup : .choosePlugins)
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

    private func finishOnboarding(via: OnboardingTelemetry.Completion) {
        // Record where the user left and how: `finishButton` (the consent
        // step's CTA) is a real completion, `closeButton` at an earlier step
        // is the drop-off point.
        OnboardingTelemetry.completed(lastStep: currentStep, via: via)

        // If the user created an agent in step 2, drop them into chat
        // with that agent already selected — otherwise the freshly
        // created persona is buried behind the built-in default and the
        // user has to hunt for it in the agent switcher.
        if let createdId = createAgentState.createdAgentId {
            AgentManager.shared.setActiveAgent(createdId)
        }
        configureImplicitDefaults()
        OnboardingService.shared.completeOnboarding()
        onComplete()
    }

    /// Identity and sandbox no longer have their own onboarding steps — the
    /// crypto/sandbox vocabulary read as jargon to non-technical users. We
    /// set both up implicitly here so the user gets the same end state
    /// without ever seeing the technical framing.
    private func configureImplicitDefaults() {
        // Identity: generate the master signature silently. On a fresh
        // install `OsaurusIdentity.setup()` writes the key to iCloud
        // Keychain with no biometric prompt. We gate on `exists()` because
        // when a master is already present `setup()` would fall into
        // `loadExistingIdentity()`, which *does* prompt for biometrics —
        // unwanted noise for someone re-running onboarding.
        if !OsaurusIdentity.exists() {
            Task.detached(priority: .utility) {
                _ = try? await OsaurusIdentity.setup()
            }
        }

        // Sandbox: persist the default CPU/RAM config on machines that
        // support it, but don't provision now. The container boots lazily
        // the first time it's needed (Sandbox tab / first sandboxed run),
        // exactly as the old "Skip for now" path behaved — no surprise
        // multi-GB download for every new user.
        if sandboxStepAvailable {
            SandboxConfigurationStore.save(SandboxConfigurationStore.load())
        }
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
