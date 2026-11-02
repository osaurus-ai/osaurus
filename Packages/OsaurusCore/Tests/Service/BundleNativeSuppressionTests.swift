import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite("Bundle-native token suppression", .serialized)
struct BundleNativeSuppressionTests {
    @Test("integer token lists match the engine decoder without coercing invalid values")
    func integerListContract() throws {
        let rows: [(String, [Int]?)] = [
            (#"{}"#, nil),
            (#"{"suppress_tokens":null}"#, nil),
            (#"{"suppress_tokens":[]}"#, []),
            (#"{"suppress_tokens":[0,7,7]}"#, [0, 7, 7]),
            (#"{"suppress_tokens":[1.0]}"#, [1]),
        ]
        for (json, expected) in rows {
            let data = Data(json.utf8)
            let native = try JSONDecoder().decode(GenerationConfigFile.self, from: data)
            #expect(native.suppressTokens == expected)
            #expect(LocalGenerationDefaults.parse(data: data).suppressTokens == native.suppressTokens)
        }
        for json in [
            #"{"suppress_tokens":[true]}"#,
            #"{"suppress_tokens":[1.5]}"#,
            #"{"suppress_tokens":["7"]}"#,
            #"{"suppress_tokens":[7,null]}"#,
            #"{"suppress_tokens":7}"#,
        ] {
            let data = Data(json.utf8)
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(GenerationConfigFile.self, from: data)
            }
            // The host's existing field-by-field decoder leaves malformed fields absent.
            #expect(LocalGenerationDefaults.parse(data: data).suppressTokens == nil)
        }
    }

    @Test("JANG and thinking overlays distinguish omission from an explicit empty list")
    func bundleOverlayPrecedence() {
        let hf = LocalGenerationDefaults.parse(data: Data(#"{"suppress_tokens":[7]}"#.utf8))
        let absent = LocalGenerationDefaults.parseJangConfig(data: Data(
            #"{"chat":{"sampling_defaults":{"temperature":0.7}}}"#.utf8))
        #expect(LocalGenerationDefaults.merge(primary: absent, fallback: hf).suppressTokens == [7])
        let declared = LocalGenerationDefaults.parseJangConfig(data: Data(
            #"{"chat":{"sampling_defaults":{"suppress_tokens":[3]},"sampling_thinking":{"suppress_tokens":[5]}}}"#.utf8))
        let merged = LocalGenerationDefaults.merge(primary: declared, fallback: hf)
        #expect(merged.suppressTokens == [3])
        #expect(merged.resolvingThinking(false).suppressTokens == [3])
        #expect(merged.resolvingThinking(true).suppressTokens == [5])
        let empty = LocalGenerationDefaults.parseJangConfig(data: Data(
            #"{"chat":{"sampling_defaults":{"suppress_tokens":[]},"sampling_thinking":{"top_k":4}}}"#.utf8))
        let cleared = LocalGenerationDefaults.merge(primary: empty, fallback: hf)
        #expect(cleared.suppressTokens == [])
        #expect(cleared.resolvingThinking(true).suppressTokens == [])
        let thinkingEmpty = LocalGenerationDefaults.parseJangConfig(data: Data(
            #"{"chat":{"sampling_defaults":{"suppress_tokens":[3]},"sampling_thinking":{"suppress_tokens":[]}}}"#.utf8))
        #expect(thinkingEmpty.resolvingThinking(true).suppressTokens == [])
    }

    @Test("exact-directory loading keeps a JANG exclusion list above HF defaults")
    func directoryLoading() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle-suppression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"suppress_tokens":[7],"temperature":0.8}"#.utf8)
            .write(to: directory.appendingPathComponent("generation_config.json"))
        try Data(#"{"chat":{"sampling_defaults":{"suppress_tokens":[3]}}}"#.utf8)
            .write(to: directory.appendingPathComponent("jang_config.json"))
        let defaults = LocalGenerationDefaults.load(fromDirectory: directory)
        #expect(defaults.suppressTokens == [3])
        #expect(defaults.temperature == 0.8)
    }

    @Test("explicit sampler overrides preserve bundle exclusions and reach a real processor")
    func resolvedSettingsReachProcessor() throws {
        let defaults = LocalGenerationDefaults.parseJangConfig(data: Data(
            #"{"chat":{"sampling_defaults":{"suppress_tokens":[0]},"sampling_thinking":{"suppress_tokens":[1]}}}"#.utf8))
        let effective = MLXBatchAdapter.effectiveGenerationSettings(
            modelName: "fixture",
            generation: GenerationParameters(
                temperature: 0, maxTokens: 17, maxTokensExplicit: true,
                topPOverride: 0, topKOverride: 0, repetitionPenalty: nil, seed: 42),
            runtimeDefaults: VMLXServerGenerationDefaults(temperature: 0.9),
            maxBatchSize: 1, modelDefaults: defaults, thinkingEnabled: true)
        #expect(effective.temperature == 0)
        #expect(effective.maxTokens == 17)
        #expect(effective.modelDefaults.suppressTokens == [1])
        try Device.withDefaultDevice(.cpu) {
            let parameters = ModelRuntime.makeGenerateParameters(
                temperature: effective.temperature, maxTokens: effective.maxTokens,
                topP: effective.topP, topK: effective.topK, minP: effective.minP,
                suppressTokens: effective.modelDefaults.suppressTokens ?? [],
                repetitionPenalty: effective.repetitionPenalty, randomSeed: 42)
            #expect(parameters.suppressTokens == [1])
            #expect(parameters.randomSeed == 42)
            #expect(parameters.maxTokens == 17)
            var processor = try #require(parameters.processor())
            processor.prompt(MLXArray([Int32(0)]))
            for _ in 0..<2 {
                let result = processor.process(logits: MLXArray([Float(2), 10, 3]).reshaped(1, 3))
                    .asArray(Float.self)
                #expect(result[0] == 2)
                #expect(result[1] == -.infinity)
                #expect(result[2] == 3)
                processor.didSample(token: MLXArray(Int32(2)))
            }
        }
    }

    @Test("an omitted or explicitly empty native list installs no suppression processor")
    func noInventedExclusions() {
        Device.withDefaultDevice(.cpu) {
            let empty = ModelRuntime.makeGenerateParameters(
                temperature: 0, maxTokens: 8, topP: 1,
                suppressTokens: [], repetitionPenalty: nil)
            #expect(empty.suppressTokens.isEmpty)
            #expect(empty.processor() == nil)
            let omitted = ModelRuntime.makeGenerateParameters(
                temperature: 0, maxTokens: 8, topP: 1, repetitionPenalty: nil)
            #expect(omitted.suppressTokens.isEmpty)
            #expect(omitted.processor() == nil)
        }
    }
}
