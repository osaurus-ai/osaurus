//
//  NotchWindowController.swift
//  osaurus
//
//  Manages the dedicated NSPanel for the notch UI.
//  Positions the panel at the top of the visible display area and detects
//  hardware notch dimensions for compact sizing.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Notch Screen Metrics

/// Hardware notch dimensions detected from the current screen.
public struct NotchScreenMetrics: Equatable {
    /// Whether the screen has a physical notch (MacBook Pro 2021+).
    public let hasHardwareNotch: Bool
    /// Width of the hardware notch (or default for non-notch screens).
    public let notchWidth: CGFloat
    /// Height of the hardware notch / menu bar area.
    public let notchHeight: CGFloat

    /// Detect notch metrics for the given screen.
    public static func detect(for screen: NSScreen) -> NotchScreenMetrics {
        var width: CGFloat = 200
        var hasNotch = false

        if let topLeft = screen.auxiliaryTopLeftArea?.width,
            let topRight = screen.auxiliaryTopRightArea?.width
        {
            width = screen.frame.width - topLeft - topRight + 4
            hasNotch = true
        }

        let height: CGFloat
        if screen.safeAreaInsets.top > 0 {
            height = screen.safeAreaInsets.top
        } else {
            // Fallback: menu bar height
            height = screen.frame.maxY - screen.visibleFrame.maxY
            if height < 24 { return NotchScreenMetrics(hasHardwareNotch: false, notchWidth: 200, notchHeight: 32) }
        }

        return NotchScreenMetrics(hasHardwareNotch: hasNotch, notchWidth: width, notchHeight: height)
    }
}

// MARK: - Notch Overlay Placement Preference

/// User-controlled vertical placement of the task-progress notch overlay.
///
/// With no saved preference, hardware-notch displays use `onMenuBar` so the
/// overlay remains visually attached to the physical notch. Other displays
/// use `belowMenuBar` so the overlay does not cover system status controls.
public enum NotchOverlayPlacement: String {
    case belowMenuBar
    case onMenuBar

    /// `UserDefaults` key backing the Chat settings toggle. Read by the
    /// controller each time it repositions the panel.
    public static let defaultsKey = "notchOverlayPlacement"

    /// Adaptive default used when the user has not chosen a placement.
    static func defaultPlacement(hasHardwareNotch: Bool) -> NotchOverlayPlacement {
        hasHardwareNotch ? .onMenuBar : .belowMenuBar
    }

    /// Resolves the saved preference, or the adaptive default for `metrics`.
    static func resolved(for metrics: NotchScreenMetrics) -> NotchOverlayPlacement {
        if let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
            let saved = NotchOverlayPlacement(rawValue: rawValue)
        {
            return saved
        }
        return defaultPlacement(hasHardwareNotch: metrics.hasHardwareNotch)
    }

    /// Current preference for the main screen, used as the settings fallback.
    public static var current: NotchOverlayPlacement {
        guard let screen = NSScreen.main else { return .belowMenuBar }
        return resolved(for: NotchScreenMetrics.detect(for: screen))
    }
}

// MARK: - Notch Panel Placement

struct NotchPanelPlacement: Equatable {
    let frame: CGRect

    static func panelRect(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        preferredSize: CGSize,
        hiddenMenuBarInset: CGFloat = 0,
        overMenuBar: Bool = false
    ) -> NotchPanelPlacement {
        let safeFrame = visibleFrame.isEmpty ? screenFrame : visibleFrame
        let width = min(preferredSize.width, max(1, safeFrame.width))
        let height = min(preferredSize.height, max(1, safeFrame.height))
        let centeredX = safeFrame.midX - width / 2
        let minX = safeFrame.minX
        let maxX = safeFrame.maxX - width
        let x = min(max(centeredX, minX), maxX)
        // Anchor the top edge. `overMenuBar` intentionally uses the physical
        // top of the display so the overlay sits on the menu bar. Otherwise we
        // stay inside the visible frame — and when the menu bar auto-hides,
        // `visibleFrame` extends to the very top of the screen, which would
        // place the panel exactly in the strip where the menu bar reappears
        // (overlapping the clock / status icons on every reveal), so we reserve
        // that strip explicitly in that case.
        let topY: CGFloat
        if overMenuBar {
            topY = screenFrame.maxY
        } else if safeFrame.maxY >= screenFrame.maxY {
            topY = safeFrame.maxY - hiddenMenuBarInset
        } else {
            topY = safeFrame.maxY
        }
        let y = topY - height

        return NotchPanelPlacement(frame: CGRect(x: x, y: y, width: width, height: height))
    }

