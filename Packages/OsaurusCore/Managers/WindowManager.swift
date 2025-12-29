//
//  WindowManager.swift
//  osaurus
//
//  Centralized window management with proper z-ordering and pin-to-top support.
//

import AppKit
import Combine
import SwiftUI

/// Identifies managed windows in the application
public enum WindowIdentifier: Hashable, CustomStringConvertible, Sendable {
    case chat
    case management
    case permission

    public var description: String {
        switch self {
        case .chat: return "Chat"
        case .management: return "Management"
        case .permission: return "Permission"
        }
    }
}

/// Configuration for creating a managed window
public struct WindowConfiguration: Sendable {
    let identifier: WindowIdentifier
    let defaultSize: NSSize
    let styleMask: NSWindow.StyleMask
    let usePanel: Bool
    let titlebarAppearsTransparent: Bool
    let titleVisibility: NSWindow.TitleVisibility
    let isMovableByWindowBackground: Bool
    let hideStandardButtons: Set<NSWindow.ButtonType>

    public static let chat = WindowConfiguration(
        identifier: .chat,
        defaultSize: NSSize(width: 720, height: 550),
        styleMask: [.titled, .resizable, .fullSizeContentView],
        usePanel: true,
        titlebarAppearsTransparent: true,
        titleVisibility: .hidden,
        isMovableByWindowBackground: false,
        hideStandardButtons: [.closeButton, .miniaturizeButton, .zoomButton]
    )

    public static let management = WindowConfiguration(
        identifier: .management,
        defaultSize: NSSize(width: 900, height: 640),
        styleMask: [.titled, .closable, .fullSizeContentView],
        usePanel: false,
        titlebarAppearsTransparent: true,
        titleVisibility: .hidden,
        isMovableByWindowBackground: true,
        hideStandardButtons: [.miniaturizeButton, .zoomButton]
    )
}

/// Centralized window management for the application
@MainActor
public final class WindowManager: NSObject, ObservableObject {
    public static let shared = WindowManager()

    // MARK: - Published State

    /// Currently pinned windows (floating above other apps)
    @Published public private(set) var pinnedWindows: Set<WindowIdentifier> = []

    // MARK: - Private State

    private var windows: [WindowIdentifier: NSWindow] = [:]
    private var windowDelegates: [WindowIdentifier: WindowManagerDelegate] = [:]

    private override init() {
        super.init()
        loadPinnedState()

        // Sync chat window pinned state from ChatConfiguration (source of truth for user preference)
        syncChatPinnedStateFromConfiguration()
    }

    /// Sync the chat window's pinned state from ChatConfiguration
    private func syncChatPinnedStateFromConfiguration() {
        let chatConfig = ChatConfigurationStore.load()
        if chatConfig.alwaysOnTop {
            pinnedWindows.insert(.chat)
        } else {
            pinnedWindows.remove(.chat)
        }
    }

    // MARK: - Window Registration

    /// Register an existing window with the manager
    public func register(_ window: NSWindow, as identifier: WindowIdentifier) {
        windows[identifier] = window

        // Create and store a delegate to handle window events
        let delegate = WindowManagerDelegate(identifier: identifier, manager: self)
        windowDelegates[identifier] = delegate
        window.delegate = delegate

        // Apply pinned state if this window was previously pinned
        if pinnedWindows.contains(identifier) {
            applyPinnedStyle(to: window, pinned: true)
        }
    }

    /// Unregister a window (typically called when window closes)
    public func unregister(_ identifier: WindowIdentifier) {
        windows.removeValue(forKey: identifier)
        windowDelegates.removeValue(forKey: identifier)
    }

    /// Get the window for an identifier (if registered)
    public func window(for identifier: WindowIdentifier) -> NSWindow? {
        windows[identifier]
    }

    /// Check if a window is currently registered and visible
    public func isVisible(_ identifier: WindowIdentifier) -> Bool {
        windows[identifier]?.isVisible ?? false
    }

    // MARK: - Show/Hide

    /// Bring a window to the front, activating the app
    /// - Parameters:
    ///   - identifier: The window to show
    ///   - center: Whether to center the window on the active screen (default: true)
    public func show(_ identifier: WindowIdentifier, center: Bool = true) {
        guard let window = windows[identifier] else {
            print("[WindowManager] No window registered for \(identifier)")
            return
        }

        // Unhide app if hidden
        NSApp.unhide(nil)

        // Deminiaturize if needed
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        // Center on active screen BEFORE showing
        if center {
            centerOnActiveScreen(window)
        }

        // Temporarily use screenSaver level (highest) to force window above everything
        // This is necessary because macOS won't bring windows to front from background apps
        let isPinned = pinnedWindows.contains(identifier)
        let originalLevel = isPinned ? NSWindow.Level.floating : NSWindow.Level.normal
        window.level = .screenSaver  // Higher than modalPanel

        // Activate app using the appropriate API for the macOS version
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        // Also yank focus using NSRunningApplication
        _ = NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeKey()

        // Force window to be visible and on top
        window.setIsVisible(true)

        // Also set collection behavior to ensure it can appear on all spaces during activation
        let originalBehavior = window.collectionBehavior
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // For NSPanel, ensure it can become key
        if let panel = window as? NSPanel {
            panel.becomesKeyOnlyIfNeeded = false
            panel.hidesOnDeactivate = false
        }

        // Restore normal level and behavior after a brief moment
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms
            window.level = originalLevel
            window.collectionBehavior = isPinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : originalBehavior

            // Re-center after window is fully displayed
            if center {
                self.centerOnActiveScreen(window)
            }
        }

