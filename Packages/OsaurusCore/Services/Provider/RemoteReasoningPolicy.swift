//
//  RemoteReasoningPolicy.swift
//  osaurus
//
//  Single source of truth for how a remote OpenAI-compatible provider exchanges
//  reasoning: how it arrives in the stream (inbound), how it must be echoed back
//  in multi-turn history (outbound), and the request-side reasoning controls.
//

import Foundation

/// Per-request resolved reasoning policy for a remote provider.
///
/// Named `Policy` rather than `Profile` to avoid confusion with the
/// model-id-matching `*ReasoningProfile` types (e.g. `DSV4ReasoningProfile`)
/// that it consults internally.
///
/// Provider-specific quirks live here as cohesive cases instead of being
/// scattered across `RemoteProviderService` as loose `static` switches; the
/// service's existing helpers delegate to this type so call sites and pinned
/// tests keep working unchanged.
struct RemoteReasoningPolicy {
    /// How reasoning arrives in the streamed response.
    enum Inbound {
        /// Provider streams reasoning on a dedicated `delta.reasoning_content`
        /// field (DeepSeek, Qwen, Together, vLLM).
        case separateField
        /// Provider inlines reasoning as `<think>...</think>` inside `content`
        /// (MiniMax M-series). Requires the `InlineThinkSplitter` on the content
        /// rail so the tags don't leak into the visible message.
        case inlineThink
    }

    /// How prior-turn reasoning must be re-sent in multi-turn history.
    enum Outbound {
        /// Drop `reasoning_content` before sending (default — avoids
        /// unknown-field rejections on strict schemas).
        case strip
        /// Keep `reasoning_content` on the wire (DeepSeek needs it to preserve
        /// the prompt-template `<think>` block and its KV cache — issue #959).
        case echoField
        /// Fold `reasoning_content` back into `content` as a `<think>` block
        /// (MiniMax's documented native history format).
        case embedAsThink
    }

    let inbound: Inbound
    let outbound: Outbound
    let providerType: RemoteProviderType
    let host: String
    let model: String

    // MARK: - Resolution

    static func resolve(
        providerType: RemoteProviderType,
        host: String,
        model: String
    ) -> RemoteReasoningPolicy {
        let (inbound, outbound) = behavior(providerType: providerType, host: host, model: model)
        return RemoteReasoningPolicy(
            inbound: inbound,
            outbound: outbound,
            providerType: providerType,
            host: host,
            model: model
        )
    }

    private static func behavior(
        providerType: RemoteProviderType,
        host: String,
        model: String
    ) -> (Inbound, Outbound) {
        switch providerType {
        case .openaiLegacy, .azureOpenAI:
            // MiniMax M-series inlines reasoning as <think> in `content` and
            // leaves `reasoning_content` empty; match by host or model id so the
            // hosted API (api.minimax.io) and aggregators (AtlasCloud's
            // `minimaxai/*`) both resolve correctly.
            if matches(needle: "minimax", host: host, model: model) {
                return (.inlineThink, .embedAsThink)
            }
            // DeepSeek-family streams `reasoning_content` and needs it echoed.
            if matches(needle: "deepseek", host: host, model: model) {
                return (.separateField, .echoField)
            }
            return (.separateField, .strip)
        case .anthropic, .openResponses, .openAICodex, .gemini, .osaurus, .osaurusRouter:
            return (.separateField, .strip)
        }
    }

    private static func matches(needle: String, host: String, model: String) -> Bool {
        host.range(of: needle, options: .caseInsensitive) != nil
            || model.range(of: needle, options: .caseInsensitive) != nil
    }

    // MARK: - Outbound history transform

    /// Apply the outbound reasoning transform to assistant history messages.
    func transformOutbound(_ messages: [ChatMessage]) -> [ChatMessage] {
        switch outbound {
        case .echoField:
            return messages
        case .strip:
            return Self.strippingReasoning(messages)
        case .embedAsThink:
            return Self.embeddingReasoningAsThink(messages)
        }
    }

    /// Returns a copy of `messages` with `reasoning_content` cleared. Unchanged
    /// messages are returned as-is to avoid needless allocations.
    static func strippingReasoning(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.map { msg in
            guard msg.reasoning_content != nil else { return msg }
            return ChatMessage(
                role: msg.role,
                content: msg.content,
                tool_calls: msg.tool_calls,
                tool_call_id: msg.tool_call_id,
                reasoning_content: nil,
                reasoning_item_id: msg.reasoning_item_id,
                reasoning_encrypted: msg.reasoning_encrypted
            )
        }
    }

