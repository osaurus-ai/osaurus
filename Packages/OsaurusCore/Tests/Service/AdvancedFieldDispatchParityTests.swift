import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

/// Exercises composition across actual host boundaries rather than reimplementing
/// the resolver in a test: saved agent values -> frozen turn -> ChatEngine -> adapter.
struct AdvancedFieldDispatchParityTests {
    private struct Entry: Sendable {
        let parameters: GenerationParameters
        let stops: [String]
    }

    private actor Capture {
        private var entries: [Entry] = []
        func append(parameters: GenerationParameters, stops: [String]) {
            entries.append(Entry(parameters: parameters, stops: stops))
        }
        func values() -> [Entry] { entries }
    }

    private struct RecordingService: ModelService {
        let capture: Capture
        private let base = FakeModelService(supportedModel: "advanced-field-fixture", completeText: "fixture")
        var id: String { base.id }
        func isAvailable() -> Bool { true }
        func handles(requestedModel: String?) -> Bool { base.handles(requestedModel: requestedModel) }
        func generateOneShot(messages: [ChatMessage], parameters: GenerationParameters,
            requestedModel: String?) async throws -> String { throw CancellationError() }
        func streamDeltas(messages: [ChatMessage], parameters: GenerationParameters,
            requestedModel: String?, stopSequences: [String]) async throws -> AsyncThrowingStream<String, Error>
        {
            await capture.append(parameters: parameters, stops: stopSequences)
            return try await base.streamDeltas(messages: messages, parameters: parameters,
                requestedModel: requestedModel, stopSequences: stopSequences)
        }
    }

    @Test("a local-only speculation override is rejected before a nonlocal service is invoked")
    func localOnlySpeculationRejectsNonlocalRoute() async throws {
        let capture = Capture()
        let engine = ChatEngine(services: [RecordingService(capture: capture)], installedModelsProvider: { [] },
            remoteServicesProvider: { [] }, source: .httpAPI)
        var controls = ChatTurnGenerationControls.capture(activeModelOptions: [:])
        controls.agentSettings = .init(speculativeDecoding: false)
        var request = ResponsesInferenceRequest(model: "advanced-field-fixture", input: [])
        controls.apply(to: &request)
        #expect(request.context.speculativeDecoding == false)
        do {
            _ = try await engine.streamResponses(request: request)
            Issue.record("Local-only speculation reached a nonlocal fake service")
        } catch let error as ChatTurnOverrides.ValidationError {
            #expect(error.localizedDescription.contains("require a local model"))
        }
        #expect(await capture.values().isEmpty)
    }

    @Test("saved neutral values beat server and bundle defaults on actual dispatch; turn overrides win next")
    func neutralAgentValuesSurviveDispatch() async throws {
        let saved = AgentGenerationSettings(
            topP: 0, topK: 0, minP: 0, repetitionPenalty: 1,
            frequencyPenalty: 0, presencePenalty: 0, seed: 0, stop: [],
            enableThinking: false, templateKwargs: [:])
        // Use the same Codable representation persisted with a custom agent.
        let settings = try JSONDecoder().decode(AgentGenerationSettings.self, from: JSONEncoder().encode(saved))
        var controls = ChatTurnGenerationControls.capture(activeModelOptions: [:])
        controls.temperature = 0
        controls.topP = 0.8
        controls.maxOutputTokens = 8
        controls.agentSettings = settings
        controls.agentDefaultsCaptured = true
        let capture = Capture()
        // This intentionally nonlocal fake advertises a boolean reasoning control;
        // it does not claim eligibility for the local-only speculation setting.
        let engine = ChatEngine(services: [RecordingService(capture: capture)], installedModelsProvider: { [] },
            remoteServicesProvider: { [] }, agentReasoningChoicesProvider: { modelID, _ in
                AgentGenerationReasoningChoices(modelID: modelID, efforts: nil, supportsThinking: true)
            }, source: .httpAPI)
        for index in 0..<2 {
            if index == 1 {
                controls.overrides = .init(temperature: 0.4, topP: 0.7, topK: 5, enableThinking: true)
            }
            var request = ResponsesInferenceRequest(model: "advanced-field-fixture", input: [],
                generation: ResponsesGenerationOptions(maxOutputTokens: controls.maxOutputTokens))
            controls.apply(to: &request)
            #expect(request.generation.stop == [])
            #expect(request.generation.templateKwargs == [:])
            for try await _ in try await engine.streamResponses(request: request) {}
        }
        // Omission after explicit controls must not inherit the previous request's values.
        let omitted = ResponsesInferenceRequest(model: "advanced-field-fixture", input: [])
        #expect(omitted.generation.stop == nil)
        for try await _ in try await engine.streamResponses(request: omitted) {}
        let entries = await capture.values()
        try #require(entries.count == 3)
        let first = entries[0].parameters
        #expect(first.temperature == 0 && first.topPOverride == 0 && first.topKOverride == 0)
        #expect(first.minPOverride == 0 && first.repetitionPenalty == 1)
        #expect(first.frequencyPenalty == 0 && first.presencePenalty == 0 && first.seed == 0)
        #expect(first.maxTokens == 8 && first.maxTokensExplicit)
        #expect(first.modelOptions["disableThinking"]?.boolValue == true)
        #expect(first.templateKwargs == [:] && first.speculativeDecoding == nil)
        #expect(entries[0].stops == [])
        let second = entries[1].parameters
        #expect(second.temperature == 0.4 && second.topPOverride == 0.7 && second.topKOverride == 5)
        #expect(second.modelOptions["disableThinking"]?.boolValue == false)
        #expect(second.minPOverride == 0 && second.presencePenalty == 0 && second.seed == 0)
        let third = entries[2].parameters
        #expect(third.temperature == nil && third.topPOverride == nil && third.topKOverride == nil)
        #expect(third.minPOverride == nil && third.repetitionPenalty == nil)
        #expect(third.presencePenalty == nil && third.frequencyPenalty == nil && third.seed == nil)
        #expect(third.templateKwargs == nil && third.speculativeDecoding == nil)
        #expect(!third.maxTokensExplicit)

        let bundle = LocalGenerationDefaults.Defaults(maxTokens: 32, temperature: 1,
            topP: 0.95, topK: 40, minP: 0.03, repetitionPenalty: 1.1,
            presencePenalty: 0.4, frequencyPenalty: 0.5)
        let server = VMLXServerGenerationDefaults(maxTokens: 16, temperature: 0.9,
            topP: 0.85, topK: 20, minP: 0.02, repetitionPenalty: 1.2)
        let explicit = MLXBatchAdapter.effectiveGenerationSettings(modelName: "advanced-field-fixture",
            generation: first, runtimeDefaults: server, maxBatchSize: 1, modelDefaults: bundle)
        #expect(explicit.temperature == 0 && explicit.topP == 0 && explicit.topK == 0 && explicit.minP == 0)
        #expect(explicit.repetitionPenalty == 1 && explicit.presencePenalty == 0 && explicit.frequencyPenalty == 0)
        #expect(explicit.maxTokens == 8)
        let inherited = MLXBatchAdapter.effectiveGenerationSettings(modelName: "advanced-field-fixture",
            generation: third, runtimeDefaults: server, maxBatchSize: 1, modelDefaults: bundle)
        #expect(inherited.temperature == 0.9 && inherited.topP == 0.85 && inherited.topK == 20)
        #expect(inherited.minP == 0.02 && inherited.repetitionPenalty == 1.2 && inherited.maxTokens == 16)
        #expect(inherited.presencePenalty == 0.4 && inherited.frequencyPenalty == 0.5)
    }
}
