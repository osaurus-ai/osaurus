//
//  ChatWindowManager.swift
//  osaurus
//
//  Manages multiple chat windows, each representing an independent session.
//  Handles window lifecycle, focus tracking, and VAD routing.
//

import AppKit
import Combine
import SwiftUI

/// Represents an active chat window with its associated session
public struct ChatWindowInfo: Identifiable, Sendable {
    public let id: UUID
    public let agentId: UUID
    public let sessionId: UUID?
    public let createdAt: Date

    public init(id: UUID = UUID(), agentId: UUID, sessionId: UUID? = nil, createdAt: Date = Date()) {
        self.id = id
        self.agentId = agentId
        self.sessionId = sessionId
        self.createdAt = createdAt
    }
}

/// Manages multiple chat windows in the application
@MainActor
public final class ChatWindowManager: NSObject, ObservableObject {
    public static let shared = ChatWindowManager()

    // MARK: - Published State

    /// All active chat windows
    @Published public private(set) var windows: [UUID: ChatWindowInfo] = [:]

    /// The last focused chat window ID (for hotkey toggle)
    @Published public private(set) var lastFocusedWindowId: UUID?

    // MARK: - Private State

    private var nsWindows: [UUID: NSWindow] = [:]
    private var windowDelegates: [UUID: ChatWindowDelegate] = [:]
    private var windowStates: [UUID: ChatWindowState] = [:]
    private var sessionCallbacks: [UUID: () -> Void] = [:]

    /// Sleep/wake observers on `NSWorkspace.shared.notificationCenter`.
    /// Held so we can detach them in `deinit`. Pause the greeting pool
    /// on sleep so a closed laptop doesn't keep firing background
    /// inferences against the GPU.
    nonisolated(unsafe) private var sleepObserver: NSObjectProtocol?
    nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?

    private override init() {
        super.init()
        installSleepWakeObservers()
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        if let token = sleepObserver { nc.removeObserver(token) }
        if let token = wakeObserver { nc.removeObserver(token) }
    }

