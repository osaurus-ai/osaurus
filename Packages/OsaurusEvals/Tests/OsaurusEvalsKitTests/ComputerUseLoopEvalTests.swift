//
//  ComputerUseLoopEvalTests.swift
//  OsaurusEvalsKitTests
//
//  Deterministic, MODEL-FREE coverage for the `computer_use_loop` eval lane.
//  Two things are exercised:
//   1. the upgraded `ScriptedCUDriver` (tier-gated trees, stale-ref click
//      failures + coordinate recovery, scroll-to-reveal, async reveal), driven
//      end-to-end through the real `ComputerUseLoop` via the scripted-model
//      seam, and
//   2. the runner scoring added in Phase 4 (scripted harness, step-efficiency,
//      verb-order subsequence) through `EvalRunner.runComputerUseLoopCase`.
//
//  No live model: the loop is driven by `ComputerUseLoop.scriptedProvider`, so
//  a failure here attributes to the driver/loop/scoring, never to a model.
//

import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

struct ComputerUseLoopEvalTests {

    private typealias Scene = EvalCase.ComputerUseLoopExpectations
    private typealias El = Scene.SceneElement
    private typealias Click = Scene.ClickEffect
    private typealias SetVal = Scene.SetValue

    // MARK: - Harness

    private func runLoop(
        _ driver: ScriptedCUDriver,
        _ actions: [AgentAction],
        maxSteps: Int = 16
    ) async -> ComputerUseRunResult {
        await ComputerUseLoop.run(
            goal: "deterministic eval",
            modelId: "scripted",
            driver: driver,
            gate: ComputerUseGate(policy: AutonomyPolicy(globalPreset: .autonomous)),
            feed: ComputerUseFeed(toolCallId: "t", goal: "deterministic eval"),
            interrupt: InterruptToken(),
            confirm: { _ in true },
            limits: RunLimits(maxSteps: maxSteps, wallClockSeconds: 30),
            vision: .none,
            sessionId: "eval-cu-test",
            nextAction: ComputerUseLoop.scriptedProvider(actions)
        )
    }

    // MARK: - Driver: empty-AX → SOM escalation

    @Test func somOnlyTreeEscalatesFromEmptyAX() async {
        // Every actionable control is SOM-only, so a plain AX capture is empty
        // and the loop must climb ax→som (Screen Recording is granted) before
        // it can see — and click — the Send button.
        let driver = ScriptedCUDriver(
            app: "Electron",
            elements: [
                El(
                    id: "send",
                    role: "button",
                    label: "Send",
                    onClick: Click(setValues: [SetVal(id: "status", value: "sent")]),
                    minTier: "som"
                ),
                El(id: "status", role: "statictext", label: "Status", value: "", minTier: "som"),
            ]
        )
        let result = await runLoop(
            driver,
            [
                AgentAction(verb: .click, target: AgentTarget(describe: "Send"), note: "send it"),
                AgentAction(verb: .done, reason: "sent"),
            ]
        )
        #expect(result.outcome.isSuccess)
        #expect(result.metrics.maxTier == .som)
        let values = await driver.finalValues()
        #expect(values["status"] == "sent")
    }

    // MARK: - Driver: stale-ref click → coordinate fallback

    @Test func staleRefClickRecoversViaCoordinateFallback() async {
        // The button's element-addressed click fails once (stale ref); the
        // loop's coordinate fallback lands and the toggle still flips.
        let driver = ScriptedCUDriver(
            app: "Slack",
            elements: [
                El(
                    id: "mute",
                    role: "switch",
                    label: "Mute",
                    value: "off",
                    onClick: Click(toggle: true),
                    clickFailures: 1
                )
            ]
        )
        let result = await runLoop(
            driver,
            [
                AgentAction(verb: .click, target: AgentTarget(mark: 1), note: "toggle mute"),
                AgentAction(verb: .done, reason: "muted"),
            ]
        )
        #expect(result.outcome.isSuccess)
        #expect(result.metrics.coordinateFallbacks == 1)
        let values = await driver.finalValues()
        #expect(values["mute"] == "on")
        #expect(await driver.wasClicked("mute"))
    }

    // MARK: - Driver: scroll reveals below-the-fold control

