//
//  ChatInputHistoryTests.swift
//  osaurusTests
//
//  Pins the composer's terminal-style input history: entry derivation,
//  draft stashing/restoration, and both navigation directions.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ChatInputHistoryTests {

    // MARK: - Entries

    @Test func entriesAreUserTurnsNewestFirst() {
        let turns = [
            ChatTurn(role: .user, content: "first"),
            ChatTurn(role: .assistant, content: "reply"),
            ChatTurn(role: .user, content: "second"),
            ChatTurn(role: .user, content: "third"),
        ]
        #expect(ChatInputHistory.entries(from: turns) == ["third", "second", "first"])
    }

    @Test func entriesSkipBlankAndCollapseConsecutiveDuplicates() {
        let turns = [
            ChatTurn(role: .user, content: "retry"),
            ChatTurn(role: .user, content: "retry"),
            ChatTurn(role: .user, content: "   "),
            ChatTurn(role: .user, content: "done"),
        ]
        #expect(ChatInputHistory.entries(from: turns) == ["done", "retry"])
    }

    @Test func entriesIgnoreNonUserRoles() {
        let turns = [
            ChatTurn(role: .system, content: "prompt"),
            ChatTurn(role: .assistant, content: "hello"),
            ChatTurn(role: .tool, content: "output"),
        ]
        #expect(ChatInputHistory.entries(from: turns).isEmpty)
    }

    // MARK: - Recall (Up)

    @Test func firstRecallStashesDraftAndShowsNewestEntry() {
        let result = ChatInputHistory.recall(
            state: ChatInputHistoryState(),
            entries: ["newest", "older"],
            currentDraft: "work in progress"
        )
        #expect(result?.text == "newest")
        #expect(result?.state == ChatInputHistoryState(index: 0, savedDraft: "work in progress"))
    }

    @Test func repeatedRecallWalksTowardOldest() {
        var state = ChatInputHistoryState()
        let entries = ["a", "b", "c"]

        for expected in ["a", "b", "c"] {
            let result = ChatInputHistory.recall(state: state, entries: entries, currentDraft: "")
            #expect(result?.text == expected)
            state = result!.state
        }
        // At the oldest entry Up recalls nothing further.
        #expect(ChatInputHistory.recall(state: state, entries: entries, currentDraft: "") == nil)
    }

    @Test func recallWithNoHistoryDoesNothing() {
        let result = ChatInputHistory.recall(
            state: ChatInputHistoryState(),
            entries: [],
            currentDraft: "draft"
        )
        #expect(result == nil)
    }

    @Test func recallPreservesOriginalDraftAcrossSteps() {
        let entries = ["a", "b"]
        var state = ChatInputHistoryState()
        state = ChatInputHistory.recall(state: state, entries: entries, currentDraft: "my draft")!.state
        state = ChatInputHistory.recall(state: state, entries: entries, currentDraft: "a")!.state
        // The stash keeps the ORIGINAL draft, not the recalled text passed
        // on subsequent steps.
        #expect(state.savedDraft == "my draft")
    }

    // MARK: - Advance (Down)

    @Test func advanceWalksBackAndRestoresDraft() {
        let entries = ["a", "b", "c"]
        var state = ChatInputHistoryState(index: 2, savedDraft: "draft")

        var result = ChatInputHistory.advance(state: state, entries: entries)
        #expect(result?.text == "b")
        state = result!.state

        result = ChatInputHistory.advance(state: state, entries: entries)
        #expect(result?.text == "a")
        state = result!.state

        // Walking past the newest entry restores the draft and leaves navigation.
        result = ChatInputHistory.advance(state: state, entries: entries)
        #expect(result?.text == "draft")
        #expect(result?.state == ChatInputHistoryState())
    }

    @Test func advanceWhileNotNavigatingDoesNothing() {
        let result = ChatInputHistory.advance(
            state: ChatInputHistoryState(),
            entries: ["a"]
        )
        #expect(result == nil)
    }

    @Test func advanceRecoversWhenEntriesShrink() {
        // Conversation was cleared mid-navigation; state points past the end.
        let result = ChatInputHistory.advance(
            state: ChatInputHistoryState(index: 5, savedDraft: "draft"),
            entries: ["only"]
        )
        #expect(result?.text == "draft")
        #expect(result?.state == ChatInputHistoryState())
    }
}
