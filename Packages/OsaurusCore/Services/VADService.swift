//
//  VADService.swift
//  osaurus
//
//  Always-on Voice Activity Detection service for wake-word agent activation.
//  Uses SpeechService for transcription to avoid audio conflicts.
//

import AVFoundation
import Combine
import Foundation
import os

/// Notification posted when an agent wake-word is detected
extension Notification.Name {
    public static let vadAgentDetected = Notification.Name("vadAgentDetected")
    public static let startVoiceInputInChat = Notification.Name("startVoiceInputInChat")
    public static let chatViewClosed = Notification.Name("chatViewClosed")
    public static let vadStartNewSession = Notification.Name("vadStartNewSession")
    public static let closeChatOverlay = Notification.Name("closeChatOverlay")
    public static let voiceConfigurationChanged = Notification.Name("voiceConfigurationChanged")
}

/// Result of a VAD detection
public struct VADDetectionResult: Sendable {
    public let agentId: UUID
    public let agentName: String
    public let confidence: Float
    public let transcription: String
}

/// VAD Service state
public enum VADServiceState: Equatable, Sendable {
    case idle
    case starting
    case listening
    case error(String)
}

/// Always-on listening service for wake-word detection
/// Uses SpeechService's audio infrastructure to avoid conflicts
@MainActor
public final class VADService: ObservableObject {
    public static let shared = VADService()

    // MARK: - Published Properties

    @Published public private(set) var state: VADServiceState = .idle
    @Published public private(set) var audioLevel: Float = 0.0

    // MARK: - Private Properties

    private var isEnabled: Bool = false
    private var configuration: VADConfiguration = .default
    private var agentDetector: AgentNameDetector?
    private var cancellables = Set<AnyCancellable>()
    private var speechService: SpeechService { SpeechService.shared }

    // Debounce detection to avoid duplicate triggers
    private var lastDetectionTime: Date = .distantPast
    private let detectionCooldown: TimeInterval = 3.0  // Seconds before detecting same agent again

    // Auto-restart management
    private var restartTask: Task<Void, Never>?
    private var restartAttempts: Int = 0
    private let maxRestartAttempts: Int = 5

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

        // Update agent detector with enabled agents
        agentDetector = AgentNameDetector(
            enabledAgentIds: configuration.enabledAgentIds,
            customWakePhrase: configuration.customWakePhrase
        )

        print("[VADService] Loaded configuration with \(configuration.enabledAgentIds.count) enabled agents")
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

        guard !configuration.enabledAgentIds.isEmpty || !configuration.customWakePhrase.isEmpty else {
            print("[VADService] No agents enabled for VAD")
            throw VADError.noAgentsEnabled
        }

        print("[VADService] Starting with \(configuration.enabledAgentIds.count) enabled agents")

        state = .starting

        // Ensure model is loaded
        if !speechService.isModelLoaded {
            // Try to load the model
            guard let selectedModel = SpeechModelManager.shared.selectedModel else {
                state = .error("No model selected")
                throw VADError.noModelSelected
            }

            do {
                try await speechService.loadModel(selectedModel.id)
            } catch {
                state = .error("Failed to load model: \(error.localizedDescription)")
                throw error
            }
        }

        // Start streaming transcription with keep-alive enabled
        do {
            // Enable keep-alive to prevent audio engine teardown during handoffs
            speechService.keepAudioEngineAlive = true

            try await speechService.startStreamingTranscription()
            state = .listening
            isEnabled = true
            accumulatedTranscription = ""
            print("[VADService] Started listening for wake words (keep-alive enabled)")
        } catch {
            speechService.keepAudioEngineAlive = false
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
        speechService.keepAudioEngineAlive = false
        _ = await speechService.stopStreamingTranscription(force: true)
        speechService.clearTranscription()

        print("[VADService] Stopped listening (keep-alive disabled)")
    }

