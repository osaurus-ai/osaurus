//
//  ChatFindMatcherTests.swift
//  osaurusTests
//
//  Pins the in-conversation find bar's match logic: role filtering,
//  case-insensitive matching, per-occurrence navigation, current-match
//  preservation across streaming recomputes, and wraparound navigation.
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
        #expect(
            state.matches == [
                ChatFindMatch(turnId: turns[0].id, occurrence: 0),
                ChatFindMatch(turnId: turns[1].id, occurrence: 0),
                ChatFindMatch(turnId: turns[3].id, occurrence: 0),
            ])
        #expect(state.matchIndex == 0)
        #expect(jumpTo == ChatFindMatch(turnId: turns[0].id, occurrence: 0))
    }

    @Test func everyOccurrenceInATurnIsItsOwnMatch() {
        let turns = [
            ChatTurn(role: .user, content: "notch"),
            ChatTurn(role: .assistant, content: "Notch notch NOTCH."),
        ]
        let (state, _) = ChatFindMatcher.recompute(
            query: "notch",
            turns: turns,
            previous: ChatFindState(),
            preserveCurrentMatch: false
        )
        #expect(
            state.matches == [
                ChatFindMatch(turnId: turns[0].id, occurrence: 0),
                ChatFindMatch(turnId: turns[1].id, occurrence: 0),
                ChatFindMatch(turnId: turns[1].id, occurrence: 1),
                ChatFindMatch(turnId: turns[1].id, occurrence: 2),
            ])
    }

    @Test func occurrenceCountIsNonOverlapping() {
        #expect(ChatFindMatcher.occurrenceCount(of: "aa", in: "aaaa") == 2)
        #expect(ChatFindMatcher.occurrenceCount(of: "notch", in: "no notch here") == 1)
        #expect(ChatFindMatcher.occurrenceCount(of: "x", in: "") == 0)
        #expect(ChatFindMatcher.occurrenceCount(of: "", in: "abc") == 0)
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
        #expect(state.matches == [ChatFindMatch(turnId: turns[2].id, occurrence: 0)])
    }

    @Test func blankQueryClearsState() {
        let turns = makeTurns()
        let previous = ChatFindState(
            matches: [ChatFindMatch(turnId: turns[0].id, occurrence: 0)], matchIndex: 0)
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
        #expect(state.matches.isEmpty)
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
        // Current match (turns[1], first occurrence) survives at the same
        // position; no jump.
        #expect(recomputed.matches.count == 4)
        #expect(
            recomputed.matches[recomputed.matchIndex]
                == ChatFindMatch(turnId: turns[1].id, occurrence: 0))
        #expect(jumpTo == nil)
    }

    @Test func preservesCurrentOccurrenceWithinATurn() {
        var turns = [ChatTurn(role: .assistant, content: "notch and notch")]
        var (state, _) = ChatFindMatcher.recompute(
            query: "notch",
            turns: turns,
            previous: ChatFindState(),
            preserveCurrentMatch: false
        )
        (state, _) = ChatFindMatcher.advance(state, by: 1)
        #expect(state.matches[state.matchIndex].occurrence == 1)

        // Streaming grows the same turn — the second occurrence stays current.
        turns[0].content += " plus a third notch"
        let (recomputed, jumpTo) = ChatFindMatcher.recompute(
            query: "notch",
            turns: turns,
            previous: state,
            preserveCurrentMatch: true
        )
        #expect(recomputed.matches.count == 3)
        #expect(recomputed.matches[recomputed.matchIndex].occurrence == 1)
        #expect(jumpTo == nil)
    }

    @Test func resetsToFirstWhenCurrentMatchDisappears() {
        let turns = makeTurns()
        let gone = ChatFindState(
            matches: [ChatFindMatch(turnId: UUID(), occurrence: 0)], matchIndex: 0)
        let (state, jumpTo) = ChatFindMatcher.recompute(
            query: "notch",
            turns: turns,
            previous: gone,
            preserveCurrentMatch: true
        )
        #expect(state.matchIndex == 0)
        #expect(state.matches.first == ChatFindMatch(turnId: turns[0].id, occurrence: 0))
        // Preserving recomputes never jump, even after a reset.
        #expect(jumpTo == nil)
    }

    @Test func advanceWrapsBothDirections() {
        let turnId = UUID()
        let matches = (0..<3).map { ChatFindMatch(turnId: turnId, occurrence: $0) }
        var state = ChatFindState(matches: matches, matchIndex: 0)

        var jumpTo: ChatFindMatch?
        (state, jumpTo) = ChatFindMatcher.advance(state, by: 1)
        #expect(state.matchIndex == 1)
        #expect(jumpTo == matches[1])

        (state, jumpTo) = ChatFindMatcher.advance(state, by: 1)
        (state, jumpTo) = ChatFindMatcher.advance(state, by: 1)
        // Wrapped past the end back to the first match.
        #expect(state.matchIndex == 0)
        #expect(jumpTo == matches[0])

        (state, jumpTo) = ChatFindMatcher.advance(state, by: -1)
        // Wrapped backwards from the first match to the last.
        #expect(state.matchIndex == 2)
        #expect(jumpTo == matches[2])
    }

    @Test func advanceOnEmptyStateIsANoOp() {
        let (state, jumpTo) = ChatFindMatcher.advance(ChatFindState(), by: 1)
        #expect(state == ChatFindState())
        #expect(jumpTo == nil)
    }
}
