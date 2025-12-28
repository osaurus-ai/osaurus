//
//  WhisperKitService.swift
//  osaurus
//
//  Core service wrapping WhisperKit for audio transcription.
//

@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os
@preconcurrency import ScreenCaptureKit

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

// MARK: - Audio Input Device

/// Represents an available audio input device
public struct AudioInputDevice: Identifiable, Equatable, Hashable, Sendable {
    public let id: String  // uniqueID from AVCaptureDevice
    public let name: String
    public let isDefault: Bool

    public init(id: String, name: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

// MARK: - Audio Input Manager

/// Manages audio input device enumeration and selection
@MainActor
public final class AudioInputManager: ObservableObject {
    public static let shared = AudioInputManager()

    /// Available audio input devices
    @Published public private(set) var availableDevices: [AudioInputDevice] = []

    /// Currently selected device ID (nil = system default)
    @Published public var selectedDeviceId: String? {
        didSet {
            if oldValue != selectedDeviceId {
                persistSelection()
            }
        }
    }

    /// Currently selected input source (microphone or system audio)
    @Published public var selectedInputSource: AudioInputSource = .microphone {
        didSet {
            if oldValue != selectedInputSource {
                persistSelection()
            }
        }
    }

    // MARK: - System Audio Status (delegated from SystemAudioCaptureManager)

    /// Whether system audio capture is available on this system (macOS 12.3+)
    public var isSystemAudioAvailable: Bool {
        SystemAudioCaptureManager.shared.isAvailable
    }

    /// Whether we have screen recording permission (required for system audio)
    public var hasSystemAudioPermission: Bool {
        SystemAudioCaptureManager.shared.hasPermission
    }

    /// Request screen recording permission for system audio capture
    public func requestSystemAudioPermission() {
        SystemAudioCaptureManager.shared.requestPermission()
    }

    /// Check/refresh system audio permission status
    public func checkSystemAudioPermission() async {
        if #available(macOS 12.3, *) {
            await SystemAudioCaptureManager.shared.checkPermission()
        }
    }

    private var deviceObservers: [NSObjectProtocol] = []

    private init() {
        loadPersistedSelection()
        refreshDevices()
        setupDeviceObservers()
    }

    deinit {
        for observer in deviceObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public Methods

    /// Refresh the list of available audio input devices
    public func refreshDevices() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )

        let defaultDeviceId = getDefaultInputDeviceId()

        // Filter out internal/aggregate devices that shouldn't be shown to users
        availableDevices = discoverySession.devices.compactMap { device in
            // Skip devices with suspicious names (internal aggregate devices)
            let name = device.localizedName
            if name.hasPrefix("CADefaultDevice") || name.contains("Aggregate") && name.contains("-") || name.isEmpty {
                return nil
            }

            return AudioInputDevice(
                id: device.uniqueID,
                name: name,
                isDefault: device.uniqueID == defaultDeviceId
            )
        }

        // If selected device is no longer available, reset to default
        if let selectedId = selectedDeviceId,
            !availableDevices.contains(where: { $0.id == selectedId })
        {
            selectedDeviceId = nil
        }
    }

    /// Get the currently selected device (or system default if none selected)
    public var selectedDevice: AudioInputDevice? {
        if let selectedId = selectedDeviceId {
            return availableDevices.first { $0.id == selectedId }
        }
        return availableDevices.first { $0.isDefault } ?? availableDevices.first
    }

    /// Select an input device by ID
    public func selectDevice(_ deviceId: String?) {
        selectedDeviceId = deviceId
    }

    // MARK: - Device Observers

    private func setupDeviceObservers() {
        // Observe device connection
        let connectedObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice,
                device.hasMediaType(.audio)
            else { return }
            Task { @MainActor in
                self?.refreshDevices()
            }
        }
        deviceObservers.append(connectedObserver)

