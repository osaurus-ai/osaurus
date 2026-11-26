//
//  EvalRunnerComputerUseGrounding.swift
//  OsaurusEvalsKit
//
//  `computer_use_grounding`: shows the model the same synthetic screens
//  Computer Use calibrates with and scores point-in-box accuracy under each
//  coordinate frame, plus decode token/s. A row passes when one frame alone
//  clears the hit bar, matches the frame the case pins, and agrees with any
//  frame the bundle itself declares or states. `scriptedFrame` cases answer
//  without a model and prove the screens and scoring for the model's budget.
//

import Foundation
import OsaurusCore

extension EvalRunner {

    static func runComputerUseGroundingCase(
        _ testCase: EvalCase,
        modelId: String
    ) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        guard let exp = testCase.expect.computerUseGrounding else {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .errored,
                notes: ["missing `expect.computerUseGrounding`"],
                modelId: modelId
            )
        }
        if exp.scriptedFrame == nil, scriptedOnly {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .skipped,
                notes: ["live grounding case skipped: OSAURUS_EVALS_SCRIPTED_ONLY=1"],
                modelId: modelId
            )
        }

        let started = Date()
        let report = await ComputerUseGroundingProbe.measure(modelId: modelId, scriptedFrame: exp.scriptedFrame)
        let latency = Date().timeIntervalSince(started) * 1000

        var notes: [String] = []
        var failures: [String] = []
        let budget = report.frameBudget
        notes.append("budget: \(budget.maxLongEdge) px edge, \(budget.maxPixels) px, multiple \(budget.multiple)")
        notes.append(
            "stated frame: "
                + (report.statedFrame.map { "\($0) (\(report.statedSource ?? "?"))" } ?? "none")
        )
        notes.append(
            "hits: "
                + ["pixels", "normalized1000", "normalizedUnit"]
                .map { "\($0)=\(report.hits[$0] ?? 0)/\(report.trials)" }
                .joined(separator: " ")
        )
        notes.append("measured frame: \(report.measuredFrame ?? "none (marks only)")")
        for screen in report.screens {
            let point = screen.point.map { "(\(format($0.x)), \(format($0.y)))" } ?? "none"
            notes.append(
                "screen \(screen.width)×\(screen.height) “\(screen.label)”: point \(point) → "
                    + (screen.hitFrames.isEmpty ? "miss" : "hit " + screen.hitFrames.joined(separator: ","))
                    + (screen.answer.map { " — answered \($0)" } ?? "")
            )
        }
        if !report.errors.isEmpty {
            notes.append("step errors: " + report.errors.joined(separator: " | "))
        }
        let meanSpeed =
            report.decodeTokensPerSecond.isEmpty
            ? nil : report.decodeTokensPerSecond.reduce(0, +) / Double(report.decodeTokensPerSecond.count)
        if let meanSpeed {
            notes.append(String(format: "decode: %.1f tok/s mean over %d steps", meanSpeed, report.decodeTokensPerSecond.count))
        }

        if !report.modelAcceptsImages && exp.scriptedFrame == nil {
            failures.append("model doesn't take images")
        }
        if report.trials == 0 {
            failures.append("no calibration screens fit this budget")
        }
        let minFraction = exp.minHitFraction ?? (2.0 / 3.0)
        if let measured = report.measuredFrame {
            let fraction = Double(report.hits[measured] ?? 0) / Double(max(1, report.trials))
            if fraction + 1e-9 < minFraction {
                failures.append(String(format: "hit fraction %.2f below %.2f", fraction, minFraction))
            }
            if let expected = exp.expectFrame, expected != measured {
                failures.append("measured \(measured), case expects \(expected)")
            }
            if exp.scriptedFrame == nil, let stated = report.statedFrame, report.statedSource != "provider",
                stated != measured
            {
                failures.append("bundle states \(stated) but the model points in \(measured)")
            }
        } else {
            failures.append("no frame cleared the bar; the model would run on marks only")
        }

        let passed = failures.isEmpty
        if !passed { notes.append("attribution: " + failures.joined(separator: "; ")) }
        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: passed ? .passed : .failed,
            notes: notes,
            modelId: modelId,
            latencyMs: latency,
            telemetry: EvalCaseTelemetry(decodeTokensPerSecond: meanSpeed)
        )
    }

    private static func format(_ value: Double) -> String {
        abs(value) >= 10 ? String(Int(value.rounded())) : String(format: "%.3g", value)
    }
}
