//
//  EvalMatrix.swift
//  OsaurusEvalsKit
//
//  Cross-model scoreboard. Reads a directory of `EvalReport` JSONs
//  (one per suite per model, the shape `osaurus-evals run --out` emits)
//  and folds them into a single matrix: domains down the side, models
//  across the top, `passed/scored` in each cell, plus a per-model perf
//  rollup. Replaces the throwaway `build/evals/aggregate2.py` with a
//  committed, Codable-backed command (`osaurus-evals matrix <dir>`).
//

import Foundation
import OsaurusCore

public struct EvalMatrixDomainCell: Sendable, Codable, Equatable {
    public let passed: Int
    /// passed + failed (skipped / errored excluded — they're "didn't
    /// apply" / "broke", not a quality denominator).
    public let scored: Int
    public let skipped: Int
    public let errored: Int
    /// Skip-reason histogram (reason → count), taken from the first note of
    /// each skipped case (the runner writes the gate reason there, e.g.
    /// "sandbox unavailable: …"). nil when the cell has no skips OR the
    /// contribution predates this field (reasons unrecorded) — so the
    /// compatibility report can distinguish "nothing skipped" (skipped == 0)
    /// from "skipped but why is unknown" (skipped > 0, skipReasons == nil).
    public let skipReasons: [String: Int]?

    public init(
        passed: Int,
        scored: Int,
        skipped: Int,
        errored: Int,
        skipReasons: [String: Int]? = nil
    ) {
        self.passed = passed
        self.scored = scored
        self.skipped = skipped
        self.errored = errored
        self.skipReasons = skipReasons
    }
}

public struct EvalMatrixModelColumn: Sendable, Codable, Equatable {
    public let modelId: String
    public let harness: String?
    public let startedAt: String?
    public let perDomain: [String: EvalMatrixDomainCell]
    public let totalPassed: Int
    public let totalScored: Int
    /// Passed/scored excluding subsystem rows (AppleScript live/liveProof +
    /// live image subagent) — the chat-model attributable column.
    public let chatModelPassed: Int
    public let chatModelScored: Int
    /// Passed/scored for subsystem-only rows (AppleScript-16B + image stack).
    public let subsystemPassed: Int
    public let subsystemScored: Int
    /// Mean decode tok/s across telemetered rows for this model.
    public let meanDecodeTokensPerSecond: Double?
    /// Mean TTFT (ms) across telemetered rows.
    public let meanTtftMs: Double?
    /// Mean wall-clock latency until the first tool action.
    public let meanFirstActionMs: Double?
    /// Share of non-skipped agent-loop rows that reached at least one tool
    /// action. Keeps a fast latency mean from hiding no-action failures.
    public let actionCompletionCoverage: Double?
    /// Median model steps across agent-loop rows.
    public let medianModelSteps: Double?
    /// Share of completed agent-loop transcripts that avoided dedupe replays
    /// and iteration-cap exits.
    public let loopFreeRate: Double?
    /// Mean case wall time across agent-loop rows.
    public let meanAgentLoopWallTimeMs: Double?
    /// Share of file-writing agent-loop rows whose scored workspace outcome
    /// passed.
    public let correctFileDeliveryRate: Double?
    /// Mean lifecycle/discovery/replay calls per agent-loop task.
    public let meanFrictionCalls: Double?
    /// Peak-of-peak physical footprint (MB) across telemetered rows —
    /// the headline RAM number the AGENTS.md gate reads.
    public let peakPhysFootprintMb: Double?
    /// Mean of per-case mean CPU utilization (%) across telemetered rows —
    /// sustained HOST overhead during model-driven cases (GPU compute is not
    /// CPU on Apple silicon).
    public let meanCpuPercent: Double?
    /// Peak-of-peak instantaneous CPU utilization (%) across telemetered rows.
    public let peakCpuPercent: Double?
    /// Mean estimated context tokens per task (prompt + tool schema, summed
    /// across model steps) across telemetered rows — the headline
    /// context-cost number the optimization loop drives down. Deterministic
    /// and provider-independent, so local and frontier columns compare 1:1.
    public let meanPromptTokensPerTask: Double?
    /// Mean estimated total tokens per task (input + output) across rows.
    public let meanTotalTokensPerTask: Double?
    /// Mean FIRST-STEP input estimate across rows that carried context
    /// attribution — the cold-prefill cost per task (what the first-step
    /// optimization axis drives down; the cumulative mean above also moves
    /// with iteration count, this one is pure surface size).
    public let meanFirstStepContextTokens: Double?
    /// Largest mean context contributors across attributed rows, formatted
    /// `name=tokens`, largest first — the "where do the tokens go" line the
    /// plan requires successful cases to surface.
    public let topContextContributors: [String]?
    /// Number of cases whose repeat trials disagreed (`--repeat N` runs) —
    /// the per-model flakiness signal. nil when no row carried trial data
    /// (single-execution runs), 0 when trials ran and all agreed.
    public let flakyCases: Int?
    /// Run provenance for this model's reports (hardware, OS, build, judge,
    /// catalog hash). nil for older reports; carried through so the history
    /// log and the crowdsourced compatibility leaderboard stay attributable.
    public let environment: RunEnvironment?

