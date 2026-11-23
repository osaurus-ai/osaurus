import Foundation

/// Explicit model-picker choices for one conversation and model. Missing values inherit
/// the saved agent and model/server defaults. These never update those default stores.
public struct ChatModelControls: Codable, Equatable, Sendable {
    public var enableThinking: Bool?
    public var reasoningEffort: String?
    public var speculativeDecoding: Bool?

    public init(enableThinking: Bool? = nil, reasoningEffort: String? = nil,
        speculativeDecoding: Bool? = nil) {
        self.enableThinking = enableThinking
        self.reasoningEffort = reasoningEffort
        self.speculativeDecoding = speculativeDecoding
    }

    static func key(for modelID: String) -> String { modelID.lowercased() }

    var hasReasoningOverride: Bool { enableThinking != nil || reasoningEffort != nil }
    var isEmpty: Bool { !hasReasoningOverride && speculativeDecoding == nil }

    /// Reuse the existing agent/request composition without changing the saved agent.
    /// Switching reasoning controls replaces its aliases, preserving unrelated template values.
    func applying(to saved: AgentGenerationSettings?) -> AgentGenerationSettings? {
        guard !isEmpty else { return saved }
        var effective = saved ?? AgentGenerationSettings()
        if hasReasoningOverride {
            effective.enableThinking = enableThinking
            effective.reasoningEffort = reasoningEffort
            if var kwargs = effective.templateKwargs {
                for key in ["enable_thinking", "thinking", "reasoning_effort"] {
                    kwargs.removeValue(forKey: key)
                }
                effective.templateKwargs = kwargs.isEmpty ? nil : kwargs
            }
        }
        if let speculativeDecoding { effective.speculativeDecoding = speculativeDecoding }
        return effective
    }
}
