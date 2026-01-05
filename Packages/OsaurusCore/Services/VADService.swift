//
//  VADService.swift
//  osaurus
//
//  Always-on Voice Activity Detection service for wake-word persona activation.
//  Uses WhisperKitService for transcription to avoid audio conflicts.
//

import AVFoundation
import Combine
import Foundation
import os

/// Notification posted when a persona wake-word is detected
extension Notification.Name {
    public static let vadPersonaDetected = Notification.Name("vadPersonaDetected")
    public static let startVoiceInputInChat = Notification.Name("startVoiceInputInChat")
    public static let chatViewClosed = Notification.Name("chatViewClosed")
    public static let vadStartNewSession = Notification.Name("vadStartNewSession")
    public static let closeChatOverlay = Notification.Name("closeChatOverlay")
    public static let voiceConfigurationChanged = Notification.Name("voiceConfigurationChanged")
}

/// Result of a VAD detection
public struct VADDetectionResult: Sendable {
    public let personaId: UUID
    public let personaName: String
    public let confidence: Float
    public let transcription: String
}

/// VAD Service state
public enum VADServiceState: Equatable, Sendable {
    case idle
    case starting
    case listening
    case processing
    case error(String)
}

/// Always-on listening service for wake-word detection
/// Uses WhisperKitService's audio infrastructure to avoid conflicts
@MainActor
public final class VADService: ObservableObject {
    public static let shared = VADService()

    // MARK: - Published Properties

    @Published public private(set) var state: VADServiceState = .idle
    @Published public private(set) var audioLevel: Float = 0.0

    // MARK: - Private Properties

    private var isEnabled: Bool = false
    private var configuration: VADConfiguration = .default
    private var personaDetector: PersonaNameDetector?
    private var cancellables = Set<AnyCancellable>()
    private var whisperService: WhisperKitService { WhisperKitService.shared }

    // Debounce detection to avoid duplicate triggers
    private var lastDetectionTime: Date = .distantPast
    private let detectionCooldown: TimeInterval = 3.0  // Seconds before detecting same persona again

    // Accumulate transcription for better detection
    private var accumulatedTranscription: String = ""
    private var lastTranscriptionUpdate: Date = Date()
    private let transcriptionResetInterval: TimeInterval = 5.0  // Reset after silence

    private init() {
        loadConfiguration()
        setupObservers()
    }

    // MARK: - Public Methods

    /// Load configuration and update state
    public func loadConfiguration() {
        configuration = VADConfigurationStore.load()

        // Update persona detector with enabled personas
        personaDetector = PersonaNameDetector(
            enabledPersonaIds: configuration.enabledPersonaIds,
            customWakePhrase: configuration.customWakePhrase
        )

        print("[VADService] Loaded configuration with \(configuration.enabledPersonaIds.count) enabled personas")
    }

    /// Start VAD listening
    public func start() async throws {
        guard state != .listening else {
            print("[VADService] Already listening, skipping start")
            return
        }

        loadConfiguration()

        guard configuration.vadModeEnabled else {
            print("[VADService] VAD mode is not enabled")
            throw VADError.notEnabled
        }

        guard !configuration.enabledPersonaIds.isEmpty || !configuration.customWakePhrase.isEmpty else {
            print("[VADService] No personas enabled for VAD")
            throw VADError.noPersonasEnabled
        }

        print("[VADService] Starting with \(configuration.enabledPersonaIds.count) enabled personas")

        state = .starting

        // Ensure model is loaded
        if !whisperService.isModelLoaded {
            // Try to load the model
            guard let selectedModel = WhisperModelManager.shared.selectedModel else {
                state = .error("No model selected")
                throw VADError.noModelSelected
            }

            do {
                try await whisperService.loadModel(selectedModel.id)
            } catch {
                state = .error("Failed to load model: \(error.localizedDescription)")
                throw VADError.modelNotDownloaded
            }
        }

        // Start streaming transcription with keep-alive enabled
        do {
            // Enable keep-alive to prevent audio engine teardown during handoffs
            whisperService.keepAudioEngineAlive = true

            try await whisperService.startStreamingTranscription()
            state = .listening
            isEnabled = true
            accumulatedTranscription = ""
            print("[VADService] Started listening for wake words (keep-alive enabled)")
        } catch {
            whisperService.keepAudioEngineAlive = false
            state = .error(error.localizedDescription)
            throw error
        }
    }

    /// Stop VAD listening
    public func stop() async {
        guard state == .listening || state == .starting else { return }

        // Update state first to prevent auto-restart logic from triggering
        // when isRecording changes to false
        state = .idle
        isEnabled = false
        audioLevel = 0
        accumulatedTranscription = ""

        // Disable keep-alive and force stop to tear down audio engine
        whisperService.keepAudioEngineAlive = false
        _ = await whisperService.stopStreamingTranscription(force: true)
        whisperService.clearTranscription()

        print("[VADService] Stopped listening (keep-alive disabled)")
    }

