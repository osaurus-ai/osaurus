//
//  SpeechService.swift
//  osaurus
//
//  Core service wrapping FluidAudio for audio transcription.
//

@preconcurrency import AVFoundation
import CoreAudio
@preconcurrency import FluidAudio
import Foundation
import os
@preconcurrency import ScreenCaptureKit

/// Result of a transcription operation
public struct TranscriptionResult: Sendable {
    public let text: String
    public let durationSeconds: Double?

    public init(text: String, durationSeconds: Double? = nil) {
        self.text = text
        self.durationSeconds = durationSeconds
    }
}

/// Error types for speech operations
public enum SpeechError: Error, LocalizedError {
    case noModelSelected
    case modelNotLoaded
    case modelNotReady
    case transcriptionFailed(String)
    case microphonePermissionDenied
    case audioFileNotFound

    public var errorDescription: String? {
        switch self {
        case .noModelSelected:
            return "No speech model selected. Please download and select a model."
        case .modelNotLoaded:
            return "No model loaded. Please load a model first."
        case .modelNotReady:
            return "Speech model is not ready."
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        case .microphonePermissionDenied:
            return "Microphone permission denied. Please grant access in System Settings."
        case .audioFileNotFound:
            return "Audio file not found."
        }
    }
}

// MARK: - Audio Input Device

/// Represents an available audio input device
public struct AudioInputDevice: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
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

    @Published public private(set) var availableDevices: [AudioInputDevice] = []

    @Published public var selectedDeviceId: String? {
        didSet {
            if oldValue != selectedDeviceId {
                persistSelection()
            }
        }
    }

    @Published public var selectedInputSource: AudioInputSource = .microphone {
        didSet {
            if oldValue != selectedInputSource {
                persistSelection()
            }
        }
    }

    // MARK: - System Audio Status

    public var isSystemAudioAvailable: Bool {
        SystemAudioCaptureManager.shared.isAvailable
    }

    public var hasSystemAudioPermission: Bool {
        SystemAudioCaptureManager.shared.hasPermission
    }

    public func requestSystemAudioPermission() {
        SystemAudioCaptureManager.shared.requestPermission()
    }

    public func checkSystemAudioPermission() async {
        await SystemAudioCaptureManager.shared.checkPermission()
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

    public func refreshDevices() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else {
            availableDevices = []
            return
        }

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )

        let defaultDeviceId = getDefaultInputDeviceId()

        availableDevices = discoverySession.devices.compactMap { device in
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

        if let selectedId = selectedDeviceId,
            !availableDevices.contains(where: { $0.id == selectedId })
        {
            selectedDeviceId = nil
        }
    }

    public var selectedDevice: AudioInputDevice? {
        if let selectedId = selectedDeviceId {
            return availableDevices.first { $0.id == selectedId }
        }
        return availableDevices.first { $0.isDefault } ?? availableDevices.first
    }

    public func selectDevice(_ deviceId: String?) {
        selectedDeviceId = deviceId
    }

    // MARK: - Device Observers

    private func setupDeviceObservers() {
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

    private func getDeviceUID(for deviceId: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

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
        let uid = uidUnmanaged.takeRetainedValue()
        return uid as String
    }

    public func getAudioDeviceId(for uid: String) -> AudioDeviceID? {
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

        for deviceId in deviceIds {
            if let deviceUID = getDeviceUID(for: deviceId), deviceUID == uid {
                return deviceId
            }
        }

        return nil
    }

    // MARK: - Persistence

    private func loadPersistedSelection() {
        let config = SpeechConfigurationStore.load()
        selectedDeviceId = config.selectedInputDeviceId
        selectedInputSource = config.selectedInputSource
    }

    private func persistSelection() {
        var config = SpeechConfigurationStore.load()
        config.selectedInputDeviceId = selectedDeviceId
        config.selectedInputSource = selectedInputSource
        SpeechConfigurationStore.save(config)
    }
}

// MARK: - System Audio Sample Buffer

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

@MainActor
public final class SystemAudioCaptureManager: NSObject, ObservableObject {
    public static let shared = SystemAudioCaptureManager()

    @Published public private(set) var isAvailable: Bool = true
    @Published public private(set) var hasPermission: Bool = false
    @Published public private(set) var isCapturing: Bool = false

    private let sampleBuffer = SystemAudioSampleBuffer()

