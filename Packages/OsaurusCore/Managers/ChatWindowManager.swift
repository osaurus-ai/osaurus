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
    public let personaId: UUID
    public let sessionId: UUID?
    public let createdAt: Date

    public init(id: UUID = UUID(), personaId: UUID, sessionId: UUID? = nil, createdAt: Date = Date()) {
        self.id = id
        self.personaId = personaId
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

    /// Create a new chat window with default persona
    /// - Parameters:
    ///   - personaId: The persona for this window (defaults to active persona)
    ///   - showImmediately: Whether to show the window immediately (default: true)
    /// - Returns: The window identifier
    @discardableResult
    public func createWindow(personaId: UUID? = nil, showImmediately: Bool = true) -> UUID {
        return createWindowInternal(personaId: personaId, sessionData: nil, showImmediately: showImmediately)
    }

    /// Create a new chat window with existing session data
    /// - Parameters:
    ///   - personaId: The persona for this window (defaults to active persona)
    ///   - sessionData: Optional existing session to load
    ///   - showImmediately: Whether to show the window immediately (default: true)
    /// - Returns: The window identifier
    @discardableResult
    func createWindow(
        personaId: UUID? = nil,
        sessionData: ChatSessionData?,
        showImmediately: Bool = true
    ) -> UUID {
        return createWindowInternal(personaId: personaId, sessionData: sessionData, showImmediately: showImmediately)
    }

    /// Internal implementation for creating windows
    private func createWindowInternal(
        personaId: UUID?,
        sessionData: ChatSessionData?,
        showImmediately: Bool
    ) -> UUID {
        let windowId = UUID()
        let effectivePersonaId = personaId ?? PersonaManager.shared.activePersonaId

        let info = ChatWindowInfo(
            id: windowId,
            personaId: effectivePersonaId,
            sessionId: sessionData?.id,
            createdAt: Date()
        )

        windows[windowId] = info

        // Create the actual NSWindow
        let window = createNSWindow(
            windowId: windowId,
            personaId: effectivePersonaId,
            sessionData: sessionData
        )

        nsWindows[windowId] = window

        // Show the window if requested
        if showImmediately {
            showWindow(id: windowId)
        }

        print(
            "[ChatWindowManager] Created window \(windowId) for persona \(effectivePersonaId) (shown: \(showImmediately))"
        )

        return windowId
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

    /// Check if window close should be allowed, showing background task dialog if needed
    /// - Returns: true if close should proceed, false if cancelled
    private func shouldAllowClose(id: UUID) -> Bool {
        guard let windowState = windowStates[id] else { return true }

        // If this window is already detached to background, allow close without prompts.
        // This prevents duplicate confirmations when we detach and then programmatically close.
        if BackgroundTaskManager.shared.isBackgroundTask(id) {
            return true
        }

        // Check if there's a running agent task
        let isAgentExecuting =
            windowState.agentSession?.isExecuting == true
            || windowState.agentSession?.hasPendingClarification == true

        guard isAgentExecuting else {
            // No running task, allow close
            return true
        }

        // Present in-app themed confirmation via SwiftUI overlay (ChatView observes this)
        if windowState.agentCloseConfirmation == nil {
            windowState.agentCloseConfirmation = AgentCloseConfirmation()
        }
        return false
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

        // Activate and bring to front
        NSApp.activate(ignoringOtherApps: true)
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
            if window.isVisible {
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

    /// Find windows by persona ID
    public func findWindows(byPersonaId personaId: UUID) -> [ChatWindowInfo] {
        windows.values.filter { $0.personaId == personaId }
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

    /// Get the window state for a specific window (for accessing session/persona)
    func windowState(id: UUID) -> ChatWindowState? {
        windowStates[id]
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
        NSApp.activate(ignoringOtherApps: true)

        // Bring all windows to front
        for (_, window) in nsWindows {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.orderFront(nil)
        }

        // Make the last focused window key
        if let lastId = lastFocusedWindowId, let window = nsWindows[lastId] {
            window.makeKeyAndOrderFront(nil)
        } else if let firstWindow = nsWindows.values.first {
            firstWindow.makeKeyAndOrderFront(nil)
        }

        print("[ChatWindowManager] Focused all \(windows.count) windows")
    }

    // MARK: - Background Task Window Support

    /// Create a window for viewing a background task
    /// - Parameters:
    ///   - backgroundId: The background task ID (original window ID)
    ///   - session: The agent session from the background task
    ///   - windowState: The window state from the background task
    /// - Returns: The window ID (same as backgroundId)
    @discardableResult
    func createWindowForBackgroundTask(
        backgroundId: UUID,
        session: AgentSession,
        windowState: ChatWindowState
    ) -> UUID {
        // Reuse the original window ID - windowState.windowId already matches
        let windowId = backgroundId

        let info = ChatWindowInfo(
            id: windowId,
            personaId: windowState.personaId,
            sessionId: nil,
            createdAt: Date()
        )

        windows[windowId] = info

        // Create the actual NSWindow reusing the existing window state
        // After restoration, this is a regular window - if user closes while
        // task is running, it will be re-detached through normal flow
        let window = createNSWindowForBackgroundTask(
            windowId: windowId,
            windowState: windowState
        )

        nsWindows[windowId] = window
        windowStates[windowId] = windowState

        // Show the window
        showWindow(id: windowId)

        print("[ChatWindowManager] Created window \(windowId) for background task \(backgroundId)")

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

        // Calculate centered position on active screen
        let defaultSize = NSSize(width: 800, height: 610)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main

        let cascadeOffset = CGFloat(windows.count) * 25.0

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

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.isReleasedWhenClosed = false

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.appearance = NSAppearance(named: windowState.theme.isDark ? .darkAqua : .aqua)

        let toolbar = NSToolbar(identifier: "ChatToolbar")
        toolbar.showsBaselineSeparator = false
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false

        let toolbarDelegate = ChatToolbarDelegate(windowState: windowState, session: windowState.session)
        toolbar.delegate = toolbarDelegate
        panel.chatToolbarDelegate = toolbarDelegate
        panel.toolbar = toolbar
        panel.toolbarStyle = .unified

        panel.contentViewController = hostingController
        panel.setContentSize(defaultSize)

        let delegate = ChatWindowDelegate(windowId: windowId, manager: self)
        windowDelegates[windowId] = delegate
        panel.delegate = delegate

        return panel
    }

    // MARK: - Private Helpers

    private func createNSWindow(
        windowId: UUID,
        personaId: UUID,
        sessionData: ChatSessionData?
    ) -> NSWindow {
        // Create per-window state container (isolates from shared singletons)
        let windowState = ChatWindowState(
            windowId: windowId,
            personaId: personaId,
            sessionData: sessionData
        )
        windowStates[windowId] = windowState

        // Create ChatView with window state
        let chatView = ChatView(windowState: windowState)
            .environment(\.theme, windowState.theme)

        let hostingController = NSHostingController(rootView: chatView)

        // Calculate centered position on active screen, with offset for multiple windows
        let defaultSize = NSSize(width: 800, height: 610)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main

        // Cascade offset based on number of existing windows (25pt per window)
        let cascadeOffset = CGFloat(windows.count) * 25.0

        let initialRect: NSRect
        if let s = screen {
            let vf = s.visibleFrame
            // Start from center, then offset down-right for each additional window
            let baseOrigin = NSPoint(
                x: vf.midX - defaultSize.width / 2,
                y: vf.midY - defaultSize.height / 2
            )
            // Apply cascade: move right and down
            var origin = NSPoint(
                x: baseOrigin.x + cascadeOffset,
                y: baseOrigin.y - cascadeOffset
            )
            // Ensure window stays within visible frame
            if origin.x + defaultSize.width > vf.maxX {
                origin.x = vf.minX + 50  // Wrap back to left
            }
            if origin.y < vf.minY {
                origin.y = vf.maxY - defaultSize.height - 50  // Wrap back to top
            }
            initialRect = NSRect(origin: origin, size: defaultSize)
        } else {
            initialRect = NSRect(origin: .zero, size: defaultSize)
        }

        // Create panel (like original chat window)
        let panel = ChatPanel(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.isReleasedWhenClosed = false

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.appearance = NSAppearance(named: windowState.theme.isDark ? .darkAqua : .aqua)

        let toolbar = NSToolbar(identifier: "ChatToolbar")
        toolbar.showsBaselineSeparator = false
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false

        let toolbarDelegate = ChatToolbarDelegate(windowState: windowState, session: windowState.session)
        toolbar.delegate = toolbarDelegate
        panel.chatToolbarDelegate = toolbarDelegate
        panel.toolbar = toolbar
        panel.toolbarStyle = .unified

        panel.contentViewController = hostingController

        // Set size directly - let SwiftUI layout asynchronously for faster window appearance
        panel.setContentSize(defaultSize)

        // Set up delegate for lifecycle events
        let delegate = ChatWindowDelegate(windowId: windowId, manager: self)
        windowDelegates[windowId] = delegate
        panel.delegate = delegate

        return panel
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

        // Check if this window was just detached to background mode
        // In this case, we don't clean up the windowState as BackgroundTaskManager now owns it
        let isDetachedToBackground = BackgroundTaskManager.shared.isBackgroundTask(id)

        // Regular window cleanup
        // Only invoke save callback and cleanup if NOT detached to background
        // (background task needs the session to keep running)
        if !isDetachedToBackground {
            // Invoke save callback before cleanup
            if let callback = sessionCallbacks[id] {
                callback()
            }
            windowStates[id]?.cleanup()
        }

        // Clean up local references
        sessionCallbacks.removeValue(forKey: id)
        windowDelegates.removeValue(forKey: id)

        // Only remove windowState if not detached to background
        if !isDetachedToBackground {
            windowStates.removeValue(forKey: id)
        }

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
    private static let modeToggleItem = NSToolbarItem.Identifier("ChatToolbar.modeToggle")
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
        [Self.sidebarItem, Self.modeToggleItem, .flexibleSpace, Self.actionItem, Self.pinItem]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarItem, Self.modeToggleItem, .flexibleSpace, Self.actionItem, Self.pinItem]
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

        case Self.modeToggleItem:
            return makeHostingItem(
                identifier: itemIdentifier,
                rootView:
                    ChatToolbarModeToggleView(windowState: windowState, session: session)
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

/// Sidebar toggle button. Observes windowState for reactive theme updates.
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

/// Mode toggle (Chat/Agent) with optional task title or model badge.
private struct ChatToolbarModeToggleView: View {
    @ObservedObject var windowState: ChatWindowState
    @ObservedObject var session: ChatSession

    private var isAgentMode: Bool { windowState.mode == .agent }

    var body: some View {
        HStack(spacing: 8) {
            ModeToggleButton(
                currentMode: isAgentMode ? .agent : .chat,
                isDisabled: !isAgentMode && !session.hasAnyModel,
                action: { windowState.switchMode(to: isAgentMode ? .chat : .agent) }
            )

            if isAgentMode, let agentSession = windowState.agentSession {
                AgentTaskTitleView(session: agentSession)
                    .frame(maxWidth: 260, alignment: .leading)
            } else if let model = session.selectedModel, session.modelOptions.count <= 1 {
                ModeIndicatorBadge(style: .model(name: Self.displayModelName(model)))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .environment(\.theme, windowState.theme)
    }

    private static func displayModelName(_ raw: String?) -> String {
        guard let raw else { return "Model" }
        if raw.lowercased() == "foundation" { return "Foundation" }
        if let last = raw.split(separator: "/").last { return String(last) }
        return raw
    }
}

/// Contextual action button: settings (empty state / agent) or new-chat plus.
private struct ChatToolbarActionView: View {
    @ObservedObject var windowState: ChatWindowState
    @ObservedObject var session: ChatSession

    private var isAgentMode: Bool { windowState.mode == .agent }

    var body: some View {
        Group {
            if isAgentMode || session.turns.isEmpty {
                SettingsButton(action: {
                    AppDelegate.shared?.showManagementWindow(initialTab: .settings)
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

/// Agent task title shown next to the mode toggle in agent mode.
private struct AgentTaskTitleView: View {
    @ObservedObject var session: AgentSession

    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if let task = session.currentTask {
                Text(task.title)
                    .font(theme.font(size: CGFloat(theme.bodySize), weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
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