    /// Hook NSWorkspace's sleep/wake notifications to the pool's
    /// pause/resume seam. Notifications from `NSWorkspace` arrive on
    /// the main thread, but the pool is an actor so we hop through
    /// `Task` to call into it.
    private func installSleepWakeObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        sleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await GenerativeGreetingPool.shared.pause() }
        }
        wakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await GenerativeGreetingPool.shared.resume() }
        }
    }

    // MARK: - Public API

    /// Create a new chat window with default agent
    /// - Parameters:
    ///   - agentId: The agent for this window (defaults to active agent)
    ///   - showImmediately: Whether to show the window immediately (default: true)
    /// - Returns: The window identifier
    @discardableResult
    public func createWindow(agentId: UUID? = nil, showImmediately: Bool = true) -> UUID {
        return createWindowInternal(agentId: agentId, sessionData: nil, showImmediately: showImmediately)
    }

    /// Create a new chat window with existing session data
    /// - Parameters:
    ///   - agentId: The agent for this window (defaults to active agent)
    ///   - sessionData: Optional existing session to load
    ///   - showImmediately: Whether to show the window immediately (default: true)
    /// - Returns: The window identifier
    @discardableResult
    func createWindow(
        agentId: UUID? = nil,
        sessionData: ChatSessionData?,
        showImmediately: Bool = true
    ) -> UUID {
        return createWindowInternal(agentId: agentId, sessionData: sessionData, showImmediately: showImmediately)
    }

    /// Internal implementation for creating windows
    private func createWindowInternal(
        agentId: UUID?,
        sessionData: ChatSessionData?,
        showImmediately: Bool
    ) -> UUID {
        // Reopening a chat the registry is still running: attach the live
        // in-memory session (same `ChatSession` instance, stream keeps
        // rendering) instead of hydrating a stale copy from disk.
        if let sessionId = sessionData?.id,
            let liveTask = BackgroundTaskManager.shared.liveTask(forSessionId: sessionId),
            let context = liveTask.executionContext
        {
            let windowId = createWindowForContext(context, showImmediately: showImmediately)
            BackgroundTaskManager.shared.bindWindow(windowId, toTask: liveTask.id)
            return windowId
        }

        let windowId = UUID()
        let effectiveAgentId = agentId ?? AgentManager.shared.activeAgentId

        let info = ChatWindowInfo(
            id: windowId,
            agentId: effectiveAgentId,
            sessionId: sessionData?.id,
            createdAt: Date()
        )

        windows[windowId] = info

        // Create the actual NSWindow
        let window = createNSWindow(
            windowId: windowId,
            agentId: effectiveAgentId,
            sessionData: sessionData
        )

        nsWindows[windowId] = window

        // Show the window if requested
        if showImmediately {
            showWindow(id: windowId)
        }

        print(
            "[ChatWindowManager] Created window \(windowId) for agent \(effectiveAgentId) (shown: \(showImmediately))"
        )

        return windowId
    }

    /// Warm the Swift generic-metadata and protocol-conformance caches for
    /// `ChatView`'s very deep view tree, once, off the user's first interactive
    /// open.
    ///
    /// The first time a `ChatView`-hosting `NSHostingController` is mounted, the
    /// runtime has to demangle and instantiate metadata for the entire body type
    /// and recursively resolve its conformances — multi-second main-thread CPU on
    /// slower machines (the dominant cost behind the chat-window open hangs). That
    /// realization is process-global, so paying it here against a throwaway
    /// controller means the first real window the user opens reuses warmed caches
    /// instead of stalling on screen. No window is registered or shown, so this
    /// stays out of the `windowCount`-based launch/cascade logic.
    private var didPrewarmChatView = false
    func prewarmChatView() {
        guard !didPrewarmChatView else { return }
        // A live chat window already paid (and warmed) this cost.
        guard windowCount == 0 else { return }
        // Constructing ChatWindowState pulls up ChatSessionsManager, which opens the
        // chat store and needs the storage key. If the launch-time key prewarm is still
        // stuck inside a slow Keychain read, that lookup would park the main thread
        // behind it, so only prewarm once the key is already resident. Skipping is
        // safe: the first real window pays the realization cost on demand instead.
        guard StorageKeyManager.shared.isStorageReadyForWrites else { return }
        didPrewarmChatView = true

        // Wrap the throwaway view tree in an autorelease pool so its teardown
        // — including SwiftUI's `dismantleNSView` (which clears the prewarmed
        // message table's hover closures) and the release of every cell's
        // tracking areas — is drained deterministically when this call
        // returns, instead of deferring to a later pool drain during the
        // sensitive launch window where the tracking-area SIGABRT was seen
        // (issue #1632).
        autoreleasepool {
            let windowState = ChatWindowState(
                windowId: UUID(),
                agentId: AgentManager.shared.activeAgentId
            )
            let chatView = ChatView(windowState: windowState)
                .environment(\.theme, windowState.theme)
            let hostingController = NSHostingController(rootView: chatView)
            // Forcing layout evaluates the SwiftUI body once, which realizes
            // the metadata. The controller is never attached to a visible
            // window, so `onAppear` / `task` side effects don't fire.
            hostingController.view.layoutSubtreeIfNeeded()

            // Tear the throwaway state down so its session/observers don't
            // linger; `deinit` removes the notification observers as it
            // deallocates.
            windowState.cleanup()
        }
        print("[ChatWindowManager] Prewarmed ChatView metadata")
    }

    /// Stop all active sessions (chat and work) across all windows.
    /// Called during app termination to prevent crashes from in-flight inference.
    public func stopAllSessions() {
        for (_, state) in windowStates {
            state.cleanup()
        }
    }

    /// Close a chat window by ID. Closing never stops execution: a mid-run
    /// session is auto-detached into the `BackgroundTaskManager` registry by
    /// `windowWillClose`, so there is no confirmation gate.
    public func closeWindow(id: UUID) {
        guard let window = nsWindows[id] else {
            print("[ChatWindowManager] No window found for ID \(id)")
            return
        }

        // Close will trigger the delegate which handles cleanup
        window.close()
    }

    /// Show/focus a window by ID
    public func showWindow(id: UUID) {
        guard let window = nsWindows[id] else {
            print("[ChatWindowManager] No window found for ID \(id)")
            return
        }

        // Unhide app if hidden
        NSApp.unhide(nil)

        // Deminiaturize if needed
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        // Activate app and bring this specific window forward
        if #available(macOS 14.0, *) {
            _ = NSRunningApplication.current.activate(options: .activateAllWindows)
        } else {
            _ = NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
        }
        NSApp.activate(ignoringOtherApps: true)

        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)

        // Update last focused
        lastFocusedWindowId = id

        // One-shot activation signal, armed by onboarding completion. Firing
        // here (the only place chat windows become visible) rather than in
        // the onboarding completion handler means it reports the window
        // actually on screen, and still fires on a later launch if the user
        // quit before the post-onboarding window opened.
        FeatureTelemetry.firstTimeChatShown()
    }

    /// Hide a window by ID
    public func hideWindow(id: UUID) {
        guard let window = nsWindows[id] else { return }
        // Drop any cached AI-generated empty-state content so re-opening
        // the window pops a fresh entry from `GenerativeGreetingPool`
        // instead of flashing the previous session's greeting before
        // the trigger replaces it. Idempotent — clearing an already
        // `.idle` session is a no-op.
        if let state = windowStates[id] {
            state.session.resetGenerativeGreeting()
        }
        // Tell the pool the user no longer has THIS window's agent on
        // screen so the 5-min ticker stops topping up its cache. The
        // pool scopes the clear to the matching agent so a second
        // visible window for a different agent keeps its active
        // pointer; same-agent multi-window is rare enough that any
        // residual over-clearing is recovered on the next empty-state
        // appearance via `setActive`.
        if let info = windows[id] {
            let agentId = info.agentId
            Task { await GenerativeGreetingPool.shared.clearActive(agentId: agentId) }
        }
        window.orderOut(nil)
        print("[ChatWindowManager] Hid window \(id)")
    }

    /// Toggle the last focused window (or create new if none exist)
    public func toggleLastFocused() {
        if let lastId = lastFocusedWindowId, let window = nsWindows[lastId] {
            // smart toggle: only hide if the window is already visible, frontmost, and the app is active
            // otherwise, toggling should just bring it to the front
            let isFrontmost = window.isVisible && window.isKeyWindow && NSApp.isActive

            if isFrontmost {
                hideWindow(id: lastId)
            } else {
                showWindow(id: lastId)
            }
        } else if let firstId = windows.keys.first {
            // No last focused, show first available
            showWindow(id: firstId)
        } else {
            // No windows exist, create new one
            createWindow()
        }
    }

    /// Open (or focus) a chat window and select the paired remote agent that
    /// owns `providerId`, so the conversation routes to that agent instead of
    /// whatever the window was last pointed at. Mirrors the toolbar's
    /// relay-agent picker: we resolve the matching `PairedRelayAgent` from the
    /// target window's state and post `.chatToolbarSelectRelayAgent`, which the
    /// window's `ChatView` turns into a real connect via `connectToRelayAgent`.
    public func openChat(withRemoteAgentProviderId providerId: UUID) {
        let targetId: UUID
        let isNewWindow: Bool
        if let lastId = lastFocusedWindowId, windowStates[lastId] != nil {
            targetId = lastId
            isNewWindow = false
            showWindow(id: lastId)
        } else if let firstId = windowStates.keys.first {
            targetId = firstId
            isNewWindow = false
            showWindow(id: firstId)
        } else {
            targetId = createWindow()
            isNewWindow = true
        }

        guard let state = windowStates[targetId] else { return }
        // Refresh so the relay list reflects the latest paired providers before
        // we look up the target agent (e.g. just-paired agents).
        state.refreshPairedRelayAgents()
        guard let relay = state.pairedRelayAgents.first(where: { $0.providerId == providerId })
        else { return }

        // A freshly-created window's `ChatView` registers its
        // `.chatToolbarSelectRelayAgent` listener a runloop turn or two after
        // creation, so delay the post for new windows. Existing windows are
        // already listening, so dispatch on the next tick is enough.
        let delay: TimeInterval = isNewWindow ? 0.35 : 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NotificationCenter.default.post(
                name: .chatToolbarSelectRelayAgent,
                object: relay,
                userInfo: ["windowId": targetId]
            )
        }
    }

    /// Find windows by agent ID
    public func findWindows(byAgentId agentId: UUID) -> [ChatWindowInfo] {
        windows.values.filter { $0.agentId == agentId }
    }

    /// Find a window by session ID. Consults the live per-window state
    /// (sessions are replaceable — a window can switch chats after
    /// creation), falling back to the creation-time info for windows whose
    /// state hasn't been registered yet.
    public func findWindow(bySessionId sessionId: UUID) -> ChatWindowInfo? {
        if let (windowId, _) = windowStates.first(where: { $0.value.session.sessionId == sessionId }) {
            return windows[windowId]
        }
        return windows.values.first { $0.sessionId == sessionId }
    }

    /// Check if any windows are visible
    public var hasVisibleWindows: Bool {
        nsWindows.values.contains { $0.isVisible }
    }

    /// True when any open chat session — or any active registry-owned
    /// background run — is currently streaming a model response. Read by
    /// `GenerativeGreetingPool` to defer background refills while a turn is
    /// in flight — both calls share the same MLX context and unboxing them
    /// concurrently degrades token-per-second on the user's active
    /// conversation. Detached runs count too: their stream is just as
    /// sensitive to contention as a windowed one.
    public var isAnySessionStreaming: Bool {
        windowStates.values.contains { $0.session.isStreaming }
            || BackgroundTaskManager.shared.activeTaskSessions().contains { $0.isStreaming }
    }

    /// True while any chat window has a blocking in-chat prompt (secret or
    /// clarify card) mounted. Surfaces the otherwise-private per-window
    /// `promptQueue` state so app-level announcement dialogs (e.g. the
    /// Product Hunt launch dialog) can defer instead of stacking on top of
    /// a deliberate pause that's waiting on the user.
    public var hasAnyBlockingPromptOverlay: Bool {
        windowStates.values.contains { $0.session.promptQueue.current != nil }
    }

    /// True when a chat window OTHER than `excluding` is currently streaming a
    /// local model, or a detached registry task is. Enforces one local
    /// generation at a time across windows AND background runs: the shared
    /// inference context can only run one, and loading a second would evict
    /// the first and cancel its in-flight stream.
    func isOtherWindowStreamingLocalModel(excluding windowId: UUID?) -> Bool {
        let excludedSession = windowId.flatMap { windowStates[$0]?.session }
        return windowStates.contains { id, state in
            id != windowId && state.session.isStreamingLocalModel
        }
            || BackgroundTaskManager.shared.isAnyDetachedTaskStreamingLocalModel(
                excludingSession: excludedSession
            )
    }

    /// True when ANY chat window or detached registry task is currently
    /// streaming a local model. Used to defer local empty-state greeting
    /// generation while a user stream is in flight.
    var isAnyWindowStreamingLocalModel: Bool {
        windowStates.values.contains { $0.session.isStreamingLocalModel }
            || BackgroundTaskManager.shared.isAnyDetachedTaskStreamingLocalModel()
    }

    /// Get the count of active windows
    public var windowCount: Int {
        windows.count
    }

    /// Check if a specific window exists
    public func windowExists(id: UUID) -> Bool {
        windows[id] != nil
    }

    /// Get the NSWindow for a specific window ID (for event matching)
    public func getNSWindow(id: UUID) -> NSWindow? {
        nsWindows[id]
    }

    /// Reverse lookup: the window id that owns a given NSWindow, if it's a
    /// chat window. Lets AppKit views deep inside the chat hierarchy resolve
    /// their own window id (e.g. to scope a ThemedAlert to this chat window)
    /// without threading it down through the view tree.
    public func windowId(for window: NSWindow) -> UUID? {
        nsWindows.first(where: { $0.value === window })?.key
    }

    /// Get window info by ID
    public func windowInfo(id: UUID) -> ChatWindowInfo? {
        windows[id]
    }

    /// Get the window state for a specific window (for accessing session/agent)
    func windowState(id: UUID) -> ChatWindowState? {
        windowStates[id]
    }

    /// Returns the set of local model names selected by currently-open chat
    /// windows plus any active registry-owned (detached) background tasks.
    /// Used as a "keep loaded for next interaction" hint for GC.
    ///
    /// Safety against unloading a model mid-stream is enforced by `ModelLease`
    /// inside `ModelRuntime.unloadModelsNotIn` — this set only needs to cover
    /// the UX heuristic of "the user still has a window (or live background
    /// run) with this model selected, don't pay reload cost on their next
    /// keystroke".
    func activeLocalModelNames() -> Set<String> {
        let windowSessions = windowStates.values.map { $0.session }
        let detachedSessions = BackgroundTaskManager.shared.activeTaskSessions()
        return Set(
            (windowSessions + detachedSessions).compactMap { session in
                guard let model = session.selectedModel,
                    // Cache-only: runs on the main actor; a cold-cache miss
                    // just means the model can't be resident yet anyway.
                    let found = ModelManager.findInstalledModelFromCache(named: model)
                else { return nil }
                return found.name
            }
        )
    }

    /// Set a callback to be invoked when window is about to close (for session saving)
    public func setCloseCallback(for windowId: UUID, callback: @escaping () -> Void) {
        sessionCallbacks[windowId] = callback
    }

    /// Sync a window's native full-screen state into its `ChatWindowState`
    /// so the content can swap the NSToolbar for the themed in-content header.
    fileprivate func windowFullScreenChanged(id: UUID, isFullScreen: Bool) {
        windowStates[id]?.isFullScreen = isFullScreen
    }

    /// Set window pinned (float on top) state
    public func setWindowPinned(id: UUID, pinned: Bool) {
        guard let window = nsWindows[id] else { return }
        window.level = pinned ? .floating : .normal
        print("[ChatWindowManager] Window \(id) pinned: \(pinned)")
    }

    /// Focus all existing windows (for dock icon click)
    public func focusAllWindows() {
        guard !windows.isEmpty else { return }

        NSApp.unhide(nil)
        _ = NSRunningApplication.current.activate(options: [.activateAllWindows])

        // Bring all windows to front without churn on key window state
        for (_, window) in nsWindows {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.orderFrontRegardless()
        }

        // Make the intended window key once
        if let lastId = lastFocusedWindowId, let window = nsWindows[lastId] {
            window.makeKeyAndOrderFront(nil)
        } else if let firstWindow = nsWindows.values.first {
            firstWindow.makeKeyAndOrderFront(nil)
        }

        print("[ChatWindowManager] Focused all \(windows.count) windows")
    }

    // MARK: - Background Task Window Support

    /// Lazily create a window from an `ExecutionContext`, reusing its sessions.
    /// Called when the user taps "View" on a dispatch toast.
    @discardableResult
    public func createWindowForContext(
        _ context: ExecutionContext,
        showImmediately: Bool = true
    ) -> UUID {
        let windowId = UUID()
        let windowState = ChatWindowState(windowId: windowId, executionContext: context)

        windows[windowId] = ChatWindowInfo(
            id: windowId,
            agentId: context.agentId,
            createdAt: Date()
        )

        let window = createNSWindowForBackgroundTask(windowId: windowId, windowState: windowState)
        nsWindows[windowId] = window
        windowStates[windowId] = windowState

        if showImmediately { showWindow(id: windowId) }

        print("[ChatWindowManager] Created window \(windowId) for context \(context.id)")
        return windowId
    }

    /// Create an NSWindow for viewing a background task (reuses existing window state)
    private func createNSWindowForBackgroundTask(
        windowId: UUID,
        windowState: ChatWindowState
    ) -> NSWindow {
        let hostingController = NSHostingController(
            rootView: ChatWindowRootView(windowState: windowState)
        )

        let panel = createChatPanel(windowId: windowId, windowState: windowState)
        panel.contentViewController = hostingController

        applyWindowFramePersistence(panel: panel)

        return panel
    }

    // MARK: - Private Helpers

    private func createNSWindow(
        windowId: UUID,
        agentId: UUID,
        sessionData: ChatSessionData?
    ) -> NSWindow {
        // Create per-window state container (isolates from shared singletons)
        let windowState = ChatWindowState(
            windowId: windowId,
            agentId: agentId,
            sessionData: sessionData
        )
        windowStates[windowId] = windowState

        let hostingController = NSHostingController(
            rootView: ChatWindowRootView(windowState: windowState)
        )

        let panel = createChatPanel(windowId: windowId, windowState: windowState)
        panel.contentViewController = hostingController

        applyWindowFramePersistence(panel: panel)

        return panel
    }

    /// Shared logic for creating the basic ChatPanel with its toolbar and delegate.
    private func createChatPanel(windowId: UUID, windowState: ChatWindowState) -> ChatPanel {
        // Calculate centered position on active screen, with offset for multiple windows
        let defaultSize = NSSize(width: 800, height: 610)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main

        // Cascade offset based on number of existing windows (25pt per window)
        // Use count - 1 so the first window starts at the base position
        let cascadeOffset = CGFloat(max(0, windows.count - 1)) * 25.0

        let initialRect: NSRect
        if let s = screen {
            let vf = s.visibleFrame
            let baseOrigin = NSPoint(
                x: vf.midX - defaultSize.width / 2,
                y: vf.midY - defaultSize.height / 2
            )
            var origin = NSPoint(
                x: baseOrigin.x + cascadeOffset,
                y: baseOrigin.y - cascadeOffset
            )
            if origin.x + defaultSize.width > vf.maxX {
                origin.x = vf.minX + 50
            }
            if origin.y < vf.minY {
                origin.y = vf.maxY - defaultSize.height - 50
            }
            initialRect = NSRect(origin: origin, size: defaultSize)
        } else {
            initialRect = NSRect(origin: .zero, size: defaultSize)
        }

        let panel = ChatPanel(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = true
        // Use the theme's background rather than the system color: in native
        // full screen the content view no longer extends under the toolbar,
        // so the titlebar strip exposes the window background directly.
        panel.backgroundColor = NSColor(windowState.theme.primaryBackground)
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.isReleasedWhenClosed = false
        // No AppKit snapshot restoration. Frame autosave (below, via
        // `applyWindowFramePersistence`) handles position persistence.
        panel.isRestorable = false
        panel.collectionBehavior = [.fullScreenPrimary, .managed]

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // No hairline under the toolbar in full screen, where the transparent
        // titlebar look otherwise breaks down.
        panel.titlebarSeparatorStyle = .none
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.appearance = NSAppearance(named: windowState.theme.isDark ? .darkAqua : .aqua)

        let toolbar = NSToolbar(identifier: "ChatToolbar")
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        // Anchor the agent pill at the toolbar's geometric center; without
        // this it drifts off-axis because of the asymmetric leading/trailing
        // items and the traffic-light area.
        toolbar.centeredItemIdentifier = ChatToolbarDelegate.agentItem

        let toolbarDelegate = ChatToolbarDelegate(windowState: windowState)
        toolbar.delegate = toolbarDelegate
        panel.chatToolbarDelegate = toolbarDelegate
        panel.toolbar = toolbar
        panel.toolbarStyle = .unified

        // Set up delegate for lifecycle events
        let delegate = ChatWindowDelegate(windowId: windowId, manager: self)
        windowDelegates[windowId] = delegate
        panel.delegate = delegate

        return panel
    }

    /// Common method for window frame persistence and cascading.
    private func applyWindowFramePersistence(panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let cascadeOffset = CGFloat(max(0, windows.count - 1)) * 25.0

        // Try to load saved frame for ALL windows to get the user's preferred size
        _ = panel.setFrameUsingName(WindowFrameAutosaveKey.chat.rawValue)

        if windows.count > 1 {
            // Recalculate origin for subsequent windows in case the size changed from default
            let currentSize = panel.frame.size
            if let s = screen {
                let vf = s.visibleFrame
                let baseOrigin = NSPoint(
                    x: vf.midX - currentSize.width / 2,
                    y: vf.midY - currentSize.height / 2
                )
                var origin = NSPoint(
                    x: baseOrigin.x + cascadeOffset,
                    y: baseOrigin.y - cascadeOffset
                )
                if origin.x + currentSize.width > vf.maxX {
                    origin.x = vf.minX + 50
                }
                if origin.y < vf.minY {
                    origin.y = vf.maxY - currentSize.height - 50
                }
                panel.setFrameOrigin(origin)
            }
        }

        // Only the first window will save its changes back to the slot
        if windows.count == 1 {
            panel.setFrameAutosaveName(WindowFrameAutosaveKey.chat.rawValue)
        }
    }

    // Called by delegate when window becomes key
    fileprivate func windowDidBecomeKey(id: UUID) {
        lastFocusedWindowId = id
        // Distinguishes "user was in a chat window" from a management tab when
        // localizing a layout-engine app hang (no first-party frame in stack).
        CrashReportingService.recordBreadcrumb(category: "navigation", message: "chat.window focused")
        print("[ChatWindowManager] Window \(id) became key")
    }

    // Called by delegate to determine if window should close (for Cmd+W, etc.)
    // Always true: closing a window only detaches the view — a mid-run
    // session is handed to the BackgroundTaskManager registry below.
    fileprivate func windowShouldClose(id: UUID) -> Bool {
        return true
    }

    // Called by delegate when window will close
    fileprivate func windowWillClose(id: UUID) {
        print("[ChatWindowManager] Window \(id) will close")

        // A window closing over a live run automatically detaches the
        // session into the registry (execution continues; progress surfaces
        // in the notch). No-op when idle or when the session is already
        // registry-owned.
        BackgroundTaskManager.shared.detachChatWindow(windowId: id)

        let isDetachedToBackground = BackgroundTaskManager.shared.isWindowDetachedToBackground(windowId: id)

        // Only invoke save callback and cleanup if NOT detached to background
        // (background task needs the session to keep running)
        if !isDetachedToBackground {
            if let callback = sessionCallbacks[id] {
                callback()
            }
            windowStates[id]?.cleanup()
        } else if let state = windowStates[id] {
            // The run survives the window: break only the view links so the
            // detached session can't push alerts or sidebar refreshes into a
            // dead window state. Execution is untouched.
            if state.session.windowState === state {
                state.session.windowState = nil
            }
            state.session.onSessionChanged = nil
        }

        // Clean up all local references. BackgroundTaskState independently retains
        // the ChatSession/ExecutionContext it needs, so removing it here is always safe.
        sessionCallbacks.removeValue(forKey: id)
        windowDelegates.removeValue(forKey: id)
        windowStates.removeValue(forKey: id)

        let closedSessionId = windows[id]?.sessionId
        let closedAgentId = windows[id]?.agentId
        Task {
            if let sid = closedSessionId {
                PluginHostContext.invalidateSessionToolCache(sessionId: sid.uuidString)
            }
            if let aid = closedAgentId {
                // Drop any 10-second-TTL memory context snapshot so a freshly
                // opened window for the same agent rebuilds from current state.
                // Without this, a user who edits memory in window B and closes
                // window A could briefly see the stale A-era assembly on the
                // next compose pass.
                await MemoryContextAssembler.shared.invalidateCache(agentId: aid.uuidString)
            }
            // Residency on window close (note: hotkey HIDE is not close — a
            // hidden window keeps its model warm for the quick-toggle flow):
            // - .immediately: unload anything no remaining window references.
            // - .afterSeconds: evict chat-sourced models immediately (zero
            //   grace) instead of waiting out the policy, so a closed chat
            //   doesn't pin gigabytes of unified memory. Models last used by
            //   the HTTP API keep their full residency; the fire-time guard
            //   re-checks lease count and open windows, so an in-flight
            //   generation or an instant reopen keeps the model warm.
            // - .never: explicit user opt-in to permanent residency.
            let idlePolicy =
                ServerConfigurationStore.load()?.modelIdleResidencyPolicy
                ?? ServerConfiguration.default.modelIdleResidencyPolicy
            switch idlePolicy {
            case .immediately:
                let active = self.activeLocalModelNames()
                await ModelRuntime.shared.unloadModelsNotIn(active)
            case .afterSeconds:
                let active = self.activeLocalModelNames()
                await ModelRuntime.shared.accelerateIdleUnloadAfterChatClose(
                    keeping: active,
                    isModelStillWanted: { name in
                        await MainActor.run {
                            ChatWindowManager.shared.activeLocalModelNames().contains(name)
                        }
                    }
                )
            case .never:
                break
            }
        }

        // Sever NSWindow -> NSHostingController link so the SwiftUI view tree
        // and its @State storage are released even if the panel lingers briefly.
        nsWindows[id]?.contentViewController = nil
        nsWindows.removeValue(forKey: id)
        windows.removeValue(forKey: id)

        // Update last focused if this was the focused window
        if lastFocusedWindowId == id {
            lastFocusedWindowId = windows.keys.first
        }

        // Post notification for VAD resume
        NotificationCenter.default.post(name: .chatViewClosed, object: id)

        // Now that no view shows the task, drop the window→task binding so
        // the still-running work (and its eventual completion/failure)
        // surfaces in the notch/toast.
        BackgroundTaskManager.shared.unbindWindow(id)

        let msg = isDetachedToBackground ? " (detached to background)" : ""
        print("[ChatWindowManager] Window \(id) cleanup complete\(msg), remaining: \(windows.count)")
    }
}

