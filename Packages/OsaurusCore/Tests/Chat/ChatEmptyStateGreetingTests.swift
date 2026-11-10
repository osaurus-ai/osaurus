//
//  ChatEmptyStateGreetingTests.swift
//  osaurusTests
//
//  The greeting subtitle ends on a whole sentence instead of an ellipsis
//  mid-clause when an agent's description is long.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ChatEmptyStateGreetingTests {
    @Test("short descriptions pass through, whitespace collapsed")
    func shortDescription() {
        #expect(ChatEmptyState.greetingSubtitle("Plans trips.") == "Plans trips.")
        #expect(ChatEmptyState.greetingSubtitle("  Plans\n trips.  ") == "Plans trips.")
    }

    @Test("long descriptions keep the leading whole sentences that fit")
    func trimsToSentences() {
        let description =
            "Configures Osaurus settings and manages agents. "
            + "Use for app setup; general tasks can stay in the current agent. "
            + "It can also install models, add providers and wire channels for you."
        let subtitle = ChatEmptyState.greetingSubtitle(description)
        #expect(subtitle == "Configures Osaurus settings and manages agents. Use for app setup; general tasks can stay in the current agent.")
        #expect(subtitle.count <= ChatEmptyState.greetingSubtitleLimit)
    }

    @Test("a first sentence longer than the limit is kept whole")
    func longFirstSentence() {
        let sentence = String(repeating: "word ", count: 50).trimmingCharacters(in: .whitespaces) + "."
        #expect(ChatEmptyState.greetingSubtitle(sentence + " Second.") == sentence)
    }
}
