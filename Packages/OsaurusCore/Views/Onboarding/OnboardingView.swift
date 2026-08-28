//
//  OnboardingView.swift
//  osaurus
//
//  Main container view managing the redesigned 3-screen onboarding flow
//  (Welcome → Create Dino → Brain setup) at a fixed dark 1000×640 window,
//  per the Figma onboarding kit. Each step renders a full-window
//  `OnboardingStepLayout`; the overlay Back/Close glass buttons and the
//  modal hosts (model chooser, provider connect) live here so
//  they stay pixel-stable across step transitions. Each step's mutable
//  state lives in a `@StateObject` here so values survive the slide.
//

import SwiftUI

// MARK: - Onboarding Step

public enum OnboardingStep: Int, CaseIterable {
    case welcome
    case createAgent
    case configureAI
}

// MARK: - Navigation Direction

enum OnboardingDirection {
    case forward
    case backward
}

// MARK: - Onboarding View

public struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var currentStep: OnboardingStep
    @State private var direction: OnboardingDirection = .forward
    /// Latched by `finishOnboarding` to play the ~0.3s scale/fade farewell
    /// beat (and block re-entry) before `onComplete` closes the window.
    @State private var isFinishing = false
    /// Guards the one-shot `onboarding_started` + first `stepViewed` emit.
    @State private var didTrackStart = false
    /// False after the first step navigation: the staggered content cascade
    /// belongs only to the window's opening moment — subsequent steps ride
    /// in whole with the slide (see `onboardingEntranceEnabled`).
    @State private var isFirstScreen = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Guards the one-shot identity/Router warm-up kicked off when the user
    /// reaches the Configure AI step, and tells `configureImplicitDefaults`
    /// that identity setup is already in flight (so it doesn't start a second,
    /// racing `OsaurusIdentity.setup()` at finish).
    @State private var didPrepareManagedBrain = false

    @StateObject private var welcomeState = WelcomeState()
    @StateObject private var createAgentState = CreateAgentState()
    @StateObject private var configureAIState = ConfigureAIState()

    // Identity, sandbox, and crash reporting are configured implicitly on
    // completion (see `configureImplicitDefaults`) rather than shown as their
    // own steps — the crypto/sandbox/diagnostics vocabulary read as jargon to
    // non-technical users.

    public init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        _currentStep = State(initialValue: .welcome)
    }

    public var body: some View {
        ZStack {
            OnboardingPalette.windowBackground.ignoresSafeArea()

            // Step content slides horizontally; clipped so the slide never
            // bleeds over the window's rounded corners.
            ZStack {
                stepContent
                    .id(currentStep)
                    .transition(slideTransition)
            }
            .environment(\.onboardingEntranceEnabled, isFirstScreen)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            // Overlay chrome: Back (configure step only) and Close glass
            // buttons pinned to the window's top corners, above the slide.
            overlayControls
                .zIndex(5)

            // Window-root modal hosts: each must dim and block the whole
            // window while open, so they can't live inside a step's layout.
            if currentStep == .configureAI && configureAIState.isChoosingModel {
                ConfigureModelChooserModal(state: configureAIState)
                    .transition(OnboardingMotion.modalFade)
                    .zIndex(10)
            }

            if currentStep == .configureAI && configureAIState.connectDialog != nil {
                ProviderConnectDialog(state: configureAIState)
                    .transition(OnboardingMotion.modalFade)
                    .zIndex(10)
            }

        }
        // `smooth`, not `bouncy`: this drives the scrim's opacity, and an
        // overshooting spring makes the dimming visibly pulse past its
        // target. The dialog's own transition supplies the character.
        .animation(OnboardingMotion.smooth, value: configureAIState.isChoosingModel)
        .animation(OnboardingMotion.smooth, value: configureAIState.connectDialog != nil)
        .frame(width: OnboardingMetrics.windowWidth, height: OnboardingMetrics.windowHeight)
        // The host window is `.titled` + `.fullSizeContentView` with a hidden
        // titlebar, so NSHostingView still reports a ~28pt top safe-area
        // inset. Without this, the fixed 640pt content gets centered in the
        // reduced safe area — shifted ~14pt down and clipped at the bottom.
        // NOTE: render modifiers (scale/opacity, e.g. the farewell beat)
        // must come AFTER `.ignoresSafeArea()` — inserted between the frame
        // and the content they broke the inset compensation and re-shifted
        // the whole window content down.
        .ignoresSafeArea()
        // Farewell beat: `finishOnboarding` latches `isFinishing`, the whole
        // window content settles down/away, then `onComplete` closes it.
        .scaleEffect(isFinishing && !reduceMotion ? 0.96 : 1)
        .opacity(isFinishing ? 0 : 1)
        .onAppear {
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
            // Warm up identity + Router as soon as this step appears. Both the
            // Cloud-only path and the temporary bridge used during a local
            // download should be ready before the user reaches chat.
            if newStep == .configureAI {
                prepareManagedBrainReadiness()
            }
        }
    }

    // MARK: - Step content dispatch

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .welcome:
            WelcomeStepView(
                state: welcomeState,
                onGetStarted: {
                    // The welcome claim owns the wallet's first signed Router
                    // action. Persist that choice before identity setup can
                    // notify any Router observers.
                    WelcomeCreditService.shared.selectForFirstLaunch()
                    // Commit the usage opt-in here (not on toggle) so the whole
                    // funnel from this point on is captured even if the user
                    // bails before the final step. Granting flushes the events
                    // buffered so far and sends everything after live. Leaving
                    // it unchecked keeps telemetry undecided — still buffering,
                    // still nothing sent — and `finishOnboarding` records the
                    // decline at the end.
                    if welcomeState.shareUsageData {
                        TelemetryService.shared.setEnabled(true)
                    }
                    advance(to: .createAgent)
                }
            )
        case .createAgent:
            CreateAgentStepView(
                state: createAgentState,
                onContinue: { advance(to: .configureAI) }
            )
        case .configureAI:
            ConfigureAIStepView(
                state: configureAIState,
                onComplete: { finishOnboarding(via: .finishButton) }
            )
        }
    }

    // MARK: - Overlay controls

    /// Back (top-leading, brain-setup step only — per the Figma frames) and
    /// Close (top-trailing, every step) glass circle buttons at 16pt insets.
    private var overlayControls: some View {
        VStack {
            HStack {
                if currentStep == .configureAI {
                    OnboardingCircleIconButton(
                        systemName: "arrow.left",
                        action: { advance(to: .createAgent, direction: .backward) },
                        accessibilityLabelKey: "Back"
                    )
                    .transition(.opacity)
                }
                Spacer(minLength: 0)
                OnboardingCircleIconButton(
                    systemName: "xmark",
                    action: { finishOnboarding(via: .closeButton) },
                    accessibilityLabelKey: "Close"
                )
            }
            Spacer(minLength: 0)
        }
        .padding(OnboardingLayout.glassButtonInset)
        .animation(OnboardingMotion.snappy, value: currentStep)
    }

    /// One-shot background warm-up for the managed Osaurus brain: create the
    /// identity master key when missing (fresh install — no biometric prompt),
    /// then attempt the Router connect so its model catalog is populated by
    /// the time `pinSelectedBrainModel` looks for it. Safe to run for users
    /// who end up choosing local/BYOK: identity is created at finish anyway
    /// (`configureImplicitDefaults`), and the connect only runs while the
    /// router is enabled.
    private func prepareManagedBrainReadiness() {
        guard !didPrepareManagedBrain else { return }
        didPrepareManagedBrain = true
        Task.detached(priority: .utility) {
            // Same gate as `configureImplicitDefaults`: `setup()` on an
            // existing identity falls into `loadExistingIdentity()`, which
            // prompts for biometrics — unwanted noise during onboarding.
            if !OsaurusIdentity.exists() {
                _ = try? await OsaurusIdentity.setup()
            }
            await RemoteProviderManager.shared.connectOsaurusRouterIfPossible()
        }
    }

    // MARK: - Sandbox availability

    /// Whether this machine supports the sandbox (macOS 26+ / Containerization).
    /// Only gates whether `configureImplicitDefaults` persists the default
    /// sandbox config. `SandboxManager.State.shared` publishes this
    /// synchronously on app launch via its seeded `initialAvailability`.
    private var sandboxAvailable: Bool {
        SandboxManager.State.shared.availability.isAvailable
    }

    // MARK: - Slide Transition (push-fade)

    /// Direction-aware push-fade: the crossfade carries the step change
    /// while a short directional drift supplies continuity. A plain
    /// crossfade under Reduce Motion.
    private var slideTransition: AnyTransition {
        OnboardingMotion.pushFade(direction: direction, reduceMotion: reduceMotion)
    }

    // MARK: - Navigation

    private func advance(to step: OnboardingStep, direction: OnboardingDirection = .forward) {
        self.direction = direction
        // Cascade is an opening-only flourish; from the first navigation on,
        // steps arrive as one surface with the slide.
        isFirstScreen = false
        // Seed the Configure AI selection *before* the step is inserted.
        // `ConfigureAIStepView.onAppear` fires mid-slide, and a view inserted
        // into an in-flight offset transition renders at its final position
        // instead of sliding — the recommended-model card (gated on
        // `selectedModel`) visibly detached from the step slide. The step's
        // own `onAppear` keeps the same calls as an idempotent safety net.
        if step == .configureAI {
            configureAIState.ensureLocalSelection(
                totalMemoryGB: SystemMonitorService.shared.totalMemoryGB
            )
            configureAIState.refreshFreeDiskSpace()
        }
        withAnimation(reduceMotion ? .easeOut(duration: 0.3) : OnboardingMotion.gentle) {
            currentStep = step
        }
    }

    private func finishOnboarding(via: OnboardingTelemetry.Completion) {
        // One-shot: the farewell beat below keeps the window interactive for
        // ~0.3s, so a double-tap on Close/CTA must not re-run completion.
        guard !isFinishing else { return }
        // Closing on any step is an explicit welcome-claim continuation
        // (idempotent when "Get started" already selected it).
        WelcomeCreditService.shared.selectForFirstLaunch()

        // Record where the user left and how: `finishButton` (the brain-setup
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

        // First chat lands on the built-in Orchestrator: it introduces
        // Osaurus, configures things, and delegates work to the Dino created
        // in step 2 (which stays one click away in the agent switcher and
        // already joined the default spawn pool on save).
        AgentManager.shared.setActiveAgent(Agent.defaultId)
        configureImplicitDefaults()

        // Persist the brain choice so the first chat-UI `message_sent` can carry
        // the `brain_source` dimension that joins the path choice to activation.
        // A run that ends without a commit (early close, or finishing without
        // choosing) records the explicit `none` token instead, keeping the
        // dimension's coverage total; the absent-writer never clobbers a
        // prior real choice.
        FeatureTelemetry.recordOnboardingBrainSource(
            configureAIState.selectedBrainSource?.telemetryValue
        )
        FeatureTelemetry.recordOnboardingBrainSourceAbsent()

        // The managed Router stays at its persisted default unless the user
        // explicitly chose the Cloud-only path. Local and BYOK choices never
        // override a previous opt-out; routing follows the model pinned below.

        // Pin the new/active agent's default model to the brain the user chose
        // on the Configure AI step, so the first chat respects their selection.
        pinSelectedBrainModel()

        OnboardingService.shared.completeOnboarding()

        // Farewell beat: settle the content down/away, then hand the window
        // back. Skipped straight to `onComplete` under Reduce Motion.
        if reduceMotion {
            onComplete()
        } else {
            withAnimation(.easeIn(duration: 0.28)) { isFinishing = true }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                onComplete()
            }
        }
    }

    /// The agents whose default model should carry the brain choice: the
    /// Orchestrator always (the first chat after onboarding lands there),
    /// plus the Dino created in step 2 so switching to it respects the same
    /// choice.
    private var brainPinTargets: [UUID] {
        var targets = [Agent.defaultId]
        if let createdId = createAgentState.createdAgentId {
            targets.append(createdId)
        }
        return targets
    }

    /// Pin the Orchestrator's (and the created Dino's) default model to the
    /// brain source the user committed to on the Configure AI step (managed
    /// Osaurus, local, or bring-your-own-key). Selecting local or a provider
    /// never routes through the hosted router implicitly — only the explicit
    /// `.osaurus` choice pins a router model.
    private func pinSelectedBrainModel() {
        switch configureAIState.selectedBrainSource {
        case .osaurus:
            // Explicit "Set up later" / start-on-Cloud path: (re-)enable the
            // managed router — a no-op unless a previous opt-out is being
            // overridden by this explicit choice — then pin its first
            // chat-capable model.
            RemoteProviderManager.shared.setOsaurusRouterEnabled(true)
            pinOsaurusRouterModel(forAgents: brainPinTargets)
        case .local:
            // The model may still be downloading; the id is durable and
            // `ChatView.refreshPickerItems` re-resolves it once the bundle lands.
            if let localModelId = configureAIState.localDefaultModelIdToPin {
                for agentId in brainPinTargets {
                    AgentManager.shared.updateDefaultModel(for: agentId, model: localModelId)
                }
            }
        case .providerKey:
            // The provider auto-connects, but its catalog populates async; poll
            // (bounded) for its first chat-capable model, then pin it.
            if let providerId = configureAIState.providerModelPinTarget {
                pinProviderModel(providerId: providerId, forAgents: brainPinTargets)
            }
        case nil:
            break
        }
    }

    /// After onboarding finishes on the managed path, poll (bounded, ~20s) for
    /// the router's first chat-capable model and pin it. The identity setup
    /// kicked off on step entry may still be in flight, so each poll retries
    /// the single-shot connect (a cheap no-op once connected / while
    /// connecting) before looking the model up. Gives up quietly — the hosted
    /// models still appear in the picker once the connect lands.
    private func pinOsaurusRouterModel(forAgents agentIds: [UUID]) {
        Task { @MainActor in
            for _ in 0 ..< 40 {
                if let model = RemoteProviderManager.shared.firstRunOsaurusRouterModelId() {
                    for agentId in agentIds {
                        AgentManager.shared.updateDefaultModel(for: agentId, model: model)
                    }
                    return
                }
                await RemoteProviderManager.shared.connectOsaurusRouterIfPossible()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// After onboarding finishes on the BYOK / OAuth path, wait (bounded) for
    /// the just-connected provider's catalog to populate, then pin the agents'
    /// default model to its first chat-capable model. Gives up quietly if the
    /// catalog never arrives (the user can still pick a model in chat).
    private func pinProviderModel(providerId: UUID, forAgents agentIds: [UUID]) {
        Task { @MainActor in
            await pinModelWhenAvailable(forAgents: agentIds, attempts: 20) {
                RemoteProviderManager.shared.firstChatCapableModelId(forProviderId: providerId)
            }
        }
    }

    /// Poll (bounded) for a model id via `lookup`, pinning it as every
    /// `agentIds` default the moment one resolves. Used by the BYOK/OAuth
    /// path, whose catalog populates asynchronously after onboarding
    /// finishes. Polls every 500ms up to `attempts` times, then gives up
    /// quietly so it never hangs (the user can still pick in chat).
    @MainActor
    private func pinModelWhenAvailable(
        forAgents agentIds: [UUID],
        attempts: Int,
        lookup: () -> String?
    ) async {
        for _ in 0 ..< attempts {
            if let model = lookup() {
                for agentId in agentIds {
                    AgentManager.shared.updateDefaultModel(for: agentId, model: model)
                }
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Identity, sandbox, and crash reporting no longer have their own
    /// onboarding steps — the crypto/sandbox/diagnostics vocabulary read as
    /// jargon to non-technical users. We set them up implicitly here so the
    /// user gets the same end state without ever seeing the technical framing.
    private func configureImplicitDefaults() {
        // Identity: generate the master signature silently. On a fresh
        // install `OsaurusIdentity.setup()` writes the key to iCloud
        // Keychain with no biometric prompt. We gate on `exists()` because
        // when a master is already present `setup()` would fall into
        // `loadExistingIdentity()`, which *does* prompt for biometrics —
        // unwanted noise for someone re-running onboarding. Skipped when the
        // Configure AI step's warm-up already kicked setup off (it may still
        // be in flight, so `exists()` alone can't dedupe it).
        if !didPrepareManagedBrain && !OsaurusIdentity.exists() {
            Task.detached(priority: .utility) {
                _ = try? await OsaurusIdentity.setup()
            }
        }

        // Crash reporting: opt-out (default ON), previously its own consent
        // step. `CrashReportingService` already defaults to enabled when no
        // choice was persisted, so finishing onboarding simply leaves the
        // default in place — an earlier explicit opt-out (Settings) is never
        // overridden here.

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
