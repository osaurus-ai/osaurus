//
//  AgentReasoningPolicy.swift
//  osaurus
//
//  Preserves the model bundle/template reasoning contract on every surface.
//  Only explicit user or API choices may override omitted thinking controls.
//

import Foundation

enum AgentReasoningPolicy {
    /// Project explicit request reasoning onto runtime options. Shared with the chat
    /// readout so saved agent defaults and template kwargs display what dispatch uses.
    /// Omitted controls do not manufacture model defaults.
    static func applyingExplicitReasoning(
        _ generation: ResponsesGenerationOptions,
        to options: [String: ModelOptionValue],
        modelID: String
    ) -> [String: ModelOptionValue] {
        var options = options
        let enabled = generation.enableThinking
            ?? generation.templateKwargs?["enable_thinking"]?.boolValue
            ?? generation.templateKwargs?["thinking"]?.boolValue
        let effort = (generation.reasoningEffort
            ?? generation.templateKwargs?["reasoning_effort"]?.stringValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if Hy3ReasoningProfile.matches(modelId: modelID) {
            if let effort, !effort.isEmpty {
                options["reasoningEffort"] = .string(Hy3ReasoningProfile.normalizedEffort(effort))
            } else if options["reasoningEffort"] == nil, let enabled {
                options["reasoningEffort"] = .string(enabled ? "high" : "no_think")
            }
            options.removeValue(forKey: "disableThinking")
        } else {
            if let enabled { options["disableThinking"] = .bool(!enabled) }
            if let effort, !effort.isEmpty { options["reasoningEffort"] = .string(effort) }
        }
        return options
    }

    /// Return the thinking override an agent/tool request should add, or nil
    /// when the caller/model contract must remain untouched.
    ///
    /// Explicit wire and model-option choices win. Otherwise leave the control
    /// omitted, including for agent/tool requests and template-only defaults.
    static func defaultEnableThinking(
        isAgentOrToolRequest: Bool,
        explicitEnableThinking: Bool?,
        explicitReasoningEffort: String?,
        modelOptions: [String: ModelOptionValue],
        usesReasoningEffortControl: Bool,
        capability: LocalReasoningCapability.Capability
    ) -> Bool? {
        if let explicitEnableThinking {
            return explicitEnableThinking
        }
        if let disableThinking = modelOptions["disableThinking"]?.boolValue {
            return !disableThinking
        }
        if let explicitReasoningEffort,
            !explicitReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return nil
        }
        if let optionEffort = modelOptions["reasoningEffort"]?.stringValue,
            !optionEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return nil
        }
        // Tool availability is not a user choice about reasoning. The processor
        // resolves omitted controls from the active bundle/template, including
        // native three-state contracts and models without a separate manifest.
        return nil
    }

    /// Presentation follows explicit choices, then the native template default.
    static func effectiveEnableThinkingForPresentation(
        isAgentOrToolRequest: Bool,
        modelOptions: [String: ModelOptionValue],
        capability: LocalReasoningCapability.Capability
    ) -> Bool {
        defaultEnableThinking(
            isAgentOrToolRequest: isAgentOrToolRequest,
            explicitEnableThinking: nil,
            explicitReasoningEffort: nil,
            modelOptions: modelOptions,
            usesReasoningEffortControl: false,
            capability: capability
        ) ?? capability.defaultThinkingOn
    }
}
