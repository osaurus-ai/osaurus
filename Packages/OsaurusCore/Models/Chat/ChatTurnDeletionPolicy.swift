//
//  ChatTurnDeletionPolicy.swift
//  osaurus
//
//  Keeps persisted provider histories valid when a user removes a chat turn.
//

import Foundation

/// Resolves the smallest safe deletion set for a chat turn.
///
/// A user turn owns its following response chain until the next user turn.
/// An assistant turn that issued tool calls owns the matching `.tool` result
/// turns, identified by the provider call id. Removing either side alone
/// creates a history most providers reject on the next request.
enum ChatTurnDeletionPolicy {
    static func removingTurn(id: UUID, from turns: [ChatTurn]) -> [ChatTurn] {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return turns }

        switch turns[index].role {
        case .user:
            let nextUserIndex = turns[(index + 1)...].firstIndex { $0.role == .user } ?? turns.endIndex
            return Array(turns[..<index]) + Array(turns[nextUserIndex...])

        case .assistant:
            let callIDs = Set(turns[index].toolCalls?.map(\.id) ?? [])
            guard !callIDs.isEmpty else {
                var remaining = turns
                remaining.remove(at: index)
                return remaining
            }

            // Tool results belong to the current exchange only. Do not remove a
            // later result that reuses an id in malformed/legacy history.
            let nextUserIndex = turns[(index + 1)...].firstIndex { $0.role == .user } ?? turns.endIndex
            return turns.enumerated().compactMap { offset, turn in
                if offset == index { return nil }
                if offset > index,
                    offset < nextUserIndex,
                    turn.role == .tool,
                    let callID = turn.toolCallId,
                    callIDs.contains(callID)
                {
                    return nil
                }
                return turn
            }

        case .tool, .system:
            var remaining = turns
            remaining.remove(at: index)
            return remaining
        }
    }
}
