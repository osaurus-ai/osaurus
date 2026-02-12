//
//  TranscriptionModeService.swift
//  osaurus
//
//  Main service for Transcription Mode.
//  Orchestrates hotkey handling, whisper transcription, keyboard simulation,
//  and the floating overlay UI.
//

import AppKit
import Combine
import Foundation

/// State of the transcription mode session
public enum TranscriptionModeState: Equatable {
    case idle
    case starting
    case transcribing
    case stopping
    case error(String)
}

/// Service that manages the Transcription Mode lifecycle
@MainActor
public final class TranscriptionModeService: ObservableObject {
    public static let shared = TranscriptionModeService()

    // MARK: - Published State

    /// Current state of transcription mode
    @Published public private(set) var state: TranscriptionModeState = .idle

    /// Whether transcription mode is enabled in settings
    @Published public private(set) var isEnabled: Bool = false

    /// Current configuration
    @Published public private(set) var configuration: TranscriptionConfiguration = .default

    // MARK: - Dependencies

    private let whisperService = WhisperKitService.shared
    private let keyboardService = KeyboardSimulationService.shared
    private let hotkeyManager = TranscriptionHotKeyManager.shared
    private let overlayService = TranscriptionOverlayWindowService.shared

    // MARK: - Private State

    /// Previously typed text (for diff-based typing)
    private var lastTypedText: String = ""

    /// Cancellables for Combine subscriptions
    private var cancellables = Set<AnyCancellable>()

    /// Global key monitor for Esc key
    private var escKeyMonitor: Any?

    private init() {
        loadConfiguration()
        setupOverlayCallbacks()
    }

    // MARK: - Public API

    /// Initialize the service and register hotkey if enabled
    public func initialize() {
        loadConfiguration()
        registerHotkeyIfNeeded()

        // Listen for configuration changes
        NotificationCenter.default.publisher(for: .transcriptionConfigurationChanged)
            .sink { [weak self] _ in
                self?.loadConfiguration()
                self?.registerHotkeyIfNeeded()
            }
            .store(in: &cancellables)
    }

    /// Toggle transcription mode (called by hotkey)
    public func toggle() {
        switch state {
        case .idle:
            startTranscription()
        case .transcribing:
            stopTranscription()
        case .starting, .stopping:
            // Ignore toggle while transitioning
            break
        case .error:
            // Reset and try again
            state = .idle
            startTranscription()
        }
    }

    /// Start transcription
    public func startTranscription() {
        guard state == .idle || state == .error("") else {
            print("[TranscriptionMode] Cannot start: already in state \(state)")
            return
        }

        // Check accessibility permission
        keyboardService.checkAccessibilityPermission()
        guard keyboardService.hasAccessibilityPermission else {
            state = .error("Accessibility permission required")
            keyboardService.requestAccessibilityPermission()
            return
        }

        // Check if model is available
        guard whisperService.isModelLoaded || WhisperModelManager.shared.selectedModel != nil else {
            state = .error("No Whisper model available")
            return
        }

        state = .starting
        lastTypedText = ""

        // Show overlay
        overlayService.show()

        // Start Esc key monitoring
        startEscKeyMonitoring()

        // Start whisper transcription
        Task {
            do {
                try await whisperService.startStreamingTranscription()
                state = .transcribing

                // Subscribe to transcription updates
                subscribeToTranscriptionUpdates()

                print("[TranscriptionMode] Started transcription")
            } catch {
                state = .error(error.localizedDescription)
                overlayService.hide()
                stopEscKeyMonitoring()
                print("[TranscriptionMode] Failed to start: \(error)")
            }
        }
    }

    /// Stop transcription and finalize
    public func stopTranscription() {
        guard state == .transcribing || state == .starting else { return }

        state = .stopping

        // Stop Esc key monitoring
        stopEscKeyMonitoring()

        // Unsubscribe from updates
        cancellables.removeAll()

        // Re-add configuration listener
        NotificationCenter.default.publisher(for: .transcriptionConfigurationChanged)
            .sink { [weak self] _ in
                self?.loadConfiguration()
                self?.registerHotkeyIfNeeded()
            }
            .store(in: &cancellables)

        // Stop whisper
        Task {
            _ = await whisperService.stopStreamingTranscription()
            whisperService.clearTranscription()

            // Hide overlay
            overlayService.hide()

            // Reset state
            lastTypedText = ""
            state = .idle

            print("[TranscriptionMode] Stopped transcription")
        }
    }

