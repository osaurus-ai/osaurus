//
//  AppDelegate.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import AVFoundation
import AppKit
import Combine
import QuartzCore
import SwiftUI
import os.log

/// File-scope logger for the AppDelegate surface. Matches the
/// `ai.osaurus` subsystem used elsewhere in OsaurusCore so the
/// whole app can be filtered with one `log stream --subsystem ai.osaurus`.
private let log = Logger(subsystem: "ai.osaurus", category: "AppDelegate")

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    public static weak var shared: AppDelegate?
    let serverController = ServerController()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    /// Global mouse-down monitor that dismisses the status popover when the
    /// user clicks in another app or on the desktop. `.transient` only covers
    /// clicks inside our own windows, so this fills the gap for outside clicks.
    private var popoverDismissMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []
    let updater = UpdaterViewModel()

    private var activityDot: NSView?
    private var vadDot: NSView?
    private var pendingPopoverAction: (@MainActor () -> Void)?
    private var keychainDisabledTestMode: Bool {
        StorageKeyManager.disablesKeychainForProcess
    }
    private var keychainDisabledUIPresentationMode: Bool {
        ProcessInfo.processInfo.environment["OSAURUS_KEYCHAIN_FREE_SHOW_UI"] == "1"
    }

    /// Runs before AppKit shows its first window. Anything that influences
    /// window painting on launch (activation policy, automatic-termination
    /// hold, restoration opt-outs, the SwiftUI Settings-placeholder hide)
    /// must happen here, not in `applicationDidFinishLaunching` — otherwise
    /// AppKit gets one or more frames where a stale/auto-presented window
    /// can flash before our real window is up.
    public func applicationWillFinishLaunching(_ notification: Notification) {
        UncaughtExceptionLogger.install()

        AppDelegate.shared = self

        // Pin the process against macOS automatic termination. We're an
        // `LSUIElement=YES` agent (no Dock window) that exposes a local HTTP
        // server, so the AppKit defaults can decide we're "idle" once the
        // chat overlay closes and quietly suspend or kill us — which on a
        // 2026-05-07 repro silently terminated the app mid-Ling decode after
        // ~12 minutes of UI idleness, surfacing in the chat UI as
        // "greeting → freeze → end" (the streamed connection drops with the
        // process). The reason string is held for app lifetime; we never
        // re-enable, since the inference path is always potentially active.
        ProcessInfo.processInfo.disableAutomaticTermination(
            "Osaurus local LLM HTTP server (long-running)"
        )

        // Tahoe only early launch hygiene. Sequoia reported launch
        // failures with this block active, so it falls back to the
        // sequencing in `applicationDidFinishLaunching`
        if #available(macOS 26.0, *) {
            // Finalise the activation policy before AppKit paints its first
            // frame. `LSUIElement=YES` in Info.plist means we launch as
            // `.accessory`. if the user wants a Dock icon we have to flip to
            // `.regular` *before* SwiftUI / AppKit can auto-present any window
            // (e.g. the `Settings { EmptyView() }` placeholder) or that flip
            // surfaces as a one-frame flash of an unrelated window.
            let hideDockIcon = ServerConfigurationStore.load()?.hideDockIcon ?? false
            NSApp.setActivationPolicy(hideDockIcon ? .accessory : .regular)

            // close (and watch for re-presents of) the SwiftUI managed
            // `Settings { EmptyView() }` placeholder window. our real settings
            // surface is `ManagementView` opened via `showManagementWindow`;
            // the placeholder only exists to anchor `.commands`
            suppressSwiftUISettingsPlaceholder()

            // opt out of AppKit snapshot state restoration. window positions
            // still autosave via `setFrameAutosaveName`. what we're killing is
            // the launch time blit of the previous run's window snapshots
            disableAppKitStateRestoration()
        }
    }

    public func applicationSupportsSecureRestorableState(
        _ app: NSApplication
    ) -> Bool {
        // Paired with `disableAppKitStateRestoration()`. Sequoia keeps
        // AppKit's default restore behavior
        if #available(macOS 26.0, *) { return true }
        return false
    }

    private func disableAppKitStateRestoration() {
        UserDefaults.standard.register(defaults: [
            "NSQuitAlwaysKeepsWindows": false
        ])
    }

    /// Hide SwiftUI's `Settings { EmptyView() }` placeholder window so it
    /// can't paint for a frame before our onboarding window appears. We
    /// observe both key and occlusion-state changes because the window
    /// can be ordered on-screen without becoming key (background launch
    /// or another app frontmost). The deferred-Task sweep is the
    /// belt-and-suspenders for the case where neither notification fires
    /// before SwiftUI paints.
    private static let swiftUISettingsPlaceholderID = "com_apple_SwiftUI_Settings_window"

    private static let swiftUISettingsPlaceholderNotifications: [Notification.Name] = [
        NSWindow.didBecomeKeyNotification,
        NSWindow.didChangeOcclusionStateNotification,
    ]

    private func suppressSwiftUISettingsPlaceholder() {
        sweepSwiftUISettingsPlaceholder()
        for name in Self.swiftUISettingsPlaceholderNotifications {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleSwiftUIPlaceholderEvent(_:)),
                name: name,
                object: nil
            )
        }
    }

    private func sweepSwiftUISettingsPlaceholder() {
        for window in NSApp.windows
        where window.identifier?.rawValue == Self.swiftUISettingsPlaceholderID {
            hidePlaceholder(window)
        }
    }

    @objc private func handleSwiftUIPlaceholderEvent(_ note: Notification) {
        guard
            let window = note.object as? NSWindow,
            window.identifier?.rawValue == Self.swiftUISettingsPlaceholderID
        else { return }
        hidePlaceholder(window)
    }

    private func hidePlaceholder(_ window: NSWindow) {
        window.orderOut(nil)
        window.setIsVisible(false)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // sequoia fallback. Tahoe already ran this in
        // `applicationWillFinishLaunching`.
        if #unavailable(macOS 26.0) {
            let hideDockIcon = ServerConfigurationStore.load()?.hideDockIcon ?? false
            NSApp.setActivationPolicy(hideDockIcon ? .accessory : .regular)
        }

        // Consolidate any agent records stranded in the legacy `Personas/`
        // directory into `agents/` before the first agent load. Enabling a
        // per-agent Database (or writing a custom avatar) creates `agents/`,
        // which used to flip path resolution away from `Personas/` and make
        // those agents vanish from Settings. Idempotent + conflict-safe.
        OsaurusPaths.migrateLegacyPersonasIfNeeded()

        // Make MLX C++ errors recoverable instead of process-fatal. Must run
        // before any model load can call into MLX so the first forward pass
        // is already protected. See `MLXErrorRecovery` for the rationale and
        // the specific crash class this prevents.
        MLXErrorRecovery.installGlobalHandler()

        // Register in-tree document format adapters before any file-ingress
        // path can run. Idempotent; safe if a future migration moves this.
        DocumentAdaptersBootstrap.registerBuiltIns()

        // Register every default-agent configure-tool domain. This is what
        // wires the consolidated `osaurus_provider`, `osaurus_model`, etc.
        // into `ToolRegistry` and feeds the system-prompt domain menu. Adding
        // a new domain is one new file under `Tools/Configuration/` plus one
        // register call in `ConfigurationDomainBootstrap`.
        ConfigurationDomainBootstrap.registerBuiltIns()

        // Bring up analytics early so the launch + onboarding funnel is
        // captured. No-ops silently when no Aptabase key is configured.
        TelemetryService.shared.configure()

        // Install the crash + app-hang handler as early as possible so it
        // covers the rest of launch. Crash reporting is opt-out (on unless the
        // user turned it off, independent of analytics); no-ops only when
        // disabled or when no Sentry DSN is configured.
        CrashReportingService.shared.startIfConsented()

        // Detect repeated startup crashes and enter safe mode if needed
        LaunchGuard.checkOnLaunch()

        // Migrate legacy → vmlx runtime settings. Deferred out of
        // `ServerController.init()` so it doesn't run before the app
        // is fully launched. See `bootstrapRuntimeSettings()`.
        serverController.bootstrapRuntimeSettings()

        // Wire up the periodic SQLite maintenance ticker (PRAGMA
        // optimize / wal_checkpoint / VACUUM at sensible intervals).
        // Idempotent — safe even if some DBs aren't open yet, the
        // ticker only touches handles that are currently registered.
        Task.detached(priority: .background) {
            await StorageMaintenance.shared.start()
        }

        // DSV4 cache topology is owned by vmlx-swift. Leave
        // `DSV4_KV_MODE` unset here so the library default uses its
        // production SWA+CSA+HSA hybrid cache; explicit operator env vars
        // remain honored by vmlx for diagnostics.

        // App has launched
        NSLog("Osaurus server app launched")

        // Log per-launch adoption count for the Agent DB feature.
        // The total is across both built-in and custom agents
        // because `effectiveDBEnabled` honours per-agent overrides
        // for both buckets (spec §5.5). Useful dogfood signal —
        // also feeds into the `dbEnabled adoption` heuristic the
        // gap-closure plan asked us to track.
        let allAgents = AgentManager.shared.agents
        let dbEnabledCount = allAgents.filter { $0.settings.dbEnabled }.count
        NSLog(
            "[Osaurus] AgentDB adoption: %d/%d agents have dbEnabled=true",
            dbEnabledCount,
            allAgents.count
        )

        // Configure local notifications
        NotificationService.shared.configureOnLaunch()

        // If PocketTTS models are already on disk, preload them so the first
        // speaker tap plays immediately without routing to settings.
        TTSService.shared.refreshModelState()

        // Set up observers for server state changes
        setupObservers()

        // Start tracking the user's most-recently-active (non-Osaurus) app so
        // the opt-in screen-context snapshot can recover "what they were doing"
        // even when Osaurus is itself frontmost at send time. Cheap: a single
        // NSWorkspace activation observer.
        FrontmostAppTracker.shared.start()

        // Set up distributed control listeners (local-only management)
        setupControlNotifications()

        // Recover skipped subsystems if a degraded (safe-mode) launch turns
        // out healthy (clean /health). See `LaunchGuard.noteHealthyHealthCheck`.
        setupSafeModeRecovery()

        // Apply saved Start at Login preference on launch
        let launchedByCLI = ProcessInfo.processInfo.arguments.contains("--launched-by-cli")
        if !launchedByCLI {
            LoginItemService.shared.applyStartAtLogin(serverController.configuration.startAtLogin)
        }

        // Create status bar item, attach click handler, and overlay the
        // activity + VAD indicator dots. See `installStatusItem`.
        installStatusItem()

        // Start the main-thread watchdog to detect UI hangs. Enabled in
        // release too (with a more conservative threshold) so a field hang
        // leaves a unified-log breadcrumb diagnosable without a debugger.
        MainThreadWatchdog.shared.start()

        // Initialize directory access early so security-scoped bookmark is active
        _ = DirectoryPickerService.shared

        if keychainDisabledTestMode {
            log.warning(
                "Keychain disabled by OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1; stored secrets will not be readable in this process"
            )
            LaunchGuard.markStartupComplete()
        } else if LaunchGuard.shouldSkip(.plugins) {
            // Tiered safe mode: plugins are the first subsystem we drop. Other
            // tiers (sandbox / distillation / auto model-load) are gated at
            // their own start sites below via `LaunchGuard.shouldSkip(...)`.
            NotificationService.shared.postSafeModeActive()
            LaunchGuard.markStartupComplete()
        } else {
            // Load external tool plugins at launch (after core is initialized)
            Task { @MainActor in
                await PluginManager.shared.loadAll()
                LaunchGuard.markStartupComplete()
            }

            // Start plugin repository background refresh for update checking
            PluginRepositoryService.shared.startBackgroundRefresh()
        }

        // Pre-warm cheap caches immediately for instant first window.
        _ = SpeechConfigurationStore.load()

        // Bind the local HTTP server before heavier optional startup work such
        // as provider connection, model-picker bundle metadata scans,
        // scheduler DB polling, sandbox registration, or Parakeet/CoreML
        // auto-load can occupy the main actor or accelerator.
        let serverStartupTask = Task { @MainActor in
            await serverController.startServer()
        }

        // Let the Bonjour-expose Combine sink honor live restarts only after
        // the initial bind completes. Until then an early `AgentManager`
        // emission would otherwise restart the server mid-launch (hang audit).
        Task { @MainActor in
            await serverStartupTask.value
            serverController.markLaunchComplete()
            // The unified prewarm builds the picker with whatever is currently
            // available; once remote providers finish connecting below they post
            // .remoteProviderModelsChanged and the cache rebuilds automatically.
            // Keep this after server bind so very large local bundles cannot
            // block `/health` and API startup while their config is inspected.
            ModelPickerItemCache.shared.prewarm()
        }

        // Only warm the storage key when the user opted in to encryption.
        // The default plaintext posture needs no key, so launch never touches
        // the Keychain in that case.
        if StorageEncryptionPolicy.shared.isEncryptionEnabled {
            Task.detached(priority: .utility) {
                try? await StorageKeyManager.shared.prewarmCurrentKeyOffCooperativeExecutor()
            }
        }

        // Seed the identity-existence memo off the main thread so the first
        // `existsCached()` caller (RemoteProviderManager's managed-router gate,
        // reached from the periodic badge recompute) doesn't pay a synchronous
        // keychain probe on the main thread during a cold singleton init.
        if !keychainDisabledTestMode {
            MasterKey.warmExistsCacheInBackground()
        }

        Task { @MainActor in
            if !keychainDisabledTestMode {
                await MCPProviderManager.shared.connectEnabledProviders()
                await RemoteProviderManager.shared.connectEnabledProviders()
            }
            await ModelPickerItemCache.shared.prewarmModelCache()
        }

        // VecturaKit inits run sequentially. Memory DB opens first because
        // MemorySearchService.initialize() needs it for reverse maps.
        // MetalGate serializes CoreML/MLX at runtime; this task is only held
        // for startup sequencing of orphan recovery + activity tracking below.
        // Databases are created/opened already SQLCipher-encrypted via
        // `EncryptedSQLiteOpener`; each `*Database.shared.open()` only parks
        // on `StorageMutationGate` while a key rotation is in flight.
        let embeddingInitTask = Task.detached(priority: .utility) {
            // Converge on-disk storage to the selected posture (default:
            // plaintext) before opening anything. For existing encrypted
            // installs this decrypts in place while the key is still available;
            // for plaintext installs it is a fast no-op. Runs under the storage
            // mutation gate so lazy opens park until it finishes.
            await StorageMigrationCoordinator.shared.convergeOnLaunch()

            // Only encrypted mode needs the Keychain key resident before we
            // open SQLCipher databases. Await the prewarm before the cache gate
            // so storage-dependent init isn't skipped purely because the
            // (separately dispatched) launch prewarm hasn't landed yet. Uses
            // the off-cooperative variant so it never pins a Swift cooperative
            // thread inside the synchronous Keychain read. In plaintext mode
            // no key is required, so storage-dependent services always come up.
            if StorageEncryptionPolicy.shared.isEncryptionEnabled {
                try? await StorageKeyManager.shared.prewarmCurrentKeyOffCooperativeExecutor()
                guard StorageKeyManager.shared.hasCachedKey else {
                    MemoryLogger.database.error(
                        "Storage-dependent search/index services disabled — storage key is not already unlocked"
                    )
                    return
                }
            }
            var memoryDBOpened = false
            var lastMemoryOpenError: Error?
            for attempt in 1 ... 3 {
                do {
                    try MemoryDatabase.shared.open()
                    memoryDBOpened = true
                    break
                } catch {
                    lastMemoryOpenError = error
                    MemoryLogger.database.error("Memory database open attempt \(attempt)/3 failed: \(error)")
                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                    }
                }
            }
            if memoryDBOpened {
                await MemorySearchService.shared.initialize()
            } else {
                MemoryLogger.database.error("Memory system disabled — database failed to open after 3 attempts")
                // Preserve the real cause so diagnostics can classify it
                // (key-locked vs corrupt vs migration) and offer recovery.
                PersistenceHealth.shared.recordDatabaseOpenFailure(
                    subsystem: StorageRecoveryService.Store.memory.rawValue,
                    error: lastMemoryOpenError
                        ?? MemoryDatabaseError.failedToOpen("open failed after 3 attempts"),
                    path: OsaurusPaths.memoryDatabaseFile().path
                )
            }

            do {
                try MethodDatabase.shared.open()
            } catch {
                PersistenceHealth.shared.recordDatabaseOpenFailure(
                    subsystem: StorageRecoveryService.Store.method.rawValue,
                    error: error,
                    path: OsaurusPaths.methodsDatabaseFile().path
                )
            }
            await MethodSearchService.shared.initialize()

            do {
                try ToolDatabase.shared.open()
            } catch {
                PersistenceHealth.shared.recordDatabaseOpenFailure(
                    subsystem: StorageRecoveryService.Store.tool.rawValue,
                    error: error,
                    path: OsaurusPaths.toolIndexDatabaseFile().path
                )
            }
            await ToolSearchService.shared.initialize()

            await SkillSearchService.shared.initialize()

            await ToolIndexService.shared.syncFromRegistry(rebuildVectorIndex: false)
        }
        // Start activity tracking, drain any pending sessions left over from
        // the previous launch, and arm the periodic consolidator.
        Task { @MainActor in
            await embeddingInitTask.value
            if MemoryDatabase.shared.isOpen {
                ActivityTracker.shared.start()
                await MemoryService.shared.recoverOrphanedSignals()
                // Tiered safe mode: skip background distillation if a crash
                // loop escalated past the distillation threshold.
                if !LaunchGuard.shouldSkip(.distillation) {
                    await MemoryConsolidator.shared.start()
                }
            }
        }

        // Setup global hotkey for Chat overlay (configured)
        applyChatHotkey()

        // Auto-load speech model if voice features are enabled. Tiered safe
        // mode can skip auto model-load entirely (a crashing model bundle is a
        // common startup-crash cause).
        Task { @MainActor in
            await serverStartupTask.value
            if !LaunchGuard.shouldSkip(.autoModelLoad) {
                await SpeechService.shared.autoLoadIfNeeded()
            }
        }

        // Initialize VAD service if enabled
        initializeVADService()

        // Setup VAD detection notification listener
        setupVADNotifications()

        // Initialize Transcription Mode service
        initializeTranscriptionModeService()

        // Initialize ScheduleManager to start scheduled tasks
        _ = ScheduleManager.shared

        // Initialize WatcherManager to start file system watchers
        _ = WatcherManager.shared

        if !keychainDisabledTestMode {
            Task.detached(priority: .utility) {
                await AgentChannelTransportSupervisor.shared.startFromLaunch()
            }
        }

        // Start the self-scheduling loop once storage is ready. In plaintext
        // mode (the default) that's immediate; in opt-in encrypted mode it
        // waits until the key is resident so startup never triggers a
        // Keychain/password prompt.
        Task { @MainActor in
            guard StorageKeyManager.shared.isStorageReadyForWrites else {
                NSLog("[Osaurus] Scheduler disabled: storage key is not already unlocked")
                // Arm a one-shot start for when the key becomes resident,
                // so slots persisted from a previous session still fire
                // once the user unlocks encrypted storage.
                NextRunScheduler.shared.startWhenStorageBecomesReady()
                return
            }
            NextRunScheduler.shared.start()
        }

        // Start sandbox tool registrar. Internally awaits container
        // auto-start before the initial `registerTools` call, so the first
        // compose for the active agent sees real sandbox tools instead of
        // the placeholder. (Replaces a separate `Task.detached` startContainer
        // call that used to race the registrar's first registration.)
        // Tiered safe mode can skip the Linux sandbox VM (a heavy, crash-prone
        // subsystem) while keeping the rest of the server alive.
        if !keychainDisabledTestMode && !LaunchGuard.shouldSkip(.sandbox) {
            SandboxToolRegistrar.shared.start()
        }

        // Present the initial user-facing window. The 300 ms defer keeps
        // window-server frames clean during the loud first second of launch:
        //
        //  - It lets the services started above settle so their first
        //    `NSPanel`/`orderFrontRegardless` calls don't share a frame
        //    with the onboarding/chat window, which is when stray "old
        //    window" flashes surface.
        //  - `ToastWindowController` and `NotchWindowController` `setup()`
        //    both build transparent overlay panels and order them front;
        //    we run them *after* the user-facing window in the same Task
        //    so they can't paint in its place during launch.
        //  - The SwiftUI Settings-placeholder key observer
        //    (`suppressSwiftUISettingsPlaceholder`) is torn down here. By
        //    the time our window is on screen, Cmd+, routes through
        //    `settingsCommand` and AppKit won't auto-present the
        //    placeholder again.
        let presentOnboarding = OnboardingService.shared.shouldShowOnboarding
        let userInitiatedLaunch = isUserInitiatedLaunch(notification)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms

            // final sweep for the Tahoe placeholder suppression. no op
            // on Sequoia (observers never installed)
            if #available(macOS 26.0, *) {
                sweepSwiftUISettingsPlaceholder()
            }

            if #unavailable(macOS 26.0) {
                await Task.yield()
                try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
            }

            if keychainDisabledTestMode && !keychainDisabledUIPresentationMode {
                // Headless live-proof launches only need the local HTTP server.
            } else if presentOnboarding {
                showOnboardingWindow()
            } else if userInitiatedLaunch {
                presentInitialWindow()
            } else {
                log.info("Non-default launch — skipping default chat window")
            }

            if keychainDisabledTestMode && !keychainDisabledUIPresentationMode {
                ProcessInfo.processInfo.disableAutomaticTermination(
                    "Osaurus keychain-free headless live proof server"
                )
            }

            if !keychainDisabledTestMode {
                ToastWindowController.shared.setup()
                NotchWindowController.shared.setup()
            }

            // Existing users who upgraded from a build without the onboarding
            // consent step never made a telemetry choice, so nothing is sent
            // for them. Ask once now (the toast overlay host is up) rather than
            // silently deciding for them. New users / re-onboarders made the
            // choice in onboarding, so this is gated to the no-onboarding path.
            if !keychainDisabledTestMode && !presentOnboarding {
                maybePromptForTelemetryConsent()
            }

            // tear down the Tahoe placeholder observers
            if #available(macOS 26.0, *) {
                for name in Self.swiftUISettingsPlaceholderNotifications {
                    NotificationCenter.default.removeObserver(
                        self,
                        name: name,
                        object: nil
                    )
                }
            }

            // Once the initial window has had a beat to settle, prewarm
            // the AI-greeting pool for whichever (agent, model) the
            // user last had open. This is purely additive: if the user
            // opens a *different* agent first, the chat view's own
            // `setActive` / `warmUp` calls will still drive the right
            // pool — but for the common "reopen the same agent I just
            // had" workflow this trims the cold inference wait off the
            // first chat session of the launch.
            if !keychainDisabledTestMode {
                prewarmGreetingPoolIfEnabled()
                // Build the Settings/management window graph while idle so the
                // first open is instant
                // instead of stalling on a synchronous SwiftUI construct+layout.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    self?.prewarmManagementWindow()
                    // Warm ChatView's (deep, slow-to-realize) generic metadata too,
                    // spaced out so the two heavy SwiftUI realizations don't stack
                    // into a single main-thread stall during the launch settle.
                    try? await Task.sleep(for: .seconds(1.0))
                    ChatWindowManager.shared.prewarmChatView()
                    // And the menu-bar popover content, so the first click on
                    // the status item doesn't pay the panel's first realization.
                    try? await Task.sleep(for: .seconds(1.0))
                    self?.prewarmStatusPanel()
                }
            }
        }

        // Start Sparkle at launch so update checks run whenever the app is
        // open, not only when the settings window is first shown. First access
        // instantiates the lazy updater controller, which also arms Sparkle's
        // own 24h scheduled check cycle for long-running sessions. Delayed a
        // few seconds so it stays clear of the busy launch window (server
        // bind, prewarms, database opens).
        if !keychainDisabledTestMode {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.updater.checkForUpdatesInBackground()
            }
        }
    }

    /// Fire-and-forget launch prewarm. Skipped when the last-active
    /// agent has generative greetings off, when no last-active context
    /// was ever recorded (fresh install), or when that agent is no
    /// longer in the store (it was deleted between launches).
    @MainActor
    private func prewarmGreetingPoolIfEnabled() {
        guard let last = GenerativeGreetingPool.lastActiveContext(),
            let agent = AgentManager.shared.agents.first(where: { $0.id == last.agentId }),
            agent.shouldUseGenerativeGreetings
        else { return }
        Task.detached(priority: .utility) { [agent, model = last.model] in
            await GenerativeGreetingPool.shared.warmUp(for: agent, model: model)
        }
    }

    /// One-time telemetry consent prompt for users upgrading from a build that
    /// predates the onboarding consent step. Their decision is `undecided`, so
    /// nothing is sent yet; this asks explicitly rather than ever defaulting
    /// them on. No-ops on keyless builds and once any choice is recorded
    /// (`needsConsentDecision`), so it shows at most once and never to users
    /// who already chose.
    ///
    /// Hosted in the user's landing app window (chat overlay, else management)
    /// so it behaves like an app modal and recedes when Osaurus is deactivated,
    /// falling back to the screen-level toast overlay only if no app window is
    /// up. Any dismissal (the "Not Now" button or a tap outside) records a
    /// decline: we treat "didn't say yes" as off.
    @MainActor
    private func maybePromptForTelemetryConsent() {
        let telemetry = TelemetryService.shared
        guard telemetry.needsConsentDecision else { return }

        Task { @MainActor in
            // Let the initial window settle so the alert has somewhere to
            // render and isn't lost in the launch churn.
            try? await Task.sleep(nanoseconds: 900_000_000)  // 900ms
            guard telemetry.needsConsentDecision else { return }

            // Host the prompt inside whatever app window the user landed on
            // (chat overlay, else management) so it behaves like an app modal —
            // recedes when Osaurus is deactivated — rather than the toast
            // overlay panel, which sits at status-bar level across all spaces
            // and would hover above other apps. The toast scope is only a
            // last-resort fallback if no app window is up.
            let scope: ThemedAlertScope
            if let chatId = ChatWindowManager.shared.lastFocusedWindowId,
                ChatWindowManager.shared.windowExists(id: chatId) {
                scope = .chat(chatId)
            } else if WindowManager.shared.isVisible(.management) {
                scope = .management
            } else {
                scope = .toastOverlay
            }
            let requestId = UUID()
            ThemedAlertCenter.shared.present(
                ThemedAlertRequest(
                    id: requestId,
                    title: "Help improve Osaurus",
                    message: L(
                        "Osaurus can send anonymous usage data to help us understand how it's used and improve it."
                    ),
                    accessory: AnyView(TelemetryConsentDetails()),
                    buttons: [
                        .cancel(L("Not Now")) {
                            telemetry.setEnabled(false)
                        },
                        .primary(L("Share Anonymous Data")) {
                            telemetry.setEnabled(true)
                        },
                    ],
                    width: 420,
                    onDismiss: {
                        ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                    }
                ),
                scope: scope
            )
        }
    }

    /// The body of the consent prompt below its one-line summary: the privacy
    /// guarantees as a scannable icon list (one per line) followed by a quiet
    /// caption pointing to where the choice can be changed. Lifting these out
    /// of a dense paragraph keeps each promise legible at a glance.
    private struct TelemetryConsentDetails: View {
        @Environment(\.theme) private var theme

        private struct Point: Identifiable {
            let id = UUID()
            let icon: String
            let text: LocalizedStringKey
        }

        private let points: [Point] = [
            Point(icon: "lock.shield", text: "No chats, prompts, files, or keys"),
            Point(icon: "person.crop.circle.badge.xmark", text: "No accounts or device profiles"),
            Point(icon: "eye.slash", text: "Nothing is tied to you"),
        ]

        var body: some View {
            VStack(spacing: 20) {
                // Leading-aligned + fixed-width icons so the symbols form a
                // tidy column; `fixedSize` shrinks the block to its widest row
                // so the outer frame can center it as a unit.
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(points) { point in
                        HStack(spacing: 12) {
                            Image(systemName: point.icon)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(theme.accentColor)
                                .frame(width: 22)
                            Text(point.text, bundle: .module)
                                .font(.system(size: 12.5))
                                .foregroundColor(theme.secondaryText)
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)

                Text("You can change this anytime in Settings → Privacy.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
        }
    }

    /// Present whatever window makes sense on a launch (or dock-icon reopen)
    /// where onboarding is already complete: focus existing chat windows if
    /// any are open, fall back to a visible management window, otherwise
    /// pop a fresh chat overlay.
    ///
    /// Deployment target is macOS 15, so we use the post-macOS-14
    /// `activate(options:)` API directly (the legacy
    /// `.activateIgnoringOtherApps` flag was deprecated in 14).
    /// Whether the user opened the app directly, versus macOS launching us to
    /// service something specific. `NSApplicationLaunchIsDefaultLaunchKey` is
    /// `false` for App Intent, deeplink/URL, notification-action, and
    /// state-restoration launches; those flows present their own window (e.g. a
    /// background-task "View Chat" toast), so we must not also pop an empty chat.
    private func isUserInitiatedLaunch(_ notification: Notification) -> Bool {
        (notification.userInfo?["NSApplicationLaunchIsDefaultLaunchKey"] as? Bool) ?? true
    }

    @MainActor
    private func presentInitialWindow() {
        NSApp.unhide(nil)
        _ = NSRunningApplication.current.activate(options: .activateAllWindows)

        if ChatWindowManager.shared.windowCount > 0 {
            ChatWindowManager.shared.focusAllWindows()
        } else if WindowManager.shared.isVisible(.management) {
            WindowManager.shared.show(.management, center: false)
        } else {
            showChatOverlay()
        }
    }

    // MARK: - VAD Service

    private func initializeVADService() {
        let vadConfig = VADConfigurationStore.load()
        guard vadConfig.vadModeEnabled, !vadConfig.enabledAgentIds.isEmpty else { return }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            log.info(
                "VAD auto-start skipped — microphone permission not yet authorized; user must re-enable from Voice settings"
            )
            return
        }

        Task { @MainActor in
            // wait for speech model to be loaded (up to 30 seconds)
            let speechService = SpeechService.shared
            var attempts = 0
            while !speechService.isModelLoaded && attempts < 60 {
                try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms
                attempts += 1
            }

            if speechService.isModelLoaded {
                do {
                    try await VADService.shared.start()
                    log.info("VAD service started successfully on app launch")
                } catch {
                    log.error("Failed to start VAD service: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                log.error("VAD service not started — speech model not loaded after 30s")
            }
        }
    }

    // MARK: - Transcription Mode Service

    private func initializeTranscriptionModeService() {
        // Initialize the transcription mode service and register hotkey if enabled
        TranscriptionModeService.shared.initialize()
        log.debug("Transcription mode service initialized")
    }

    private func setupVADNotifications() {
        // Listen for agent detection from VAD service
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVADAgentDetected(_:)),
            name: .vadAgentDetected,
            object: nil
        )

        // Listen for requests to show main window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowMainWindow(_:)),
            name: NSNotification.Name("ShowMainWindow"),
            object: nil
        )

        // Listen for requests to show voice settings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowVoiceSettings(_:)),
            name: NSNotification.Name("ShowVoiceSettings"),
            object: nil
        )

        // Listen for requests to show management window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowManagement(_:)),
            name: NSNotification.Name("ShowManagement"),
            object: nil
        )

        // Route "user tapped speaker but model isn't ready" to the TTS settings tab.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenTTSSettings(_:)),
            name: .openTTSSettingsRequested,
            object: nil
        )

        // Listen for chat view closed to resume VAD
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleChatViewClosed(_:)),
            name: .chatViewClosed,
            object: nil
        )

        // Listen for requests to close chat overlay (from silence timeout)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCloseChatOverlay(_:)),
            name: .closeChatOverlay,
            object: nil
        )
    }

    @objc private func handleChatViewClosed(_ notification: Notification) {
        log.debug("Chat view closed, checking if VAD should resume…")
        Task { @MainActor in
            // Resume VAD if it was paused
            await VADService.shared.resumeAfterChat()
        }
    }

    @objc private func handleCloseChatOverlay(_ notification: Notification) {
        log.debug("Close chat overlay requested (silence timeout)")
        Task { @MainActor in
            closeChatOverlay()
        }
    }

    @objc private func handleVADAgentDetected(_ notification: Notification) {
        guard let detection = notification.object as? VADDetectionResult else { return }

        Task { @MainActor in
            log.debug("VAD detected agent: \(detection.agentName, privacy: .public)")

            // Check if a window for this agent already exists
            let existingWindows = ChatWindowManager.shared.findWindows(byAgentId: detection.agentId)

            let targetWindowId: UUID
            if let existing = existingWindows.first {
                // Focus existing window for this agent
                log.debug("Found existing window for agent, focusing")
                ChatWindowManager.shared.showWindow(id: existing.id)
                targetWindowId = existing.id
            } else {
                // Create a new chat window for the detected agent
                log.debug("Creating new chat window for agent")
                targetWindowId = ChatWindowManager.shared.createWindow(agentId: detection.agentId)
            }

            log.debug(
                "VAD target window: \(targetWindowId, privacy: .public), windowCount=\(ChatWindowManager.shared.windowCount)"
            )

            // Pause VAD when handling voice input
            await VADService.shared.pause()

            // Start voice input in chat after a delay (let VAD stop and UI settle)
            let vadConfig = VADConfigurationStore.load()
            if vadConfig.autoStartVoiceInput {
                try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms - fast handoff
                log.debug("Triggering voice input in chat for window \(targetWindowId, privacy: .public)")
                NotificationCenter.default.post(
                    name: .startVoiceInputInChat,
                    object: targetWindowId  // Target specific window
                )
            }

            NotificationCenter.default.post(name: .chatOverlayActivated, object: nil)
        }
    }

    @objc private func handleShowMainWindow(_ notification: Notification) {
        Task { @MainActor in
            showChatOverlay()
        }
    }

    @objc private func handleShowVoiceSettings(_ notification: Notification) {
        Task { @MainActor in
            showManagementWindow(initialTab: .voice)
        }
    }

    @objc private func handleShowManagement(_ notification: Notification) {
        Task { @MainActor in
            showManagementWindow()
        }
    }

    @objc private func handleOpenTTSSettings(_ notification: Notification) {
        Task { @MainActor in
            ManagementStateManager.shared.voiceSubTabRequest = VoiceTab.textToSpeech.rawValue
            showManagementWindow(initialTab: .voice)
        }
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleDeepLink(url)
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            // Show onboarding if not completed (mandatory step)
            if OnboardingService.shared.shouldShowOnboarding {
                self.showOnboardingWindow()
                return
            }

            self.presentInitialWindow()
        }

        return true
    }

    // MARK: - Dock Menu

    public func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "New Chat", action: #selector(dockNewChat), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Agents", action: #selector(dockShowAgents), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(dockShowSettings), keyEquivalent: ""))
        #if DEBUG
            menu.addItem(NSMenuItem.separator())
            menu.addItem(
                NSMenuItem(title: "Reset Onboarding", action: #selector(dockResetOnboarding), keyEquivalent: "")
            )
            menu.addItem(
                NSMenuItem(title: "Preview What's New", action: #selector(dockPreviewWhatsNew), keyEquivalent: "")
            )
        #endif
        return menu
    }

    @objc private func dockNewChat() {
        showChatOverlay()
    }

    @objc private func dockShowAgents() {
        showManagementWindow(initialTab: .agents)
    }

    @objc private func dockShowSettings() {
        showManagementWindow(initialTab: nil)
    }

    #if DEBUG
        @objc private func dockResetOnboarding() {
            OnboardingService.shared.resetOnboarding()
            showOnboardingWindow(forceFresh: true)
        }

        @objc private func dockPreviewWhatsNew() {
            WhatsNewGate.preview()
            // A fresh chat window re-runs the `onAppear` gate check, which
            // now force-returns every release's notes and presents the modal
            // regardless of the dev build's bundle version.
            ChatWindowManager.shared.createWindow()
        }
    #endif

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Defer termination so in-flight inference tasks and MLX GPU resources are
        // released before exit() triggers C++ static destructors.
        //
        // Issue #860: the previous version guarded the server shutdown on
        // `serverController.isRunning`. That flag can be false while the
        // underlying NIO `MultiThreadedEventLoopGroup` is still alive
        // (e.g. mid-partial-start, mid-shutdown, or Sparkle-triggered
        // quit racing against server cleanup). When the EL group is
        // still non-nil at `exit()`, NIO's destructor hits
        // `preconditionFailure("EventLoopGroup is still running")` —
        // EXC_BREAKPOINT at `NIO-ELT-3` as reported. `ensureShutdown()`
        // itself is a no-op if everything is already nil, so always
        // call it.
        //
        // We also always stop the sandbox (which in turn stops the
        // HostAPIBridgeServer) so its 2-thread EL group can't leak
        // past quit even when no sandbox container was started.
        //
        // Hang audit: the teardown below is a *bounded* best-effort chain,
        // ordered by what the OS can and cannot reclaim for us on exit.
        //
        //   Phase 0 (sync, instant): freeze every background dispatcher and
        //     audio engine so nothing schedules new LLM/DB/FS/GPU work mid-
        //     teardown.
        //   Phase 1 + 2 (must-not-orphan): cancel generations (ends SSE so
        //     NIO drains), SIGKILL live-exec jobs, kill MCP stdio runners,
        //     stop MCP servers, shut down NIO, stop the Linux VM, stop the
        //     bridge. The OS does NOT clean these up for us — leak them and
        //     we orphan child processes / a VM / a NIO group past quit.
        //   Phase 3 (abandonable): memory flush + MLX/GPU teardown. The OS
        //     reclaims RAM/GPU on exit, so if anything wedges here it is safe
        //     to abandon.
        //
        // Every step is wrapped in `runWithDeadline`. A global watchdog set
        // *above* the guaranteed-cleanup budget (phases 0–2) guarantees
        // `reply(true)` always fires; because it sits above that budget it
        // can only ever cut the abandonable phase-3 tail, never an orphan-
        // prone step.

        // Reentrancy guard: a second Cmd-Q, or a Sparkle-triggered relaunch
        // racing a user quit, must not spawn a duplicate teardown chain +
        // watchdog or double-call `NSApp.reply(...)`. Once we've started
        // terminating we stay terminating; the first chain (or the watchdog)
        // owns the single reply.
        if isTerminating {
            return .terminateLater
        }
        isTerminating = true

        // Global watchdog: hard ceiling on the entire quit. Independent of
        // the ordered chain below, so it fires even if a step blocks the
        // chain's own continuations. 22s comfortably exceeds the sum of the
        // phase 0–2 (must-not-orphan) budgets (~18s), so a watchdog firing
        // can only ever cut the abandonable phase-3 MLX/memory tail.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(22 * 1_000_000_000))
            if !hasRepliedToTermination {
                log.error("Quit watchdog fired after 22s — forcing termination reply")
            }
            replyToTerminationOnce()
        }

        Task { @MainActor in
            // ── Phase 0: freeze everything that can dispatch new work ──
            // All cheap + synchronous (cancel timers / tasks, stop FSEvents,
            // tear down audio taps), so no per-step deadline is needed.
            ChatWindowManager.shared.stopAllSessions()
            BackgroundTaskManager.shared.cancelAllTasks()
            RemoteProviderManager.shared.disconnectAll()

            NextRunScheduler.shared.stop()
            ActivityTracker.shared.stop()
            SystemMonitorService.shared.stopMonitoring()
            ScheduleManager.shared.stop()
            WatcherManager.shared.stop()
            await runWithDeadline(seconds: 2) {
                await AgentChannelTransportSupervisor.shared.stop()
            }
            // MemoryConsolidator / StorageMaintenance are actors; their stop()
            // just cancels timers, so the actor hop is quick — bound it anyway
            // so a busy actor can't stall phase 0.
            await runWithDeadline(seconds: 2) {
                await MemoryConsolidator.shared.stop()
                await StorageMaintenance.shared.stop()
            }

            // Audio: stop the mic engine and TTS playback so neither runs
            // through the quit window. VAD teardown is async (engine stop on
            // a detached queue); bound it so a wedged engine can't stall us.
            TTSService.shared.stop()
            await runWithDeadline(seconds: 2) {
                await VADService.shared.stop()
            }
            if SpeechService.shared.isRecording {
                await runWithDeadline(seconds: 2) {
                    _ = await SpeechService.shared.stopStreamingTranscription(force: true)
                }
            }
            SpeechService.shared.unloadModel()

            // ── Phase 1: must-not-orphan — stop new GPU work + kill children ──
            // Cancel in-flight model generations first. This ends the SSE
            // producers that keep NIO child channels open, so the bounded
            // server shutdown in phase 2 can drain promptly. Buffers are NOT
            // freed here — `clearAll(quit:)` does that in phase 3.
            await runWithDeadline(seconds: 3) {
                await ModelRuntime.shared.cancelAllGenerations()
            }

            // Kill orphan-prone child processes: live exec jobs (background
            // `shell_run` / `sandbox_exec`) and MCP stdio runners, then MCP
            // servers. SIGKILL is effectively instant, so these budgets are
            // small.
            await runWithDeadline(seconds: 2) {
                await LiveExecRegistry.shared.terminateAll()
            }
            await runWithDeadline(seconds: 2) {
                await MCPProviderManager.shared.shutdownAllStdioRunners()
            }
            await runWithDeadline(seconds: 2) {
                await MCPServerManager.shared.stopAll()
            }

            // ── Phase 2: must-not-orphan — network + VM teardown ──
            // ensureShutdown is idempotent when already clean. The NIO
            // graceful shutdown is itself bounded inside `stop(gracefully:
            // false)`; the outer deadline is a backstop.
            await runWithDeadline(seconds: 4) {
                await self.serverController.ensureShutdown()
            }
            await runWithDeadline(seconds: 3) {
                do {
                    try await SandboxManager.shared.stopContainer()
                } catch {
                    NSLog("[Osaurus] Sandbox stop failed: \(error)")
                }
            }
            // Belt-and-suspenders: if the sandbox was never provisioned,
            // `stopContainer` still stops the bridge, but if the bridge was
            // started through some other path we want its EL group torn down
            // regardless.
            await runWithDeadline(seconds: 2) {
                await HostAPIBridgeServer.shared.stop()
            }

            // ── Phase 3: abandonable — OS reclaims RAM/GPU on exit ──
            // Drain debounced memory sessions before MLX teardown so the user
            // doesn't lose pending signals to the 60s debounce race. Bounded
            // internally (5s) and here (belt + braces).
            await runWithDeadline(seconds: 6) {
                await MemoryService.shared.flushAllPending(timeoutSeconds: 5)
            }
            // Free MLX / GPU buffers. `quit: true` caps the lease drain, skips
            // the cooperative cold-load join, and refuses to free buffers a
            // stuck lease still references (UAF guard) so a wedged generation
            // can't hang exit or crash the Metal teardown.
            await runWithDeadline(seconds: 6) {
                await ModelRuntime.shared.clearAll(quit: true)
            }

            replyToTerminationOnce()
        }
        return .terminateLater
    }

    /// Tracks whether a termination teardown is already in flight. Set once on
    /// the first `applicationShouldTerminate` and never reset — a second quit
    /// (Cmd-Q spam, Sparkle relaunch racing a user quit) returns
    /// `.terminateLater` without spawning a duplicate teardown chain/watchdog.
    /// `@MainActor`-isolated, so no lock is needed.
    private var isTerminating = false

    /// Guards `recoverFromSafeMode` so a flurry of `/health` hits can't start
    /// the skipped subsystems more than once.
    private var hasRecoveredFromSafeMode = false

    /// Tracks whether the termination reply has already been sent so the
    /// ordered teardown chain and the global quit watchdog can race to call
    /// `reply(true)` without double-replying. `@MainActor`-isolated, so the
    /// two `@MainActor` tasks accessing it are serialized — no lock needed.
    private var hasRepliedToTermination = false

    /// Send `NSApp.reply(toApplicationShouldTerminate: true)` exactly once.
    /// Idempotent: whichever of the teardown chain or the watchdog reaches
    /// this first wins; subsequent calls are no-ops.
    @MainActor
    private func replyToTerminationOnce() {
        guard !hasRepliedToTermination else { return }
        hasRepliedToTermination = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        NSLog("Osaurus server app terminating")
        PluginRepositoryService.shared.stopBackgroundRefresh()
        ToastWindowController.shared.teardown()
        NotchWindowController.shared.teardown()
        SharedConfigurationService.shared.remove()
        // `applicationWillTerminate` is sync and the process exits as
        // soon as it returns. Bridge to the actor synchronously so
        // any debounced greeting-pool entries land on disk — without
        // this, a quit within the 1s save debounce silently throws
        // away the latest seeds and the next launch is cold again.
        flushGreetingPoolSync()

        // Tool enable/policy changes persist via a background serial writer to
        // keep the UI snappy; drain it here so a toggle made right before quit
        // isn't lost when `_exit` skips the pending write.
        ToolConfigurationStore.flushPendingWrites()

        // Same for the Computer Use autonomy policy (its own coalescing writer).
        ComputerUsePolicyStore.flushPendingWrites()

        // Aptabase batches analytics in an in-memory queue and normally drains
        // it from its own `willTerminate` observer — but that flush is async and
        // the `_exit(0)` below skips it. Kick a final bounded, best-effort send
        // so the last session's events have a chance to leave first. No-op unless
        // telemetry is live and consented, so most quits pay nothing here.
        TelemetryService.shared.flushForQuit()

        // Hard-exit without running `atexit`/C++ static destructors.
        // AppKit's `terminate:` would otherwise call `exit()`, which runs
        // `__cxa_finalize_ranges` on the main thread and tears down MLX/Metal's
        // global compute-pipeline cache. If any thread still touches GPU state
        // during that teardown — an abandoned generation we cancelled but
        // couldn't join (see `clearAll(quit:)`'s stuck-lease path), or live
        // Network/QUIC work — the dealloc races it into a use-after-free
        // SIGSEGV that macOS reports as a crash on quit. `_exit` skips all of
        // that: the kernel reclaims the address space and GPU resources
        // atomically, so no in-flight thread can lose its objects mid-call.
        Darwin._exit(0)
    }

    /// Synchronously bridge to the greeting-pool actor so its
    /// debounced save lands before the process exits. Capped at
    /// 1.5s so a stalled write can't block the user's quit.
    private func flushGreetingPoolSync() {
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await GenerativeGreetingPool.shared.flushPendingSave()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1.5)
    }

    // MARK: Status Item / Menu

    /// Which corner of the status-bar button a status dot is pinned to.
    /// The activity (server-busy) indicator sits at `.bottomTrailing`; the
    /// VAD indicator sits at `.topTrailing`. Both use a 3 pt inset.
    private enum StatusDotCorner {
        case bottomTrailing
        case topTrailing
    }

    /// Builds the menu-bar status item (icon, tooltip, click target) and
    /// installs the two indicator dots. Idempotent at call-site only: this
    /// is called exactly once from `applicationDidFinishLaunching`.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = NSImage(named: "osaurus") {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "Osaurus"
            }
            button.toolTip = L("Osaurus Server")
            button.target = self
            button.action = #selector(togglePopover(_:))

            // Green blinking dot — server is generating.
            activityDot = makeStatusDot(in: button, color: .systemGreen, corner: .bottomTrailing)

            // Blue/red pulse — VAD listening / error.
            vadDot = makeStatusDot(in: button, color: .systemBlue, corner: .topTrailing)
        }
        statusItem = item
        updateStatusItemAndMenu()
    }

    /// Creates a 7x7 circular overlay view anchored to one corner of `button`.
    /// The view starts hidden; callers toggle visibility + animation in
    /// `updateStatusItemAndMenu`.
    private func makeStatusDot(
        in button: NSStatusBarButton,
        color: NSColor,
        corner: StatusDotCorner
    ) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.isHidden = true
        button.addSubview(dot)

        // Constants chosen to fit comfortably inside the menu-bar icon's
        // safe area without clipping at any system text size.
        let inset: CGFloat = 3
        let side: CGFloat = 7

        var constraints: [NSLayoutConstraint] = [
            dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -inset),
            dot.widthAnchor.constraint(equalToConstant: side),
            dot.heightAnchor.constraint(equalToConstant: side),
        ]
        switch corner {
        case .bottomTrailing:
            constraints.append(dot.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -inset))
        case .topTrailing:
            constraints.append(dot.topAnchor.constraint(equalTo: button.topAnchor, constant: inset))
        }
        NSLayoutConstraint.activate(constraints)

        if let layer = dot.layer {
            layer.backgroundColor = color.cgColor
            layer.cornerRadius = side / 2
            layer.borderWidth = 1
            layer.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        }
        return dot
    }

    private func setupObservers() {
        cancellables.removeAll()
        serverController.$serverHealth
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemAndMenu()
            }
            .store(in: &cancellables)
        serverController.$isRunning
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemAndMenu()
            }
            .store(in: &cancellables)
        serverController.$configuration
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemAndMenu()
            }
            .store(in: &cancellables)

        serverController.$activeRequestCount
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemAndMenu()
            }
            .store(in: &cancellables)

        // Observe VAD service state for menu bar indicator
        VADService.shared.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemAndMenu()
            }
            .store(in: &cancellables)

        // Publish shared configuration on state/config/address changes
        Publishers.CombineLatest3(
            serverController.$serverHealth,
            serverController.$configuration,
            serverController.$localNetworkAddress
        )
        .receive(on: RunLoop.main)
        .sink { health, config, address in
            SharedConfigurationService.shared.update(
                health: health,
                configuration: config,
                localAddress: address
            )
        }
        .store(in: &cancellables)
    }

    private func updateStatusItemAndMenu() {
        guard let statusItem else { return }
        // Ensure no NSMenu is attached so button action is triggered
        statusItem.menu = nil
        if let button = statusItem.button {
            // Update status bar icon
            if let image = NSImage(named: "osaurus") {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = true
                button.image = image
            }
            // Toggle green blinking dot overlay
            let isGenerating = serverController.activeRequestCount > 0
            if let dot = activityDot {
                if isGenerating {
                    dot.isHidden = false
                    if let layer = dot.layer, layer.animation(forKey: "blink") == nil {
                        let anim = CABasicAnimation(keyPath: "opacity")
                        anim.fromValue = 1.0
                        anim.toValue = 0.2
                        anim.duration = 0.8
                        anim.autoreverses = true
                        anim.repeatCount = .infinity
                        layer.add(anim, forKey: "blink")
                    }
                } else {
                    if let layer = dot.layer {
                        layer.removeAnimation(forKey: "blink")
                    }
                    dot.isHidden = true
                }
            }
            var tooltip: String
            switch serverController.serverHealth {
            case .stopped:
                tooltip =
                    serverController.isRestarting ? "Osaurus — Restarting…" : "Osaurus — Ready to start"
            case .starting:
                tooltip = "Osaurus — Starting…"
            case .restarting:
                tooltip = "Osaurus — Restarting…"
            case .running:
                tooltip = "Osaurus — Running on port \(serverController.port)"
            case .stopping:
                tooltip = "Osaurus — Stopping…"
            case .error(let message):
                tooltip = "Osaurus — Error: \(message)"
            }
            if serverController.activeRequestCount > 0 {
                tooltip += " — Generating…"
            }

            // Update VAD status dot
            let vadState = VADService.shared.state
            if let vDot = vadDot {
                switch vadState {
                case .listening:
                    vDot.isHidden = false
                    if let layer = vDot.layer {
                        layer.backgroundColor = NSColor.systemBlue.cgColor
                        // Add pulse animation for listening state
                        if layer.animation(forKey: "vadPulse") == nil {
                            let anim = CABasicAnimation(keyPath: "opacity")
                            anim.fromValue = 1.0
                            anim.toValue = 0.4
                            anim.duration = 1.2
                            anim.autoreverses = true
                            anim.repeatCount = .infinity
                            layer.add(anim, forKey: "vadPulse")
                        }
                    }
                    tooltip += " — Voice: Listening"

                case .error:
                    vDot.isHidden = false
                    if let layer = vDot.layer {
                        layer.backgroundColor = NSColor.systemRed.cgColor
                        layer.removeAnimation(forKey: "vadPulse")
                    }
                    tooltip += " — Voice: Error"

                default:
                    if let layer = vDot.layer {
                        layer.removeAnimation(forKey: "vadPulse")
                    }
                    vDot.isHidden = true
                }
            }

            // Advertise MCP HTTP endpoints on the same port
            tooltip += " — MCP: /mcp/*"
            button.toolTip = tooltip
        }
    }

    // MARK: - Actions

    /// Warm the SwiftUI metadata for the menu-bar popover's content view.
    /// `showPopover` builds a fresh hosting controller per open, and the first
    /// realization of the panel's view graph can stall the main thread for
    /// seconds on slower machines — right under the user's click on the status
    /// item. A throwaway controller realizes it once during the launch settle;
    /// it's never attached to a window, so `onAppear`/`task` don't fire.
    @MainActor func prewarmStatusPanel() {
        guard popover == nil else { return }
        let root = StatusPanelView()
            .environmentObject(serverController)
            .environment(\.theme, ThemeManager.shared.currentTheme)
            .environmentObject(updater)
        let host = NSHostingController(rootView: root)
        host.view.layoutSubtreeIfNeeded()
        print("[AppDelegate] Prewarmed status panel")
    }

    @objc private func togglePopover(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        showPopover()
    }

    // Expose a method to show the popover programmatically (e.g., for Cmd+,)
    public func showPopover() {
        guard let statusButton = statusItem?.button else { return }
        if let popover, popover.isShown {
            // Already visible; bring app to front
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        let themeManager = ThemeManager.shared
        let statusPanel = StatusPanelView()
            .environmentObject(serverController)
            .environment(\.theme, themeManager.currentTheme)
            .environmentObject(updater)

        popover.contentViewController = NSHostingController(rootView: statusPanel)
        self.popover = popover

        popover.show(relativeTo: statusButton.bounds, of: statusButton, preferredEdge: .minY)

        // ensure popover window can join all spaces and appear over full screen apps
        if let popoverWindow = popover.contentViewController?.view.window {
            popoverWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }

        // Close the popover when the user clicks in another app or on the
        // desktop. Global monitors only fire for events delivered to other
        // applications, so clicks on the status item and our own windows are
        // left to the status item action and the popover's transient behavior.
        popoverDismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.popover?.performClose(nil)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSPopoverDelegate

    public func popoverDidClose(_ notification: Notification) {
        log.debug("Popover closed, posting chatViewClosed notification")

        // Tear down the outside-click monitor regardless of how the popover
        // was closed (status item, transient click, or this monitor itself).
        if let monitor = popoverDismissMonitor {
            NSEvent.removeMonitor(monitor)
            popoverDismissMonitor = nil
        }

        // Post notification so VAD can resume
        NotificationCenter.default.post(name: .chatViewClosed, object: nil)

        if let action = pendingPopoverAction {
            pendingPopoverAction = nil
            Task { @MainActor in
                action()
            }
        }
    }

}

// MARK: - Distributed Control (Local Only)
extension AppDelegate {
    fileprivate static let controlToolsReloadNotification = Notification.Name(
        "com.dinoki.osaurus.control.toolsReload"
    )
    fileprivate static let controlServeNotification = Notification.Name(
        "com.dinoki.osaurus.control.serve"
    )
    fileprivate static let controlStopNotification = Notification.Name(
        "com.dinoki.osaurus.control.stop"
    )
    fileprivate static let controlShowUINotification = Notification.Name(
        "com.dinoki.osaurus.control.ui"
    )

    private func setupControlNotifications() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            self,
            selector: #selector(handleServeCommand(_:)),
            name: Self.controlServeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleStopCommand(_:)),
            name: Self.controlStopNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleShowUICommand(_:)),
            name: Self.controlShowUINotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleToolsReloadCommand(_:)),
            name: Self.controlToolsReloadNotification,
            object: nil
        )
    }

    private func setupSafeModeRecovery() {
        NotificationCenter.default.addObserver(
            forName: .safeModeRecoveryRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recoverFromSafeMode()
            }
        }
    }

    /// Bring subsystems skipped by a degraded launch online after the running
    /// app proved healthy via `/health`. Idempotent and only ever runs once.
    @MainActor
    private func recoverFromSafeMode() {
        guard !hasRecoveredFromSafeMode else { return }
        guard !keychainDisabledTestMode else { return }
        hasRecoveredFromSafeMode = true
        log.warning("Safe-mode recovery: starting previously skipped subsystems after clean /health")

        Task { @MainActor in
            await PluginManager.shared.loadAll()
        }
        PluginRepositoryService.shared.startBackgroundRefresh()
        SandboxToolRegistrar.shared.start()

        Task { @MainActor in
            if MemoryDatabase.shared.isOpen {
                await MemoryConsolidator.shared.start()
            }
        }
    }

    @objc private func handleServeCommand(_ note: Notification) {
        var desiredPort: Int?
        var exposeFlag: Bool = false
        if let ui = note.userInfo {
            if let p = ui["port"] as? Int {
                desiredPort = p
            } else if let s = ui["port"] as? String, let p = Int(s) {
                desiredPort = p
            }
            if let e = ui["expose"] as? Bool {
                exposeFlag = e
            } else if let es = ui["expose"] as? String {
                let v = es.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                exposeFlag = (v == "1" || v == "true" || v == "yes" || v == "y")
            }
        }

        // Apply defaults if not provided
        let targetPort = desiredPort ?? (ServerConfigurationStore.load()?.port ?? 1337)
        guard (1 ..< 65536).contains(targetPort) else { return }

        // Apply exposure policy based on request (default localhost-only)
        serverController.configuration.exposeToNetwork = exposeFlag
        serverController.port = targetPort
        serverController.saveConfiguration()

        Task { @MainActor in
            await serverController.startServer()
        }
    }

    @objc private func handleStopCommand(_ note: Notification) {
        Task { @MainActor in
            await serverController.stopServer()
        }
    }

    @objc private func handleShowUICommand(_ note: Notification) {
        Task { @MainActor in
            self.showPopover()
        }
    }

    @objc private func handleToolsReloadCommand(_ note: Notification) {
        Task { @MainActor in
            await PluginManager.shared.loadAll(forceReload: true)
        }
    }
}

