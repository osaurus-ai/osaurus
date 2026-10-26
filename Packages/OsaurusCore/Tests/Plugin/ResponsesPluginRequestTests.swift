import Foundation
import Testing

@testable import OsaurusCore

@Suite("Plugin Responses request continuity", .timeLimit(.minutes(1)))
struct ResponsesPluginRequestTests {
    private func snapshot(_ request: ChatCompletionRequest) -> ResponsesInferenceRequest {
        ResponsesInferenceRequest(chatCompletion: request)
    }
    private func snapshot(_ request: ResponsesInferenceRequest) -> ResponsesInferenceRequest { request }

    private var tool: Tool {
        Tool(type: "function", function: ToolFunction(name: "probe", description: nil, parameters: nil))
    }

    private func context(memory: String? = nil) -> PluginHostContext.AgentContext {
        .init(
            agentId: UUID(), systemPrompt: "fixture system", memorySection: memory,
            model: "selected-model", temperature: nil, maxTokens: 900, tools: [tool], executionMode: .none
        )
    }

    private func source() -> ChatCompletionRequest {
        var request = ChatCompletionRequest(
            model: "default", messages: [ChatMessage(role: "user", content: "fixture")],
            temperature: nil, max_tokens: nil, stream: true, top_p: 0.91,
            frequency_penalty: nil, presence_penalty: nil, stop: ["user-stop"], n: nil,
            tools: [tool], tool_choice: .auto, session_id: "plugin-session", seed: 27
        )
        request.max_completion_tokens = 72
        request.top_k = 17
        request.min_p = 0.03
        request.enable_thinking = true
        request.reasoning_effort = "high"
        request.samplingParametersAreImplicit = true
        request.turnId = UUID()
        request.idempotencyKey = "plugin-request-id"
        request.admissionPositionLimit = 777
        request.admissionOutputTokensAreImplicit = true
        request.backgroundModelLoad = true
        request.preserveExistingResidencyOwner = true
        return request
    }

    private func verify(_ actual: ResponsesInferenceRequest, source: ChatCompletionRequest) {
        #expect(actual.model == "selected-model")
        #expect(actual.generation.maxOutputTokens == 72)
        #expect(actual.generation.topK == 17)
        #expect(actual.generation.minP == 0.03)
        #expect(actual.generation.seed == 27)
        #expect(actual.generation.enableThinking == true && actual.generation.reasoningEffort == "high")
        #expect(actual.generation.temperature == nil)
        #expect(actual.context.turnId == source.turnId)
        #expect(actual.context.idempotencyKey == "plugin-request-id")
        #expect(actual.context.samplingParametersAreImplicit)
        #expect(actual.context.admissionPositionLimit == 777)
        #expect(actual.context.admissionOutputTokensAreImplicit)
        #expect(actual.context.backgroundModelLoad && actual.context.preserveExistingResidencyOwner)
        #expect(actual.sessionID == "plugin-session")
    }

    @Test func enrichmentAndIterationKeepExplicitAliasesAndHostControls() {
        let source = source()
        let enriched = PluginHostContext.enrichRequest(
            source, context: context(), options: .init(from: [:])
        )
        verify(snapshot(enriched.request), source: source)
        let iter = PluginHostContext.iterationRequest(
            from: enriched.request, messages: [ChatMessage(role: "user", content: "next")], tools: [tool]
        )
        let value = snapshot(iter)
        verify(value, source: source)
        #expect(value.input.first?.content == "next")
        #expect(value.context.isAgentRequest)
    }

    @Test @MainActor func resolvedToolsKeepRequestAndRecordedMemoryBoundary() async throws {
        let source = source()
        let enriched = PluginHostContext.enrichRequest(
            source, context: context(memory: "fixture memory"), options: .init(from: [:])
        )
        let recorded = try #require(enriched.recordedUserPrefix)
        let resolved = await PluginHostContext.applyResolvedTools([tool], to: enriched)
        verify(snapshot(resolved.request), source: source)
        #expect(resolved.recordedUserPrefix?.key == recorded.key)
        #expect(resolved.recordedUserPrefix?.prefix == recorded.prefix)
    }
}
