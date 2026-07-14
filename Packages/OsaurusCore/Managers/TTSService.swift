//
//  TTSService.swift
//  osaurus
//
//  PocketTTS (FluidAudio) text-to-speech service. Streams 80 ms audio frames
//  from the model into an AVAudioEngine player node for real-time playback.
//

import AVFoundation
import Combine
@preconcurrency import FluidAudio
import Foundation

/// Errors mapped onto tool error envelopes by the `speak` tool.
public enum TTSPlaybackError: Error {
    case modelNotReady
}

/// Model-readiness state for PocketTTS.
public enum TTSModelState: Equatable {
    case notReady
    /// `fraction` is in [0, 1]. `nil` means indeterminate (e.g. compile phase).
    case downloading(fraction: Double?)
    case ready
    case failed(String)
}

/// Singleton that owns the PocketTTS manager, audio engine, and playback lifecycle.
@MainActor
public final class TTSService: ObservableObject {
    public static let shared = TTSService()

    // MARK: - Published state

    /// ID of the message currently being spoken. `nil` when idle.
    @Published public private(set) var playingMessageId: UUID? {
        didSet {
            if oldValue != playingMessageId {
                // Clear the tool-call binding when playback ends so
                // the row's spinner stops alongside the audio.
                if playingMessageId == nil { activeSpeakCallId = nil }
                NotificationCenter.default.post(name: .ttsPlaybackStateChanged, object: nil)
            }
        }
    }

    /// Tracks whether the PocketTTS model is initialized and usable.
    @Published public private(set) var modelState: TTSModelState = .notReady

    /// Tool-call id driving the current playback (`nil` for the manual
    /// speaker button or when idle). The inline tool card watches this
    /// to swap its check for a spinner while audio is still playing.
    @Published public private(set) var activeSpeakCallId: String? {
        didSet {
            if oldValue != activeSpeakCallId {
                NotificationCenter.default.post(name: .ttsPlaybackStateChanged, object: nil)
            }
        }
    }

    // MARK: - Private state

    private var manager: PocketTtsManager?
    private var playbackTask: Task<Void, Never>?
    private var initTask: Task<Void, Never>?

