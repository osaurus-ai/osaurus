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

    /// Stop all active sessions (chat and work) across all windows.
    /// Called during app termination to prevent crashes from in-flight inference.
    public func stopAllSessions() {
        for (_, state) in windowStates {
            state.cleanup()
        }
    }

    /// Close a chat window by ID
    public func closeWindow(id: UUID) {
        guard let window = nsWindows[id] else {
            print("[ChatWindowManager] No window found for ID \(id)")
            return
        }

        // Check if we should allow the close (may show background task dialog)
        guard shouldAllowClose(id: id) else {
            return
        }

        // Close will trigger the delegate which handles cleanup
        window.close()
    }

    /// Check if window close should be allowed. Chat sessions can always
    /// be safely closed; users keep work running by leaving the window open.
    private func shouldAllowClose(id: UUID) -> Bool {
        _ = id
        return true
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
        _ = NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)

        // Bring the window forward and make it key
        window.makeKeyAndOrderFront(nil)

        // Update last focused
        lastFocusedWindowId = id
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

    /// Find windows by agent ID
    public func findWindows(byAgentId agentId: UUID) -> [ChatWindowInfo] {
        windows.values.filter { $0.agentId == agentId }
    }

    /// Find a window by session ID
    public func findWindow(bySessionId sessionId: UUID) -> ChatWindowInfo? {
        windows.values.first { $0.sessionId == sessionId }
    }

    /// Check if any windows are visible
    public var hasVisibleWindows: Bool {
        nsWindows.values.contains { $0.isVisible }
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

    /// Get window info by ID
    public func windowInfo(id: UUID) -> ChatWindowInfo? {
        windows[id]
    }

    /// Get the window state for a specific window (for accessing session/agent)
    func windowState(id: UUID) -> ChatWindowState? {
        windowStates[id]
    }

    /// Returns the set of local model names selected by currently-open chat
    /// windows. Used as a "keep loaded for next interaction" hint for GC.
    ///
    /// Safety against unloading a model mid-stream is enforced by `ModelLease`
    /// inside `ModelRuntime.unloadModelsNotIn` — this set only needs to cover
    /// the UX heuristic of "the user still has a window open with this model
    /// selected, don't pay reload cost on their next keystroke".
    func activeLocalModelNames() -> Set<String> {
        Set(
            windowStates.values.compactMap { state in
                guard let model = state.session.selectedModel,
                    ModelManager.findInstalledModel(named: model) != nil
                else { return nil }
                return model
            }
        )
    }

    /// Set a callback to be invoked when window is about to close (for session saving)
    public func setCloseCallback(for windowId: UUID, callback: @escaping () -> Void) {
        sessionCallbacks[windowId] = callback
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
        // Create ChatView with the existing window state
        let chatView = ChatView(windowState: windowState)
            .environment(\.theme, windowState.theme)

        let hostingController = NSHostingController(rootView: chatView)

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

        // Create ChatView with window state
        let chatView = ChatView(windowState: windowState)
            .environment(\.theme, windowState.theme)

        let hostingController = NSHostingController(rootView: chatView)

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
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .managed]

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.appearance = NSAppearance(named: windowState.theme.isDark ? .darkAqua : .aqua)

        let toolbar = NSToolbar(identifier: "ChatToolbar")
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false

        let toolbarDelegate = ChatToolbarDelegate(windowState: windowState, session: windowState.session)
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
        print("[ChatWindowManager] Window \(id) became key")
    }

    // Called by delegate to determine if window should close (for Cmd+W, etc.)
    fileprivate func windowShouldClose(id: UUID) -> Bool {
        return shouldAllowClose(id: id)
    }

    // Called by delegate when window will close
    fileprivate func windowWillClose(id: UUID) {
        print("[ChatWindowManager] Window \(id) will close")

        let isDetachedToBackground = BackgroundTaskManager.shared.isBackgroundTask(id)

        // Only invoke save callback and cleanup if NOT detached to background
        // (background task needs the session to keep running)
        if !isDetachedToBackground {
            if let callback = sessionCallbacks[id] {
                callback()
            }
            windowStates[id]?.cleanup()
        }

        // Clean up all local references. BackgroundTaskState independently retains
        // the ChatWindowState it needs, so removing it here is always safe.
        sessionCallbacks.removeValue(forKey: id)
        windowDelegates.removeValue(forKey: id)
        windowStates.removeValue(forKey: id)

        let closedSessionId = windows[id]?.sessionId
        let closedAgentId = windows[id]?.agentId
        Task {
            if let sid = closedSessionId {
                await ModelRuntime.shared.invalidateSession(sid.uuidString)
                PluginHostContext.invalidatePreflightCache(sessionId: sid.uuidString)
            }
            if let aid = closedAgentId {
                // Drop any 10-second-TTL memory context snapshot so a freshly
                // opened window for the same agent rebuilds from current state.
                // Without this, a user who edits memory in window B and closes
                // window A could briefly see the stale A-era assembly on the
                // next compose pass.
                await MemoryContextAssembler.shared.invalidateCache(agentId: aid.uuidString)
            }
            let active = self.activeLocalModelNames()
            await ModelRuntime.shared.unloadModelsNotIn(active)
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

        let msg = isDetachedToBackground ? " (detached to background)" : ""
        print("[ChatWindowManager] Window \(id) cleanup complete\(msg), remaining: \(windows.count)")
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
    private static let sidebarItem = NSToolbarItem.Identifier("ChatToolbar.sidebar")
    private static let actionItem = NSToolbarItem.Identifier("ChatToolbar.action")
    private static let pinItem = NSToolbarItem.Identifier("ChatToolbar.pin")

    private weak var windowState: ChatWindowState?
    private weak var session: ChatSession?

    init(windowState: ChatWindowState, session: ChatSession) {
        self.windowState = windowState
        self.session = session
        super.init()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Chat/Work toggle removed: the agentic loop (todo / complete /
        // clarify) now lives inside Chat itself, so a separate Work tab
        // is redundant. The toggle case below still resolves so any
        // stale toolbar identifiers in user defaults render as no-ops
        // instead of crashing.
        [
            Self.sidebarItem, .flexibleSpace, .flexibleSpace, Self.actionItem,
            Self.pinItem,
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.sidebarItem, .flexibleSpace, .flexibleSpace, Self.actionItem,
            Self.pinItem,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let windowState, let session else { return nil }

        switch itemIdentifier {
        case Self.sidebarItem:
            return makeHostingItem(
                identifier: itemIdentifier,
                rootView:
                    ChatToolbarSidebarView(windowState: windowState)
            )

        case Self.actionItem:
            return makeHostingItem(
                identifier: itemIdentifier,
                rootView:
                    ChatToolbarActionView(windowState: windowState, session: session)
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

/// Contextual action button: settings (empty state) or new-chat plus.
private struct ChatToolbarActionView: View {
    @ObservedObject var windowState: ChatWindowState
    @ObservedObject var session: ChatSession

    var body: some View {
        Group {
            if session.turns.isEmpty {
                SettingsButton(action: {
                    AppDelegate.shared?.showManagementWindow(initialTab: nil)
                })
            } else {
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
}
