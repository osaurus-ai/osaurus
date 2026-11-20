// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Kokoro TTS engine")
struct KokoroTTSEngineTests {
    private func kokoro(
        _ language: KokoroLanguage,
        _ runtime: KokoroRuntime = .standard,
        voice: String = "af_heart"
    ) -> TTSConfiguration {
        TTSConfiguration(provider: .kokoro, kokoroLanguage: language, kokoroRuntime: runtime, kokoroVoice: voice)
    }

    @Test("each language and runtime is its own model; Spanish and French always run standard")
    func modelIds() {
        #expect(LocalTTSEngines.modelId(for: kokoro(.english)) == "kokoro/english/standard")
        #expect(LocalTTSEngines.modelId(for: kokoro(.english, .fast)) == "kokoro/english/fast")
        #expect(LocalTTSEngines.modelId(for: kokoro(.japanese, .fast)) == "kokoro/japanese/fast")
        #expect(LocalTTSEngines.modelId(for: kokoro(.spanish, .fast)) == "kokoro/spanish/standard")
        #expect(LocalTTSEngines.modelId(for: kokoro(.french, .fast)) == "kokoro/french/standard")
        #expect(LocalTTSEngines.make(for: kokoro(.mandarin, .fast))?.modelId == "kokoro/mandarin/fast")
    }

    @Test("a voice or speed change keeps the loaded model")
    func voiceAndSpeedShareModel() {
        var other = kokoro(.english, voice: "bm_george")
        other.kokoroSpeed = 1.4
        #expect(LocalTTSEngines.modelId(for: other) == LocalTTSEngines.modelId(for: kokoro(.english)))
    }

    @Test("the fast runtime lists only the language's native voices")
    func fastVoiceLists() {
        let english = KokoroVoiceCatalog.voices(language: .english, runtime: .fast)
        #expect(english.contains("af_heart") && english.contains("bm_george"))
        #expect(!english.contains("ef_dora") && !english.contains("zf_xiaobei"))
        #expect(english.allSatisfy { ["af_", "am_", "bf_", "bm_"].contains(where: $0.hasPrefix) })
        #expect(KokoroVoiceCatalog.voices(language: .english, runtime: .standard).contains("ef_dora"))

        let mandarin = KokoroVoiceCatalog.voices(language: .mandarin, runtime: .fast)
        #expect(mandarin.contains("zf_001") && !mandarin.contains("af_maple"))
        #expect(
            KokoroVoiceCatalog.voices(language: .spanish, runtime: .fast)
                == KokoroVoiceCatalog.voices(language: .spanish, runtime: .standard)
        )
        for language in KokoroLanguage.allCases {
            for runtime in KokoroRuntime.allCases {
                #expect(
                    KokoroVoiceCatalog.voices(language: language, runtime: runtime)
                        .contains(KokoroVoiceCatalog.defaultVoice(language: language))
                )
            }
        }
    }

    @Test("voice resolution: agent override, then configured voice, then the language default")
    func voiceResolution() {
        func resolve(_ override: String?, _ configured: String, _ language: KokoroLanguage, _ runtime: KokoroRuntime)
            -> (voice: String, rejected: String?)
        {
            KokoroVoiceCatalog.resolveVoice(
                override: override,
                configured: configured,
                language: language,
                runtime: runtime
            )
        }
        #expect(resolve(" bf_emma ", "af_heart", .english, .standard) == ("bf_emma", nil))
        #expect(resolve("", "am_adam", .english, .standard) == ("am_adam", nil))
        #expect(resolve("alba", "am_adam", .english, .standard) == ("am_adam", "alba"))
        #expect(resolve(nil, "ef_dora", .english, .fast) == ("af_heart", "ef_dora"))
        #expect(resolve(nil, "af_heart", .japanese, .standard) == ("jf_alpha", "af_heart"))
        #expect(resolve("em_alex", "af_heart", .spanish, .fast) == ("em_alex", nil))
    }

    @Test("the engine resolves voices against its own language and runtime")
    func engineResolvesVoice() {
        let engine = KokoroTTSEngine(language: .english, runtime: .fast, preloadVoice: "af_heart")
        #expect(engine.resolveVoice(override: "jf_alpha", config: kokoro(.english, .fast)) == "af_heart")
        #expect(engine.resolveVoice(override: "am_onyx", config: kokoro(.english, .fast)) == "am_onyx")
    }

    @Test("voice names read as name, accent, gender")
    func displayNames() {
        #expect(KokoroVoiceCatalog.displayName(for: "af_heart") == "Heart (American, female)")
        #expect(KokoroVoiceCatalog.displayName(for: "bm_george") == "George (British, male)")
        #expect(KokoroVoiceCatalog.displayName(for: "zf_001") == "Voice 001 (Mandarin, female)")
        #expect(KokoroVoiceCatalog.displayName(for: "custom") == "custom")
    }

    @Test("a whole utterance is handed to the player in 80 ms frames")
    func framesSlicing() {
        let samples = (0 ..< 4000).map(Float.init)
        let frames = KokoroTTSEngine.frames(of: samples)
        #expect(frames.map(\.count) == [1920, 1920, 160])
        #expect(frames.flatMap { $0 } == samples)
        #expect(KokoroTTSEngine.frames(of: []).isEmpty)
    }

    @Test("a finished repo download fills its whole slice of the load bar")
    func downloadProgressMapping() {
        func bar(_ fraction: Double, _ offset: Double, _ scale: Double, weight: Double = 0.5) -> Double {
            KokoroTTSEngine.loadFraction(downloadFraction: fraction, phaseWeight: weight, offset: offset, scale: scale)
        }
        #expect(KokoroTTSEngine.repoDownloadPhaseWeight == 0.5)
        #expect(bar(0, 0, 0.5) == 0)
        #expect(abs(bar(0.25, 0, 0.5) - 0.25) < 1e-9)
        #expect(abs(bar(0.5, 0, 0.5) - 0.5) < 1e-9)
        #expect(abs(bar(0.5, 0.5, 0.5, weight: 1) - 0.75) < 1e-9)
        #expect(bar(1, 0.5, 0.5, weight: 1) == 1)
        #expect(bar(0.9, 0, 1) == 1)
    }

    @Test("synthesizing before load fails as not ready")
    func synthesizeRequiresLoad() async {
        let engine = KokoroTTSEngine(language: .english, runtime: .standard, preloadVoice: "af_heart")
        await #expect(throws: TTSPlaybackError.self) {
            _ = try await engine.synthesize(chunk: "Hello.", voice: "af_heart", config: kokoro(.english))
        }
    }

    @Test("the crash notice covers macOS 26.4 through 26.5.x only")
    func crashNoticeOSRange() {
        func affected(_ major: Int, _ minor: Int, _ patch: Int = 0) -> Bool {
            KokoroVoiceCatalog.osMayCrashDuringSynthesis(
                OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch))
        }
        #expect(affected(26, 4))
        #expect(affected(26, 5, 2))
        #expect(!affected(26, 3, 1))
        #expect(!affected(26, 6))
        #expect(!affected(15, 5))
        #expect(!affected(27, 0))
    }
}

