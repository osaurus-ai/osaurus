//
//  InjectedContextSpansTests.swift
//  osaurus / PrivacyFilter Tests
//
//  The app-injected `[Current Time]` block is context for the agent, not
//  user text: nothing inside it may be redacted, while identical content
//  outside it still is. Covers the range helper directly and the
//  regex-only engine path that applies it.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Injected context spans")
struct InjectedContextSpansTests {

    private let timeBlock = SystemPromptTemplates.timeContext(
        now: Date(timeIntervalSince1970: 1_789_000_000),
        timeZone: TimeZone(identifier: "Asia/Kolkata")!
    )

    @Test func findsTheTimeBlockInclusiveOfTags() {
        let text = timeBlock + "\n\nhello"
        let ranges = InjectedContextSpans.ranges(in: text)
        #expect(ranges.count == 1)
        #expect(ranges.first.map { String(text[$0]) } == timeBlock)
    }

    @Test func noBlock_noRanges() {
        #expect(InjectedContextSpans.ranges(in: "plain user text").isEmpty)
        // Unclosed tag is not a block.
        #expect(InjectedContextSpans.ranges(in: "[Current Time] dangling").isEmpty)
    }

    /// A phone number inside the injected block is skipped; the same
    /// number in the user's own text is still detected.
    @MainActor
    @Test func detect_skipsMatchesInsideInjectedBlock_keepsUserText() async throws {
        let injected = "[Current Time]\ncall 555-867-5309 now\n[/Current Time]"
        let text = injected + "\n\nmy number is 555-123-4567"
        let map = RedactionMap(conversationID: UUID())
        let detections = try await PrivacyFilterEngine.shared.detect(
            in: text,
            map: map,
            skipCodeBlocks: true,
            useModel: false
        )
        #expect(!detections.contains { $0.original == "555-867-5309" })
        #expect(detections.contains { $0.category == .phone && $0.original == "555-123-4567" })
    }

    /// The leak invariant must see the same view as detection, or a
    /// skipped in-block match would be counted as a leak and block the send.
    @Test func scanForLeaks_ignoresInjectedBlock() {
        let injected = "[Current Time]\ncall 555-867-5309 now\n[/Current Time]"
        let messages = [ChatMessage(role: "user", content: injected + "\n\nhi")]
        let counts = PrivacyFilterPipeline.scanForLeaks(
            in: messages,
            ruleset: .allBuiltins(),
            skipCodeBlocks: true
        )
        #expect(counts[.phone] == nil)
    }

    @Test func modelPiecesSeparateTheMessageFromEachInjectedBlock() {
        let screen = "[Screen Context]\nDoing: In Safari\n[/Screen Context]"
        let memory = "[Memory]\nfact\n[/Memory]"
        let message = "My name is Alice Smith, call me on 0211238389"
        let text = screen + "\n\n" + memory + "\n\n" + timeBlock + "\n\n" + message
        let pieces = InjectedContextSpans.modelPieces(in: text).map { String(text[$0]) }
        // The time block is skipped outright; blank stretches are dropped.
        #expect(pieces == [screen, memory, "\n\n" + message])
    }

    @Test func modelPiecesKeepAPlainMessageWhole() {
        let text = "My name is Alice Smith"
        #expect(InjectedContextSpans.modelPieces(in: text).map { String(text[$0]) } == [text])
    }
}
