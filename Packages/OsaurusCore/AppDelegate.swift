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

        // Make MLX C++ errors recoverable instead of process-fatal. Must run
        // before any model load can call into MLX so the first forward pass
        // is already protected. See `MLXErrorRecovery` for the rationale and
        // the specific crash class this prevents.
        MLXErrorRecovery.installGlobalHandler()

        // Register in-tree document format adapters before any file-ingress
        // path can run. Idempotent; safe if a future migration moves this.
        DocumentAdaptersBootstrap.registerBuiltIns()

        // Register every default-agent configure-tool domain. This is what
        // wires `osaurus_provider_add`, `osaurus_model_download`, etc. into
        // `ToolRegistry` and feeds the system-prompt domain menu. Adding a
        // new domain is one new file under `Tools/Configuration/` plus one
        // register call in `ConfigurationDomainBootstrap`.
        ConfigurationDomainBootstrap.registerBuiltIns()

        // Detect repeated startup crashes and enter safe mode if needed
        LaunchGuard.checkOnLaunch()

        // CRITICAL SEQUENCING: run the at-rest encryption migrator
        // BEFORE any database opens. Without this gate
        // `MemoryDatabase.shared.open()` below would try SQLCipher
        // against still-plaintext files and fail key verification,
        // leaving the app in a degraded state on first launch after
        // upgrade. We block the launch flow synchronously while the
        // overlay shows progress; the run loop is pumped so SwiftUI
        // updates keep painting.
        StorageMigrationCoordinator.blockingAwaitReady()

        // Deferred from `ServerController.init()` to keep
        // `~/.osaurus/` pristine until the storage gate has stamped
        // `.storage-version`. See `bootstrapRuntimeSettings()`.
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

        // Set up distributed control listeners (local-only management)
        setupControlNotifications()

        // Apply saved Start at Login preference on launch
        let launchedByCLI = ProcessInfo.processInfo.arguments.contains("--launched-by-cli")
        if !launchedByCLI {
            LoginItemService.shared.applyStartAtLogin(serverController.configuration.startAtLogin)
        }

        // Create status bar item, attach click handler, and overlay the
        // activity + VAD indicator dots. See `installStatusItem`.
        installStatusItem()

        // Start main thread watchdog in debug builds to detect UI hangs
        #if DEBUG
            MainThreadWatchdog.shared.start()
        #endif

        // Initialize directory access early so security-scoped bookmark is active
        _ = DirectoryPickerService.shared

        if keychainDisabledTestMode {
            log.warning(
                "Keychain disabled by OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1; stored secrets will not be readable in this process"
            )
            LaunchGuard.markStartupComplete()
        } else if LaunchGuard.isSafeMode {
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

        // Pre-warm caches immediately for instant first window (no async deps).
        // The unified prewarm builds the picker with whatever is currently
        // available; once remote providers finish connecting below they post
        // .remoteProviderModelsChanged and the cache rebuilds automatically.
        _ = SpeechConfigurationStore.load()
        ModelPickerItemCache.shared.prewarm()

        // Bind the local HTTP server before heavier optional startup work such
        // as provider connection, scheduler DB polling, sandbox registration,
        // or Parakeet/CoreML auto-load can occupy the main actor or accelerator.
        let serverStartupTask = Task { @MainActor in
            await serverController.startServer()
        }

        Task.detached(priority: .utility) {
            try? await StorageKeyManager.shared.prewarmCurrentKeyOffCooperativeExecutor()
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
        //
        // The `blockingAwaitReady()` call above already gated the
        // launch flow on the storage migrator, so by the time this
        // Task runs the migrator is guaranteed done. Each
        // `*Database.shared.open()` also calls the gate
        // defensively (no-op fast path) for the plugin/HTTP entry
        // points that don't go through this Task.
        let embeddingInitTask = Task.detached(priority: .utility) {
            guard StorageKeyManager.shared.hasCachedKey else {
                MemoryLogger.database.error(
                    "Storage-dependent search/index services disabled — storage key is not already unlocked"
                )
                return
            }
            var memoryDBOpened = false
            for attempt in 1 ... 3 {
                do {
                    try MemoryDatabase.shared.open()
                    memoryDBOpened = true
                    break
                } catch {
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
            }

            try? MethodDatabase.shared.open()
            await MethodSearchService.shared.initialize()

            try? ToolDatabase.shared.open()
            await ToolSearchService.shared.initialize()

            await SkillSearchService.shared.initialize()

            await ToolIndexService.shared.syncFromRegistry()
            await SkillSearchService.shared.rebuildIndex()
            await MethodSearchService.shared.rebuildIndex()
        }
        // Start activity tracking, drain any pending sessions left over from
        // the previous launch, and arm the periodic consolidator.
        Task { @MainActor in
            await embeddingInitTask.value
            if MemoryDatabase.shared.isOpen {
                ActivityTracker.shared.start()
                await MemoryService.shared.recoverOrphanedSignals()
                await MemoryConsolidator.shared.start()
            }
        }

        // Setup global hotkey for Chat overlay (configured)
        applyChatHotkey()

        // Auto-load speech model if voice features are enabled
        Task { @MainActor in
            await serverStartupTask.value
            await SpeechService.shared.autoLoadIfNeeded()
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

        // Start the self-scheduling loop only if encrypted storage is already
        // unlocked. Startup must not trigger a Keychain/password prompt.
        Task { @MainActor in
            guard StorageKeyManager.shared.hasCachedKey else {
                NSLog("[Osaurus] Scheduler disabled: storage key is not already unlocked")
                return
            }
            NextRunScheduler.shared.start()
        }

        // Start sandbox tool registrar. Internally awaits container
        // auto-start before the initial `registerTools` call, so the first
        // compose for the active agent sees real sandbox tools instead of
        // the placeholder. (Replaces a separate `Task.detached` startContainer
        // call that used to race the registrar's first registration.)
        if !keychainDisabledTestMode {
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
            } else {
                presentInitialWindow()
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
            }
        }
    }

    /// Fire-and-forget launch prewarm. Skipped when the global AI
    /// greetings toggle is off, when no last-active context was ever
    /// recorded (fresh install), or when that agent is no longer in
    /// the store (it was deleted between launches).
    @MainActor
    private func prewarmGreetingPoolIfEnabled() {
        guard AppConfiguration.shared.chatConfig.generativeGreetingsEnabled,
            let last = GenerativeGreetingPool.lastActiveContext(),
            let agent = AgentManager.shared.agents.first(where: { $0.id == last.agentId })
        else { return }
        Task.detached(priority: .utility) { [agent, model = last.model] in
            await GenerativeGreetingPool.shared.warmUp(for: agent, model: model)
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
            ManagementStateManager.shared.voiceSubTabRequest = "TTS"
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
            showOnboardingWindow(forceShowIdentity: true)
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
        Task { @MainActor in
            ChatWindowManager.shared.stopAllSessions()
            BackgroundTaskManager.shared.cancelAllTasks()
            MCPProviderManager.shared.disconnectAll()
            RemoteProviderManager.shared.disconnectAll()
            // Best-effort: drain any debounced memory sessions before
            // MLX / NIO / SQLCipher shutdown so the user doesn't lose
            // pending_signals to the 60s debounce race.
            await MemoryService.shared.flushAllPending(timeoutSeconds: 5)
            // Unconditional: ensureShutdown is idempotent when already clean.
            await serverController.ensureShutdown()
            await MCPServerManager.shared.stopAll()
            await ModelRuntime.shared.clearAll()
            do {
                try await SandboxManager.shared.stopContainer()
            } catch {
                NSLog("[Osaurus] Sandbox stop failed: \(error)")
            }
            // Belt-and-suspenders: if the sandbox was never provisioned,
            // `stopContainer` still stops the bridge, but if the bridge
            // was started through some other path in a future refactor
            // we want its EL group torn down regardless.
            await HostAPIBridgeServer.shared.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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

        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSPopoverDelegate

    public func popoverDidClose(_ notification: Notification) {
        log.debug("Popover closed, posting chatViewClosed notification")
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

    @MainActor public func showOnboardingWindow(forceShowIdentity: Bool = false) {
        closePopoverAndPerform { [weak self] in
            guard let self = self else { return }
            // Reuse existing window if already open (unless forcing full flow)
            if !forceShowIdentity, let existingWindow = Self.onboardingWindow, existingWindow.isVisible {
                existingWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }

            // Close existing window when forcing a fresh flow
            if forceShowIdentity {
                Self.onboardingWindow?.close()
                Self.onboardingWindow = nil
            }

            let themeManager = ThemeManager.shared
            let contentView = OnboardingView(
                forceShowIdentity: forceShowIdentity,
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
        deeplinkAgentId: UUID? = nil
    ) {
        closePopoverAndPerform { [weak self] in
            guard let self = self else { return }
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
                existingWindow.contentViewController = NSHostingController(rootView: root)
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
}