// MARK: - Window Root View

/// Hosting-root wrapper that rebuilds `ChatView` whenever the window's
/// `session` is swapped out (chat switch while a run keeps executing in the
/// registry, or re-attaching a live background session). `ChatView` binds
/// `@ObservedObject` to the session captured at struct construction, so it
/// must be reconstructed — and `.id` keyed on session identity resets its
/// per-conversation `@State` (scroll position, editing, find matches) the
/// same way a fresh window would.
private struct ChatWindowRootView: View {
    @ObservedObject var windowState: ChatWindowState

    var body: some View {
        VStack(spacing: 0) {
            if windowState.isFullScreen {
                ChatFullScreenHeaderView(windowState: windowState)
            }
            ChatView(windowState: windowState)
                .id(ObjectIdentifier(windowState.session))
        }
        .environment(\.theme, windowState.theme)
    }
}

/// Themed replacement for the NSToolbar while in native full screen, where
/// AppKit's toolbar backdrop can't be themed. Mirrors the toolbar layout:
/// sidebar toggle leading, agent pill centered, action + pin trailing.
private struct ChatFullScreenHeaderView: View {
    @ObservedObject var windowState: ChatWindowState

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                ChatToolbarSidebarView(windowState: windowState)
                Spacer()
                ChatToolbarActionView(windowState: windowState)
                ChatToolbarPinView(windowState: windowState)
            }
            ChatToolbarAgentView(windowState: windowState)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(windowState.theme.primaryBackground)
    }
}

