import Foundation
import Testing
@testable import OsaurusCore

struct AgentGenerationApplicabilityTests {
    @Test("only the registered native target type limits AR fields")
    func classificationUsesTargetMetadata() {
        let native = Data(#"{"model_type":"diffusion_gemma"}"#.utf8)
        #expect(AgentGenerationApplicability.classify(configData: native) == .nativeBlockDiffusion)
        for fixture in [
            #"{"model_type":"gemma4","name":"diffusiongemma"}"#,
            #"{"model_type":"qwen3_5","decision":{"generates_text":false}}"#,
            #"{"model_type":"qwen3","draft_model":{"model_type":"diffusion_gemma"}}"#,
            #"{"model_type":"diffusion_gemma_text"}"#,
            #"{"model_type":"DIFFUSION_GEMMA"}"#,
            #"{"architectures":["DiffusionGemmaModel"]}"#,
            "{}", "not json",
        ] {
            #expect(AgentGenerationApplicability.classify(configData: Data(fixture.utf8)) == .unrestricted)
        }
        #expect(AgentGenerationApplicability.resolve(modelID: "diffusion_gemma", isLocal: false) == .unrestricted)
        #expect(AgentGenerationApplicability.resolve(modelID: nil, isLocal: true) == .unrestricted)
    }

    @Test("renamed local bundles use their config; missing and changed config is not cached")
    func localMetadataAndReclassification() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("renamed-native-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(AgentGenerationApplicability.detect(at: directory) == .unrestricted)
        let config = directory.appendingPathComponent("config.json")
        try Data(#"{"model_type":"diffusion_gemma"}"#.utf8).write(to: config)
        #expect(AgentGenerationApplicability.detect(at: directory) == .nativeBlockDiffusion)
        try Data(#"{"model_type":"gemma4"}"#.utf8).write(to: config)
        #expect(AgentGenerationApplicability.detect(at: directory) == .unrestricted)
        // Metadata discovery must never read model weights or oversized files.
        let oversized = "{\"model_type\":\"diffusion_gemma\",\"padding\":\""
            + String(repeating: "x", count: 1_048_576) + "\"}"
        try Data(oversized.utf8).write(to: config)
        #expect(AgentGenerationApplicability.detect(at: directory) == .unrestricted)
    }

    @Test("native diffusion keeps length seed stop and prompt JSON available")
    func exactFieldApplicability() {
        let inactive: [AgentGenerationField] = [
            .temperature, .topP, .topK, .minP,
            .repetitionPenalty, .frequencyPenalty, .presencePenalty,
        ]
        let active: [AgentGenerationField] = [.maxTokens, .seed, .stop, .templateKwargs]
        #expect(inactive.count + active.count == AgentGenerationField.allCases.count)
        for field in inactive { #expect(!AgentGenerationApplicability.nativeBlockDiffusion.isApplicable(field)) }
        for field in active { #expect(AgentGenerationApplicability.nativeBlockDiffusion.isApplicable(field)) }
        for field in AgentGenerationField.allCases {
            #expect(AgentGenerationApplicability.unrestricted.isApplicable(field))
        }
    }

    @Test("model switching never clears saved overrides, zero values, or unsaved draft text")
    func draftAndJSONSurviveApplicabilityChanges() throws {
        let settings = AgentGenerationSettings(
            topP: 0, topK: 0, minP: 0, repetitionPenalty: 1,
            frequencyPenalty: 0, presencePenalty: 0, seed: 0, stop: [],
            enableThinking: false, templateKwargs: [:])
        let draft = AgentGenerationDraft(temperature: 0, maxTokens: 1_000_000, settings: settings)
        let before = draft
        for policy in [AgentGenerationApplicability.unrestricted, .nativeBlockDiffusion, .unrestricted] {
            #expect(policy.inactiveOverrideCount(in: draft) == (policy == .nativeBlockDiffusion ? 7 : 0))
            let values = try draft.validated()
            #expect(values.temperature == 0)
            #expect(values.maxTokens == 1_000_000)
            #expect(values.settings == settings)
            let roundTrip = try JSONDecoder().decode(
                AgentGenerationSettings.self, from: JSONEncoder().encode(values.settings))
            #expect(roundTrip == settings)
            #expect(draft == before)
        }
        var unsaved = draft
        unsaved.topP.text = "unfinished"
        let unsavedBefore = unsaved
        #expect(AgentGenerationApplicability.nativeBlockDiffusion.inactiveOverrideCount(in: unsaved) == 7)
        #expect(unsaved == unsavedBefore)
        #expect(AgentGenerationApplicability.unrestricted.isApplicable(.topP))
        #expect(unsaved.topP.text == "unfinished")
    }
}

@MainActor
@Suite(.serialized)
struct AgentGenerationApplicabilityPersistenceTests {
    @Test("agent save reload keeps inactive settings through an AR native AR model change")
    func agentStoragePreservesInactiveSettings() async throws {
        try await ChatHistoryTestStorage.run {
            let settings = AgentGenerationSettings(
                topP: 0, topK: 0, minP: 0, repetitionPenalty: 1,
                frequencyPenalty: 0, presencePenalty: 0, seed: 0, stop: [],
                enableThinking: false, templateKwargs: [:])
            var agent = Agent(
                name: "Applicability fixture", defaultModel: "AR fixture",
                temperature: 0, maxTokens: 1_000_000, generationSettings: settings,
                autonomousExec: AutonomousExecConfig(enabled: false))
            for modelID in ["AR fixture", "renamed native fixture", "AR fixture"] {
                agent.defaultModel = modelID
                AgentStore.save(agent)
                let reloaded = try AgentStore.loadPersisted(id: agent.id)
                #expect(reloaded.defaultModel == modelID)
                #expect(reloaded.temperature == 0)
                #expect(reloaded.maxTokens == 1_000_000)
                #expect(reloaded.generationSettings == settings)
                let draft = AgentGenerationDraft(
                    temperature: reloaded.temperature, maxTokens: reloaded.maxTokens,
                    settings: reloaded.generationSettings)
                #expect(AgentGenerationApplicability.nativeBlockDiffusion.inactiveOverrideCount(in: draft) == 7)
            }
        }
    }
}