        // Observe device disconnection
        let disconnectedObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice,
                device.hasMediaType(.audio)
            else { return }
            Task { @MainActor in
                self?.refreshDevices()
            }
        }
        deviceObservers.append(disconnectedObserver)
    }

    // MARK: - CoreAudio Helpers

    /// Get the system default input device ID
    private func getDefaultInputDeviceId() -> String? {
        var defaultDeviceId = AudioDeviceID()
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &defaultDeviceId
        )

        guard status == noErr else { return nil }

        return getDeviceUID(for: defaultDeviceId)
    }

    /// Get the UID for an AudioDeviceID
    private func getDeviceUID(for deviceId: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // Use Unmanaged to properly handle the CFString reference
        var uidUnmanaged: Unmanaged<CFString>?
        var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(
            deviceId,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &uidUnmanaged
        )

        guard status == noErr, let uidUnmanaged = uidUnmanaged else { return nil }
        // Take ownership and release after use
        let uid = uidUnmanaged.takeRetainedValue()
        return uid as String
    }

    /// Get AudioDeviceID for a UID by iterating through all audio devices
    public func getAudioDeviceId(for uid: String) -> AudioDeviceID? {
        // Get all audio devices
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize
        )

        guard status == noErr, propertySize > 0 else { return nil }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIds = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceIds
        )

        guard status == noErr else { return nil }

        // Find device with matching UID
        for deviceId in deviceIds {
            if let deviceUID = getDeviceUID(for: deviceId), deviceUID == uid {
                return deviceId
            }
        }

        return nil
    }

    // MARK: - Persistence

    private func loadPersistedSelection() {
        let config = WhisperConfigurationStore.load()
        selectedDeviceId = config.selectedInputDeviceId
        selectedInputSource = config.selectedInputSource
    }

    private func persistSelection() {
        var config = WhisperConfigurationStore.load()
        config.selectedInputDeviceId = selectedDeviceId
        config.selectedInputSource = selectedInputSource
        WhisperConfigurationStore.save(config)
    }
}

// MARK: - System Audio Sample Buffer

/// Thread-safe buffer for system audio samples
private final class SystemAudioSampleBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock = OSAllocatedUnfairLock()

    func append(_ newSamples: [Float]) {
        lock.withLock {
            samples.append(contentsOf: newSamples)
        }
    }

    func getAndClear() -> [Float] {
        lock.withLock {
            let current = samples
            samples = []
            return current
        }
    }

    func clear() {
        lock.withLock {
            samples = []
        }
    }
}

// MARK: - System Audio Capture Manager

/// Manages system audio capture using ScreenCaptureKit (macOS 12.3+)
/// This allows capturing audio from the computer (apps, browser, etc.)
@MainActor
public final class SystemAudioCaptureManager: NSObject, ObservableObject {
    public static let shared = SystemAudioCaptureManager()

    /// Whether system audio capture is available on this system
    @Published public private(set) var isAvailable: Bool = false

    /// Whether we have permission to capture screen/audio
    @Published public private(set) var hasPermission: Bool = false

    /// Whether system audio capture is currently active
    @Published public private(set) var isCapturing: Bool = false

    /// Thread-safe audio sample buffer
    private let sampleBuffer = SystemAudioSampleBuffer()

    private var stream: SCStream?
    private var streamOutput: SystemAudioStreamOutput?

    private override init() {
        super.init()
        checkAvailability()
    }

    // MARK: - Public Methods

