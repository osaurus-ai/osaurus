import Foundation

/// The selected model's existing catalog/template contract, never a generic effort ladder.
struct AgentGenerationReasoningChoices: Equatable, Sendable {
    var modelID: String? = nil
    var efforts: ModelReasoningCapabilities?
    var supportsThinking: Bool
    /// Presentation can use a single effort picker while the native template still accepts a boolean.
    var thinkingControlIsCanonical: Bool? = nil

    var showsThinkingControl: Bool { supportsThinking && thinkingControlIsCanonical != false }

    static func resolve(modelID: String, isLocal: Bool) async -> Self {
        let local = isLocal
            ? await LocalReasoningCapability.resolveForDispatch(modelId: modelID)
            : .none
        return resolved(
            modelID: modelID,
            localCapability: local,
            efforts: ModelProfileRegistry.reasoningCapabilities(for: modelID),
            options: ModelProfileRegistry.options(for: modelID)
        )
    }

    static func resolved(modelID: String, localCapability: LocalReasoningCapability.Capability,
        efforts: ModelReasoningCapabilities?, options: [ModelOptionDefinition]) -> Self
    {
        Self(modelID: modelID, efforts: efforts,
            supportsThinking: localCapability.isToggleableThinking,
            thinkingControlIsCanonical: options.contains { $0.id == "disableThinking" })
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
