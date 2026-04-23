//
//  EvalReport.swift
//  OsaurusEvalsKit
//
//  Result types emitted by `EvalRunner`. Codable so the CLI can dump
//  a machine-readable report (`--out report.json`) for downstream
//  baselining + scoreboard work; `formatHumanReadable` is what gets
//  printed to stdout for interactive runs.
//

import Foundation
import OsaurusCore

/// Outcome bucket for one case. `skipped` exists so a missing local
/// fixture (e.g. plugin not installed) reads as "didn't apply" rather
/// than "regressed" — an important distinction when sharing reports
/// across machines with different installs.
public enum EvalCaseOutcome: String, Sendable, Codable {
    case passed
    case failed
    case skipped
    case errored

    /// Fixed-width 4-char display tag — kept on the enum so any future
    /// surface (HTML report, CI annotation, etc.) gets the same labels.
    public var badge: String {
        switch self {
        case .passed: return "PASS"
        case .failed: return "FAIL"
        case .skipped: return "SKIP"
        case .errored: return "ERR "
        }
    }
}

/// Per-case scoring breakdown. Each component is a `Float` in `[0, 1]`
/// (component absent → `nil`), plus an aggregate `score`. Cases without
/// any expectations score `1.0` — pure smoke tests that pass as long
/// as preflight didn't throw.
public struct EvalCaseScore: Sendable, Codable {
    public let aggregate: Float
    public let tools: Float?
    public let companions: Float?

    public init(aggregate: Float, tools: Float?, companions: Float?) {
        self.aggregate = aggregate
        self.tools = tools
        self.companions = companions
    }
}

/// Single-case row in the eval report.
public struct EvalCaseReport: Sendable, Codable {
    public let id: String
    public let label: String
    public let domain: String
    public let outcome: EvalCaseOutcome
    public let score: EvalCaseScore?
    /// Preflight snapshot we ran the scorers against. `nil` for
    /// `skipped` / `errored` outcomes.
    public let observed: PreflightEvaluation?
    /// One-line per-component diagnostic — populated for `failed` and
    /// `errored` so a glance at the report tells you WHAT broke without
    /// rerunning. Empty for clean passes.
    public let notes: [String]
    public let modelId: String
    public let latencyMs: Double?

    public init(
        id: String,
        label: String,
        domain: String,
        outcome: EvalCaseOutcome,
        score: EvalCaseScore?,
        observed: PreflightEvaluation?,
        notes: [String],
        modelId: String,
        latencyMs: Double?
    ) {
        self.id = id
        self.label = label
        self.domain = domain
        self.outcome = outcome
        self.score = score
        self.observed = observed
        self.notes = notes
        self.modelId = modelId
        self.latencyMs = latencyMs
    }

    /// Build an early-exit row (decode failure, unknown domain, missing
    /// fixture). All scoring fields are nil because we never invoked
    /// preflight — the `notes` array is the only diagnostic.
    public static func terminal(
        id: String,
        label: String,
        domain: String,
        outcome: EvalCaseOutcome,
        notes: [String],
        modelId: String
    ) -> EvalCaseReport {
        EvalCaseReport(
            id: id,
            label: label,
            domain: domain,
            outcome: outcome,
            score: nil,
            observed: nil,
            notes: notes,
            modelId: modelId,
            latencyMs: nil
        )
    }
}

/// Aggregated report for one runner invocation. Carries every case row
/// plus run-level metadata (which model, when, summary counts).
public struct EvalReport: Sendable, Codable {
    public let modelId: String
    /// ISO-8601 timestamp of when the runner started. Captured here so
    /// per-model scoreboards can stack reports without name collisions.
    public let startedAt: String
    public let cases: [EvalCaseReport]

    public var counts: Counts { Counts(cases: cases) }

    public init(modelId: String, startedAt: String, cases: [EvalCaseReport]) {
        self.modelId = modelId
        self.startedAt = startedAt
        self.cases = cases
    }

    public struct Counts: Sendable, Codable {
        public let total: Int
        public let passed: Int
        public let failed: Int
        public let skipped: Int
        public let errored: Int

        public init(cases: [EvalCaseReport]) {
            total = cases.count
            passed = cases.filter { $0.outcome == .passed }.count
            failed = cases.filter { $0.outcome == .failed }.count
            skipped = cases.filter { $0.outcome == .skipped }.count
            errored = cases.filter { $0.outcome == .errored }.count
        }
    }

    // MARK: - Output

    public func toJSON(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting =
            prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Human-readable table — what the CLI prints to stdout. Compact
    /// enough to scan a 6-case run in a single terminal screen.
    public func formatHumanReadable() -> String {
        var lines: [String] = []
        lines.append("Eval report")
        lines.append("  model:     \(modelId)")
        lines.append("  startedAt: \(startedAt)")
        let c = counts
        lines.append(
            "  totals:    \(c.total) total · \(c.passed) passed · \(c.failed) failed · "
                + "\(c.skipped) skipped · \(c.errored) errored"
        )
        lines.append("")
        for row in cases {
            let scoreStr = row.score.map { String(format: "%.2f", $0.aggregate) } ?? "—"
            let latencyStr = row.latencyMs.map { String(format: "%5.0fms", $0) } ?? "      —"
            lines.append("[\(row.outcome.badge)] \(row.id)  score=\(scoreStr)  \(latencyStr)")
            for note in row.notes { lines.append("       · \(note)") }
        }
        return lines.joined(separator: "\n")
    }
}
