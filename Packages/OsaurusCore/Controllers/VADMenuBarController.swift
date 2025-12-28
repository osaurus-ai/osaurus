//
//  VADMenuBarController.swift
//  osaurus
//
//  Menu bar status item for VAD mode indicator.
//  Shows listening status and provides quick controls.
//

import AppKit
import Combine
import SwiftUI

/// Menu bar controller for VAD status indicator
@MainActor
public final class VADMenuBarController: ObservableObject {
    public static let shared = VADMenuBarController()

    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var pulseTimer: Timer?

    @Published public private(set) var isVisible: Bool = false

    // MARK: - Initialization

    private init() {
        setupObservers()
    }

    // MARK: - Public Methods

    /// Show the menu bar item
    public func show() {
        guard statusItem == nil else { return }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "VAD Mode")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked)
        }

        updateStatusItemAppearance()
        setupMenu()

        isVisible = true
    }

    /// Hide the menu bar item
    public func hide() {
        guard let item = statusItem else { return }

        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        stopPulseAnimation()

        isVisible = false
    }

    /// Update visibility based on configuration
    public func updateVisibility() {
        let config = VADConfigurationStore.load()

        if config.vadModeEnabled && config.menuBarVisible {
            show()
        } else {
            hide()
        }
    }

    // MARK: - Private Methods

    private func setupObservers() {
        // Observe VAD service state changes
        VADService.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusItemAppearance()
            }
            .store(in: &cancellables)

        // Observe audio level for animation
        VADService.shared.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.updateAudioLevelIndicator(level)
            }
            .store(in: &cancellables)

        // Observe VAD configuration changes
        VADService.shared.$isEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                if enabled {
                    self?.updateVisibility()
                } else {
                    self?.hide()
                }
            }
            .store(in: &cancellables)
    }

    private func setupMenu() {
        let menu = NSMenu()

        // Status header
        let statusItem = NSMenuItem(title: "VAD Mode", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        // Toggle listening
        let toggleItem = NSMenuItem(
            title: VADService.shared.state == .listening ? "Stop Listening" : "Start Listening",
            action: #selector(toggleListening),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        // Open Osaurus
        let openItem = NSMenuItem(
            title: "Open Osaurus",
            action: #selector(openApp),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        // Voice Settings
        let settingsItem = NSMenuItem(
            title: "Voice Settings...",
            action: #selector(openVoiceSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        self.statusItem?.menu = menu
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }

        let state = VADService.shared.state

        switch state {
        case .listening:
            button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "VAD Listening")
            button.contentTintColor = .systemGreen
            startPulseAnimation()

        case .processing:
            button.image = NSImage(systemSymbolName: "ellipsis.circle.fill", accessibilityDescription: "VAD Processing")
            button.contentTintColor = .systemOrange
            stopPulseAnimation()

        case .error:
            button.image = NSImage(
                systemSymbolName: "exclamationmark.circle.fill",
                accessibilityDescription: "VAD Error"
            )
            button.contentTintColor = .systemRed
            stopPulseAnimation()

        default:
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "VAD Idle")
            button.contentTintColor = nil
            stopPulseAnimation()
        }

        button.image?.isTemplate = state != .listening && state != .processing && state != .error("")

        // Update menu items
        setupMenu()
    }

    private func updateAudioLevelIndicator(_ level: Float) {
        // Could animate the status item based on audio level
        // For now, just rely on pulse animation
    }

    private func startPulseAnimation() {
        guard pulseTimer == nil else { return }

        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, let button = self.statusItem?.button else { return }

                let currentAlpha = button.alphaValue
                let targetAlpha: CGFloat = currentAlpha < 0.9 ? 1.0 : 0.6

                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.4
                    button.alphaValue = targetAlpha
                }
            }
        }
    }

    private func stopPulseAnimation() {
        pulseTimer?.invalidate()
        pulseTimer = nil

        statusItem?.button?.alphaValue = 1.0
    }

    // MARK: - Actions

    @objc private func statusItemClicked() {
        // Show menu on click
    }

    @objc private func toggleListening() {
        Task {
            try? await VADService.shared.toggle()
        }
    }

    @objc private func openApp() {
        NSApp.activate(ignoringOtherApps: true)

        // Post notification to show main window
        NotificationCenter.default.post(
            name: NSNotification.Name("ShowMainWindow"),
            object: nil
        )
    }

    @objc private func openVoiceSettings() {
        NSApp.activate(ignoringOtherApps: true)

        // Post notification to show voice settings
        NotificationCenter.default.post(
            name: NSNotification.Name("ShowVoiceSettings"),
            object: nil
        )
    }
}

// MARK: - Menu Bar SwiftUI View (for popover if needed)

struct VADMenuBarPopover: View {
    @StateObject private var vadService = VADService.shared
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(statusColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("VAD Mode")
                        .font(.system(size: 14, weight: .semibold))
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            Divider()

            // Audio level
            if vadService.state == .listening {
                HStack(spacing: 8) {
                    Text("Audio Level")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    ProgressView(value: Double(vadService.audioLevel))
                        .progressViewStyle(.linear)
                }
            }

            // Last detection
            if let detection = vadService.lastDetection {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last: \(detection.personaName)")
                            .font(.system(size: 12, weight: .medium))
                        Text(detection.transcription)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Divider()

            // Controls
            HStack {
                Button(action: {
                    Task {
                        try? await vadService.toggle()
                    }
                }) {
                    Text(vadService.state == .listening ? "Stop" : "Start")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 240)
    }

    private var statusColor: Color {
        switch vadService.state {
        case .listening: return .green
        case .processing: return .orange
        case .error: return .red
        default: return .gray
        }
    }

    private var statusText: String {
        switch vadService.state {
        case .idle: return "Inactive"
        case .starting: return "Starting..."
        case .listening: return "Listening for wake words"
        case .processing: return "Processing speech..."
        case .error(let msg): return "Error: \(msg)"
        }
    }
}
