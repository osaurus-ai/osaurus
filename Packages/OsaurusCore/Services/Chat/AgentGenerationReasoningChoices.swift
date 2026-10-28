import Foundation

/// The selected model's existing catalog/template contract, never a generic effort ladder.
struct AgentGenerationReasoningChoices: Equatable, Sendable {
    var modelID: String? = nil
    var efforts: ModelReasoningCapabilities?
    var supportsThinking: Bool

    static func resolve(modelID: String, isLocal: Bool) async -> Self {
        let local = isLocal
            ? await LocalReasoningCapability.resolveForDispatch(modelId: modelID)
            : .none
        return Self(
            modelID: modelID,
            efforts: ModelProfileRegistry.reasoningCapabilities(for: modelID),
            supportsThinking: local.isToggleableThinking
        )
    }

    func validate(settings: AgentGenerationSettings) throws {
        if let effort = settings.reasoningEffort,
            efforts?.levels.contains(where: { $0.id == effort }) != true
        {
            throw ChatTurnOverrides.ValidationError.invalid(
                "The selected model does not advertise reasoning effort '\(effort)'. Choose a supported value or Inherit.")
        }
        if settings.enableThinking != nil, !supportsThinking {
            throw ChatTurnOverrides.ValidationError.invalid(
                "The selected model does not advertise a Thinking switch. Choose Inherit.")
        }
    }
}