    static func alertContentTopPadding(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        overMenuBar: Bool = false
    ) -> CGFloat {
        // A notch attached to the physical display edge must remain at y=0
        // when the alert temporarily expands its panel to the full screen.
        // Applying the menu-bar gap here would visibly detach the entire
        // shape for the duration of the confirmation dialog.
        guard !overMenuBar else { return 0 }
        guard !visibleFrame.isEmpty else { return 0 }
        return max(0, screenFrame.maxY - visibleFrame.maxY)
    }
}

// MARK: - Notch Window Controller

enum NotchSessionNavigationDirection: Equatable {
    case previous
    case next
}

/// Displays the notch background task indicator at the top center of the screen,
/// inside the screen's visible frame so task progress never covers the menu bar.
@MainActor
public final class NotchWindowController: NSObject, ObservableObject {
    public static let shared = NotchWindowController()
    static let navigateToPreviousSessionNotification =
        Notification.Name("NotchWindowController.navigateToPreviousSession")
    static let navigateToNextSessionNotification =
        Notification.Name("NotchWindowController.navigateToNextSession")

    private var notchPanel: NSPanel?
    private var hostingView: NSHostingView<NotchContentView>?
    private var cancellables = Set<AnyCancellable>()
    private var keyEventMonitor: Any?
    private var isExpandedForAlert = false
    private var screenChangeDebounce: DispatchWorkItem?

    /// Current screen's notch metrics (published for SwiftUI observation).
    @Published public private(set) var metrics = NotchScreenMetrics(
        hasHardwareNotch: false,
        notchWidth: 200,
        notchHeight: 32
    )

    /// Extra top inset applied only while the alert dimming layer expands the
    /// panel to the whole display. Keeps the visible notch content below the
    /// menu bar even though the panel itself covers the full screen.
    @Published public private(set) var alertContentTopPadding: CGFloat = 0

    /// Panel width – generous to allow expansion + shadow.
    private static let panelWidth: CGFloat = 600
    /// Panel height – tall enough for the largest expanded state.
    private static let panelHeight: CGFloat = 500

    private override init() {
        super.init()
    }

