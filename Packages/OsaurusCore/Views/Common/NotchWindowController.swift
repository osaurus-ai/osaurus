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
/// `below` (default) keeps the overlay inside the visible frame so it never
/// covers the menu bar / system status controls (issue that motivated #1874).
/// `onMenuBar` anchors it to the physical top of the display so it sits on the
/// menu bar for users who prefer that (issue #1951).
public enum NotchOverlayPlacement: String {
    case belowMenuBar
    case onMenuBar

    /// `UserDefaults` key backing the Chat settings toggle. Read by the
    /// controller each time it repositions the panel.
    public static let defaultsKey = "notchOverlayPlacement"

    /// Current preference, defaulting to `.belowMenuBar` when unset.
    public static var current: NotchOverlayPlacement {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(NotchOverlayPlacement.init) ?? .belowMenuBar
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
        visibleFrame: CGRect
    ) -> CGFloat {
        guard !visibleFrame.isEmpty else { return 0 }
        return max(0, screenFrame.maxY - visibleFrame.maxY)
    }
}

// MARK: - Notch Window Controller

/// Displays the notch background task indicator at the top center of the screen,
/// inside the screen's visible frame so task progress never covers the menu bar.
@MainActor
public final class NotchWindowController: NSObject, ObservableObject {
    public static let shared = NotchWindowController()

    private var notchPanel: NSPanel?
    private var hostingView: NSHostingView<NotchContentView>?
    private var cancellables = Set<AnyCancellable>()
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

    // MARK: - Public API

    /// Setup the notch overlay window.
    public func setup() {
        guard notchPanel == nil else { return }
        guard let screen = NSScreen.main else { return }

        metrics = NotchScreenMetrics.detect(for: screen)
        let panelFrame = panelRect(for: screen, metrics: metrics)

        let panel = NSPanel(
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
        notchPanel?.close()
        notchPanel = nil
        hostingView = nil
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
        let targetFrame =
            alertActive
            ? screen.frame
            : panelRect(for: screen, metrics: NotchScreenMetrics.detect(for: screen))
        let targetLevel = alertActive ? Self.alertPanelLevel : basePanelLevel
        let targetPadding = alertActive
            ? NotchPanelPlacement.alertContentTopPadding(
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame
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
            overMenuBar: NotchOverlayPlacement.current == .onMenuBar
        ).frame
    }

    /// Non-alert window level for the panel. `.onMenuBar` placement must sit
    /// above the menu-bar window so the overlay actually renders on top of it;
    /// `.belowMenuBar` uses `.floating` so it stays above app windows but below
    /// the menu bar / status items.
    private var basePanelLevel: NSWindow.Level {
        NotchOverlayPlacement.current == .onMenuBar ? Self.onMenuBarPanelLevel : .floating
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

// MARK: - Pass-Through View

/// A view that passes mouse events through to windows below, except when hitting subviews.
private final class NotchPassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result === self ? nil : result
    }

    override var acceptsFirstResponder: Bool { false }
}
