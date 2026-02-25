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

    public func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

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
            button.toolTip = "Osaurus Server"
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

        // Load external tool plugins at launch (after core is initialized)
        Task { @MainActor in
            await PluginManager.shared.loadAll()
        }

        // Pre-warm caches immediately for instant first window (no async deps)
        _ = SpeechConfigurationStore.load()
        ModelOptionsCache.shared.prewarmLocalModelsOnly()

        // Auto-connect to enabled providers, then update model cache with remote models
        Task { @MainActor in
            await MCPProviderManager.shared.connectEnabledProviders()
            await RemoteProviderManager.shared.connectEnabledProviders()
            await ModelOptionsCache.shared.prewarmModelCache()
        }

        // Start plugin repository background refresh for update checking
        PluginRepositoryService.shared.startBackgroundRefresh()

        // Initialize memory system with retry
        Task { @MainActor in
            var opened = false
            for attempt in 1 ... 3 {
                do {
                    try MemoryDatabase.shared.open()
                    opened = true
                    break
                } catch {
                    MemoryLogger.database.error("Memory database open attempt \(attempt)/3 failed: \(error)")
                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                    }
                }
            }
            if opened {
                ActivityTracker.shared.start()
                await MemorySearchService.shared.initialize()
                await MemoryService.shared.recoverOrphanedSignals()
            } else {
                MemoryLogger.database.error("Memory system disabled — database failed to open after 3 attempts")
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

        // Show onboarding for first-time users
        if OnboardingService.shared.shouldShowOnboarding {
            // Slight delay to let the app finish launching
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms
                showOnboardingWindow()
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
                // Focus existing windows
                ChatWindowManager.shared.focusAllWindows()
            } else {
                // No windows exist, create a new one
                self.showChatOverlay()
            }
        }
        return true
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Defer termination so in-flight inference tasks and MLX GPU resources are
        // released before exit() triggers C++ static destructors.
        Task { @MainActor in
            ChatWindowManager.shared.stopAllSessions()
            BackgroundTaskManager.shared.cancelAllTasks()
            if serverController.isRunning {
                await serverController.ensureShutdown()
            }
            await MCPServerManager.shared.stopAll()
            await ModelRuntime.shared.clearAll()
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
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSPopoverDelegate

    public func popoverDidClose(_ notification: Notification) {
        print("[AppDelegate] Popover closed, posting chatViewClosed notification")
        // Post notification so VAD can resume
        NotificationCenter.default.post(name: .chatViewClosed, object: nil)
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
            await PluginManager.shared.loadAll()
        }
    }
}

// MARK: Deep Link Handling
extension AppDelegate {
    func applyChatHotkey() {
        let cfg = ChatConfigurationStore.load()
        HotKeyManager.shared.register(hotkey: cfg.hotkey) { [weak self] in
            Task { @MainActor in
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

// MARK: - Chat Overlay Window
extension AppDelegate {
    @MainActor private func toggleChatOverlay() {
        // Use ChatWindowManager for multi-window support
        ChatWindowManager.shared.toggleLastFocused()

        if ChatWindowManager.shared.hasVisibleWindows {
            // Pause VAD when chat window is shown (like when VAD detects a agent)
            // This allows voice input to work without competing for the microphone
            Task {
                await VADService.shared.pause()
            }
            NotificationCenter.default.post(name: .chatOverlayActivated, object: nil)
        }
    }

    /// Show a new chat window (creates new window via ChatWindowManager)
    @MainActor func showChatOverlay() {
        print("[AppDelegate] Creating new chat window via ChatWindowManager...")
        ChatWindowManager.shared.createWindow()

        // Pause VAD when chat window is shown (like when VAD detects a agent)
        // This allows voice input to work without competing for the microphone
        Task {
            await VADService.shared.pause()
        }

        print("[AppDelegate] Chat window shown, count: \(ChatWindowManager.shared.windowCount)")
        NotificationCenter.default.post(name: .chatOverlayActivated, object: nil)
    }

    /// Show a new chat window for a specific agent (used by VAD)
    @MainActor func showChatOverlay(forAgentId agentId: UUID) {
        print("[AppDelegate] Creating new chat window for agent \(agentId) via ChatWindowManager...")
        ChatWindowManager.shared.createWindow(agentId: agentId)

        print("[AppDelegate] Chat window shown for agent, count: \(ChatWindowManager.shared.windowCount)")
        NotificationCenter.default.post(name: .chatOverlayActivated, object: nil)
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

        Self.acknowledgementsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Onboarding Window
extension AppDelegate {
    private static var onboardingWindow: NSWindow?

    @MainActor public func showOnboardingWindow() {
        // Reuse existing window if already open
        if let existingWindow = Self.onboardingWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let themeManager = ThemeManager.shared
        let contentView = OnboardingView { [weak self] in
            // Close the onboarding window when complete
            Self.onboardingWindow?.close()
            Self.onboardingWindow = nil
            // Invalidate model cache so fresh models are discovered
            // This ensures any models downloaded during onboarding are visible
            ModelOptionsCache.shared.invalidateCache()
            // Open ChatView after onboarding completes
            self?.showChatOverlay()
        }
        .environment(\.theme, themeManager.currentTheme)

        // Use NSHostingView directly in an NSView container to avoid auto-sizing issues
        let windowWidth: CGFloat = 500
        let windowHeight: CGFloat = 560

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

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

        Self.onboardingWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: Management Window
extension AppDelegate {
    @MainActor public func showManagementWindow(
        initialTab: ManagementTab = .models,
        deeplinkModelId: String? = nil,
        deeplinkFile: String? = nil
    ) {
        let windowManager = WindowManager.shared

        let presentWindow: () -> Void = { [weak self] in
            guard let self = self else { return }

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

            windowManager.show(.management)
            NSLog("[Management] Created new window and presented")
        }

        if let pop = popover, pop.isShown {
            pop.performClose(nil)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                presentWindow()
            }
        } else {
            presentWindow()
        }
    }
}