    /// Check if ScreenCaptureKit is available and we have permission
    public func checkAvailability() {
        // ScreenCaptureKit requires macOS 12.3+
        if #available(macOS 12.3, *) {
            isAvailable = true
            Task {
                await checkPermission()
            }
        } else {
            isAvailable = false
            hasPermission = false
        }
    }

    /// Check if we have screen recording permission (required for system audio)
    @available(macOS 12.3, *)
    public func checkPermission() async {
        do {
            // Attempting to get shareable content will check/request permission
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            await MainActor.run {
                self.hasPermission = true
            }
        } catch {
            await MainActor.run {
                self.hasPermission = false
            }
        }
    }

    /// Request permission by triggering the system prompt
    public func requestPermission() {
        if #available(macOS 12.3, *) {
            Task {
                await checkPermission()
                if !hasPermission {
                    // Open System Settings if permission wasn't granted
                    if let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    /// Start capturing system audio
    @available(macOS 12.3, *)
    public func startCapture() async throws {
        guard isAvailable else {
            throw WhisperKitError.transcriptionFailed("System audio capture not available on this macOS version")
        }

        guard !isCapturing else { return }

        // Clear any previous stream
        if let existingStream = stream {
            try? await existingStream.stopCapture()
            stream = nil
            streamOutput = nil
        }

        // Get shareable content
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        // Create a filter to capture all audio (no specific window/app)
        guard let display = content.displays.first else {
            throw WhisperKitError.transcriptionFailed("No display found for audio capture")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Configure stream for audio capture
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true  // Don't capture our own audio
        configuration.sampleRate = 16000  // WhisperKit's preferred sample rate
        configuration.channelCount = 1  // Mono for transcription

        // Video configuration - use display size but minimal frame rate
        // Using 1x1 can cause stream creation to fail on some systems
        configuration.width = Int(display.width)
        configuration.height = Int(display.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps minimal
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        // Create output handler first
        let output = SystemAudioStreamOutput { [weak self] samples in
            self?.appendSamples(samples)
        }
        self.streamOutput = output

        // Create stream with self as delegate for error handling
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)

        // Store stream reference before starting (prevent deallocation)
        self.stream = newStream

        do {
            try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))

            // Start the stream
            try await newStream.startCapture()

            isCapturing = true
            print("[SystemAudioCaptureManager] Started capturing system audio")
        } catch {
            // Clean up on failure
            self.stream = nil
            self.streamOutput = nil
            print("[SystemAudioCaptureManager] Failed to start capture: \(error)")
            throw WhisperKitError.transcriptionFailed(
                "Failed to start system audio capture: \(error.localizedDescription)"
            )
        }
    }

    /// Stop capturing system audio
    @available(macOS 12.3, *)
    public func stopCapture() async {
        guard isCapturing, let stream = stream else { return }

        do {
            try await stream.stopCapture()
        } catch {
            print("[SystemAudioCaptureManager] Error stopping capture: \(error)")
        }

        self.stream = nil
        self.streamOutput = nil
        isCapturing = false

        print("[SystemAudioCaptureManager] Stopped capturing system audio")
    }

    /// Get and clear captured audio samples
    public nonisolated func getAndClearSamples() -> [Float] {
        sampleBuffer.getAndClear()
    }

    // MARK: - Private Methods

    private nonisolated func appendSamples(_ samples: [Float]) {
        sampleBuffer.append(samples)
    }
}

// MARK: - SCStreamDelegate

@available(macOS 12.3, *)
extension SystemAudioCaptureManager: SCStreamDelegate {
    public nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[SystemAudioCaptureManager] Stream stopped with error: \(error)")
        Task { @MainActor in
            self.isCapturing = false
            self.stream = nil
            self.streamOutput = nil
        }
    }
}

// MARK: - System Audio Stream Output

@available(macOS 12.3, *)
private class SystemAudioStreamOutput: NSObject, SCStreamOutput {
    private let onSamples: ([Float]) -> Void

    init(onSamples: @escaping ([Float]) -> Void) {
        self.onSamples = onSamples
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        // Extract audio samples from the sample buffer
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )

        guard status == noErr, let dataPointer = dataPointer else { return }

