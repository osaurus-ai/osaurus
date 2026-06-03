//
//  GenerativeGreetingFormatTests.swift
//  osaurusTests
//
//  Pin the parser contract for the new tagged-line + legacy JSON
//  formats produced by `GenerativeGreetingService`. The tagged-line
//  format is what small models (Apple Foundation in particular) can
//  realistically follow; the JSON format is the back-compat path for
//  completions still mid-flight at upgrade time. The quality gate
//  predicate is a pure function we can lock in here without spinning
//  up CoreModelService.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("GenerativeGreetingService format")
struct GenerativeGreetingFormatTests {

    // MARK: - Tagged-line format

    @Test("parse accepts the canonical tagged-line format")
    func taggedLinesCanonical() throws {
        let raw = """
            GREETING: Soho Delight
            SUBTITLE: Map your next move with a quick win.
            ACTION1: sparkles|Boost|Give me one bold idea for\u{0020}
            ACTION2: calendar|Plan Ahead|Sketch tomorrow's priorities for\u{0020}
            """
        let result = try GenerativeGreetingService.parse(raw, expectedActions: 2)
        #expect(result.greeting == "Soho Delight")
        #expect(result.actions.count == 2)
        #expect(result.actions[0].icon == "sparkles")
        #expect(result.actions[0].text == "Boost")
        // The prompt's trailing space must survive the parser — the
        // chat input field puts the caret right after it.
        #expect(result.actions[0].prompt.hasSuffix(" "))
        #expect(result.actions[1].icon == "calendar")
    }

    @Test("parse tolerates trailing whitespace on each line + blank separators")
    func taggedLinesTolerantWhitespace() throws {
        let raw = """

            GREETING:   Quick Pivot   \t

            SUBTITLE: Two paths, both worth a look.   

            ACTION1: lightbulb|Idea|Suggest a new angle for\u{0020}
            ACTION2: pencil.line|Draft|Outline a one-pager about\u{0020}

            """
        let result = try GenerativeGreetingService.parse(raw, expectedActions: 2)
        #expect(result.greeting == "Quick Pivot")
        #expect(result.subtitle == "Two paths, both worth a look.")
        #expect(result.actions.count == 2)
    }

    @Test("parse reorders out-of-order ACTION indices")
    func taggedLinesActionsReordered() throws {
        let raw = """
            GREETING: Steady Hands
            SUBTITLE: Pick a thread to pull next.
            ACTION2: calendar|Plan|Sketch tomorrow's plan for\u{0020}
            ACTION1: sparkles|Boost|Give me one bold idea for\u{0020}
            """
        let result = try GenerativeGreetingService.parse(raw, expectedActions: 2)
        // ACTION1 (sparkles) must come first regardless of source order.
        #expect(result.actions[0].icon == "sparkles")
        #expect(result.actions[1].icon == "calendar")
    }

