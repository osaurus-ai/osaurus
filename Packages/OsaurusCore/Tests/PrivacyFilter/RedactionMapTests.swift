//
//  RedactionMapTests.swift
//  osaurusTests
//
//  RedactionMap behavior: dedup-by-original, per-category counters,
//  reverse lookup, snapshot, and emptiness probe.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("RedactionMap")
struct RedactionMapTests {

    @Test func intern_uniqueOriginals_assignDistinctIndices() async {
        let map = RedactionMap(conversationID: UUID())

        let a = await map.intern("Alice Anderson", as: .person)
        let b = await map.intern("Bob Brown", as: .person)
        let c = await map.intern("alice@example.com", as: .email)

        #expect(a.token == "[PERSON_1]")
        #expect(b.token == "[PERSON_2]")
        #expect(c.token == "[EMAIL_1]")
    }

    @Test func intern_sameOriginalTwice_returnsSamePlaceholder() async {
        let map = RedactionMap(conversationID: UUID())

        let first = await map.intern("Alice", as: .person)
        let second = await map.intern("Alice", as: .person)

        #expect(first == second)
    }

    @Test func resolve_returnsOriginalForKnownToken() async {
        let map = RedactionMap(conversationID: UUID())
        let placeholder = await map.intern("info@example.com", as: .email)

        let original = await map.resolve(token: placeholder.token)
        #expect(original == "info@example.com")
    }

    @Test func resolve_returnsNilForUnknownToken() async {
        let map = RedactionMap(conversationID: UUID())
        _ = await map.intern("Alice", as: .person)

        let original = await map.resolve(token: "[PERSON_99]")
        #expect(original == nil)
    }

    @Test func maxTokenLength_growsWithLargerIndices() async {
        let map = RedactionMap(conversationID: UUID())

        // Start empty.
        let empty = await map.maxTokenLength
        #expect(empty == 0)

        // Single placeholder: `[PERSON_1]` = 10 chars.
        _ = await map.intern("a", as: .person)
        let one = await map.maxTokenLength
        #expect(one == "[PERSON_1]".count)

        // Add enough to push the index to two digits.
        for i in 1 ... 10 {
            _ = await map.intern("person\(i)", as: .person)
        }
        let two = await map.maxTokenLength
        #expect(two >= "[PERSON_10]".count)
    }

    @Test func isEmpty_tracksInternState() async {
        let map = RedactionMap(conversationID: UUID())
        let beforeEmpty = await map.isEmpty
        #expect(beforeEmpty == true)

        _ = await map.intern("Alice", as: .person)
        let afterEmpty = await map.isEmpty
        #expect(afterEmpty == false)
    }

    @Test func snapshot_reflectsEveryInternedPair() async {
        let map = RedactionMap(conversationID: UUID())
        _ = await map.intern("Alice", as: .person)
        _ = await map.intern("alice@example.com", as: .email)

        let snapshot = await map.snapshot()
        let originals = Set(snapshot.map(\.1))
        #expect(originals == ["Alice", "alice@example.com"])
    }
}