    /// Cancel transcription without typing remaining text
    public func cancelTranscription() {
        stopTranscription()
    }

    // MARK: - Private Helpers

    private func loadConfiguration() {
        configuration = TranscriptionConfigurationStore.load()
        isEnabled = configuration.transcriptionModeEnabled
    }

    private func registerHotkeyIfNeeded() {
        if isEnabled, let hotkey = configuration.hotkey {
            hotkeyManager.register(hotkey: hotkey) { [weak self] in
                Task { @MainActor in
                    self?.toggle()
                }
            }
            print("[TranscriptionMode] Hotkey registered: \(hotkey.displayString)")
        } else {
            hotkeyManager.unregister()
            print("[TranscriptionMode] Hotkey unregistered")
        }
    }

    private func setupOverlayCallbacks() {
        overlayService.onDone = { [weak self] in
            self?.stopTranscription()
        }
        overlayService.onCancel = { [weak self] in
            self?.cancelTranscription()
        }
    }

    private func subscribeToTranscriptionUpdates() {
        // Subscribe to current transcription changes
        whisperService.$currentTranscription
            .sink { [weak self] _ in
                self?.handleTranscriptionUpdate()
            }
            .store(in: &cancellables)

        // Subscribe to confirmed transcription changes
        whisperService.$confirmedTranscription
            .sink { [weak self] _ in
                self?.handleTranscriptionUpdate()
            }
            .store(in: &cancellables)

        // Subscribe to audio level for overlay
        whisperService.$audioLevel
            .sink { [weak self] level in
                self?.overlayService.updateAudioLevel(level)
            }
            .store(in: &cancellables)
    }

    private func handleTranscriptionUpdate() {
        guard state == .transcribing else { return }

        // Get the full current transcription
        let fullText: String
        if whisperService.confirmedTranscription.isEmpty {
            fullText = whisperService.currentTranscription
        } else if whisperService.currentTranscription.isEmpty {
            fullText = whisperService.confirmedTranscription
        } else {
            fullText = whisperService.confirmedTranscription + " " + whisperService.currentTranscription
        }

        // Calculate what needs to be typed
        typeNewText(fullText)
    }

    private func typeNewText(_ fullText: String) {
        // If the new text starts with what we've already typed, just type the new part
        if fullText.hasPrefix(lastTypedText) {
            let newPart = String(fullText.dropFirst(lastTypedText.count))
            if !newPart.isEmpty {
                keyboardService.typeText(newPart)
                lastTypedText = fullText
            }
        } else if lastTypedText.hasPrefix(fullText) {
            // Text was reduced (correction) - delete the difference
            let charsToDelete = lastTypedText.count - fullText.count
            if charsToDelete > 0 {
                keyboardService.typeBackspace(count: charsToDelete)
                lastTypedText = fullText
            }
        } else {
            // Text diverged - find common prefix and correct
            let commonPrefixLength = zip(lastTypedText, fullText).prefix(while: { $0 == $1 }).count
            let charsToDelete = lastTypedText.count - commonPrefixLength
            let newPart = String(fullText.dropFirst(commonPrefixLength))

            if charsToDelete > 0 {
                keyboardService.typeBackspace(count: charsToDelete)
            }
            if !newPart.isEmpty {
                keyboardService.typeText(newPart)
            }
            lastTypedText = fullText
        }
    }

    // MARK: - Esc Key Monitoring

    private func startEscKeyMonitoring() {
        stopEscKeyMonitoring()

        // Monitor for Esc key globally to cancel/stop transcription
        escKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Esc key code is 53
            if event.keyCode == 53 {
                Task { @MainActor in
                    self?.cancelTranscription()
                }
            }
        }
    }

    private func stopEscKeyMonitoring() {
        if let monitor = escKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escKeyMonitor = nil
        }
    }
}
