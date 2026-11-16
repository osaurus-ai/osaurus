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
    /// Protocol options are data-plane values, separate from host-only
    /// admission, residency, routing and attribution controls.
    var providerOptions: ResponsesProviderOptions? = nil
}

struct ResponsesProviderOptions: Sendable {
    var tools: [OpenResponsesTool]? = nil
    var toolChoice: OpenResponsesToolChoice? = nil
    var reasoning: OpenResponsesReasoningConfig? = nil
    var store: Bool? = nil
    var include: [String]? = nil
    var parallelToolCalls: Bool? = nil
    var metadata: [String: String]? = nil
    var text: OpenResponsesTextConfig? = nil

    /// Hosted/custom tools have no native local executor. Reject them on a
    /// portable route instead of silently dropping them from the schema.
    var unsupportedPortableTools: [String] { tools?.filter { !$0.isFunction }.map(\.type) ?? [] }
}

/// Nil values preserve the active bundle's generation defaults. The transport
/// adapter resolves aliases once; it does not invent sampling or output caps.
struct ResponsesGenerationOptions: Sendable, Encodable {
    var temperature: Float? = nil
    var maxOutputTokens: Int? = nil
    var topP: Float? = nil
    var topK: Int? = nil
    var minP: Float? = nil
    var repetitionPenalty: Float? = nil
    var frequencyPenalty: Float? = nil
    var presencePenalty: Float? = nil
    var stop: [String]? = nil
    var seed: Int? = nil
    var outputFormat: ResponseFormat? = nil
    var enableThinking: Bool? = nil
    var reasoningEffort: String? = nil
    var templateKwargs: [String: JSONValue]? = nil
}

extension ResponsesInferenceRequest {
    /// Boundary adapter for an older injected engine/client implementation.
    /// The builtin engine overrides the typed entry point and never uses this.
    func chatCompletionsCompatibilityRequest() -> ChatCompletionRequest {
        var request = ChatCompletionRequest(
            model: model,
            messages: input,
            temperature: generation.temperature,
            max_tokens: generation.maxOutputTokens,
            stream: true,
            top_p: generation.topP,
            top_k: generation.topK,
            frequency_penalty: generation.frequencyPenalty,
            presence_penalty: generation.presencePenalty,
            stop: generation.stop,
            n: nil,
            tools: tools,
            tool_choice: toolChoice,
            session_id: sessionID,
            seed: generation.seed,
            response_format: generation.outputFormat
        )
        request.min_p = generation.minP
        request.repetition_penalty = generation.repetitionPenalty
        request.enable_thinking = generation.enableThinking
        request.reasoning_effort = generation.reasoningEffort
        request.chat_template_kwargs = generation.templateKwargs
        request.inferenceContext = context
        return request
    }

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
            repetitionPenalty: request.repetition_penalty,
            frequencyPenalty: request.frequency_penalty,
            presencePenalty: request.presence_penalty,
            stop: request.stop,
            seed: request.seed,
            outputFormat: request.response_format,
            enableThinking: request.enable_thinking,
            reasoningEffort: request.reasoning_effort,
            templateKwargs: request.chat_template_kwargs
        )
        tools = request.tools
        toolChoice = request.tool_choice
        sessionID = request.session_id
        context = request.inferenceContext
    }
}
