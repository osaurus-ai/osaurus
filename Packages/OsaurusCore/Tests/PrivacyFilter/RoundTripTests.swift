//
//  RoundTripTests.swift
//  osaurusTests
//
//  Engine-free round-trip: intern + apply produces a scrubbed string;
//  feeding the scrubbed text back through the unscrubber recovers the
//  original. Exercises the pieces a real chat turn touches without
//  loading the on-device classifier.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("PrivacyFilter Round-Trip")
struct RoundTripTests {

    @Test func internApplyUnscrub_recoversOriginal() async {
        let map = RedactionMap(conversationID: UUID())
        let originalText = "Hi Alice, email alice@example.com about the meeting."

        // Manually intern the entities the engine would have found.
        let alicePh = await map.intern("Alice", as: .person)
        let emailPh = await map.intern("alice@example.com", as: .email)

        // Apply: simulate substitution that PrivacyFilterEngine.apply
        // would produce. We replace the originals with their tokens.
        var scrubbed = originalText
        scrubbed = scrubbed.replacingOccurrences(of: "Alice", with: alicePh.token)
        scrubbed = scrubbed.replacingOccurrences(of: "alice@example.com", with: emailPh.token)

        #expect(scrubbed.contains(alicePh.token))
        #expect(scrubbed.contains(emailPh.token))
        #expect(!scrubbed.contains("Alice"))

        // Round-trip through the streaming unscrubber.
        let unscrubber = await StreamingUnscrubber.make(for: map)
        var collected = ""
        collected += await unscrubber.push(scrubbed)
        collected += await unscrubber.flush()

        #expect(collected == originalText)
    }

    @Test func repeatedOriginal_collapsesToSinglePlaceholder() async {
        let map = RedactionMap(conversationID: UUID())
        let placeholder1 = await map.intern("Alice", as: .person)
        let placeholder2 = await map.intern("Alice", as: .person)
        #expect(placeholder1 == placeholder2)
    }
}