// MARK: - Chat Panel

/// Custom panel that keeps native traffic lights and hosts a unified toolbar.
private final class ChatPanel: NSPanel {
    /// Keep toolbar delegate alive (NSToolbar's delegate is weak).
    var chatToolbarDelegate: ChatToolbarDelegate?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Chat Toolbar

/// Toolbar delegate that places each control in its own `NSToolbarItem`
/// so macOS applies native per-item styling (pill backgrounds, spacing).
@MainActor
private final class ChatToolbarDelegate: NSObject, NSToolbarDelegate {
    fileprivate static let sidebarItem = NSToolbarItem.Identifier("ChatToolbar.sidebar")
    fileprivate static let agentItem = NSToolbarItem.Identifier("ChatToolbar.agent")
    fileprivate static let actionItem = NSToolbarItem.Identifier("ChatToolbar.action")
    fileprivate static let pinItem = NSToolbarItem.Identifier("ChatToolbar.pin")

    /// Layout: sidebar on the leading edge, agent pill centered (via the
    /// toolbar's `centeredItemIdentifier`), action + pin on the trailing edge.
    /// The flexible spaces let the trailing items hug the right edge.
    /// Any stale identifiers AppKit may have persisted in user defaults
    /// fall through to `default: nil` in `itemForItemIdentifier`, which
    /// renders them as no-ops rather than crashing.
    private static let itemIdentifiers: [NSToolbarItem.Identifier] = [
        sidebarItem, .flexibleSpace, agentItem, .flexibleSpace, actionItem, pinItem,
    ]

