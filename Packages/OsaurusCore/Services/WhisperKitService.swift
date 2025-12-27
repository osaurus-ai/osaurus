//
//  WhisperKitService.swift
//  osaurus
//
//  Core service wrapping WhisperKit for audio transcription.
//

@preconcurrency import AVFoundation
import Foundation
import os

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
    case modelNotLoaded
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
        case .modelNotLoaded:
            return "No model loaded. Please load a model first."
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
        guard let selectedModel = WhisperModelManager.shared.selectedModel else {
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
            let config = WhisperConfigurationStore.load()

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

            let config = WhisperConfigurationStore.load()

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

    // MARK: - Streaming Transcription

    private var audioEngine: AVAudioEngine?
    private let audioBuffer = ThreadSafeAudioBuffer()
    private var transcriptionWorker: TranscriptionWorker?

    @Published public var isRecording: Bool = false
    @Published public var currentTranscription: String = ""
    @Published public var confirmedTranscription: String = ""
    @Published public var audioLevel: Float = 0.0  // 0.0 to 1.0 for visualization

    /// Start streaming transcription
    public func startStreamingTranscription() async throws {
        guard !isRecording else { return }

        if !microphonePermissionGranted {
            let granted = await requestMicrophonePermission()
            if !granted {
                throw WhisperKitError.microphonePermissionDenied
            }
        }

        guard let whisperKit = whisperKit else {
            throw WhisperKitError.modelNotLoaded
        }

        // Reset state
        audioBuffer.clear()
        audioBuffer.setActive(true)
        currentTranscription = ""
        confirmedTranscription = ""
        audioLevel = 0.0

        // Setup engine off-main-thread to safely handle graph setup and tap installation
        // This avoids _dispatch_assert_queue_fail assertions from CoreAudio/RealtimeMessenger
        let (engine, format) = try await Task.detached(priority: .userInitiated) {
            () -> (AVAudioEngine, AVAudioFormat) in
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let tapFormat = inputNode.outputFormat(forBus: 0)

            guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
                // Try to fallback to standard format if output format is invalid (rare but possible)
                let inputFormat = inputNode.inputFormat(forBus: 0)
                if inputFormat.sampleRate > 0 {
                    return (engine, inputFormat)
                }
                throw WhisperKitError.transcriptionFailed("Invalid input audio format: \(tapFormat)")
            }

            return (engine, tapFormat)
        }.value

        self.audioEngine = engine
        let tapFormat = format

        // Initialize Worker
        transcriptionWorker = TranscriptionWorker(
            whisperKit: whisperKit,
            audioBuffer: audioBuffer,
            inputFormat: tapFormat
        )
        let bufferRef = audioBuffer

        // Install tap and start engine on background task
        try await Task.detached(priority: .userInitiated) { [bufferRef] in
            let inputNode = engine.inputNode

            // Install tap
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, time in
                guard bufferRef.isActive else { return }

                // Just copy raw samples to buffer
                guard let floatData = buffer.floatChannelData?[0] else { return }
                let frameCount = Int(buffer.frameLength)
                guard frameCount > 0 else { return }

                // Calculate Level (RMS) for UI
                var sum: Float = 0
                for i in 0 ..< frameCount {
                    sum += floatData[i] * floatData[i]
                }
                let rms = sqrt(sum / Float(frameCount))
                bufferRef.setLevel(min(1.0, rms * 10))

                // Append samples
                let samples = Array(UnsafeBufferPointer(start: floatData, count: frameCount))
                bufferRef.append(samples)
            }

            engine.prepare()
            try engine.start()
        }.value

        isRecording = true

        // Start a level polling task for UI updates
        Task { @MainActor [weak self] in
            while let self = self, bufferRef.isActive {
                self.audioLevel = bufferRef.getLevel()
                try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms for smooth animation
            }
            self?.audioLevel = 0
        }

        // Start streaming transcription task
        Task {
            guard let worker = transcriptionWorker else { return }
            for await update in await worker.start() {
                switch update {
                case .partial(let text):
                    self.currentTranscription = text
                case .final(let text):
                    if self.confirmedTranscription.isEmpty {
                        self.confirmedTranscription = text
                    } else {
                        self.confirmedTranscription += " " + text
                    }
                    self.currentTranscription = ""
                }
            }
        }
    }

    /// Stop streaming transcription and get final result
    public func stopStreamingTranscription() async -> String {
        // Stop the streaming first
        audioBuffer.setActive(false)
        await transcriptionWorker?.stop()
        transcriptionWorker = nil

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        isRecording = false

        // Final transcription of complete buffer
        let finalBuffer = audioBuffer.getAndClear()

        // Use hardcoded 16000 since minBufferSamples is gone/private
        if finalBuffer.count > 16000, let whisperKit = whisperKit {
            do {
                let options = DecodingOptions(
                    task: .transcribe,
                    language: "en",
                    usePrefillPrompt: true,
                    wordTimestamps: false
                )

                let results = try await whisperKit.transcribe(audioArray: finalBuffer, decodeOptions: options)

                if let result = results.first {
                    let finalText = result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    await MainActor.run {
                        if self.confirmedTranscription.isEmpty {
                            self.confirmedTranscription = finalText
                        } else {
                            self.confirmedTranscription += " " + finalText
                        }
                        self.currentTranscription = ""
                    }
                    return finalText
                }
            } catch {
                print("[WhisperKitService] Final transcription error: \(error)")
            }
        }

        return currentTranscription
    }

    /// Clear transcription state
    public func clearTranscription() {
        currentTranscription = ""
        confirmedTranscription = ""
        audioBuffer.clear()
    }
}

