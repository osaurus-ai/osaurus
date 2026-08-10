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
        case .chat: return L("Chat")
        case .management: return L("Management")
        case .permission: return L("Permission")
        }
    }
}

/// Strictly typed autosave names for window frame persistence
public enum WindowFrameAutosaveKey: String, Sendable {
    case chat = "ChatWindow"
    case management = "ManagementWindow"
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
    let autosaveKey: WindowFrameAutosaveKey?

    public static let chat = WindowConfiguration(
        identifier: .chat,
        defaultSize: NSSize(width: 800, height: 610),
        styleMask: [.titled, .resizable, .fullSizeContentView],
        usePanel: true,
        titlebarAppearsTransparent: true,
        titleVisibility: .hidden,
        isMovableByWindowBackground: false,
        hideStandardButtons: [.closeButton, .miniaturizeButton, .zoomButton],
        autosaveKey: .chat
    )

    public static let management = WindowConfiguration(
        identifier: .management,
        defaultSize: NSSize(width: 900, height: 640),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        usePanel: false,
        titlebarAppearsTransparent: true,
        titleVisibility: .hidden,
        isMovableByWindowBackground: false,
        hideStandardButtons: [],
        autosaveKey: .management
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

        // Unhide app if hidden. Guarded because `unhide:` always makes a
        // synchronous mach round-trip to the WindowServer (SLSSetFrontProcess),
        // which can stall for seconds when the system is under memory pressure
        // (Sentry APPLE-MACOS-P9) — skip it in the common not-hidden case.
        if NSApp.isHidden {
            NSApp.unhide(nil)
        }

        // Deminiaturize if needed
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        // Recover from a stale autosaved frame BEFORE showing. Callers pass
        // `center: false` so the frame restored by `setFrameAutosaveName`
        // wins, but that frame can reference a display region that no longer
        // exists (external monitor unplugged or rearranged) or have collapsed
        // to a degenerate size. AppKit still reports such a window as visible,
        // so every entry point "works" while the user sees nothing (the
        // "Settings won't open" reports). If the frame is not usably on any
        // current screen, fall back to the default size and re-center.
        let frame = window.frame
        let hasUsableSize = frame.width >= 200 && frame.height >= 200
        let isReachable = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(frame)
            return overlap.width >= 100 && overlap.height >= 50
        }
        if !hasUsableSize || !isReachable {
            print(
                "[WindowManager] Recovering \(identifier) from stale frame \(frame) (usableSize: \(hasUsableSize), reachable: \(isReachable))"
            )
            window.setContentSize(Self.fallbackSize(for: identifier))
            centerOnActiveScreen(window)
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

        // Activate app and yank focus. Force activation (`ignoringOtherApps`)
        // when Osaurus is backgrounded rather than relying on the cooperative
        // `NSApp.activate()`: as an `LSUIElement` accessory app whose main
        // surface is a transient status-bar popover, Osaurus is usually not the
        // active app when a window is opened from the popover. Sequoia's
        // stricter cooperative-activation rules then make `NSApp.activate()` a
        // no-op, so the window is created but never comes to the front (the
        // "Settings won't open" reports). Gated on `!isActive` so behavior is
        // unchanged when already frontmost, and safe because the popover is
        // already closed by the time this runs (`closePopoverAndPerform`).
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSApp.activate()
        }
        if #available(macOS 14.0, *) {
            _ = NSRunningApplication.current.activate(options: .activateAllWindows)
        } else {
            _ = NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
        }

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

            // Critical check: Ensure window is still visible before restoring state.
            // If the user closed the window during this delay, we must abort to avoid
            // inadvertently re-showing or modifying a closed/hidden window.
            guard self.isVisible(identifier) else {
                print("[WindowManager] Window \(identifier) hidden during transition, aborting restore")
                return
            }

            window.level = originalLevel
            window.collectionBehavior = isPinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : originalBehavior
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

        // AppKit owns these windows' size via `defaultSize` + frame autosave,
        // so the SwiftUI content should fill the window rather than drive it.
        // Leaving the default sizingOptions on lets the hosting controller push
        // the content's measured size back onto the window every layout pass;
        // with fill-style (`maxWidth/maxHeight: .infinity`) roots that negotiation
        // has no fixed point and can oscillate after a resize or state change,
        // pinning the main thread in a non-converging layout loop.
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = []
        }

        // Calculate centered position on active screen
        let initialRect: NSRect
        if let s = activeScreen {
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

        // Opt out of AppKit snapshot state restoration. Window positions
        // still persist via `setFrameAutosaveName` below; this only kills
        // the launch-time blit of the previous run's window snapshots.
        window.isRestorable = false

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

        // Force set content size again to ensure we start with the intended size
        // This prevents the window from starting at 0x0 or wrong size if layoutSubtreeIfNeeded did something unexpected
        window.setContentSize(config.defaultSize)

        if let autosaveKey = config.autosaveKey {
            window.setFrameAutosaveName(autosaveKey.rawValue)
        }

        // Register with manager
        register(window, as: config.identifier)

        return window
    }

    // MARK: - Private Helpers

    /// Known-good size to restore a window to when its persisted frame is
    /// unusable. Mirrors the `WindowConfiguration` defaults.
    private static func fallbackSize(for identifier: WindowIdentifier) -> NSSize {
        switch identifier {
        case .chat: return WindowConfiguration.chat.defaultSize
        case .management: return WindowConfiguration.management.defaultSize
        case .permission: return NSSize(width: 800, height: 600)
        }
    }

    private var activeScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

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
        guard let s = activeScreen else {
            print("[WindowManager] No screen found, using window.center()")
            window.center()
            return
        }

        let rect = centeredRect(size: window.frame.size, on: s)

        print(
            "[WindowManager] Centering window: screen=\(s.localizedName), visibleFrame=\(s.visibleFrame), windowSize=\(window.frame.size), newOrigin=\(rect.origin)"
        )

        window.setFrameOrigin(rect.origin)
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
