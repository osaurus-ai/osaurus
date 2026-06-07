//
//  Scorers.swift
//  OsaurusEvalsKit
//
//  Pure-function scorers that take an observed `PreflightEvaluation`
//  and case-side `Expectations`, returning a normalised score in
//  `[0, 1]` plus diagnostic notes for the report.
//
//  Kept as a single file (rather than a `Scorers/` directory) because
//  there are only three small functions and they share helpers — the
//  file-per-scorer split was a YAGNI from the original plan.
//

import Foundation
import OsaurusCore

public enum Scorers {

    // MARK: - Tools

    /// Score the picked tool set against a `mustInclude` / `mustNotInclude`
    /// contract. Each violation costs an equal share of the total budget,
    /// so `mustInclude: [a, b]` with one missing scores `0.5` rather than
    /// `0.0` — partial credit reads more usefully when comparing models.
    /// Returns `nil` when no tool expectations were declared.
    public static func scoreTools(
        observed: PreflightEvaluation,
        expectation: EvalCase.ToolExpectations?
    ) -> (score: Float, notes: [String])? {
        guard let expectation else { return nil }
        let mustInclude = expectation.mustInclude ?? []
        let mustNotInclude = expectation.mustNotInclude ?? []
        let total = mustInclude.count + mustNotInclude.count
        guard total > 0 else { return nil }

        let pickedSet = Set(observed.pickedToolNames)
        var hits = 0
        var notes: [String] = []

        for name in mustInclude {
            if pickedSet.contains(name) {
                hits += 1
            } else {
                notes.append("missing required tool: \(name)")
            }
        }
        for name in mustNotInclude {
            if pickedSet.contains(name) {
                notes.append("forbidden tool was picked: \(name)")
            } else {
                hits += 1
            }
        }

        let score = Float(hits) / Float(total)
        return (score, notes)
    }

    // MARK: - Aggregation

    /// Combine optional component scores into one aggregate. Components
    /// not declared by the case are ignored — a tools-only case scores
    /// 100% on `aggregate` when its single component scores 100%. Pass
    /// threshold defaults to `1.0` (everything must be perfect); cases
    /// that want soft passes can adjust at runner-call time.
    public static func aggregate(
        tools: Float?
    ) -> Float {
        let parts = [tools].compactMap { $0 }
        guard !parts.isEmpty else { return 1.0 }
        return parts.reduce(0, +) / Float(parts.count)
    }
}
