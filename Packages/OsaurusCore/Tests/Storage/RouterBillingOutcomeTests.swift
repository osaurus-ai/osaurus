//
//  RouterBillingOutcomeTests.swift
//  osaurusTests
//
//  Table-driven coverage for the shared billing-outcome classifier. The same
//  precedence drives both the chat keep/notice decision and the ledger row, so
//  support sees exactly what the user saw.
//

import Testing

@testable import OsaurusCore

@Suite("RouterBillingOutcome.classify")
struct RouterBillingOutcomeTests {

    private struct Case {
        let visible: Bool
        let tools: Bool
        let reasoning: Bool
        let cancelled: Bool
        let errored: Bool
        let expected: RouterBillingOutcome
    }

    @Test func classify_followsPrecedence() {
        let cases: [Case] = [
            // Visible text wins over everything else.
            Case(visible: true, tools: true, reasoning: true, cancelled: true, errored: true, expected: .rendered),
            Case(visible: true, tools: false, reasoning: false, cancelled: false, errored: false, expected: .rendered),
            // Tools beat reasoning/cancel/error when there's no visible text.
            Case(visible: false, tools: true, reasoning: true, cancelled: true, errored: true, expected: .toolOnly),
            // Reasoning-only.
            Case(
                visible: false,
                tools: false,
                reasoning: true,
                cancelled: true,
                errored: true,
                expected: .reasoningOnly
            ),
            // Cancelled beats error.
            Case(visible: false, tools: false, reasoning: false, cancelled: true, errored: true, expected: .cancelled),
            // Error.
            Case(visible: false, tools: false, reasoning: false, cancelled: false, errored: true, expected: .error),
            // Nothing at all — a billed-but-empty turn.
            Case(visible: false, tools: false, reasoning: false, cancelled: false, errored: false, expected: .empty),
        ]

        for c in cases {
            let outcome = RouterBillingOutcome.classify(
                hasVisibleText: c.visible,
                hasToolCalls: c.tools,
                hasReasoning: c.reasoning,
                wasCancelled: c.cancelled,
                hadError: c.errored
            )
            #expect(
                outcome == c.expected,
                "visible=\(c.visible) tools=\(c.tools) reasoning=\(c.reasoning) cancelled=\(c.cancelled) errored=\(c.errored)"
            )
        }
    }
}
