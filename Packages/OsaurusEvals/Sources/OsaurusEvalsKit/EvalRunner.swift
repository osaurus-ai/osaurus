//
//  EvalRunner.swift
//  OsaurusEvalsKit
//
//  Orchestrates one suite run: applies the model selection, walks each
//  case sequentially (avoids tripping the CoreModelService circuit
//  breaker), and assembles an `EvalReport`.
//
//  Cases run on the main actor — `PreflightEvaluator.evaluate` is
//  main-actor-isolated because the underlying registry / agent /
//  plugin manager state is. Sequencing keeps the state guarantees
//  simple and matches how preflight runs in the actual chat path.
//

import Foundation
import OsaurusCore

@MainActor
public enum EvalRunner {

    /// Run every case in `suite`, one at a time, and produce a report.
    /// `filter` is a substring that must appear in `case.id` for the
    /// case to run — the CLI exposes it via `--filter` so a contributor
    /// debugging a single case doesn't burn tokens on the whole suite.
    public static func run(
        suite: EvalSuite,
        model: ModelSelection,
        filter: String? = nil
    ) async -> EvalReport {
        // The CLI is its own process — it has to scan + dlopen every
        // installed plugin manually before preflight can see plugin
        // tools (the host app does this in AppDelegate). Without it
        // every `requirePlugins` case skips with "missing plugins" no
        // matter what's actually installed on disk.
        await PreflightEvaluator.loadInstalledPlugins()

        let modelLabel = ModelOverride.describe(model)
        let startedAt = isoNow()
        var rows: [EvalCaseReport] = []

        // Surface decode failures up-front as `errored` rows so a
        // contributor with a typo sees the file name in the report
        // instead of silently losing one case.
        for failure in suite.decodeFailures {
            rows.append(
                EvalCaseReport.terminal(
                    id: failure.filename,
                    label: failure.filename,
                    domain: "(unknown)",
                    outcome: .errored,
                    notes: ["decode failure: \(failure.error)"],
                    modelId: modelLabel
                )
            )
        }

        await ModelOverride.withSelection(model) {
            for testCase in suite.cases {
                if let filter, !testCase.id.contains(filter) { continue }
                let row = await runOne(testCase, modelId: modelLabel)
                rows.append(row)
            }
        }

        return EvalReport(modelId: modelLabel, startedAt: startedAt, cases: rows)
    }

    // MARK: - Per-case

    private static func runOne(_ testCase: EvalCase, modelId: String) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id

        // Today the only domain is preflight. New domains add a
        // `case` arm here and stay separate top-level functions —
        // mixing them into one runner gets messy fast.
        guard testCase.domain == "preflight" else {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .errored,
                notes: ["unknown domain: \(testCase.domain)"],
                modelId: modelId
            )
        }

        // Skip cases whose required plugins aren't installed locally.
        // We check before calling preflight so the LLM doesn't burn
        // a generation just to reveal a fixture mismatch.
        if let required = testCase.fixtures.requirePlugins, !required.isEmpty {
            let installed = PreflightEvaluator.installedPluginIds()
            let missing = required.filter { !installed.contains($0) }
            if !missing.isEmpty {
                return .terminal(
                    id: testCase.id,
                    label: label,
                    domain: testCase.domain,
                    outcome: .skipped,
                    notes: ["missing plugins: \(missing.joined(separator: ", "))"],
                    modelId: modelId
                )
            }
        }

        // `EvalCase.PreflightMode` mirrors `PreflightSearchMode` raw
        // values 1:1 (off / narrow / balanced / wide); the rawValue
        // bridge keeps the enums decoupled without a hand-rolled
        // mapping function.
        let mode =
            PreflightSearchMode(
                rawValue: (testCase.fixtures.preflightMode ?? .balanced).rawValue
            ) ?? .balanced
        let observed = await PreflightEvaluator.evaluate(query: testCase.query, mode: mode)

        let toolResult = Scorers.scoreTools(observed: observed, expectation: testCase.expect.tools)
        let companionResult = Scorers.scoreCompanions(
            observed: observed,
            expectation: testCase.expect.companions
        )
        let aggregate = Scorers.aggregate(
            tools: toolResult?.score,
            companions: companionResult?.score
        )
        let score = EvalCaseScore(
            aggregate: aggregate,
            tools: toolResult?.score,
            companions: companionResult?.score
        )
        let notes = (toolResult?.notes ?? []) + (companionResult?.notes ?? [])
        let outcome: EvalCaseOutcome = aggregate >= 1.0 ? .passed : .failed

        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: outcome,
            score: score,
            observed: observed,
            notes: notes,
            modelId: modelId,
            latencyMs: observed.latencyMs
        )
    }

    // MARK: - Helpers

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
