//
//  TranscriptionOverlayWindowService.swift
//  osaurus
//
//  Manages the floating NSPanel for Transcription Mode overlay.
//  The panel stays on top of all windows and remains visible
//  when the user is typing in other applications.
//

import AppKit
import SwiftUI

/// Service for managing the floating transcription overlay window
@MainActor
public final class TranscriptionOverlayWindowService: ObservableObject {
    public static let shared = TranscriptionOverlayWindowService()

    /// The floating panel
    private var panel: NSPanel?

    /// Hosting controller for the SwiftUI view
    private var hostingController: NSHostingController<AnyView>?

    /// Current audio level for the overlay
    @Published public var audioLevel: Float = 0

    /// Whether transcription is active
    @Published public var isActive: Bool = false

    /// Whether transcription output is being cleaned up by the LLM
    @Published public var isProcessing: Bool = false

    /// Callback when user presses Done
    public var onDone: (() -> Void)?

    /// Callback when user presses Cancel
    public var onCancel: (() -> Void)?

    private init() {}

    // MARK: - Public API

    /// Show the transcription overlay
    public func show() {
        if panel == nil {
            createPanel()
        }

        guard let panel = panel else { return }

        // Position at top-center of active screen
        positionPanel(panel)

        // Show the panel
        panel.orderFront(nil)
        isActive = true

        print("[TranscriptionOverlay] Showing overlay")
    }

    /// Hide the transcription overlay
    public func hide() {
        panel?.orderOut(nil)
        isActive = false
        isProcessing = false
        audioLevel = 0

        print("[TranscriptionOverlay] Hiding overlay")
    }

    /// Update the audio level displayed in the overlay
    public func updateAudioLevel(_ level: Float) {
        audioLevel = level
        updateView()
    }

    /// Update the processing state displayed in the overlay
    public func updateProcessing(_ processing: Bool) {
        guard isProcessing != processing else { return }
        isProcessing = processing
        updateView()
    }

    // MARK: - Private Helpers

    private func createPanel() {
        let panelSize = NSSize(width: 400, height: 120)
        let initialRect = NSRect(origin: .zero, size: panelSize)

        // Create panel with minimal chrome
        let panel = NSPanel(
            contentRect: initialRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Native window shadow traces a black silhouette around the clear, rounded
        // content. The SwiftUI view draws its own shadow, so disable the native one
        // (matches the toast/notch overlays).
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow

        // Create the SwiftUI view
        let overlayView = createOverlayView()
        let hostingController = NSHostingController(rootView: AnyView(overlayView))
        hostingController.view.frame = NSRect(origin: .zero, size: panelSize)
        // Ensure the hosting view's backing is transparent so nothing paints
        // behind the rounded SwiftUI content.
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor

        panel.contentViewController = hostingController

        self.panel = panel
        self.hostingController = hostingController
    }

    private func createOverlayView() -> some View {
        let config = SpeechConfigurationStore.load()
        // Show a Stop button whenever transcription won't stop on its own:
        // manual mode, or automatic mode with pause duration 0 (no auto-send).
        let showsStopButton =
            config.transcriptionStopMode == .manual
            || (config.transcriptionStopMode == .automatic && config.pauseDuration == 0)
        return TranscriptionOverlayView(
            audioLevel: audioLevel,
            isActive: isActive,
            isProcessing: isProcessing,
            showsStopButton: showsStopButton,
            onDone: { [weak self] in
                self?.onDone?()
            },
            onCancel: { [weak self] in
                self?.onCancel?()
            }
        )
        .environment(\.theme, ThemeManager.shared.currentTheme)
    }

    private func updateView() {
        // Update the view with new audio level
        let overlayView = createOverlayView()
        hostingController?.rootView = AnyView(overlayView)
    }

    private func positionPanel(_ panel: NSPanel) {
        // Find the screen where the mouse is (active screen)
        let mouseLocation = NSEvent.mouseLocation
        let activeScreen =
            NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main

        guard let screen = activeScreen else { return }

        // Position at bottom-center of the screen, above the Dock.
        let visibleFrame = screen.visibleFrame
        let panelSize = panel.frame.size

        let x = visibleFrame.origin.x + (visibleFrame.width - panelSize.width) / 2
        let y = visibleFrame.origin.y + 20

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
