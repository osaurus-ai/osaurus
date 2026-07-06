//
//  ChatFindMatcher.swift
//  osaurus
//
//  Pure match logic for the in-conversation find bar (Cmd+F). Extracted from
//  ChatView so the invariants — role filtering, case-insensitive matching,
//  current-match preservation across streaming recomputes, and wraparound
//  navigation — are unit-testable without the view layer.
//

import Foundation

/// Snapshot of the find bar's match state.
struct ChatFindState: Equatable {
    /// Ordered turn ids whose content matches the query.
    var matchTurnIds: [UUID] = []
    /// Zero-based index of the current match; 0 when there are no matches.
    var matchIndex: Int = 0
}

@MainActor
enum ChatFindMatcher {

    /// Recompute the match list for `query` over `turns`.
    ///
    /// Only user and assistant turns participate, matched by case-insensitive
    /// substring over their content. When `preserveCurrentMatch` is true (used
    /// when streaming appends turns mid-search) and the previous current match
    /// still matches, the index follows it instead of resetting; otherwise the
    /// index resets to the first match. `jumpTo` is non-nil only when the
    /// caller asked to jump (`preserveCurrentMatch == false`) and a match
    /// exists.
    static func recompute(
        query: String,
        turns: [ChatTurn],
        previous: ChatFindState,
        preserveCurrentMatch: Bool
    ) -> (state: ChatFindState, jumpTo: UUID?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (ChatFindState(), nil)
        }
        let matches = turns
            .filter { turn in
                (turn.role == .user || turn.role == .assistant)
                    && turn.content.range(of: trimmed, options: [.caseInsensitive]) != nil
            }
            .map(\.id)

        let previousCurrent =
            previous.matchTurnIds.indices.contains(previous.matchIndex)
            ? previous.matchTurnIds[previous.matchIndex] : nil
        if preserveCurrentMatch, let previousCurrent,
            let index = matches.firstIndex(of: previousCurrent)
        {
            return (ChatFindState(matchTurnIds: matches, matchIndex: index), nil)
        }
        return (
            ChatFindState(matchTurnIds: matches, matchIndex: 0),
            preserveCurrentMatch ? nil : matches.first
        )
    }

    /// Step the current match by `delta`, wrapping at both ends. Returns the
    /// unchanged state (and no jump target) when there are no matches.
    static func advance(
        _ state: ChatFindState,
        by delta: Int
    ) -> (state: ChatFindState, jumpTo: UUID?) {
        let count = state.matchTurnIds.count
        guard count > 0 else { return (state, nil) }
        let index = ((state.matchIndex + delta) % count + count) % count
        return (
            ChatFindState(matchTurnIds: state.matchTurnIds, matchIndex: index),
            state.matchTurnIds[index]
        )
    }
}
