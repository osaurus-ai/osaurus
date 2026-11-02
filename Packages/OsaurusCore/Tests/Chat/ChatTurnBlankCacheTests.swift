//
//  ChatTurnBlankCacheTests.swift
//
//  `contentIsBlank` / `thinkingIsBlank` are read for every assistant turn on
//  every streaming visible-blocks rebuild, so they are memoized instead of
//  trimming the whole message each time (APPLE-MACOS-3KF). These tests pin
//  that every mutation invalidates the memo so the answer never goes stale.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ChatTurnBlankCacheTests {

    @Test func emptyContentIsBlank() {
        let turn = ChatTurn(role: .assistant, content: "")
        #expect(turn.contentIsBlank)
    }

    @Test func whitespaceOnlyContentIsBlankAndStaysCorrectAfterAppend() {
        let turn = ChatTurn(role: .assistant, content: "")
        turn.appendContent("\n")
        turn.appendContent("  \n")
        #expect(turn.contentIsBlank)
        #expect(turn.contentIsBlank)
        turn.appendContent("answer")
        #expect(!turn.contentIsBlank)
    }

    @Test func directSetInvalidatesContentBlank() {
        let turn = ChatTurn(role: .assistant, content: "hello")
        #expect(!turn.contentIsBlank)
        turn.content = "   "
        #expect(turn.contentIsBlank)
        turn.content = "again"
        #expect(!turn.contentIsBlank)
        turn.content = ""
        #expect(turn.contentIsBlank)
    }

    @Test func emptyThinkingIsBlank() {
        let turn = ChatTurn(role: .assistant, content: "")
        #expect(turn.thinkingIsBlank)
        #expect(!turn.hasRenderableThinking)
    }

    @Test func thinkingBlankTracksAppendAndSet() {
        let turn = ChatTurn(role: .assistant, content: "")
        turn.appendThinking("\n ")
        #expect(turn.thinkingIsBlank)
        #expect(turn.thinkingIsBlank)
        turn.appendThinking("Let me reason about this.")
        #expect(!turn.thinkingIsBlank)
        #expect(turn.hasRenderableThinking)
        turn.thinking = "  "
        #expect(turn.thinkingIsBlank)
        turn.thinking = "real reasoning text"
        #expect(!turn.thinkingIsBlank)
    }

    @Test func bareChannelLabelThinkingIsBlank() {
        let turn = ChatTurn(role: .assistant, content: "")
        turn.thinking = "thought"
        #expect(turn.thinkingIsBlank == ChatTurn.isBareChannelIdentifier("thought"))
    }

    @Test func consolidateKeepsBlankAnswers() {
        let turn = ChatTurn(role: .assistant, content: "")
        turn.appendContent(" ")
        turn.appendContent("x")
        turn.appendThinking(" ")
        #expect(!turn.contentIsBlank)
        #expect(turn.thinkingIsBlank)
        turn.consolidateContent()
        #expect(!turn.contentIsBlank)
        #expect(turn.thinkingIsBlank)
    }
}
