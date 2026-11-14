import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite("Bundle thinking sampling defaults", .serialized)
struct ThinkingSamplingDefaultsTests {
    private func fixture(defaultThinking: Bool = false) throws -> LocalGenerationDefaults.Defaults {
        let chat: [String: Any] = [
            "reasoning": ["default_enabled": defaultThinking],
            "sampling_defaults": ["temperature": 0.2, "top_p": 0.95, "top_k": 50],
            "sampling_thinking": [
                "temperature": 0.6, "top_k": 0, "min_p": 0.0,
                "repetition_penalty": 1.1, "presence_penalty": 0.3,
                "frequency_penalty": 0.4, "max_new_tokens": 1234,
            ],
        ]
        return LocalGenerationDefaults.parseJangConfig(
            data: try JSONSerialization.data(withJSONObject: ["chat": chat])
        )
    }

    @Test
    func selectsCompleteDeclaredOverlayWithoutChangingBaseSnapshot() throws {
        let base = try fixture()
        let on = base.resolvingThinking(true)
        #expect(on.temperature == 0.6)
        #expect(on.topP == 0.95)
        #expect(on.topK == 0)
        #expect(on.minP == 0)
        #expect(on.repetitionPenalty == 1.1)
        #expect(on.presencePenalty == 0.3)
        #expect(on.frequencyPenalty == 0.4)
        #expect(on.maxTokens == 1234)
        #expect(base.temperature == 0.2)
        #expect(base.resolvingThinking(false) == base)
        #expect(base.resolvingThinking(nil) == base)
    }

    @Test
    func selectedModeStillYieldsToExplicitUserAndServerSampling() throws {
        let base = try fixture()
        func resolve(_ request: GenerationParameters, _ server: VMLXServerGenerationDefaults)
            -> MLXBatchAdapter.EffectiveGenerationSettings
        {
            MLXBatchAdapter.effectiveGenerationSettings(
                modelName: "fixture",
                generation: request,
                runtimeDefaults: server,
                maxBatchSize: 1,
                modelDefaults: base,
                thinkingEnabled: true
            )
        }
        let inherited = resolve(GenerationParameters(temperature: nil, maxTokens: 4096), .init())
        #expect(inherited.temperature == 0.6)
        #expect(inherited.topK == 0)
        #expect(inherited.presencePenalty == 0.3)
        #expect(inherited.frequencyPenalty == 0.4)
        #expect(
            resolve(GenerationParameters(temperature: nil, maxTokens: 4096), .init(temperature: 0.8)).temperature == 0.8
        )
        #expect(
            resolve(GenerationParameters(temperature: 0, maxTokens: 4096), .init(temperature: 0.8)).temperature == 0
        )
    }

    @Test
    func templateFlagUsesTypedReasoningPrecedenceAndDeclaredDefault() throws {
        let base = try fixture(defaultThinking: true)
        func enabled(_ request: GenerationParameters, template: Bool = true) -> Bool? {
            MLXBatchAdapter.thinkingEnabledForSampling(
                generation: request,
                modelName: "fixture",
                modelDefaults: base,
                usesChatTemplate: template
            )
        }
        #expect(enabled(GenerationParameters(temperature: nil, maxTokens: 32)) == true)
        let typedOff = GenerationParameters(
            temperature: nil,
            maxTokens: 32,
            modelOptions: ["disableThinking": .bool(true)],
            templateKwargs: ["enable_thinking": .bool(true)]
        )
        #expect(enabled(typedOff) == false)
        let typedOn = GenerationParameters(
            temperature: nil,
            maxTokens: 32,
            modelOptions: ["disableThinking": .bool(false)],
            templateKwargs: ["enable_thinking": .bool(false)]
        )
        #expect(enabled(typedOn) == true)
        #expect(enabled(typedOn, template: false) == nil)
        #expect(enabled(GenerationParameters(
            temperature: nil, maxTokens: 32, templateKwargs: ["enable_thinking": .null])) == nil)
    }

    @Test
    func modeOverlayAndHuggingFaceFallbackComposeFromTheSameDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"chat":{"sampling_thinking":{"temperature":0.6}}}"#.utf8)
            .write(to: directory.appendingPathComponent("jang_config.json"))
        try Data(#"{"temperature":0.2,"top_k":20,"do_sample":true}"#.utf8)
            .write(to: directory.appendingPathComponent("generation_config.json"))
        let base = LocalGenerationDefaults.load(fromDirectory: directory)
        #expect(base.temperature == 0.2)
        #expect(base.defaultThinkingEnabled == nil)
        #expect(base.resolvingThinking(true).temperature == 0.6)
        #expect(base.resolvingThinking(true).topK == 20)
        #expect(base.resolvingThinking(true).doSample == true)
    }
}