    @Test func scrollRevealsOffscreenControl() async {
        let driver = ScriptedCUDriver(
            app: "Notes",
            elements: [
                El(id: "header", role: "statictext", label: "Header", value: "top"),
                El(
                    id: "submit",
                    role: "button",
                    label: "Submit",
                    onClick: Click(setValues: [SetVal(id: "result", value: "submitted")]),
                    revealOnScroll: true
                ),
                El(id: "result", role: "statictext", label: "Result", value: ""),
            ]
        )
        let result = await runLoop(
            driver,
            [
                AgentAction(verb: .scroll, direction: .down, note: "scroll into view"),
                AgentAction(verb: .click, target: AgentTarget(describe: "Submit"), note: "submit"),
                AgentAction(verb: .done, reason: "done"),
            ]
        )
        #expect(result.outcome.isSuccess)
        let values = await driver.finalValues()
        #expect(values["result"] == "submitted")
        let verbs = await driver.verbTrace()
        #expect(verbs.contains("scroll"))
        #expect(await driver.wasClicked("submit"))
    }

    // MARK: - Driver: async reveal needs a wait

    @Test func asyncRevealAppearsAfterWait() async {
        // Clicking "Load" reveals a field only after a couple of captures, so
        // the model must `wait` for it before it can set the value.
        let driver = ScriptedCUDriver(
            app: "Async",
            elements: [
                El(id: "load", role: "button", label: "Load", onClick: Click(reveal: ["field"])),
                El(
                    id: "field",
                    role: "textfield",
                    label: "Async Field",
                    value: "",
                    editable: true,
                    hidden: true,
                    revealAfterCaptures: 2
                ),
            ]
        )
        let result = await runLoop(
            driver,
            [
                AgentAction(verb: .click, target: AgentTarget(describe: "Load"), note: "start load"),
                AgentAction(verb: .wait, seconds: 0, note: "let it load"),
                AgentAction(
                    verb: .setValue,
                    target: AgentTarget(describe: "Async Field"),
                    text: "ready",
                    note: "fill it"
                ),
                AgentAction(verb: .done, reason: "filled"),
            ]
        )
        #expect(result.outcome.isSuccess)
        let values = await driver.finalValues()
        #expect(values["field"] == "ready")
    }

    // MARK: - Runner: scripted harness + scoring

    private func scoreCase(_ scene: Scene, query: String = "q") async -> EvalCaseReport {
        let testCase = EvalCase(
            id: "computer_use_loop.test",
            domain: "computer_use_loop",
            query: query,
            fixtures: EvalCase.Fixtures(),
            expect: EvalCase.Expectations(computerUseLoop: scene)
        )
        return await EvalRunner.runComputerUseLoopCase(testCase, modelId: "scripted")
    }

    @Test func scriptedHarnessScoresWithoutModel() async {
        let scene = Scene(
            app: "Form",
            elements: [
                El(id: "name", role: "textfield", label: "Name", value: "", editable: true),
                El(
                    id: "save",
                    role: "button",
                    label: "Save",
                    onClick: Click(setValues: [SetVal(id: "status", value: "saved")])
                ),
                El(id: "status", role: "statictext", label: "Status", value: ""),
            ],
            expectOutcome: ["done"],
            successValues: [Scene.ValuePredicate(id: "name", equals: "Ada")],
            successClicked: ["save"],
            scriptedActions: [
                AgentAction(verb: .setValue, target: AgentTarget(mark: 1), text: "Ada").argumentsJSON(),
                AgentAction(verb: .click, target: AgentTarget(mark: 2)).argumentsJSON(),
                AgentAction(verb: .done, reason: "saved").argumentsJSON(),
            ]
        )
        let report = await scoreCase(scene)
        #expect(report.outcome == .passed)
    }

    @Test func verbOrderScoringFailsWhenViolated() async {
        let scene = Scene(
            app: "Form",
            elements: [El(id: "go", role: "button", label: "Go")],
            // The trace will be just `click`; requiring scroll BEFORE click can't hold.
            expectVerbsInOrder: ["scroll", "click"],
            scriptedActions: [
                AgentAction(verb: .click, target: AgentTarget(mark: 1)).argumentsJSON(),
                AgentAction(verb: .done, reason: "clicked").argumentsJSON(),
            ]
        )
        let report = await scoreCase(scene)
        #expect(report.outcome == .failed)
    }

