import Foundation

/// The selected model's existing catalog/template contract, never a generic effort ladder.
struct AgentGenerationReasoningChoices: Equatable, Sendable {
    var modelID: String? = nil
    var efforts: ModelReasoningCapabilities?
    var supportsThinking: Bool
    var speculation: ModelRuntime.LoadingModelMTPStatus? = nil
    /// Presentation can use a single effort picker while the native template still accepts a boolean.
    var thinkingControlIsCanonical: Bool? = nil

    var showsThinkingControl: Bool { supportsThinking && thinkingControlIsCanonical != false }

    static func resolve(modelID: String, isLocal: Bool, includeSpeculation: Bool = false) async -> Self {
        let local = isLocal
            ? await LocalReasoningCapability.resolveForDispatch(modelId: modelID)
            : .none
        var choices = resolved(
            modelID: modelID,
            localCapability: local,
            efforts: ModelProfileRegistry.reasoningCapabilities(for: modelID),
            options: ModelProfileRegistry.options(for: modelID)
        )
        if isLocal && includeSpeculation {
            choices.speculation = await Task.detached(priority: .utility) {
                ModelRuntime.inspectLoadingModelMTP(name: modelID)
            }.value
        }
        return choices
    }

    static func resolved(modelID: String, localCapability: LocalReasoningCapability.Capability,
        efforts: ModelReasoningCapabilities?, options: [ModelOptionDefinition]) -> Self
    {
        Self(modelID: modelID, efforts: efforts,
            supportsThinking: localCapability.isToggleableThinking,
            thinkingControlIsCanonical: options.contains { $0.id == "disableThinking" })
    }

    func validate(settings: AgentGenerationSettings) throws {
        if settings.speculativeDecoding != nil, speculation == nil {
            throw ChatTurnOverrides.ValidationError.invalid(
                "The selected model has no local speculation capability information. Choose Inherit.")
        }
        if settings.speculativeDecoding == true,
            speculation?.speculationAvailable != true || speculation?.speculationBlocked == true
        {
            throw ChatTurnOverrides.ValidationError.invalid(
                "The selected model has no eligible adaptive speculation path. Choose Inherit or Off (AR).")
        }
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
