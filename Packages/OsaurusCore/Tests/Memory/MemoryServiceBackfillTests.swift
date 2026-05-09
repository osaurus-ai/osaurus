//
//  MemoryServiceBackfillTests.swift
//  osaurus
//
//  Pure unit tests for `MemoryService.pairTurnsForBackfill` — the
//  state machine that walks `chat_history.turns` and emits the
//  `(user, assistant?)` pairs the distillation pipeline expects.
//
//  This is the only path that turns the existing chat-history corpus
//  into `pending_signals` rows during the v7-migration backfill, so
//  every shape (regenerations, user-only sessions, sessions starting
//  with an assistant turn, system/tool turns mixed in) needs a test.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct MemoryServiceBackfillTests {

    @Test func empty_input_emits_no_pairs() {
        let pairs = MemoryService.pairTurnsForBackfill([])
        #expect(pairs.isEmpty)
    }

    @Test func single_user_turn_emits_pair_with_nil_assistant() {
        let turns = [turn(.user, "hello")]
        let pairs = MemoryService.pairTurnsForBackfill(turns)
        #expect(pairs.count == 1)
        #expect(pairs[0].user == "hello")
        #expect(pairs[0].assistant == nil)
    }

    @Test func user_then_assistant_emits_one_paired_entry() {
        let turns = [
            turn(.user, "ping"),
            turn(.assistant, "pong"),
        ]
        let pairs = MemoryService.pairTurnsForBackfill(turns)
        #expect(pairs.count == 1)
        #expect(pairs[0].user == "ping")
        #expect(pairs[0].assistant == "pong")
    }

    @Test func two_user_turns_in_a_row_emits_first_with_nil() {
        // Models the "user regenerated their question without waiting
        // for a response" case.
        let turns = [
            turn(.user, "first"),
            turn(.user, "second"),
            turn(.assistant, "answer"),
        ]
        let pairs = MemoryService.pairTurnsForBackfill(turns)
        #expect(pairs.count == 2)
        #expect(pairs[0].user == "first")
        #expect(pairs[0].assistant == nil)
        #expect(pairs[1].user == "second")
        #expect(pairs[1].assistant == "answer")
    }

    @Test func leading_assistant_turn_is_dropped_until_a_user_appears() {
        // Some imported sessions start with the assistant (greeting
        // template, system prompt rendered as assistant, etc.). These
        // turns can't anchor a pair, so they must be discarded.
        let turns = [
            turn(.assistant, "greeting"),
            turn(.user, "hi"),
            turn(.assistant, "hello"),
        ]
        let pairs = MemoryService.pairTurnsForBackfill(turns)
        #expect(pairs.count == 1)
        #expect(pairs[0].user == "hi")
        #expect(pairs[0].assistant == "hello")
    }

    @Test func system_and_tool_turns_are_skipped() {
        let turns = [
            turn(.system, "you are a helpful assistant"),
            turn(.user, "search the web"),
            turn(.tool, "{\"results\":[\"x\"]}"),
            turn(.assistant, "here's what i found"),
        ]
        let pairs = MemoryService.pairTurnsForBackfill(turns)
        #expect(pairs.count == 1)
        #expect(pairs[0].user == "search the web")
        #expect(pairs[0].assistant == "here's what i found")
    }

    @Test func empty_or_whitespace_content_is_skipped() {
        let turns = [
            turn(.user, "   "),
            turn(.assistant, ""),
            turn(.user, "real question"),
            turn(.assistant, "real answer"),
        ]
        let pairs = MemoryService.pairTurnsForBackfill(turns)
        #expect(pairs.count == 1)
        #expect(pairs[0].user == "real question")
        #expect(pairs[0].assistant == "real answer")
    }

    @Test func trailing_user_turn_is_emitted_with_nil_assistant() {
        // Last in-flight turn before app crash / quit. We still want
        // its content in the episode summary.
        let turns = [
            turn(.user, "first"),
            turn(.assistant, "answered"),
            turn(.user, "follow-up"),
        ]
        let pairs = MemoryService.pairTurnsForBackfill(turns)
        #expect(pairs.count == 2)
        #expect(pairs[1].user == "follow-up")
        #expect(pairs[1].assistant == nil)
    }

    @Test func content_is_trimmed_in_pairs() {
        let turns = [
            turn(.user, "  spaced question \n"),
            turn(.assistant, "\n\nanswer with whitespace  "),
        ]
        let pairs = MemoryService.pairTurnsForBackfill(turns)
        #expect(pairs.count == 1)
        #expect(pairs[0].user == "spaced question")
        #expect(pairs[0].assistant == "answer with whitespace")
    }

    @Test func long_session_alternating_pairs_correctly() {
        let turns = [
            turn(.user, "u1"),
            turn(.assistant, "a1"),
            turn(.user, "u2"),
            turn(.assistant, "a2"),
            turn(.user, "u3"),
            turn(.assistant, "a3"),
        ]
        let pairs = MemoryService.pairTurnsForBackfill(turns)
        #expect(pairs.count == 3)
        for (i, p) in pairs.enumerated() {
            #expect(p.user == "u\(i + 1)")
            #expect(p.assistant == "a\(i + 1)")
        }
    }

    // MARK: - Helpers

    private func turn(_ role: MessageRole, _ content: String) -> ChatTurnData {
        ChatTurnData(role: role, content: content)
    }
}
