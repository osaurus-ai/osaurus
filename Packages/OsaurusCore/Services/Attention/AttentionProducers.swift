//
//  AttentionProducers.swift
//  osaurus
//
//  Shared helpers for the prompt queues that raise attention items: build an
//  item from the running turn's context, map answers back to each queue's
//  own outcome type, and flip the background task to "waiting" while a
//  person is needed.
//

import Foundation

@MainActor
enum AttentionProducers {
    /// An item stamped with the current run's agent, session, task, turn and
    /// caller (when the run belongs to someone other than the owner).
    static func item(
        id: UUID,
        kind: AttentionKind,
        title: String,
        body: String = "",
        toolName: String? = nil,
        actions: [AttentionAction]? = nil,
        expiresAt: Date? = nil,
        hasInlineCard: Bool = true,
        link: AttentionLink? = nil
    ) -> AttentionItem {
        let agentId = ChatExecutionContext.currentAgentId
        let agent = agentId.flatMap { AgentManager.shared.agent(for: $0) }
        let taskId = ChatExecutionContext.currentBackgroundId ?? ChatExecutionContext.currentTaskId
        // A hidden handoff (the Configurator, say) runs its tools under a
        // session id of its own ("handoff-…", not a chat), so an item it raised
        // named no chat, and an iPhone couldn't show it in the chat that asked.
        // Then the launching chat, bound for the whole turn, is named. A real
        // chat id (a spawned agent's own chat included) is kept as it was.
        let chatSessionId =
            ChatExecutionContext.currentSessionId.flatMap(UUID.init(uuidString:))
            ?? ChatExecutionContext.currentChatSessionBox?.session?.sessionId
        return AttentionItem(
            id: id,
            kind: kind,
            requester: ChatExecutionContext.currentParticipant,
            agent: agent.map { Participant.agent(name: $0.name, address: $0.agentAddress) },
            agentId: agentId,
            sessionId: chatSessionId,
            taskId: taskId,
            turnId: ChatExecutionContext.currentAssistantTurnId,
            title: title,
            body: body,
            toolName: toolName,
            actions: actions,
            expiresAt: expiresAt,
            hasInlineCard: hasInlineCard,
            link: link
        )
    }

    /// The owner answered on this Mac.
    static func inline(_ outcome: AttentionResolution.Outcome, replyText: String? = nil) -> AttentionResolution {
        AttentionResolution(outcome: outcome, surface: .inline, decidedBy: .owner(), replyText: replyText)
    }

    /// The run ended or was cancelled before anyone answered.
    static let abandoned = AttentionResolution(outcome: .abandoned, surface: .system)

    /// A channel message that started work (an agent turn or a workflow).
    /// Informational: the run answers the sender itself.
    static func raiseInboundChannelMessage(_ message: ChannelInboundMessage, agentId: UUID?) {
        let sender = Participant.channelSender(kind: message.identity.kind, sender: message.identity.sender)
        let agent = agentId.flatMap { AgentManager.shared.agent(for: $0) }
        let preview = String(message.content.prefix(240))
        AttentionCenter.shared.raise(
            AttentionItem(
                kind: .inboundMessage,
                requester: sender,
                agent: agent.map { Participant.agent(name: $0.name, address: $0.agentAddress) },
                agentId: agentId,
                title: ParticipantFormatter.short(sender),
                body: preview,
                actions: [.open, .dismiss],
                hasInlineCard: false
            )
        )
    }

    /// Open items per background task, captured when raised: the answer
    /// usually arrives outside the run's task context.
    private static var waiting: [UUID: (backgroundId: UUID, step: String)] = [:]

    /// Marks the running background task as waiting on a person while item
    /// `id` is open. A no-op outside a background run.
    static func beginWaiting(itemId id: UUID, step: String, backgroundId explicit: UUID? = nil) {
        guard let backgroundId = explicit ?? ChatExecutionContext.currentBackgroundId else { return }
        waiting[id] = (backgroundId, step)
        BackgroundTaskManager.shared.setAwaitingApproval(backgroundId, waiting: true, step: step)
    }

    /// A conversation was deleted on this Mac: whatever was waiting in it
    /// ends, its "Allow for This Conversation" grants go, and its caller's
    /// mailbox is dropped.
    static func conversationDeleted(_ sessionId: UUID) {
        let center = AttentionCenter.shared
        for item in center.pending where item.sessionId == sessionId && item.kind.isBlocking {
            center.resolve(id: item.id, with: abandoned)
        }
        center.retractAll(sessionId: sessionId)
        OwnerApprovalService.shared.clearLeases(sessionId: sessionId)
        ConversationMailbox.shared.forget(taskId: sessionId)
        ConversationEventLog.shared.forget(sessionId: sessionId)
    }

    /// Whether any card of this task is still open.
    static func isWaiting(backgroundId: UUID) -> Bool {
        waiting.values.contains { $0.backgroundId == backgroundId }
    }

    /// Item `id` was answered: the task runs again once nothing else of its
    /// is open.
    static func endWaiting(itemId id: UUID) {
        guard let entry = waiting.removeValue(forKey: id) else { return }
        guard !waiting.values.contains(where: { $0.backgroundId == entry.backgroundId }) else { return }
        BackgroundTaskManager.shared.setAwaitingApproval(entry.backgroundId, waiting: false, step: entry.step)
    }
}
