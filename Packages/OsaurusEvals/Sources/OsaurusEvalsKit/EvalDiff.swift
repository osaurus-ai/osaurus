//
//  EvalDiff.swift
//  OsaurusEvalsKit
//
//  All-domain before/after comparator — the optimization loop's gating
//  primitive. `AgentLoopRegressionLab` only diffs `agent_loop` rows;
//  this generalizes the same outcome-transition rules across every
//  domain and layers on perf deltas (decode tok/s, TTFT, peak RAM) so a
//  change can be gated on "no regressions" and reviewed for "wins" in
//  one pass.
//
//  Reuses `AgentLoopRegressionReportSet` for loading (its file/dir JSON
//  walk is domain-agnostic); the agent_loop-specific part was only the
//  case indexing, which this file replaces with an all-domain index.
//

import Foundation

/// One case's before→after delta across outcome + perf.
public struct EvalCaseDelta: Sendable, Codable, Equatable {
    public let id: String
    public let domain: String
    public let baselineOutcome: EvalCaseOutcome?
    public let currentOutcome: EvalCaseOutcome?
    public let baselineLatencyMs: Double?
    public let currentLatencyMs: Double?
    public let latencyDeltaMs: Double?
    public let baselineDecodeTps: Double?
    public let currentDecodeTps: Double?
    /// Signed percent change in decode tok/s (positive = faster).
    public let decodeTpsDeltaPct: Double?
    public let baselineTtftMs: Double?
    public let currentTtftMs: Double?
    public let ttftDeltaMs: Double?
    public let baselinePeakRamMb: Double?
    public let currentPeakRamMb: Double?
    public let peakRamDeltaMb: Double?
    /// Estimated context tokens per task (prompt + frozen tool schema,
    /// summed across model steps). A NEGATIVE delta is the optimization-loop
    /// win: same outcome, fewer tokens.
    public let baselinePromptTokens: Int?
    public let currentPromptTokens: Int?
    public let promptTokensDelta: Int?
    /// Signed percent change in context tokens (negative = cheaper).
    public let promptTokensDeltaPct: Double?
    public let notes: [String]

    init(
        baseline: EvalDiff.CaseSnapshot?,
        current: EvalDiff.CaseSnapshot?
    ) {
        id = current?.id ?? baseline?.id ?? "(unknown)"
        domain = current?.domain ?? baseline?.domain ?? "(unknown)"
        baselineOutcome = baseline?.outcome
        currentOutcome = current?.outcome
        baselineLatencyMs = baseline?.latencyMs
        currentLatencyMs = current?.latencyMs
        latencyDeltaMs = EvalDiff.subtract(current?.latencyMs, baseline?.latencyMs)

        baselineDecodeTps = baseline?.telemetry?.decodeTokensPerSecond
        currentDecodeTps = current?.telemetry?.decodeTokensPerSecond
        if let base = baseline?.telemetry?.decodeTokensPerSecond, base > 0,
            let now = current?.telemetry?.decodeTokensPerSecond
        {
            decodeTpsDeltaPct = (now - base) / base * 100
        } else {
            decodeTpsDeltaPct = nil
        }
        baselineTtftMs = baseline?.telemetry?.ttftMs
        currentTtftMs = current?.telemetry?.ttftMs
        ttftDeltaMs = EvalDiff.subtract(current?.telemetry?.ttftMs, baseline?.telemetry?.ttftMs)
        baselinePeakRamMb = baseline?.telemetry?.peakPhysFootprintMb
        currentPeakRamMb = current?.telemetry?.peakPhysFootprintMb
        peakRamDeltaMb = EvalDiff.subtract(
            current?.telemetry?.peakPhysFootprintMb,
            baseline?.telemetry?.peakPhysFootprintMb
        )
        baselinePromptTokens = baseline?.telemetry?.promptTokensTotal
        currentPromptTokens = current?.telemetry?.promptTokensTotal
        if let b = baseline?.telemetry?.promptTokensTotal,
            let c = current?.telemetry?.promptTokensTotal
        {
            promptTokensDelta = c - b
            promptTokensDeltaPct = b > 0 ? Double(c - b) / Double(b) * 100 : nil
        } else {
            promptTokensDelta = nil
            promptTokensDeltaPct = nil
        }
        notes = current?.notes ?? baseline?.notes ?? []
    }
}

