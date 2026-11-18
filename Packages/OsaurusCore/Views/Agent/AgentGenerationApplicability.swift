import Foundation

/// Presentation only: retain saved values even when the selected execution
/// path does not consume them. Unknown/remote models keep the existing editor.
enum AgentGenerationApplicability: Equatable, Sendable {
    case unrestricted
    case nativeBlockDiffusion

    static func resolve(modelID: String?, isLocal: Bool) -> Self {
        guard isLocal, let modelID,
            let directory = LocalReasoningCapability.localDirectory(forModelId: modelID)
        else { return .unrestricted }
        return detect(at: directory)
    }

    static func detect(at directory: URL) -> Self {
        guard let data = LocalReasoningCapability.readSmallConfigFile(
            directory.appendingPathComponent("config.json"))
        else { return .unrestricted }
        return classify(configData: data)
    }

    static func classify(configData: Data) -> Self {
        guard let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
            let modelType = config["model_type"] as? String
        else { return .unrestricted }
        // Both current runtime factories route this exact type to a target
        // conforming to BlockDiffusionModel. Names, decision backbones and
        // the presence of a diffusion drafter do not select that target path.
        return modelType == "diffusion_gemma" ? .nativeBlockDiffusion : .unrestricted
    }

    func isApplicable(_ field: AgentGenerationField) -> Bool {
        guard self == .nativeBlockDiffusion else { return true }
        switch field {
        case .temperature, .topP, .topK, .minP,
            .repetitionPenalty, .frequencyPenalty, .presencePenalty:
            return false
        case .maxTokens, .seed, .stop, .templateKwargs:
            return true
        }
    }

    func inactiveOverrideCount(in draft: AgentGenerationDraft) -> Int {
        AgentGenerationField.allCases.filter {
            !isApplicable($0) && draft[keyPath: $0.path].isCustom
        }.count
    }
}