    @Test func verbOrderScoringPassesForSubsequence() async {
        let scene = Scene(
            app: "Notes",
            elements: [
                El(id: "header", role: "statictext", label: "Header", value: "top"),
                El(id: "submit", role: "button", label: "Submit", revealOnScroll: true),
            ],
            successClicked: ["submit"],
            expectVerbsInOrder: ["scroll", "click"],
            scriptedActions: [
                AgentAction(verb: .scroll, direction: .down).argumentsJSON(),
                AgentAction(verb: .click, target: AgentTarget(describe: "Submit")).argumentsJSON(),
                AgentAction(verb: .done, reason: "done").argumentsJSON(),
            ]
        )
        let report = await scoreCase(scene)
        #expect(report.outcome == .passed)
    }

    @Test func stepEfficiencyScoringFailsWhenOverBudget() async {
        let scene = Scene(
            app: "Form",
            elements: [El(id: "go", role: "button", label: "Go")],
            expectOutcome: ["done"],
            scoredMaxSteps: 1,
            scriptedActions: [
                AgentAction(verb: .observe).argumentsJSON(),
                AgentAction(verb: .observe).argumentsJSON(),
                AgentAction(verb: .observe).argumentsJSON(),
                AgentAction(verb: .done, reason: "wasteful").argumentsJSON(),
            ]
        )
        let report = await scoreCase(scene)
        #expect(report.outcome == .failed)
    }

    /// The scripted seam makes no model call, so a run spends 0 tokens and the
    /// token budget is satisfied trivially — but the wiring (decode, scoring
    /// composition, and the always-on `tokens=`/`latencyMs=` telemetry line)
    /// has to hold. The over-budget failure path mirrors step-efficiency, which
    /// is already covered; faking a non-zero token count would need a model.
    @Test func tokenBudgetScoredAndReportedForScriptedRun() async {
        let scene = Scene(
            app: "Form",
            elements: [El(id: "go", role: "button", label: "Go")],
            expectOutcome: ["done"],
            successClicked: ["go"],
            scoredMaxModelTokens: 0,
            scriptedActions: [
                AgentAction(verb: .click, target: AgentTarget(mark: 1)).argumentsJSON(),
                AgentAction(verb: .done, reason: "clicked").argumentsJSON(),
            ]
        )
        let report = await scoreCase(scene)
        #expect(report.outcome == .passed)
        #expect(report.notes.contains { $0.contains("tokens ok: 0 ≤ 0") })
        #expect(report.notes.contains { $0.contains("tokens=0") })
    }

    // MARK: - Suite files: decode guard + scripted scenarios pass

    @Test func suiteScenariosDecodeAndScriptedOnesPass() async throws {
        let suiteDir =
            URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OsaurusEvalsKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // OsaurusEvals
            .appendingPathComponent("Suites")
            .appendingPathComponent("ComputerUseLoop")

        let suite = try EvalSuite.load(from: suiteDir)
        #expect(
            suite.decodeFailures.isEmpty,
            "ComputerUseLoop scene JSON failed to decode: \(suite.decodeFailures)"
        )
        #expect(suite.cases.count >= 11, "Expected the full ComputerUseLoop suite; got \(suite.cases.count)")

        // Every scenario that ships a scripted model must pass deterministically
        // (no live model). Model-driven scenarios are only decode-guarded here.
        var scriptedRan = 0
        for testCase in suite.cases {
            guard let scene = testCase.expect.computerUseLoop,
                let scripted = scene.scriptedActions, !scripted.isEmpty
            else { continue }
            let report = await EvalRunner.runComputerUseLoopCase(testCase, modelId: "scripted")
            #expect(
                report.outcome == .passed,
                "scripted scenario \(testCase.id) expected to pass; notes: \(report.notes)"
            )
            scriptedRan += 1
        }
        #expect(scriptedRan >= 4, "Expected ≥4 deterministic scripted scenarios; ran \(scriptedRan)")
    }
}
