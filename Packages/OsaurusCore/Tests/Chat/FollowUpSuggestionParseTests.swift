//
//  FollowUpSuggestionParseTests.swift
//  osaurusTests
//
//  Pin the follow-up suggestion parser contract: the pure `parse` function
//  that turns a raw Core Model completion into clean, deduped, bounded
//  question strings. Small models deviate from the JSON contract constantly
//  (fences, prose preambles, numbered lists, duplicates), so the parser has
//  to be tolerant without letting junk through.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Follow-up suggestion parsing")
struct FollowUpSuggestionParseTests {

    @Test("clean JSON array parses in order")
    func cleanJSONArray() {
        let raw = #"["What is Prop 213?", "Are there exceptions?"]"#
        #expect(
            FollowUpSuggestionService.parse(raw)
                == ["What is Prop 213?", "Are there exceptions?"]
        )
    }

    @Test("JSON wrapped in a code fence and prose still parses")
    func fencedJSON() {
        let raw = """
            Sure! Here are some follow-ups:
            ```json
            ["First question?", "Second question?"]
            ```
            """
        #expect(
            FollowUpSuggestionService.parse(raw)
                == ["First question?", "Second question?"]
        )
    }

    @Test("plain numbered / bulleted list falls back to line parsing")
    func lineListFallback() {
        let raw = """
            1. What are the key elements?
            2) Can you explain the exclusion?
            - What are common defenses?
            """
        #expect(
            FollowUpSuggestionService.parse(raw) == [
                "What are the key elements?",
                "Can you explain the exclusion?",
                "What are common defenses?",
            ]
        )
    }

    @Test("case-insensitive duplicates collapse to one")
    func dedupesCaseInsensitively() {
        let raw = #"["What is Prop 213?", "what is prop 213?", "A different one?"]"#
        #expect(
            FollowUpSuggestionService.parse(raw)
                == ["What is Prop 213?", "A different one?"]
        )
    }

    @Test("caps at the requested suggestion count")
    func capsCount() {
        let raw = #"["Q1?", "Q2?", "Q3?", "Q4?", "Q5?", "Q6?"]"#
        let result = FollowUpSuggestionService.parse(raw)
        #expect(result.count == FollowUpSuggestionService.suggestionCount)
        #expect(result == ["Q1?", "Q2?", "Q3?", "Q4?"])
    }

    @Test("empty or whitespace input yields no suggestions")
    func emptyInput() {
        #expect(FollowUpSuggestionService.parse("").isEmpty)
        #expect(FollowUpSuggestionService.parse("   \n  ").isEmpty)
    }

    @Test("entries with structural leakage are dropped, valid ones kept")
    func dropsStructuralLeakage() {
        let raw = #"["Valid question?", "<div>leaked</div>", "Another valid one?"]"#
        #expect(
            FollowUpSuggestionService.parse(raw)
                == ["Valid question?", "Another valid one?"]
        )
    }

    @Test("an over-long line is treated as leaked prose and dropped")
    func dropsOverLongSuggestion() {
        let long = String(repeating: "word ", count: 60) + "?"
        let raw = "[\"Short question?\", \"\(long)\"]"
        #expect(FollowUpSuggestionService.parse(raw) == ["Short question?"])
    }
}
