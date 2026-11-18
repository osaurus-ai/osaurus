//
//  KokoroTTSEngine.swift
//  osaurus
//
//  hexgrad Kokoro-82M through FluidAudio's Core ML ports. Kokoro renders a
//  whole utterance per call, so each `TTSTextChunker` chunk is synthesized
//  in one pass and handed to the player in 80 ms frames.
//

@preconcurrency import FluidAudio
import Foundation

actor KokoroTTSEngine: LocalTTSEngine {
    /// Samples per frame handed to the player: 80 ms at 24 kHz, the size
    /// PocketTTS streams, so both engines schedule the same buffers.
    static let frameSamples = 1920

    let language: KokoroLanguage
    let runtime: KokoroRuntime
    /// Voice to fetch and warm while loading, so the first utterance in the
    /// configured voice doesn't wait on its voice pack.
    private let preloadVoice: String
    private var manager: KokoroAneManager?

    /// `runtime` must already be effective for `language`
    /// (`KokoroVoiceCatalog.effectiveRuntime`).
    init(language: KokoroLanguage, runtime: KokoroRuntime, preloadVoice: String) {
        self.language = language
        self.runtime = runtime
        self.preloadVoice = preloadVoice
    }

    static func id(language: KokoroLanguage, runtime: KokoroRuntime) -> String {
        "kokoro/\(language.rawValue)/\(runtime.rawValue)"
    }

    nonisolated var modelId: String { Self.id(language: language, runtime: runtime) }
    nonisolated var activityModel: String { "hexgrad/Kokoro-82M" }
    nonisolated var activityProvider: String { "Kokoro" }

    nonisolated func filesOnDisk() -> Bool {
        guard let models = Self.modelsRoot() else { return false }
        let fm = FileManager.default
        let g2p = models.appendingPathComponent(Repo.kokoro.folderName, isDirectory: true)
        let frontend: Set<String> =
            switch language {
            case .english: ModelNames.G2P.requiredModels
            case .french: ModelNames.MultilingualG2P.requiredModels
            case .mandarin, .japanese, .spanish: []
            }
        guard frontend.allSatisfy({ fm.fileExists(atPath: g2p.appendingPathComponent($0).path) }) else {
            return false
        }
        switch runtime {
        case .standard:
            let variant = language.variant
            let repo = models.appendingPathComponent(variant.repo.folderName, isDirectory: true)
            return Self.requiredStandardModels(variant)
                .allSatisfy { fm.fileExists(atPath: repo.appendingPathComponent($0).path) }
        case .fast:
            // FluidAudio writes the v3 manifest last, after every file it
            // lists, under a directory named for the pinned revision.
            let v3 = models.appendingPathComponent("kokoro-82m-coreml/ANE-v3", isDirectory: true)
            let revisions = (try? fm.contentsOfDirectory(atPath: v3.path)) ?? []
            return revisions.contains { revision in
                let manifest = v3.appendingPathComponent(revision)
                    .appendingPathComponent(language.v3Code)
                    .appendingPathComponent("manifest.json")
                return fm.fileExists(atPath: manifest.path)
            }
        }
    }

    nonisolated func resolveVoice(override: String?, config: TTSConfiguration) -> String {
        let resolution = KokoroVoiceCatalog.resolveVoice(
            override: override,
            configured: config.kokoroVoice,
            language: language,
            runtime: runtime
        )
        if let rejected = resolution.rejected {
            TTSLogger.service.notice(
                "Kokoro voice \(rejected, privacy: .public) isn't in the \(self.modelId, privacy: .public) catalog; using \(resolution.voice, privacy: .public)"
            )
        }
        return resolution.voice
    }

    func load(progress: @escaping LocalTTSLoadProgress) async throws {
        if manager != nil { return }
        let variant = language.variant
        switch runtime {
        case .standard:
            // English's G2P (~2 MB) and French's multilingual G2P fallback
            // (~80 MB) follow the ~80 MB chain; weight the bar by size so it
            // doesn't restart at zero.
            let chainShare: Double =
                switch language {
                case .english: 0.95
                case .french: 0.5
                case .mandarin, .japanese, .spanish: 1
                }
            try await KokoroAneResourceDownloader.ensureModels(
                variant: variant,
                progressHandler: Self.progressHandler(
                    progress,
                    offset: 0,
                    scale: chainShare,
                    phaseWeight: Self.repoDownloadPhaseWeight
                )
            )
            switch language {
            case .english:
                try await KokoroAneResourceDownloader.ensureG2PAssets(
                    progressHandler: Self.progressHandler(
                        progress,
                        offset: chainShare,
                        scale: 1 - chainShare,
                        phaseWeight: Self.repoDownloadPhaseWeight
                    )
                )
            case .french:
                try await KokoroAneResourceDownloader.ensureMultilingualG2PAssets(
                    progressHandler: Self.progressHandler(
                        progress,
                        offset: chainShare,
                        scale: 1 - chainShare,
                        phaseWeight: 1
                    )
                )
            case .mandarin, .japanese, .spanish:
                break
            }
        case .fast:
            // The v3 downloader has no progress callback.
            progress(nil)
        }
        progress(nil)
        let mgr = KokoroAneManager(
            variant: variant,
            defaultVoice: variant.defaultVoice,
            version: runtime == .fast ? .v3 : .legacy
        )
        try await mgr.initialize(preloadVoices: [preloadVoice])
        // Mandarin and Japanese fetch their text-frontend dictionaries on the
        // first text they see. One short utterance here pulls them (and
        // warms Core ML) while the UI still says "loading", instead of
        // stalling the first real sentence.
        _ = try await mgr.synthesizeDetailed(text: language.warmupText, voice: preloadVoice)
        manager = mgr
    }

    func unload() async {
        guard let mgr = manager else { return }
        manager = nil
        await mgr.cleanup()
    }

    func synthesize(
        chunk: String,
        voice: String,
        config: TTSConfiguration
    ) async throws -> AsyncThrowingStream<[Float], Error> {
        guard let manager else { throw TTSPlaybackError.modelNotReady }
        // A chunk with nothing to pronounce (a rule line, an emoji) has no
        // phonemes and Kokoro rejects it; it is silence, not an error.
        guard chunk.contains(where: { $0.isLetter || $0.isNumber }) else {
            return AsyncThrowingStream { $0.finish() }
        }
        let range = TTSConfiguration.kokoroSpeedRange
        let speed = Float(min(max(config.kokoroSpeed, range.lowerBound), range.upperBound))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await manager.synthesizeDetailed(text: chunk, voice: voice, speed: speed)
                    guard result.sampleRate == KokoroAneConstants.sampleRate else {
                        throw KokoroAneError.audioConversionFailed(
                            "Expected \(KokoroAneConstants.sampleRate) Hz, got \(result.sampleRate) Hz"
                        )
                    }
                    for frame in Self.frames(of: result.samples) {
                        try Task.checkCancellation()
                        continuation.yield(frame)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `samples` cut into `frameSamples`-long buffers; the last may be shorter.
    static func frames(of samples: [Float]) -> [[Float]] {
        stride(from: 0, to: samples.count, by: frameSamples).map {
            Array(samples[$0 ..< min($0 + frameSamples, samples.count)])
        }
    }

    // MARK: - Disk layout

    /// `~/.cache/fluidaudio/Models`, as FluidAudio resolves it.
    nonisolated private static func modelsRoot() -> URL? {
        guard let cache = try? TtsCacheDirectory.ensure() else { return nil }
        return cache.appendingPathComponent(KokoroAneResourceDownloader.modelsSubdirectory, isDirectory: true)
    }

    nonisolated private static func requiredStandardModels(_ variant: KokoroAneVariant) -> Set<String> {
        switch variant {
        case .english, .spanish, .french: return ModelNames.KokoroAne.requiredModels
        case .mandarin: return ModelNames.KokoroAne.requiredModelsZh
        case .japanese: return ModelNames.KokoroAne.requiredModelsJa
        }
    }

    /// Share of `fractionCompleted` FluidAudio gives the download phase of a
    /// repo download (`ModelHub.download(_:to:)`); the remainder belongs to a
    /// compile phase that call never reports, so finished files read 0.5.
    /// Subdirectory downloads span the full 0–1.
    static let repoDownloadPhaseWeight = 0.5

    /// Load-bar position for a download's `fractionCompleted`, given the
    /// slice of the bar (`offset`, `scale`) that download owns.
    static func loadFraction(
        downloadFraction: Double,
        phaseWeight: Double,
        offset: Double,
        scale: Double
    ) -> Double {
        offset + min(max(downloadFraction / phaseWeight, 0), 1) * scale
    }

    private static func progressHandler(
        _ progress: @escaping LocalTTSLoadProgress,
        offset: Double,
        scale: Double,
        phaseWeight: Double
    ) -> ProgressHandler {
        { update in
            switch update.phase {
            case .downloading:
                progress(
                    loadFraction(
                        downloadFraction: update.fractionCompleted,
                        phaseWeight: phaseWeight,
                        offset: offset,
                        scale: scale
                    )
                )
            case .listing, .compiling: progress(nil)
            }
        }
    }
}

extension KokoroLanguage {
    var variant: KokoroAneVariant {
        switch self {
        case .english: return .english
        case .mandarin: return .mandarin
        case .japanese: return .japanese
        case .spanish: return .spanish
        case .french: return .french
        }
    }

    /// Directory name FluidAudio uses for this language's v3 pack.
    var v3Code: String {
        switch self {
        case .english: return "en"
        case .mandarin: return "zh"
        case .japanese: return "ja"
        case .spanish: return "es"
        case .french: return "fr"
        }
    }

    /// A short sentence in the language, synthesized once at load.
    var warmupText: String {
        switch self {
        case .english: return "Ready."
        case .mandarin: return "准备好了。"
        case .japanese: return "準備ができました。"
        case .spanish: return "Listo."
        case .french: return "Prêt."
        }
    }
}

/// Kokoro voices and the language/runtime rules that decide which ones work.
/// Shared by the TTS settings tab, the per-agent voice picker, and playback.
public enum KokoroVoiceCatalog {
    /// The runtime that actually runs: `.fast` only where a v3 pack exists.
    public static func effectiveRuntime(language: KokoroLanguage, requested: KokoroRuntime) -> KokoroRuntime {
        language.supportsFastRuntime ? requested : .standard
    }

    public static func effectiveRuntime(for config: TTSConfiguration) -> KokoroRuntime {
        effectiveRuntime(language: config.kokoroLanguage, requested: config.kokoroRuntime)
    }

    /// Voices the language's pack ships for `runtime`. The fast runtime only
    /// accepts the language's native speakers (FluidAudio rejects the rest).
    public static func voices(language: KokoroLanguage, runtime: KokoroRuntime) -> [String] {
        let all = language.variant.knownVoices
        guard effectiveRuntime(language: language, requested: runtime) == .fast else { return all }
        let prefixes = fastPrefixes(language)
        return all.filter { voice in prefixes.contains(where: voice.hasPrefix) }
    }

    public static func defaultVoice(language: KokoroLanguage) -> String {
        language.variant.defaultVoice
    }

    /// The per-agent override if this language/runtime has it, else the
    /// configured voice if it has that, else the language default.
    /// `rejected` names the first requested voice that had to be skipped.
    public static func resolveVoice(
        override: String?,
        configured: String,
        language: KokoroLanguage,
        runtime: KokoroRuntime
    ) -> (voice: String, rejected: String?) {
        let available = voices(language: language, runtime: runtime)
        let trimmedOverride = override?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requested = [trimmedOverride, configured].compactMap { $0 }.filter { !$0.isEmpty }
        guard let index = requested.firstIndex(where: available.contains) else {
            return (defaultVoice(language: language), requested.first)
        }
        return (requested[index], index > 0 ? requested[0] : nil)
    }

    /// Whether `voice` is one `config`'s Kokoro language/runtime can speak.
    public static func isAvailable(_ voice: String, for config: TTSConfiguration) -> Bool {
        voices(language: config.kokoroLanguage, runtime: effectiveRuntime(for: config)).contains(voice)
    }

    /// "Heart (American, female)". Kokoro ids are `<accent><gender>_<name>`.
    public static func displayName(for voice: String) -> String {
        let parts = voice.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 2 else { return voice }
        let code = Array(parts[0])
        let rawName = String(parts[1])
        let name =
            rawName.allSatisfy(\.isNumber)
            ? L("Voice \(rawName)")
            : rawName.prefix(1).uppercased() + rawName.dropFirst()
        let gender: String
        switch code[1] {
        case "f": gender = L("female")
        case "m": gender = L("male")
        default: return name
        }
        guard let accent = accentName(code[0]) else { return name }
        return "\(name) (\(accent), \(gender))"
    }

    public static func displayName(for language: KokoroLanguage) -> String {
        switch language {
        case .english: return L("English")
        case .mandarin: return L("Mandarin Chinese")
        case .japanese: return L("Japanese")
        case .spanish: return L("Spanish")
        case .french: return L("French")
        }
    }

    /// Rough download for a language on a runtime, for the "Not downloaded"
    /// caption: the Core ML chain plus that language's text frontend.
    public static func approximateDownloadMB(language: KokoroLanguage, runtime: KokoroRuntime) -> Int {
        switch (language, effectiveRuntime(language: language, requested: runtime)) {
        case (.english, .standard): return 95
        case (.english, .fast): return 390
        case (.mandarin, .standard): return 310
        case (.mandarin, .fast): return 385
        case (.japanese, .standard): return 285
        case (.japanese, .fast): return 500
        case (.spanish, _): return 85
        case (.french, _): return 175
        }
    }

    private static func fastPrefixes(_ language: KokoroLanguage) -> [String] {
        switch language {
        case .english: return ["af_", "am_", "bf_", "bm_"]
        case .mandarin: return ["zf_", "zm_"]
        case .japanese: return ["jf_", "jm_"]
        case .spanish, .french: return []
        }
    }

    private static func accentName(_ code: Character) -> String? {
        switch code {
        case "a": return L("American")
        case "b": return L("British")
        case "e": return L("Spanish")
        case "f": return L("French")
        case "h": return L("Hindi")
        case "i": return L("Italian")
        case "j": return L("Japanese")
        case "p": return L("Brazilian Portuguese")
        case "z": return L("Mandarin")
        default: return nil
        }
    }
}
