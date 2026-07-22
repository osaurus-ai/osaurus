//
//  TTSService.swift
//  osaurus
//
//  PocketTTS (FluidAudio) text-to-speech service. Streams 80 ms audio frames
//  from the model into an AVAudioEngine player node for real-time playback.
//

import AVFoundation
import Combine
import OSLog
@preconcurrency import FluidAudio
import Foundation

/// TTS diagnostics. A synthesis failure used to be a bare `print`, which meant a user whose
/// audio silently died had nothing to send us and nothing to read.
enum TTSLogger {
    static let service = Logger(subsystem: "ai.osaurus", category: "tts.service")
}

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

/// Owns the AVAudioEngine + player node and serializes every call to them on a
/// private queue. Engine construction and `start()` make synchronous XPC
/// round-trips to coreaudiod that stalled the main thread for seconds in
/// production, so none of this may run on the main actor.
/// `@unchecked Sendable`: all mutable state is confined to `queue`.
final class TTSAudioPipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.osaurus.tts.audio", qos: .userInitiated)
    private let sourceFormat: AVAudioFormat

    // Lazy so constructing the pipeline stays cheap; the audio stack is only
    // realized on first playback, on `queue`.
    private lazy var engine = AVAudioEngine()
    private lazy var playerNode = AVAudioPlayerNode()
    private var configured = false
    private var needsRebuild = false
    private var changeObserver: NSObjectProtocol?

    /// Invoked (on an arbitrary thread) when the engine reports its graph was
    /// torn down by an output-route change. The owner rebuilds the graph on
    /// the new device and resumes playback (or ends it if the rebuild fails).
    var onConfigurationChange: (@Sendable () -> Void)?

    init(format: AVAudioFormat) {
        self.sourceFormat = format
    }

    /// Configure the engine graph if needed, start the engine, and start the
    /// player node. Runs on the pipeline queue; the caller awaits without
    /// blocking its thread.
    func prepareAndPlay() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.configureIfNeededLocked()
                    self.playerNode.play()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Schedule a PCM frame. `completion` fires exactly once — when the buffer
    /// finishes playing, or immediately if the buffer could not be built — so
    /// the owner's pending-buffer accounting stays balanced.
    func schedule(samples: [Float], completion: @escaping @Sendable () -> Void) {
        queue.async {
            guard let buffer = self.makeBufferLocked(from: samples) else {
                completion()
                return
            }
            self.playerNode.scheduleBuffer(buffer) { completion() }
        }
    }

    /// Stop and reset the player node (drops any scheduled buffers). The
    /// engine itself keeps running so the next playback start is cheap.
    func stopPlayer() {
        queue.async {
            guard self.configured else { return }
            self.playerNode.stop()
            self.playerNode.reset()
        }
    }

    private func configureIfNeededLocked() throws {
        // Do NOT trust `isRunning` alone.
        //
        // When the output device changes — AirPods connecting, the user switching to the
        // built-in speakers, the default device changing — AVAudioEngine tears its graph
        // down and posts `.AVAudioEngineConfigurationChange`, but it keeps reporting
        // `isRunning == true`. Returning early on that would leave the player node wired to
        // a device that no longer exists: buffers are still consumed, their completion
        // handlers still fire, the Stop control still flips back on its own — and not a
        // single sample is audible, with no error anywhere. That is exactly what a silent
        // TTS looks like from the outside.
        //
        // `needsRebuild` is set by the configuration-change observer, so the next
        // playback re-establishes the graph instead of politely doing nothing.
        if needsRebuild {
            if engine.isRunning { engine.stop() }
            configured = false
            needsRebuild = false
        }

        if configured, engine.isRunning { return }
        if !configured {
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: sourceFormat)
            configured = true
            // Registered against the engine we just built, and only once.
            observeEngineConfigurationChangesLocked()
        }
        if !engine.isRunning {
            try engine.start()
        }
    }

    /// The notification arrives on an arbitrary thread; flag flips hop onto
    /// `queue`, and the owner is told so it can end playback on its own actor.
    private func observeEngineConfigurationChangesLocked() {
        guard changeObserver == nil else { return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.needsRebuild = true }
            self.onConfigurationChange?()
        }
    }

    private func makeBufferLocked(from samples: [Float]) -> AVAudioPCMBuffer? {
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

    /// All AVAudioEngine work lives here, serialized on the pipeline's own
    /// queue, because engine construction and `start()` block on coreaudiod
    /// XPC. This class keeps only the published UI state and the
    /// pending-buffer accounting on the main actor.
    private let pipeline = TTSAudioPipeline(
        format: AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        )!
    )
    private var pendingBufferCount = 0
    private var streamFinished = false

    /// Bumped whenever the buffer accounting is reset (stop, route-change
    /// rebuild). Completion handlers from buffers scheduled under an older
    /// generation — including ones wired to a disconnected output device,
    /// whose callbacks may fire late or not at all — are ignored so they
    /// can't corrupt the count for the rebuilt node.
    private var bufferGeneration = 0

    private init() {
        pipeline.onConfigurationChange = {
            Task { @MainActor in
                TTSService.shared.handleRouteChange()
            }
        }
    }

    // MARK: - Public API

    /// True when the active provider can synthesize right now. The remote
    /// provider has no local model to download, so it is always "ready";
    /// connection failures surface at playback time via `lastRemoteError`.
    public var isModelReady: Bool {
        if TTSConfigurationStore.load().provider == .openAICompatible { return true }
        if case .ready = modelState { return true }
        return false
    }

    /// Most recent remote-synthesis failure, shown in the TTS settings tab.
    /// Cleared when a later playback starts.
    @Published public private(set) var lastRemoteError: String?

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
        bufferGeneration += 1
        pipeline.stopPlayer()
        playingMessageId = nil
    }

    /// The output device changed mid-utterance (e.g. a Bluetooth speaker
    /// disconnected). The engine graph is dead, but the synthesis stream is
    /// still producing frames — so rebuild the engine on the new default
    /// device and keep playing instead of stopping. Buffers already scheduled
    /// on the old device are lost (a sub-second gap), and their late/missing
    /// completions are excluded from accounting via `bufferGeneration`.
    private func handleRouteChange() {
        guard playingMessageId != nil else { return }
        bufferGeneration += 1
        pendingBufferCount = 0
        Task { [weak self] in
            do {
                // `needsRebuild` was already flagged on the pipeline queue
                // ahead of this call, so this re-establishes the graph.
                try await self?.pipeline.prepareAndPlay()
            } catch {
                // Couldn't rebuild on the new device: end playback honestly
                // rather than leaving a Stop control over silence.
                self?.stop()
            }
        }
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
        let config = TTSConfigurationStore.load()
        switch config.provider {
        case .pocketTTS:
            startPocketPlayback(
                text: text, messageId: messageId, voiceOverride: voiceOverride, config: config)
        case .openAICompatible:
            startRemotePlayback(
                text: text, messageId: messageId, voiceOverride: voiceOverride, config: config)
        }
    }

    private func startPocketPlayback(
        text: String, messageId: UUID, voiceOverride: String?, config: TTSConfiguration
    ) {
        guard let manager else {
            playingMessageId = nil
            return
        }

        streamFinished = false
        pendingBufferCount = 0

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
            // Engine configure + start makes synchronous XPC round-trips to
            // coreaudiod; awaiting it here keeps the main actor free while
            // the pipeline queue pays that cost.
            do {
                try await self?.pipeline.prepareAndPlay()
            } catch {
                self?.modelState = .failed(error.localizedDescription)
                self?.playingMessageId = nil
                return
            }
            guard !Task.isCancelled else { return }
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

    private func startRemotePlayback(
        text: String, messageId: UUID, voiceOverride: String?, config: TTSConfiguration
    ) {
        streamFinished = false
        pendingBufferCount = 0
        lastRemoteError = nil

        let trimmedOverride = voiceOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = (trimmedOverride?.isEmpty == false ? trimmedOverride! : config.remoteVoice)

        playbackTask = Task { [weak self] in
            // Keychain read is blocking XPC; a detached task keeps it off the
            // main actor (a plain `Task {}` here would inherit it).
            let apiKey = await Task.detached(priority: .userInitiated) {
                TTSRemoteAPIKeyStore.loadSync()
            }.value
            guard !Task.isCancelled else { return }
            let client = OpenAICompatibleTTSClient(
                endpoint: config.remoteEndpoint,
                model: config.remoteModel,
                voice: voice,
                speed: config.remoteSpeed,
                apiKey: apiKey
            )
            do {
                try await self?.pipeline.prepareAndPlay()
            } catch {
                self?.lastRemoteError = error.localizedDescription
                self?.playingMessageId = nil
                return
            }
            guard !Task.isCancelled else { return }
            do {
                let stream = try client.synthesizeStreaming(text: text)
                for try await samples in stream {
                    if Task.isCancelled { break }
                    self?.schedule(samples: samples)
                }
                self?.markStreamFinished(for: messageId)
            } catch is CancellationError {
                // stop() already cleared state
            } catch {
                self?.handleRemoteStreamError(error, for: messageId)
            }
        }
    }

    private func handleRemoteStreamError(_ error: Error, for messageId: UUID) {
        TTSLogger.service.error(
            "Remote TTS synthesis failed: \(error.localizedDescription, privacy: .public)")
        // Unlike the local path, don't touch `modelState`: that tracks the
        // PocketTTS download and a network hiccup shouldn't flip it to failed.
        lastRemoteError = error.localizedDescription
        if playingMessageId == messageId {
            stop()
        }
    }

    private func schedule(samples: [Float]) {
        // Incremented before handing off; the pipeline guarantees the
        // completion fires exactly once even when the buffer can't be built.
        pendingBufferCount += 1
        let generation = bufferGeneration
        pipeline.schedule(samples: samples) { [weak self] in
            Task { @MainActor [weak self] in
                self?.bufferDidFinish(generation: generation)
            }
        }
    }

    private func bufferDidFinish(generation: Int) {
        guard generation == bufferGeneration else { return }
        pendingBufferCount = max(0, pendingBufferCount - 1)
        if streamFinished, pendingBufferCount == 0 {
            playingMessageId = nil
            pipeline.stopPlayer()
        }
    }

    private func markStreamFinished(for messageId: UUID) {
        guard playingMessageId == messageId else { return }
        streamFinished = true
        if pendingBufferCount == 0 {
            playingMessageId = nil
            pipeline.stopPlayer()
        }
    }

    private func handleStreamError(_ error: Error, for messageId: UUID) {
        // A `print` is not a user-facing error. When synthesis fails, playback ends, the
        // Stop control flips back on its own, and the user is left with silence and no
        // explanation — indistinguishable from the app simply ignoring them. Say what
        // happened, in the one place they are already looking at TTS.
        TTSLogger.service.error(
            "TTS synthesis failed: \(error.localizedDescription, privacy: .public)")
        modelState = .failed(error.localizedDescription)
        if playingMessageId == messageId {
            stop()
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