public struct EvalDiffDomainCount: Sendable, Codable, Equatable {
    public let domain: String
    public let baselinePassed: Int
    public let baselineTotalScored: Int
    public let currentPassed: Int
    public let currentTotalScored: Int
}

/// Full before/after summary across all domains.
public struct EvalDiffSummary: Sendable, Codable, Equatable {
    public let generatedAt: String
    public let baselineLabel: String
    public let currentLabel: String
    public let baselineModelId: String?
    public let currentModelId: String?
    public let domainCounts: [EvalDiffDomainCount]
    public let regressions: [EvalCaseDelta]
    /// Pass→not-pass flips with repeat-trial flake evidence (either side ran
    /// `--repeat` and its trials DISAGREED, or the current side still passed
    /// some trials). Surfaced for review but NOT blocking — a flip inside a
    /// case's observed flake band is noise, not a regression. Flips with no
    /// trial evidence (single-execution runs) stay in `regressions`.
    public let suspectedFlaky: [EvalCaseDelta]
    public let newFailures: [EvalCaseDelta]
    public let fixed: [EvalCaseDelta]
    public let persistentFailures: [EvalCaseDelta]
    public let newCases: [EvalCaseDelta]
    public let removedCases: [EvalCaseDelta]
    /// Perf movements worth a human glance (not gating by default): a
    /// decode-tps drop or peak-RAM growth beyond the configured margins.
    public let perfWarnings: [String]
    /// Perf wins (decode faster / RAM lower beyond the margins).
    public let perfWins: [String]
    public let warnings: [String]

    /// Outcome regressions are the only hard gate. Perf movements are
    /// advisory — the maintainer decides whether a speed/RAM change is
    /// acceptable (some quality fixes legitimately cost tokens).
    public var hasBlockingRegressions: Bool {
        !regressions.isEmpty || !newFailures.isEmpty
    }