    public init(
        modelId: String,
        harness: String? = nil,
        startedAt: String?,
        perDomain: [String: EvalMatrixDomainCell],
        totalPassed: Int,
        totalScored: Int,
        chatModelPassed: Int? = nil,
        chatModelScored: Int? = nil,
        subsystemPassed: Int? = nil,
        subsystemScored: Int? = nil,
        meanDecodeTokensPerSecond: Double?,
        meanTtftMs: Double?,
        meanFirstActionMs: Double? = nil,
        actionCompletionCoverage: Double? = nil,
        medianModelSteps: Double? = nil,
        loopFreeRate: Double? = nil,
        meanAgentLoopWallTimeMs: Double? = nil,
        correctFileDeliveryRate: Double? = nil,
        meanFrictionCalls: Double? = nil,
        peakPhysFootprintMb: Double?,
        meanCpuPercent: Double? = nil,
        peakCpuPercent: Double? = nil,
        meanPromptTokensPerTask: Double? = nil,
        meanTotalTokensPerTask: Double? = nil,
        meanFirstStepContextTokens: Double? = nil,
        topContextContributors: [String]? = nil,
        flakyCases: Int? = nil,
        environment: RunEnvironment? = nil
    ) {
        self.modelId = modelId
        self.harness = harness
        self.startedAt = startedAt
        self.perDomain = perDomain
        self.totalPassed = totalPassed
        self.totalScored = totalScored
        self.chatModelPassed = chatModelPassed ?? totalPassed
        self.chatModelScored = chatModelScored ?? totalScored
        self.subsystemPassed = subsystemPassed ?? 0
        self.subsystemScored = subsystemScored ?? 0
        self.meanDecodeTokensPerSecond = meanDecodeTokensPerSecond
        self.meanTtftMs = meanTtftMs
        self.meanFirstActionMs = meanFirstActionMs
        self.actionCompletionCoverage = actionCompletionCoverage
        self.medianModelSteps = medianModelSteps
        self.loopFreeRate = loopFreeRate
        self.meanAgentLoopWallTimeMs = meanAgentLoopWallTimeMs
        self.correctFileDeliveryRate = correctFileDeliveryRate
        self.meanFrictionCalls = meanFrictionCalls
        self.peakPhysFootprintMb = peakPhysFootprintMb
        self.meanCpuPercent = meanCpuPercent
        self.peakCpuPercent = peakCpuPercent
        self.meanPromptTokensPerTask = meanPromptTokensPerTask
        self.meanTotalTokensPerTask = meanTotalTokensPerTask
        self.meanFirstStepContextTokens = meanFirstStepContextTokens
        self.topContextContributors = topContextContributors
        self.flakyCases = flakyCases
        self.environment = environment
    }
}

public struct EvalMatrix: Sendable, Codable, Equatable {
    public let generatedAt: String
    public let domains: [String]
    public let models: [EvalMatrixModelColumn]

