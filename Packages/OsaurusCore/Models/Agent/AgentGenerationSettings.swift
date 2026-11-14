import Foundation

/// User-saved custom-agent overrides. Omission inherits the selected model's defaults.
/// Temperature and output-token limits remain on `Agent` rather than being duplicated here.
public struct AgentGenerationSettings: Codable, Equatable, Sendable {
    public var topP: Float?
    public var topK: Int?
    public var minP: Float?
    public var repetitionPenalty: Float?
    public var frequencyPenalty: Float?
    public var presencePenalty: Float?
    public var seed: Int?
    public var stop: [String]?
    public var enableThinking: Bool?
    public var reasoningEffort: String?
    public var templateKwargs: [String: JSONValue]?
    /// Host-only preference: nil inherits Server; false uses AR; true requests adaptive drafting.
    public var speculativeDecoding: Bool?

    public init(
        topP: Float? = nil, topK: Int? = nil, minP: Float? = nil,
        repetitionPenalty: Float? = nil, frequencyPenalty: Float? = nil,
        presencePenalty: Float? = nil, seed: Int? = nil, stop: [String]? = nil,
        enableThinking: Bool? = nil, reasoningEffort: String? = nil,
        templateKwargs: [String: JSONValue]? = nil, speculativeDecoding: Bool? = nil
    ) {
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.seed = seed
        self.stop = stop
        self.enableThinking = enableThinking
        self.reasoningEffort = reasoningEffort
        self.templateKwargs = templateKwargs
        self.speculativeDecoding = speculativeDecoding
    }

    enum CodingKeys: String, CodingKey {
        case topP = "top_p"
        case topK = "top_k"
        case minP = "min_p"
        case repetitionPenalty = "repetition_penalty"
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
        case seed, stop
        case enableThinking = "enable_thinking"
        case reasoningEffort = "reasoning_effort"
        case templateKwargs = "template_kwargs"
        case speculativeDecoding = "speculative_decoding"
    }

    var hasReasoningOverride: Bool {
        enableThinking != nil || reasoningEffort != nil
            || templateKwargs?["enable_thinking"]?.boolValue != nil
            || templateKwargs?["thinking"]?.boolValue != nil
            || templateKwargs?["reasoning_effort"]?.stringValue != nil
    }

    var isEmpty: Bool {
        topP == nil && topK == nil && minP == nil && repetitionPenalty == nil
            && frequencyPenalty == nil && presencePenalty == nil && seed == nil
            && stop == nil && enableThinking == nil && reasoningEffort == nil
            && templateKwargs == nil && speculativeDecoding == nil
    }

    func validate() throws {
        try ChatTurnOverrides(
            topP: topP, topK: topK, reasoningEffort: reasoningEffort,
            enableThinking: enableThinking, templateKwargs: templateKwargs
        ).validate()
        if let reason = RequestValidator.repetitionPenaltyReason(repetitionPenalty) {
            throw ChatTurnOverrides.ValidationError.invalid(reason)
        }
        // These existing request fields have no shared model-independent range contract.
        // Reject non-numbers without inventing provider-specific bounds or defaults.
        for (name, value) in [
            ("Min P", minP), ("Frequency penalty", frequencyPenalty),
            ("Presence penalty", presencePenalty),
        ] {
            if let value, !value.isFinite {
                throw ChatTurnOverrides.ValidationError.invalid("\(name) must be a finite number.")
            }
        }
    }
}
