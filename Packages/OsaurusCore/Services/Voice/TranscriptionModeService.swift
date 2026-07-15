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

    /// Shared chat voice-input settings; Transcription Mode reuses its
    /// stop-mode / pause-duration so both behave the same way.
    private var speechConfig: SpeechConfiguration = .default

    /// Drives automatic (hands-free) stop via silence detection
    private var silenceTimer: Timer?
    private var lastSpeechActivityTime: Date = .distantFuture
    private var lastConfirmedLength: Int = 0

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

        // Pick up the latest shared voice-input settings (stop mode / pause
        // duration) so a change made just before starting takes effect.
        speechConfig = SpeechConfigurationStore.load()

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
                // The user may have cancelled while the stream was starting up.
                // If we're no longer in `.starting`, a stop is already in flight
                // (or done) — don't resurrect the session by subscribing again,
                // which would leave the audio stream and timers running.
                guard state == .starting else {
                    _ = await speechService.stopStreamingTranscription()
                    return
                }
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

    /// Stops transcription. When `discard` is true the captured text is thrown
    /// away (cancel); otherwise it is cleaned up and inserted (done).
    public func stopTranscription(discard: Bool = false) {
        guard state == .transcribing || state == .starting else { return }

        // A cancel has nothing to clean up, so dismiss the overlay right away
        // instead of showing a "Processing" state while the stream tears down.
        if discard {
            overlayService.hide()
        }

        state = .stopping
        stopEscKeyMonitoring()
        stopSilenceMonitoring()
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        Task {
            _ = await speechService.stopStreamingTranscription()

            let rawText = TranscriptionTextNormalizer.combined([
                speechService.confirmedTranscription,
                speechService.currentTranscription,
            ])
            speechService.clearTranscription()

            if !discard, !rawText.isEmpty {
                let cleanedText =
                    SpeechConfigurationStore.load().postProcessTranscription
                    ? await TranscriptionCleanupService.shared.clean(rawText)
                    : rawText
                let finalText = TranscriptionTextNormalizer.visibleText(cleanedText)
                if finalText.isEmpty {
                    showNoSpeechDetectedFeedback()
                } else {
                    keyboardService.pasteText(finalText)
                }
            } else if !discard {
                showNoSpeechDetectedFeedback()
            }

            overlayService.hide()
            if case .error = state {
                // Keep the error visible in Status/Settings until the next toggle.
            } else {
                state = .idle
            }
            print("[TranscriptionMode] Stopped transcription (discard: \(discard))")
        }
    }

    // MARK: - Private Helpers

    private func loadConfiguration() {
        configuration = TranscriptionConfigurationStore.load()
        isEnabled = configuration.transcriptionModeEnabled
        speechConfig = SpeechConfigurationStore.load()
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
            self?.stopTranscription(discard: true)
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
        startSilenceMonitoring()
    }

    // MARK: - Automatic Stop (Silence Detection)

    /// Starts watching for a speech pause so transcription can finalize
    /// hands-free when the shared stop mode is `.automatic`.
    private func startSilenceMonitoring() {
        stopSilenceMonitoring()
        lastSpeechActivityTime = .distantFuture
        lastConfirmedLength = 0

        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForAutoStop()
            }
        }
        silenceTimer = timer
    }

    private func stopSilenceMonitoring() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    /// Mirrors `FloatingInputCard.checkForPause`: once the user pauses for
    /// `pauseDuration` seconds with content captured, stop and paste.
    private func checkForAutoStop() {
        guard state == .transcribing else { return }
        // Honor the shared Voice Input setting. pauseDuration == 0 means
        // "auto-send disabled" — keep manual (Esc / Done) behavior.
        guard speechConfig.transcriptionStopMode == .automatic,
            speechConfig.pauseDuration > 0
        else { return }

        // Reset the pause timer on any real voice activity.
        let confirmedText = TranscriptionTextNormalizer.visibleText(speechService.confirmedTranscription)
        let currentText = TranscriptionTextNormalizer.visibleText(speechService.currentTranscription)
        let confirmedLength = confirmedText.count
        let hasNewConfirmedText = confirmedLength > lastConfirmedLength
        if hasNewConfirmedText { lastConfirmedLength = confirmedLength }
        if speechService.isSpeechDetected || hasNewConfirmedText
            || !currentText.isEmpty
        {
            lastSpeechActivityTime = Date()
        }

        // Only auto-stop once we've actually captured something to paste.
        let hasContent =
            !confirmedText.isEmpty
            || !currentText.isEmpty
        guard hasContent else { return }

        let silenceDuration = Date().timeIntervalSince(lastSpeechActivityTime)
        if silenceDuration >= speechConfig.pauseDuration {
            print(
                "[TranscriptionMode] Auto-stop after \(String(format: "%.1f", silenceDuration))s silence"
            )
            stopTranscription()
        }
    }

    private func showNoSpeechDetectedFeedback() {
        state = .error(L("No speech detected"))
        ToastManager.shared.infoLocalized(
            "No Speech Detected",
            message: "Nothing was inserted."
        )
    }

    // MARK: - Esc Key Monitoring

    private func startEscKeyMonitoring() {
        stopEscKeyMonitoring()

        escKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {  // Esc
                Task { @MainActor in
                    self?.stopTranscription(discard: true)
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
