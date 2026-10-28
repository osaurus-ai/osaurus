//
//  AnthropicReasoningContract.swift
//  osaurus
//
//  Thinking/effort contract for Claude models on the native Anthropic route,
//  driven by the live Models API `capabilities` object.
//

import Foundation
import os

/// Per-provider Anthropic Models API metadata, keyed by provider id and the
/// bare model id the Messages API expects. Lock-backed so the request builder
/// (off the main actor) and the picker cache read the same snapshot.
enum AnthropicModelCatalog {
    private static let box = OSAllocatedUnfairLock<[UUID: [String: AnthropicModelInfo]]>(initialState: [:])

    static func replace(providerId: UUID, models: [AnthropicModelInfo]) {
        let byId = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        box.withLock { $0[providerId] = byId }
    }

    static func remove(providerId: UUID) {
        box.withLock { _ = $0.removeValue(forKey: providerId) }
    }

    static func removeAll() {
        box.withLock { $0 = [:] }
    }

    static func info(providerId: UUID, modelId: String) -> AnthropicModelInfo? {
        box.withLock { $0[providerId]?[modelId] }
    }

    static func contextLengths(of models: [AnthropicModelInfo]) -> [String: Int] {
        models.reduce(into: [:]) { map, model in
            if let tokens = model.max_input_tokens, tokens > 0 { map[model.id] = tokens }
        }
    }
}

/// Translates the Models API capability contract into the picker's effort
/// levels and the Messages API `thinking` / `output_config.effort` fields.
///
/// Defaults follow Anthropic's recommended client behavior: thinking is
/// turned on (`adaptive`) with readable summaries wherever the model accepts
/// it, and effort is sent only when the user picked one, so the model's own
/// default effort applies otherwise. Models whose capabilities are unknown
/// (proxies that omit them) get no thinking field at all.
enum AnthropicReasoningContract {
    /// The picker level id that turns thinking off.
    static let offLevelId = "none"

    /// Budgets for manual (`enabled`) thinking on models without adaptive
    /// thinking, matching the token scale of the effort levels they stand in for.
    static let manualBudgets: [String: Int] = ["low": 1024, "medium": 8192, "high": 24576]
    private static let manualLevels = ["low", "medium", "high"]
    /// Anthropic's minimum `budget_tokens`.
    static let minimumBudget = 1024

    enum OffMode: Equatable, Sendable {
        /// `thinking: {type: "disabled"}`.
        case disabled
        /// `thinking: {type: "between_tools"}` — the lowest setting on models
        /// that reject `disabled` (Claude Sonnet 5.5).
        case betweenTools
    }

    struct WireControls: Equatable, Sendable {
        var thinking: AnthropicThinkingConfig?
        var effort: String?

        /// Manual thinking rejects forced tool use (`tool_choice` any/tool).
        var isManualThinking: Bool { thinking?.type == "enabled" }
    }

    static func supportsThinking(_ capabilities: AnthropicModelCapabilities) -> Bool {
        capabilities.thinking?.supported == true
    }

    static func supportsAdaptive(_ capabilities: AnthropicModelCapabilities) -> Bool {
        supportsThinking(capabilities) && capabilities.thinking?.types?.adaptive?.isSupported == true
    }

    /// Thinking is available only through `enabled` + `budget_tokens` (the 4.5 generation).
    static func supportsManualOnly(_ capabilities: AnthropicModelCapabilities) -> Bool {
        supportsThinking(capabilities) && !supportsAdaptive(capabilities)
            && capabilities.thinking?.types?.enabled?.isSupported == true
    }

    /// Generations without manual `enabled` thinking also reject `temperature`,
    /// `top_p` and `top_k` (HTTP 400 "… is deprecated for this model") even with
    /// thinking off; generations that keep `enabled` accept them. The Models API
    /// has no sampler capability, so this is the advertised signal that tracks
    /// it. Nil when the capabilities are unknown.
    static func acceptsSamplerKnobs(_ capabilities: AnthropicModelCapabilities?) -> Bool? {
        guard let capabilities, supportsThinking(capabilities) else { return nil }
        return capabilities.thinking?.types?.enabled?.isSupported == true
    }

    static func offMode(_ capabilities: AnthropicModelCapabilities) -> OffMode? {
        guard supportsThinking(capabilities), let types = capabilities.thinking?.types else { return nil }
        if types.disabled?.isSupported == true { return .disabled }
        if types.between_tools?.isSupported == true { return .betweenTools }
        return nil
    }

    /// Picker levels for the model. Adaptive models offer their published
    /// effort ladder (plus Off when thinking can be turned off) with no
    /// default, since the API applies its own. Manual-only models offer Off
    /// (their API default) plus three budget levels.
    static func capabilities(from capabilities: AnthropicModelCapabilities?) -> ModelReasoningCapabilities? {
        guard let capabilities, supportsThinking(capabilities) else { return nil }
        if supportsAdaptive(capabilities) {
            let efforts = capabilities.effort?.supportedLevels ?? []
            guard !efforts.isEmpty else { return nil }
            let levels = (offMode(capabilities) != nil ? [offLevelId] : []) + efforts
            return ModelReasoningCapabilities(
                levels: levels.map { ModelReasoningCapabilities.Level(id: $0) },
                defaultLevelId: nil
            )
        }
        if supportsManualOnly(capabilities) {
            return ModelReasoningCapabilities(
                levels: ([offLevelId] + manualLevels).map { ModelReasoningCapabilities.Level(id: $0) },
                defaultLevelId: offLevelId
            )
        }
        return nil
    }

    /// Wire fields for a request. Nil when nothing should be sent.
    static func wireControls(
        capabilities: AnthropicModelCapabilities?,
        effort: String?,
        maxTokens: Int
    ) -> WireControls? {
        guard let capabilities, supportsThinking(capabilities) else { return nil }
        let effort = effort?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if supportsAdaptive(capabilities) {
            if effort == offLevelId, let mode = offMode(capabilities) {
                switch mode {
                case .disabled: return WireControls(thinking: AnthropicThinkingConfig(type: "disabled"))
                case .betweenTools: return WireControls(thinking: AnthropicThinkingConfig(type: "between_tools"))
                }
            }
            let levels = capabilities.effort?.supportedLevels ?? []
            return WireControls(
                thinking: AnthropicThinkingConfig(type: "adaptive", display: "summarized"),
                effort: effort.flatMap { levels.contains($0) ? $0 : nil }
            )
        }

        if supportsManualOnly(capabilities) {
            guard let effort, let budget = manualBudgets[effort], maxTokens > minimumBudget else { return nil }
            return WireControls(
                thinking: AnthropicThinkingConfig(
                    type: "enabled",
                    budget_tokens: max(minimumBudget, min(budget, maxTokens / 2))
                )
            )
        }
        return nil
    }
}
