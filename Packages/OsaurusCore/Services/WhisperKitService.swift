//
//  WhisperKitService.swift
//  osaurus
//
//  Core service wrapping WhisperKit for audio transcription.
//

import AVFoundation
import Foundation

@preconcurrency import WhisperKit

/// Result of a transcription operation
public struct TranscriptionResult: Sendable {
    public let text: String
    public let language: String?
    public let segments: [TranscriptionSegment]
    public let durationSeconds: Double?

    public init(
        text: String,
        language: String? = nil,
        segments: [TranscriptionSegment] = [],
        durationSeconds: Double? = nil
    ) {
        self.text = text
        self.language = language
        self.segments = segments
        self.durationSeconds = durationSeconds
    }
}

/// A segment of transcribed text with timing information
public struct TranscriptionSegment: Sendable {
    public let id: Int
    public let text: String
    public let start: Double
    public let end: Double
    public let tokens: [Int]?

    public init(id: Int, text: String, start: Double, end: Double, tokens: [Int]? = nil) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.tokens = tokens
    }
}

/// Error types for WhisperKit operations
public enum WhisperKitError: Error, LocalizedError {
    case noModelSelected
    case modelNotDownloaded
    case pipelineNotInitialized
    case transcriptionFailed(String)
    case microphonePermissionDenied
    case audioFileNotFound
    case invalidAudioFormat

    public var errorDescription: String? {
        switch self {
        case .noModelSelected:
            return "No WhisperKit model selected. Please download and select a model."
        case .modelNotDownloaded:
            return "The selected model is not downloaded."
        case .pipelineNotInitialized:
            return "WhisperKit pipeline is not initialized."
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        case .microphonePermissionDenied:
            return "Microphone permission denied. Please grant access in System Settings."
        case .audioFileNotFound:
            return "Audio file not found."
        case .invalidAudioFormat:
            return "Invalid or unsupported audio format."
        }
    }
}

/// Service for audio transcription using WhisperKit
@MainActor
public final class WhisperKitService: ObservableObject {
    public static let shared = WhisperKitService()

    // MARK: - Published Properties

    @Published public var isTranscribing: Bool = false
    @Published public var isModelLoaded: Bool = false
    @Published public var isLoadingModel: Bool = false
    @Published public var loadedModelId: String?
    @Published public var lastError: String?
    @Published public var microphonePermissionGranted: Bool = false

    // MARK: - Private Properties

    private nonisolated(unsafe) var whisperKit: WhisperKit?

    // MARK: - Initialization

    private init() {
        checkMicrophonePermission()
    }

    // MARK: - Microphone Permission

