//
//  TranscriptionModeService.swift
//  osaurus
//
//  Main service for Transcription Mode.
//  Orchestrates hotkey handling, speech transcription, keyboard simulation,
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

    private let speechService = SpeechService.shared
    private let keyboardService = KeyboardSimulationService.shared
    private let hotkeyManager = TranscriptionHotKeyManager.shared
    private let overlayService = TranscriptionOverlayWindowService.shared

    // MARK: - Private State

    private var configCancellables = Set<AnyCancellable>()
    private var escKeyMonitor: Any?

    private init() {
        loadConfiguration()
        setupOverlayCallbacks()
        observeStateForOverlay()
    }

    // MARK: - Public API

    public func initialize() {
        loadConfiguration()
        registerHotkeyIfNeeded()

        NotificationCenter.default.publisher(for: .transcriptionConfigurationChanged)
            .sink { [weak self] _ in
                self?.loadConfiguration()
                self?.registerHotkeyIfNeeded()
            }
            .store(in: &configCancellables)
    }

    public func toggle() {
        switch state {
        case .idle:
            startTranscription()
        case .transcribing:
            stopTranscription()
        case .starting, .stopping:
            break
        case .error:
            state = .idle
            startTranscription()
        }
    }

    public func startTranscription() {
        switch state {
        case .idle, .error: break
        default:
            print("[TranscriptionMode] Cannot start: already in state \(state)")
            return
        }

        keyboardService.checkAccessibilityPermission()
        guard keyboardService.hasAccessibilityPermission else {
            state = .error("Accessibility permission required")
            keyboardService.requestAccessibilityPermission()
            return
        }

        guard speechService.isModelLoaded || SpeechModelManager.shared.selectedModel != nil else {
            state = .error("No speech model available")
            return
        }

        state = .starting
        overlayService.show()
        startEscKeyMonitoring()

        Task {
            do {
                try await speechService.startStreamingTranscription()
                state = .transcribing
                subscribeToAudioLevel()
                print("[TranscriptionMode] Started transcription")
            } catch {
                state = .error(error.localizedDescription)
                overlayService.hide()
                stopEscKeyMonitoring()
                print("[TranscriptionMode] Failed to start: \(error)")
            }
        }
    }

    public func stopTranscription() {
        guard state == .transcribing || state == .starting else { return }

        state = .stopping
        stopEscKeyMonitoring()

        Task {
            _ = await speechService.stopStreamingTranscription()

            let rawText = speechService.confirmedTranscription
            speechService.clearTranscription()

            if !rawText.isEmpty {
                let finalText = await TranscriptionCleanupService.shared.clean(rawText)
                keyboardService.pasteText(finalText)
            }

            overlayService.hide()
            state = .idle
            print("[TranscriptionMode] Stopped transcription")
        }
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
            self?.stopTranscription()
        }
    }

    private func observeStateForOverlay() {
        $state
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                self?.overlayService.updateProcessing(newState == .stopping)
            }
            .store(in: &configCancellables)
    }

    private var audioLevelCancellable: AnyCancellable?

    private func subscribeToAudioLevel() {
        audioLevelCancellable = speechService.$audioLevel
            .sink { [weak self] level in
                self?.overlayService.updateAudioLevel(level)
            }
    }

    // MARK: - Esc Key Monitoring

    private func startEscKeyMonitoring() {
        stopEscKeyMonitoring()

        escKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {  // Esc
                Task { @MainActor in
                    self?.stopTranscription()
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