    private weak var windowState: ChatWindowState?

    init(windowState: ChatWindowState) {
        self.windowState = windowState
        super.init()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.itemIdentifiers
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.itemIdentifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let windowState else { return nil }

        switch itemIdentifier {
        case Self.sidebarItem:
            return makeHostingItem(
                identifier: itemIdentifier,
                rootView:
                    ChatToolbarSidebarView(windowState: windowState)
            )

        case Self.agentItem:
            return makeHostingItem(
                identifier: itemIdentifier,
                rootView:
                    ChatToolbarAgentView(windowState: windowState)
            )

        case Self.actionItem:
            return makeHostingItem(
                identifier: itemIdentifier,
                rootView:
                    ChatToolbarActionView(windowState: windowState)
            )

        case Self.pinItem:
            return makeHostingItem(
                identifier: itemIdentifier,
                rootView:
                    ChatToolbarPinView(windowState: windowState)
            )

        default:
            return nil
        }
    }

    private func makeHostingItem<Content: View>(
        identifier: NSToolbarItem.Identifier,
        rootView: Content
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        item.view = hostingView
        if #available(macOS 13.0, *) {
            item.isBordered = false
        }
        return item
    }
}

// MARK: - Toolbar Item Views

/// Sidebar toggle button.
private struct ChatToolbarSidebarView: View {
    @ObservedObject var windowState: ChatWindowState

