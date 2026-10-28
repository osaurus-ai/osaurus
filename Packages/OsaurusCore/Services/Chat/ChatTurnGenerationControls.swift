//
//  ChatTurnGenerationControls.swift
//  osaurus
//
//  Freezes prompt-affecting UI model controls for one logical chat turn.
//  Agent loops rebuild ChatCompletionRequest for every model step, so the
//  explicit Thinking choice must be copied to every reconstruction in both
//  its local runtime representation (`modelOptions`) and its wire-safe API
//  representation (`enable_thinking`).
//

import Foundation

struct ChatTurnGenerationControls: Sendable, Equatable, Codable {
    let modelOptions: [String: ModelOptionValue]?
    let enableThinking: Bool?
    var overrides = ChatTurnOverrides()
    /// Defaults are captured once before asynchronous dispatch, not on retries.
    var temperature: Float? = nil
    var topP: Float? = nil
    var topK: Int? = nil
    /// Agent defaults are frozen with the turn, including an intentionally absent cap.
    var agentSettings: AgentGenerationSettings? = nil
    var maxOutputTokens: Int? = nil
    var agentDefaultsCaptured: Bool? = nil
    var hasResolvedReasoning = false
    var storedExplicitOptions: [String: ModelOptionValue]? = nil

    var reasoningEffort: String? {
        overrides.reasoningEffort ?? agentSettings?.reasoningEffort ?? modelOptions?["reasoningEffort"]?.stringValue
    }

    /// A steer shares the active logical run's requests. Never consume a
    /// submission whose captured defaults need a different generation request.
    /// Ignore only the transient cold-capability-resolution bookkeeping.
    func matchesForSteering(_ active: ChatTurnGenerationControls) -> Bool {
        var pending = self
        var active = active
        pending.hasResolvedReasoning = false
        active.hasResolvedReasoning = false
        // Compare serialized prompt values byte-for-byte: Swift String equality
        // considers NFC/NFD equivalent, but a tokenizer need not do so. Sorted
        // keys make dictionary insertion order irrelevant without normalizing text.
        let encoder = JSONEncoder.osaurusCanonical(prettyPrinted: false)
        guard let pendingBytes = try? encoder.encode(pending),
            let activeBytes = try? encoder.encode(active)
        else { return false }
        return pendingBytes == activeBytes
    }

    static func capture(
        activeModelOptions: [String: ModelOptionValue]
    ) -> ChatTurnGenerationControls {
        let options = activeModelOptions.isEmpty ? nil : activeModelOptions

        // Only an explicit toggle becomes an API override. An absent value
        // remains nil so the bundle's chat-template default still owns fresh
        // models. `disableThinking` is the canonical stored option for every
        // current Thinking profile, including dynamically discovered local
        // profiles such as Ornith. Translate it directly instead of resolving
        // the model profile again on the send path; dynamic profile discovery
        // can touch the local model catalog and must not add synchronous TTFT.
        let enableThinking = options?["disableThinking"]?.boolValue.map { !$0 }

        return ChatTurnGenerationControls(
            modelOptions: options,
            enableThinking: enableThinking
        )
    }

    /// Recover persisted explicit Thinking/effort choices when launch-time UI
    /// normalization raced the cold local-model capability cache. The caller
    /// supplies the already-read versioned payload and the off-main resolver,
    /// keeping this policy deterministic in tests. Unrelated model options
    /// and already-live reasoning choices do not wait for discovery.
    static func captureForSend(
        modelId: String?,
        activeModelOptions: [String: ModelOptionValue],
        storedExplicitOptions: [String: ModelOptionValue]?,
        resolveCapability: @Sendable (String) async -> Void
    ) async -> ChatTurnGenerationControls {
        guard activeModelOptions["disableThinking"] == nil,
            activeModelOptions["reasoningEffort"] == nil,
            let modelId,
            let storedExplicitOptions,
            storedExplicitOptions["disableThinking"]?.boolValue != nil
                || storedExplicitOptions["reasoningEffort"]?.stringValue != nil
        else {
            return capture(activeModelOptions: activeModelOptions)
        }

        await resolveCapability(modelId)
        let validated = ModelProfileRegistry.normalizedOptions(
            for: modelId,
            persisted: storedExplicitOptions
        )
        var merged = activeModelOptions
        for key in ["disableThinking", "reasoningEffort"] {
            if let recovered = validated[key] { merged[key] = recovered }
        }
        return capture(activeModelOptions: merged)
    }

    func apply(to request: inout ChatCompletionRequest) {
        request.modelOptions = modelOptions
        request.enable_thinking = agentSettings?.enableThinking ?? enableThinking
        request.reasoning_effort = reasoningEffort
        request.temperature = overrides.temperature ?? temperature
        request.top_p = overrides.topP ?? agentSettings?.topP ?? topP
        request.top_k = overrides.topK ?? agentSettings?.topK ?? topK
        if let value = agentSettings?.minP { request.min_p = value }
        if let value = agentSettings?.repetitionPenalty { request.repetition_penalty = value }
        if let value = agentSettings?.frequencyPenalty { request.frequency_penalty = value }
        if let value = agentSettings?.presencePenalty { request.presence_penalty = value }
        if let value = agentSettings?.seed { request.seed = value }
        if let value = agentSettings?.stop { request.stop = value }
        if let enabled = overrides.enableThinking { request.enable_thinking = enabled }
        request.chat_template_kwargs = overrides.templateKwargs ?? agentSettings?.templateKwargs
        request.inferenceContext.agentReasoningDefaults = AgentReasoningDefaults(settings: agentSettings, overrides: overrides)
    }

    func apply(to request: inout ResponsesInferenceRequest) {
        // Explicit empty freezes absence and prevents the engine from re-reading
        // model-scoped UI preferences on a later tool step.
        request.context.modelOptions = modelOptions ?? [:]
        request.generation.temperature = temperature
        request.generation.topP = topP
        request.generation.topK = topK
        request.generation.enableThinking = enableThinking
        request.generation.reasoningEffort = reasoningEffort
        agentSettings?.apply(to: &request.generation)
        overrides.apply(to: &request)
        request.context.agentReasoningDefaults = AgentReasoningDefaults(settings: agentSettings, overrides: overrides)
    }
}

extension AgentGenerationSettings {
    /// Apply only explicit agent values; absent fields preserve the caller's defaults.
    func apply(to generation: inout ResponsesGenerationOptions) {
        if let topP { generation.topP = topP }
        if let topK { generation.topK = topK }
        if let minP { generation.minP = minP }
        if let repetitionPenalty { generation.repetitionPenalty = repetitionPenalty }
        if let frequencyPenalty { generation.frequencyPenalty = frequencyPenalty }
        if let presencePenalty { generation.presencePenalty = presencePenalty }
        if let seed { generation.seed = seed }
        if let stop { generation.stop = stop }
        if let enableThinking { generation.enableThinking = enableThinking }
        if let reasoningEffort { generation.reasoningEffort = reasoningEffort }
        if let templateKwargs { generation.templateKwargs = templateKwargs }
    }
}