    /// Pause VAD temporarily (e.g., when chat voice input is active or testing)
    public func pause() async {
        guard state == .listening || state == .starting else { return }
        print("[VADService] Pausing temporarily")

        // Update state and disable auto-restart to prevent the isRecording observer
        // from restarting VAD while chat voice input is active
        state = .idle
        isEnabled = false
        restartTask?.cancel()
        restartTask = nil

        // NOTE: We do NOT set keepAudioEngineAlive = false here.
        // We want the engine to stay alive for handoff.

        // Stop streaming (will keep engine alive because keepAudioEngineAlive is true from start())
        _ = await speechService.stopStreamingTranscription()
        speechService.clearTranscription()

        print("[VADService] Paused - transcription stopped, auto-restart disabled")
    }

    // MARK: - Private Methods

    private func setupObservers() {
        // Observe configuration changes
        NotificationCenter.default.publisher(for: .voiceConfigurationChanged)
            .sink { [weak self] _ in
                self?.loadConfiguration()
            }
            .store(in: &cancellables)

        // Observe transcription changes from SpeechService
        speechService.$currentTranscription
            .sink { [weak self] transcription in
                self?.handleTranscription(transcription, isConfirmed: false)
            }
            .store(in: &cancellables)

        speechService.$confirmedTranscription
            .sink { [weak self] transcription in
                self?.handleTranscription(transcription, isConfirmed: true)
            }
            .store(in: &cancellables)

        // Observe audio level
        speechService.$audioLevel
            .sink { [weak self] level in
                guard let self = self, self.state == .listening else { return }
                self.audioLevel = level
            }
            .store(in: &cancellables)

        // Observe recording state - auto-restart if stopped unexpectedly
        speechService.$isRecording
            .dropFirst()  // Ignore initial value
            .sink { [weak self] isRecording in
                guard let self = self else { return }

                // Update state based on recording
                if isRecording && self.state == .starting {
                    self.state = .listening
                    self.restartAttempts = 0  // Reset counter on successful start
                }

                // If VAD should be running but recording stopped, try to restart after a delay
                if self.isEnabled && self.configuration.vadModeEnabled && !isRecording {
                    // Cancel any previous restart attempt
                    self.restartTask?.cancel()

                    guard self.restartAttempts < self.maxRestartAttempts else {
                        print("[VADService] Max restart attempts (\(self.maxRestartAttempts)) reached, giving up.")
                        self.state = .error("Recording stopped repeatedly")
                        return
                    }

                    self.restartAttempts += 1
                    print(
                        "[VADService] Recording stopped unexpectedly. Attempting restart \(self.restartAttempts)/\(self.maxRestartAttempts) in 1 second..."
                    )

                    // Force state to idle if we were listening, so restart logic works
                    if self.state == .listening {
                        self.state = .idle
                    }

                    self.restartTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        guard !Task.isCancelled else { return }
                        guard let self else { return }
                        if self.isEnabled && self.configuration.vadModeEnabled {
                            print("[VADService] Restarting VAD...")
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
                speechService.confirmedTranscription.isEmpty
                ? transcription
                : speechService.confirmedTranscription + " " + transcription
            accumulatedTranscription = fullText
        }

        // Check for agent detection
        checkForAgentDetection(in: accumulatedTranscription)
    }

    private func checkForAgentDetection(in text: String) {
        guard let detector = agentDetector else { return }

        // Check cooldown
        let now = Date()
        guard now.timeIntervalSince(lastDetectionTime) >= detectionCooldown else { return }

        if let detection = detector.detect(in: text) {
            lastDetectionTime = now

            print(
                "[VADService] ✅ Detected agent: \(detection.agentName) with confidence \(detection.confidence) in '\(text)'"
            )

            // Pause VAD (will resume when ChatView closes)
            Task {
                await self.pause()

                // Clear transcription to avoid re-detecting same phrase
                speechService.clearTranscription()
                accumulatedTranscription = ""

                // Post notification to open chat with voice mode
                NotificationCenter.default.post(
                    name: .vadAgentDetected,
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
        speechService.clearTranscription()
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
    case noAgentsEnabled
    case noModelSelected

    public var errorDescription: String? {
        switch self {
        case .notEnabled:
            return "VAD mode is not enabled"
        case .noAgentsEnabled:
            return "No agents are enabled for VAD activation"
        case .noModelSelected:
            return "No speech model selected"
        }
    }
}
