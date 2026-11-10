//
//  ChatSession+Attention.swift
//  osaurus
//
//  Mirrors a chat's clarifying question onto the attention channels, so a
//  desktop notification's Reply field or the paired phone can answer it.
//

import Foundation

extension ChatSession {
    func syncClarifyAttention() {
        let center = AttentionCenter.shared
        if let payload = awaitingClarify {
            guard clarifyAttentionId == nil else { return }
            let agent = agentId.flatMap { AgentManager.shared.agent(for: $0) }
            let id = UUID()
            clarifyAttentionId = id
            center.raise(
                AttentionItem(
                    id: id,
                    kind: .clarification,
                    requester: nil,
                    agent: agent.map { Participant.agent(name: $0.name, address: $0.agentAddress) },
                    agentId: agentId,
                    sessionId: sessionId,
                    title: L("\(agent?.name ?? L("Your agent")) has a question"),
                    body: payload.question
                )
            ) { [weak self] resolution in
                guard let self, self.clarifyAttentionId == id else { return }
                self.clarifyAttentionId = nil
                guard resolution.outcome == .replied,
                    let text = resolution.replyText?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !text.isEmpty
                else { return }
                self.promptQueue.drainAll()
                self.send(text)
            }
        } else if let id = clarifyAttentionId {
            clarifyAttentionId = nil
            // Answered here (the next send cleared it), or the chat was reset.
            if !center.resolve(id: id, with: AttentionProducers.inline(.replied)) { center.retract(id: id) }
        }
    }
}
