//
//  ChatSessionWarmup.swift
//  osaurus
//
//  Warm-up payload assembly and model-switch helpers for `ChatSession`.
//

import Foundation

extension ChatSession: ChatWarmupSessionContext {
    func makeWarmupEngine() -> ChatEngineProtocol {
        chatEngineFactory()
    }

    func makeWarmupPayload() async -> ChatWarmupPayload? {
        guard let model = selectedModel, !model.isEmpty else { return nil }
        guard selectedModelIsLocal, !isRemoteAgentTarget else { return nil }
        guard !isImageGenerationModel(model) else { return nil }

        let chatCfg = ChatConfigurationStore.load()
        let effectiveAgentId = agentId ?? Agent.defaultId
        let executionMode = await prepareChatExecutionMode(agentId: effectiveAgentId)

        let liveToolMode = AgentManager.shared.effectiveToolSelectionMode(for: effectiveAgentId)
        let liveFingerprint = SessionToolState.fingerprint(
            executionMode: executionMode,
            toolMode: liveToolMode
        )

        let cachedSession: SessionToolState?
        if let sid = sessionId {
            let key = sid.uuidString
            await SessionToolStateStore.shared.invalidateIfFingerprintChanged(
                key,
                liveFingerprint: liveFingerprint
            )
            cachedSession = await SessionToolStateStore.shared.get(key)
        } else {
            cachedSession = nil
        }

        let priorUserMessages: [ChatMessage] = turns.compactMap { t in
            guard t.role == .user, !t.contentIsEmpty else { return nil }
            return ChatMessage(role: "user", content: t.content)
        }

        let context = await SystemPromptComposer.composeChatContext(
            agentId: effectiveAgentId,
            executionMode: executionMode,
            model: model,
            query: "",
            messages: priorUserMessages,
            toolsDisabled: chatCfg.disableTools,
            additionalToolNames: cachedSession?.loadedToolNames ?? [],
            frozenAlwaysLoadedNames: cachedSession?.initialAlwaysLoadedNames,
            frozenManifest: cachedSession?.frozenManifest,
            frozenSoul: cachedSession?.frozenSoul,
            trace: nil
        )

        var sys = context.prompt

        if let pid = sourcePluginId,
            let pluginInstructions = PluginInstructionsResolver.instructions(
                pluginId: pid,
                agentId: agentId
            )
        {
            sys = sys.isEmpty ? pluginInstructions : sys + "\n\n" + pluginInstructions
        }

        let toolSpecs = context.tools
        let messages = buildWarmupMessages(systemPrompt: sys)

        let historyFingerprint = turns.map { turn in
            "\(turn.role.rawValue):\(turn.id.uuidString):\(turn.content.count)"
        }.joined(separator: "|")

        // Options like the Thinking toggle change the rendered prompt and
        // the runtime cache salt, so they're part of the warm identity.
        let optionsFingerprint = activeModelOptions
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: ",")

        let fingerprint = "\(model)|\(context.cacheHint)|\(optionsFingerprint)|\(historyFingerprint)"

        return ChatWarmupPayload(
            model: model,
            messages: messages,
            tools: toolSpecs.isEmpty ? nil : toolSpecs,
            modelOptions: activeModelOptions.isEmpty ? nil : activeModelOptions,
            fingerprint: fingerprint
        )
    }

    private func buildWarmupMessages(systemPrompt: String) -> [ChatMessage] {
        var msgs: [ChatMessage] = []
        if !systemPrompt.isEmpty {
            msgs.append(ChatMessage(role: "system", content: systemPrompt))
        }

        for (index, turn) in turns.enumerated() {
            let isLastTurn = index == turns.count - 1
            if let msg = warmupTurnToMessage(turn, isLastTurn: isLastTurn) {
                msgs.append(msg)
            }
        }
        return msgs
    }

    private func warmupTurnToMessage(_ turn: ChatTurn, isLastTurn: Bool) -> ChatMessage? {
        switch turn.role {
        case .assistant:
            if isLastTurn && turn.contentIsBlank && turn.thinkingIsBlank && turn.toolCalls == nil {
                return nil
            }
            if turn.contentIsBlank && turn.thinkingIsBlank && (turn.toolCalls == nil || turn.toolCalls!.isEmpty) {
                return nil
            }
            let content: String? = turn.contentIsBlank ? nil : turn.content
            let reasoning: String? = turn.thinkingIsBlank ? nil : turn.thinking
            return ChatMessage(
                role: "assistant",
                content: content,
                tool_calls: turn.toolCalls,
                tool_call_id: nil,
                reasoning_content: reasoning,
                reasoning_item_id: turn.reasoningItemId,
                reasoning_encrypted: turn.reasoningEncrypted
            )
        case .tool:
            return ChatMessage(
                role: "tool",
                content: turn.content,
                tool_calls: nil,
                tool_call_id: turn.toolCallId
            )
        case .user:
            let base = Self.buildUserChatMessage(
                content: turn.content,
                attachments: turn.attachments,
                supportsImages: selectedModelSupportsImages,
                supportsAudio: selectedModelSupportsAudio,
                supportsVideo: selectedModelSupportsVideo
            )
            return Self.applyingFrozenInjectedPrefix(turn.injectedContextPrefix, to: base)
        default:
            return ChatMessage(role: turn.role.rawValue, content: turn.content)
        }
    }

    /// Apply the residency side of a model switch: evict models no chat
    /// window still points at (strict single-model only), then — when the
    /// warm-up feature is off — plain-preload the new local model so switch
    /// still hides the load cost. With warm-up on, the follow-up warm-up
    /// generation loads the container itself.
    ///
    /// Eviction runs even when the new selection is remote/Foundation: the
    /// previous local model should not stay resident just because the user
    /// moved off local models entirely.
    func performModelResidencySwitch(evictOthers: Bool) async {
        if evictOthers {
            let active = ChatWindowManager.shared.activeLocalModelNames()
            await ModelRuntime.shared.unloadModelsNotIn(active)
        }

        guard !ChatConfigurationStore.load().warmModelsOnLoad else { return }
        guard let model = selectedModel, !model.isEmpty, selectedModelIsLocal else { return }
        // Same RAM gate as the warm-up path: a switch-triggered preload is
        // Osaurus-initiated background work and must not force a load whose
        // projection exceeds the hard RAM ceiling — that's a fatal Metal OOM
        // on machines where the selected model can't fit. The send path
        // surfaces the block to the user via the input card's banner.
        if let feasibility = await ModelRuntime.shared.projectedLoadFeasibility(for: model),
            feasibility.loadPressureSeverity == .block
        {
            return
        }
        try? await ModelRuntime.shared.preload(name: model)
    }

    func notifySessionBecameActive() {
        warmupController.scheduleWarmup(session: self)
    }

    func handleWarmupAfterRunCompleted() {
        warmupController.scheduleWarmup(session: self)
    }

    func invalidateWarmupAfterContextShapeChange() {
        warmupController.invalidateWarmState()
        warmupController.scheduleWarmup(session: self)
    }
}
