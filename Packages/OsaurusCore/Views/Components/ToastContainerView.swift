//
//  ToastContainerView.swift
//  osaurus
//
//  Container view that manages toast positioning, stacking, and animations.
//  Add this as an overlay to windows that need toast support.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Pass-Through View

/// A view that passes mouse events through to windows below, except when hitting subviews
final class ToastPassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Check if any subview wants to handle the event
        let result = super.hitTest(point)
        // Only return a hit if it's a subview, not this view itself
        return result === self ? nil : result
    }

    override var acceptsFirstResponder: Bool { false }
}

// MARK: - Toast Container View

/// Container that positions and animates toasts based on configuration
public struct ToastContainerView: View {
    @StateObject private var toastManager = ToastManager.shared
    @Environment(\.theme) private var theme

    public init() {}

    public var body: some View {
        ZStack {
            // Transparent background that passes through mouse events
            Color.clear
                .allowsHitTesting(false)

            // Position toasts based on configuration
            toastStack
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                .padding(edgePadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toast Stack

    @ViewBuilder
    private var toastStack: some View {
        VStack(spacing: 10) {
            // Order toasts based on position (newest on top for top positions, newest on bottom for bottom)
            ForEach(orderedToasts) { toast in
                ToastView(
                    toast: toast,
                    onDismiss: {
                        toastManager.dismiss(id: toast.id)
                    },
                    onAction: {
                        toastManager.triggerAction(for: toast)
                    }
                )
                .transition(toastTransition)
                .id(toast.id)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: toastManager.toasts.map { $0.id })
    }

    // MARK: - Computed Properties

    /// Toasts ordered based on position (for proper stacking visual)
    private var orderedToasts: [Toast] {
        let position = toastManager.configuration.position
        let toasts = toastManager.toasts

        // For top positions, newest should appear at top (so reverse order)
        // For bottom positions, newest should appear at bottom (natural order)
        if position.isTop {
            return toasts.reversed()
        } else {
            return toasts
        }
    }

    /// Alignment based on toast position
    private var alignment: Alignment {
        let position = toastManager.configuration.position

        switch position {
        case .topLeft:
            return .topLeading
        case .topCenter:
            return .top
        case .topRight:
            return .topTrailing
        case .bottomLeft:
            return .bottomLeading
        case .bottomCenter:
            return .bottom
        case .bottomRight:
            return .bottomTrailing
        }
    }

    /// Edge padding based on position
    private var edgePadding: EdgeInsets {
        let position = toastManager.configuration.position
        let padding: CGFloat = 20

        switch position {
        case .topLeft:
            return EdgeInsets(top: padding, leading: padding, bottom: 0, trailing: 0)
        case .topCenter:
            return EdgeInsets(top: padding, leading: 0, bottom: 0, trailing: 0)
        case .topRight:
            return EdgeInsets(top: padding, leading: 0, bottom: 0, trailing: padding)
        case .bottomLeft:
            return EdgeInsets(top: 0, leading: padding, bottom: padding, trailing: 0)
        case .bottomCenter:
            return EdgeInsets(top: 0, leading: 0, bottom: padding, trailing: 0)
        case .bottomRight:
            return EdgeInsets(top: 0, leading: 0, bottom: padding, trailing: padding)
        }
    }

    /// Transition animation for toasts
    private var toastTransition: AnyTransition {
        let position = toastManager.configuration.position

        let slideEdge = position.slideEdge
        let slide = AnyTransition.move(edge: slideEdge)
        let opacity = AnyTransition.opacity
        let scale = AnyTransition.scale(scale: 0.9)

        return slide.combined(with: opacity).combined(with: scale)
    }
}

// MARK: - Toast Overlay Modifier

/// View modifier for easily adding toast support to any view
public struct ToastOverlayModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .overlay(
                ToastContainerView()
            )
    }
}

extension View {
    /// Add toast notification support to this view
    public func withToastOverlay() -> some View {
        modifier(ToastOverlayModifier())
    }
}

// MARK: - Global Toast Window

/// A separate window for displaying toasts at the system level (above all app windows)
@MainActor
public final class ToastWindowController: NSObject {
    public static let shared = ToastWindowController()

    private var toastPanel: NSPanel?
    private var hostingView: NSHostingView<ToastOverlayWindowContent>?
    private var cancellables = Set<AnyCancellable>()

    private override init() {
        super.init()
    }

    /// Setup the toast overlay window
    public func setup() {
        guard toastPanel == nil else { return }

        // Get the main screen bounds
        guard let screen = NSScreen.main else { return }

        // Create a panel (NSPanel is better for floating utility windows)
        let panel = NSPanel(
            contentRect: screen.visibleFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar  // High level to appear above most windows
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        // Create a pass-through content view that only responds to hits on subviews
        let passThroughView = ToastPassThroughView()
        passThroughView.frame = panel.contentView?.bounds ?? .zero
        passThroughView.autoresizingMask = [.width, .height]

        // Create hosting view with toast content
        let content = ToastOverlayWindowContent()
        let hosting = NSHostingView(rootView: content)
        hosting.frame = passThroughView.bounds
        hosting.autoresizingMask = [.width, .height]

        passThroughView.addSubview(hosting)
        panel.contentView = passThroughView
        self.toastPanel = panel
        self.hostingView = hosting

        // Show the panel
        panel.orderFrontRegardless()

        // Observe screen changes to resize window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Observe window focus changes to move toast panel to active window's screen
        ChatWindowManager.shared.$lastFocusedWindowId
            .sink { [weak self] windowId in
                self?.updatePanelScreen(forWindowId: windowId)
            }
            .store(in: &cancellables)

        print("[Osaurus] Toast window controller setup complete on screen: \(screen.localizedName)")
    }

    /// Teardown the toast window
    public func teardown() {
        NotificationCenter.default.removeObserver(self)
        cancellables.removeAll()
        toastPanel?.close()
        toastPanel = nil
        hostingView = nil
    }

    @objc private func screenDidChange() {
        updatePanelScreen(forWindowId: ChatWindowManager.shared.lastFocusedWindowId)
    }

    /// Update the toast panel to display on the screen containing the active chat window
    private func updatePanelScreen(forWindowId windowId: UUID?) {
        guard let panel = toastPanel else { return }

        // Get screen from active chat window, fallback to main screen
        let targetScreen: NSScreen
        if let windowId = windowId,
            let chatWindow = ChatWindowManager.shared.getNSWindow(id: windowId),
            let windowScreen = chatWindow.screen
        {
            targetScreen = windowScreen
        } else {
            targetScreen = NSScreen.main ?? NSScreen.screens.first!
        }

        // Only update if the screen actually changed
        if panel.frame != targetScreen.visibleFrame {
            panel.setFrame(targetScreen.visibleFrame, display: true)
            print("[Osaurus] Toast panel moved to screen: \(targetScreen.localizedName)")
        }
    }
}

/// Content view for the toast overlay window
struct ToastOverlayWindowContent: View {
    @StateObject private var themeManager = ThemeManager.shared

    var body: some View {
        ToastContainerView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.theme, themeManager.currentTheme)
    }
}

// MARK: - Preview

#if DEBUG
    struct ToastContainerView_Previews: PreviewProvider {
        static var previews: some View {
            ZStack {
                Color.black.opacity(0.8)
                    .ignoresSafeArea()

                ToastContainerView()
            }
            .frame(width: 800, height: 600)
        }
    }
#endif