    /// Cross-column comparability caveats, mirroring the checks `EvalCompat`
    /// applies to crowdsourced contributions: columns that graded different
    /// case catalogs (mixed denominators), columns with no catalog hash at
    /// all, and columns whose LLM rubrics were graded by the run model
    /// itself. Surfaced in both markdown and console output so a maintainer
    /// scoreboard can't silently mix incomparable columns (the way an early
    /// `reports/SNAPSHOT.md` did).
    public var comparabilityWarnings: [String] {
        var warnings: [String] = []
        let hashed = models.compactMap { col -> (model: String, hash: String)? in
            guard let hash = col.environment?.catalogHash else { return nil }
            return (columnTitle(col), hash)
        }
        if Set(hashed.map(\.hash)).count > 1 {
            let detail = hashed.map { "\($0.model)=\($0.hash)" }.joined(separator: ", ")
            warnings.append(
                "columns graded DIFFERENT case catalogs (\(detail)) — totals mix "
                    + "denominators; only same-catalog columns compare 1:1"
            )
        }
        let unhashed =
            models
            .filter { $0.environment?.catalogHash == nil }
            .map(columnTitle)
        if !unhashed.isEmpty && !hashed.isEmpty {
            warnings.append(
                "no catalog hash for: \(unhashed.joined(separator: ", ")) — "
                    + "comparability with the hashed columns is unverified"
            )
        }
        let selfJudged =
            models
            .filter { $0.environment?.judge == "self-judge" }
            .map(columnTitle)
        if !selfJudged.isEmpty {
            warnings.append(
                "self-judged column(s): \(selfJudged.joined(separator: ", ")) — "
                    + "LLM-rubric rows were graded by the run model itself (weaker grade)"
            )
        }
        let sparseExternal = models.filter { column in
            guard column.harness != nil, column.harness != "osaurus" else { return false }
            return column.environment?.chip == nil
                || column.environment?.osVersion == nil
                || column.meanDecodeTokensPerSecond == nil
                || column.peakPhysFootprintMb == nil
        }.map(columnTitle)
        if !sparseExternal.isEmpty {
            warnings.append(
                "external harness runtime telemetry is incomplete for: "
                    + sparseExternal.joined(separator: ", ")
                    + " — unavailable token/s, RAM, or host fields remain BLOCKED; no values were estimated"
            )
        }
        // Mixed composition profiles: an ablation column must never be read
        // as production. Any profile mix (including profile-vs-none) warns
        // with the exact name@hash so the reader knows which is which.
        let profiled = models.compactMap { col -> String? in
            guard let name = col.environment?.experimentProfile else { return nil }
            let hash = col.environment?.experimentProfileHash.map { "@\($0)" } ?? ""
            return "\(columnTitle(col))=\(name)\(hash)"
        }
        if !profiled.isEmpty && profiled.count < models.count {
            warnings.append(
                "experiment-profile column(s) mixed with production columns "
                    + "(\(profiled.joined(separator: ", "))) — profiled rows composed a "
                    + "DIFFERENT prompt/tool surface"
            )
        } else if Set(models.compactMap { $0.environment?.experimentProfileHash }).count > 1 {
            warnings.append(
                "columns ran DIFFERENT experiment profiles (\(profiled.joined(separator: ", "))) "
                    + "— not an apples-to-apples comparison"
            )
        }
        return warnings
    }

