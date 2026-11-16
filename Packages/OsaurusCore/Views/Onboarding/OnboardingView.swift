//
//  OnboardingView.swift
//  osaurus
//
//  The onboarding window: a stage over the brand landscape where the dino
//  stands across two chapters. Welcome greets the person and pitches
//  Osaurus; Model sets up where Osaurus runs (Raptor on this Mac, a
//  provider key, or Osaurus Cloud). The third chapter, Team, happens in the
//  first chat, which this window morphs into (`OnboardingHandoff`). The overlay
//  controls, chapter indicator, and modal hosts live here so they stay
//  stable across chapter transitions, and each chapter's mutable state
//  lives in a `@StateObject` here so values survive the slide.
//

import AppKit
import SwiftUI

// MARK: - Onboarding Step

public enum OnboardingStep: Int, CaseIterable {
    case welcome
    case configureAI
}

// MARK: - Navigation Direction

enum OnboardingDirection {
    case forward
    case backward
}

/// The pointer over the onboarding window, kept apart from the view state
/// so pointer moves only redraw the landscape.
@MainActor
final class OnboardingPointer: ObservableObject {
    @Published var location: CGPoint?
}

// MARK: - Onboarding View

public struct OnboardingView: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(55, enabled: inspectionEnabled) }
    let onComplete: () -> Void

    @State private var currentStep: OnboardingStep
    @State private var direction: OnboardingDirection = .forward
    /// Latched by `finishOnboarding`: the chapter content dissolves, leaving
    /// the landscape and the dino for the handoff.
    @State private var isFinishing = false
    /// Latched while the day-one team is created at finish, before the
    /// farewell beat; blocks a second finish.
    @State private var isSeedingTeam = false
    /// Guards the one-shot `onboarding_started` + first `stepViewed` emit.
    @State private var didTrackStart = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Guards the one-shot identity/Router warm-up kicked off when the user
    /// reaches the Configure AI step, and tells `configureImplicitDefaults`
    /// that identity setup is already in flight (so it doesn't start a second,
    /// racing `OsaurusIdentity.setup()` at finish).
    @State private var didPrepareManagedBrain = false

    @StateObject private var welcomeState = WelcomeState()
    @StateObject private var configureAIState = ConfigureAIState()
    @StateObject private var stage = OnboardingStage()
    @StateObject private var pointer = OnboardingPointer()

    // Identity, sandbox, and crash reporting are configured implicitly on
    // completion (see `configureImplicitDefaults`) rather than shown as their
    // own steps — the crypto/sandbox/diagnostics vocabulary read as jargon to
    // non-technical users.

    /// An installed bundle asked to skip the intro: the window opens on
    /// Configure AI and no walkthrough follows in chat.
    private let skipsIntro: Bool
    /// Team is the walkthrough in chat, so the indicator leaves it out when
    /// none will follow.
    private let chapters: [OnboardingChapter]

    public init(onComplete: @escaping () -> Void) {
        let preferences = BundleOnboardingPreferences.effective
        let roster = TeamSeeder.Options(
            developerMac: DeveloperMacSignal.isDeveloperMac(),
            brainIsLocal: false,
            excludedTeammates: preferences.excludeTeammates
        ).teammates
        self.init(
            skipsIntro: preferences.skip,
            walkthroughFollows: !preferences.skip && !roster.isEmpty,
            onComplete: onComplete)
    }

    init(skipsIntro: Bool, walkthroughFollows: Bool = true, onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        self.skipsIntro = skipsIntro
        self.chapters = walkthroughFollows ? OnboardingChapter.allCases : [.welcome, .model]
        _currentStep = State(initialValue: skipsIntro ? .configureAI : .welcome)
    }

    private var chapter: OnboardingChapter { currentStep == .welcome ? .welcome : .model }

    public var body: some View {
        Group {

        ZStack {
            OnboardingPalette.windowBackground.ignoresSafeArea()

            OnboardingBackdropHost(stage: stage, pointer: pointer)

            ZStack {
                // Chapter content slides; clipped so the slide never bleeds
                // over the window's rounded corners.
                ZStack {
                    stepContent
                        .id(currentStep)
                        .transition(slideTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .opacity(isFinishing ? 0 : 1)
                .allowsHitTesting(!isFinishing)

                OnboardingStageDino(stage: stage)

                OnboardingDinoHelp(stage: stage, maxRight: helpMaxRight, pages: helpPages)
                    .opacity(isFinishing ? 0 : 1)
                    .allowsHitTesting(!isFinishing)

                // Overlay chrome: the chapter indicator, Back (Brain only)
                // and Close pinned to the window's top edge, above the slide.
                overlayControls
                    .opacity(isFinishing ? 0 : 1)
                    .zIndex(5)

                // Window-root modal host: it must dim and block the whole
                // window while open, so it can't live inside a step's layout.
                if currentStep == .configureAI && configureAIState.connectDialog != nil {
                    ProviderConnectDialog(state: configureAIState)
                        .transition(OnboardingMotion.modalFade)
                        .zIndex(10)
                }
            }
            .frame(width: OnboardingMetrics.windowWidth, height: OnboardingMetrics.windowHeight)
        }
        // `smooth`, not `bouncy`: this drives the scrim's opacity, and an
        // overshooting spring makes the dimming visibly pulse past its
        // target. The dialog's own transition supplies the character.
        .animation(OnboardingMotion.smooth, value: configureAIState.connectDialog != nil)
        .animation(theme.motion.standard, value: isFinishing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The host window is `.titled` + `.fullSizeContentView` with a hidden
        // titlebar, so NSHostingView still reports a ~28pt top safe-area
        // inset. Without this, the fixed 640pt content gets centered in the
        // reduced safe area — shifted ~14pt down and clipped at the bottom.
        .ignoresSafeArea()
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                pointer.location = location
                stage.pointerMoved(to: location)
            case .ended:
                pointer.location = nil
            }
        }
        .onAppear {
            // `.onAppear` can fire more than once (window re-activation); the
            // flag keeps "started" and the first step-view to a single emit.
            if !didTrackStart {
                didTrackStart = true
                OnboardingTelemetry.started()
                if skipsIntro {
                    OnboardingTelemetry.stepSkipped(.welcome)
                    openOnBrainSetup()
                }
                if !isFinishing && !isSeedingTeam { OnboardingTelemetry.stepViewed(currentStep) }
            }
            if !skipsIntro { stage.greet() }
        }
        .onChange(of: helpTopic) { _, _ in stage.closeHelp() }
        .onChange(of: currentStep) { _, newStep in
            OnboardingTelemetry.stepViewed(newStep)
            // Warm up identity + Router as soon as this step appears. Both the
            // Cloud-only path and the temporary bridge used during a local
            // download should be ready before the user reaches chat.
            if newStep == .configureAI {
                prepareManagedBrainReadiness()
            }
        }

        }.environment(\.theme, theme)
}

    // MARK: - Step content dispatch

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .welcome:
            HelloChapterView(
                state: welcomeState,
                stage: stage,
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
                    continueToBrainSetup()
                }
            )
        case .configureAI:
            ConfigureAIStepView(
                state: configureAIState,
                onComplete: { finishOnboarding(via: .finishButton) }
            )
        }
    }

    // MARK: - Dino help

    private var helpTopic: OnboardingHelp.Topic {
        switch currentStep {
        case .welcome: return .welcome
        case .configureAI:
            switch configureAIState.screen {
            case .home: return .paths
            case .local: return .localModel
            case .keys, .byok, .claudeCode: return .ownAccount
            }
        }
    }

    /// Welcome: short of the glass card. Model: inside the left column,
    /// clear of the setup panel.
    private var helpMaxRight: CGFloat {
        switch currentStep {
        case .welcome:
            return OnboardingMetrics.windowWidth - OnboardingLayout.contentPadding
                - OnboardingLayout.helloCardWidth - OnboardingLayout.columnGap
        case .configureAI:
            return OnboardingLayout.contentPadding + OnboardingLayout.brainColumnWidth
        }
    }

    private func helpPages() -> [String] {
        let totalMemoryGB = SystemMonitorService.shared.totalMemoryGB
        let pick = configureAIState.selectedModel.map { model in
            OnboardingHelp.Pick(
                name: model.simplifiedName,
                downloadSize: model.formattedDownloadSize,
                isDownloaded: model.isDownloaded,
                reason: ConfigureAIState.pickReason(for: model, totalMemoryGB: totalMemoryGB)
            )
        }
        return OnboardingHelp.pages(helpTopic, pick: pick)
    }

    // MARK: - Overlay controls

    /// Back (Brain only) and Skip setup on glass at the top corners, with
    /// the chapter indicator centered between them.
    private var overlayControls: some View {
        VStack {
            ZStack {
                OnboardingChapterIndicator(current: chapter, chapters: chapters)
                HStack {
                    if currentStep == .configureAI && !skipsIntro {
                        OnboardingCircleIconButton(
                            systemName: "arrow.left",
                            action: {
                                advance(to: .welcome, direction: .backward)
                            },
                            accessibilityLabelKey: "Back"
                        )
                        .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                    OnboardingGlassTextButton(title: "Skip setup") {
                        finishOnboarding(via: .skipButton)
                    }
                }
            }
            .frame(height: OnboardingLayout.glassButtonDiameter)
            Spacer(minLength: 0)
        }
        .padding(OnboardingLayout.glassButtonInset)
        .animation(OnboardingMotion.snappy, value: currentStep)
    }

    /// One-shot background warm-up for the managed Osaurus brain: create the
    /// identity master key when missing (fresh install — no biometric prompt),
    /// then attempt the Router connect so its model catalog is populated by
    /// the time `OnboardingBrainPin` looks for it. Safe to run for users
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
        // Seed the Configure AI selection *before* the step is inserted.
        // `ConfigureAIStepView.onAppear` fires mid-slide, and a view inserted
        // into an in-flight offset transition renders at its final position
        // instead of sliding — the recommended-model card (gated on
        // `selectedModel`) visibly detached from the step slide. The step's
        // own `onAppear` keeps the same calls as an idempotent safety net.
        if step == .configureAI {
            configureAIState.ensureLocalSelection()
            configureAIState.refreshFreeDiskSpace()
            stage.enterBrain()
        } else {
            stage.returnToHello()
        }
        withAnimation(reduceMotion ? theme.motion.standard : OnboardingMotion.gentle) {
            currentStep = step
        }
    }

    /// The step after Welcome. The full distribution ships Raptor 0.7 inside
    /// the app and `BundledModelSeeder` installs it at launch, so when that
    /// model is on disk and fits comfortably there is nothing left to choose:
    /// commit it as the local brain and finish, skipping Configure AI. Every
    /// other case (light build, seed still copying, model deleted, tight RAM)
    /// proceeds to the Configure AI step.
    private func continueToBrainSetup() {
        if let bundled = configureAIState.bundledLocalBrainReady(
            totalMemoryGB: SystemMonitorService.shared.totalMemoryGB
        ) {
            configureAIState.commitBundledLocalBrain(bundled)
            OnboardingTelemetry.stepSkipped(.configureAI)
            finishOnboarding(via: .finishButton)
            return
        }
        advance(to: .configureAI)
    }

    /// The bundle-skip start: the window opens on Configure AI, so do what
    /// `advance(to: .configureAI)` and the step change would have done. A
    /// bundled brain that is ready still finishes without the step.
    private func openOnBrainSetup() {
        if let bundled = configureAIState.bundledLocalBrainReady(
            totalMemoryGB: SystemMonitorService.shared.totalMemoryGB
        ) {
            configureAIState.commitBundledLocalBrain(bundled)
            OnboardingTelemetry.stepSkipped(.configureAI)
            finishOnboarding(via: .finishButton)
            return
        }
        configureAIState.ensureLocalSelection()
        configureAIState.refreshFreeDiskSpace()
        stage.enterBrain()
        prepareManagedBrainReadiness()
    }

    private func finishOnboarding(via reason: OnboardingTelemetry.Completion) {
        let via: OnboardingTelemetry.Completion = skipsIntro && reason == .finishButton ? .bundleSkip : reason
        // One-shot: the farewell beat below keeps the window interactive for
        // a moment, so a double-tap on Skip/CTA must not re-run completion.
        guard !isFinishing, !isSeedingTeam else { return }
        // Skipping on any step is an explicit welcome-claim continuation
        // (idempotent when "Get started" already selected it).
        WelcomeCreditService.shared.selectForFirstLaunch()

        // Skipping with no brain chosen starts on Osaurus Cloud, the same as
        // its card, so no way out of the window leaves the
        // first chat without a model. A re-run that already has a model
        // keeps it.
        if configureAIState.selectedBrainSource == nil,
            OnboardingService.shared.isFreshInstall
                || AgentManager.shared.effectiveModel(for: Agent.defaultId) == nil
        {
            configureAIState.chooseOsaurusAndContinue(onComplete: {})
        }

        // Record where the user left and how: `finishButton` (the brain-setup
        // step's CTA) is a real completion, `skipButton` is the drop-off
        // point.
        OnboardingTelemetry.completed(lastStep: currentStep, via: via)

        // Arm the post-onboarding activation funnel: the chat window that
        // opens right after this (see AppDelegate's `onComplete`) fires
        // `first_time_chat_shown` exactly once. Armed for the skip path
        // too — chat opens either way, and `onboarding_completed`'s
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
        // Osaurus, configures things, and routes work to the team.
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

        // A fresh install gets the team before the first chat opens. The teammates are pinned with the Orchestrator so
        // delegating never swaps a local model. Onboarding completes after
        // the seed, so a quit mid-seed runs it again on the next launch.
        if OnboardingService.shared.isFreshInstall {
            isSeedingTeam = true
            let options = TeamSeeder.Options(
                developerMac: DeveloperMacSignal.isDeveloperMac(),
                brainIsLocal: configureAIState.selectedBrainSource == .local,
                excludedTeammates: BundleOnboardingPreferences.effective.excludeTeammates
            )
            Task { @MainActor in
                let team = await TeamSeeder.seedFreshInstall(options)
                OnboardingBrainPin.pin(configureAIState, forAgents: [Agent.defaultId] + team.map(\.id))
                // Skip setup means all of it: no walkthrough in the first
                // chat. The walkthrough introduces the team, so none
                // follows when a bundle left every teammate out either.
                let hasTeam = AgentManager.shared.agents.contains { $0.teammate != nil }
                if via == .finishButton && hasTeam { OnboardingFirstRun.armOpening() }
                OnboardingService.shared.completeOnboarding()
                playFarewell()
            }
            return
        }

        // Pin the Orchestrator's default model to the brain the user chose on
        // the Configure AI step, so the first chat respects their selection.
        OnboardingBrainPin.pin(configureAIState, forAgents: [Agent.defaultId])

        OnboardingService.shared.completeOnboarding()
        playFarewell()
    }

    /// The chapter content dissolves, then the window becomes the chat
    /// (`OnboardingHandoff`).
    private func playFarewell() {
        isFinishing = true
        Task { @MainActor in
            if !reduceMotion { await OnboardingChoreography.sleep(0.3) }
            onComplete()
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
        // support it and download the runtime in the background (no VM
        // boot, no UI takeover). The container still boots lazily the
        // first time it's needed, but from cache instead of a cold download.
        if sandboxAvailable {
            SandboxConfigurationStore.save(SandboxConfigurationStore.load())
            Task { await SandboxManager.shared.prefetchRuntimeAssetsInBackground() }
        }
    }
}