// MARK: - Transcription Worker

private enum TranscriptionUpdate: Sendable {
    case partial(String)
    case final(String)
}

private actor TranscriptionWorker {
    private let whisperKit: WhisperKit
    private let audioBuffer: ThreadSafeAudioBuffer
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<TranscriptionUpdate>.Continuation?
    private let inputFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    // VAD Parameters
    private let silenceThresholdSeconds: Double = 0.5
    private let maxSegmentDurationSeconds: Double = 30.0
    private let speechEnergyThreshold: Float = 0.05
    private let minSamples = 16000  // 1 second

    init(whisperKit: WhisperKit, audioBuffer: ThreadSafeAudioBuffer, inputFormat: AVAudioFormat) {
        self.whisperKit = whisperKit
        self.audioBuffer = audioBuffer
        self.inputFormat = inputFormat
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
    }

    func start() -> AsyncStream<TranscriptionUpdate> {
        let stream = AsyncStream<TranscriptionUpdate> { continuation in
            self.continuation = continuation
        }

        task = Task { [weak self] in
            await self?.runLoop()
        }

        return stream
    }

    func stop() {
        task?.cancel()
        continuation?.finish()
        task = nil
        continuation = nil
    }

    private func runLoop() async {
        print("[TranscriptionWorker] Streaming task started")

        self.converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        if self.converter == nil {
            print("[TranscriptionWorker] Failed to create audio converter")
        }

        var lastSpeechTime = Date()
        var isSpeaking = false
        var segmentStartTime = Date()
        var accumulatedSamples: [Float] = []

        while !Task.isCancelled && audioBuffer.isActive {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)  // Check every 100ms

                guard audioBuffer.isActive else { break }

                // Fetch new raw samples and clear from buffer
                let rawSamples = audioBuffer.getAndClear()
                if !rawSamples.isEmpty {
                    let converted = convertTo16kHz(rawSamples)
                    accumulatedSamples.append(contentsOf: converted)
                }

                // Calculate level from recent samples for VAD (approximate)
                // We use the last chunk or a window of accumulated samples
                let vadWindowSize = 1600  // 100ms at 16kHz
                let vadSamples = accumulatedSamples.suffix(vadWindowSize)
                let level: Float
                if !vadSamples.isEmpty {
                    let sum = vadSamples.reduce(0) { $0 + $1 * $1 }
                    level = sqrt(sum / Float(vadSamples.count)) * 10  // Scale roughly like the tap
                } else {
                    level = 0
                }

                let now = Date()

                // VAD Logic
                if level > speechEnergyThreshold {
                    if !isSpeaking {
                        isSpeaking = true
                        segmentStartTime = now
                    }
                    lastSpeechTime = now
                }

                let silenceDuration = now.timeIntervalSince(lastSpeechTime)
                let segmentDuration = now.timeIntervalSince(segmentStartTime)

                // 1. End of Speech Detected (Silence)
                if isSpeaking && silenceDuration > silenceThresholdSeconds {
                    await finalizeSegment(accumulatedSamples)
                    accumulatedSamples = []
                    isSpeaking = false
                }
                // 2. Max Duration Reached
                else if isSpeaking && segmentDuration > maxSegmentDurationSeconds {
                    await finalizeSegment(accumulatedSamples)
                    accumulatedSamples = []
                    isSpeaking = false
                }
                // 3. Ongoing Speech - Update Preview (every 1s roughly)
                else if isSpeaking && accumulatedSamples.count > minSamples {
                    if segmentDuration > 1.0 {
                        await updatePreview(accumulatedSamples)
                    }
                }
                // 4. Clean up noise if too long without speech
                else if !isSpeaking && accumulatedSamples.count > 16000 * 5 {
                    // Keep a rolling buffer of silence/noise to allow for pickup, but don't grow forever
                    accumulatedSamples = Array(accumulatedSamples.suffix(16000))
                }
            } catch {
                print("[TranscriptionWorker] Streaming task error: \(error)")
                break
            }
        }
        continuation?.finish()
    }

    private func convertTo16kHz(_ samples: [Float]) -> [Float] {
        guard let converter = converter else { return [] }

        let inputFrameCount = AVAudioFrameCount(samples.count)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrameCount) else {
            return []
        }

        inputBuffer.frameLength = inputFrameCount
        if let channelData = inputBuffer.floatChannelData?[0] {
            // Unsafe copy
            samples.withUnsafeBufferPointer { ptr in
                channelData.update(from: ptr.baseAddress!, count: samples.count)
            }
        }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(inputFrameCount) * ratio) + 100  // Padding

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            return []
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            print("[TranscriptionWorker] Conversion error: \(error)")
            return []
        }

        if let floatData = outputBuffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: floatData, count: Int(outputBuffer.frameLength)))
        }

        return []
    }

    private func finalizeSegment(_ buffer: [Float]) async {
        guard !buffer.isEmpty else { return }

        do {
            let options = DecodingOptions(
                task: .transcribe,
                language: "en",
                usePrefillPrompt: true,
                wordTimestamps: false
            )

            let results = try await whisperKit.transcribe(audioArray: buffer, decodeOptions: options)
            if let result = results.first {
                let text = result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                if !text.isEmpty {
                    continuation?.yield(.final(text))
                }
            }
        } catch {
            print("[TranscriptionWorker] Finalize error: \(error)")
        }
    }

    private func updatePreview(_ buffer: [Float]) async {
        do {
            let options = DecodingOptions(
                task: .transcribe,
                language: "en",
                wordTimestamps: false
            )

            let results = try await whisperKit.transcribe(audioArray: buffer, decodeOptions: options)
            if let result = results.first {
                let text = result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                continuation?.yield(.partial(text))
            }
        } catch {
            // Ignore preview errors
        }
    }
}

// MARK: - Thread-Safe Audio Buffer

/// Thread-safe audio buffer for real-time audio capture
private final class ThreadSafeAudioBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private var _isActive: Bool = false
    private var _level: Float = 0.0
    private let lock = OSAllocatedUnfairLock()

    var isActive: Bool {
        lock.withLock { _isActive }
    }

    func setActive(_ active: Bool) {
        lock.withLock { _isActive = active }
    }

    func setLevel(_ level: Float) {
        lock.withLock { _level = level }
    }

    func getLevel() -> Float {
        lock.withLock { _level }
    }

    func append(_ newSamples: [Float]) {
        lock.withLock {
            if _isActive {
                samples.append(contentsOf: newSamples)
            }
        }
    }

    func getSamples() -> [Float] {
        lock.withLock { samples }
    }

    func getAndClear() -> [Float] {
        lock.withLock {
            let current = samples
            samples = []
            // Do not deactivate on getAndClear for streaming flow,
            // but for stopStreaming we might want to.
            // However, caller usually handles state.
            // Let's just return data and clear buffer.
            return current
        }
    }

    func resetBuffer() {
        lock.withLock {
            samples = []
        }
    }

    func clear() {
        lock.withLock {
            samples = []
            _isActive = false
            _level = 0.0
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