    nonisolated static func sessionNavigationDirection(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> NotchSessionNavigationDirection? {
        let navigationModifiers = modifierFlags.intersection([
            .command, .shift, .option, .control,
        ])
        guard navigationModifiers == .command else { return nil }
        switch keyCode {
        case 123: return .previous
        case 124: return .next
        default: return nil
        }
    }

    // MARK: - Public API

    /// Setup the notch overlay window.
    public func setup() {
        guard notchPanel == nil else { return }
        guard let screen = NSScreen.main else { return }

        metrics = NotchScreenMetrics.detect(for: screen)
        let panelFrame = panelRect(for: screen, metrics: metrics)

        let panel = NotchPanel(
            contentRect: panelFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Keep task progress above regular app windows. Below the menu bar by
        // default; the user can opt into an on-menu-bar placement (issue #1951)
        // which raises the level above the menu-bar window.
        panel.level = basePanelLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        // Transient overlay; nothing to restore.
        panel.isRestorable = false

        // Pass-through view so clicks outside the notch go to windows below.
        let passThroughView = NotchPassThroughView()
        passThroughView.frame = panel.contentView?.bounds ?? .zero
        passThroughView.autoresizingMask = [.width, .height]

        // Host the SwiftUI NotchContentView
        let content = NotchContentView()
        let hosting = NSHostingView(rootView: content)
        hosting.frame = passThroughView.bounds
        hosting.autoresizingMask = [.width, .height]

        passThroughView.addSubview(hosting)
        panel.contentView = passThroughView

        self.notchPanel = panel
        self.hostingView = hosting

        panel.orderFrontRegardless()

        // SwiftUI `keyboardShortcut` does not reliably receive commands from
        // a borderless non-activating panel. Monitor key events while this
        // panel is key and translate the documented ⌘← / ⌘→ commands into
        // local navigation notifications. Returning nil consumes the event,
        // preventing the focused editor from also moving its caret.
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, self.notchPanel?.isKeyWindow == true else { return event }
            let notification: Notification.Name
            switch Self.sessionNavigationDirection(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags
            ) {
            case .previous:
                notification = Self.navigateToPreviousSessionNotification
            case .next:
                notification = Self.navigateToNextSessionNotification
            case nil:
                return event
            }
            NotificationCenter.default.post(name: notification, object: nil)
            return nil
        }

        // Screen change observer
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Follow the active chat window's screen
        ChatWindowManager.shared.$lastFocusedWindowId
            .sink { [weak self] windowId in
                self?.updatePanelScreen(forWindowId: windowId)
            }
            .store(in: &cancellables)

        // Expand panel to full screen while an alert is active so the
        // dimming overlay covers the entire display instead of just 600x500.
        ThemedAlertCenter.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncAlertExpansion()
            }
            .store(in: &cancellables)

        print(
            "[Osaurus] Notch window controller setup on screen: \(screen.localizedName) (notch: \(metrics.hasHardwareNotch), w: \(metrics.notchWidth), h: \(metrics.notchHeight))"
        )
    }