    var body: some View {
        HeaderActionButton(
            icon: "sidebar.left",
            help: windowState.showSidebar ? "Hide sidebar" : "Show sidebar",
            action: {
                withAnimation(windowState.theme.animationQuick()) {
                    windowState.showSidebar.toggle()
                }
            }
        )
        .environment(\.theme, windowState.theme)
    }
}

/// Agent selector pill that lives in the toolbar's centered slot.
private struct ChatToolbarAgentView: View {
    @ObservedObject var windowState: ChatWindowState

    /// Incremented by the `/agent` slash command notification to pop the
    /// agent picker open from the input card.
    @State private var openPickerTrigger: Int = 0

    var body: some View {
        AgentPill(
            agents: windowState.agents,
            activeAgentId: windowState.agentId,
            onSelectAgent: { newAgentId in
                windowState.switchAgent(to: newAgentId)
            },
            discoveredAgents: windowState.discoveredAgents,
            onSelectDiscoveredAgent: { agent in
                NotificationCenter.default.post(
                    name: .chatToolbarSelectDiscoveredAgent,
                    object: agent,
                    userInfo: ["windowId": windowState.windowId]
                )
            },
            activeDiscoveredAgent: windowState.selectedDiscoveredAgent,
            pairedRelayAgents: windowState.pairedRelayAgents,
            onSelectRelayAgent: { relay in
                NotificationCenter.default.post(
                    name: .chatToolbarSelectRelayAgent,
                    object: relay,
                    userInfo: ["windowId": windowState.windowId]
                )
            },
            activeRelayAgent: windowState.selectedRelayAgent,
            activeRemoteAgentAvatar: windowState.pinnedRemoteAgentAvatar,
            onOpenActiveAgentSettings: { openActiveAgentSettings() },
            onOpenRemoteAgentSettings: { openRemoteAgentSettings() },
            openPickerTrigger: openPickerTrigger
        )
        .environment(\.theme, windowState.theme)
        .onReceive(NotificationCenter.default.publisher(for: .chatToolbarOpenAgentPicker)) { notification in
            guard let targetWindowId = notification.userInfo?["windowId"] as? UUID,
                targetWindowId == windowState.windowId
            else { return }
            openPickerTrigger &+= 1
        }
    }