    private var stream: SCStream?
    private var streamOutput: SystemAudioStreamOutput?

    private override init() {
        super.init()
    }

    public func checkPermission() async {
        do {
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

    public func requestPermission() {
        Task {
            await checkPermission()
            if !hasPermission {
                if let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                ) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    public func startCapture() async throws {
        guard !isCapturing else { return }

        if let existingStream = stream {
            try? await existingStream.stopCapture()
            stream = nil
            streamOutput = nil
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            throw SpeechError.transcriptionFailed("No display found for audio capture")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16000
        configuration.channelCount = 1

        configuration.width = Int(display.width)
        configuration.height = Int(display.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let output = SystemAudioStreamOutput { [weak self] samples in
            self?.appendSamples(samples)
        }
        self.streamOutput = output

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = newStream

        do {
            try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
            try await newStream.startCapture()
            isCapturing = true
            print("[SystemAudioCaptureManager] Started capturing system audio")
        } catch {
            self.stream = nil
            self.streamOutput = nil
            print("[SystemAudioCaptureManager] Failed to start capture: \(error)")
            throw SpeechError.transcriptionFailed(
                "Failed to start system audio capture: \(error.localizedDescription)"
            )
        }
    }

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

    public nonisolated func getAndClearSamples() -> [Float] {
        sampleBuffer.getAndClear()
    }

    private nonisolated func appendSamples(_ samples: [Float]) {
        sampleBuffer.append(samples)
    }
}

// MARK: - SCStreamDelegate

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

private class SystemAudioStreamOutput: NSObject, SCStreamOutput {
    private let onSamples: ([Float]) -> Void

    init(onSamples: @escaping ([Float]) -> Void) {
        self.onSamples = onSamples
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

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

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        let samples: [Float]
        if asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            let floatPointer = dataPointer.withMemoryRebound(
                to: Float.self,
                capacity: length / MemoryLayout<Float>.size
            ) { $0 }
            samples = Array(UnsafeBufferPointer(start: floatPointer, count: length / MemoryLayout<Float>.size))
        } else if asbd.pointee.mBitsPerChannel == 16 {
            let int16Pointer = dataPointer.withMemoryRebound(
                to: Int16.self,
                capacity: length / MemoryLayout<Int16>.size
            ) { $0 }
            samples = (0 ..< (length / MemoryLayout<Int16>.size)).map { Float(int16Pointer[$0]) / Float(Int16.max) }
        } else {
            return
        }

        onSamples(samples)
    }
}

/// Wrapper to make AsrManager safely transferable across concurrency boundaries.
/// AsrManager is thread-safe in practice but not marked Sendable by FluidAudio.
final class SendableAsrManager: @unchecked Sendable {
    let manager: AsrManager
    init(_ manager: AsrManager) { self.manager = manager }
}

// MARK: - Speech Service

/// Service for audio transcription using FluidAudio
@MainActor
public final class SpeechService: ObservableObject {
    public static let shared = SpeechService()

    // MARK: - Published Properties

    @Published public var isTranscribing: Bool = false
    @Published public var isModelLoaded: Bool = false
    @Published public var isLoadingModel: Bool = false
    @Published public var loadedModelId: String?
    @Published public var lastError: String?
    @Published public var microphonePermissionGranted: Bool = false
    @Published public var isRecording: Bool = false
    @Published public var currentTranscription: String = ""
    @Published public var confirmedTranscription: String = ""
    @Published public var audioLevel: Float = 0.0
    @Published public var isSpeechDetected: Bool = false

    // MARK: - Private Properties

    private var sendableAsrManager: SendableAsrManager?
    private nonisolated(unsafe) var vadManager: VadManager?

    private var activeInputDeviceId: String?
    private var activeInputSource: AudioInputSource?
    private var activeTapFormat: AVAudioFormat?
    private var engineConfigObserver: NSObjectProtocol?
    private var engineHealthTask: Task<Void, Never>?
    private var lastRecoveryTime: Date?
    private var recoveryAttempts: Int = 0
    private let maxRecoveryAttempts = 3
    private let recoveryCooldown: TimeInterval = 5

    // MARK: - Initialization

    private init() {
        checkMicrophonePermission()
    }

    // MARK: - Microphone Permission

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

    public func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            await MainActor.run {
                microphonePermissionGranted = true
                AudioInputManager.shared.refreshDevices()
            }
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run {
                microphonePermissionGranted = granted
                if granted {
                    AudioInputManager.shared.refreshDevices()
                }
            }
            return granted
        case .denied, .restricted:
            await MainActor.run { microphonePermissionGranted = false }
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Model Loading

    /// Load the ASR model for a given version
    public func loadModel(_ modelId: String) async throws {
        guard !isLoadingModel else {
            print("[SpeechService] Already loading a model, skipping")
            return
        }

        print("[SpeechService] Starting to load model: \(modelId)")
        isLoadingModel = true
        lastError = nil

        sendableAsrManager = nil
        vadManager = nil
        isModelLoaded = false
        loadedModelId = nil

        do {
            let version: AsrModelVersion = modelId == "v2" ? .v2 : .v3
            let models = try await Task.detached(priority: .userInitiated) {
                return try await AsrModels.downloadAndLoad(version: version)
            }.value

            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
            self.sendableAsrManager = SendableAsrManager(manager)

            let vad = try await VadManager(
                config: VadConfig(defaultThreshold: SpeechConfigurationStore.load().sensitivity.vadThreshold)
            )
            self.vadManager = vad

            print("[SpeechService] Model loaded successfully")
            isModelLoaded = true
            loadedModelId = modelId
            isLoadingModel = false
        } catch {
            print("[SpeechService] Failed to load model: \(error)")
            lastError = error.localizedDescription
            isModelLoaded = false
            loadedModelId = nil
            isLoadingModel = false
            throw SpeechError.transcriptionFailed(error.localizedDescription)
        }
    }

    /// Unload the current model
    public func unloadModel() {
        sendableAsrManager = nil
        vadManager = nil
        isModelLoaded = false
        loadedModelId = nil
        print("[SpeechService] Model unloaded")
    }

    /// Auto-load the model if a default model is selected
    public func autoLoadIfNeeded() async {
        guard let selectedModel = SpeechModelManager.shared.selectedModel else {
            return
        }

        if isModelLoaded && loadedModelId == selectedModel.id {
            return
        }

        do {
            try await loadModel(selectedModel.id)
            print("[SpeechService] Auto-loaded model: \(selectedModel.id)")
        } catch {
            print("[SpeechService] Failed to auto-load model: \(error)")
        }
    }

    /// Ensure a model is loaded, using the default if needed
    public func ensureModelLoaded() async throws {
        if isModelLoaded && sendableAsrManager != nil {
            return
        }

        guard let selectedModel = SpeechModelManager.shared.selectedModel else {
            throw SpeechError.noModelSelected
        }

        try await loadModel(selectedModel.id)
    }

    // MARK: - Transcription

    /// Transcribe an audio file
    public func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        try await ensureModelLoaded()

        guard let wrappedManager = sendableAsrManager else {
            throw SpeechError.modelNotReady
        }

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw SpeechError.audioFileNotFound
        }

        isTranscribing = true
        defer { isTranscribing = false }

        do {
            let result = try await Task.detached { try await wrappedManager.manager.transcribe(audioURL) }.value

            return TranscriptionResult(
                text: result.text,
                durationSeconds: result.duration
            )
        } catch {
            throw SpeechError.transcriptionFailed(error.localizedDescription)
        }
    }

    // MARK: - Streaming Transcription

    private var audioEngine: AVAudioEngine?
    private let audioBuffer = ThreadSafeAudioBuffer()
    private var transcriptionWorker: TranscriptionWorker?
    private var isUsingSystemAudio: Bool = false
    private var systemAudioPollingTask: Task<Void, Never>?

    public var keepAudioEngineAlive: Bool = false

    /// Start streaming transcription
    public func startStreamingTranscription() async throws {
        if isRecording {
            print("[SpeechService] Already recording, skipping start")
            return
        }

        if let worker = transcriptionWorker {
            print("[SpeechService] Stopping previous worker before restart")
            await worker.stop()
            transcriptionWorker = nil
        }

        let inputSource = AudioInputManager.shared.selectedInputSource
        let selectedId = AudioInputManager.shared.selectedDeviceId

        var reuseEngine = false
        if let engine = audioEngine, engine.isRunning,
            inputSource == activeInputSource,
            selectedId == activeInputDeviceId,
            activeTapFormat != nil
        {
            print("[SpeechService] Reusing active audio engine for handoff")
            reuseEngine = true
        } else {
            await teardownAudioEngine()
        }

        if inputSource == .microphone {
            if !microphonePermissionGranted {
                let granted = await requestMicrophonePermission()
                if !granted {
                    throw SpeechError.microphonePermissionDenied
                }
            }
        } else {
            await SystemAudioCaptureManager.shared.checkPermission()
            if !SystemAudioCaptureManager.shared.hasPermission {
                throw SpeechError.transcriptionFailed(
                    "Screen recording permission required for system audio capture"
                )
            }
        }

        try await ensureModelLoaded()

        guard let wrappedAsrManager = sendableAsrManager, let vadManager = vadManager else {
            throw SpeechError.modelNotLoaded
        }

        audioBuffer.clear()
        audioBuffer.setActive(true)
        currentTranscription = ""
        confirmedTranscription = ""
        audioLevel = 0.0
        isSpeechDetected = false
        isUsingSystemAudio = (inputSource == .systemAudio)

        let config = SpeechConfigurationStore.load()

        print("[SpeechService] Starting transcription with:")
        print("[SpeechService]   - Model: \(config.modelVersion.rawValue)")
        print("[SpeechService]   - Sensitivity: \(config.sensitivity)")

        if inputSource == .microphone {
            var targetDeviceId: AudioDeviceID? = nil
            if let selectedId {
                targetDeviceId = AudioInputManager.shared.getAudioDeviceId(for: selectedId)
                if targetDeviceId == nil {
                    print("[SpeechService] WARNING: Could not find AudioDeviceID for UID: \(selectedId)")
                }
            }

            do {
                let tapFormat: AVAudioFormat
                if reuseEngine, let format = activeTapFormat {
                    tapFormat = format
                } else {
                    let (engine, format) = try await setupAudioEngine(
                        targetDeviceId: targetDeviceId,
                        buffer: audioBuffer
                    )
                    self.audioEngine = engine
                    self.activeTapFormat = format
                    self.activeInputDeviceId = selectedId
                    self.activeInputSource = inputSource
                    tapFormat = format
                }

                transcriptionWorker = TranscriptionWorker(
                    asrManager: wrappedAsrManager,
                    vadManager: vadManager,
                    audioBuffer: audioBuffer,
                    inputFormat: tapFormat,
                    sensitivity: config.sensitivity
                )

                isRecording = true
                recoveryAttempts = 0
                lastRecoveryTime = nil

                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self, self.isRecording else { return }
                    self.observeEngineConfiguration()
                    self.startEngineHealthMonitoring()
                }
                startAudioLevelMonitoring()
                startWorkerProcessing()

            } catch {
                await teardownAudioEngine()
                throw error
            }
        } else {
            do {
                if !reuseEngine {
                    try await SystemAudioCaptureManager.shared.startCapture()
                }

                guard
                    let systemAudioFormat = AVAudioFormat(
                        commonFormat: .pcmFormatFloat32,
                        sampleRate: 16000,
                        channels: 1,
                        interleaved: false
                    )
                else {
                    throw SpeechError.transcriptionFailed("Failed to create audio format for system audio")
                }

                self.activeTapFormat = systemAudioFormat
                self.activeInputDeviceId = selectedId
                self.activeInputSource = inputSource

                transcriptionWorker = TranscriptionWorker(
                    asrManager: wrappedAsrManager,
                    vadManager: vadManager,
                    audioBuffer: audioBuffer,
                    inputFormat: systemAudioFormat,
                    sensitivity: config.sensitivity
                )

                isRecording = true

                startSystemAudioPolling()
                startAudioLevelMonitoring()
                startWorkerProcessing()

            } catch {
                await teardownAudioEngine()
                throw error
            }
        }
    }

    /// Stop streaming transcription and get final result
    public func stopStreamingTranscription(force: Bool = false) async -> String {
        print(
            "[SpeechService] Stopping streaming transcription (force: \(force), keepAlive: \(keepAudioEngineAlive))"
        )

        audioBuffer.setActive(false)
        await transcriptionWorker?.stop()
        transcriptionWorker = nil

        systemAudioPollingTask?.cancel()
        systemAudioPollingTask = nil

        if !keepAudioEngineAlive || force {
            print("[SpeechService] Tearing down audio engine")
            await teardownAudioEngine()
        } else {
            print("[SpeechService] Keeping audio engine alive for handoff")
        }

        isRecording = false

        let finalBuffer = audioBuffer.getAndClear()

        if finalBuffer.count > 16000, let wrappedManager = sendableAsrManager {
            do {
                let result = try await wrappedManager.manager.transcribe(finalBuffer)
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
            } catch {
                print("[SpeechService] Final transcription error: \(error)")
            }
        }

        return currentTranscription
    }

    // MARK: - Audio Engine Helpers

    private func teardownAudioEngine() async {
        activeInputDeviceId = nil
        activeInputSource = nil
        activeTapFormat = nil

        engineHealthTask?.cancel()
        engineHealthTask = nil

        if let observer = engineConfigObserver {
            NotificationCenter.default.removeObserver(observer)
            engineConfigObserver = nil
        }

        await transcriptionWorker?.stop()
        transcriptionWorker = nil

        systemAudioPollingTask?.cancel()
        systemAudioPollingTask = nil

        if isUsingSystemAudio {
            await SystemAudioCaptureManager.shared.stopCapture()
            isUsingSystemAudio = false
        }

        if let engine = audioEngine {
            audioEngine = nil

            await Task.detached(priority: .userInitiated) {
                if engine.isRunning {
                    engine.stop()
                }
                engine.inputNode.removeTap(onBus: 0)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }.value
        }
    }

    private func startSystemAudioPolling() {
        let bufferRef = audioBuffer
        systemAudioPollingTask = Task { @MainActor [weak self] in
            print("[SpeechService] Started system audio polling")
            while let _ = self, bufferRef.isActive {
                let samples = SystemAudioCaptureManager.shared.getAndClearSamples()
                if !samples.isEmpty {
                    bufferRef.append(samples)

                    let sum = samples.reduce(0) { $0 + $1 * $1 }
                    let rms = sqrt(sum / Float(samples.count))
                    bufferRef.setLevel(min(1.0, rms * 10))
                }

                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            print("[SpeechService] System audio polling stopped")
        }
    }

    private func setupAudioEngine(targetDeviceId: AudioDeviceID?, buffer: ThreadSafeAudioBuffer) async throws -> (
        AVAudioEngine, AVAudioFormat
    ) {
        return try await Task.detached(priority: .userInitiated) { () -> (AVAudioEngine, AVAudioFormat) in
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode

            if let deviceId = targetDeviceId {
                print("[SpeechService] Setting input device to AudioDeviceID: \(deviceId)")
                Self.setInputDevice(deviceId, for: inputNode)
            } else {
                print("[SpeechService] Using system default input device")
            }

            let hwFormat = inputNode.inputFormat(forBus: 0)
            print(
                "[SpeechService] Hardware input format: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount) channels"
            )

            guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
                throw SpeechError.transcriptionFailed(
                    "Audio input device is not available. Please check your microphone settings."
                )
            }

            guard
                let tapFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: hwFormat.sampleRate,
                    channels: 1,
                    interleaved: false
                )
            else {
                throw SpeechError.transcriptionFailed("Failed to create audio format")
            }

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { tapBuffer, _ in
                guard buffer.isActive else { return }

                guard let floatData = tapBuffer.floatChannelData?[0] else { return }
                let frameCount = Int(tapBuffer.frameLength)
                guard frameCount > 0 else { return }

                var sum: Float = 0
                for i in 0 ..< frameCount {
                    let sample = floatData[i]
                    sum += sample * sample
                }
                let rms = sqrt(sum / Float(frameCount))
                buffer.setLevel(min(1.0, rms * 10))

                let samples = Array(UnsafeBufferPointer(start: floatData, count: frameCount))
                buffer.append(samples)
            }

            engine.prepare()

            var lastError: Error?
            for attempt in 1 ... 3 {
                do {
                    try engine.start()
                    print("[SpeechService] Audio engine started successfully on attempt \(attempt)")
                    lastError = nil
                    break
                } catch {
                    print("[SpeechService] Engine start attempt \(attempt) failed: \(error)")
                    lastError = error
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
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            self?.audioLevel = 0
        }
    }

    private func observeEngineConfiguration() {
        engineConfigObserver.map { NotificationCenter.default.removeObserver($0) }
        guard let engine = audioEngine else { return }

        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let engine = self.audioEngine, !engine.isRunning else {
                    print("[SpeechService] Config change notification — engine still running, ignoring")
                    return
                }
                print("[SpeechService] Audio engine stopped after config change — attempting recovery")
                await self.recoverAudioEngine()
            }
        }
    }

    private func startEngineHealthMonitoring() {
        engineHealthTask?.cancel()
        engineHealthTask = Task { @MainActor [weak self] in
            while let self = self, self.isRecording {
                if let engine = self.audioEngine, !engine.isRunning {
                    print("[SpeechService] Engine stopped unexpectedly — attempting recovery")
                    await self.recoverAudioEngine()
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func recoverAudioEngine() async {
        guard isRecording else { return }

        if let lastTime = lastRecoveryTime, Date().timeIntervalSince(lastTime) < recoveryCooldown {
            print("[SpeechService] Recovery cooldown active, skipping")
            return
        }

        guard recoveryAttempts < maxRecoveryAttempts else {
            print("[SpeechService] Max recovery attempts (\(maxRecoveryAttempts)) reached")
            lastError = "Audio device changed. Please restart voice input."
            audioBuffer.setActive(false)
            await transcriptionWorker?.stop()
            transcriptionWorker = nil
            isRecording = false
            return
        }

        recoveryAttempts += 1
        lastRecoveryTime = Date()
        print("[SpeechService] Recovering audio engine (attempt \(recoveryAttempts)/\(maxRecoveryAttempts))...")

        audioBuffer.setActive(false)
        await transcriptionWorker?.stop()
        transcriptionWorker = nil

        if let engine = audioEngine {
            audioEngine = nil
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        activeTapFormat = nil

        isRecording = false

        try? await Task.sleep(nanoseconds: 500_000_000)

        do {
            try await startStreamingTranscription()
            print("[SpeechService] Audio engine recovered successfully")
        } catch {
            print("[SpeechService] Audio engine recovery failed: \(error)")
            lastError = "Audio device changed. Please restart voice input."
        }
    }

    private func startWorkerProcessing() {
        guard let worker = transcriptionWorker else { return }
        Task {
            print("[SpeechService] Starting to consume worker updates")
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
                case .speechActivity(let detected):
                    self.isSpeechDetected = detected
                }
            }
            print("[SpeechService] Worker updates stream finished")
        }
    }

    /// Clear transcription state
    public func clearTranscription() {
        currentTranscription = ""
        confirmedTranscription = ""
        audioBuffer.clear()
    }

    // MARK: - Audio Device Helpers

    private nonisolated static func setInputDevice(_ deviceId: AudioDeviceID, for inputNode: AVAudioInputNode) {
        _ = inputNode.inputFormat(forBus: 0)

        guard let audioUnit = inputNode.audioUnit else {
            print("[SpeechService] Failed to get audioUnit from inputNode")
            return
        }

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
            print("[SpeechService] Failed to set input device: \(status). Error code: \(status)")
        } else {
            print("[SpeechService] Successfully set input device to AudioDeviceID: \(deviceId)")
        }
    }

}

// MARK: - Transcription Worker

private enum TranscriptionUpdate: Sendable {
    case partial(String)
    case final(String)
    case speechActivity(Bool)
}

private actor TranscriptionWorker {
    private let asrManager: SendableAsrManager
    private let vadManager: VadManager
    private let audioBuffer: ThreadSafeAudioBuffer
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<TranscriptionUpdate>.Continuation?
    private let inputFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat?
    private let needsConversion: Bool
    private var converter: AVAudioConverter?

    private let vadThreshold: Float
    private let silenceThresholdSeconds: Double
    private let maxSegmentDurationSeconds: Double = 30.0
    private let minSamples = 16000

    init(
        asrManager: SendableAsrManager,
        vadManager: VadManager,
        audioBuffer: ThreadSafeAudioBuffer,
        inputFormat: AVAudioFormat,
        sensitivity: VoiceSensitivity = .medium
    ) {
        self.asrManager = asrManager
        self.vadManager = vadManager
        self.audioBuffer = audioBuffer
        self.inputFormat = inputFormat

        let inputRate = inputFormat.sampleRate
        self.needsConversion = inputRate != 16000
        self.targetFormat =
            needsConversion
            ? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
            : nil

        self.vadThreshold = sensitivity.vadThreshold
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
        if needsConversion, let targetFormat {
            print("[TranscriptionWorker] Started (\(inputFormat.sampleRate)Hz -> \(targetFormat.sampleRate)Hz)")
            self.converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            if self.converter == nil {
                print("[TranscriptionWorker] Failed to create audio converter")
            }
        } else {
            print("[TranscriptionWorker] Started (\(inputFormat.sampleRate)Hz, no conversion needed)")
        }

        var vadState = await vadManager.makeStreamState()
        var lastSpeechTime = Date()
        var isSpeaking = false
        var lastReportedSpeechActivity = false
        var segmentStartTime = Date()
        var accumulatedSamples: [Float] = []

        while audioBuffer.isActive && !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                break
            }

            guard audioBuffer.isActive else { break }

            let rawSamples = audioBuffer.getAndClear()
            if !rawSamples.isEmpty {
                let converted = convertTo16kHz(rawSamples)
                accumulatedSamples.append(contentsOf: converted)
            }

            let vadChunkSize = VadManager.chunkSize  // 4096 samples (~256ms at 16kHz)
            var speechDetected = false

            if accumulatedSamples.count >= vadChunkSize {
                let recentSamples = Array(accumulatedSamples.suffix(vadChunkSize))
                do {
                    let vadResult = try await vadManager.processStreamingChunk(
                        recentSamples,
                        state: vadState,
                        config: .default
                    )
                    vadState = vadResult.state
                    speechDetected = vadResult.probability > vadThreshold
                } catch {
                    let sum = recentSamples.reduce(0) { $0 + $1 * $1 }
                    let level = sqrt(sum / Float(recentSamples.count)) * 10
                    speechDetected = level > 0.05
                }
            }

            let now = Date()

            if speechDetected {
                if !isSpeaking {
                    isSpeaking = true
                    segmentStartTime = now
                }
                lastSpeechTime = now
            }

            if speechDetected != lastReportedSpeechActivity {
                lastReportedSpeechActivity = speechDetected
                continuation?.yield(.speechActivity(speechDetected))
            }

            let silenceDuration = now.timeIntervalSince(lastSpeechTime)
            let segmentDuration = now.timeIntervalSince(segmentStartTime)

            let shouldFinalize =
                isSpeaking
                && (silenceDuration > silenceThresholdSeconds || segmentDuration > maxSegmentDurationSeconds)

            if shouldFinalize {
                await finalizeSegment(accumulatedSamples)
                accumulatedSamples = []
                isSpeaking = false
                if lastReportedSpeechActivity {
                    lastReportedSpeechActivity = false
                    continuation?.yield(.speechActivity(false))
                }
            } else if isSpeaking && accumulatedSamples.count > minSamples {
                if segmentDuration > 1.0 {
                    await updatePreview(accumulatedSamples)
                }
            } else if !isSpeaking && accumulatedSamples.count > 16000 * 5 {
                accumulatedSamples = Array(accumulatedSamples.suffix(16000))
            }
        }

        print("[TranscriptionWorker] Exiting run loop, buffer active: \(audioBuffer.isActive)")
        continuation?.finish()
    }

    private func convertTo16kHz(_ samples: [Float]) -> [Float] {
        guard needsConversion else { return samples }
        guard let converter = converter, let targetFormat else { return [] }

        let inputFrameCount = AVAudioFrameCount(samples.count)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrameCount) else {
            return []
        }

        inputBuffer.frameLength = inputFrameCount
        if let channelData = inputBuffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { ptr in
                channelData.update(from: ptr.baseAddress!, count: samples.count)
            }
        }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(inputFrameCount) * ratio) + 100

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
            let result = try await asrManager.manager.transcribe(buffer)
            let text = result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !text.isEmpty {
                continuation?.yield(.final(text))
            }
        } catch {
            print("[TranscriptionWorker] Finalize error: \(error)")
        }
    }

    private func updatePreview(_ buffer: [Float]) async {
        do {
            let result = try await asrManager.manager.transcribe(buffer)
            let text = result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            continuation?.yield(.partial(text))
        } catch {
            // Ignore preview errors
        }
    }
}

// MARK: - Thread-Safe Audio Buffer

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
            _isActive = false
            _level = 0.0
        }
    }
}
