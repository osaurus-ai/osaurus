import Foundation

/// App-owned request, independent of a provider's JSON request schema.
///
/// Input retains the portable template messages, native audio samples, and
/// verbatim Responses output Items together. Provider adapters render that
/// snapshot into their wire protocol; native generation consumes it directly.
/// This type deliberately has no Codable conformance: host admission and
/// residency controls must never become client-settable wire fields.
struct ResponsesInferenceRequest: Sendable {
    var model: String
    var input: [ChatMessage]
    var generation = ResponsesGenerationOptions()
    var tools: [Tool]? = nil
    var toolChoice: ToolChoiceOption? = nil
    var sessionID: String? = nil
    var context = InferenceRequestContext()
}

/// Nil values preserve the active bundle's generation defaults. The transport
/// adapter resolves aliases once; it does not invent sampling or output caps.
struct ResponsesGenerationOptions: Sendable, Encodable {
    var temperature: Float? = nil
    var maxOutputTokens: Int? = nil
    var topP: Float? = nil
    var topK: Int? = nil
    var minP: Float? = nil
    var frequencyPenalty: Float? = nil
    var presencePenalty: Float? = nil
    var stop: [String]? = nil
    var seed: Int? = nil
    var outputFormat: ResponseFormat? = nil
    var enableThinking: Bool? = nil
    var reasoningEffort: String? = nil
}

extension ResponsesInferenceRequest {
    /// Compatibility entry point only. Store values directly rather than
    /// encode/decode: JSON would discard live audio and provider output Items.
    init(chatCompletion request: ChatCompletionRequest) {
        model = request.model
        input = request.messages
        generation = ResponsesGenerationOptions(
            temperature: request.temperature,
            maxOutputTokens: request.resolvedMaxTokens,
            topP: request.top_p,
            topK: request.top_k,
            minP: request.min_p,
            frequencyPenalty: request.frequency_penalty,
            presencePenalty: request.presence_penalty,
            stop: request.stop,
            seed: request.seed,
            outputFormat: request.response_format,
            enableThinking: request.enable_thinking,
            reasoningEffort: request.reasoning_effort
        )
        tools = request.tools
        toolChoice = request.tool_choice
        sessionID = request.session_id
        context = request.inferenceContext
    }
}