    /// Deep-link the management window to the active local agent's config.
    /// Built-in agents have no editable record, so they open the Agents tab
    /// without a selection.
    private func openActiveAgentSettings() {
        let active = windowState.agents.first { $0.id == windowState.agentId }
        let deeplinkId = (active?.isBuiltIn == false) ? active?.id : nil
        AppDelegate.shared?.showManagementWindow(
            initialTab: .agents,
            deeplinkAgentId: deeplinkId
        )
    }

    /// Deep-link the management window to the active remote agent's detail view.
    /// Resolves the chat's remote target → persisted `RemoteAgent` id; ephemeral
    /// peers with no record fall back to the Agents tab.
    private func openRemoteAgentSettings() {
        let remoteId = windowState.selectedDiscoveredAgentProviderId.flatMap {
            RemoteAgentManager.shared.remoteAgentDetailId(forProviderId: $0)
        }
        AppDelegate.shared?.showManagementWindow(
            initialTab: .agents,
            deeplinkRemoteAgentId: remoteId
        )
    }
}

extension Notification.Name {
    static let chatToolbarSelectDiscoveredAgent = Notification.Name("chatToolbarSelectDiscoveredAgent")
    static let chatToolbarSelectRelayAgent = Notification.Name("chatToolbarSelectRelayAgent")
    /// Posted by the `/agent` slash command to pop open the toolbar's agent
    /// picker for the window identified in `userInfo["windowId"]`.
    static let chatToolbarOpenAgentPicker = Notification.Name("chatToolbarOpenAgentPicker")
}

