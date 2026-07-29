//
//  AgentReasoningPolicy.swift
//  osaurus
//
//  Resolves the one agent-specific reasoning default Osaurus owns. Ordinary
//  chat leaves an omitted thinking control to the model bundle. Agent/tool
//  runs instead choose the direct rail for locally detected toggleable
//  templates, unless the user or API explicitly chose a mode.
//

import Foundation

enum AgentReasoningPolicy {
    /// Return the thinking override an agent/tool request should add, or nil
    /// when the caller/model contract must remain untouched.
    ///
    /// Precedence is deliberate:
    /// 1. The wire-safe API toggle is an explicit user/client choice.
    /// 2. The canonical local model option is the same choice before encoding.
    /// 3. A reasoning-effort control owns the model's reasoning rail.
    /// 4. Only a truly unspecified agent/tool run receives the direct default.
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
        // A segmented reasoning-effort rail (DSV4 instruct/reasoning/max,
        // Hy3, and similar profiles) owns its own default semantics even when
        // the underlying template also happens to accept `enable_thinking`.
        // Never collapse that richer contract into the generic boolean rail.
        guard !usesReasoningEffortControl else { return nil }
        guard isAgentOrToolRequest, capability.isToggleableThinking else {
            return nil
        }
        return false
    }

    /// Resolve the state the UI should present for a toggleable local model.
    /// This deliberately reuses the dispatch policy so an untouched agent
    /// composer cannot claim the bundle default is active while dispatch will
    /// select the direct rail. Explicit choices still win; ordinary no-tool
    /// chat falls back to the bundle's own template default.
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