    /// Pause VAD temporarily (e.g., when chat voice input is active or testing)
    public func pause() async {
        guard state == .listening || state == .starting else { return }
        print("[VADService] Pausing temporarily")

        // Update state first to prevent auto-restart logic from triggering
        state = .idle
        // Keep isEnabled = true so we know to resume later

        // NOTE: We do NOT set keepAudioEngineAlive = false here.
        // We want the engine to stay alive for handoff.

        // Stop streaming (will keep engine alive because keepAudioEngineAlive is true from start())
        _ = await whisperService.stopStreamingTranscription()
        whisperService.clearTranscription()

        print("[VADService] Paused - transcription stopped, ready for chat voice input")
    }

    // MARK: - Private Methods

    private func setupObservers() {
        // Observe configuration changes
        NotificationCenter.default.publisher(for: .voiceConfigurationChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadConfiguration()
            }
            .store(in: &cancellables)

        // Observe transcription changes from WhisperKitService
        whisperService.$currentTranscription
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcription in
                self?.handleTranscription(transcription, isConfirmed: false)
            }
            .store(in: &cancellables)

        whisperService.$confirmedTranscription
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcription in
                self?.handleTranscription(transcription, isConfirmed: true)
            }
            .store(in: &cancellables)

        // Observe audio level
        whisperService.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                guard let self = self, self.state == .listening else { return }
                self.audioLevel = level
            }
            .store(in: &cancellables)

        // Observe recording state - auto-restart if stopped unexpectedly
        whisperService.$isRecording
            .receive(on: DispatchQueue.main)
            .dropFirst()  // Ignore initial value
            .sink { [weak self] isRecording in
                guard let self = self else { return }

                // Update state based on recording
                if isRecording && self.state == .starting {
                    self.state = .listening
                }

                // If VAD should be running but recording stopped, try to restart after a delay
                if self.isEnabled && self.configuration.vadModeEnabled && !isRecording {
                    print("[VADService] Recording stopped unexpectedly. Attempting restart in 1 second...")

                    // Force state to idle if we were listening, so restart logic works
                    if self.state == .listening {
                        self.state = .idle
                    }

                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        // Only restart if still supposed to be enabled
                        if self.isEnabled && self.configuration.vadModeEnabled {
                            print("[VADService] Restarting VAD...")
                            // Ensure state allows start
                            if self.state == .listening {
                                self.state = .idle
                            }
                            try? await self.start()
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func handleTranscription(_ transcription: String, isConfirmed: Bool) {
        guard state == .listening else { return }
        guard !transcription.isEmpty else { return }

        let now = Date()

        // Reset accumulated transcription after silence
        if now.timeIntervalSince(lastTranscriptionUpdate) > transcriptionResetInterval {
            accumulatedTranscription = ""
        }
        lastTranscriptionUpdate = now

        // Update accumulated transcription
        if isConfirmed {
            accumulatedTranscription = transcription
        } else {
            // Combine confirmed and current
            let fullText =
                whisperService.confirmedTranscription.isEmpty
                ? transcription
                : whisperService.confirmedTranscription + " " + transcription
            accumulatedTranscription = fullText
        }

        // Check for persona detection
        checkForPersonaDetection(in: accumulatedTranscription)
    }

    private func checkForPersonaDetection(in text: String) {
        guard let detector = personaDetector else { return }

        // Check cooldown
        let now = Date()
        guard now.timeIntervalSince(lastDetectionTime) >= detectionCooldown else { return }

        if let detection = detector.detect(in: text) {
            lastDetectionTime = now

            print(
                "[VADService] ✅ Detected persona: \(detection.personaName) with confidence \(detection.confidence) in '\(text)'"
            )

            // Pause VAD (will resume when ChatView closes)
            Task {
                await self.pause()

                // Clear transcription to avoid re-detecting same phrase
                whisperService.clearTranscription()
                accumulatedTranscription = ""

                // Post notification to open chat with voice mode
                NotificationCenter.default.post(
                    name: .vadPersonaDetected,
                    object: detection
                )
            }
        }
    }

    /// Resume VAD after chat view closes (called externally)
    public func resumeAfterChat() async {
        // Reload configuration in case it changed
        loadConfiguration()

        print(
            "[VADService] Resume check: vadModeEnabled=\(configuration.vadModeEnabled), state=\(state), isEnabled=\(isEnabled)"
        )

        guard configuration.vadModeEnabled else {
            print("[VADService] Not resuming - VAD mode is disabled")
            return
        }

        guard state == .idle else {
            print("[VADService] Not resuming - state is \(state), not idle")
            return
        }

        print("[VADService] Resuming after chat closed...")

        // Wait for audio system to settle before restarting
        try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms

        // Clear any stale transcription before resuming
        whisperService.clearTranscription()
        accumulatedTranscription = ""

        do {
            try await start()
            print("[VADService] Successfully resumed")
        } catch {
            print("[VADService] Failed to resume: \(error)")
        }
    }
}

// MARK: - VAD Errors

public enum VADError: Error, LocalizedError {
    case notEnabled
    case noPersonasEnabled
    case noModelSelected
    case modelNotDownloaded
    case audioSetupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notEnabled:
            return "VAD mode is not enabled"
        case .noPersonasEnabled:
            return "No personas are enabled for VAD activation"
        case .noModelSelected:
            return "No Whisper model selected"
        case .modelNotDownloaded:
            return "Selected Whisper model is not downloaded"
        case .audioSetupFailed(let reason):
            return "Audio setup failed: \(reason)"
        }
    }
}
