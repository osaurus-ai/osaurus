//
//  TurnAttachmentMessageCacheTests.swift
//  OsaurusCoreTests
//
//  A turn's attachments are read once per run, and any change to the turn
//  builds its message again.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct TurnAttachmentMessageCacheTests {
    @Test func turnWithAttachmentsIsBuiltOnceUntilItChanges() {
        let cache = TurnAttachmentMessageCache()
        let turn = ChatTurn(
            role: .user, content: "describe this", attachments: [.image(Data([0x89, 0x50, 0x4E, 0x47]))])
        var builds = 0
        func build() -> ChatMessage {
            builds += 1
            return ChatMessage(role: "user", content: turn.content)
        }

        _ = cache.message(for: turn, build: build)
        let reused = cache.message(for: turn, build: build)
        #expect(builds == 1)
        #expect(reused.content == "describe this")

        turn.content = "describe this one"
        #expect(cache.message(for: turn, build: build).content == "describe this one")
        #expect(builds == 2)

        turn.attachments.append(.document(filename: "a.txt", content: "a", fileSize: 1))
        _ = cache.message(for: turn, build: build)
        #expect(builds == 3)

        turn.toolCallId = "call-1"
        _ = cache.message(for: turn, build: build)
        #expect(builds == 4)
    }

    @Test func turnWithoutAttachmentsIsAlwaysBuilt() {
        let cache = TurnAttachmentMessageCache()
        let turn = ChatTurn(role: .user, content: "hi")
        var builds = 0
        for _ in 0 ..< 3 {
            _ = cache.message(for: turn) {
                builds += 1
                return ChatMessage(role: "user", content: turn.content)
            }
        }
        #expect(builds == 3)
    }
}
