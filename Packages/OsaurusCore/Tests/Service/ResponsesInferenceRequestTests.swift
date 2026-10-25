import Foundation
import Testing

@testable import OsaurusCore

struct ResponsesInferenceRequestTests {
    private func legacy() -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: "model",
            messages: [],
            temperature: nil,
            max_tokens: nil,
            stream: true,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil
        )
    }

    @Test func omittedGenerationControlsStayOmitted() {
        let request = ResponsesInferenceRequest(chatCompletion: legacy())
        #expect(request.generation.temperature == nil)
        #expect(request.generation.maxOutputTokens == nil)
        #expect(request.generation.topP == nil)
        #expect(request.generation.topK == nil)
        #expect(request.generation.minP == nil)
        #expect(request.generation.frequencyPenalty == nil)
        #expect(request.generation.presencePenalty == nil)
        #expect(request.generation.stop == nil)
        #expect(request.generation.seed == nil)
        #expect(request.generation.outputFormat == nil)
        #expect(request.generation.enableThinking == nil)
        #expect(request.generation.reasoningEffort == nil)
    }

    @Test(arguments: [false, true])
    func legacyOutputTokenAliasPreservesExistingPrecedence(_ bothPresent: Bool) throws {
        var request = try JSONDecoder().decode(
            ChatCompletionRequest.self,
            from:
                Data(#"{"model":"model","messages":[],"max_completion_tokens":4096}"#.utf8)
        )
        if bothPresent {
            request = try JSONDecoder().decode(
                ChatCompletionRequest.self,
                from:
                    Data(#"{"model":"model","messages":[],"max_tokens":2048,"max_completion_tokens":4096}"#.utf8)
            )
        }
        #expect(
            ResponsesInferenceRequest(chatCompletion: request).generation.maxOutputTokens == request.resolvedMaxTokens
        )
        #expect(
            ResponsesInferenceRequest(chatCompletion: request).generation.maxOutputTokens == (bothPresent ? 2048 : 4096)
        )
    }

    @Test func mediaSamplesAndProviderItemsSurviveTheBoundaryWithoutWireRoundTrip() throws {
        let samples = LocalAudioSamples(samples: [0.25, -0.5], sampleRate: 16000)
        let media = ChatMessage(
            role: "user",
            text: "inspect",
            imageData: [Data([1, 2])],
            audios: [(data: Data([3, 4]), format: "wav")],
            localAudioSamples: [samples],
            videos: [(data: Data([5, 6]), mimeSubtype: "mp4")]
        )
        let raw = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(
                #"{"type":"message","id":"msg_1","phase":"commentary","content":[{"type":"output_text","text":"working","annotations":[]}],"future_field":{"untouched":true}}"#
                    .utf8
            )
        )
        let assistant = ChatMessage(
            role: "assistant",
            content: "working",
            tool_calls: nil,
            tool_call_id: nil,
            reasoning_content: "native chain",
            reasoning_item_id: "rs_1",
            reasoning_encrypted: "opaque",
            responses_output_items: [raw]
        )
        var legacy = legacy()
        legacy.messages = [media, assistant]
        let request = ResponsesInferenceRequest(chatCompletion: legacy)
        #expect(request.input.count == 2)
        #expect(request.input[0].localAudioSamples == [samples])
        #expect(request.input[0].imageUrls == media.imageUrls)
        #expect(request.input[0].videoUrls == media.videoUrls)
        #expect(request.input[0].audioInputs.first?.data == media.audioInputs.first?.data)
        #expect(request.input[1].reasoning_content == "native chain")
        #expect(request.input[1].reasoning_item_id == "rs_1")
        #expect(request.input[1].reasoning_encrypted == "opaque")
        #expect(request.input[1].responses_output_items == [raw])
        let compatibility = request.chatCompletionsCompatibilityRequest()
        #expect(compatibility.messages[0].localAudioSamples == [samples])
        #expect(compatibility.messages[1].responses_output_items == [raw])
        #expect(compatibility.messages[1].reasoning_content == "native chain")
    }

    @Test func contextAndExplicitOptionsAreCopiedIndependently() {
        var legacy = legacy()
        legacy.top_k = 37
        legacy.min_p = 0.03
        legacy.enable_thinking = false
        legacy.reasoning_effort = "high"
        legacy.session_id = "session"
        legacy.inferenceContext.admissionPositionLimit = 8192
        legacy.inferenceContext.admissionOutputTokensAreImplicit = true
        legacy.inferenceContext.cacheStableSystemPrefix = "byte-exact prefix"
        legacy.inferenceContext.backgroundModelLoad = true
        legacy.inferenceContext.preserveExistingResidencyOwner = true
        let request = ResponsesInferenceRequest(chatCompletion: legacy)
        legacy.admissionPositionLimit = 1024
        var next = request
        next.model = "next"
        next.context.backgroundModelLoad = false
        #expect(request.model == "model")
        #expect(request.context.admissionPositionLimit == 8192)
        #expect(request.context.admissionOutputTokensAreImplicit)
        #expect(request.context.cacheStableSystemPrefix == "byte-exact prefix")
        #expect(request.context.backgroundModelLoad)
        #expect(request.context.preserveExistingResidencyOwner)
        #expect(next.context.admissionPositionLimit == 8192)
        #expect(request.generation.topK == 37)
        #expect(request.generation.minP == 0.03)
        #expect(request.generation.enableThinking == false)
        #expect(request.generation.reasoningEffort == "high")
        #expect(request.sessionID == "session")
        let compatibility = request.chatCompletionsCompatibilityRequest()
        #expect(compatibility.admissionPositionLimit == 8192)
        #expect(compatibility.admissionOutputTokensAreImplicit)
        #expect(compatibility.backgroundModelLoad)
        #expect(compatibility.cacheStableSystemPrefix == "byte-exact prefix")
        #expect(compatibility.top_k == 37)
        #expect(compatibility.min_p == 0.03)
        #expect(compatibility.enable_thinking == false)
    }
}