    // Lazy so the singleton can be touched at launch (e.g. `refreshModelState`)
    // without paying for audio-stack construction on the main thread. Building
    // `AVAudioPlayerNode` synchronously queries the AudioComponent registrar
    // over XPC, which can stall launch for seconds under memory pressure. These
    // are only realized on first playback via `configureEngineIfNeeded`, which
    // is user-initiated and off the launch critical path.
    private lazy var audioEngine = AVAudioEngine()
    private lazy var playerNode = AVAudioPlayerNode()
    private let sourceFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        )!
    }()
    private var engineConfigured = false
    private var pendingBufferCount = 0
    private var streamFinished = false

    private init() {}

    // MARK: - Public API

    /// True when the model is fully loaded and ready to synthesize.
    public var isModelReady: Bool {
        if case .ready = modelState { return true }
        return false
    }

    /// Toggle speech for a given message. Tapping the currently-playing
    /// message stops playback; tapping a different message switches to it.
    /// If the model isn't downloaded yet, posts `.openTTSSettingsRequested`.
    public func toggleSpeak(text: String, messageId: UUID, voiceOverride: String? = nil) {
        if playingMessageId == messageId {
            stop()
            return
        }

        guard isModelReady else {
            if Self.pocketTtsModelsExistOnDisk() {
                // Models already downloaded; just load them into memory.
                ensureModelLoaded()
            } else {
                NotificationCenter.default.post(name: .openTTSSettingsRequested, object: nil)
            }
            return
        }

        let plain = MarkdownStripper.plainText(from: text)
        guard !plain.isEmpty else { return }

        stop()
        playingMessageId = messageId
        startPlayback(text: plain, messageId: messageId, voiceOverride: voiceOverride)
    }

    /// Fire-and-forget playback for the `speak` tool. Sets
    /// `activeSpeakCallId` so the row spinner runs until audio drains
    public func startToolPlayback(text: String, messageId: UUID, callId: String, voiceOverride: String? = nil) throws {
        guard isModelReady else {
            if Self.pocketTtsModelsExistOnDisk() {
                ensureModelLoaded()
            } else {
                NotificationCenter.default.post(name: .openTTSSettingsRequested, object: nil)
            }
            throw TTSPlaybackError.modelNotReady
        }
        let plain = MarkdownStripper.plainText(from: text)
        guard !plain.isEmpty else { return }

        stop()
        playingMessageId = messageId
        activeSpeakCallId = callId
        startPlayback(text: plain, messageId: messageId, voiceOverride: voiceOverride)
    }

    /// Stop any in-flight synthesis and clear playback state.
    public func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        streamFinished = true
        pendingBufferCount = 0
        if engineConfigured {
            playerNode.stop()
            playerNode.reset()
        }
        playingMessageId = nil
    }

    /// Begin a background download/initialize. Safe to call multiple times.
    public func ensureModelLoaded() {
        if case .ready = modelState { return }
        if initTask != nil { return }

        modelState = .downloading(fraction: nil)
        let voice = TTSConfigurationStore.load().voice
        initTask = Task { [weak self] in
            do {
                // Route through the downloader explicitly so we get progress callbacks.
                // When models are already cached this returns nearly instantly.
                _ = try await PocketTtsResourceDownloader.ensureModels(
                    directory: nil,
                    progressHandler: { progress in
                        Task { @MainActor in
                            guard let self else { return }
                            let fraction: Double?
                            switch progress.phase {
                            case .downloading:
                                fraction = progress.fractionCompleted
                            case .listing, .compiling:
                                fraction = nil
                            }
                            self.modelState = .downloading(fraction: fraction)
                        }
                    }
                )

                let mgr = PocketTtsManager(defaultVoice: voice)
                try await mgr.initialize()
                await MainActor.run {
                    guard let self else { return }
                    self.manager = mgr
                    self.modelState = .ready
                    self.initTask = nil
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.modelState = .failed(error.localizedDescription)
                    self.initTask = nil
                }
            }
        }
    }

    /// Refresh `modelState` by checking the PocketTTS cache on disk.
    /// Call this on app launch and when returning to the settings tab.
    /// If models are already present, transitions to `.ready` after a fast local load.
    public func refreshModelState() {
        if case .ready = modelState { return }
        if initTask != nil { return }

        // The on-disk probe stats several files (`getattrlist` over XPC), which
        // can block for seconds under filesystem pressure. This runs during
        // `applicationDidFinishLaunching`, so do the probe off the main thread
        // and hop back to update state, keeping launch off the critical path.
        Task.detached(priority: .utility) {
            let exists = Self.pocketTtsModelsExistOnDisk()
            await MainActor.run {
                let service = TTSService.shared
                if case .ready = service.modelState { return }
                if service.initTask != nil { return }
                if exists {
                    service.ensureModelLoaded()
                } else {
                    service.modelState = .notReady
                }
            }
        }
    }

    nonisolated private static func pocketTtsModelsExistOnDisk() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let repoDir =
            home
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("fluidaudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("pocket-tts", isDirectory: true)
        let required = ModelNames.PocketTTS.requiredModels
        let fm = FileManager.default
        return required.allSatisfy { fm.fileExists(atPath: repoDir.appendingPathComponent($0).path) }
    }

    // MARK: - Playback

    private func startPlayback(text: String, messageId: UUID, voiceOverride: String? = nil) {
        do {
            try configureEngineIfNeeded()
        } catch {
            modelState = .failed(error.localizedDescription)
            playingMessageId = nil
            return
        }

        guard let manager else {
            playingMessageId = nil
            return
        }

        streamFinished = false
        pendingBufferCount = 0
        playerNode.play()

        let config = TTSConfigurationStore.load()
        let trimmedOverride = voiceOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedVoice = (trimmedOverride?.isEmpty == false ? trimmedOverride! : config.voice)
        // Fall back to the default when the configured/overridden voice isn't a
        // known PocketTTS voice. A stale or invalid value (e.g. a renamed voice)
        // otherwise 404s fetching its voice prompt and playback dies silently.
        let voice =
            PocketTTSVoiceCatalog.availableVoices.contains(requestedVoice)
            ? requestedVoice : TTSConfiguration.defaultVoice
        let temperature = Float(config.temperature)

        playbackTask = Task { [weak self] in
            do {
                let stream = try await manager.synthesizeStreaming(
                    text: text,
                    voice: voice,
                    temperature: temperature
                )
                for try await frame in stream {
                    if Task.isCancelled { break }
                    self?.schedule(samples: frame.samples)
                }
                self?.markStreamFinished(for: messageId)
            } catch is CancellationError {
                // stop() already cleared state
            } catch {
                self?.handleStreamError(error, for: messageId)
            }
        }
    }

    private func schedule(samples: [Float]) {
        guard let buffer = makeBuffer(from: samples) else { return }
        pendingBufferCount += 1
        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor [weak self] in
                self?.bufferDidFinish()
            }
        }
    }

    private func bufferDidFinish() {
        pendingBufferCount = max(0, pendingBufferCount - 1)
        if streamFinished, pendingBufferCount == 0 {
            playingMessageId = nil
            playerNode.stop()
        }
    }

    private func markStreamFinished(for messageId: UUID) {
        guard playingMessageId == messageId else { return }
        streamFinished = true
        if pendingBufferCount == 0 {
            playingMessageId = nil
            playerNode.stop()
        }
    }

    private func handleStreamError(_ error: Error, for messageId: UUID) {
        print("[TTSService] synthesis error: \(error)")
        if playingMessageId == messageId {
            stop()
        }
    }

    private func makeBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty else { return nil }
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let ptr = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                ptr.update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }

    private func configureEngineIfNeeded() throws {
        if engineConfigured, audioEngine.isRunning { return }
        if !engineConfigured {
            audioEngine.attach(playerNode)
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: sourceFormat)
            engineConfigured = true
        }
        if !audioEngine.isRunning {
            try audioEngine.start()
        }
    }
}

/// built-in PocketTTS voices (kyutai/pocket-tts on HuggingFace). shared by
/// the TTS settings tab and the per-agent voice picker.
public enum PocketTTSVoiceCatalog {
    public static let availableVoices: [String] = [
        "alba", "anna", "azelma", "bill_boerst", "caro_davy", "charles",
        "cosette", "eponine", "eve", "fantine", "george", "jane",
        "javert", "jean", "marius", "mary", "michael", "paul",
        "peter_yearsley", "stuart_bell", "vera",
    ]

    public static func displayName(for voice: String) -> String {
        voice.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

extension Notification.Name {
    /// Posted when the user taps a speaker button but the TTS model isn't ready.
    /// The app should surface the TTS settings tab so they can download the model.
    public static let openTTSSettingsRequested = Notification.Name("osaurus.openTTSSettingsRequested")

    /// Posted whenever `TTSService.playingMessageId` changes.
    /// AppKit views that can't observe `@Published` use this to refresh their speaker button icon.
    public static let ttsPlaybackStateChanged = Notification.Name("osaurus.ttsPlaybackStateChanged")
}