    public func toJSON(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting =
            prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func formatMarkdown() -> String {
        var lines: [String] = []
        lines.append("# Eval Matrix")
        lines.append("")
        lines.append("- Generated: \(generatedAt)")
        lines.append("")
        let header = "| Domain | " + models.map(columnTitle).joined(separator: " | ") + " |"
        let sep = "| --- | " + models.map { _ in "---" }.joined(separator: " | ") + " |"
        lines.append(header)
        lines.append(sep)
        for domain in domains {
            let cells = models.map { col -> String in
                guard let cell = col.perDomain[domain] else { return "—" }
                var s = "\(cell.passed)/\(cell.scored)"
                if cell.skipped > 0 { s += " (skip \(cell.skipped))" }
                if cell.errored > 0 { s += " (err \(cell.errored))" }
                return s
            }
            lines.append("| \(domain) | " + cells.joined(separator: " | ") + " |")
        }
        lines.append(
            "| **total** | "
                + models.map { "**\($0.totalPassed)/\($0.totalScored)**" }.joined(separator: " | ") + " |"
        )
        lines.append(
            "| **chat-model** | "
                + models.map { "\($0.chatModelPassed)/\($0.chatModelScored)" }.joined(separator: " | ") + " |"
        )
        lines.append(
            "| **subsystem** | "
                + models.map { "\($0.subsystemPassed)/\($0.subsystemScored)" }.joined(separator: " | ") + " |"
        )
        lines.append("")
        lines.append("## Performance")
        lines.append("")
        lines.append("| Metric | " + models.map(columnTitle).joined(separator: " | ") + " |")
        lines.append(sep)
        lines.append(
            "| decode tok/s (mean) | "
                + models.map { $0.meanDecodeTokensPerSecond.map { String(format: "%.1f", $0) } ?? "—" }
                .joined(separator: " | ") + " |"
        )
        lines.append(
            "| TTFT ms (mean) | "
                + models.map { $0.meanTtftMs.map { String(format: "%.0f", $0) } ?? "—" }
                .joined(separator: " | ") + " |"
        )
        lines.append(
            "| first action ms (mean) | "
                + models.map { $0.meanFirstActionMs.map { String(format: "%.0f", $0) } ?? "—" }
                .joined(separator: " | ") + " |"
        )
        lines.append(
            "| action completion coverage | "
                + models.map {
                    $0.actionCompletionCoverage.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
                }.joined(separator: " | ") + " |"
        )
        lines.append(
            "| model steps (median) | "
                + models.map { $0.medianModelSteps.map { String(format: "%.1f", $0) } ?? "—" }
                .joined(separator: " | ") + " |"
        )
        lines.append(
            "| loop-free rate | "
                + models.map { $0.loopFreeRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—" }
                .joined(separator: " | ") + " |"
        )
        lines.append(
            "| agent wall ms (mean) | "
                + models.map { $0.meanAgentLoopWallTimeMs.map { String(format: "%.0f", $0) } ?? "—" }
                .joined(separator: " | ") + " |"
        )
        lines.append(
            "| correct file delivery | "
                + models.map {
                    $0.correctFileDeliveryRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
                }.joined(separator: " | ") + " |"
        )
        lines.append(
            "| friction calls/task (mean) | "
                + models.map { $0.meanFrictionCalls.map { String(format: "%.2f", $0) } ?? "—" }
                .joined(separator: " | ") + " |"
        )
        lines.append(
            "| peak RAM MB | "
                + models.map { $0.peakPhysFootprintMb.map { String(format: "%.0f", $0) } ?? "—" }
                .joined(separator: " | ") + " |"
        )
        lines.append(
            "| CPU % (mean) | "
                + models.map { $0.meanCpuPercent.map { String(format: "%.0f", $0) } ?? "—" }
                .joined(separator: " | ") + " |"
        )
        lines.append(
            "| CPU % (peak) | "
                + models.map { $0.peakCpuPercent.map { String(format: "%.0f", $0) } ?? "—" }
                .joined(separator: " | ") + " |"
        )
        lines.append(
            "| ctx tok/task (mean) | "
                + models.map { $0.meanPromptTokensPerTask.map { String(format: "%.0f", $0) } ?? "—" }
                .joined(separator: " | ") + " |"
        )
        lines.append(
            "| total tok/task (mean) | "
                + models.map { $0.meanTotalTokensPerTask.map { String(format: "%.0f", $0) } ?? "—" }
                .joined(separator: " | ") + " |"
        )
        lines.append(
            "| first-step ctx tok (mean) | "
                + models.map { $0.meanFirstStepContextTokens.map { String(format: "%.0f", $0) } ?? "—" }
                .joined(separator: " | ") + " |"
        )
        if models.contains(where: { $0.flakyCases != nil }) {
            lines.append(
                "| flaky cases (repeat trials) | "
                    + models.map { $0.flakyCases.map(String.init) ?? "—" }
                    .joined(separator: " | ") + " |"
            )
        }
        if models.contains(where: { !($0.topContextContributors ?? []).isEmpty }) {
            lines.append("")
            lines.append("## Top Context Contributors")
            lines.append("")
            for col in models {
                guard let top = col.topContextContributors, !top.isEmpty else { continue }
                lines.append("- `\(columnTitle(col))` — \(top.joined(separator: ", "))")
            }
        }
        let warnings = comparabilityWarnings
        if !warnings.isEmpty {
            lines.append("")
            lines.append("## Comparability")
            lines.append("")
            for warning in warnings {
                lines.append("- ⚠ \(warning)")
            }
        }
        let envRows = models.compactMap { col -> String? in
            guard let env = col.environment else { return nil }
            return "- `\(columnTitle(col))` — \(env.summary)"
        }
        if !envRows.isEmpty {
            lines.append("")
            lines.append("## Environment")
            lines.append("")
            lines.append(contentsOf: envRows)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Compact console rendering for the loop's stdout.
    public func formatConsole() -> String {
        var lines = ["eval matrix (\(models.count) model(s)):"]
        for col in models {
            var perf: [String] = []
            if let d = col.meanDecodeTokensPerSecond { perf.append(String(format: "%.1f tok/s", d)) }
            if let s = col.medianModelSteps { perf.append(String(format: "%.1f median steps", s)) }
            if let l = col.loopFreeRate { perf.append(String(format: "%.0f%% loop-free", l * 100)) }
            if let a = col.actionCompletionCoverage {
                perf.append(String(format: "%.0f%% acted", a * 100))
            }
            if let r = col.peakPhysFootprintMb { perf.append(String(format: "%.0fMB", r)) }
            if let c = col.meanCpuPercent { perf.append(String(format: "%.0f%% CPU", c)) }
            if let ctx = col.meanPromptTokensPerTask { perf.append(String(format: "%.0f ctx tok", ctx)) }
            let perfStr = perf.isEmpty ? "" : "  [\(perf.joined(separator: ", "))]"
            lines.append("  \(columnTitle(col)): \(col.totalPassed)/\(col.totalScored)\(perfStr)")
            lines.append(
                "    chat-model: \(col.chatModelPassed)/\(col.chatModelScored)  "
                    + "subsystem: \(col.subsystemPassed)/\(col.subsystemScored)"
            )
        }
        for warning in comparabilityWarnings {
            lines.append("  ⚠ \(warning)")
        }
        return lines.joined(separator: "\n")
    }

    private func shortModel(_ id: String) -> String {
        id.contains("/") ? String(id.split(separator: "/").last ?? Substring(id)) : id
    }

    private func columnTitle(_ column: EvalMatrixModelColumn) -> String {
        guard let harness = column.harness, harness != "osaurus" else {
            return shortModel(column.modelId)
        }
        return "\(shortModel(column.modelId)) [\(harness)]"
    }
}

public enum EvalMatrixBuilder {
    private struct MatrixSample {
        let id: String
        let domain: String
        let outcome: EvalCaseOutcome
        let notes: [String]
        let latencyMs: Double?
        let toolUsage: [ToolUsageStat]?
        let telemetry: EvalCaseTelemetry?
        let context: ContextAttribution?
        let blocker: EvalBlockerReason?
    }

    private static func samples(for row: EvalCaseReport) -> [MatrixSample] {
        if let trials = row.trialSummaries, !trials.isEmpty {
            return trials.map {
                MatrixSample(
                    id: row.id,
                    domain: row.domain,
                    outcome: $0.outcome,
                    notes: $0.notes,
                    latencyMs: $0.latencyMs,
                    toolUsage: $0.toolUsage,
                    telemetry: $0.telemetry,
                    context: $0.context,
                    blocker: $0.blocker
                )
            }
        }
        return [
            MatrixSample(
                id: row.id,
                domain: row.domain,
                outcome: row.outcome,
                notes: row.notes,
                latencyMs: row.latencyMs,
                toolUsage: row.toolUsage,
                telemetry: row.telemetry,
                context: row.context,
                blocker: row.blocker
            )
        ]
    }

    /// True when a case belongs on the subsystem scoreboard (AppleScript-16B
    /// live/liveProof lanes + live image subagent), not the chat-model column.
    public static func isSubsystemCase(id: String, domain: String) -> Bool {
        if domain == "apple_script" {
            let lower = id.lowercased()
            return lower.contains("liveproof") || lower.contains(".live-")
        }
        if domain == "subagent", id.hasPrefix("subagent.image-") {
            return true
        }
        return false
    }

    private static func scoreTotals(for cases: [EvalCaseReport]) -> (passed: Int, scored: Int) {
        let scoredRows = cases.flatMap { samples(for: $0) }.filter {
            $0.outcome == .passed || $0.outcome == .failed
        }
        return (
            scoredRows.filter { $0.outcome == .passed }.count,
            scoredRows.count
        )
    }

    /// Load every file that decodes as an `EvalReport` under `dir`
    /// (recursively). Files that don't decode (diff summaries, matrices,
    /// notes) are silently skipped so the loop can point this at a
    /// timestamped run dir that also holds derived artifacts.
    public static func loadReports(in dir: URL) throws -> [EvalReport] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir) else {
            throw EvalMatrixError.pathNotFound(dir.path)
        }
        let urls: [URL]
        if isDir.boolValue {
            let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil)
            urls = (enumerator?.allObjects as? [URL] ?? [])
                .filter { $0.pathExtension.lowercased() == "json" }
                .sorted { $0.path < $1.path }
        } else {
            urls = [dir]
        }
        let decoder = JSONDecoder()
        var reports: [EvalReport] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                let report = try? decoder.decode(EvalReport.self, from: data),
                !report.cases.isEmpty
            else { continue }
            reports.append(report)
        }
        if reports.isEmpty { throw EvalMatrixError.noReports(dir.path) }
        return reports
    }

