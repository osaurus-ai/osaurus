//
//  WaitingOnOthers.swift
//  osaurus
//
//  The caller's side of an owner approval: your chat with someone else's
//  shared agent is paused while its owner decides on a tool call. Fed by the
//  `osaurus_owner_approval` stream hint and listed in Inbox → Waiting on
//  Others, so a paused chat is findable without opening every tab.
//

import Foundation

@MainActor
final class WaitingOnOthers: ObservableObject {
    static let shared = WaitingOnOthers()

    struct Item: Identifiable, Equatable {
        /// The host's approval id.
        let id: String
        let sessionId: UUID?
        let agentAddress: String?
        let agentName: String
        /// The owner's label as the host sent it (`@alice`).
        let owner: String
        let tool: String
        let since: Date
    }

    @Published private(set) var items: [Item] = []

    /// One stream hint: `waiting` adds or refreshes the row, anything else
    /// (approved, declined, timed out) removes it.
    func note(
        approvalId: String,
        phase: String,
        sessionId: UUID?,
        agentAddress: String?,
        agentName: String,
        owner: String,
        tool: String,
        now: Date = Date()
    ) {
        guard phase == "waiting" else {
            items.removeAll { $0.id == approvalId }
            return
        }
        let since = items.first { $0.id == approvalId }?.since ?? now
        let item = Item(
            id: approvalId,
            sessionId: sessionId,
            agentAddress: agentAddress,
            agentName: agentName,
            owner: owner,
            tool: tool,
            since: since
        )
        if let index = items.firstIndex(where: { $0.id == approvalId }) {
            items[index] = item
        } else {
            items.append(item)
        }
    }

    /// The chat's run ended (finished, stopped, or failed): nothing it was
    /// waiting on can still answer it.
    func clear(sessionId: UUID?) {
        guard let sessionId else { return }
        items.removeAll { $0.sessionId == sessionId }
    }

    func _resetForTesting() { items = [] }
}
