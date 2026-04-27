//
//  AppDelegate.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import AppKit
import Combine
import QuartzCore
import SwiftUI

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

    public func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

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

        // Wire up the periodic SQLite maintenance ticker (PRAGMA
        // optimize / wal_checkpoint / VACUUM at sensible intervals).
        // Idempotent — safe even if some DBs aren't open yet, the
        // ticker only touches handles that are currently registered.
        Task.detached(priority: .background) {
            await StorageMaintenance.shared.start()
        }

        // vmlx-swift-lm DSV4 cache-mode default. Process-wide env var read
        // by `LLMModelFactory.dispatchDeepseekV4` at model-load time.
        //
        // DSV4-Flash's stock default is `RotatingKVCache(maxSize: 128)` per
        // layer — fine for FIM / short Q&A but loses prompt visibility on
        // any decode > 128 tokens, which means any chat conversation /
        // reasoning-mode trace / multi-turn response drifts off-topic
        // (live-confirmed 2026-04-25 on DSV4-Flash JANGTQ: thinking traces
        // produced random SQL queries because the original prompt scrolled
        // out of attention).
        //
        // Setting `DSV4_KV_MODE=full` switches new caches to `KVCacheSimple`
        // — full attention across the entire prompt + decode. Memory cost
        // ~360 MB at 8K output (vs. ~6 MB rotating), which is a non-issue
        // on any machine that can load DSV4 in the first place (79.5 GB+
        // bundles).
        //
        // No effect on non-DSV4 models — vmlx ignores the var unless the
        // factory dispatch hits the `deepseek_v4` model_type. Setting this
        // unconditionally at launch is the recommended osaurus-side
        // operating point per vmlx
        // `Libraries/MLXLMCommon/BatchEngine/OSAURUS-INTEGRATION.md`
        // §"DeepSeek-V4 — runtime knobs" (2026-04-25 update). Users who
        // want the rotating-window memory savings can override by exporting
        // a different value before launching osaurus.
        if ProcessInfo.processInfo.environment["DSV4_KV_MODE"] == nil {
            setenv("DSV4_KV_MODE", "full", 1)
        }

        // Configure as regular app (show Dock icon) by default, or accessory if hidden
        let hideDockIcon = ServerConfigurationStore.load()?.hideDockIcon ?? false
        if hideDockIcon {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }

        // App has launched
        NSLog("Osaurus server app launched")

        // Configure local notifications
        NotificationService.shared.configureOnLaunch()

        // Set up observers for server state changes
        setupObservers()

        // Set up distributed control listeners (local-only management)
        setupControlNotifications()

        // Apply saved Start at Login preference on launch
        let launchedByCLI = ProcessInfo.processInfo.arguments.contains("--launched-by-cli")
        if !launchedByCLI {
            LoginItemService.shared.applyStartAtLogin(serverController.configuration.startAtLogin)
        }

        // Create status bar item and attach click handler
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

            // Add a small green blinking dot at the bottom-right of the status bar button
            let dot = NSView()
            dot.wantsLayer = true
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.isHidden = true
            button.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -3),
                dot.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -3),
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
            ])
            if let layer = dot.layer {
                layer.backgroundColor = NSColor.systemGreen.cgColor
                layer.cornerRadius = 3.5
                layer.borderWidth = 1
                layer.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
            }
            activityDot = dot

            // Add a VAD status dot at the top-right of the status bar button (blue/purple for VAD listening)
            let vDot = NSView()
            vDot.wantsLayer = true
            vDot.translatesAutoresizingMaskIntoConstraints = false
            vDot.isHidden = true
            button.addSubview(vDot)
            NSLayoutConstraint.activate([
                vDot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -3),
                vDot.topAnchor.constraint(equalTo: button.topAnchor, constant: 3),
                vDot.widthAnchor.constraint(equalToConstant: 7),
                vDot.heightAnchor.constraint(equalToConstant: 7),
            ])
            if let layer = vDot.layer {
                layer.backgroundColor = NSColor.systemBlue.cgColor
                layer.cornerRadius = 3.5
                layer.borderWidth = 1
                layer.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
            }
            vadDot = vDot
        }
        statusItem = item
        updateStatusItemAndMenu()

        // Start main thread watchdog in debug builds to detect UI hangs
        #if DEBUG
            MainThreadWatchdog.shared.start()
        #endif

        // Initialize directory access early so security-scoped bookmark is active
        let _ = DirectoryPickerService.shared

        if LaunchGuard.isSafeMode {
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

        // Auto-connect to enabled providers, then update model cache with remote models
        Task { @MainActor in
            await MCPProviderManager.shared.connectEnabledProviders()
            await RemoteProviderManager.shared.connectEnabledProviders()
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
        let embeddingInitTask = Task {
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

        // Auto-start server on app launch
        Task { @MainActor in
            await serverController.startServer()
        }

        // Setup global hotkey for Chat overlay (configured)
        applyChatHotkey()

        // Auto-load speech model if voice features are enabled
        Task { @MainActor in
            await SpeechService.shared.autoLoadIfNeeded()
        }

        // Initialize VAD service if enabled
        initializeVADService()

        // Setup VAD detection notification listener
        setupVADNotifications()

        // Initialize Transcription Mode service
        initializeTranscriptionModeService()

        // Setup global toast notification system
        ToastWindowController.shared.setup()

        // Setup notch background task indicator
        NotchWindowController.shared.setup()

        // Initialize ScheduleManager to start scheduled tasks
        _ = ScheduleManager.shared

        // Initialize WatcherManager to start file system watchers
        _ = WatcherManager.shared

        // Start sandbox tool registrar. Internally awaits container
        // auto-start before the initial `registerTools` call, so the first
        // compose for the active agent sees real sandbox tools instead of
        // the placeholder. (Replaces a separate `Task.detached` startContainer
        // call that used to race the registrar's first registration.)
        SandboxToolRegistrar.shared.start()

        // Show onboarding for first-time users
        if OnboardingService.shared.shouldShowOnboarding {
            // Slight delay to let the app finish launching
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms
                showOnboardingWindow()
            }
        } else {
            // Fresh launch from terminated state: explicitly activate and show window
            Task { @MainActor in
                // Delay slightly to ensure services are ready
                try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms

                // Ensure app is unhidden and active
                NSApp.unhide(nil)
                if #available(macOS 14.0, *) {
                    _ = NSRunningApplication.current.activate(options: .activateAllWindows)
                } else {
                    _ = NSRunningApplication.current.activate(options: [
                        .activateAllWindows, .activateIgnoringOtherApps,
                    ])
                }

                if ChatWindowManager.shared.windowCount > 0 {
                    ChatWindowManager.shared.focusAllWindows()
                } else if WindowManager.shared.isVisible(.management) {
                    WindowManager.shared.show(.management, center: false)
                } else {
                    showChatOverlay()
                }
            }
        }
    }

    // MARK: - VAD Service

    private func initializeVADService() {
        // Auto-start VAD if enabled (with delay to wait for model loading)
        let vadConfig = VADConfigurationStore.load()
        if vadConfig.vadModeEnabled && !vadConfig.enabledAgentIds.isEmpty {
            Task { @MainActor in
                // Wait for speech model to be loaded (up to 30 seconds)
                let speechService = SpeechService.shared
                var attempts = 0
                while !speechService.isModelLoaded && attempts < 60 {
                    try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms
                    attempts += 1
                }

                if speechService.isModelLoaded {
                    do {
                        try await VADService.shared.start()
                        print("[AppDelegate] VAD service started successfully on app launch")
                    } catch {
                        print("[AppDelegate] Failed to start VAD service: \(error)")
                    }
                } else {
                    print("[AppDelegate] VAD service not started - model not loaded after 30 seconds")
                }
            }
        }
    }

    // MARK: - Transcription Mode Service

    private func initializeTranscriptionModeService() {
        // Initialize the transcription mode service and register hotkey if enabled
        TranscriptionModeService.shared.initialize()
        print("[AppDelegate] Transcription mode service initialized")
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
        print("[AppDelegate] Chat view closed, checking if VAD should resume...")
        Task { @MainActor in
            // Resume VAD if it was paused
            await VADService.shared.resumeAfterChat()
        }
    }

    @objc private func handleCloseChatOverlay(_ notification: Notification) {
        print("[AppDelegate] Close chat overlay requested (silence timeout)")
        Task { @MainActor in
            closeChatOverlay()
        }
    }

    @objc private func handleVADAgentDetected(_ notification: Notification) {
        guard let detection = notification.object as? VADDetectionResult else { return }

        Task { @MainActor in
            print("[AppDelegate] VAD detected agent: \(detection.agentName)")

            // Check if a window for this agent already exists
            let existingWindows = ChatWindowManager.shared.findWindows(byAgentId: detection.agentId)

            let targetWindowId: UUID
            if let existing = existingWindows.first {
                // Focus existing window for this agent
                print("[AppDelegate] Found existing window for agent, focusing...")
                ChatWindowManager.shared.showWindow(id: existing.id)
                targetWindowId = existing.id
            } else {
                // Create a new chat window for the detected agent
                print("[AppDelegate] Creating new chat window for agent...")
                targetWindowId = ChatWindowManager.shared.createWindow(agentId: detection.agentId)
            }

            print(
                "[AppDelegate] VAD target window: \(targetWindowId), window count: \(ChatWindowManager.shared.windowCount)"
            )

            // Pause VAD when handling voice input
            await VADService.shared.pause()

            // Start voice input in chat after a delay (let VAD stop and UI settle)
            let vadConfig = VADConfigurationStore.load()
            if vadConfig.autoStartVoiceInput {
                try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms - fast handoff
                print("[AppDelegate] Triggering voice input in chat for window \(targetWindowId)")
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

            if ChatWindowManager.shared.windowCount > 0 {
                ChatWindowManager.shared.focusAllWindows()
            } else if WindowManager.shared.isVisible(.management) {
                WindowManager.shared.show(.management, center: false)
            } else {
                self.showChatOverlay()
            }
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
    }

    // MARK: Status Item / Menu

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
        print("[AppDelegate] Popover closed, posting chatViewClosed notification")
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
        var desiredPort: Int? = nil
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
        guard let scheme = url.scheme?.lowercased(), scheme == "huggingface" else { return }
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
                alert.messageText = "Unsupported model"
                alert.informativeText = "Osaurus only supports MLX-compatible Hugging Face repositories."
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
            print("[AppDelegate] Creating new chat window via ChatWindowManager...")
            ChatWindowManager.shared.createWindow()

            // start clipboard monitoring and do an immediate check
            ClipboardService.shared.startMonitoring()
            ClipboardService.shared.checkPasteboard()

            // Pause VAD when chat window is shown (like when VAD detects a agent)
            // This allows voice input to work without competing for the microphone
            Task {
                await VADService.shared.pause()
            }

            print("[AppDelegate] Chat window shown, count: \(ChatWindowManager.shared.windowCount)")
            NotificationCenter.default.post(name: .chatOverlayActivated, object: nil)
        }
    }

    /// Show a new chat window for a specific agent (used by VAD)
    @MainActor func showChatOverlay(forAgentId agentId: UUID) {
        closePopoverAndPerform {
            print("[AppDelegate] Creating new chat window for agent \(agentId) via ChatWindowManager...")
            ChatWindowManager.shared.createWindow(agentId: agentId)

            print("[AppDelegate] Chat window shown for agent, count: \(ChatWindowManager.shared.windowCount)")
            NotificationCenter.default.post(name: .chatOverlayActivated, object: nil)
        }
    }

    /// Close the last focused chat overlay (legacy API for backward compatibility)
    @MainActor func closeChatOverlay() {
        if let lastId = ChatWindowManager.shared.lastFocusedWindowId {
            ChatWindowManager.shared.closeWindow(id: lastId)
        }
        print("[AppDelegate] Chat overlay closed via closeChatOverlay")
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
                onPreferredHeightChange: { [weak self] newHeight in
                    self?.resizeOnboardingWindow(toHeight: newHeight)
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
            let windowWidth: CGFloat = OnboardingMetrics.windowWidth
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
    fileprivate func resizeOnboardingWindow(toHeight newHeight: CGFloat) {
        guard let window = Self.onboardingWindow else { return }
        let clamped = min(max(newHeight, OnboardingMetrics.minHeight), OnboardingMetrics.maxHeight)
        let currentFrame = window.frame
        // Skip changes smaller than a couple of points to avoid jitter from
        // SwiftUI re-publishing the same preference during transitions.
        guard abs(currentFrame.height - clamped) > 2 else { return }

        // Anchor by top edge (NSWindow origin is bottom-left, so subtract delta from y).
        let delta = clamped - currentFrame.height
        let newFrame = NSRect(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y - delta,
            width: OnboardingMetrics.windowWidth,
            height: clamped
        )

        // Animate the resize alongside the SwiftUI slide transition. A short
        // ease-in-out feels in sync with the spring used for step navigation.
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
        deeplinkFile: String? = nil
    ) {
        closePopoverAndPerform { [weak self] in
            guard let self = self else { return }
            let windowManager = WindowManager.shared
            let themeManager = ThemeManager.shared
            let root = ManagementView(
                initialTab: initialTab,
                deeplinkModelId: deeplinkModelId,
                deeplinkFile: deeplinkFile
            )
            .environmentObject(self.serverController)
            .environmentObject(self.updater)
            .environment(\.theme, themeManager.currentTheme)

            // Reuse existing window if it exists
            if let existingWindow = windowManager.window(for: .management) {
                existingWindow.contentViewController = NSHostingController(rootView: root)
                windowManager.show(.management, center: false)  // Don't re-center if user moved it
                NSLog("[Management] Reused existing window and brought to front")
                return
            }

            // Create new management window via WindowManager
            let window = windowManager.createWindow(config: .management) {
                root
            }
            window.isReleasedWhenClosed = false

            // Set center to false so the window respects its saved position (via setFrameAutosaveName)
            // instead of being manually centered by the WindowManager on every show.
            windowManager.show(.management, center: false)
            NSLog("[Management] Created new window and presented")
        }
    }
}
