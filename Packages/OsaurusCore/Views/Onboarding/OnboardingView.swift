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

    @Environment(\.theme) private var theme
    @State private var currentStep: OnboardingStep
    @State private var direction: OnboardingDirection = .forward
    /// Guards the one-shot `onboarding_started` + first `stepViewed` emit.
    @State private var didTrackStart = false

    @StateObject private var welcomeState = WelcomeState()
    @StateObject private var createAgentState = CreateAgentState()
    @StateObject private var configureAIState = ConfigureAIState()
    @StateObject private var choosePluginsState = ChoosePluginsState()
    @StateObject private var walkthroughState = WalkthroughState()
    @StateObject private var consentState = ConsentState()

    // Identity and sandbox are configured implicitly on completion (see
    // `configureImplicitDefaults`) rather than shown as their own steps — the
    // crypto/sandbox vocabulary read as jargon to non-technical users.

    public init(
        onPreferredSizeChange: ((CGSize) -> Void)? = nil,
        onComplete: @escaping () -> Void
    ) {
        self.onPreferredSizeChange = onPreferredSizeChange
        self.onComplete = onComplete
        _currentStep = State(initialValue: .welcome)
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

            // Hosted at the window root (above the chrome, not inside the
            // clipped body) so the "Choose your model" dialog can dim the whole
            // step and center over it — the previous popover overflowed the body
            // region and covered the footer CTA.
            if currentStep == .configureAI && configureAIState.isChoosingModel {
                ConfigureModelChooserModal(state: configureAIState)
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .frame(width: OnboardingMetrics.windowWidth, height: OnboardingMetrics.windowHeight)
        .animation(theme.springAnimation(), value: configureAIState.isChoosingModel)
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
            stepFooterCaption
                .id(currentStep)
                .transition(slideTransition)
        }
    }

    /// Per-step footer caption content, rendered directly above the CTA. Most
    /// steps surface a plain text caption; the Welcome step instead surfaces
    /// the usage opt-in checkbox here (rather than at the bottom of its body)
    /// so it sits the same distance above the CTA as the other captions.
    @ViewBuilder
    private var stepFooterCaption: some View {
        switch currentStep {
        case .welcome:
            VStack(spacing: 8) {
                WelcomeUsageOptIn(state: welcomeState)
                WelcomeLegalNotice()
            }
            .padding(.bottom, OnboardingMetrics.footerCaptionToCTA)
        default:
            stepFooterCaptionText
        }
    }

    /// The action row is bottom-anchored, so a captionless step doesn't need a
    /// reserved placeholder — collapsing it (no text, no spacing) reclaims the
    /// dead gap above the CTA without shifting the CTA itself. The caption owns
    /// its own bottom spacing so the empty case contributes nothing.
    @ViewBuilder
    private var stepFooterCaptionText: some View {
        if let caption = chromeFooterCaption {
            Text(caption, bundle: .module)
                .font(theme.font(size: OnboardingMetrics.captionSize))
                .foregroundColor(theme.tertiaryText)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .padding(.bottom, OnboardingMetrics.footerCaptionToCTA)
        }
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
            WelcomeBody(state: welcomeState)
        case .createAgent:
            CreateAgentBody(state: createAgentState)
        case .configureAI:
            ConfigureAIBody(state: configureAIState)
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
                WelcomeCTA(onContinue: {
                    // Commit the usage opt-in here (not on toggle) so the whole
                    // funnel from this point on is captured even if the user
                    // bails before the final step. Granting flushes the events
                    // buffered so far (app_launched, onboarding_started, the
                    // first step view) and sends everything after live. Leaving
                    // it unchecked keeps telemetry undecided — still buffering,
                    // still nothing sent — and `finishOnboarding` records the
                    // decline at the end.
                    if welcomeState.shareUsageData {
                        TelemetryService.shared.setEnabled(true)
                    }
                    advance(to: .createAgent)
                })
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
            // Centered (like Create Agent) with a content-hugging pill, so the
            // CTA reads consistently across the two adjacent steps.
            HStack {
                Spacer(minLength: 0)
                ConfigureAICTA(
                    state: configureAIState,
                    onComplete: { advance(to: .choosePlugins) }
                )
                Spacer(minLength: 0)
            }
        case .choosePlugins:
            // Centered, content-hugging pill. "Skip" is folded into this CTA
            // when nothing is ticked, so there's no separate secondary link.
            HStack {
                Spacer(minLength: 0)
                ChoosePluginsCTA(
                    state: choosePluginsState,
                    onComplete: { advance(to: .walkthrough) },
                    onSkip: {
                        OnboardingTelemetry.stepSkipped(.choosePlugins)
                        advance(to: .walkthrough)
                    }
                )
                Spacer(minLength: 0)
            }
        case .walkthrough:
            // Centered, content-hugging pill — consistent with the other steps.
            HStack {
                Spacer(minLength: 0)
                WalkthroughCTA(
                    state: walkthroughState,
                    onContinue: { advance(to: .consent) }
                )
                Spacer(minLength: 0)
            }
        case .consent:
            // Centered, content-hugging pill — consistent with the other steps.
            HStack {
                Spacer(minLength: 0)
                ConsentCTA(onFinish: {
                    // Crash reporting (opt-out) is committed here. Usage
                    // analytics consent was already decided back on the Welcome
                    // step; `finishOnboarding` finalizes a decline if the user
                    // never opted in there.
                    CrashReportingService.shared.setEnabled(consentState.shareCrashReports)
                    finishOnboarding(via: .finishButton)
                })
                Spacer(minLength: 0)
            }
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
            // The download escape hatch now lives in the primary CTA
            // ("Continue in Background"), so there's no secondary slot.
            EmptyView()
        case .choosePlugins:
            // Skip is folded into the primary CTA when nothing is selected.
            EmptyView()
        case .walkthrough:
            EmptyView()
        case .consent:
            // No skip — the crash-reports toggle (default on) is the choice,
            // and the CTA commits it. Usage analytics was already decided on
            // the Welcome step.
            EmptyView()
        }
    }

    // MARK: - Chrome content (reads from per-step state)

    private var chromeTitle: LocalizedStringKey? {
        switch currentStep {
        case .welcome: return nil
        case .createAgent: return "Meet your dino"
        case .configureAI: return "Give your dino a brain"
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

    // MARK: - Sandbox availability

    /// Whether this machine supports the sandbox (macOS 26+ / Containerization).
    /// The sandbox no longer has its own onboarding step; this now only gates
    /// whether `configureImplicitDefaults` persists the default sandbox config.
    /// `SandboxManager.State.shared` publishes this synchronously on app launch
    /// via its seeded `initialAvailability`, so the gate is always reliable.
    private var sandboxAvailable: Bool {
        SandboxManager.State.shared.availability.isAvailable
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

        // Arm the post-onboarding activation funnel: the chat window that
        // opens right after this (see AppDelegate's `onComplete`) fires
        // `first_time_chat_shown` exactly once. Armed for the close-button
        // path too — chat opens either way, and `onboarding_completed`'s
        // `via` property already separates the two cohorts.
        FeatureTelemetry.armFirstTimeChatShown()

        // If the user never opted into usage analytics on the Welcome step,
        // telemetry is still `undecided` here. Finalize that as a decline so
        // the post-launch upgrade prompt (`maybePromptForTelemetryConsent`)
        // never re-asks a user who just chose not to opt in. Opted-in users
        // are already `granted`, so this no-ops for them.
        if TelemetryService.shared.needsConsentDecision {
            TelemetryService.shared.setEnabled(false)
        }

        // If the user created an agent in step 2, drop them into chat
        // with that agent already selected — otherwise the freshly
        // created persona is buried behind the built-in default and the
        // user has to hunt for it in the agent switcher.
        if let createdId = createAgentState.createdAgentId {
            AgentManager.shared.setActiveAgent(createdId)
        }
        configureImplicitDefaults()

        // Persist the brain choice so the first chat-UI `message_sent` can carry
        // the `brain_source` dimension that joins the path choice to activation.
        FeatureTelemetry.recordOnboardingBrainSource(
            configureAIState.selectedBrainSource?.telemetryValue
        )

        // The managed Osaurus Router is intentionally left at its persisted
        // default (on for fresh installs via `OsaurusRouter.isEnabled`) so the
        // hosted models are available in everyone's picker. Onboarding no longer
        // writes the flag, so a user's explicit opt-out in Credits sticks and is
        // never silently re-enabled. Routing is not forced: each agent still
        // runs whatever model `pinSelectedBrainModel` pins below.

        // Pin the new/active agent's default model to the brain the user chose
        // on the Configure AI step, so the first chat respects their selection.
        pinSelectedBrainModel()

        OnboardingService.shared.completeOnboarding()
        onComplete()
    }

    /// Pin the new/active agent's default model to the brain source the user
    /// committed to on the Configure AI step (local or bring-your-own-key). The
    /// hosted router is on by default and surfaces its models in the picker, but
    /// it's never forced as the active brain here.
    private func pinSelectedBrainModel() {
        let agentId = createAgentState.createdAgentId ?? Agent.defaultId
        switch configureAIState.selectedBrainSource {
        case .local:
            // The model may still be downloading; the id is durable and
            // `ChatView.refreshPickerItems` re-resolves it once the bundle lands.
            if let localModelId = configureAIState.localDefaultModelIdToPin {
                AgentManager.shared.updateDefaultModel(for: agentId, model: localModelId)
            }
        case .providerKey:
            // The provider auto-connects, but its catalog populates async; poll
            // (bounded) for its first chat-capable model, then pin it.
            if let providerId = configureAIState.providerModelPinTarget {
                pinProviderModel(providerId: providerId, forAgent: agentId)
            }
        case nil:
            break
        }
    }

    /// After onboarding finishes on the BYOK / OAuth path, wait (bounded) for
    /// the just-connected provider's catalog to populate, then pin the agent's
    /// default model to its first chat-capable model. Gives up quietly if the
    /// catalog never arrives (the user can still pick a model in chat).
    private func pinProviderModel(providerId: UUID, forAgent agentId: UUID) {
        Task { @MainActor in
            await pinModelWhenAvailable(forAgent: agentId, attempts: 20) {
                RemoteProviderManager.shared.firstChatCapableModelId(forProviderId: providerId)
            }
        }
    }

    /// Poll (bounded) for a model id via `lookup`, pinning it as `agentId`'s
    /// default the moment one resolves. Used by the BYOK/OAuth path, whose
    /// catalog populates asynchronously after onboarding finishes. Polls every
    /// 500ms up to `attempts` times, then gives up quietly so it never hangs
    /// (the user can still pick in chat).
    @MainActor
    private func pinModelWhenAvailable(
        forAgent agentId: UUID,
        attempts: Int,
        lookup: () -> String?
    ) async {
        for _ in 0 ..< attempts {
            if let model = lookup() {
                AgentManager.shared.updateDefaultModel(for: agentId, model: model)
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
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
        if sandboxAvailable {
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
