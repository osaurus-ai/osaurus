//
//  ChatFindMatcherTests.swift
//  osaurusTests
//
//  Pins the in-conversation find bar's match logic: role filtering,
//  case-insensitive matching, current-match preservation across streaming
//  recomputes, and wraparound navigation.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ChatFindMatcherTests {

    private func makeTurns() -> [ChatTurn] {
        [
            ChatTurn(role: .user, content: "how do I configure the notch?"),
            ChatTurn(role: .assistant, content: "The notch overlay lives in settings."),
            ChatTurn(role: .user, content: "thanks!"),
            ChatTurn(role: .assistant, content: "You can also move the NOTCH per display."),
        ]
    }

    @Test func matchesUserAndAssistantTurnsCaseInsensitively() {
        let turns = makeTurns()
        let (state, jumpTo) = ChatFindMatcher.recompute(
            query: "notch",
            turns: turns,
            previous: ChatFindState(),
            preserveCurrentMatch: false
        )
        #expect(state.matchTurnIds == [turns[0].id, turns[1].id, turns[3].id])
        #expect(state.matchIndex == 0)
        #expect(jumpTo == turns[0].id)
    }

    @Test func ignoresNonConversationRoles() {
        let turns = [
            ChatTurn(role: .system, content: "notch instructions"),
            ChatTurn(role: .tool, content: "notch tool output"),
            ChatTurn(role: .user, content: "notch question"),
        ]
        let (state, _) = ChatFindMatcher.recompute(
            query: "notch",
            turns: turns,
            previous: ChatFindState(),
            preserveCurrentMatch: false
        )
        #expect(state.matchTurnIds == [turns[2].id])
    }

    @Test func blankQueryClearsState() {
        let turns = makeTurns()
        let previous = ChatFindState(matchTurnIds: [turns[0].id], matchIndex: 0)
        for query in ["", "   ", "\n"] {
            let (state, jumpTo) = ChatFindMatcher.recompute(
                query: query,
                turns: turns,
                previous: previous,
                preserveCurrentMatch: false
            )
            #expect(state == ChatFindState())
            #expect(jumpTo == nil)
        }
    }

    @Test func noMatchesProducesEmptyStateWithoutJump() {
        let (state, jumpTo) = ChatFindMatcher.recompute(
            query: "zzz-not-present",
            turns: makeTurns(),
            previous: ChatFindState(),
            preserveCurrentMatch: false
        )
        #expect(state.matchTurnIds.isEmpty)
        #expect(state.matchIndex == 0)
        #expect(jumpTo == nil)
    }

    @Test func preservesCurrentMatchWhenTurnsAppend() {
        var turns = makeTurns()
        var (state, _) = ChatFindMatcher.recompute(
            query: "notch",
            turns: turns,
            previous: ChatFindState(),
            preserveCurrentMatch: false
        )
        // Navigate to the second match, then a streaming turn appends.
        (state, _) = ChatFindMatcher.advance(state, by: 1)
        #expect(state.matchIndex == 1)

        turns.append(ChatTurn(role: .assistant, content: "more about the notch"))
        let (recomputed, jumpTo) = ChatFindMatcher.recompute(
            query: "notch",
            turns: turns,
            previous: state,
            preserveCurrentMatch: true
        )
        // Current match (turns[1]) survives at the same position; no jump.
        #expect(recomputed.matchTurnIds.count == 4)
        #expect(recomputed.matchTurnIds[recomputed.matchIndex] == turns[1].id)
        #expect(jumpTo == nil)
    }

    @Test func resetsToFirstWhenCurrentMatchDisappears() {
        let turns = makeTurns()
        let gone = ChatFindState(matchTurnIds: [UUID()], matchIndex: 0)
        let (state, jumpTo) = ChatFindMatcher.recompute(
            query: "notch",
            turns: turns,
            previous: gone,
            preserveCurrentMatch: true
        )
        #expect(state.matchIndex == 0)
        #expect(state.matchTurnIds.first == turns[0].id)
        // Preserving recomputes never jump, even after a reset.
        #expect(jumpTo == nil)
    }

    @Test func advanceWrapsBothDirections() {
        let ids = [UUID(), UUID(), UUID()]
        var state = ChatFindState(matchTurnIds: ids, matchIndex: 0)

        var jumpTo: UUID?
        (state, jumpTo) = ChatFindMatcher.advance(state, by: 1)
        #expect(state.matchIndex == 1)
        #expect(jumpTo == ids[1])

        (state, jumpTo) = ChatFindMatcher.advance(state, by: 1)
        (state, jumpTo) = ChatFindMatcher.advance(state, by: 1)
        // Wrapped past the end back to the first match.
        #expect(state.matchIndex == 0)
        #expect(jumpTo == ids[0])

        (state, jumpTo) = ChatFindMatcher.advance(state, by: -1)
        // Wrapped backwards from the first match to the last.
        #expect(state.matchIndex == 2)
        #expect(jumpTo == ids[2])
    }

    @Test func advanceOnEmptyStateIsANoOp() {
        let (state, jumpTo) = ChatFindMatcher.advance(ChatFindState(), by: 1)
        #expect(state == ChatFindState())
        #expect(jumpTo == nil)
    }
}