// MARK: Deep Link Handling
extension AppDelegate {
    func applyChatHotkey() {
        let cfg = ChatConfigurationStore.load()
        HotKeyManager.shared.register(hotkey: cfg.hotkey) { [weak self] in
            Task { @MainActor in
                // if opening (about to be shown), and clipboard monitoring is enabled, trigger a selection grab before showing Osaurus
                // to capture content from the currently active application.
                if !ChatWindowManager.shared.hasVisibleWindows && cfg.enableClipboardMonitoring {
                    // start grabbing selection in the background before we take focus
                    Task {
                        _ = await ClipboardService.shared.grabSelection()
                    }
                    // small yield to allow Cmd+C to be posted before toggle takes focus
                    // 50ms
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }

                self?.toggleChatOverlay()
            }
        }
    }
    fileprivate func handleDeepLink(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "osaurus":
            handleOsaurusDeepLink(url)
        case "huggingface":
            handleHuggingFaceDeepLink(url)
        default:
            return
        }
    }

    /// `osaurus://<addr>?pair=<base64url(invite)>` — incoming agent share link.
    /// `osaurus://plugins-install?tool=<plugin_id>` — open Plugins tab on a plugin's detail page.
    /// `osaurus://themes-install?hash=<sha256>` — open Themes tab and install a shared theme.
    fileprivate func handleOsaurusDeepLink(_ url: URL) {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)

            if url.host?.lowercased() == "plugins-install" {
                handlePluginsInstallDeepLink(url)
                return
            }

            if url.host?.lowercased() == ThemeShareService.deepLinkHost {
                showManagementWindow(initialTab: .themes)
                _ = ThemesDeepLinkRouter.handle(url)
                return
            }

            // default: pairing. bring the management window forward as the anchor
            // the approval is presented as its own NSPanel via PairingPromptService
            showManagementWindow(initialTab: .agents)
            _ = PairingDeepLinkRouter.handle(url)
        }
    }

    @MainActor
    fileprivate func handlePluginsInstallDeepLink(_ url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let toolId = components?.queryItems?
            .first(where: { $0.name.lowercased() == "tool" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        ManagementStateManager.shared.pendingPluginDetailId = (toolId?.isEmpty == false) ? toolId : nil
        showManagementWindow(initialTab: .plugins)
    }

    fileprivate func handleHuggingFaceDeepLink(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let items = components.queryItems ?? []
        let modelId = items.first(where: { $0.name.lowercased() == "model" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let file = items.first(where: { $0.name.lowercased() == "file" })?.value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard let modelId, !modelId.isEmpty else {
            // No model id provided; ignore silently
            return
        }

        // Resolve to ensure it appears in the UI; enforce MLX-only via metadata
        Task { @MainActor in
            if await ModelManager.shared.resolveModelIfMLXCompatible(byRepoId: modelId) == nil {
                let alert = NSAlert()
                alert.messageText = L("Unsupported model")
                alert.informativeText = L(
                    "Osaurus supports MLX-compatible Hugging Face repositories, including MLX, MXFP, JANG, JANGTQ, and TurboQuant artifacts when required files are present."
                )
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }

            // Open Model Manager in its own window for deeplinks
            showManagementWindow(initialTab: .models, deeplinkModelId: modelId, deeplinkFile: file)
        }
    }
}

// MARK: - Popover Helper
extension AppDelegate {
    @MainActor private func closePopoverAndPerform(_ action: @escaping @MainActor () -> Void) {
        if let pop = popover, pop.isShown {
            self.pendingPopoverAction = action
            pop.performClose(nil)
        } else {
            action()
        }
    }
}

// MARK: - Chat Overlay Window
extension AppDelegate {
    @MainActor private func toggleChatOverlay() {
        closePopoverAndPerform {
            // Use ChatWindowManager for multi-window support
            ChatWindowManager.shared.toggleLastFocused()

            if ChatWindowManager.shared.hasVisibleWindows {
                // start clipboard monitoring and do an immediate check
                ClipboardService.shared.startMonitoring()
                ClipboardService.shared.checkPasteboard()

                // Pause VAD when chat window is shown (like when VAD detects a agent)
                // This allows voice input to work without competing for the microphone
                Task {
                    await VADService.shared.pause()
                }
                NotificationCenter.default.post(name: .chatOverlayActivated, object: nil)
            } else {
                // stop clipboard monitoring when overlay is hidden to save battery
                ClipboardService.shared.stopMonitoring()
            }
        }
    }

    /// Show a new chat window (creates new window via ChatWindowManager)
    @MainActor func showChatOverlay() {
        closePopoverAndPerform {
            log.debug("Creating new chat window via ChatWindowManager")
            ChatWindowManager.shared.createWindow()

            // start clipboard monitoring and do an immediate check
            ClipboardService.shared.startMonitoring()
            ClipboardService.shared.checkPasteboard()

            // Pause VAD when chat window is shown (like when VAD detects a agent)
            // This allows voice input to work without competing for the microphone
            Task {
                await VADService.shared.pause()
            }

            log.debug("Chat window shown, count=\(ChatWindowManager.shared.windowCount)")
            NotificationCenter.default.post(name: .chatOverlayActivated, object: nil)
        }
    }

    /// Show a new chat window for a specific agent (used by VAD)
    @MainActor func showChatOverlay(forAgentId agentId: UUID) {
        closePopoverAndPerform {
            log.debug(
                "Creating new chat window for agent \(agentId, privacy: .public) via ChatWindowManager"
            )
            ChatWindowManager.shared.createWindow(agentId: agentId)

            log.debug("Chat window shown for agent, count=\(ChatWindowManager.shared.windowCount)")
            NotificationCenter.default.post(name: .chatOverlayActivated, object: nil)
        }
    }

    /// Close the last focused chat overlay (legacy API for backward compatibility)
    @MainActor func closeChatOverlay() {
        if let lastId = ChatWindowManager.shared.lastFocusedWindowId {
            ChatWindowManager.shared.closeWindow(id: lastId)
        }
        log.debug("Chat overlay closed via closeChatOverlay")
    }
}

extension Notification.Name {
    static let chatOverlayActivated = Notification.Name("chatOverlayActivated")
    static let toolsListChanged = Notification.Name("toolsListChanged")
}

// MARK: - Acknowledgements Window
extension AppDelegate {
    private static var acknowledgementsWindow: NSWindow?

    @MainActor public func showAcknowledgements() {
        closePopoverAndPerform {
            // Reuse existing window if already open
            if let existingWindow = Self.acknowledgementsWindow, existingWindow.isVisible {
                existingWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }

            let themeManager = ThemeManager.shared
            let contentView = AcknowledgementsView()
                .environment(\.theme, themeManager.currentTheme)

            let hostingController = NSHostingController(rootView: contentView)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Acknowledgements"
            window.contentViewController = hostingController
            window.center()
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            Self.acknowledgementsWindow = window

            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Onboarding Window
extension AppDelegate {
    private static var onboardingWindow: NSWindow?

    @MainActor public func showOnboardingWindow(forceFresh: Bool = false) {
        closePopoverAndPerform { [weak self] in
            guard let self = self else { return }
            // Reuse existing window if already open (unless forcing a fresh flow)
            if !forceFresh, let existingWindow = Self.onboardingWindow, existingWindow.isVisible {
                existingWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }

            // Close existing window when forcing a fresh flow
            if forceFresh {
                Self.onboardingWindow?.close()
                Self.onboardingWindow = nil
            }

            let themeManager = ThemeManager.shared
            let contentView = OnboardingView(
                onPreferredSizeChange: { [weak self] newSize in
                    self?.resizeOnboardingWindow(to: newSize)
                },
                onComplete: { [weak self] in
                    // Close the onboarding window when complete
                    Self.onboardingWindow?.close()
                    Self.onboardingWindow = nil
                    // Invalidate model cache so fresh models are discovered
                    // This ensures any models downloaded during onboarding are visible
                    ModelPickerItemCache.shared.invalidateCache()
                    // Open ChatView after onboarding completes
                    self?.showChatOverlay()
                }
            )
            .environment(\.theme, themeManager.currentTheme)

            // Use NSHostingView directly in an NSView container to avoid auto-sizing issues.
            // Start the window at the welcome step's preferred height so the first frame
            // doesn't visibly snap into place from a different size.
            let windowWidth: CGFloat = onboardingPreferredWidth(for: .welcome)
            let windowHeight: CGFloat = onboardingPreferredHeight(for: .welcome)

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            // Disable SwiftUI-driven auto-sizing of the hosting view; AppDelegate
            // owns the window's size via `resizeOnboardingWindow(toHeight:)`.
            // Without this, NSHostingView (macOS 14+) reports the SwiftUI content's
            // intrinsic size and can grow the hosting view past the container,
            // producing a tall narrow window.
            if #available(macOS 13.0, *) {
                hostingView.sizingOptions = []
            }

            let containerView = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
            containerView.addSubview(hostingView)

            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            ])

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = ""
            window.contentView = containerView
            window.center()
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.backgroundColor = NSColor(themeManager.currentTheme.primaryBackground)
            window.isMovableByWindowBackground = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            Self.onboardingWindow = window

            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Resize the onboarding window to a new height (width stays fixed),
    /// anchoring the window at its current top edge so the title bar stays put
    /// and growth happens downward.
    @MainActor
    fileprivate func resizeOnboardingWindow(to newSize: CGSize) {
        guard let window = Self.onboardingWindow else { return }
        let clampedHeight = min(max(newSize.height, OnboardingMetrics.minHeight), OnboardingMetrics.maxHeight)
        let newWidth = newSize.width
        let currentFrame = window.frame
        // Skip changes smaller than a couple of points to avoid jitter from
        // SwiftUI re-publishing the same preference during transitions.
        guard abs(currentFrame.height - clampedHeight) > 2 || abs(currentFrame.width - newWidth) > 2 else { return }

        // Anchor the window by its top-centre so the resize feels natural.
        let deltaH = clampedHeight - currentFrame.height
        let deltaW = newWidth - currentFrame.width
        let newFrame = NSRect(
            x: currentFrame.origin.x - deltaW / 2,
            y: currentFrame.origin.y - deltaH,
            width: newWidth,
            height: clampedHeight
        )

        // Animate alongside the SwiftUI slide transition.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            window.animator().setFrame(newFrame, display: true)
        }
    }
}

// MARK: Management Window
extension AppDelegate {
    @MainActor public func showManagementWindow(
        initialTab: ManagementTab? = nil,
        deeplinkModelId: String? = nil,
        deeplinkFile: String? = nil,
        deeplinkAgentId: UUID? = nil,
        deeplinkRemoteAgentId: UUID? = nil
    ) {
        // Remote-agent detail navigation rides the shared management state
        // (mirrors `pendingPluginDetailId`) so it works for both a freshly
        // created window and a reused one without rebuilding the SwiftUI graph.
        if let deeplinkRemoteAgentId {
            ManagementStateManager.shared.pendingRemoteAgentDetailId = deeplinkRemoteAgentId
        }
        closePopoverAndPerform { [weak self] in
            guard let self = self else { return }
            // Reopening a reused window doesn't rebuild the SwiftUI graph, so
            // the Models grid wouldn't otherwise notice external models the
            // user deleted on disk while the app stayed running. Prune them
            // off the main thread; it posts `.localModelsChanged` only when
            // something actually went missing.
            Task.detached(priority: .utility) {
                ExternalModelLocator.pruneMissing()
            }
            // Records the screen the window opens to; `handleTabChange` only
            // fires on later switches, so this captures the initial tab too.
            let shownTab = initialTab ?? ManagementStateManager.shared.selectedTab
            CrashReportingService.recordBreadcrumb(
                category: "navigation",
                message: "management.window \(shownTab.rawValue)"
            )
            let windowManager = WindowManager.shared
            let themeManager = ThemeManager.shared
            let root = ManagementView(
                initialTab: initialTab,
                deeplinkModelId: deeplinkModelId,
                deeplinkFile: deeplinkFile,
                deeplinkAgentId: deeplinkAgentId
            )
            .environmentObject(self.serverController)
            .environmentObject(self.updater)
            .environment(\.theme, themeManager.currentTheme)

            let themeAppearance = NSAppearance(
                named: themeManager.currentTheme.isDark ? .darkAqua : .aqua
            )

            // Reuse existing window if it exists
            if let existingWindow = windowManager.window(for: .management) {
                let hasDeeplink =
                    deeplinkModelId != nil || deeplinkFile != nil || deeplinkAgentId != nil
                if hasDeeplink {
                    // Deeplink targets are baked into the view at creation, so the
                    // hosting controller has to be rebuilt to deliver them.
                    existingWindow.contentViewController = NSHostingController(rootView: root)
                } else if let initialTab {
                    // No deeplink: drive navigation through the shared state the
                    // existing view already observes. Recreating the hosting
                    // controller here tears down and rebuilds the whole SwiftUI
                    // graph synchronously on the main thread, which has been seen
                    // to hang for seconds under memory pressure.
                    ManagementStateManager.shared.selectedTab = initialTab
                }
                existingWindow.appearance = themeAppearance
                windowManager.show(.management, center: false)  // Don't re-center if user moved it
                NSLog("[Management] Reused existing window and brought to front")
                return
            }

            // Create new management window via WindowManager
            let window = windowManager.createWindow(config: .management) {
                root
            }
            window.isReleasedWhenClosed = false
            window.appearance = themeAppearance

            // keep window appearance in sync with theme changes so AppKit
            // chrome stays visible after live theme switches
            themeManager.$currentTheme
                .receive(on: DispatchQueue.main)
                .sink { [weak window] theme in
                    window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
                }
                .store(in: &self.cancellables)

            // Set center to false so the window respects its saved position (via setFrameAutosaveName)
            // instead of being manually centered by the WindowManager on every show.
            windowManager.show(.management, center: false)
            NSLog("[Management] Created new window and presented")
        }
    }

    /// Opens the management window on the Agents tab and deep-links into a
    /// specific agent's detail view, optionally focusing an inner tab and/or a
    /// saved view. The `.agentDetailDeeplink` post is deferred a beat because
    /// `AgentsView` / `AgentDetailView` only attach their `.onReceive` once the
    /// management hierarchy mounts — on a cold-launch open the observers aren't
    /// listening yet when this is called.
    ///
    /// - Parameters:
    ///   - agentId: The target agent.
    ///   - tab: A `DetailTab.rawValue` (e.g. `"subagents"`, `"views"`) to
    ///     focus, or `nil` to leave the detail view on its default tab.
    ///   - viewRef: An optional saved-view name to highlight within the tab.
    @MainActor public func showAgentDetail(
        agentId: UUID,
        tab: String? = nil,
        viewRef: String? = nil
    ) {
        // The built-in Default agent has no configuration detail — land on the
        // all-agents list instead of posting a deep-link the Agents view would
        // just swallow (`detailAgent` drops built-ins).
        guard agentId != Agent.defaultId else {
            showManagementWindow(initialTab: .agents)
            return
        }
        showManagementWindow(initialTab: .agents)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            var payload: [String: Any] = ["agentId": agentId]
            if let tab { payload["tab"] = tab }
            if let viewRef, !viewRef.isEmpty { payload["viewRef"] = viewRef }
            NotificationCenter.default.post(
                name: .agentDetailDeeplink,
                object: nil,
                userInfo: payload
            )
        }
    }

    /// Builds the management window's SwiftUI graph + `NSHostingController`
    /// once, while idle, WITHOUT showing it. The construction + initial layout
    /// of `ManagementView` (sidebar, badge stores, tab shell) is the dominant
    /// cost of opening Settings; doing it here means the first user-initiated
    /// open (e.g. the chat "Insights" button) hits the cheap reuse path in
    /// `showManagementWindow` instead of stalling the click. No-op if the
    /// window already exists.
    @MainActor public func prewarmManagementWindow() {
        let windowManager = WindowManager.shared
        guard windowManager.window(for: .management) == nil else { return }

        let themeManager = ThemeManager.shared
        let root = ManagementView()
            .environmentObject(self.serverController)
            .environmentObject(self.updater)
            .environment(\.theme, themeManager.currentTheme)

        let window = windowManager.createWindow(config: .management) { root }
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: themeManager.currentTheme.isDark ? .darkAqua : .aqua)
        themeManager.$currentTheme
            .receive(on: DispatchQueue.main)
            .sink { [weak window] theme in
                window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
            }
            .store(in: &self.cancellables)
        // Intentionally not shown — it stays registered and hidden until the
        // user opens Settings, at which point `showManagementWindow` reuses it.
        NSLog("[Management] Prewarmed hidden window")
    }
}