    /// Teardown the notch window.
    public func teardown() {
        NotificationCenter.default.removeObserver(self)
        cancellables.removeAll()
        screenChangeDebounce?.cancel()
        screenChangeDebounce = nil
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
        }
        notchPanel?.close()
        notchPanel = nil
        hostingView = nil
    }

    /// Give inline notch controls a real key window before SwiftUI asks an
    /// `NSTextField` to become first responder. A borderless `NSPanel`
    /// normally refuses key status; `NotchPanel.canBecomeKey` opts in while
    /// `.nonactivatingPanel` still prevents a quick reply from pulling the
    /// whole app to the foreground.
    public func prepareForTextInput() {
        guard let panel = notchPanel else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - Private

    /// `didChangeScreenParametersNotification` is delivered synchronously inside
    /// the window server's display-reconfigure callout, and macOS posts it
    /// several times per reconfigure. Repositioning immediately performs
    /// window-server round-trips (`NotchScreenMetrics.detect`, `setFrame`) that
    /// can block in `mach_msg` for seconds while the server is mid-reconfigure
    /// (Sentry APPLE-MACOS-YC / -YH / -YK). Debounce so the work runs once,
    /// after the reconfiguration burst settles.
    @objc private func screenDidChange() {
        screenChangeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.handleScreenChange()
        }
        screenChangeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func handleScreenChange() {
        updatePanelScreen(forWindowId: ChatWindowManager.shared.lastFocusedWindowId)
        // Re-apply alert expansion now that the screen set changed. If a prior
        // `syncAlertExpansion` bailed because no display was attached, the panel
        // frame and `isExpandedForAlert` may not match the live alert state;
        // running it here resizes against the now-available screen.
        syncAlertExpansion()
    }

    private func updatePanelScreen(forWindowId windowId: UUID?) {
        guard let panel = notchPanel else { return }

        let targetScreen: NSScreen
        if let windowId = windowId,
            let chatWindow = ChatWindowManager.shared.getNSWindow(id: windowId),
            let windowScreen = chatWindow.screen
        {
            targetScreen = windowScreen
        } else if let fallback = NSScreen.main ?? NSScreen.screens.first {
            targetScreen = fallback
        } else {
            // No attached display (headless / all screens detached). Nothing
            // to reposition onto; bail rather than trap on `.first!`.
            return
        }

        let newMetrics = NotchScreenMetrics.detect(for: targetScreen)
        if metrics != newMetrics {
            metrics = newMetrics
        }

        // Don't shrink back to notch size while an alert is covering the screen.
        guard !isExpandedForAlert else { return }

        let newFrame = panelRect(for: targetScreen, metrics: newMetrics)
        if panel.frame != newFrame {
            panel.setFrame(newFrame, display: true)
        }
    }

    private func syncAlertExpansion() {
        guard let panel = notchPanel else { return }
        let alertActive = ThemedAlertCenter.shared.active(for: .notchOverlay) != nil

        guard let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            // No attached display; nothing to resize against. Leave
            // `isExpandedForAlert` unchanged so the panel frame and the flag
            // stay in sync — otherwise flipping it here would make the guard
            // above short-circuit once a display reappears, leaving the panel
            // stuck at the wrong size. We'll retry on the next sync.
            return
        }
        let screenMetrics = NotchScreenMetrics.detect(for: screen)
        let overMenuBar = NotchOverlayPlacement.resolved(for: screenMetrics) == .onMenuBar
        let targetFrame =
            alertActive
            ? screen.frame
            : panelRect(for: screen, metrics: screenMetrics)
        let targetLevel = alertActive ? Self.alertPanelLevel : basePanelLevel
        let targetPadding =
            alertActive
            ? NotchPanelPlacement.alertContentTopPadding(
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                overMenuBar: overMenuBar
            )
            : 0

        if panel.level != targetLevel {
            panel.level = targetLevel
        }
        if alertContentTopPadding != targetPadding {
            alertContentTopPadding = targetPadding
        }
        if panel.frame != targetFrame {
            panel.setFrame(targetFrame, display: true)
        }
        isExpandedForAlert = alertActive
    }

    /// Panel positioned at the top of the usable display area, below the menu
    /// bar — including the reveal strip of an auto-hidden menu bar, which
    /// `visibleFrame` does not reserve.
    ///
    /// Takes already-detected metrics so callers don't pay a second
    /// `NotchScreenMetrics.detect` window-server round-trip per pass.
    private func panelRect(for screen: NSScreen, metrics: NotchScreenMetrics) -> NSRect {
        NotchPanelPlacement.panelRect(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            preferredSize: CGSize(width: Self.panelWidth, height: Self.panelHeight),
            hiddenMenuBarInset: metrics.notchHeight,
            overMenuBar: NotchOverlayPlacement.resolved(for: metrics) == .onMenuBar
        ).frame
    }

    /// Non-alert window level for the panel. `.onMenuBar` placement must sit
    /// above the menu-bar window so the overlay actually renders on top of it;
    /// `.belowMenuBar` uses `.floating` so it stays above app windows but below
    /// the menu bar / status items.
    private var basePanelLevel: NSWindow.Level {
        NotchOverlayPlacement.resolved(for: metrics) == .onMenuBar ? Self.onMenuBarPanelLevel : .floating
    }

    /// Re-read the placement preference and reposition the panel. Called when
    /// the user flips the Chat settings toggle. No-ops while an alert has the
    /// panel expanded to full screen; the next `syncAlertExpansion` restores
    /// the correct level/frame once the alert clears.
    public func refreshPlacement() {
        guard notchPanel != nil, !isExpandedForAlert else { return }
        notchPanel?.level = basePanelLevel
        updatePanelScreen(forWindowId: ChatWindowManager.shared.lastFocusedWindowId)
    }

    private static let onMenuBarPanelLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
    private static let alertPanelLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
}

// MARK: - Notch Panel

/// Borderless non-activating panels do not become key by default, which
/// leaves embedded SwiftUI text fields visible but impossible to focus.
/// Opting into key status allows typing without changing the overlay's
/// transient, non-main-window behavior.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Pass-Through View

/// A view that passes mouse events through to windows below, except when hitting subviews.
private final class NotchPassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result === self ? nil : result
    }

    override var acceptsFirstResponder: Bool { false }
}