    /// Check current microphone permission status
    public func checkMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphonePermissionGranted = true
        case .notDetermined, .denied, .restricted:
            microphonePermissionGranted = false
        @unknown default:
            microphonePermissionGranted = false
        }
    }

    /// Request microphone permission
    public func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            await MainActor.run { microphonePermissionGranted = true }
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run { microphonePermissionGranted = granted }
            return granted
        case .denied, .restricted:
            await MainActor.run { microphonePermissionGranted = false }
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Model Loading

    /// Load a WhisperKit model
    public func loadModel(_ modelId: String) async throws {
        guard !isLoadingModel else {
            print("[WhisperKitService] Already loading a model, skipping")
            return
        }

        print("[WhisperKitService] Starting to load model: \(modelId)")
        isLoadingModel = true
        lastError = nil

        // Unload previous model
        whisperKit = nil
        isModelLoaded = false
        loadedModelId = nil

        // WhisperKit stores models at: {baseDir}/models/argmaxinc/whisperkit-coreml/{modelId}/
        let modelFolder = WhisperModelManager.whisperModelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(modelId, isDirectory: true)

        print("[WhisperKitService] Model folder: \(modelFolder.path)")

        guard FileManager.default.fileExists(atPath: modelFolder.path) else {
            print("[WhisperKitService] Model folder not found")
            isLoadingModel = false
            throw WhisperKitError.modelNotDownloaded
        }

        do {
            // Initialize WhisperKit with the direct model folder path
            // modelFolder should point to the folder containing the .mlmodelc files
            print("[WhisperKitService] Initializing WhisperKit...")
            let config = WhisperKitConfig(
                modelFolder: modelFolder.path,
                computeOptions: ModelComputeOptions(
                    audioEncoderCompute: .cpuAndNeuralEngine,
                    textDecoderCompute: .cpuAndNeuralEngine
                ),
                verbose: true,
                logLevel: .debug,
                prewarm: true,
                load: true,
                useBackgroundDownloadSession: false
            )

            let newWhisperKit = try await WhisperKit(config)
            whisperKit = newWhisperKit

            print("[WhisperKitService] Model loaded successfully")
            isModelLoaded = true
            loadedModelId = modelId
            isLoadingModel = false
        } catch {
            print("[WhisperKitService] Failed to load model: \(error)")
            lastError = error.localizedDescription
            isModelLoaded = false
            loadedModelId = nil
            isLoadingModel = false
            throw WhisperKitError.transcriptionFailed(error.localizedDescription)
        }
    }

    /// Unload the current model
    public func unloadModel() {
        whisperKit = nil
        isModelLoaded = false
        loadedModelId = nil
    }

    /// Ensure a model is loaded, using the default if needed
    public func ensureModelLoaded() async throws {
        if isModelLoaded && whisperKit != nil {
            return
        }

        // Get the selected model from manager
        guard let selectedModel = await WhisperModelManager.shared.selectedModel else {
            throw WhisperKitError.noModelSelected
        }

        guard selectedModel.isDownloaded else {
            throw WhisperKitError.modelNotDownloaded
        }

        try await loadModel(selectedModel.id)
    }

    // MARK: - Transcription

    /// Transcribe an audio file
    public func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        try await ensureModelLoaded()

        guard let whisperKit = whisperKit else {
            throw WhisperKitError.pipelineNotInitialized
        }

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw WhisperKitError.audioFileNotFound
        }

        isTranscribing = true
        defer { isTranscribing = false }

        do {
            // Get configuration
            let config = await WhisperConfigurationStore.load()

            // Configure decoding options
            let options = DecodingOptions(
                task: config.task == .translate ? .translate : .transcribe,
                language: config.languageHint,
                wordTimestamps: config.wordTimestamps
            )

            // Transcribe
            let results = try await whisperKit.transcribe(audioPath: audioURL.path, decodeOptions: options)

            guard let result = results.first else {
                throw WhisperKitError.transcriptionFailed("No transcription result")
            }

            // Convert segments
            let segments: [TranscriptionSegment] = result.segments.enumerated().map { index, segment in
                TranscriptionSegment(
                    id: index,
                    text: segment.text,
                    start: Double(segment.start),
                    end: Double(segment.end),
                    tokens: segment.tokens
                )
            }

            let duration: Double? = result.segments.last.map { Double($0.end) }

            return TranscriptionResult(
                text: result.text,
                language: result.language,
                segments: segments,
                durationSeconds: duration
            )
        } catch {
            throw WhisperKitError.transcriptionFailed(error.localizedDescription)
        }
    }

    /// Transcribe raw audio data (for streaming/VAD use cases)
    public func transcribe(audioData: Data, sampleRate: Int = 16000) async throws -> TranscriptionResult {
        try await ensureModelLoaded()

        guard let whisperKit = whisperKit else {
            throw WhisperKitError.pipelineNotInitialized
        }

        isTranscribing = true
        defer { isTranscribing = false }

        do {
            // Convert Data to float array (assuming 16-bit PCM)
            let floatArray = audioData.withUnsafeBytes { buffer -> [Float] in
                let int16Buffer = buffer.bindMemory(to: Int16.self)
                return int16Buffer.map { Float($0) / Float(Int16.max) }
            }

            let config = await WhisperConfigurationStore.load()

            let options = DecodingOptions(
                task: config.task == .translate ? .translate : .transcribe,
                language: config.languageHint,
                wordTimestamps: config.wordTimestamps
            )

            let results = try await whisperKit.transcribe(audioArray: floatArray, decodeOptions: options)

            guard let result = results.first else {
                throw WhisperKitError.transcriptionFailed("No transcription result")
            }

            let segments: [TranscriptionSegment] = result.segments.enumerated().map { index, segment in
                TranscriptionSegment(
                    id: index,
                    text: segment.text,
                    start: Double(segment.start),
                    end: Double(segment.end),
                    tokens: segment.tokens
                )
            }

            let duration2: Double? = result.segments.last.map { Double($0.end) }

            return TranscriptionResult(
                text: result.text,
                language: result.language,
                segments: segments,
                durationSeconds: duration2
            )
        } catch {
            throw WhisperKitError.transcriptionFailed(error.localizedDescription)
        }
    }

    // MARK: - Audio Recording (for testing)

    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?

    @Published public var isRecording: Bool = false

    /// Start recording audio for testing
    public func startRecording() async throws -> URL {
        if !microphonePermissionGranted {
            let granted = await requestMicrophonePermission()
            if !granted {
                throw WhisperKitError.microphonePermissionDenied
            }
        }

        let tempDir = FileManager.default.temporaryDirectory
        let recordingURL = tempDir.appendingPathComponent("osaurus_recording_\(UUID().uuidString).wav")
        self.recordingURL = recordingURL

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            audioRecorder?.prepareToRecord()
            audioRecorder?.record()
            isRecording = true
            return recordingURL
        } catch {
            throw WhisperKitError.transcriptionFailed("Failed to start recording: \(error.localizedDescription)")
        }
    }

    /// Stop recording and return the audio file URL
    public func stopRecording() -> URL? {
        audioRecorder?.stop()
        audioRecorder = nil
        isRecording = false
        return recordingURL
    }

    /// Clean up recording file
    public func cleanupRecording() {
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }
    }
}

// MARK: - VAD Interface Placeholder

/// Protocol for Voice Activity Detection (VAD) - future implementation
/// This interface reserves architecture for continuous voice monitoring
public protocol VADDelegate: AnyObject {
    /// Called when speech is detected
    func vadDidDetectSpeech()

    /// Called when speech ends
    func vadDidEndSpeech()

    /// Called with transcription result after speech ends
    func vadDidTranscribe(result: TranscriptionResult)

    /// Called when an error occurs
    func vadDidFail(error: Error)
}

/// Placeholder for VAD configuration - to be implemented
public struct VADConfiguration {
    /// Minimum duration of silence to consider speech ended (seconds)
    public var silenceThreshold: Double = 0.5

    /// Minimum speech duration to trigger transcription (seconds)
    public var minSpeechDuration: Double = 0.3

    /// Energy threshold for voice detection
    public var energyThreshold: Float = 0.01

    /// Whether to auto-transcribe after speech ends
    public var autoTranscribe: Bool = true

    public init() {}
}
