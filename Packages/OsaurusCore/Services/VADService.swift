//
//  VADService.swift
//  osaurus
//
//  Always-on Voice Activity Detection service for wake-word persona activation.
//  Continuously listens for persona names and triggers activation.
//

import AVFoundation
import Combine
import Foundation
import os

@preconcurrency import WhisperKit

/// Notification posted when a persona wake-word is detected
extension Notification.Name {
    static let vadPersonaDetected = Notification.Name("vadPersonaDetected")
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
@MainActor
public final class VADService: ObservableObject {
    public static let shared = VADService()

    // MARK: - Published Properties

    @Published public private(set) var state: VADServiceState = .idle
    @Published public private(set) var isEnabled: Bool = false
    @Published public private(set) var lastDetection: VADDetectionResult?
    @Published public private(set) var audioLevel: Float = 0.0

    // MARK: - Private Properties

    private var audioEngine: AVAudioEngine?
    private var whisperKit: WhisperKit?
    private var configuration: VADConfiguration = .default
    private var personaDetector: PersonaNameDetector?
    private var processingTask: Task<Void, Never>?
    private var audioBuffer: VADAudioBuffer?
    private var isProcessingAudio = false

    // Audio processing parameters
    private let sampleRate: Double = 16000
    private let bufferDuration: TimeInterval = 3.0  // Process every 3 seconds
    private let overlapDuration: TimeInterval = 1.0  // Keep 1 second overlap

    private init() {
        loadConfiguration()
    }

    // MARK: - Public Methods

    /// Load configuration and update state
    public func loadConfiguration() {
        configuration = VADConfigurationStore.load()
        isEnabled = configuration.vadModeEnabled

        // Update persona detector with enabled personas
        personaDetector = PersonaNameDetector(
            enabledPersonaIds: configuration.enabledPersonaIds,
            customWakePhrase: configuration.customWakePhrase
        )
    }

    /// Start VAD listening
    public func start() async throws {
        guard !isEnabled || state != .listening else { return }

        loadConfiguration()

        guard configuration.vadModeEnabled else {
            throw VADError.notEnabled
        }

        guard !configuration.enabledPersonaIds.isEmpty || !configuration.customWakePhrase.isEmpty else {
            throw VADError.noPersonasEnabled
        }

        state = .starting

        do {
            // Initialize WhisperKit if needed
            try await initializeWhisperKit()

            // Setup audio engine
            try await setupAudioEngine()

            state = .listening
            isEnabled = true

            print("[VADService] Started listening for wake words")
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    /// Stop VAD listening
    public func stop() async {
        processingTask?.cancel()
        processingTask = nil

        await teardownAudioEngine()

        state = .idle
        isEnabled = false
        audioLevel = 0

        print("[VADService] Stopped listening")
    }

    /// Toggle VAD on/off
    public func toggle() async throws {
        if state == .listening {
            await stop()
        } else {
            try await start()
        }
    }

    /// Update configuration and restart if needed
    public func updateConfiguration(_ newConfig: VADConfiguration) async throws {
        let wasListening = state == .listening

        if wasListening {
            await stop()
        }

        configuration = newConfig
        VADConfigurationStore.save(newConfig)
        loadConfiguration()

        if newConfig.vadModeEnabled && wasListening {
            try await start()
        }
    }

    // MARK: - Private Methods

    private func initializeWhisperKit() async throws {
        guard whisperKit == nil else { return }

        // Use the same model as WhisperKitService
        guard let selectedModel = WhisperModelManager.shared.selectedModel else {
            throw VADError.noModelSelected
        }

        let modelFolder = WhisperModelManager.whisperModelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(selectedModel.id, isDirectory: true)

        guard FileManager.default.fileExists(atPath: modelFolder.path) else {
            throw VADError.modelNotDownloaded
        }

        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            ),
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            useBackgroundDownloadSession: false
        )

        whisperKit = try await WhisperKit(config)
    }

    private func setupAudioEngine() async throws {
        await teardownAudioEngine()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Get input format
        let hwFormat = inputNode.inputFormat(forBus: 0)
        let actualSampleRate = hwFormat.sampleRate > 0 ? hwFormat.sampleRate : 48000

        guard
            let tapFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: actualSampleRate,
                channels: 1,
                interleaved: false
            )
        else {
            throw VADError.audioSetupFailed("Failed to create audio format")
        }

        // Create audio buffer for continuous processing
        audioBuffer = VADAudioBuffer(
            sampleRate: actualSampleRate,
            bufferDuration: bufferDuration,
            overlapDuration: overlapDuration
        )

        // Install tap
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self = self, self.state == .listening else { return }

            guard let floatData = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }

