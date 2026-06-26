//
//  SubagentEvalTests.swift
//  OsaurusEvalsKitTests
//
//  Deterministic, MODEL-FREE coverage for the `subagent` eval lane. Two
//  things are exercised:
//   1. the `SubagentJobEvaluator` scripted lane — a `ScriptedSubagentKind`
//      drives the REAL `SubagentSession` host so the whole lifecycle
//      (resolve -> permission -> handoff -> run -> normalize -> cleanup),
//      the unified recursion guard, and the feed lifecycle run with no
//      tokens, and
//   2. the runner scoring in `EvalRunner.runSubagentCase` (envelope kind,
//      result kind, feed phases, handoff/recursion observations), plus a
//      decode guard over the committed `Suites/Subagent` files asserting
//      every scripted scenario passes deterministically.
//
//  No live model: the spawn/image lanes (which load MLX) are decode-guarded
//  here but only RUN in the suite pass-check for `lane == "scripted"` cases,
//  so a failure here attributes to the host/runner/scoring, never a model.
//

import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

struct SubagentEvalTests {

    private typealias Sub = EvalCase.SubagentExpectations

    // MARK: - Runner harness

    private func scoreScripted(_ exp: Sub, id: String = "subagent.test") async -> EvalCaseReport {
        let testCase = EvalCase(
            id: id,
            domain: "subagent",
            query: "scripted",
            fixtures: EvalCase.Fixtures(),
            expect: EvalCase.Expectations(subagent: exp)
        )
        return await EvalRunner.runSubagentCase(testCase, modelId: "scripted")
    }

    // MARK: - Runner scoring (scripted lane)

    @Test func happyPathScriptedScores() async {
        let report = await scoreScripted(
            Sub(
                lane: "scripted",
                decision: "allow",
                phases: ["running"],
                expectSuccess: true,
                expectEnvelopeKind: "success",
                expectResultKind: "scripted_result",
                summaryContains: ["scripted digest"],
                expectFeedKinds: ["phase"],
                expectPhasesInOrder: ["running"]
            )
        )
        #expect(report.outcome == .passed, "notes: \(report.notes)")
    }

    @Test func policyDeniedMapsToRejected() async {
        let report = await scoreScripted(
            Sub(lane: "scripted", decision: "deny", expectSuccess: false, expectEnvelopeKind: "rejected")
        )
        #expect(report.outcome == .passed, "notes: \(report.notes)")
    }

    @Test func userRefusalMapsToUserDenied() async {
        let report = await scoreScripted(
            Sub(
                lane: "scripted",
                decision: "userDeny",
                expectSuccess: false,
                expectEnvelopeKind: "user_denied"
            )
        )
        #expect(report.outcome == .passed, "notes: \(report.notes)")
    }

    @Test func resolveFailureIsRejectBeforeEvict() async {
        let report = await scoreScripted(
            Sub(
                lane: "scripted",
                resolveFailure: "unavailable",
                expectSuccess: false,
                expectEnvelopeKind: "unavailable"
            )
        )
        #expect(report.outcome == .passed, "notes: \(report.notes)")
    }

    @Test func runFailureMapsToExecutionErrorWithFeed() async {
        let report = await scoreScripted(
            Sub(
                lane: "scripted",
                decision: "allow",
                runFailure: "executionFailed",
                phases: ["running"],
                expectSuccess: false,
                expectEnvelopeKind: "execution_error",
                expectFeedKinds: ["phase"]
            )
        )
        #expect(report.outcome == .passed, "notes: \(report.notes)")
    }

    @Test func handoffWrapsNeedsHandoffKinds() async {
        let report = await scoreScripted(
            Sub(
                lane: "scripted",
                needsHandoff: true,
                decision: "allow",
                expectSuccess: true,
                expectHandoffWrapped: true
            )
        )
        #expect(report.outcome == .passed, "notes: \(report.notes)")
    }

