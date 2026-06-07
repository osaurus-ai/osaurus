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

/// Single-case row in the eval report.
public struct EvalCaseReport: Sendable, Codable {
    public let id: String
    public let label: String
    public let domain: String
    /// User-facing query that drove the case. Captured here (rather
    /// than re-derived from the source file) so a JSON report is fully
    /// self-describing — readers don't have to keep the suite around
    /// to interpret a result.
    public let query: String?
    public let outcome: EvalCaseOutcome
    /// Capability-search snapshot for `domain == "capability_search"`
    /// rows. Carries both raw and accepted hits so the
    /// `--report-forensics` CLI flag can compute the H1/H2/H3
    /// disambiguation block without re-running the eval.
    public let capabilitySearch: CapabilitySearchEvaluation?
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
        query: String? = nil,
        outcome: EvalCaseOutcome,
        capabilitySearch: CapabilitySearchEvaluation? = nil,
        notes: [String],
        modelId: String,
        latencyMs: Double?
    ) {
        self.id = id
        self.label = label
        self.domain = domain
        self.query = query
        self.outcome = outcome
        self.capabilitySearch = capabilitySearch
        self.notes = notes
        self.modelId = modelId
        self.latencyMs = latencyMs
    }

    /// Build an early-exit row (decode failure, unknown domain, missing
    /// fixture). The `notes` array is the only diagnostic because we
    /// never ran the case.
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
            query: nil,
            outcome: outcome,
            capabilitySearch: nil,
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
    /// `verbose` adds per-case diagnostics (the case query) — use it
    /// when chasing a specific failure.
    public func formatHumanReadable(verbose: Bool = false) -> String {
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
            let latencyStr = row.latencyMs.map { String(format: "%5.0fms", $0) } ?? "      —"
            lines.append("[\(row.outcome.badge)] \(row.id)  \(latencyStr)")
            for note in row.notes { lines.append("       · \(note)") }
            if verbose { appendVerboseDiagnostics(for: row, into: &lines) }
        }
        return lines.joined(separator: "\n")
    }

    /// Add per-case diagnostic lines (the case query) to `lines`. Pulled
    /// out of `formatHumanReadable` so the verbose-off code path stays a
    /// tight table; call only when `verbose == true`.
    private func appendVerboseDiagnostics(
        for row: EvalCaseReport,
        into lines: inout [String]
    ) {
        if let query = row.query {
            lines.append("       · query: \"\(query)\"")
        }
    }
}