    public static func build(from reports: [EvalReport], generatedAt: String? = nil) -> EvalMatrix {
        // Merge every case for the same model across suite files.
        var byModel: [String: [EvalCaseReport]] = [:]
        var startedByModel: [String: String] = [:]
        var envByModel: [String: RunEnvironment] = [:]
        var modelIdByColumn: [String: String] = [:]
        var harnessByColumn: [String: String] = [:]
        for report in reports {
            let harness = report.environment?.harness ?? "osaurus"
            let profile = report.environment?.experimentProfileHash
                ?? report.environment?.experimentProfile
                ?? "production"
            let columnKey = "\(report.modelId)\u{1F}\(harness)\u{1F}\(profile)"
            byModel[columnKey, default: []].append(contentsOf: report.cases)
            modelIdByColumn[columnKey] = report.modelId
            harnessByColumn[columnKey] = harness
            // Keep the earliest startedAt per model as the run stamp.
            if let existing = startedByModel[columnKey] {
                startedByModel[columnKey] = min(existing, report.startedAt)
            } else {
                startedByModel[columnKey] = report.startedAt
            }
            // First non-nil environment per model wins — a single contribution
            // (one machine, one run) shares one env across its suite reports.
            if envByModel[columnKey] == nil, let env = report.environment {
                envByModel[columnKey] = env
            }
        }
        let allDomains = Set(reports.flatMap { $0.cases.map(\.domain) }).sorted()
        let columns = byModel.keys.sorted().map { columnKey -> EvalMatrixModelColumn in
            let cases = byModel[columnKey] ?? []
            let samples = cases.flatMap { Self.samples(for: $0) }
            var perDomain: [String: EvalMatrixDomainCell] = [:]
            for domain in allDomains {
                let rows = samples.filter { $0.domain == domain }
                guard !rows.isEmpty else { continue }
                let skippedRows = rows.filter { $0.outcome == .skipped }
                var skipReasons: [String: Int] = [:]
                for row in skippedRows {
                    let reason =
                        row.blocker.map { "\($0.kind.rawValue): \($0.message)" }
                        ?? row.notes.first
                        ?? "unspecified"
                    skipReasons[reason, default: 0] += 1
                }
                perDomain[domain] = EvalMatrixDomainCell(
                    passed: rows.filter { $0.outcome == .passed }.count,
                    scored: rows.filter { $0.outcome == .passed || $0.outcome == .failed }.count,
                    skipped: skippedRows.count,
                    errored: rows.filter { $0.outcome == .errored }.count,
                    skipReasons: skipReasons.isEmpty ? nil : skipReasons
                )
            }
            let telem = samples.compactMap(\.telemetry).filter { !$0.isEmpty }
            // Context attribution rollup: mean first-step cost + the
            // largest mean contributors across attributed rows.
            let attributed = samples.compactMap(\.context)
            let firstSteps = attributed.compactMap(\.firstStepInputTokens)
            var contributorTotals: [String: Int] = [:]
            var contributorCounts: [String: Int] = [:]
            for a in attributed {
                for s in a.sections {
                    contributorTotals["§\(s.id)", default: 0] += s.tokens
                    contributorCounts["§\(s.id)", default: 0] += 1
                }
                for t in a.tools {
                    contributorTotals["tool:\(t.name)", default: 0] += t.tokens
                    contributorCounts["tool:\(t.name)", default: 0] += 1
                }
            }
            let topContributors = contributorTotals
                .map { (name: $0.key, mean: $0.value / max(1, contributorCounts[$0.key] ?? 1)) }
                .sorted { $0.mean > $1.mean }
                .prefix(6)
                .map { "\($0.name)=\($0.mean)" }
            let decodes = telem.compactMap(\.decodeTokensPerSecond)
            let ttfts = telem.compactMap(\.ttftMs)
            let firstActions = telem.compactMap(\.firstActionMs)
            let rams = telem.compactMap(\.peakPhysFootprintMb)
            let cpus = telem.compactMap(\.meanCpuPercent)
            let promptToks = telem.compactMap(\.promptTokensTotal)
            let totalToks = telem.compactMap(\.totalModelTokens)
            let trialed = cases.filter { $0.trials != nil }
            let agentCases = samples.filter { $0.domain == "agent_loop" }
            let modelSteps = agentCases.compactMap { $0.telemetry?.modelSteps }.sorted()
            let measuredAgentCases = agentCases.filter {
                $0.outcome != .skipped
            }
            let actionCount = measuredAgentCases.filter { row in
                row.telemetry?.firstActionMs != nil
                    || row.toolUsage?.contains(where: { $0.calls > 0 }) == true
            }.count
            let loopFreeCount = measuredAgentCases.filter { row in
                let deduped = row.toolUsage?.reduce(0) { $0 + $1.deduped } ?? 0
                let hitCap = row.notes.contains { $0.contains("exit=iterationCapReached") }
                let oversizedRecovery = row.notes.contains {
                    $0.contains("oversized tool call recoveries:")
                }
                let oversizedExhausted = row.notes.contains {
                    $0.contains("exit=oversizedToolCallExhausted")
                }
                let truncatedToolCall = row.notes.contains {
                    $0.contains("exit=truncatedToolCallExhausted")
                        || $0.contains("truncated tool call recoveries:")
                }
                // External harness adapters cannot report an Osaurus dedupe
                // replay, but they can deterministically identify duplicate
                // executed calls after canonicalizing the arguments.
                let executedDuplicate = row.notes.contains {
                    $0.lowercased().contains("duplicate call(s)")
                }
                let hadAction =
                    row.telemetry?.firstActionMs != nil
                    || row.toolUsage?.contains(where: { $0.calls > 0 }) == true
                let noActionFailure = row.outcome != .passed && !hadAction
                return deduped == 0
                    && !hitCap
                    && !oversizedRecovery
                    && !oversizedExhausted
                    && !truncatedToolCall
                    && !executedDuplicate
                    && !noActionFailure
            }.count
            let fileDeliveryCases = agentCases.filter { row in
                let hasSuccessfulWrite =
                    row.toolUsage?.contains(where: {
                        $0.tool == "file_write" && $0.calls > $0.errors
                    }) == true
                // A failed generation can miss every required file before any
                // write executes. Keep those rows in the denominator instead
                // of reporting perfect delivery from only successful calls.
                let hasScoredFileAssertion = row.notes.contains { note in
                    note.contains("file '")
                        && (note.contains(" contains '") || note.contains(" missing"))
                }
                return hasSuccessfulWrite || hasScoredFileAssertion
            }
            let frictionNames: Set<String> = [
                "todo", "complete", "clarify", "share_artifact",
                "capabilities", "capabilities_discover", "capabilities_load",
            ]
            let frictionCounts: [Int] = agentCases.map { row in
                (row.toolUsage ?? []).reduce(0) { total, stat in
                    total + stat.deduped + (frictionNames.contains(stat.tool) ? stat.calls : 0)
                }
            }
            let agentLatencies = agentCases.compactMap(\.latencyMs)
            let chatCases = cases.filter { !isSubsystemCase(id: $0.id, domain: $0.domain) }
            let subsystemCases = cases.filter { isSubsystemCase(id: $0.id, domain: $0.domain) }
            let chatTotals = scoreTotals(for: chatCases)
            let subsystemTotals = scoreTotals(for: subsystemCases)
            return EvalMatrixModelColumn(
                modelId: modelIdByColumn[columnKey] ?? columnKey,
                harness: harnessByColumn[columnKey],
                startedAt: startedByModel[columnKey],
                perDomain: perDomain,
                totalPassed: samples.filter { $0.outcome == .passed }.count,
                totalScored: samples.filter { $0.outcome == .passed || $0.outcome == .failed }.count,
                chatModelPassed: chatTotals.passed,
                chatModelScored: chatTotals.scored,
                subsystemPassed: subsystemTotals.passed,
                subsystemScored: subsystemTotals.scored,
                meanDecodeTokensPerSecond: decodes.isEmpty ? nil : decodes.reduce(0, +) / Double(decodes.count),
                meanTtftMs: ttfts.isEmpty ? nil : ttfts.reduce(0, +) / Double(ttfts.count),
                meanFirstActionMs: firstActions.isEmpty
                    ? nil : firstActions.reduce(0, +) / Double(firstActions.count),
                actionCompletionCoverage: measuredAgentCases.isEmpty
                    ? nil : Double(actionCount) / Double(measuredAgentCases.count),
                medianModelSteps: median(modelSteps),
                loopFreeRate: measuredAgentCases.isEmpty
                    ? nil : Double(loopFreeCount) / Double(measuredAgentCases.count),
                meanAgentLoopWallTimeMs: agentLatencies.isEmpty
                    ? nil : agentLatencies.reduce(0, +) / Double(agentLatencies.count),
                correctFileDeliveryRate: fileDeliveryCases.isEmpty
                    ? nil
                    : Double(fileDeliveryCases.filter { $0.outcome == .passed }.count)
                        / Double(fileDeliveryCases.count),
                meanFrictionCalls: frictionCounts.isEmpty
                    ? nil : Double(frictionCounts.reduce(0, +)) / Double(frictionCounts.count),
                peakPhysFootprintMb: rams.max(),
                meanCpuPercent: cpus.isEmpty ? nil : cpus.reduce(0, +) / Double(cpus.count),
                peakCpuPercent: telem.compactMap(\.peakCpuPercent).max(),
                meanPromptTokensPerTask: promptToks.isEmpty
                    ? nil : Double(promptToks.reduce(0, +)) / Double(promptToks.count),
                meanTotalTokensPerTask: totalToks.isEmpty
                    ? nil : Double(totalToks.reduce(0, +)) / Double(totalToks.count),
                meanFirstStepContextTokens: firstSteps.isEmpty
                    ? nil : Double(firstSteps.reduce(0, +)) / Double(firstSteps.count),
                topContextContributors: topContributors.isEmpty ? nil : Array(topContributors),
                flakyCases: trialed.isEmpty ? nil : trialed.filter(\.isFlaky).count,
                environment: envByModel[columnKey]
            )
        }
        return EvalMatrix(
            generatedAt: generatedAt ?? isoNow(),
            domains: allDomains,
            models: columns
        )
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    private static func median(_ values: [Int]) -> Double? {
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return Double(values[middle - 1] + values[middle]) / 2
        }
        return Double(values[middle])
    }
}

public enum EvalMatrixError: Error, LocalizedError, Equatable {
    case pathNotFound(String)
    case noReports(String)

    public var errorDescription: String? {
        switch self {
        case .pathNotFound(let p): return "path does not exist: \(p)"
        case .noReports(let p): return "no decodable EvalReport JSONs found under: \(p)"
        }
    }
}
