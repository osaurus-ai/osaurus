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

    // MARK: - computer_use lane (scripted driver, model-free)

    private typealias CULElement = EvalCase.ComputerUseLoopExpectations.SceneElement
    private typealias CULClick = EvalCase.ComputerUseLoopExpectations.ClickEffect

    /// A scripted `click` + `done` driven through the REAL computer_use host
    /// (`SubagentSession` → `ComputerUseKind` eval seam → `ComputerUseLoop`)
    /// maps `done` → a `success` / `computer_use` envelope AND mutates the
    /// injected world (the switch flips on, the control is clicked). This is the
    /// host-lane analogue of the `computer_use_loop` scripted-driver tests: no
    /// model, no desktop — a failure attributes to the seam/host/loop.
    @Test func computerUseScriptedToggleSucceedsAndMutatesWorld() async {
        let driver = ScriptedCUDriver(
            app: "Settings",
            elements: [
                CULElement(
                    id: "nightshift",
                    role: "switch",
                    label: "Night Shift",
                    value: "off",
                    onClick: CULClick(toggle: true)
                )
            ]
        )
        let transcript = await SubagentJobEvaluator.runComputerUse(
            goal: "turn on Night Shift",
            modelId: "scripted",
            driver: driver,
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            scriptedActions: [
                AgentAction(verb: .click, target: AgentTarget(mark: 1), note: "toggle").argumentsJSON(),
                AgentAction(verb: .done, reason: "Night Shift on").argumentsJSON(),
            ],
            maxSteps: 6
        )
        #expect(transcript.tool == "computer_use")
        #expect(
            transcript.succeeded,
            "expected success; got \(transcript.envelopeKind) err=\(transcript.error ?? "-")"
        )
        #expect(transcript.envelopeKind == "success")
        #expect(transcript.resultKind == "computer_use")
        let values = await driver.finalValues()
        #expect(values["nightshift"] == "on")
        #expect(await driver.wasClicked("nightshift"))
    }

    /// A scripted `give_up` must surface as a non-retryable `execution_error`
    /// envelope (NOT success) and must never click the control — the host's
    /// non-completion mapping (`gaveUp → executionFailed`), model-free.
    @Test func computerUseScriptedGiveUpMapsToExecutionError() async {
        let driver = ScriptedCUDriver(
            app: "Messages",
            elements: [CULElement(id: "send", role: "button", label: "Send")]
        )
        let transcript = await SubagentJobEvaluator.runComputerUse(
            goal: "export the conversation to PDF",
            modelId: "scripted",
            driver: driver,
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            scriptedActions: [
                AgentAction(verb: .giveUp, reason: "no control can export to PDF").argumentsJSON()
            ],
            maxSteps: 4
        )
        #expect(!transcript.succeeded)
        #expect(transcript.envelopeKind == "execution_error")
        #expect(!(await driver.wasClicked("send")))
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

        // Every model-free scenario must pass deterministically: the `scripted`
        // host lane AND the `computer_use` cases that ship `scriptedActions`
        // (driven by the in-memory `ScriptedCUDriver`, no model). Live lanes
        // (spawn/image, model-driven computer_use) are
        // decode-guarded only — they SKIP without a configured host, which is
        // not a pass/fail signal here.
        func isModelFree(_ exp: EvalCase.SubagentExpectations) -> Bool {
            switch exp.lane {
            case "scripted": return true
            case "computer_use": return !(exp.scriptedActions?.isEmpty ?? true)
            default: return false
            }
        }
        var scriptedRan = 0
        var cuScriptedRan = 0
        for testCase in suite.cases {
            guard let exp = testCase.expect.subagent, isModelFree(exp) else { continue }
            let report = await EvalRunner.runSubagentCase(testCase, modelId: "scripted")
            #expect(
                report.outcome == .passed,
                "model-free scenario \(testCase.id) expected to pass; notes: \(report.notes)"
            )
            if exp.lane == "computer_use" { cuScriptedRan += 1 } else { scriptedRan += 1 }
        }
        #expect(scriptedRan >= 8, "Expected >=8 deterministic scripted scenarios; ran \(scriptedRan)")
        #expect(
            cuScriptedRan >= 2,
            "Expected >=2 deterministic scripted computer_use scenarios; ran \(cuScriptedRan)"
        )
    }
}
