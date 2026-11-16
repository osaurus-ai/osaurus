//
//  DefaultAgentArgsMatcherTests.swift
//  OsaurusEvalsKitTests
//
//  Pins the DefaultAgent per-call argument scorers: `argsMustContain`
//  (at least one call satisfies the matcher) and its inverse
//  `argsMustNotContain` (no call may satisfy it). The inverse exists for
//  the apply-first contract — `osaurus_config` is legitimately called with
//  `action: apply`, so `mustNotCallTools` cannot express "never `plan`".
//

import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

@Suite
struct DefaultAgentArgsMatcherTests {
    private typealias Matcher = EvalCase.DefaultAgentExpectations.ToolArgsMatcher

    private static func transcript(_ calls: [(String, String)]) -> CapabilityClaimsTranscript {
        CapabilityClaimsTranscript(
            toolCalls: calls.map { .init(name: $0.0, arguments: $0.1) },
            finalText: "done",
            iterations: 2,
            hitIterationCap: false,
            systemPrompt: "system",
            loadedToolNames: ["osaurus_config"],
            error: nil
        )
    }

    @MainActor
    @Test func mustNotContainFailsOnlyWhenEveryPairMatchesOneCall() {
        let planThenApply = Self.transcript([
            ("osaurus_config", "{\"action\":\"plan\",\"yaml\":\"agents:\\n  - name: X\"}"),
            ("osaurus_config", "{\"action\":\"apply\",\"yaml\":\"agents:\\n  - name: X\"}"),
        ])
        let applyOnly = Self.transcript([
            ("osaurus_config", "{\"action\":\"APPLY\",\"yaml\":\"agents:\\n  - name: X\"}")
        ])
        let noPlan = Matcher(tool: "osaurus_config", args: ["action": "plan"])

        let flagged = EvalRunner.scoreArgsMustNotContain(matcher: noPlan, transcript: planThenApply)
        #expect(!flagged.passed)
        #expect(flagged.note.contains("call #1"))

        #expect(EvalRunner.scoreArgsMustNotContain(matcher: noPlan, transcript: applyOnly).passed)

        // Value matching is a case-insensitive substring, like the positive scorer.
        let apply = Matcher(tool: "osaurus_config", args: ["action": "apply"])
        #expect(!EvalRunner.scoreArgsMustNotContain(matcher: apply, transcript: applyOnly).passed)
        #expect(EvalRunner.scoreArgsMustContain(matcher: apply, transcript: applyOnly).passed)

        // Every pair must match on the SAME call: plan+yaml "prune" is
        // not satisfied by a plan call without prune plus an apply call
        // with prune.
        let planPrune = Matcher(tool: "osaurus_config", args: ["action": "plan", "yaml": "prune"])
        let split = Self.transcript([
            ("osaurus_config", "{\"action\":\"plan\",\"yaml\":\"agents: []\"}"),
            ("osaurus_config", "{\"action\":\"apply\",\"yaml\":\"prune: true\"}"),
        ])
        #expect(EvalRunner.scoreArgsMustNotContain(matcher: planPrune, transcript: split).passed)
    }

    @MainActor
    @Test func mustNotContainPassesWhenToolNeverCalledAndSkipsUnparseableArgs() {
        let noPlan = Matcher(tool: "osaurus_config", args: ["action": "plan"])
        #expect(EvalRunner.scoreArgsMustNotContain(matcher: noPlan, transcript: Self.transcript([])).passed)
        #expect(
            EvalRunner.scoreArgsMustNotContain(
                matcher: noPlan,
                transcript: Self.transcript([("osaurus_help", "{\"action\":\"plan\"}")])
            ).passed
        )
        // Garbage arguments can't satisfy a matcher, so they never trip
        // the prohibition — the loop's own arg-validation rows own that.
        #expect(
            EvalRunner.scoreArgsMustNotContain(
                matcher: noPlan,
                transcript: Self.transcript([("osaurus_config", "action: plan")])
            ).passed
        )
    }
}
