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

/// Behavior of the ⌘N shortcut in the File menu. Off (default) keeps ⌘N on
/// "New Window". On, ⌘N starts a new chat in the frontmost chat window (the
/// sidebar "New Chat" action) and "New Window" moves to ⇧⌘N. Toggled in
/// Chat settings, read by the app's File menu commands.
public enum NewChatShortcutSetting {
    public static let defaultsKey = "chatCmdNStartsNewChatInCurrentWindow"
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

    private override init() {
        super.init()
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

    /// Start a new chat in the frontmost chat window, mirroring the sidebar
    /// "New Chat" button. Targets the last-focused window as long as it still
    /// exists, even when hidden, and brings it to the front first. Returns
    /// false when no chat window exists so the caller can fall back to
    /// creating a new window.
    @discardableResult
    public func startNewChatInLastFocusedWindow() -> Bool {
        let targetId: UUID? =
            if let lastId = lastFocusedWindowId, windowStates[lastId] != nil {
                lastId
            } else {
                windowStates.keys.first
            }
        guard let targetId, let state = windowStates[targetId] else { return false }
        showWindow(id: targetId)
        state.startNewChatInCurrentProject()
        return true
    }

    /// The chat window app-menu keyboard shortcuts act on: the key chat
    /// window when one is focused, otherwise the last-focused window as long
    /// as it is still visible. Hidden windows are excluded — unlike ⌘N these
    /// shortcuts toggle in-window UI, and mutating a window the user cannot
    /// see (without bringing it forward) would just be silent confusion.
    private var shortcutTargetState: ChatWindowState? {
        if let keyId = nsWindows.first(where: { $0.value.isKeyWindow })?.key {
            return windowStates[keyId]
        }
        if let lastId = lastFocusedWindowId, let window = nsWindows[lastId], window.isVisible {
            return windowStates[lastId]
        }
        return nil
    }

    /// ⌘B: hide/show the focused chat window's session sidebar, mirroring
    /// the toolbar's sidebar button.
    public func toggleSidebarInFocusedWindow() {
        guard let state = shortcutTargetState else { return }
        withAnimation(state.theme.animationQuick()) {
            state.showSidebar.toggle()
        }
    }

    /// ⇧⌘.: switch the focused chat window to the next agent, wrapping at the
    /// end of the list. Mirrors picking the next entry in the toolbar's agent
    /// pill, so it is a no-op on the project page (where the pill hides) and
    /// while a remote/discovered agent is selected (cycling covers local
    /// agents only, matching what `agentId` points at).
    public func cycleAgentInFocusedWindow() {
        guard let state = shortcutTargetState,
            !state.isProjectPageVisible,
            state.selectedDiscoveredAgent == nil,
            state.selectedRelayAgent == nil
        else { return }
        let agents = state.agents
        guard agents.count > 1,
            let index = agents.firstIndex(where: { $0.id == state.agentId })
        else { return }
        state.switchAgent(to: agents[(index + 1) % agents.count].id)
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
        if let (windowId, _) = windowStates.first(where: { state in
            state.value.tabSessions.contains { $0.sessionId == sessionId }
        }) {
            return windows[windowId]
        }
        return windows.values.first { $0.sessionId == sessionId }
    }

    /// The live `ChatSession` currently showing the given persisted session
    /// id in any open window. Used by `SessionActivityMonitor.stop` to route
    /// a sidebar Stop to the owning window's run when it isn't a detached
    /// registry task.
    func session(forSessionId sessionId: UUID) -> ChatSession? {
        // Prefer the visible (active-tab) instance, then any inactive tab.
        if let active = windowStates.values.first(where: { $0.session.sessionId == sessionId }) {
            return active.session
        }
        for state in windowStates.values {
            if let match = state.liveTabSessions.first(where: { $0.sessionId == sessionId }) {
                return match
            }
        }
        return nil
    }

    /// Check if any windows are visible
    public var hasVisibleWindows: Bool {
        nsWindows.values.contains { $0.isVisible }
    }

    /// True when any open chat session — or any active registry-owned
    /// background run — is currently streaming a model response.
    public var isAnySessionStreaming: Bool {
        windowStates.values.contains { $0.tabSessions.contains { $0.isStreaming } }
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
        // Exclude only the excluded window's ACTIVE session — a sibling tab
        // in the same window streaming a local model contends for the single
        // shared inference slot exactly like another window does.
        let excludedSession = windowId.flatMap { windowStates[$0]?.session }
        return windowStates.values.contains { state in
            state.tabSessions.contains { $0 !== excludedSession && $0.isStreamingLocalModel }
        }
            || BackgroundTaskManager.shared.isAnyDetachedTaskStreamingLocalModel(
                excludingSession: excludedSession
            )
    }

    /// True when ANY chat window or detached registry task is currently
    /// streaming a local model. Used to defer speculative model warm-up while
    /// a user stream is in flight.
    var isAnyWindowStreamingLocalModel: Bool {
        windowStates.values.contains { $0.tabSessions.contains { $0.isStreamingLocalModel } }
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
        let windowSessions = windowStates.values.flatMap { $0.tabSessions }
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

    /// Stop visible and detached chat work that owns `name`, and cancel every
    /// matching session's speculative warm-up before an explicit cache unload.
    /// The runtime remains authoritative for HTTP/plugin consumers; this
    /// bridge exists so chat-owned cancellation also updates chat lifecycle
    /// state (`stopRequested`, terminal controls, and post-run warm-up policy).
    @discardableResult
    func prepareSessionsForExplicitModelUnload(named name: String) -> Int {
        let sessions =
            windowStates.values.flatMap { $0.tabSessions }
            + BackgroundTaskManager.shared.activeTaskSessions()
        var seen: Set<ObjectIdentifier> = []
        var prepared = 0

        for session in sessions {
            guard seen.insert(ObjectIdentifier(session)).inserted,
                let selectedModel = session.selectedModel,
                ChatWarmupController.isSelectedModelResident(
                    selectedModel,
                    in: [name]
                )
            else { continue }

            session.prepareForExplicitModelUnload()
            prepared += 1
        }
        return prepared
    }

    /// True only for the visible key chat while Osaurus is frontmost. Runtime
    /// residency notifications use this stronger predicate instead of
    /// `lastFocusedWindowId`, which can still refer to a hidden/background
    /// window and must never authorize a speculative replacement warm-up.
    func isChatWindowActive(id: UUID) -> Bool {
        guard NSApp.isActive, let window = nsWindows[id] else { return false }
        return window.isVisible && window.isKeyWindow
    }

    /// Re-arm speculative warm-up on the active chat window after a
    /// registry-owned background run reaches a terminal state. While that run
    /// streamed, `shouldAttemptWarmup` refused every warm-up; nothing else
    /// re-triggers one until the user refocuses the window, so a chat left
    /// open through a dispatched run stayed cold indefinitely. Only the
    /// visible key window re-arms — hidden windows warm on their next focus,
    /// by which point the finished run's residency release has settled.
    func rearmChatWarmupAfterBackgroundWork() {
        for (id, state) in windowStates where isChatWindowActive(id: id) {
            state.session.notifySessionBecameActive()
        }
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
        // No centered item: the tab strip is leading-aligned (Chrome-style,
        // tabs grow left to right); the single flexible space pushes the
        // action/pin items to the trailing edge.

        let toolbarDelegate = ChatToolbarDelegate(windowState: windowState)
        toolbar.delegate = toolbarDelegate
        panel.chatToolbarDelegate = toolbarDelegate
        panel.chatWindowState = windowState
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
        // Once-per-user layout tour for users updating from the pre-tabs
        // layout; a no-op after it has run or been skipped.
        ChatLayoutTour.shared.autoStartIfEligible(windowId: id)
        // Idle residency may have unloaded this window's selected model while
        // the user was away. Re-arm the existing speculative warm-up when the
        // user returns; its RAM and competing-residency gates still decide
        // whether background loading is safe.
        windowStates[id]?.session.notifySessionBecameActive()
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
            // The ACTIVE session's run survives the window in the registry,
            // but inactive tabs are not covered by that detach — save/stop
            // (or hand off) each of them before the state is dropped.
            state.teardownInactiveTabSessions()
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
        HStack(spacing: 8) {
            ChatToolbarSidebarView(windowState: windowState)
            // Leading-aligned like Chrome: tabs grow left to right.
            ChatTabStripView(windowState: windowState, leadingChromeWidth: 76)
            Spacer()
            ChatToolbarActionView(windowState: windowState)
            ChatToolbarTrailingView(windowState: windowState)
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
    /// The window's state container, for browser-style tab shortcuts
    /// (⌘T / ⌘W / ⇧⌘[ / ⇧⌘]).
    weak var chatWindowState: ChatWindowState?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// ⌘W (the Close menu item) closes the active TAB while more than one is
    /// open, exactly like a browser; the last tab closes the window.
    override func performClose(_ sender: Any?) {
        if let state = chatWindowState, state.tabs.count > 1 {
            state.closeTab(id: state.activeTabId)
            return
        }
        super.performClose(sender)
    }

    /// Browser-style tab shortcuts, handled as KEY EQUIVALENTS so they win
    /// over menu items and over views that swallow key-downs: ⌘N new tab
    /// (overrides File ▸ New Window while the chat surface is showing; on
    /// the project page the menu keeps ⌘N), ⌘T new tab, ⇧⌘T reopen the
    /// last closed tab, ⌃Tab / ⌃⇧Tab and ⇧⌘] / ⇧⌘[ cycle tabs. AppKit
    /// asks the key window before the menu bar, so returning true here is
    /// what keeps New Window from firing.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let state = chatWindowState, handleTabShortcut(event, state: state) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func handleTabShortcut(_ event: NSEvent, state: ChatWindowState) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // Tab key (keyCode 48) with ⌃: next / previous tab.
        if event.keyCode == 48, flags.contains(.control) {
            state.selectAdjacentTab(offset: flags.contains(.shift) ? -1 : 1)
            return true
        }
        switch (flags, key) {
        case (.command, "n") where !state.isProjectPageVisible:
            // Always a NEW tab (like ⌘T), staying in the current project.
            state.newTabInCurrentProject()
            return true
        case (.command, "t"):
            state.newTab()
            return true
        case ([.command, .shift], "t"):
            state.reopenLastClosedTab()
            return true
        case ([.command, .shift], "]"), ([.command, .shift], "}"):
            state.selectAdjacentTab(offset: 1)
            return true
        case ([.command, .shift], "["), ([.command, .shift], "{"):
            state.selectAdjacentTab(offset: -1)
            return true
        default:
            return false
        }
    }
}

// MARK: - Chat Toolbar

/// Toolbar delegate that places each control in its own `NSToolbarItem`
/// so macOS applies native per-item styling (pill backgrounds, spacing).
@MainActor
private final class ChatToolbarDelegate: NSObject, NSToolbarDelegate {
    fileprivate static let sidebarItem = NSToolbarItem.Identifier("ChatToolbar.sidebar")
    /// The centered slot. Hosted the agent pill until the pill moved into
    /// the sidebar's Chats tab; now hosts the chat tab strip. (The old
    /// "ChatToolbar.agent" identifier falls through to `default: nil` if
    /// AppKit ever replays it from stale persisted state.)
    fileprivate static let tabsItem = NSToolbarItem.Identifier("ChatToolbar.tabs")
    fileprivate static let actionItem = NSToolbarItem.Identifier("ChatToolbar.action")
    // The trailing item; hosts the pin (chat) or the settings gear
    // (project page). Named `pin` for backward identity continuity.
    fileprivate static let pinItem = NSToolbarItem.Identifier("ChatToolbar.pin")

    /// Layout: sidebar on the leading edge, agent pill centered (via the
    /// toolbar's `centeredItemIdentifier`), action + pin on the trailing edge.
    /// The flexible spaces let the trailing items hug the right edge.
    /// Any stale identifiers AppKit may have persisted in user defaults
    /// fall through to `default: nil` in `itemForItemIdentifier`, which
    /// renders them as no-ops rather than crashing.
    // The trailing slot is a SINGLE item that shows the pin (chat) or the
    // settings gear (project page) — they're mutually exclusive. Keeping
    // them as two items left whichever one was hidden as an empty toolbar
    // item that AppKit still reserved spacing for, so every chat had a dead
    // gap at the toolbar's right edge.
    private static let itemIdentifiers: [NSToolbarItem.Identifier] = [
        sidebarItem, tabsItem, .flexibleSpace, actionItem, pinItem,
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

        case Self.tabsItem:
            return makeHostingItem(
                identifier: itemIdentifier,
                rootView:
                    ChatTabStripView(windowState: windowState)
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
                    ChatToolbarTrailingView(windowState: windowState)
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
        // Track the SwiftUI content's intrinsic size continuously — the tab
        // strip (and the project back-pill) change width at runtime, and a
        // frame fixed at creation makes those transitions clip/jump.
        if #available(macOS 13.0, *) {
            hostingView.sizingOptions = [.intrinsicContentSize]
        }
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

extension Notification.Name {
    static let chatToolbarSelectDiscoveredAgent = Notification.Name("chatToolbarSelectDiscoveredAgent")
    /// Posted by the toolbar's back button to reopen the current chat's
    /// project page in the window identified by `userInfo["windowId"]`.
    static let chatToolbarBackToProject = Notification.Name("chatToolbarBackToProject")
    static let chatToolbarSelectRelayAgent = Notification.Name("chatToolbarSelectRelayAgent")
    /// Posted by the `/agent` slash command to pop open the toolbar's agent
    /// picker for the window identified in `userInfo["windowId"]`.
    static let chatToolbarOpenAgentPicker = Notification.Name("chatToolbarOpenAgentPicker")
    /// Posted by `ChatSessionsManager` when a session's project membership
    /// changes (or a whole project is deleted), so open chat windows update
    /// their live `ChatSession.projectId` — the value each turn's compose
    /// reads for project instructions and knowledge grants. userInfo carries
    /// either `sessionId` + `projectId` (single move) or `clearedProjectId`
    /// (project deleted).
    static let chatSessionProjectDidChange = Notification.Name("chatSessionProjectDidChange")
}

/// Back button beside the sidebar toggle: shown while the current chat
/// belongs to a project (and the project page itself is not up); returns to
/// that project's detail page. Split into outer/inner views for the same
/// session-replacement reason as `ChatToolbarActionView` below.
/// Contextual action button: new-chat plus once a conversation exists.
/// Split into an outer view (observing `windowState`, which republishes when
/// the window's session is replaced) and an inner content view holding the
/// `@ObservedObject` session, so the button tracks the CURRENT session's
/// turns after a chat switch instead of a stale instance.
private struct ChatToolbarActionView: View {
    @ObservedObject var windowState: ChatWindowState

    var body: some View {
        // New-chat/plus is chat chrome; the project page has its own
        // New Chat entry point.
        if !windowState.isProjectPageVisible {
            ChatToolbarActionContent(windowState: windowState, session: windowState.session)
        }
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
            // New-chat button retired with the tab strip: its "+" (and ⌘T)
            // starts a new chat in a new tab, and two adjacent plus buttons
            // with subtly different semantics read as a mistake.
            // if !session.turns.isEmpty {
            //     HeaderActionButton(
            //         icon: "plus",
            //         help: "New chat",
            //         action: { windowState.startNewChatInCurrentProject() }
            //     )
            // }
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

/// The single trailing toolbar item. Window pinning is chat chrome; the
/// settings gear only makes sense on the project detail page (the chat
/// surface reaches settings through the agent pill's gear, which hides with
/// the rest of the chat chrome while a project is open). The two are
/// mutually exclusive, so they share one toolbar item — otherwise the
/// hidden one leaves an empty item that reserves a dead gap at the toolbar's
/// right edge. Both are `HeaderActionButton`-sized, so the item's footprint
/// is stable as it swaps.
private struct ChatToolbarTrailingView: View {
    @ObservedObject var windowState: ChatWindowState

    // Two chat-only buttons: History (the conversation list, as a dialog)
    // and Pin Window. Settings moved to the bottom of the sidebar. Both
    // hide on the project page, which has no chat to list or pin.
    var body: some View {
        HStack(spacing: 8) {
            if !windowState.isProjectPageVisible {
                HeaderActionButton(
                    icon: "clock.arrow.circlepath",
                    help: "History",
                    action: { ChatHistoryDialog.present(for: windowState) }
                )
                // Tour spotlight anchor (invisible; reports the button's frame).
                .background(TourAnchorMarker(anchor: .historyButton))

                HeaderActionButton(
                    icon: windowState.isWindowPinned ? "pin.fill" : "pin",
                    help: windowState.isWindowPinned ? "Unpin Window" : "Pin Window",
                    action: {
                        windowState.isWindowPinned.toggle()
                        ChatWindowManager.shared.setWindowPinned(
                            id: windowState.windowId, pinned: windowState.isWindowPinned)
                    }
                )
            }
        }
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

    /// Push the live content width into the window state on every resize so
    /// the tab strip re-sizes even while its toolbar item is folded into the
    /// overflow menu (see `ChatWindowState.windowContentWidth`).
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let contentView = window.contentView
        else { return }
        manager?.windowState(id: windowId)?.updateWindowContentWidth(contentView.bounds.width)
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
