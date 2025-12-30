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
    /// - Parameter personaId: The persona for this window (defaults to active persona)
    /// - Returns: The window identifier
    @discardableResult
    public func createWindow(personaId: UUID? = nil) -> UUID {
        return createWindowInternal(personaId: personaId, sessionData: nil)
    }

    /// Create a new chat window with existing session data
    /// - Parameters:
    ///   - personaId: The persona for this window (defaults to active persona)
    ///   - sessionData: Optional existing session to load
    /// - Returns: The window identifier
    @discardableResult
    func createWindow(
        personaId: UUID? = nil,
        sessionData: ChatSessionData?
    ) -> UUID {
        return createWindowInternal(personaId: personaId, sessionData: sessionData)
    }

    /// Internal implementation for creating windows
    private func createWindowInternal(
        personaId: UUID?,
        sessionData: ChatSessionData?
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

        // Show the window
        showWindow(id: windowId)

        print("[ChatWindowManager] Created window \(windowId) for persona \(effectivePersonaId)")

        return windowId
    }

    /// Close a chat window by ID
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

        // Activate and bring to front
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // Update last focused
        lastFocusedWindowId = id

        print("[ChatWindowManager] Showed window \(id)")
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
            .environmentObject(AppDelegate.shared!.serverController)
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
        let panel = NSPanel(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
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

        // Hide standard buttons (we have custom ones)
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        panel.contentViewController = hostingController

        // Pre-layout
        hostingController.view.layoutSubtreeIfNeeded()
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

    // Called by delegate when window will close
    fileprivate func windowWillClose(id: UUID) {
        print("[ChatWindowManager] Window \(id) will close")

        // Invoke save callback before cleanup
        if let callback = sessionCallbacks[id] {
            callback()
        }

        // Clean up
        sessionCallbacks.removeValue(forKey: id)
        windowDelegates.removeValue(forKey: id)
        windowStates.removeValue(forKey: id)
        nsWindows.removeValue(forKey: id)
        windows.removeValue(forKey: id)

        // Update last focused if this was the focused window
        if lastFocusedWindowId == id {
            lastFocusedWindowId = windows.keys.first
        }

        // Post notification for VAD resume
        NotificationCenter.default.post(name: .chatViewClosed, object: id)

        print("[ChatWindowManager] Window \(id) cleanup complete, remaining: \(windows.count)")
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

    func windowWillClose(_ notification: Notification) {
        manager?.windowWillClose(id: windowId)
    }
}
