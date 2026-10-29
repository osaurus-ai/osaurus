import Foundation
@preconcurrency import MLXLMCommon

/// Display-only snapshot. Values come from the runtime resolver, never from UI examples.
/// Unknown provider defaults stay unknown; this type never writes settings or requests.
struct AgentGenerationInheritedValues {
    struct Value: Equatable {
        var text: String
        var source: String
        var customText: String?
    }
    var fields: [AgentGenerationField: Value] = [:]

    subscript(_ field: AgentGenerationField) -> Value {
        fields[field] ?? Value(text: "Model / server default", source: "", customText: nil)
    }

    static func resolve(
        modelID: String?,
        isLocal: Bool,
        modelDefaults: LocalGenerationDefaults.Defaults,
        runtime: VMLXServerGenerationDefaults,
        appTopP: Float?,
        modelOptions: [String: ModelOptionValue],
        draft: AgentGenerationDraft
    ) -> Self {
        var result = Self()
        result.fields[.stop] = .init(text: "No additional stop strings", source: "", customText: "[]")
        result.fields[.templateKwargs] = .init(text: "No additional parameters", source: "", customText: "{}")
        // App-level Top P is sent to remote providers too; it is known even when
        // that provider's own defaults are not. Local runtime policy resolves it below.
        if let appTopP {
            result.fields[.topP] = .init(text: String(appTopP), source: "App", customText: String(appTopP))
        }
        guard let modelID, isLocal else { return result }
        var options = modelOptions
        if draft.thinking != "inherit" { options["disableThinking"] = .bool(draft.thinking == "off") }
        if !draft.reasoningEffort.isEmpty { options["reasoningEffort"] = .string(draft.reasoningEffort) }
        let kwargs =
            draft.templateKwargs.isCustom
            ? try? JSONDecoder().decode([String: JSONValue].self, from: Data(draft.templateKwargs.text.utf8)) : nil
        // No request is dispatched. The sentinel cap is never displayed or seeded as a default.
        let generation = GenerationParameters(
            temperature: nil,
            maxTokens: 0,
            maxTokensExplicit: false,
            topPOverride: appTopP,
            modelOptions: options,
            templateKwargs: kwargs
        )
        let thinking = MLXBatchAdapter.thinkingEnabledForSampling(
            generation: generation,
            modelName: modelID,
            modelDefaults: modelDefaults
        )
        let bundle = modelDefaults.resolvingThinking(thinking)
        let resolved = MLXBatchAdapter.effectiveGenerationSettings(
            modelName: modelID,
            generation: generation,
            runtimeDefaults: runtime,
            maxBatchSize: 1,
            modelDefaults: modelDefaults,
            thinkingEnabled: thinking
        )
        func number<T: CustomStringConvertible>(
            _ field: AgentGenerationField,
            _ value: T,
            server: Bool,
            model: Bool,
            app: Bool = false
        ) {
            result.fields[field] = .init(
                text: value.description,
                source: app ? "App" : server ? "Server" : model ? "Model" : "Runtime",
                customText: value.description
            )
        }
        number(
            .temperature,
            resolved.temperature,
            server: runtime.temperature != nil,
            model: bundle.temperature != nil || bundle.doSample == false
        )
        number(.topP, resolved.topP, server: runtime.topP != nil, model: bundle.topP != nil, app: appTopP != nil)
        number(.topK, resolved.topK, server: runtime.topK != nil, model: bundle.topK != nil)
        number(.minP, resolved.minP, server: runtime.minP != nil, model: bundle.minP != nil)
        if runtime.maxTokens != nil || bundle.maxTokens != nil {
            number(.maxTokens, resolved.maxTokens, server: runtime.maxTokens != nil, model: bundle.maxTokens != nil)
        } else {
            result.fields[.maxTokens] = .init(text: "Response default", source: "App", customText: nil)
        }
        if let penalty = resolved.repetitionPenalty {
            number(
                .repetitionPenalty,
                penalty,
                server: runtime.repetitionPenalty != nil,
                model: bundle.repetitionPenalty != nil
            )
        } else {
            result.fields[.repetitionPenalty] = .init(text: "Off", source: "Runtime", customText: nil)
        }
        if let penalty = resolved.frequencyPenalty {
            number(.frequencyPenalty, penalty, server: false, model: bundle.frequencyPenalty != nil)
        } else {
            result.fields[.frequencyPenalty] = .init(text: "Off", source: "Runtime", customText: nil)
        }
        if let penalty = resolved.presencePenalty {
            number(.presencePenalty, penalty, server: false, model: bundle.presencePenalty != nil)
        } else {
            result.fields[.presencePenalty] = .init(text: "Off", source: "Runtime", customText: nil)
        }
        result.fields[.seed] = .init(text: "Random", source: "Runtime", customText: nil)
        return result
    }
}