    /// Returns a copy of `messages` with any `reasoning_content` folded into the
    /// message `content` as a leading `<think>...</think>` block and the
    /// `reasoning_content` field cleared. MiniMax's native OpenAI-compatible
    /// format expects the prior turn's think block preserved inside `content`.
    static func embeddingReasoningAsThink(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.map { msg in
            guard let reasoning = msg.reasoning_content else { return msg }
            let base = msg.content ?? ""
            let folded =
                reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (base.isEmpty ? nil : base)
                : "<think>\n\(reasoning)\n</think>\n\(base)"
            return ChatMessage(
                role: msg.role,
                content: folded,
                tool_calls: msg.tool_calls,
                tool_call_id: msg.tool_call_id,
                reasoning_content: nil,
                reasoning_item_id: msg.reasoning_item_id,
                reasoning_encrypted: msg.reasoning_encrypted
            )
        }
    }

    // MARK: - Request-side reasoning controls

    /// Whether a `reasoning: { effort }` object may be sent alongside
    /// `reasoning_effort` on the chat-completions request.
    var allowsReasoningObject: Bool {
        switch providerType {
        case .openaiLegacy:
            let lowered = host.lowercased()
            // Mistral's chat-completions schema accepts only the root-level
            // `reasoning_effort` string; a sibling `reasoning: { effort }`
            // object is rejected with HTTP 422 (`extra_forbidden`). OpenAI
            // proper likewise only reads `reasoning_effort` here.
            return !lowered.contains("openai.com") && !lowered.contains("mistral")
        case .azureOpenAI, .anthropic, .openResponses, .openAICodex, .gemini, .osaurus, .osaurusRouter:
            return false
        }
    }

    /// Translate a local reasoning-effort value into the on-the-wire
    /// `reasoning_effort` + `thinking` fields the target provider understands.
    func controls(effort: String?) -> (effort: String?, thinking: ThinkingConfig?) {
        let translated = Self.dsv4Effort(host: host, model: model, effort: effort)
        let accepted = Self.acceptedEffort(
            providerType: providerType,
            host: host,
            effort: translated.effort
        )
        return (accepted, translated.thinking)
    }

    /// Filter a reasoning-effort value to what the provider accepts on the
    /// chat-completions request. DeepSeek only accepts a fixed alias set.
    static func acceptedEffort(
        providerType: RemoteProviderType,
        host: String,
        effort: String?
    ) -> String? {
        guard
            let effort = effort?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !effort.isEmpty
        else {
            return nil
        }

        switch providerType {
        case .openaiLegacy, .azureOpenAI:
            if host.lowercased().contains("deepseek") {
                let acceptedDeepSeekEfforts: Set<String> = ["low", "medium", "high", "max", "xhigh"]
                return acceptedDeepSeekEfforts.contains(effort) ? effort : nil
            }
            return effort
        case .anthropic, .openResponses, .openAICodex, .gemini, .osaurus, .osaurusRouter:
            return effort
        }
    }

    /// Translate the local DSV4 `reasoningEffort` value into the wire fields.
    ///
    /// `DSV4ReasoningProfile` exposes `instruct` / `high` / `max`, but DeepSeek's
    /// public chat API only accepts `high`/`max` (plus `low`/`medium`/`xhigh`
    /// aliases) and toggles reasoning via a separate `thinking` object. Direct/off
    /// aliases (`instruct`, `no_think`, `none`, ...) are internal local-runtime
    /// controls, not portable wire values — stripped for every remote model; DSV4
    /// on a DeepSeek host additionally gets the `thinking.disabled` object.
    static func dsv4Effort(
        host: String,
        model: String,
        effort: String?
    ) -> (effort: String?, thinking: ThinkingConfig?) {
        guard
            let normalized = effort?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(), !normalized.isEmpty
        else {
            return (nil, nil)
        }
        // Mistral's public API genuinely accepts `reasoning_effort: "none"` as a
        // wire value (unlike DSV4's `instruct`/`no_think`/etc., which are local-
        // only runtime aliases every other remote schema rejects) — exempt it
        // before the generic direct-rail stripping below.
        guard !host.lowercased().contains("mistral") else {
            return (normalized, nil)
        }

        let isDirectRailEffort: Bool
        switch normalized {
        case "instruct", "chat", "none", "no_think", "nothink", "off", "disabled", "false":
            isDirectRailEffort = true
        default:
            isDirectRailEffort = false
        }
        guard isDirectRailEffort else { return (normalized, nil) }
        let thinking =
            host.lowercased().contains("deepseek")
                && DSV4ReasoningProfile.matches(modelId: model)
            ? ThinkingConfig(type: "disabled") : nil
        return (nil, thinking)
    }
}
