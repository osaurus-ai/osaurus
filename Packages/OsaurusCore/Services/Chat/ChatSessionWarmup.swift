//
//  ChatSessionWarmup.swift
//  osaurus
//
//  `ChatSession`'s hooks into the residency observer, plus the pure renderers
//  of the session's committed history. Chat model loading is lazy: nothing
//  here loads, evicts or prefills a model — the first Send does that through
//  the ordinary request path (`ModelRuntime.loadContainer` on demand, with
//  the runtime's own residency policy at load time).
//

import Foundation

extension ChatSession: ChatWarmupSessionContext {
    /// Window focus / background work finished: refresh the residency-backed
    /// chip dot from the runtime. No load is scheduled.
    func notifySessionBecameActive() {
        warmupController.handleSessionBecameActive(session: self)
    }

    /// A prompt-shape change (tools, agent, system prompt, model options)
    /// drops any warm claim. The next Send renders the authoritative prompt.
    func invalidateWarmupAfterContextShapeChange() {
        warmupController.handleContextShapeChange(session: self)
    }

    // MARK: - Model-visible history rendering
    // Pure renderers of the committed history in the exact shape a real send
    // uses (compaction and tests reuse them). They build messages only.


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

    /// The transcript a warm-up may safely prefill: every turn EXCEPT
    /// trailing user turns that have not been dispatched yet. A pending turn
    /// (pre-appended by `send()` so the message is visible during the DSV4
    /// pre-send handshake) gets its injected context prefix — the
    /// `[Current Time]` block, memory, screen context — frozen only at
    /// dispatch, so its final wire bytes do not exist yet. Warming it
    /// prefills bytes the real request never composes: observed live as a
    /// third prefill per Send whose tokens past the static prefix could
    /// never be reused. Dropping it keeps the warm transcript a strict
    /// byte-prefix of the real request.
    var warmupCommittedTurns: [ChatTurn] {
        var eligible = turns
        while let last = eligible.last, last.role == .user, last.injectedContextPrefix == nil {
            eligible.removeLast()
        }
        return eligible
    }

    func buildWarmupMessages(
        systemPrompt: String,
        turnsToWarm: [ChatTurn]? = nil
    ) -> [ChatMessage] {
        let warmable = turnsToWarm ?? warmupCommittedTurns
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

        for turn in warmable {
            if let summary, coveredIds.contains(turn.id) {
                if !summaryInjected {
                    msgs.append(ChatMessage(role: "user", content: summary.contextMessageText))
                    summaryInjected = true
                }
                continue
            }
            // Last-turn position is judged against the FULL transcript, not
            // the warmable slice: when a pending user turn was dropped above,
            // the real request renders the final assistant turn as a
            // non-last message, and the warm bytes must match that.
            let isLastTurn = turn.id == turns.last?.id
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
}
