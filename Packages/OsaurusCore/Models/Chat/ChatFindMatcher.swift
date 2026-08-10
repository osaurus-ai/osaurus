//
//  ChatFindMatcher.swift
//  osaurus
//
//  Pure match logic for the in-conversation find bar (Cmd+F). Extracted from
//  ChatView so the invariants — role filtering, case-insensitive matching,
//  per-occurrence navigation, current-match preservation across streaming
//  recomputes, and wraparound navigation — are unit-testable without the
//  view layer.
//

import Foundation

/// A single query occurrence inside a turn's content. `occurrence` is the
/// zero-based index of the occurrence within that turn, counting
/// case-insensitive non-overlapping matches from the top of the content.
struct ChatFindMatch: Equatable, Hashable {
    var turnId: UUID
    var occurrence: Int
}

/// Snapshot of the find bar's match state.
struct ChatFindState: Equatable, Sendable {
    /// Every query occurrence, in conversation order.
    var matches: [ChatFindMatch] = []
    /// Zero-based index of the current match; 0 when there are no matches.
    var matchIndex: Int = 0
}

/// Minimal Sendable projection of a turn, so the match scan can run off the
/// main thread (`ChatTurn` itself is a mutable ObservableObject). Strings
/// are copy-on-write, so snapshotting a conversation is O(turn count), not
/// O(text size).
struct ChatFindTurnSnapshot: Sendable {
    let id: UUID
    let role: MessageRole
    let content: String
}

enum ChatFindMatcher {

    /// Number of case-insensitive, non-overlapping occurrences of `query`
    /// in `text`. Scans over UTF-16 the same way the cell-layer highlighter
    /// does, so model-side occurrence indices line up with painted ranges.
    nonisolated static func occurrenceCount(of query: String, in text: String) -> Int {
        guard !query.isEmpty, !text.isEmpty else { return 0 }
        let string = text as NSString
        var count = 0
        var searchRange = NSRange(location: 0, length: string.length)
        while searchRange.length > 0 {
            let found = string.range(of: query, options: [.caseInsensitive], range: searchRange)
            if found.location == NSNotFound { break }
            count += 1
            let next = found.location + max(found.length, 1)
            if next >= string.length { break }
            searchRange = NSRange(location: next, length: string.length - next)
        }
        return count
    }

    /// Recompute the match list for `query` over `turns`.
    ///
    /// Only user and assistant turns participate; every case-insensitive
    /// occurrence in a turn's content becomes its own match, so navigation
    /// steps through individual occurrences rather than whole messages.
    /// When `preserveCurrentMatch` is true (used when streaming appends
    /// turns mid-search) and the previous current match still exists, the
    /// index follows it instead of resetting; otherwise the index resets to
    /// the first match. `jumpTo` is non-nil only when the caller asked to
    /// jump (`preserveCurrentMatch == false`) and a match exists.
    @MainActor
    static func recompute(
        query: String,
        turns: [ChatTurn],
        previous: ChatFindState,
        preserveCurrentMatch: Bool
    ) -> (state: ChatFindState, jumpTo: ChatFindMatch?) {
        recompute(
            query: query,
            turns: turns.map { ChatFindTurnSnapshot(id: $0.id, role: $0.role, content: $0.content) },
            previous: previous,
            preserveCurrentMatch: preserveCurrentMatch
        )
    }

    /// Off-main-thread recompute: the scan is O(total conversation text)
    /// and must never hang the UI (Sentry app-hang). A detached task (not
    /// a bare `nonisolated async`) guarantees the scan leaves the caller's
    /// actor on every Swift concurrency semantics version.
    nonisolated static func recomputeDetached(
        query: String,
        turns: [ChatFindTurnSnapshot],
        previous: ChatFindState,
        preserveCurrentMatch: Bool
    ) async -> (state: ChatFindState, jumpTo: ChatFindMatch?) {
        await Task.detached(priority: .userInitiated) {
            recompute(
                query: query,
                turns: turns,
                previous: previous,
                preserveCurrentMatch: preserveCurrentMatch
            )
        }.value
    }

    /// Snapshot-based synchronous core; pure and thread-agnostic.
    nonisolated static func recompute(
        query: String,
        turns: [ChatFindTurnSnapshot],
        previous: ChatFindState,
        preserveCurrentMatch: Bool
    ) -> (state: ChatFindState, jumpTo: ChatFindMatch?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (ChatFindState(), nil)
        }
        var matches: [ChatFindMatch] = []
        for turn in turns where turn.role == .user || turn.role == .assistant {
            let count = occurrenceCount(of: trimmed, in: turn.content)
            for occurrence in 0..<count {
                matches.append(ChatFindMatch(turnId: turn.id, occurrence: occurrence))
            }
        }

        let previousCurrent =
            previous.matches.indices.contains(previous.matchIndex)
            ? previous.matches[previous.matchIndex] : nil
        if preserveCurrentMatch, let previousCurrent,
            let index = matches.firstIndex(of: previousCurrent)
        {
            return (ChatFindState(matches: matches, matchIndex: index), nil)
        }
        return (
            ChatFindState(matches: matches, matchIndex: 0),
            preserveCurrentMatch ? nil : matches.first
        )
    }

    /// Step the current match by `delta`, wrapping at both ends. Returns the
    /// unchanged state (and no jump target) when there are no matches.
    static func advance(
        _ state: ChatFindState,
        by delta: Int
    ) -> (state: ChatFindState, jumpTo: ChatFindMatch?) {
        let count = state.matches.count
        guard count > 0 else { return (state, nil) }
        let index = ((state.matchIndex + delta) % count + count) % count
        return (
            ChatFindState(matches: state.matches, matchIndex: index),
            state.matches[index]
        )
    }
}
