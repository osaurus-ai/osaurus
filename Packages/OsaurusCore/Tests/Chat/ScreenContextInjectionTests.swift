//
//  ScreenContextInjectionTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Coverage for `SystemPromptComposer.injectScreenContextPrefix`: it must ride
//  on the latest user message (so the Privacy Filter scans it) without
//  disturbing the system prefix or multimodal turns, and compose cleanly with
//  the memory prefix that shares the same seam.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class ScreenContextInjectionTests: XCTestCase {
    private let block = "[Screen Context]\nDoing: In Safari\n[/Screen Context]"

    func testPrependsToLatestUserMessage() {
        var msgs: [ChatMessage] = [
            ChatMessage(role: "system", content: "sys"),
            ChatMessage(role: "user", content: "hello"),
        ]
        SystemPromptComposer.injectScreenContextPrefix(block, into: &msgs)
        XCTAssertEqual(msgs[0].content, "sys")
        XCTAssertEqual(msgs[1].content, "\(block)\n\nhello")
    }

    func testNoOpOnNilOrBlank() {
        var msgs: [ChatMessage] = [ChatMessage(role: "user", content: "hi")]
        SystemPromptComposer.injectScreenContextPrefix(nil, into: &msgs)
        SystemPromptComposer.injectScreenContextPrefix("   \n  ", into: &msgs)
        XCTAssertEqual(msgs[0].content, "hi")
    }

    func testNoOpWhenNoUserMessage() {
        var msgs: [ChatMessage] = [ChatMessage(role: "system", content: "sys")]
        SystemPromptComposer.injectScreenContextPrefix(block, into: &msgs)
        XCTAssertEqual(msgs[0].content, "sys")
    }

    func testSkipsMultimodalUserMessage() {
        var msgs: [ChatMessage] = [
            ChatMessage(role: "user", content: "caption", contentParts: [.text("caption")])
        ]
        SystemPromptComposer.injectScreenContextPrefix(block, into: &msgs)
        XCTAssertNotNil(msgs[0].contentParts)
        XCTAssertEqual(msgs[0].content, "caption")
    }

    func testTargetsTheLastUserMessage() {
        var msgs: [ChatMessage] = [
            ChatMessage(role: "user", content: "first"),
            ChatMessage(role: "assistant", content: "reply"),
            ChatMessage(role: "user", content: "second"),
        ]
        SystemPromptComposer.injectScreenContextPrefix(block, into: &msgs)
        XCTAssertEqual(msgs[0].content, "first")
        XCTAssertEqual(msgs[2].content, "\(block)\n\nsecond")
    }

    func testComposesWithMemoryPrefix() {
        var msgs: [ChatMessage] = [
            ChatMessage(role: "system", content: "sys"),
            ChatMessage(role: "user", content: "hello"),
        ]
        // Same order the chat loop uses: memory first, then screen context.
        SystemPromptComposer.injectMemoryPrefix("remember this", into: &msgs)
        SystemPromptComposer.injectScreenContextPrefix(block, into: &msgs)

        let content = msgs[1].content ?? ""
        XCTAssertTrue(content.contains("[Screen Context]"))
        XCTAssertTrue(content.contains("[Memory]"))
        XCTAssertTrue(content.contains("hello"))

        // Screen context is prepended last, so it sits above the memory block.
        let screenIdx = content.range(of: "[Screen Context]")!.lowerBound
        let memoryIdx = content.range(of: "[Memory]")!.lowerBound
        XCTAssertLessThan(screenIdx, memoryIdx)
    }
}