    @Test("parse rejects tagged input with too few actions")
    func taggedLinesMissingActions() {
        let raw = """
            GREETING: Half Done
            SUBTITLE: Only one action made it.
            ACTION1: sparkles|Boost|Give me one bold idea for\u{0020}
            """
        #expect(throws: GenerativeGreetingError.missingFields) {
            try GenerativeGreetingService.parse(raw, expectedActions: 2)
        }
    }

    @Test("parse rejects an unknown icon in tagged-line output")
    func taggedLinesRejectUnknownIcon() {
        let raw = """
            GREETING: Test
            SUBTITLE: Pinning the icon allowlist.
            ACTION1: not.a.real.icon|Go|Draft a plan for\u{0020}
            ACTION2: definitely.fake|Plan|Sketch a path for\u{0020}
            """
        #expect(throws: GenerativeGreetingError.missingFields) {
            try GenerativeGreetingService.parse(raw, expectedActions: 2)
        }
    }

    @Test("parse rejects action payloads with extra pipe delimiters")
    func taggedLinesRejectExtraActionPipes() {
        let raw = """
            GREETING: Test
            SUBTITLE: Pinning the pipe delimiter.
            ACTION1: sparkles|Go|Draft a plan for\u{0020}
            ACTION2: calendar|Plan|Sketch|a path for\u{0020}
            """
        #expect(throws: GenerativeGreetingError.missingFields) {
            try GenerativeGreetingService.parse(raw, expectedActions: 2)
        }
    }

    @Test("quality gate rejects corrupted Gemma4 greeting fields")
    func qualityGateTripsOnCorruptedGemma4Fields() {
        let g = GenerativeGreeting(
            greeting: "I' a doing well",
            subtitle: "How can I assist with your infrastructure-related-setup_____?",
            actions: [
                AgentQuickAction(icon: "sparkles", text: "Cloud_", prompt: "Help me set up_ "),
                AgentQuickAction(icon: "calendar", text: "Local", prompt: "Configure my local model "),
            ]
        )
        #expect(GenerativeGreetingService.shouldRetryForQuality(g, expectedActions: 2))
    }

    // MARK: - Legacy JSON back-compat

    @Test("parse falls back to JSON when no tagged lines are present")
    func legacyJSONBackCompat() throws {
        let raw = """
            {
              "greeting": "Soho Delight",
              "subtitle": "Map your next move with a quick win.",
              "actions": [
                {"icon": "sparkles", "text": "Boost", "prompt": "Give me one bold idea for "},
                {"icon": "calendar", "text": "Plan", "prompt": "Sketch tomorrow's plan for "}
              ]
            }
            """
        let result = try GenerativeGreetingService.parse(raw, expectedActions: 2)
        #expect(result.greeting == "Soho Delight")
        #expect(result.actions.count == 2)
        #expect(result.actions[1].icon == "calendar")
    }

    @Test("parse tolerates JSON inside code fences + chatty preamble")
    func legacyJSONWithCodeFence() throws {
        let raw = """
            Sure, here is your greeting:
            ```json
            {
              "greeting": "Test",
              "subtitle": "Pinning the fence-stripper.",
              "actions": [
                {"icon": "sparkles", "text": "Go", "prompt": "Draft a plan for "},
                {"icon": "calendar", "text": "Plan", "prompt": "Sketch a path for "}
              ]
            }
            ```
            """
        let result = try GenerativeGreetingService.parse(raw, expectedActions: 2)
        #expect(result.greeting == "Test")
        #expect(result.actions.count == 2)
    }

    @Test("parse rejects empty + completely malformed input")
    func parseRejectsGarbage() {
        #expect(throws: GenerativeGreetingError.emptyResponse) {
            try GenerativeGreetingService.parse("   \n  ", expectedActions: 2)
        }
        #expect(throws: GenerativeGreetingError.malformedJSON) {
            // Neither tagged lines nor a `{...}` JSON object — must
            // bubble the JSON fallback's error so the caller's retry
            // path knows we never reached a structured payload.
            try GenerativeGreetingService.parse(
                "This is just chatty prose without any structure.",
                expectedActions: 2
            )
        }
    }

    // MARK: - Quality gate predicate

    @Test("quality gate trips on 'Welcome' opener")
    func qualityGateTripsOnWelcome() {
        let g = GenerativeGreeting(
            greeting: "Welcome back",
            subtitle: "Pick a thread to pull next.",
            actions: [
                AgentQuickAction(icon: "sparkles", text: "Boost", prompt: "Give me an idea for "),
                AgentQuickAction(icon: "calendar", text: "Plan", prompt: "Sketch a path for "),
            ]
        )
        #expect(GenerativeGreetingService.shouldRetryForQuality(g, expectedActions: 2))
    }

    @Test("quality gate trips on 'Hello' (case-insensitive)")
    func qualityGateTripsOnHelloCaseInsensitive() {
        let g = GenerativeGreeting(
            greeting: "  hello there friend",
            subtitle: "Test.",
            actions: [
                AgentQuickAction(icon: "sparkles", text: "A", prompt: "x "),
                AgentQuickAction(icon: "calendar", text: "B", prompt: "y "),
            ]
        )
        #expect(GenerativeGreetingService.shouldRetryForQuality(g, expectedActions: 2))
    }

    @Test("quality gate trips on 'Hey there' multi-word prefix")
    func qualityGateTripsOnHeyThere() {
        let g = GenerativeGreeting(
            greeting: "Hey there explorer",
            subtitle: "Test.",
            actions: [
                AgentQuickAction(icon: "sparkles", text: "A", prompt: "x "),
                AgentQuickAction(icon: "calendar", text: "B", prompt: "y "),
            ]
        )
        #expect(GenerativeGreetingService.shouldRetryForQuality(g, expectedActions: 2))
    }

    @Test("quality gate trips when the action count is short")
    func qualityGateTripsOnFewActions() {
        let g = GenerativeGreeting(
            greeting: "Soho Delight",
            subtitle: "Test.",
            actions: [
                AgentQuickAction(icon: "sparkles", text: "Boost", prompt: "Give me an idea for ")
            ]
        )
        #expect(GenerativeGreetingService.shouldRetryForQuality(g, expectedActions: 2))
    }

    @Test("quality gate accepts a clean greeting with the expected actions")
    func qualityGateAcceptsCleanResponse() {
        let g = GenerativeGreeting(
            greeting: "Soho Delight",
            subtitle: "Map your next move.",
            actions: [
                AgentQuickAction(icon: "sparkles", text: "Boost", prompt: "Give me an idea for "),
                AgentQuickAction(icon: "calendar", text: "Plan", prompt: "Sketch a path for "),
            ]
        )
        #expect(!GenerativeGreetingService.shouldRetryForQuality(g, expectedActions: 2))
    }

    // MARK: - Size-class table

    @Test("tiny size class drops to 2 actions / 180 tokens")
    func sizeClassTinyAdaptation() {
        #expect(GenerativeGreetingService.expectedActionCount(for: .tiny) == 2)
        #expect(GenerativeGreetingService.maxTokens(for: .tiny) == 180)
    }

    @Test("normal size class keeps 4 actions / 320 tokens")
    func sizeClassNormalAdaptation() {
        #expect(GenerativeGreetingService.expectedActionCount(for: .normal) == 4)
        #expect(GenerativeGreetingService.maxTokens(for: .normal) == 320)
    }
}
