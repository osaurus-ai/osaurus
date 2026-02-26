//
//  NotchWindowController.swift
//  osaurus
//
//  Manages the dedicated NSPanel for the notch UI.
//  Positions the panel at the very top of the screen, flush with the
//  display edge, and detects hardware notch dimensions.
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

// MARK: - Notch Window Controller

/// Displays the notch background task indicator at the top center of the screen,
/// flush with the display's top edge so it blends with the hardware notch.
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
        // Sit above the menu bar so the notch overlaps the bezel area
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false

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
    }

    private func updatePanelScreen(forWindowId windowId: UUID?) {
        guard let panel = notchPanel else { return }

        let targetScreen: NSScreen
        if let windowId = windowId,
            let chatWindow = ChatWindowManager.shared.getNSWindow(id: windowId),
            let windowScreen = chatWindow.screen
        {
            targetScreen = windowScreen
        } else {
            targetScreen = NSScreen.main ?? NSScreen.screens.first!
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

        guard alertActive != isExpandedForAlert else { return }
        isExpandedForAlert = alertActive

        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first!
        let targetFrame = alertActive ? screen.frame : panelRect(for: screen)
        panel.setFrame(targetFrame, display: true)
    }

    /// Panel positioned at the very top of the screen (using full frame, not visibleFrame).
    private func panelRect(for screen: NSScreen) -> NSRect {
        let screenFrame = screen.frame
        let x = screenFrame.origin.x + (screenFrame.width / 2) - Self.panelWidth / 2
        let y = screenFrame.origin.y + screenFrame.height - Self.panelHeight
        return NSRect(x: x, y: y, width: Self.panelWidth, height: Self.panelHeight)
    }
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
