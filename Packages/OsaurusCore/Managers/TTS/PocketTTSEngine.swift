//
//  PocketTTSEngine.swift
//  osaurus
//
//  Kyutai PocketTTS (English) through FluidAudio. Streams 80 ms frames as
//  they are generated.
//

@preconcurrency import FluidAudio
import Foundation

actor PocketTTSEngine: LocalTTSEngine {
    static let id = "pocket-tts"
    static let language: PocketTtsLanguage = .english

    nonisolated var modelId: String { Self.id }
    nonisolated var activityModel: String { "kyutai/pocket-tts" }
    nonisolated var activityProvider: String { "PocketTTS" }

    private var manager: PocketTtsManager?

    nonisolated func filesOnDisk() -> Bool {
        guard let root = Self.languageRoot() else { return false }
        let fm = FileManager.default
        return ModelNames.PocketTTS.requiredModels(precision: .fp16, placement: .gpu)
            .allSatisfy { fm.fileExists(atPath: root.appendingPathComponent($0).path) }
    }

    nonisolated func resolveVoice(override: String?, config: TTSConfiguration) -> String {
        let trimmed = override?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requested = (trimmed?.isEmpty == false ? trimmed! : config.voice)
        // A stale or invalid name (e.g. a renamed voice) otherwise 404s
        // fetching its voice prompt and playback dies.
        guard PocketTTSVoiceCatalog.availableVoices.contains(requested) else {
            TTSLogger.service.notice(
                "PocketTTS voice \(requested, privacy: .public) unknown; using \(TTSConfiguration.defaultVoice, privacy: .public)"
            )
            return TTSConfiguration.defaultVoice
        }
        return requested
    }

    func load(progress: @escaping LocalTTSLoadProgress) async throws {
        if manager != nil { return }
        // Route through the downloader explicitly to get progress callbacks.
        // When the models are already cached this returns almost instantly.
        _ = try await PocketTtsResourceDownloader.ensureModels(
            language: Self.language,
            progressHandler: { update in
                switch update.phase {
                case .downloading: progress(update.fractionCompleted)
                case .listing, .compiling: progress(nil)
                }
            }
        )
        try Task.checkCancellation()
        let mgr = PocketTtsManager(language: Self.language)
        try await mgr.initialize()
        guard !Task.isCancelled else {
            await mgr.cleanup()
            throw CancellationError()
        }
        manager = mgr
        Self.removeLegacyRootFiles()
    }

    func unload() async {
        guard let mgr = manager else { return }
        manager = nil
        await mgr.cleanup()
    }

    func synthesize(
        chunk: String, voice: String, config: TTSConfiguration
    ) async throws -> AsyncThrowingStream<[Float], Error> {
        guard let manager else { throw TTSPlaybackError.modelNotReady }
        let frames = try await manager.synthesizeStreaming(
            text: chunk,
            voice: voice,
            temperature: config.temperature.map(Float.init)
        )
        return LocalTTSEngines.samples(from: frames) { $0.samples }
    }

    // MARK: - Disk layout

    /// `~/.cache/fluidaudio/Models/pocket-tts`, as FluidAudio resolves it.
    nonisolated private static func repoRoot() -> URL? {
        guard let cache = try? TtsCacheDirectory.ensure() else { return nil }
        return cache
            .appendingPathComponent(PocketTtsConstants.defaultModelsSubdirectory, isDirectory: true)
            .appendingPathComponent(Repo.pocketTts.folderName, isDirectory: true)
    }

    nonisolated private static func languageRoot() -> URL? {
        repoRoot()?.appendingPathComponent(language.repoSubdirectory, isDirectory: true)
    }

    /// FluidAudio 0.14 kept the English pack at the repo root; 0.18 reads
    /// `v2.1/<language>/` and never touches the old files. Once the new pack
    /// has loaded, the ~700 MB left at the root is dead weight.
    static let legacyRootEntries = [
        "cond_step.mlmodelc", "flowlm_step.mlmodelc", "flow_decoder.mlmodelc",
        "mimi_decoder_v2.mlmodelc", "mimi_encoder.mlmodelc", "constants_bin",
    ]

    nonisolated private static func removeLegacyRootFiles() {
        guard let root = repoRoot() else { return }
        let fm = FileManager.default
        for name in legacyRootEntries {
            let url = root.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
                TTSLogger.service.info("Removed legacy PocketTTS file \(name, privacy: .public)")
            } catch {
                TTSLogger.service.error(
                    "Couldn't remove legacy PocketTTS file \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}

/// Built-in PocketTTS voices (kyutai/pocket-tts on HuggingFace). Shared by
/// the TTS settings tab and the per-agent voice picker.
public enum PocketTTSVoiceCatalog {
    public static let availableVoices: [String] = [
        "alba", "anna", "azelma", "bill_boerst", "caro_davy", "charles",
        "cosette", "daan", "eponine", "estelle", "eve", "fantine", "george",
        "giovanni", "jane", "javert", "jean", "juergen", "lola", "marius",
        "mary", "michael", "paul", "peter_yearsley", "rafael", "stuart_bell",
        "vera",
    ]

    /// The temperature the English checkpoint was tuned for; used when the
    /// user hasn't set one.
    public static var defaultTemperature: Double {
        Double(PocketTTSEngine.language.defaultTemperature)
    }

    public static func displayName(for voice: String) -> String {
        voice.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
