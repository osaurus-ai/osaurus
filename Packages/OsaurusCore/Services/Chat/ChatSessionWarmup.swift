//
//  ChatSessionWarmup.swift
//  osaurus
//
//  Warm-up payload assembly and model-switch helpers for `ChatSession`.
//

import Foundation

extension ChatSession: ChatWarmupSessionContext {
    func makeWarmupEngine() -> ChatEngineProtocol {
        chatEngineFactory(source.inferenceSource)
    }

    func makeWarmupPayload() async -> ChatWarmupPayload? {
        guard let model = selectedModel, !model.isEmpty else { return nil }
        guard selectedModelIsLocal, !isRemoteAgentTarget else { return nil }
        guard !isImageGenerationModel(model) else { return nil }

        let chatCfg = ChatConfigurationStore.load()
        let effectiveAgentId = agentId ?? Agent.defaultId
        let executionMode = await prepareChatExecutionMode(agentId: effectiveAgentId)

        // The plugin catalog is part of the static system/tool prefix. Wait
        // for its one-time launch snapshot before warming, otherwise the same
        // installed plugins can render a different prefix across process
        // restarts and bypass an otherwise valid disk-L2 cache entry.
        await PluginManager.shared.ensurePromptCatalogReady()

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
            modelType: selectedPickerItem?.modelType,
            query: "",
            messages: priorUserMessages,
            toolsDisabled: chatCfg.disableTools,
            additionalToolNames: cachedSession?.loadedToolNames ?? [],
            frozenAlwaysLoadedNames: cachedSession?.initialAlwaysLoadedNames,
            frozenToolSpecs: cachedSession?.initialToolSpecs,
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

        // LLM context compaction replaces the covered turns with one summary
        // message in the composed bytes WITHOUT changing `turns`, so the
        // summary must be part of the warm identity. Otherwise a pre-compaction
        // warm-up keeps claiming a hot prefix for bytes the post-compaction
        // send no longer composes (and vice versa when a summary is
        // invalidated), and the send cold-re-prefills everything past the
        // static system prefix.
        let summaryFingerprint =
            activeWarmupSummary.map { "\($0.id.uuidString):\($0.coveredTurnIds.count)" } ?? "none"

        // Options like the Thinking toggle change the rendered prompt and
        // the runtime cache salt, so they're part of the warm identity.
        let optionsFingerprint = activeModelOptions
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: ",")

        // Hash of the FULL rendered system prompt (static + dynamic sections
        // + plugin instructions), not just `cacheHint`. `cacheHint` covers
        // only the static prefix and tool schemas, so an edit that rewrites a
        // dynamic section — a channel-destination mode change, an agent DB
        // schema change, a sandbox-state flip — left the old fingerprint
        // intact and the controller kept claiming a warm prefix for bytes
        // the next send would no longer compose. The send then diverged
        // inside the system message and cold-re-prefilled the entire
        // conversation. Folding the rendered bytes in makes such edits
        // re-warm with the current prompt instead.
        let promptFingerprint = PromptSurfaceEvaluator.fnv1a(sys)

        let fingerprint =
            "\(model)|\(context.cacheHint)|\(promptFingerprint)|\(optionsFingerprint)|\(summaryFingerprint)|\(historyFingerprint)"

        return ChatWarmupPayload(
            model: model,
            messages: messages,
            tools: toolSpecs.isEmpty ? nil : toolSpecs,
            modelOptions: activeModelOptions.isEmpty ? nil : activeModelOptions,
            cacheStableSystemPrefix: context.staticPrefix,
            fingerprint: fingerprint
        )
    }

    /// The compaction summary the next send will inject, or nil when there is
    /// none / it no longer lines up with the transcript. Same validity rule as
    /// the send path (`validateConversationSummary` runs at the top of every
    /// send), applied inline because warm-up composes at arbitrary times.
    var activeWarmupSummary: ConversationSummary? {
        guard let summary = conversationSummary,
            ContextCompactionService.summaryIsValid(summary, for: turns)
        else { return nil }
        return summary
    }

    func buildWarmupMessages(systemPrompt: String) -> [ChatMessage] {
        var msgs: [ChatMessage] = []
        if !systemPrompt.isEmpty {
            msgs.append(ChatMessage(role: "system", content: systemPrompt))
        }

        // Mirror the send path's non-destructive LLM compaction (see
        // `buildMessages` in the send loop): covered turns are replaced by ONE
        // byte-stable summary message. Warm-up must serialize the identical
        // shape, or the prefill it stores (memory + disk L2) diverges from the
        // real send right after the system prompt and the warm work is wasted.
        let summary = activeWarmupSummary
        let coveredIds = summary.map { Set($0.coveredTurnIds) } ?? []
        var summaryInjected = false

        for (index, turn) in turns.enumerated() {
            if let summary, coveredIds.contains(turn.id) {
                if !summaryInjected {
                    msgs.append(ChatMessage(role: "user", content: summary.contextMessageText))
                    summaryInjected = true
                }
                continue
            }
            let isLastTurn = index == turns.count - 1
            if let msg = warmupTurnToMessage(turn, isLastTurn: isLastTurn) {
                msgs.append(msg)
            }
        }
        return msgs
    }

    func warmupTurnToMessage(_ turn: ChatTurn, isLastTurn: Bool) -> ChatMessage? {
        switch turn.role {
        case .assistant:
            // Warm-up and the real request must serialize one identical
            // transcript. In particular, a reasoning-only attempt abandoned
            // by the bounded retry remains visible in the UI but carries
            // `modelContextExcluded`; warming it would prefill poisoned
            // history that the next real send correctly omits.
            return Self.modelVisibleAssistantMessage(turn, isLastTurn: isLastTurn)
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
        // The GC below is an explicit unload, not a load, so the runtime's
        // load-intent refusal can't cover it — but the decision still has to be
        // made *inside* the actor. `skipIfLoadInFlight` does that: a model that
        // is mid-load is in `loadingTasks`, not `modelCache`, and holds no lease,
        // so it is invisible to both the window snapshot and the lease check, and
        // a sweep would tear the runtime down around it. That is the 94 GB HY3
        // load we watched die to a stale-selection warm-up.
        if evictOthers {
            let active = ChatWindowManager.shared.activeLocalModelNames()
            await ModelRuntime.shared.unloadModelsNotIn(active, skipIfLoadInFlight: true)
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
        // Speculative: it only exists to hide the load cost of a selection the
        // user has not sent to yet. It must never be the reason someone else's
        // model gets evicted, so it declines rather than disturb residency.
        try? await ModelRuntime.shared.preload(name: model, intent: .background)
    }

    func notifySessionBecameActive() {
        warmupController.handleSessionBecameActive(session: self)
    }

    func handleWarmupAfterRunCompleted(wasCancelled: Bool, hadError: Bool) {
        let hadToolActivity = turns.contains { turn in
            turn.role == .tool
                || !(turn.toolCalls?.isEmpty ?? true)
                || !turn.toolResults.isEmpty
                || turn.hasRemoteToolActivity
        }
        warmupController.handleRunCompleted(
            session: self,
            wasCancelled: wasCancelled,
            hadError: hadError,
            hadToolActivity: hadToolActivity
        )
    }

    func invalidateWarmupAfterContextShapeChange() {
        warmupController.handleContextShapeChange(session: self)
    }
}
