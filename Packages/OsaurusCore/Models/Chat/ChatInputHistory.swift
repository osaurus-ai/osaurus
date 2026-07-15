//
//  ChatInputHistory.swift
//  osaurus
//
//  Pure logic for terminal-style input history in the chat composer:
//  Up recalls previously sent messages of the current conversation
//  (newest first), Down walks back toward the in-progress draft.
//  Extracted from the composer so the invariants are unit-testable.
//

import Foundation

/// Snapshot of the composer's history-navigation state.
struct ChatInputHistoryState: Equatable {
    /// Position in the history entries (0 = most recent sent message);
    /// nil when the user is editing their draft, not navigating.
    var index: Int? = nil
    /// The in-progress draft stashed when navigation began, restored when
    /// the user walks Down past the most recent entry.
    var savedDraft: String = ""
}

@MainActor
enum ChatInputHistory {

    /// History entries for a conversation: the user's sent messages, newest
    /// first, blank entries dropped and consecutive duplicates collapsed
    /// (recalling "retry" three times shouldn't take three Up presses to
    /// get past).
    static func entries(from turns: [ChatTurn]) -> [String] {
        var out: [String] = []
        for turn in turns.reversed() where turn.role == .user {
            let content = turn.content
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if out.last == content { continue }
            out.append(content)
        }
        return out
    }

    /// Up arrow: step one entry further into the past. Entering navigation
    /// (index nil → 0) stashes `currentDraft` for later restoration. Returns
    /// nil when there is nothing to recall (no entries, or already at the
    /// oldest entry) — the caller should then let the caret move normally.
    static func recall(
        state: ChatInputHistoryState,
        entries: [String],
        currentDraft: String
    ) -> (state: ChatInputHistoryState, text: String)? {
        guard !entries.isEmpty else { return nil }
        guard let index = state.index else {
            return (
                ChatInputHistoryState(index: 0, savedDraft: currentDraft),
                entries[0]
            )
        }
        let next = index + 1
        guard next < entries.count else { return nil }
        return (
            ChatInputHistoryState(index: next, savedDraft: state.savedDraft),
            entries[next]
        )
    }

    /// Down arrow: step one entry back toward the present. Walking past the
    /// most recent entry leaves navigation and restores the stashed draft.
    /// Returns nil when not navigating — the caller should then let the
    /// caret move normally.
    static func advance(
        state: ChatInputHistoryState,
        entries: [String]
    ) -> (state: ChatInputHistoryState, text: String)? {
        guard let index = state.index else { return nil }
        guard index > 0 else {
            return (ChatInputHistoryState(), state.savedDraft)
        }
        let previous = index - 1
        guard previous < entries.count else {
            // Entries shrank underneath us (e.g. conversation cleared);
            // bail back to the draft rather than indexing out of bounds.
            return (ChatInputHistoryState(), state.savedDraft)
        }
        return (
            ChatInputHistoryState(index: previous, savedDraft: state.savedDraft),
            entries[previous]
        )
    }
}