    public func toJSON(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting =
            prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func formatConsole() -> String {
        var lines: [String] = []
        let verdict =
            hasBlockingRegressions
            ? "REGRESSED: \(regressions.count) regression(s), \(newFailures.count) new failing case(s)"
            : "PASS: no blocking regressions"
        lines.append("eval diff — \(verdict)")
        lines.append("  baseline: \(baselineLabel) (\(baselineModelId ?? "?"))")
        lines.append("  current:  \(currentLabel) (\(currentModelId ?? "?"))")
        lines.append("")
        lines.append("  per-domain pass (scored = passed+failed):")
        for dc in domainCounts {
            lines.append(
                "    \(dc.domain.padding(toLength: max(20, dc.domain.count), withPad: " ", startingAt: 0))"
                    + "  \(dc.baselinePassed)/\(dc.baselineTotalScored) -> \(dc.currentPassed)/\(dc.currentTotalScored)"
            )
        }
        appendConsoleDeltaSection("regressions (pass -> not-pass)", regressions, into: &lines)
        appendConsoleDeltaSection(
            "suspected flaky (flip within observed flake band — review, not blocking)",
            suspectedFlaky,
            into: &lines
        )
        appendConsoleDeltaSection("new failing cases", newFailures, into: &lines)
        appendConsoleDeltaSection("fixed (fail/err -> pass)", fixed, into: &lines)
        if !perfWins.isEmpty {
            lines.append("")
            lines.append("  perf wins:")
            for w in perfWins { lines.append("    + \(w)") }
        }
        if !perfWarnings.isEmpty {
            lines.append("")
            lines.append("  perf warnings:")
            for w in perfWarnings { lines.append("    ! \(w)") }
        }
        return lines.joined(separator: "\n")
    }

    private func appendConsoleDeltaSection(
        _ title: String,
        _ rows: [EvalCaseDelta],
        into lines: inout [String]
    ) {
        guard !rows.isEmpty else { return }
        lines.append("")
        lines.append("  \(title):")
        for row in rows {
            let base = row.baselineOutcome?.rawValue ?? "—"
            let now = row.currentOutcome?.rawValue ?? "—"
            lines.append("    \(row.id)  [\(row.domain)]  \(base) -> \(now)")
        }
    }

    public func formatMarkdown() -> String {
        var lines: [String] = []
        let verdict =
            hasBlockingRegressions
            ? "REGRESSED: \(regressions.count) regression(s), \(newFailures.count) new failing case(s)"
            : "PASS: no blocking regressions"
        lines.append("# Eval Diff")
        lines.append("")
        lines.append("- Verdict: \(verdict)")
        lines.append("- Generated: \(generatedAt)")
        lines.append("- Baseline: \(baselineLabel) (\(baselineModelId ?? "?"))")
        lines.append("- Current: \(currentLabel) (\(currentModelId ?? "?"))")
        lines.append("")
        lines.append("## Per-domain pass rate")
        lines.append("")
        lines.append("| Domain | Baseline | Current |")
        lines.append("| --- | ---: | ---: |")
        for dc in domainCounts {
            lines.append(
                "| \(dc.domain) | \(dc.baselinePassed)/\(dc.baselineTotalScored) | "
                    + "\(dc.currentPassed)/\(dc.currentTotalScored) |"
            )
        }
        appendMarkdownDeltaSection("Blocking Regressions", regressions, into: &lines)
        appendMarkdownDeltaSection("Suspected Flaky (non-blocking)", suspectedFlaky, into: &lines)
        appendMarkdownDeltaSection("New Failing Cases", newFailures, into: &lines)
        appendMarkdownDeltaSection("Fixed Cases", fixed, into: &lines)
        appendMarkdownDeltaSection("Persistent Failures", persistentFailures, into: &lines)
        appendMarkdownDeltaSection("Suite Drift", newCases + removedCases, into: &lines)
        if !perfWins.isEmpty || !perfWarnings.isEmpty {
            lines.append("")
            lines.append("## Performance")
            lines.append("")
            for w in perfWins { lines.append("- win: \(w)") }
            for w in perfWarnings { lines.append("- warn: \(w)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func appendMarkdownDeltaSection(
        _ title: String,
        _ rows: [EvalCaseDelta],
        into lines: inout [String]
    ) {
        guard !rows.isEmpty else { return }
        lines.append("")
        lines.append("## \(title)")
        lines.append("")
        lines.append("| Case | Domain | Baseline | Current | Δ decode | Δ peak RAM | Δ ctx tok |")
        lines.append("| --- | --- | --- | --- | ---: | ---: | ---: |")
        for row in rows {
            let base = row.baselineOutcome?.rawValue ?? "missing"
            let now = row.currentOutcome?.rawValue ?? "missing"
            let decode = row.decodeTpsDeltaPct.map { String(format: "%+.0f%%", $0) } ?? "-"
            let ram = row.peakRamDeltaMb.map { String(format: "%+.0fMB", $0) } ?? "-"
            let ctx = row.promptTokensDeltaPct.map { String(format: "%+.0f%%", $0) } ?? "-"
            lines.append(
                "| \(EvalDiff.mdCell(row.id)) | \(row.domain) | \(base) | \(now) | \(decode) | \(ram) | \(ctx) |"
            )
        }
    }
}

public enum EvalDiff {
    /// Margins above which a perf movement is surfaced as a win/warning.
    public struct PerfMargins: Sendable {
        public let decodeTpsPct: Double
        public let peakRamMb: Double
        /// Context-token movement (percent) above which a savings is logged
        /// as a win and a regrowth as a warning. Tighter than the speed
        /// margin because context cost is the metric this loop targets.
        public let promptTokensPct: Double
        public init(decodeTpsPct: Double = 10, peakRamMb: Double = 200, promptTokensPct: Double = 5) {
            self.decodeTpsPct = decodeTpsPct
            self.peakRamMb = peakRamMb
            self.promptTokensPct = promptTokensPct
        }
    }

    struct CaseSnapshot: Sendable {
        let suite: String
        let id: String
        let domain: String
        let outcome: EvalCaseOutcome
        let latencyMs: Double?
        let notes: [String]
        let telemetry: EvalCaseTelemetry?
        /// Repeat-trial evidence (`--repeat N`), nil for single executions.
        let trials: Int?
        let trialsPassed: Int?

        /// Trials disagreed — observed flake.
        var isFlaky: Bool {
            guard let trials, let trialsPassed else { return false }
            return trialsPassed > 0 && trialsPassed < trials
        }
    }

    public static func compare(
        baseline: AgentLoopRegressionReportSet,
        current: AgentLoopRegressionReportSet,
        margins: PerfMargins = PerfMargins(),
        generatedAt: String? = nil
    ) -> EvalDiffSummary {
        let baselineIndex = index(baseline)
        let currentIndex = index(current)

        let baselineIds = Set(baselineIndex.byId.keys)
        let currentIds = Set(currentIndex.byId.keys)
        let commonIds = baselineIds.intersection(currentIds).sorted()
        let currentOnly = currentIds.subtracting(baselineIds).sorted()
        let baselineOnly = baselineIds.subtracting(currentIds).sorted()

        var regressions: [EvalCaseDelta] = []
        var suspectedFlaky: [EvalCaseDelta] = []
        var fixed: [EvalCaseDelta] = []
        var persistentFailures: [EvalCaseDelta] = []
        var newFailures: [EvalCaseDelta] = []
        var newCases: [EvalCaseDelta] = []
        var removedCases: [EvalCaseDelta] = []
        var perfWarnings: [String] = []
        var perfWins: [String] = []

        for id in commonIds {
            let b = baselineIndex.byId[id]
            let c = currentIndex.byId[id]
            let delta = EvalCaseDelta(baseline: b, current: c)
            if isBlockingRegression(baseline: b?.outcome, current: c?.outcome) {
                if hasFlakeEvidence(baseline: b, current: c) {
                    suspectedFlaky.append(delta)
                } else {
                    regressions.append(delta)
                }
            } else if isFixed(baseline: b?.outcome, current: c?.outcome) {
                fixed.append(delta)
            } else if isFailing(b?.outcome) && isFailing(c?.outcome) {
                persistentFailures.append(delta)
            }
            classifyPerf(delta, margins: margins, warnings: &perfWarnings, wins: &perfWins)
        }
        for id in currentOnly {
            let delta = EvalCaseDelta(baseline: nil, current: currentIndex.byId[id])
            if isFailing(currentIndex.byId[id]?.outcome) {
                newFailures.append(delta)
            } else {
                newCases.append(delta)
            }
        }
        for id in baselineOnly {
            removedCases.append(EvalCaseDelta(baseline: baselineIndex.byId[id], current: nil))
        }

        return EvalDiffSummary(
            generatedAt: generatedAt ?? isoNow(),
            baselineLabel: baseline.label,
            currentLabel: current.label,
            baselineModelId: commonModelId(baseline),
            currentModelId: commonModelId(current),
            domainCounts: domainCounts(baselineIndex.cases, currentIndex.cases),
            regressions: regressions,
            suspectedFlaky: suspectedFlaky,
            newFailures: newFailures,
            fixed: fixed,
            persistentFailures: persistentFailures,
            newCases: newCases,
            removedCases: removedCases,
            perfWarnings: perfWarnings.sorted(),
            perfWins: perfWins.sorted(),
            warnings: (baselineIndex.warnings + currentIndex.warnings).sorted()
        )
    }

    // MARK: - Indexing

    private static func index(
        _ set: AgentLoopRegressionReportSet
    ) -> (cases: [CaseSnapshot], byId: [String: CaseSnapshot], warnings: [String]) {
        var cases: [CaseSnapshot] = []
        var byId: [String: CaseSnapshot] = [:]
        var warnings: [String] = []
        for named in set.reports.sorted(by: { $0.name < $1.name }) {
            for row in named.report.cases {
                let snap = CaseSnapshot(
                    suite: named.name,
                    id: row.id,
                    domain: row.domain,
                    outcome: row.outcome,
                    latencyMs: row.latencyMs,
                    notes: row.notes,
                    telemetry: row.telemetry,
                    trials: row.trials,
                    trialsPassed: row.trialsPassed
                )
                cases.append(snap)
                if byId[row.id] != nil {
                    warnings.append("duplicate case id '\(row.id)' across reports; keeping first")
                } else {
                    byId[row.id] = snap
                }
            }
        }
        return (cases, byId, warnings)
    }

    private static func domainCounts(
        _ baseline: [CaseSnapshot],
        _ current: [CaseSnapshot]
    ) -> [EvalDiffDomainCount] {
        let domains = Set(baseline.map(\.domain)).union(current.map(\.domain)).sorted()
        return domains.map { domain in
            let b = baseline.filter { $0.domain == domain }
            let c = current.filter { $0.domain == domain }
            return EvalDiffDomainCount(
                domain: domain,
                baselinePassed: b.filter { $0.outcome == .passed }.count,
                baselineTotalScored: b.filter { $0.outcome == .passed || $0.outcome == .failed }.count,
                currentPassed: c.filter { $0.outcome == .passed }.count,
                currentTotalScored: c.filter { $0.outcome == .passed || $0.outcome == .failed }.count
            )
        }
    }

    // MARK: - Perf classification

    private static func classifyPerf(
        _ delta: EvalCaseDelta,
        margins: PerfMargins,
        warnings: inout [String],
        wins: inout [String]
    ) {
        if let pct = delta.decodeTpsDeltaPct, abs(pct) >= margins.decodeTpsPct {
            let line = String(
                format: "%@: decode %+.0f%% (%.1f -> %.1f tok/s)",
                delta.id,
                pct,
                delta.baselineDecodeTps ?? 0,
                delta.currentDecodeTps ?? 0
            )
            if pct < 0 { warnings.append(line) } else { wins.append(line) }
        }
        if let ram = delta.peakRamDeltaMb, abs(ram) >= margins.peakRamMb {
            let line = String(
                format: "%@: peak RAM %+.0fMB (%.0f -> %.0f)",
                delta.id,
                ram,
                delta.baselinePeakRamMb ?? 0,
                delta.currentPeakRamMb ?? 0
            )
            if ram > 0 { warnings.append(line) } else { wins.append(line) }
        }
        if let pct = delta.promptTokensDeltaPct, abs(pct) >= margins.promptTokensPct {
            let pctStr = String(format: "%+.0f%%", pct)
            let line =
                "\(delta.id): ctx tokens \(pctStr) "
                + "(\(delta.baselinePromptTokens ?? 0) -> \(delta.currentPromptTokens ?? 0))"
            // Fewer context tokens at equal outcome is the win; more is a
            // warning the maintainer reviews against the pass-rate change.
            if pct < 0 { wins.append(line) } else { warnings.append(line) }
        }
    }

    // MARK: - Outcome-transition rules (mirror AgentLoopRegressionLab)

    private static func isBlockingRegression(baseline: EvalCaseOutcome?, current: EvalCaseOutcome?) -> Bool {
        guard let baseline, let current else { return false }
        if baseline == .passed && current != .passed { return true }
        if baseline == .failed && current == .errored { return true }
        if baseline == .skipped && current == .errored { return true }
        return false
    }

    private static func isFixed(baseline: EvalCaseOutcome?, current: EvalCaseOutcome?) -> Bool {
        guard let baseline, let current else { return false }
        return (baseline == .failed || baseline == .errored) && current == .passed
    }

    /// A pass→not-pass flip is downgraded from "blocking regression" to
    /// "suspected flaky" only when repeat trials produced DIRECT flake
    /// evidence: either side's trials disagreed with each other, or the
    /// current side still passed at least one trial. A current side that
    /// failed EVERY one of ≥2 trials is strong evidence of a real
    /// regression and stays blocking, as does any flip with no trial data
    /// (single executions carry no flake information).
    private static func hasFlakeEvidence(
        baseline: CaseSnapshot?,
        current: CaseSnapshot?
    ) -> Bool {
        if baseline?.isFlaky == true { return true }
        if let current, current.isFlaky { return true }
        return false
    }

    private static func isFailing(_ outcome: EvalCaseOutcome?) -> Bool {
        outcome == .failed || outcome == .errored
    }

    private static func commonModelId(_ set: AgentLoopRegressionReportSet) -> String? {
        let unique = Set(set.reports.map(\.report.modelId))
        if unique.count == 1 { return unique.first }
        return unique.isEmpty ? nil : "mixed"
    }

    static func subtract(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b else { return nil }
        return a - b
    }

    static func mdCell(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|")
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