        // Get format description
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        // Convert based on format
        let samples: [Float]
        if asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            // Already float
            let floatPointer = dataPointer.withMemoryRebound(
                to: Float.self,
                capacity: length / MemoryLayout<Float>.size
            ) { $0 }
            samples = Array(UnsafeBufferPointer(start: floatPointer, count: length / MemoryLayout<Float>.size))
        } else if asbd.pointee.mBitsPerChannel == 16 {
            // 16-bit integer
            let int16Pointer = dataPointer.withMemoryRebound(
                to: Int16.self,
                capacity: length / MemoryLayout<Int16>.size
            ) { $0 }
            samples = (0 ..< (length / MemoryLayout<Int16>.size)).map { Float(int16Pointer[$0]) / Float(Int16.max) }
        } else {
            // Unsupported format
            return
        }

        onSamples(samples)
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
        print("[WhisperKitService] Model unloaded")
    }

    /// Auto-load the model if voice features are enabled and a default model is selected
    /// Call this when voice settings change or on app launch
    public func autoLoadIfNeeded() async {
        let config = WhisperConfigurationStore.load()

        // If voice features are disabled, unload any loaded model
        guard config.enabled else {
            if isModelLoaded {
                unloadModel()
            }
            return
        }

        // If no model is selected, nothing to load
        guard let selectedModel = WhisperModelManager.shared.selectedModel else {
            return
        }

        // If model is not downloaded, can't load
        guard selectedModel.isDownloaded else {
            return
        }

        // If the selected model is already loaded, nothing to do
        if isModelLoaded && loadedModelId == selectedModel.id {
            return
        }

        // Load the model
        do {
            try await loadModel(selectedModel.id)
            print("[WhisperKitService] Auto-loaded model: \(selectedModel.id)")
        } catch {
            print("[WhisperKitService] Failed to auto-load model: \(error)")
        }
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
                task: .transcribe,
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
                task: .transcribe,
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

    /// Whether we're currently using system audio capture (vs microphone)
    private var isUsingSystemAudio: Bool = false
    /// Task for polling system audio samples
    private var systemAudioPollingTask: Task<Void, Never>?

    @Published public var isRecording: Bool = false
    @Published public var currentTranscription: String = ""
    @Published public var confirmedTranscription: String = ""
    @Published public var audioLevel: Float = 0.0  // 0.0 to 1.0 for visualization

    /// When true, prevents stopStreamingTranscription from actually stopping (for VAD background mode)
    public var isVADBackgroundMode: Bool = false

    /// Start streaming transcription
    public func startStreamingTranscription() async throws {
        guard !isRecording else { return }

        // 1. Clean up previous state strictly
        await teardownAudioEngine()

        // Get the selected input source
        let inputSource = AudioInputManager.shared.selectedInputSource

        // 2. Check Permissions & Model based on input source
        if inputSource == .microphone {
            if !microphonePermissionGranted {
                let granted = await requestMicrophonePermission()
                if !granted {
                    throw WhisperKitError.microphonePermissionDenied
                }
            }
        } else {
            // System audio requires screen recording permission
            if #available(macOS 12.3, *) {
                await SystemAudioCaptureManager.shared.checkPermission()
                if !SystemAudioCaptureManager.shared.hasPermission {
                    throw WhisperKitError.transcriptionFailed(
                        "Screen recording permission required for system audio capture"
                    )
                }
            } else {
                throw WhisperKitError.transcriptionFailed("System audio capture requires macOS 12.3 or later")
            }
        }

        // Auto-load model if needed
        try await ensureModelLoaded()

        guard let whisperKit = whisperKit else {
            throw WhisperKitError.modelNotLoaded
        }

        // 3. Reset State
        audioBuffer.clear()
        audioBuffer.setActive(true)
        currentTranscription = ""
        confirmedTranscription = ""
        audioLevel = 0.0
        isUsingSystemAudio = (inputSource == .systemAudio)

        // Get configuration
        let config = WhisperConfigurationStore.load()

        print("[WhisperKitService] Starting transcription with:")
        print("[WhisperKitService]   - Language: \(config.languageHint ?? "auto-detect")")
        print("[WhisperKitService]   - Sensitivity: \(config.sensitivity)")

        if inputSource == .microphone {
            // 4a. Microphone path: Resolve Device ID
            let selectedId = AudioInputManager.shared.selectedDeviceId
            var targetDeviceId: AudioDeviceID? = nil

            if let selectedId {
                targetDeviceId = AudioInputManager.shared.getAudioDeviceId(for: selectedId)
                if targetDeviceId == nil {
                    print("[WhisperKitService] WARNING: Could not find AudioDeviceID for UID: \(selectedId)")
                }
            }

            // 5a. Setup Audio Engine
            do {
                let (engine, tapFormat) = try await setupAudioEngine(
                    targetDeviceId: targetDeviceId,
                    buffer: audioBuffer
                )
                self.audioEngine = engine

                // 6a. Start Worker with microphone format
                transcriptionWorker = TranscriptionWorker(
                    whisperKit: whisperKit,
                    audioBuffer: audioBuffer,
                    inputFormat: tapFormat,
                    languageHint: config.languageHint,
                    sensitivity: config.sensitivity
                )

                isRecording = true

                // 7a. Start Processing
                startAudioLevelMonitoring()
                startWorkerProcessing()

            } catch {
                await teardownAudioEngine()
                throw error
            }
        } else {
            // 4b. System Audio path
            if #available(macOS 12.3, *) {
                do {
                    try await SystemAudioCaptureManager.shared.startCapture()

                    // System audio is already at 16kHz mono, create format for worker
                    guard
                        let systemAudioFormat = AVAudioFormat(
                            commonFormat: .pcmFormatFloat32,
                            sampleRate: 16000,
                            channels: 1,
                            interleaved: false
                        )
                    else {
                        throw WhisperKitError.transcriptionFailed("Failed to create audio format for system audio")
                    }

                    // 6b. Start Worker with 16kHz format (no conversion needed)
                    transcriptionWorker = TranscriptionWorker(
                        whisperKit: whisperKit,
                        audioBuffer: audioBuffer,
                        inputFormat: systemAudioFormat,
                        languageHint: config.languageHint,
                        sensitivity: config.sensitivity
                    )

                    isRecording = true

                    // 7b. Start polling system audio samples into the buffer
                    startSystemAudioPolling()
                    startAudioLevelMonitoring()
                    startWorkerProcessing()

                } catch {
                    await teardownAudioEngine()
                    throw error
                }
            }
        }
    }

    /// Stop streaming transcription and get final result
    /// - Parameter force: If true, stops even if VAD background mode is active
    public func stopStreamingTranscription(force: Bool = false) async -> String {
        // Don't stop if VAD background mode is active (unless forced)
        if isVADBackgroundMode && !force {
            print("[WhisperKitService] Ignoring stop request - VAD background mode active")
            return confirmedTranscription + " " + currentTranscription
        }

        // Stop the streaming first
        audioBuffer.setActive(false)

        await teardownAudioEngine()

        isRecording = false

        // Final transcription of complete buffer
        let finalBuffer = audioBuffer.getAndClear()

        // Use hardcoded 16000 since minBufferSamples is gone/private
        if finalBuffer.count > 16000, let whisperKit = whisperKit {
            do {
                // Get configuration for final transcription
                let config = WhisperConfigurationStore.load()

                let options = DecodingOptions(
                    task: .transcribe,
                    language: config.languageHint,
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

    // MARK: - Audio Engine Helpers

    /// Teardown the audio engine and worker to ensure a clean state
    private func teardownAudioEngine() async {
        // Stop worker first
        await transcriptionWorker?.stop()
        transcriptionWorker = nil

        // Stop system audio polling if active
        systemAudioPollingTask?.cancel()
        systemAudioPollingTask = nil

        // Stop system audio capture if we were using it
        if isUsingSystemAudio {
            if #available(macOS 12.3, *) {
                await SystemAudioCaptureManager.shared.stopCapture()
            }
            isUsingSystemAudio = false
        }

        // Stop engine and remove tap
        if let engine = audioEngine {
            print("[WhisperKitService] Tearing down audio engine...")
            if engine.isRunning {
                engine.stop()
            }
            // Remove tap if it exists (safe to call even if not)
            engine.inputNode.removeTap(onBus: 0)

            // Release engine
            audioEngine = nil

            // Allow Core Audio to cleanup to prevent "thread already exists" errors
            try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms
        }
    }

    /// Start polling system audio samples into the audio buffer
    private func startSystemAudioPolling() {
        let bufferRef = audioBuffer
        systemAudioPollingTask = Task { @MainActor [weak self] in
            print("[WhisperKitService] Started system audio polling")
            while let self = self, bufferRef.isActive {
                // Get samples from SystemAudioCaptureManager
                let samples = SystemAudioCaptureManager.shared.getAndClearSamples()
                if !samples.isEmpty {
                    bufferRef.append(samples)

                    // Calculate audio level for visualization
                    let sum = samples.reduce(0) { $0 + $1 * $1 }
                    let rms = sqrt(sum / Float(samples.count))
                    bufferRef.setLevel(min(1.0, rms * 10))
                }

                // Poll every 50ms
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            print("[WhisperKitService] System audio polling stopped")
        }
    }

    /// Setup the audio engine in a detached task
    private func setupAudioEngine(targetDeviceId: AudioDeviceID?, buffer: ThreadSafeAudioBuffer) async throws -> (
        AVAudioEngine, AVAudioFormat
    ) {
        // Use detached task to avoid blocking main thread with CoreAudio operations
        return try await Task.detached(priority: .userInitiated) { () -> (AVAudioEngine, AVAudioFormat) in
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode

            // 1. Set Input Device if requested
            if let deviceId = targetDeviceId {
                print("[WhisperKitService] Setting input device to AudioDeviceID: \(deviceId)")
                Self.setInputDevice(deviceId, for: inputNode)
            } else {
                print("[WhisperKitService] Using system default input device")
            }

            // 2. Determine Format
            // CRITICAL: Get format *after* setting device to ensure it matches the actual hardware
            let hwFormat = inputNode.inputFormat(forBus: 0)
            print(
                "[WhisperKitService] Hardware input format: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount) channels"
            )

            // Create a compatible tap format (Float32, 1 channel)
            // If hardware is 0Hz/0ch (error state), fallback to 48kHz
            let sampleRate = hwFormat.sampleRate > 0 ? hwFormat.sampleRate : 48000
            guard
                let tapFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sampleRate,
                    channels: 1,
                    interleaved: false
                )
            else {
                throw WhisperKitError.transcriptionFailed("Failed to create audio format")
            }

            print("[WhisperKitService] Using tap format: \(tapFormat.sampleRate)Hz")

            // 3. Install Tap
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { tapBuffer, _ in
                guard buffer.isActive else { return }

                // Process audio buffer
                guard let floatData = tapBuffer.floatChannelData?[0] else { return }
                let frameCount = Int(tapBuffer.frameLength)
                guard frameCount > 0 else { return }

                // Calculate RMS for UI
                var sum: Float = 0
                for i in 0 ..< frameCount {
                    let sample = floatData[i]
                    sum += sample * sample
                }
                let rms = sqrt(sum / Float(frameCount))
                buffer.setLevel(min(1.0, rms * 10))

                // Append samples
                let samples = Array(UnsafeBufferPointer(start: floatData, count: frameCount))
                buffer.append(samples)
            }

            // 4. Start Engine with Retry Logic
            engine.prepare()

            var lastError: Error?
            for attempt in 1 ... 3 {
                do {
                    try engine.start()
                    print("[WhisperKitService] Audio engine started successfully on attempt \(attempt)")
                    lastError = nil
                    break
                } catch {
                    print("[WhisperKitService] Engine start attempt \(attempt) failed: \(error)")
                    lastError = error
                    // Backoff before retry
                    try? await Task.sleep(nanoseconds: UInt64(attempt * 200_000_000))
                    engine.prepare()
                }
            }

            if let error = lastError {
                throw error
            }

            return (engine, tapFormat)
        }.value
    }

    private func startAudioLevelMonitoring() {
        let bufferRef = audioBuffer
        Task { @MainActor [weak self] in
            while let self = self, bufferRef.isActive {
                self.audioLevel = bufferRef.getLevel()
                try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
            }
            self?.audioLevel = 0
        }
    }

    private func startWorkerProcessing() {
        guard let worker = transcriptionWorker else { return }
        Task {
            print("[WhisperKitService] Starting to consume worker updates")
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
            print("[WhisperKitService] Worker updates stream finished")
        }
    }

    /// Clear transcription state
    public func clearTranscription() {
        currentTranscription = ""
        confirmedTranscription = ""
        audioBuffer.clear()
    }

    // MARK: - Audio Device Helpers

    /// Set the input device for an AVAudioEngine's input node using CoreAudio
    private nonisolated static func setInputDevice(_ deviceId: AudioDeviceID, for inputNode: AVAudioInputNode) {
        // Access the input node to ensure the graph is built
        // This triggers the creation of the underlying AudioUnit
        _ = inputNode.inputFormat(forBus: 0)

        // Get the underlying AudioUnit from the input node
        guard let audioUnit = inputNode.audioUnit else {
            print("[WhisperKitService] Failed to get audioUnit from inputNode")
            return
        }

        // Set the input device
        var mutableDeviceId = deviceId
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceId,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status != noErr {
            print("[WhisperKitService] Failed to set input device: \(status). Error code: \(status)")
        } else {
            print("[WhisperKitService] Successfully set input device to AudioDeviceID: \(deviceId)")
        }
    }

    /// Get the current input device ID from an audio engine's input node
    private nonisolated static func getCurrentInputDevice(for inputNode: AVAudioInputNode) -> AudioDeviceID? {
        guard let audioUnit = inputNode.audioUnit else { return nil }

        var deviceId = AudioDeviceID()
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceId,
            &propertySize
        )

        guard status == noErr else { return nil }
        return deviceId
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

    // Configuration from WhisperConfigurationStore
    private let languageHint: String?

    // VAD Parameters (configured via sensitivity)
    private let silenceThresholdSeconds: Double
    private let maxSegmentDurationSeconds: Double = 30.0
    private let speechEnergyThreshold: Float
    private let minSamples = 16000  // 1 second

    init(
        whisperKit: WhisperKit,
        audioBuffer: ThreadSafeAudioBuffer,
        inputFormat: AVAudioFormat,
        languageHint: String? = nil,
        sensitivity: VoiceSensitivity = .medium
    ) {
        self.whisperKit = whisperKit
        self.audioBuffer = audioBuffer
        self.inputFormat = inputFormat
        self.languageHint = languageHint
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        // Apply sensitivity-based VAD thresholds
        self.speechEnergyThreshold = sensitivity.energyThreshold
        self.silenceThresholdSeconds = sensitivity.silenceThresholdSeconds
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
        print("[TranscriptionWorker] Input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channels")
        print(
            "[TranscriptionWorker] Target format: \(targetFormat.sampleRate)Hz, \(targetFormat.channelCount) channels"
        )

        self.converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        if self.converter == nil {
            print(
                "[TranscriptionWorker] Failed to create audio converter from \(inputFormat.sampleRate)Hz to \(targetFormat.sampleRate)Hz"
            )
        } else {
            print("[TranscriptionWorker] Audio converter created successfully")
        }

        var lastSpeechTime = Date()
        var isSpeaking = false
        var segmentStartTime = Date()
        var accumulatedSamples: [Float] = []

        while audioBuffer.isActive {
            // Check for task cancellation explicitly
            if Task.isCancelled {
                print("[TranscriptionWorker] Task was cancelled, stopping")
                break
            }

            // Sleep with error handling - don't break on CancellationError if buffer is still active
            do {
                try await Task.sleep(nanoseconds: 100_000_000)  // Check every 100ms
            } catch is CancellationError {
                // Only exit if buffer is inactive, otherwise continue
                if !audioBuffer.isActive {
                    print("[TranscriptionWorker] Sleep cancelled and buffer inactive, stopping")
                    break
                }
                // Otherwise, continue the loop - spurious cancellation
                continue
            } catch {
                print("[TranscriptionWorker] Sleep error: \(error)")
                continue
            }

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
        }

        print("[TranscriptionWorker] Exiting run loop, buffer active: \(audioBuffer.isActive)")
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
            print("[TranscriptionWorker] Finalizing segment with language=\(languageHint ?? "auto")")

            let options = DecodingOptions(
                task: .transcribe,
                language: languageHint,
                usePrefillPrompt: true,
                wordTimestamps: false
            )

            let results = try await whisperKit.transcribe(audioArray: buffer, decodeOptions: options)
            if let result = results.first {
                print(
                    "[TranscriptionWorker] Result - language=\(result.language ?? "unknown"), text=\(result.text.prefix(50))..."
                )
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
                language: languageHint,
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

/// Audio-level VAD settings for speech detection during transcription
/// (Separate from VADConfiguration which handles persona wake-word activation)
public struct VADAudioSettings {
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
