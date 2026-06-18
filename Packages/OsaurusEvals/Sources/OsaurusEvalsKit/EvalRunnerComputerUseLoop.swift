//
//  EvalRunnerComputerUseLoop.swift
//  OsaurusEvalsKit
//
//  Runner for the `computer_use_loop` domain: end-to-end Computer Use
//  evals that drive the real `ComputerUseLoop` with the chosen model
//  against a deterministic in-memory `ScriptedCUDriver`, then score the
//  RESULTING WORLD STATE (field values, toggles, clicks) plus the loop's
//  own telemetry. This is the "can a small local model actually operate
//  the screen" lane — the model call is the only non-deterministic part;
//  perception and actuation are fully scripted, so a failure attributes
//  to the model (planning / targeting / JSON-shape), not to flaky AX.
//

import Foundation
import OsaurusCore

extension EvalRunner {

    /// Model-driven Computer Use evaluator for `domain == "computer_use_loop"`.
    static func runComputerUseLoopCase(
        _ testCase: EvalCase,
        modelId: String
    ) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id

        guard let exp = testCase.expect.computerUseLoop else {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .errored,
                notes: ["missing `expect.computerUseLoop`"],
                modelId: modelId
            )
        }

        // Scripted world + permissive-by-default gate. `autonomous` auto-runs
        // every effect so the case measures the model's planning rather than
        // gate friction; a case can pick a stricter preset to exercise the
        // confirm path (auto-approved here).
        let driver = ScriptedCUDriver(app: exp.app, elements: exp.elements)
        let preset = AutonomyPreset(rawValue: exp.preset ?? "autonomous") ?? .autonomous
        let gate = ComputerUseGate(policy: AutonomyPolicy(globalPreset: preset))
        let feed = ComputerUseFeed(toolCallId: "eval-\(testCase.id)", goal: testCase.query)
        let interrupt = InterruptToken()
        let limits = RunLimits(maxSteps: exp.maxSteps ?? 16, wallClockSeconds: 240)

        let started = Date()
        let result = await ComputerUseLoop.run(
            goal: testCase.query,
            modelId: modelId,
            driver: driver,
            gate: gate,
            feed: feed,
            interrupt: interrupt,
            confirm: { _ in true },
            limits: limits,
            policySummary: "",
            vision: .none,
            sessionId: "eval-cu-\(testCase.id)"
        )
        let latency = Date().timeIntervalSince(started) * 1000

        // Telemetry read-back. Feed events carry the per-step kind breakdown
        // the metrics struct doesn't: `.retry` = invalid `agent_action` shape
        // (the JSON-discipline signal), `.propose` = an action the model
        // committed to, `.act` = a driver call.
        let events = feed.currentEvents()
        let invalidActions = events.filter { $0.kind == .retry }.count
        let proposed = events.filter { $0.kind == .propose }.count
        let acted = events.filter { $0.kind == .act }.count
        let finalValues = await driver.finalValues()
        let verbTrace = await driver.verbTrace()
        let metrics = result.metrics
        let outcomeName = Self.outcomeName(result.outcome)

        var passed = true
        var notes: [String] = []
        func check(_ ok: Bool, pass: String, fail: String) {
            passed = passed && ok
            notes.append(ok ? pass : fail)
        }

        // 1. Outcome shape — did the run end the way the case expects.
        let allowedOutcomes = exp.expectOutcome ?? ["done"]
        check(
            allowedOutcomes.contains(outcomeName),
            pass: "outcome ok: \(outcomeName)",
            fail: "outcome '\(outcomeName)' not in allowed \(allowedOutcomes)"
        )

        // 2. The substantive check — did the world reach the goal state.
        for predicate in exp.successValues ?? [] {
            let value = (finalValues[predicate.id] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let exact = predicate.equals {
                check(
                    value == exact.trimmingCharacters(in: .whitespacesAndNewlines),
                    pass: "value[\(predicate.id)] == '\(exact)'",
                    fail: "value[\(predicate.id)] = '\(value)' != '\(exact)'"
                )
            }
            if let needle = predicate.contains {
                check(
                    value.localizedCaseInsensitiveContains(needle),
                    pass: "value[\(predicate.id)] contains '\(needle)'",
                    fail: "value[\(predicate.id)] = '\(value)' missing '\(needle)'"
                )
            }
        }

        // 3. Click outcomes.
        for id in exp.successClicked ?? [] {
            let clicked = await driver.wasClicked(id)
            check(
                clicked,
                pass: "clicked '\(id)'",
                fail: "never clicked '\(id)'"
            )
        }

        // 3b. Precision / safety — forbidden clicks (e.g. "don't Delete").
        for id in exp.failIfClicked ?? [] {
            let clicked = await driver.wasClicked(id)
            check(
                !clicked,
                pass: "correctly avoided '\(id)'",
                fail: "clicked forbidden '\(id)'"
            )
        }

        // 3c. Read-and-report — the answer the model surfaced in its
        // terminal reason (the only place a pure-read result lives).
        for needle in exp.finalSummaryContains ?? [] {
            check(
                result.outcome.summary.localizedCaseInsensitiveContains(needle),
                pass: "final summary contains '\(needle)'",
                fail: "final summary missing '\(needle)' (got: \(result.outcome.summary))"
            )
        }

        // 4. JSON-discipline ceiling (only scored when set; always reported).
        if let maxInvalid = exp.maxInvalidActions {
            check(
                invalidActions <= maxInvalid,
                pass: "invalidActions ok: \(invalidActions) ≤ \(maxInvalid)",
                fail: "invalidActions \(invalidActions) > \(maxInvalid)"
            )
        }

        // Telemetry summary (always present so a pass is still legible).
        notes.append("outcome: \(result.outcome.summary)")
        notes.append(
            "telemetry: steps=\(metrics.steps) proposed=\(proposed) acted=\(acted) "
                + "verifyChanged=\(metrics.verifyChanged) blocked=\(metrics.blocked) "
                + "confirms=\(metrics.confirmsRequested) invalidActions=\(invalidActions)"
        )
        if let rate = metrics.axResolvableRate {
            notes.append("axResolvableRate: \(String(format: "%.2f", rate)) "
                + "(\(metrics.targetResolveSuccesses)/\(metrics.targetResolveAttempts))")
        }
        notes.append("verbs: [\(verbTrace.joined(separator: ","))]")

        if !passed {
            notes.append(
                "attribution: " + Self.attributeFailure(
                    outcome: result.outcome,
                    invalidActions: invalidActions,
                    metrics: metrics,
                    acted: acted
                )
            )
            notes.append(
                "final values: "
                    + finalValues.keys.sorted()
                    .map { "\($0)='\(finalValues[$0] ?? "")'" }
                    .joined(separator: " ")
            )
        }

        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: passed ? .passed : .failed,
            notes: notes,
            modelId: modelId,
            latencyMs: latency,
            toolUsage: Self.verbUsageStats(verbTrace)
        )
    }

    // MARK: - Helpers

    /// Short, stable name for a `RunOutcome` used in `expectOutcome`
    /// matching and report lines.
    private static func outcomeName(_ outcome: RunOutcome) -> String {
        switch outcome {
        case .done: return "done"
        case .gaveUp: return "gaveUp"
        case .stepCapReached: return "stepCapReached"
        case .deadEnd: return "deadEnd"
        case .interrupted: return "interrupted"
        case .failed: return "failed"
        }
    }

    /// One-line failure attribution so a reader can tell WHY a model failed
    /// without replaying the trace: JSON-shape (re-asks), planning (gave up /
    /// never acted), or targeting (couldn't resolve the elements it picked).
    private static func attributeFailure(
        outcome: RunOutcome,
        invalidActions: Int,
        metrics: ComputerUseRunMetrics,
        acted: Int
    ) -> String {
        if case .gaveUp(let reason) = outcome, reason.localizedCaseInsensitiveContains("valid action") {
            return "JSON-shape — model could not emit a valid agent_action (\(invalidActions) re-asks)."
        }
        if invalidActions >= 3 {
            return "JSON-shape — \(invalidActions) invalid agent_action shapes."
        }
        if case .deadEnd = outcome {
            return "targeting — repeatedly couldn't resolve a chosen target "
                + "(axResolvable \(metrics.targetResolveSuccesses)/\(metrics.targetResolveAttempts))."
        }
        if let rate = metrics.axResolvableRate, rate < 0.5, metrics.targetResolveAttempts >= 2 {
            return "targeting — low target-resolution rate "
                + "(\(metrics.targetResolveSuccesses)/\(metrics.targetResolveAttempts))."
        }
        if acted == 0 {
            return "planning — model never executed an action before the run ended."
        }
        return "planning — acted but didn't reach the goal state within the step budget."
    }

    /// Fold the executed-verb trace into per-verb counters so the suite-wide
    /// usage table surfaces the action mix (type vs click vs observe …) the
    /// same way it does tool calls for `agent_loop`.
    private static func verbUsageStats(_ verbs: [String]) -> [ToolUsageStat]? {
        guard !verbs.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for verb in verbs { counts[verb, default: 0] += 1 }
        return counts.keys.sorted().map {
            ToolUsageStat(tool: $0, calls: counts[$0] ?? 0, errors: 0, deduped: 0)
        }
    }
}
