import Foundation
import Testing

@testable import OsaurusCore

struct ChatTemplateEngineCarrierTests {
    private actor Capture {
        private var recorded: [GenerationParameters] = []
        func append(_ value: GenerationParameters) { recorded.append(value) }
        func values() -> [GenerationParameters] { recorded }
    }

    /// Uses the existing lightweight fake only at the actual service boundary.
    /// The real engine owns request conversion, option resolution and dispatch.
    private struct RecordingService: ModelService {
        let capture: Capture
        private let base = FakeModelService(supportedModel: "extractor", completeText: "fixture")
        var id: String { base.id }
        func isAvailable() -> Bool { base.isAvailable() }
        func handles(requestedModel: String?) -> Bool { base.handles(requestedModel: requestedModel) }
        func generateOneShot(messages: [ChatMessage], parameters: GenerationParameters,
            requestedModel: String?) async throws -> String {
            throw CancellationError() // This regression requires streaming dispatch.
        }
        func streamDeltas(messages: [ChatMessage], parameters: GenerationParameters,
            requestedModel: String?, stopSequences: [String]) async throws -> AsyncThrowingStream<String, Error> {
            await capture.append(parameters)
            return try await base.streamDeltas(messages: messages, parameters: parameters,
                requestedModel: requestedModel, stopSequences: stopSequences)
        }
    }

    @Test(arguments: ["enable_thinking", "thinking"])
    func realEngineDispatchPreservesTemplateVariablesAndRequestIsolation(thinkingAlias: String) async throws {
        let capture = Capture()
        let engine = ChatEngine(services: [RecordingService(capture: capture)],
            installedModelsProvider: { [] }, remoteServicesProvider: { [] }, source: .httpAPI)
        let first: [String: OsaurusCore.JSONValue] = [
            "template": .object(["name": .string("string"), "optional": .null]),
            "examples": .array([.object(["input": .string("Ada"), "output": .null])]),
            "strict": .bool(false), "threshold": .number(0),
            thinkingAlias: .bool(true),
            "temperature": .number(0.8), "top_p": .number(0.9), "top_k": .number(99)
        ]
        let second: [String: OsaurusCore.JSONValue] = [
            "template": .object(["year": .string("integer")]), thinkingAlias: .bool(false)
        ]
        func send(_ values: [String: OsaurusCore.JSONValue]?, sampling: Bool,
            explicitThinking: Bool?) async throws {
            var body: [String: Any] = ["model": "extractor", "input": "Ada", "max_output_tokens": 16]
            if let values { body["chat_template_kwargs"] = values.mapValues(\.anyValue) }
            if sampling { body["temperature"] = 0; body["top_p"] = 0; body["top_k"] = 0; body["min_p"] = 0 }
            if let explicitThinking { body["enable_thinking"] = explicitThinking }
            let wire = try JSONDecoder().decode(OpenResponsesRequest.self,
                from: JSONSerialization.data(withJSONObject: body))
            let request = try wire.toResponsesInferenceRequest()
            for try await _ in try await engine.streamResponses(request: request) {}
        }

        // Explicit top-level false wins over a true template alias. Sampling
        // fields remain independent of same-named ordinary template variables.
        try await send(first, sampling: true, explicitThinking: false)
        // A later request may supply only an alias, without sampler overrides.
        try await send(second, sampling: false, explicitThinking: nil)
        // The same engine must not carry any of those variables into step three.
        try await send(nil, sampling: false, explicitThinking: nil)

        let values = await capture.values()
        try #require(values.count == 3)
        #expect(values[0].templateKwargs == first)
        #expect(values[0].temperature == 0)
        #expect(values[0].topPOverride == 0)
        #expect(values[0].topKOverride == 0)
        #expect(values[0].minPOverride == 0)
        #expect(values[0].modelOptions["disableThinking"] == .bool(true))
        #expect(values[1].templateKwargs == second)
        #expect(values[1].temperature == nil && values[1].topPOverride == nil)
        #expect(values[1].topKOverride == nil && values[1].minPOverride == nil)
        #expect(values[1].modelOptions["disableThinking"] == .bool(true))
        #expect(values[2].templateKwargs == nil)
        #expect(values[2].temperature == nil && values[2].topPOverride == nil)
        #expect(values[2].topKOverride == nil && values[2].minPOverride == nil)
        #expect(values[2].modelOptions["disableThinking"] == nil)
    }
}