/// Contextual action button: new-chat plus once a conversation exists.
/// Split into an outer view (observing `windowState`, which republishes when
/// the window's session is replaced) and an inner content view holding the
/// `@ObservedObject` session, so the button tracks the CURRENT session's
/// turns after a chat switch instead of a stale instance.
private struct ChatToolbarActionView: View {
    @ObservedObject var windowState: ChatWindowState

    var body: some View {
        ChatToolbarActionContent(windowState: windowState, session: windowState.session)
    }
}

private struct ChatToolbarActionContent: View {
    // Must observe windowState directly: with a plain `let`, SwiftUI sees the
    // unchanged object reference and skips this view's body when only a
    // published property (e.g. `sandboxChangesCount` after an undo) changed —
    // the outer ChatToolbarActionView re-rendering is not enough.
    @ObservedObject var windowState: ChatWindowState
    @ObservedObject var session: ChatSession

    var body: some View {
        HStack(spacing: 0) {
            // Sandbox "Changes" entrypoint: only when the current chat has
            // tracked workspace changes, and never for remote-agent chats
            // (those run on another machine's sandbox).
            if windowState.sandboxChangesCount > 0,
                windowState.selectedDiscoveredAgentProviderId == nil
            {
                ChatToolbarChangesButton(
                    count: windowState.sandboxChangesCount,
                    action: { windowState.isChangesSheetPresented = true }
                )
            }
            if !session.turns.isEmpty {
                HeaderActionButton(
                    icon: "plus",
                    help: "New chat",
                    action: { windowState.startNewChat() }
                )
            }
        }
        .environment(\.theme, windowState.theme)
    }
}

/// Compact icon + count pill for the chat toolbar that opens the
/// session-scoped sandbox Changes sheet. Neutral chip colors (secondary text
/// on a tertiary capsule) so it sits quietly beside the `HeaderActionButton`s,
/// warming to accent on hover like they do.
private struct ChatToolbarChangesButton: View {
    let count: Int
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)
            .frame(height: 28)
            .padding(.horizontal, 9)
            .background(
                Capsule().fill(theme.tertiaryBackground.opacity(isHovered ? 1 : 0.7))
            )
            .overlay(
                Capsule().stroke(theme.primaryBorder.opacity(0.4), lineWidth: 1)
            )
            // The plus and pin buttons live in separate NSToolbarItems, so
            // AppKit adds ~8pt of inter-item spacing between them on top of
            // their built-in 4pt paddings (~16pt visual gap). The badge sits
            // in the same item as the plus, so it must supply that spacing
            // itself: 12pt here + the plus's own 4pt ≈ the same 16pt gap.
            .padding(.trailing, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .help(Text(LocalizedStringKey("File changes"), bundle: .module))
    }
}

/// Pin button. Observes windowState for reactive theme updates.
private struct ChatToolbarPinView: View {
    @ObservedObject var windowState: ChatWindowState

    var body: some View {
        PinButton(windowId: windowState.windowId)
            .environment(\.theme, windowState.theme)
    }
}

// MARK: - Window Delegate

@MainActor
private final class ChatWindowDelegate: NSObject, NSWindowDelegate {
    let windowId: UUID
    weak var manager: ChatWindowManager?

    init(windowId: UUID, manager: ChatWindowManager) {
        self.windowId = windowId
        self.manager = manager
        super.init()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        manager?.windowDidBecomeKey(id: windowId)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return manager?.windowShouldClose(id: windowId) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        manager?.windowWillClose(id: windowId)
    }

    // MARK: Full screen

    /// AppKit draws the full-screen toolbar with an opaque system backdrop
    /// that can't be tinted or removed via public API and clashes with custom
    /// themes. Hide the NSToolbar in full screen; the SwiftUI content shows
    /// its own themed header row (`ChatFullScreenHeaderView`) instead.
    /// Toolbar detached during full screen, reattached on exit. Detaching
    /// (rather than `isVisible = false`) is deliberate: AppKit manages
    /// toolbar visibility itself across the full-screen transition and can
    /// override a manual `isVisible` toggle, leaving the toolbar lost.
    private var stashedToolbar: NSToolbar?

    func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        stashedToolbar = window.toolbar
        window.toolbar = nil
        manager?.windowFullScreenChanged(id: windowId, isFullScreen: true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let toolbar = stashedToolbar {
            window.toolbar = toolbar
            stashedToolbar = nil
        }
        manager?.windowFullScreenChanged(id: windowId, isFullScreen: false)
    }

    /// If the exit transition is interrupted the window stays in full
    /// screen; keep the stashed toolbar for the next successful exit.
    func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window.toolbar != nil else { return }
        // Defensive: if AppKit restored a toolbar while entering, drop the
        // stash so we don't attach a second one later.
        stashedToolbar = nil
    }
}