@Suite("Kokoro configuration decoding")
struct KokoroConfigurationDecodingTests {
    private func decode(_ json: String) throws -> TTSConfiguration {
        try JSONDecoder().decode(TTSConfiguration.self, from: Data(json.utf8))
    }

    @Test("configs saved before Kokoro get Kokoro defaults")
    func missingKeysUseDefaults() throws {
        let config = try decode(#"{"enabled": true, "provider": "pocketTTS", "voice": "vera"}"#)
        #expect(config.kokoroLanguage == .english)
        #expect(config.kokoroRuntime == .standard)
        #expect(config.kokoroVoice == TTSConfiguration.defaultKokoroVoice)
        #expect(config.kokoroSpeed == 1.0)
        #expect(config.voice == "vera")
    }

    @Test("unknown language or runtime values fall back without losing the rest")
    func unknownValuesFallBack() throws {
        let config = try decode(
            #"{"provider": "kokoro", "kokoroLanguage": "klingon", "kokoroRuntime": "warp", "kokoroVoice": "bf_emma", "kokoroSpeed": 1.3}"#
        )
        #expect(config.provider == .kokoro)
        #expect(config.kokoroLanguage == .english)
        #expect(config.kokoroRuntime == .standard)
        #expect(config.kokoroVoice == "bf_emma")
        #expect(config.kokoroSpeed == 1.3)
    }

    @Test("Kokoro settings round-trip")
    func roundTrip() throws {
        let original = TTSConfiguration(
            provider: .kokoro,
            kokoroLanguage: .japanese,
            kokoroRuntime: .fast,
            kokoroVoice: "jm_kumo",
            kokoroSpeed: 0.8
        )
        let decoded = try JSONDecoder().decode(TTSConfiguration.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}
