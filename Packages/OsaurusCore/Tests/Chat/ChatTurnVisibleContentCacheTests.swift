//
//  ChatTurnVisibleContentCacheTests.swift
//
//  `ChatTurn.visibleContent` is read several times per block build on the
//  main thread and runs three display cleaners over the whole message. It is
//  memoized like `content`; these tests pin that every content mutation
//  invalidates the cache so the displayed text never goes stale
//  (APPLE-MACOS-1FE / 2PF).
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ChatTurnVisibleContentCacheTests {

    private let leaked = #"{"action": "share_artifact", "action_input": {"path": "a.md"}}"#

    @Test func repeatedReadsReturnTheSameCleanedValue() {
        let turn = ChatTurn(role: .assistant, content: "Hello\n\(leaked)")
        let first = turn.visibleContent
        #expect(first == "Hello")
        #expect(turn.visibleContent == first)
        #expect(turn.visibleContent == first)
    }

    @Test func appendInvalidatesCache() {
        let turn = ChatTurn(role: .assistant, content: "Hello")
        #expect(turn.visibleContent == "Hello")
        turn.appendContent(" world")
        #expect(turn.visibleContent == "Hello world")
        turn.appendContentAndNotify("\n\(leaked)")
        #expect(turn.visibleContent == "Hello world")
        #expect(turn.content == "Hello world\n\(leaked)")
    }

    @Test func directSetInvalidatesCache() {
        let turn = ChatTurn(role: .assistant, content: "A")
        #expect(turn.visibleContent == "A")
        turn.content = "B\n\(leaked)"
        #expect(turn.visibleContent == "B")
        turn.content = ""
        #expect(turn.visibleContent == "")
    }

    @Test func trailingLeakTrimInvalidatesCache() {
        let turn = ChatTurn(role: .assistant, content: "Reading it now.\nFunction: {\"name\": \"file_read\"")
        _ = turn.visibleContent
        turn.trimTrailingFunctionCallLeakage(toolName: "file_read")
        #expect(turn.content == "Reading it now.")
        #expect(turn.visibleContent == "Reading it now.")
    }

    @Test func consolidateKeepsCacheValid() {
        let turn = ChatTurn(role: .assistant, content: "")
        turn.appendContent("part one ")
        turn.appendContent("part two")
        #expect(turn.visibleContent == "part one part two")
        turn.consolidateContent()
        #expect(turn.visibleContent == "part one part two")
    }

    @Test func userTurnsAreNotCleaned() {
        let turn = ChatTurn(role: .user, content: leaked)
        #expect(turn.visibleContent == leaked)
        turn.appendContent(" more")
        #expect(turn.visibleContent == leaked + " more")
    }
}
