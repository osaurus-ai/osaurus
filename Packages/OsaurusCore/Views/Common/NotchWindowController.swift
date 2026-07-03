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

// MARK: - Notch Panel Placement

struct NotchPanelPlacement: Equatable {
    let frame: CGRect

    static func panelRect(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        preferredSize: CGSize
    ) -> NotchPanelPlacement {
        let safeFrame = visibleFrame.isEmpty ? screenFrame : visibleFrame
        let width = min(preferredSize.width, max(1, safeFrame.width))
        let height = min(preferredSize.height, max(1, safeFrame.height))
        let centeredX = safeFrame.midX - width / 2
        let minX = safeFrame.minX
        let maxX = safeFrame.maxX - width
        let x = min(max(centeredX, minX), maxX)
        let y = safeFrame.maxY - height

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
        let panelFrame = panelRect(for: screen)

        let panel = NSPanel(
            contentRect: panelFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Keep task progress above regular app windows without covering macOS
        // menu-bar/status-item windows.
        panel.level = .floating
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
        notchPanel?.close()
        notchPanel = nil
        hostingView = nil
    }

    // MARK: - Private

    @objc private func screenDidChange() {
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

        let newFrame = panelRect(for: targetScreen)
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
        let targetFrame = alertActive ? screen.frame : panelRect(for: screen)
        let targetLevel = alertActive ? Self.alertPanelLevel : NSWindow.Level.floating
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

    /// Panel positioned at the top of the usable display area, below the menu bar.
    private func panelRect(for screen: NSScreen) -> NSRect {
        NotchPanelPlacement.panelRect(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            preferredSize: CGSize(width: Self.panelWidth, height: Self.panelHeight)
        ).frame
    }

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
