//
//  StreamingUnscrubberTests.swift
//  osaurusTests
//
//  StreamingUnscrubber correctness across:
//   • single push with a complete token
//   • mid-token chunk splits
//   • unknown placeholder tokens
//   • adversarial stray-bracket prose that exceeds the safety margin
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("StreamingUnscrubber")
struct StreamingUnscrubberTests {

    @Test func push_completeToken_isReplaced() async {
        let map = RedactionMap(conversationID: UUID())
        _ = await map.intern("Alice", as: .person)
        let unscrubber = await StreamingUnscrubber.make(for: map)

        var collected = ""
        collected += await unscrubber.push("Hello [PERSON_1], how are you?")
        collected += await unscrubber.flush()

        #expect(collected == "Hello Alice, how are you?")
    }

    @Test func push_tokenSplitAcrossChunks_isReplacedAfterRejoin() async {
        let map = RedactionMap(conversationID: UUID())
        _ = await map.intern("Bob Brown", as: .person)
        let unscrubber = await StreamingUnscrubber.make(for: map)

        var collected = ""
        collected += await unscrubber.push("Hi [")
        collected += await unscrubber.push("PERS")
        collected += await unscrubber.push("ON_1], welcome.")
        collected += await unscrubber.flush()

        #expect(collected == "Hi Bob Brown, welcome.")
    }

    @Test func push_unknownPlaceholder_isLeftInPlace() async {
        let map = RedactionMap(conversationID: UUID())
        _ = await map.intern("Alice", as: .person)
        let unscrubber = await StreamingUnscrubber.make(for: map)

        var collected = ""
        collected += await unscrubber.push("Hi [PERSON_99], not me.")
        collected += await unscrubber.flush()

        #expect(collected == "Hi [PERSON_99], not me.")
    }

    @Test func push_strayOpenBracketBeyondLimit_isFlushed() async {
        let map = RedactionMap(conversationID: UUID())
        _ = await map.intern("Alice", as: .person)
        let unscrubber = await StreamingUnscrubber.make(for: map)

        // The pending tail after a stray `[` should NOT be held forever
        // when the model emits long prose without a matching `]`.
        let tail = String(repeating: "X", count: 200)
        var collected = ""
        collected += await unscrubber.push("Start [\(tail)")
        collected += await unscrubber.flush()

        #expect(collected == "Start [\(tail)")
    }

    @Test func push_emptyStream_flushesEmpty() async {
        let map = RedactionMap(conversationID: UUID())
        let unscrubber = await StreamingUnscrubber.make(for: map)

        let pushed = await unscrubber.push("")
        let flushed = await unscrubber.flush()

        #expect(pushed.isEmpty)
        #expect(flushed.isEmpty)
    }
}