        print(
            "[WindowManager] Showed \(identifier), visible: \(window.isVisible), centered: \(center), pinned: \(isPinned)"
        )
    }

    /// Hide a window (order out, not close)
    public func hide(_ identifier: WindowIdentifier) {
        guard let window = windows[identifier] else { return }
        window.orderOut(nil)
        print("[WindowManager] Hid \(identifier)")
    }

    /// Toggle visibility of a window
    /// - Parameters:
    ///   - identifier: The window to toggle
    ///   - center: Whether to center the window when showing (default: true)
    public func toggle(_ identifier: WindowIdentifier, center: Bool = true) {
        if isVisible(identifier) {
            hide(identifier)
        } else {
            show(identifier, center: center)
        }
    }

    // MARK: - Pin to Top

    /// Set whether a window should be pinned (floating above other apps)
    public func setPinned(_ identifier: WindowIdentifier, pinned: Bool) {
        if pinned {
            pinnedWindows.insert(identifier)
        } else {
            pinnedWindows.remove(identifier)
        }

        // Apply to window if it exists
        if let window = windows[identifier] {
            applyPinnedStyle(to: window, pinned: pinned)
        }

        // Persist the pinned state
        savePinnedState()

        // Also update ChatConfiguration for chat window (keep in sync)
        if identifier == .chat {
            var chatConfig = ChatConfigurationStore.load()
            if chatConfig.alwaysOnTop != pinned {
                chatConfig.alwaysOnTop = pinned
                ChatConfigurationStore.save(chatConfig)
            }
        }

        print("[WindowManager] \(identifier) pinned: \(pinned)")
    }

    /// Check if a window is pinned
    public func isPinned(_ identifier: WindowIdentifier) -> Bool {
        pinnedWindows.contains(identifier)
    }

    /// Toggle pinned state
    public func togglePinned(_ identifier: WindowIdentifier) {
        setPinned(identifier, pinned: !isPinned(identifier))
    }

    // MARK: - Window Creation Helpers

    /// Create and register a new window with the given configuration and content
    public func createWindow<Content: View>(
        config: WindowConfiguration,
        content: () -> Content
    ) -> NSWindow {
        let hostingController = NSHostingController(rootView: content())

        // Calculate centered position on active screen
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let initialRect: NSRect
        if let s = screen {
            initialRect = centeredRect(size: config.defaultSize, on: s)
        } else {
            initialRect = NSRect(origin: .zero, size: config.defaultSize)
        }

        let window: NSWindow
        if config.usePanel {
            let panel = NSPanel(
                contentRect: initialRect,
                styleMask: config.styleMask,
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.animationBehavior = .none
            // Critical panel settings for proper activation
            panel.becomesKeyOnlyIfNeeded = false
            panel.hidesOnDeactivate = false
            panel.worksWhenModal = true
            window = panel
        } else {
            window = NSWindow(
                contentRect: initialRect,
                styleMask: config.styleMask,
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
        }

        // Apply common configuration
        window.titleVisibility = config.titleVisibility
        window.titlebarAppearsTransparent = config.titlebarAppearsTransparent
        window.isMovableByWindowBackground = config.isMovableByWindowBackground

        // Hide standard buttons
        for buttonType in config.hideStandardButtons {
            window.standardWindowButton(buttonType)?.isHidden = true
        }

        window.contentViewController = hostingController

        // Pre-layout to avoid jank
        hostingController.view.layoutSubtreeIfNeeded()

        // Register with manager
        register(window, as: config.identifier)

        return window
    }

    // MARK: - Private Helpers

    private func applyPinnedStyle(to window: NSWindow, pinned: Bool) {
        if pinned {
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            window.level = .normal
            window.collectionBehavior = []
        }
    }

    private func centerOnActiveScreen(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main

        guard let s = screen else {
            print("[WindowManager] No screen found, using window.center()")
            window.center()
            return
        }

        let vf = s.visibleFrame
        let size = window.frame.size
        let x = vf.midX - size.width / 2
        let y = vf.midY - size.height / 2
        let newOrigin = NSPoint(x: x, y: y)

        print(
            "[WindowManager] Centering window: screen=\(s.localizedName), visibleFrame=\(vf), windowSize=\(size), newOrigin=\(newOrigin)"
        )

        window.setFrameOrigin(newOrigin)
    }

    private func centeredRect(size: NSSize, on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let origin = NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2)
        return NSRect(origin: origin, size: size)
    }

    // MARK: - Persistence

    private static let pinnedWindowsKey = "WindowManager.pinnedWindows"

    private func savePinnedState() {
        let identifiers = pinnedWindows.map { identifier -> String in
            switch identifier {
            case .chat: return "chat"
            case .management: return "management"
            case .permission: return "permission"
            }
        }
        UserDefaults.standard.set(identifiers, forKey: Self.pinnedWindowsKey)
    }

    private func loadPinnedState() {
        guard let identifiers = UserDefaults.standard.stringArray(forKey: Self.pinnedWindowsKey) else {
            return
        }
        for id in identifiers {
            switch id {
            case "chat": pinnedWindows.insert(.chat)
            case "management": pinnedWindows.insert(.management)
            case "permission": pinnedWindows.insert(.permission)
            default: break
            }
        }
    }
}

// MARK: - Window Delegate

/// Internal delegate to handle window lifecycle events
@MainActor
private final class WindowManagerDelegate: NSObject, NSWindowDelegate {
    let identifier: WindowIdentifier
    weak var manager: WindowManager?

    init(identifier: WindowIdentifier, manager: WindowManager) {
        self.identifier = identifier
        self.manager = manager
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        manager?.unregister(identifier)

        // Post appropriate notifications based on window type
        switch identifier {
        case .chat:
            NotificationCenter.default.post(name: .chatViewClosed, object: nil)
        default:
            break
        }
    }
}
