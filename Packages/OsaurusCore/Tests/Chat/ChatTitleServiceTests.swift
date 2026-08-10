//
//  ChatTitleServiceTests.swift
//  osaurusTests
//
//  Pin the sanitizer contract for AI-generated chat titles. `sanitize` is a
//  pure function, so we can lock in the quality gate without spinning up
//  CoreModelService. Also pins the setting's default-off state, which the
//  rollout plan relies on (bake for a few releases before flipping).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("ChatTitleService sanitize")
struct ChatTitleServiceTests {

    @Test("clean title passes through unchanged")
    func cleanTitle() {
        #expect(ChatTitleService.sanitize("Fixing a SwiftUI Layout Bug") == "Fixing a SwiftUI Layout Bug")
    }

    @Test("wrapping quotes and trailing punctuation are stripped")
    func quotesAndPunctuation() {
        #expect(ChatTitleService.sanitize("\"Planning a Trip to Kyoto.\"") == "Planning a Trip to Kyoto")
        #expect(ChatTitleService.sanitize("“Weekly Meal Prep Ideas!”") == "Weekly Meal Prep Ideas")
        #expect(ChatTitleService.sanitize("'Rust Borrow Checker Basics…'") == "Rust Borrow Checker Basics")
    }

    @Test("leading Title: label is dropped")
    func titleLabel() {
        #expect(ChatTitleService.sanitize("Title: Debugging Python Imports") == "Debugging Python Imports")
        #expect(ChatTitleService.sanitize("TITLE:  Tax Filing Questions") == "Tax Filing Questions")
    }

    @Test("markdown emphasis is stripped")
    func markdown() {
        #expect(ChatTitleService.sanitize("**Docker Compose Setup**") == "Docker Compose Setup")
        #expect(ChatTitleService.sanitize("# Resume Review") == "Resume Review")
    }

    @Test("only the first non-empty line is used")
    func firstLineOnly() {
        let raw = "\n\nGarden Irrigation Plan\nThis title captures the topic."
        #expect(ChatTitleService.sanitize(raw) == "Garden Irrigation Plan")
    }

    @Test("structural markup characters reject the title outright")
    func corruptedOutput() {
        #expect(ChatTitleService.sanitize("{\"title\": \"Chat\"}") == nil)
        #expect(ChatTitleService.sanitize("<title>Chat</title>") == nil)
        #expect(ChatTitleService.sanitize("icon|label|prompt") == nil)
    }

    @Test("empty and whitespace output rejects")
    func emptyOutput() {
        #expect(ChatTitleService.sanitize("") == nil)
        #expect(ChatTitleService.sanitize("   \n\n  ") == nil)
        #expect(ChatTitleService.sanitize("\"...\"") == nil)
    }

    @Test("long output is capped at the word budget")
    func wordCap() {
        let raw = "one two three four five six seven eight nine ten"
        #expect(ChatTitleService.sanitize(raw) == "one two three four five six seven eight")
    }

    @Test("character clamp lands on a word boundary")
    func characterClamp() throws {
        let raw = "Comprehensive Kubernetes Deployment Troubleshooting Walkthrough Guide"
        let unwrapped = try #require(ChatTitleService.sanitize(raw))
        #expect(unwrapped.count <= ChatTitleService.maxTitleChars)
        #expect(!unwrapped.hasSuffix(" "))
        #expect(raw.hasPrefix(unwrapped))
    }

    @Test("auto titles ship default-off")
    func defaultOff() throws {
        #expect(ChatConfiguration.default.autoGenerateChatTitles == false)
        // A persisted config from a build predating the field decodes to off.
        let legacy = #"{"systemPrompt":"","title":"x"}"#
        let decoded = try JSONDecoder().decode(
            ChatConfiguration.self,
            from: Data(legacy.utf8)
        )
        #expect(decoded.autoGenerateChatTitles == false)
    }
}