            // Calculate audio level
            var sum: Float = 0
            for i in 0 ..< frameCount {
                sum += floatData[i] * floatData[i]
            }
            let rms = sqrt(sum / Float(frameCount))

            Task { @MainActor in
                self.audioLevel = min(1.0, rms * 10)
            }

            // Add samples to buffer
            let samples = Array(UnsafeBufferPointer(start: floatData, count: frameCount))
            self.audioBuffer?.append(samples)

            // Check if buffer is ready for processing
            if let buffer = self.audioBuffer, buffer.isReady && !self.isProcessingAudio {
                self.processAudioBuffer()
            }
        }

        engine.prepare()

        do {
            try engine.start()
            self.audioEngine = engine
        } catch {
            throw VADError.audioSetupFailed(error.localizedDescription)
        }
    }

    private func teardownAudioEngine() async {
        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            engine.inputNode.removeTap(onBus: 0)
            audioEngine = nil
        }
        audioBuffer = nil
    }

    private func processAudioBuffer() {
        guard let buffer = audioBuffer, !isProcessingAudio else { return }

        isProcessingAudio = true
        let samples = buffer.getAndAdvance()

        Task { @MainActor in
            defer { isProcessingAudio = false }

            guard state == .listening else { return }

            // Check energy threshold
            let energy = samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
            let threshold = configuration.wakeWordSensitivity.energyThreshold

            guard energy > threshold else {
                // Too quiet, likely no speech
                return
            }

            state = .processing

            do {
                // Resample to 16kHz if needed
                let processedSamples: [Float]
                if let buffer = audioBuffer, buffer.sampleRate != 16000 {
                    processedSamples = resample(samples, from: buffer.sampleRate, to: 16000)
                } else {
                    processedSamples = samples
                }

                // Transcribe
                guard let whisperKit = whisperKit else { return }

                let options = DecodingOptions(
                    task: .transcribe,
                    language: "en",  // VAD typically works best with English wake words
                    wordTimestamps: false
                )

                let results = try await whisperKit.transcribe(audioArray: processedSamples, decodeOptions: options)

                if let result = results.first {
                    let transcription = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

                    // Check for persona name
                    if let detection = personaDetector?.detect(in: transcription) {
                        lastDetection = detection

                        // Post notification
                        NotificationCenter.default.post(
                            name: .vadPersonaDetected,
                            object: detection
                        )

                        print("[VADService] Detected persona: \(detection.personaName) in '\(transcription)'")
                    }
                }
            } catch {
                print("[VADService] Transcription error: \(error)")
            }

            state = .listening
        }
    }

    private func resample(_ samples: [Float], from inputRate: Double, to outputRate: Double) -> [Float] {
        let ratio = outputRate / inputRate
        let outputCount = Int(Double(samples.count) * ratio)

        var output = [Float](repeating: 0, count: outputCount)

        for i in 0 ..< outputCount {
            let srcIndex = Double(i) / ratio
            let srcIndexInt = Int(srcIndex)
            let frac = Float(srcIndex - Double(srcIndexInt))

            if srcIndexInt + 1 < samples.count {
                output[i] = samples[srcIndexInt] * (1 - frac) + samples[srcIndexInt + 1] * frac
            } else if srcIndexInt < samples.count {
                output[i] = samples[srcIndexInt]
            }
        }

        return output
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

// MARK: - VAD Audio Buffer

/// Circular audio buffer for continuous VAD processing
private final class VADAudioBuffer {
    let sampleRate: Double
    let bufferDuration: TimeInterval
    let overlapDuration: TimeInterval

    private var samples: [Float] = []
    private let lock = NSLock()

    var bufferSamples: Int { Int(sampleRate * bufferDuration) }
    var overlapSamples: Int { Int(sampleRate * overlapDuration) }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return samples.count >= bufferSamples
    }

    init(sampleRate: Double, bufferDuration: TimeInterval, overlapDuration: TimeInterval) {
        self.sampleRate = sampleRate
        self.bufferDuration = bufferDuration
        self.overlapDuration = overlapDuration
    }

    func append(_ newSamples: [Float]) {
        lock.lock()
        defer { lock.unlock() }

        samples.append(contentsOf: newSamples)

        // Limit buffer size to prevent unbounded growth
        let maxSize = bufferSamples * 3
        if samples.count > maxSize {
            samples = Array(samples.suffix(bufferSamples))
        }
    }

    func getAndAdvance() -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        guard samples.count >= bufferSamples else { return [] }

        // Get buffer
        let buffer = Array(samples.prefix(bufferSamples))

        // Keep overlap
        let dropCount = bufferSamples - overlapSamples
        if samples.count > dropCount {
            samples = Array(samples.dropFirst(dropCount))
        }

        return buffer
    }
}