    @Test func recursionGuardRefusesNesting() async {
        let report = await scoreScripted(
            Sub(lane: "scripted", decision: "allow", recurse: true, expectSuccess: true, expectNestedRefused: true)
        )
        #expect(report.outcome == .passed, "notes: \(report.notes)")
    }

    @Test func multiPhaseFeedOrderScores() async {
        let report = await scoreScripted(
            Sub(
                lane: "scripted",
                decision: "allow",
                phases: ["resolving", "running", "restoring"],
                expectSuccess: true,
                expectFeedKinds: ["phase"],
                expectPhasesInOrder: ["resolving", "running", "restoring"]
            )
        )
        #expect(report.outcome == .passed, "notes: \(report.notes)")
    }

    @Test func phaseOrderViolationFails() async {
        // Only `running` is emitted; requiring `resolving` BEFORE it can't hold.
        let report = await scoreScripted(
            Sub(
                lane: "scripted",
                decision: "allow",
                phases: ["running"],
                expectSuccess: true,
                expectPhasesInOrder: ["resolving", "running"]
            )
        )
        #expect(report.outcome == .failed, "notes: \(report.notes)")
    }

    @Test func unknownFailureValueErrors() async {
        let report = await scoreScripted(
            Sub(lane: "scripted", resolveFailure: "bogus", expectEnvelopeKind: "unavailable")
        )
        #expect(report.outcome == .errored, "notes: \(report.notes)")
    }

    @Test func unknownLaneErrors() async {
        let report = await scoreScripted(Sub(lane: "teleport"))
        #expect(report.outcome == .errored, "notes: \(report.notes)")
    }

    // MARK: - Facade transcript shape

    @Test func facadeHappyPathTranscript() async {
        let t = await SubagentJobEvaluator.runScripted(ScriptedSubagentSpec())
        #expect(t.succeeded)
        #expect(t.envelopeKind == "success")
        #expect(t.resultKind == "scripted_result")
        #expect(t.feedPhases == ["running"])
        #expect(t.summary == "scripted digest")
        #expect(t.feedEventKinds.contains("phase"))
    }

    @Test func facadeRecursionTranscript() async {
        let t = await SubagentJobEvaluator.runScripted(
            ScriptedSubagentSpec(recurse: true)
        )
        #expect(t.succeeded)
        #expect(t.nestedRefused == true)
    }

    @Test func facadeHandoffTranscript() async {
        let t = await SubagentJobEvaluator.runScripted(
            ScriptedSubagentSpec(needsHandoff: true)
        )
        #expect(t.succeeded)
        #expect(t.handoffWrapped == true)
    }

    // MARK: - Suite files: decode guard + scripted scenarios pass

    @Test func suiteScenariosDecodeAndScriptedOnesPass() async throws {
        let suiteDir =
            URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OsaurusEvalsKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // OsaurusEvals
            .appendingPathComponent("Suites")
            .appendingPathComponent("Subagent")

        let suite = try EvalSuite.load(from: suiteDir)
        #expect(
            suite.decodeFailures.isEmpty,
            "Subagent case JSON failed to decode: \(suite.decodeFailures)"
        )
        #expect(
            suite.cases.count >= 12,
            "Expected the full Subagent suite; got \(suite.cases.count)"
        )

        // Every scripted (model-free) scenario must pass deterministically.
        // Live lanes (spawn/image) are decode-guarded only — they SKIP without
        // a configured host, which is not a pass/fail signal here.
        var scriptedRan = 0
        for testCase in suite.cases {
            guard testCase.expect.subagent?.lane == "scripted" else { continue }
            let report = await EvalRunner.runSubagentCase(testCase, modelId: "scripted")
            #expect(
                report.outcome == .passed,
                "scripted scenario \(testCase.id) expected to pass; notes: \(report.notes)"
            )
            scriptedRan += 1
        }
        #expect(scriptedRan >= 8, "Expected >=8 deterministic scripted scenarios; ran \(scriptedRan)")
    }
}
