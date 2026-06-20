//
//  CapabilityQueryIntentTests.swift
//  osaurusTests
//
//  Locks the precision contract of the capability-search query-intent
//  abstain gate (W3 retrieval). The gate must abstain on pure chit-chat
//  (so `capabilities_discover` returns nothing for a greeting) while NEVER
//  suppressing a real capability request — a single capability token must
//  keep the query out of the abstain bucket. Every CapabilitySearch suite
//  query is asserted here so a future word-list change can't silently
//  regress recall.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct CapabilityQueryIntentTests {

    private func abstains(_ q: String) -> Bool {
        CapabilityQueryIntent.isConversationalAbstain(q)
    }

    // MARK: - Must abstain (pure chit-chat)

    @Test func abstainsOnClosingPleasantry() {
        #expect(abstains("thanks, that's perfect"))
    }

    @Test func abstainsOnGreeting() {
        #expect(abstains("good morning"))
        #expect(abstains("hey there"))
        #expect(abstains("hello"))
    }

    @Test func abstainsOnAcknowledgements() {
        #expect(abstains("ok"))
        #expect(abstains("great thanks"))
        #expect(abstains("perfect, thank you"))
        #expect(abstains("awesome"))
        #expect(abstains("cool cool"))
        #expect(abstains("yep"))
    }

    @Test func abstainsOnFarewell() {
        #expect(abstains("bye!"))
        #expect(abstains("goodnight, thanks"))
    }

    // MARK: - Must NOT abstain (every CapabilitySearch suite query)

    @Test func doesNotAbstainOnSuiteCapabilityQueries() {
        let capabilityQueries = [
            "browser",
            "what's the weather in tokyo",
            "extract webpage contents",
            "summarize this PDF for me",
            "make a chart from this data",
            "I have a PDF I need to work with",
            "help me debug this crash",
            "help me prioritize my tasks",
            "give me the gist of this article",
            "run shell script",
        ]
        for query in capabilityQueries {
            #expect(abstains(query) == false, "should not abstain on: \(query)")
        }
    }

    // MARK: - Precision edge cases (pleasantry prefix + real ask)

    @Test func doesNotAbstainWhenPleasantryPrefixesARealRequest() {
        #expect(abstains("thanks! now summarize this") == false)
        #expect(abstains("cool, can you open a web page") == false)
        #expect(abstains("perfect, make me a chart") == false)
        #expect(abstains("good — find the weather") == false)
    }

    @Test func doesNotAbstainOnSingleCapabilityToken() {
        #expect(abstains("weather") == false)
        #expect(abstains("summarize") == false)
        #expect(abstains("gist") == false)
    }

    // MARK: - Degenerate input

    @Test func doesNotAbstainOnEmptyOrResidualStopwords() {
        // Nothing to judge → no pleasantry signal → don't abstain.
        #expect(abstains("") == false)
        #expect(abstains("   ") == false)
        #expect(abstains("the this it") == false)
    }
}
