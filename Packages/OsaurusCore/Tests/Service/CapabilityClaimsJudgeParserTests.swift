//
//  CapabilityClaimsJudgeParserTests.swift
//  osaurusTests
//
//  Regression tests for `CapabilityClaimsEvaluator.parseVerdicts`, the
//  hardened judge-output parser. The original parser brace-counted the
//  first `{...}` and blanket-failed the whole case on any mismatch, so a
//  fenced block, a brace inside a `reason`, a bare array, or a short reply
//  zeroed grades the judge actually produced. These tests lock in the
//  graceful-degradation ladder so a small self-judging model still scores.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct CapabilityClaimsJudgeParserTests {

    private func verdicts(_ raw: String, expected: Int) -> [CapabilityClaimsJudgement]? {
        CapabilityClaimsEvaluator.parseVerdicts(raw, expected: expected)
    }

    // MARK: - Happy path

    @Test func parsesCleanEnvelope() {
        let raw = #"{"verdicts":[{"pass":true,"reason":"ok"},{"pass":false,"reason":"no"}]}"#
        let result = verdicts(raw, expected: 2)
        #expect(result?.count == 2)
        #expect(result?[0].pass == true)
        #expect(result?[0].reason == "ok")
        #expect(result?[1].pass == false)
    }

    @Test func parsesEnvelopeWrappedInProse() {
        let raw = """
            Sure, here is my assessment of the reply:
            {"verdicts":[{"pass":true,"reason":"states it has the tool"}]}
            Let me know if you need more detail.
            """
        let result = verdicts(raw, expected: 1)
        #expect(result?.count == 1)
        #expect(result?[0].pass == true)
    }

    @Test func parsesFencedJSONBlock() {
        let raw = """
            ```json
            {"verdicts":[{"pass":true,"reason":"a"},{"pass":true,"reason":"b"}]}
            ```
            """
        let result = verdicts(raw, expected: 2)
        #expect(result?.count == 2)
        #expect(result?.allSatisfy { $0.pass } == true)
    }

    // MARK: - String-aware brace matching

    @Test func toleratesBraceInsideReasonString() {
        // A naive brace-counter closes early at the `}` inside the reason.
        let raw = #"{"verdicts":[{"pass":false,"reason":"missing closing } in answer"}]}"#
        let result = verdicts(raw, expected: 1)
        #expect(result?.count == 1)
        #expect(result?[0].pass == false)
        #expect(result?[0].reason.contains("}") == true)
    }

    @Test func toleratesEscapedQuoteInsideReason() {
        let raw = #"{"verdicts":[{"pass":true,"reason":"said \"yes I can\" clearly"}]}"#
        let result = verdicts(raw, expected: 1)
        #expect(result?.count == 1)
        #expect(result?[0].pass == true)
        #expect(result?[0].reason.contains("yes I can") == true)
    }

    // MARK: - Alternative shapes

    @Test func parsesBareArray() {
        let raw = #"[{"pass":true,"reason":"a"},{"pass":false,"reason":"b"}]"#
        let result = verdicts(raw, expected: 2)
        #expect(result?.count == 2)
        #expect(result?[0].pass == true)
        #expect(result?[1].pass == false)
    }

    @Test func parsesSingleObjectForSingleCondition() {
        let raw = #"{"pass":true,"reason":"satisfied"}"#
        let result = verdicts(raw, expected: 1)
        #expect(result?.count == 1)
        #expect(result?[0].pass == true)
    }

    @Test func toleratesBooleanishValues() {
        let raw = #"{"verdicts":[{"pass":"yes","reason":"a"},{"pass":1,"reason":"b"},{"pass":"no","reason":"c"}]}"#
        let result = verdicts(raw, expected: 3)
        #expect(result?[0].pass == true)
        #expect(result?[1].pass == true)
        #expect(result?[2].pass == false)
    }

    // MARK: - Graceful degradation (the core W2 fix)

    @Test func shortfallGradesReturnedVerdictsAndMarksRest() {
        // Judge graded only 2 of 3 conditions: keep the 2, mark #3 ungraded
        // instead of zeroing all three.
        let raw = #"{"verdicts":[{"pass":true,"reason":"a"},{"pass":true,"reason":"b"}]}"#
        let result = verdicts(raw, expected: 3)
        #expect(result?.count == 3)
        #expect(result?[0].pass == true)
        #expect(result?[1].pass == true)
        #expect(result?[2].pass == false)
        #expect(result?[2].reason.contains("not graded") == true)
    }

    @Test func overflowTruncatesToExpected() {
        let raw = #"{"verdicts":[{"pass":true,"reason":"a"},{"pass":true,"reason":"b"},{"pass":true,"reason":"c"}]}"#
        let result = verdicts(raw, expected: 2)
        #expect(result?.count == 2)
    }

    @Test func prefersFragmentMatchingExpectedCount() {
        // A stray single-verdict object precedes the real full envelope;
        // the parser should prefer the count-matching fragment.
        let raw = """
            note: {"pass":true,"reason":"stray"}
            {"verdicts":[{"pass":false,"reason":"x"},{"pass":true,"reason":"y"}]}
            """
        let result = verdicts(raw, expected: 2)
        #expect(result?.count == 2)
        #expect(result?[0].pass == false)
        #expect(result?[1].pass == true)
    }

    // MARK: - Hard failures (must still be nil so the case fails honestly)

    @Test func returnsNilWhenNoJSON() {
        #expect(verdicts("I think the answer is fine, no JSON here.", expected: 2) == nil)
    }

    @Test func returnsNilForEmptyVerdictArray() {
        #expect(verdicts(#"{"verdicts":[]}"#, expected: 2) == nil)
    }

    @Test func returnsEmptyForZeroExpected() {
        #expect(verdicts(#"{"verdicts":[]}"#, expected: 0)?.isEmpty == true)
    }
}
