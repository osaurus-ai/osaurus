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

public struct EvalMatrixDomainCell: Sendable, Codable, Equatable {
    public let passed: Int
    /// passed + failed (skipped / errored excluded — they're "didn't
    /// apply" / "broke", not a quality denominator).
    public let scored: Int
    public let skipped: Int
    public let errored: Int
}

public struct EvalMatrixModelColumn: Sendable, Codable, Equatable {
    public let modelId: String
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
        peakPhysFootprintMb: Double?,
        meanCpuPercent: Double? = nil,
        peakCpuPercent: Double? = nil,
        meanPromptTokensPerTask: Double? = nil,
        meanTotalTokensPerTask: Double? = nil,
        flakyCases: Int? = nil,
        environment: RunEnvironment? = nil
    ) {
        self.modelId = modelId
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
        self.peakPhysFootprintMb = peakPhysFootprintMb
        self.meanCpuPercent = meanCpuPercent
        self.peakCpuPercent = peakCpuPercent
        self.meanPromptTokensPerTask = meanPromptTokensPerTask
        self.meanTotalTokensPerTask = meanTotalTokensPerTask
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
            return (shortModel(col.modelId), hash)
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
            .map { shortModel($0.modelId) }
        if !unhashed.isEmpty && !hashed.isEmpty {
            warnings.append(
                "no catalog hash for: \(unhashed.joined(separator: ", ")) — "
                    + "comparability with the hashed columns is unverified"
            )
        }
        let selfJudged =
            models
            .filter { $0.environment?.judge == "self-judge" }
            .map { shortModel($0.modelId) }
        if !selfJudged.isEmpty {
            warnings.append(
                "self-judged column(s): \(selfJudged.joined(separator: ", ")) — "
                    + "LLM-rubric rows were graded by the run model itself (weaker grade)"
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
        let header = "| Domain | " + models.map { shortModel($0.modelId) }.joined(separator: " | ") + " |"
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
        lines.append("| Metric | " + models.map { shortModel($0.modelId) }.joined(separator: " | ") + " |")
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
        if models.contains(where: { $0.flakyCases != nil }) {
            lines.append(
                "| flaky cases (repeat trials) | "
                    + models.map { $0.flakyCases.map(String.init) ?? "—" }
                    .joined(separator: " | ") + " |"
            )
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
            return "- `\(shortModel(col.modelId))` — \(env.summary)"
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
            if let r = col.peakPhysFootprintMb { perf.append(String(format: "%.0fMB", r)) }
            if let c = col.meanCpuPercent { perf.append(String(format: "%.0f%% CPU", c)) }
            if let ctx = col.meanPromptTokensPerTask { perf.append(String(format: "%.0f ctx tok", ctx)) }
            let perfStr = perf.isEmpty ? "" : "  [\(perf.joined(separator: ", "))]"
            lines.append("  \(shortModel(col.modelId)): \(col.totalPassed)/\(col.totalScored)\(perfStr)")
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
}

public enum EvalMatrixBuilder {
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
        let scoredRows = cases.filter { $0.outcome == .passed || $0.outcome == .failed }
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
        for report in reports {
            byModel[report.modelId, default: []].append(contentsOf: report.cases)
            // Keep the earliest startedAt per model as the run stamp.
            if let existing = startedByModel[report.modelId] {
                startedByModel[report.modelId] = min(existing, report.startedAt)
            } else {
                startedByModel[report.modelId] = report.startedAt
            }
            // First non-nil environment per model wins — a single contribution
            // (one machine, one run) shares one env across its suite reports.
            if envByModel[report.modelId] == nil, let env = report.environment {
                envByModel[report.modelId] = env
            }
        }
        let allDomains = Set(reports.flatMap { $0.cases.map(\.domain) }).sorted()
        let columns = byModel.keys.sorted().map { modelId -> EvalMatrixModelColumn in
            let cases = byModel[modelId] ?? []
            var perDomain: [String: EvalMatrixDomainCell] = [:]
            for domain in allDomains {
                let rows = cases.filter { $0.domain == domain }
                guard !rows.isEmpty else { continue }
                perDomain[domain] = EvalMatrixDomainCell(
                    passed: rows.filter { $0.outcome == .passed }.count,
                    scored: rows.filter { $0.outcome == .passed || $0.outcome == .failed }.count,
                    skipped: rows.filter { $0.outcome == .skipped }.count,
                    errored: rows.filter { $0.outcome == .errored }.count
                )
            }
            let telem = cases.compactMap(\.telemetry).filter { !$0.isEmpty }
            let decodes = telem.compactMap(\.decodeTokensPerSecond)
            let ttfts = telem.compactMap(\.ttftMs)
            let rams = telem.compactMap(\.peakPhysFootprintMb)
            let cpus = telem.compactMap(\.meanCpuPercent)
            let promptToks = telem.compactMap(\.promptTokensTotal)
            let totalToks = telem.compactMap(\.totalModelTokens)
            let trialed = cases.filter { $0.trials != nil }
            let chatCases = cases.filter { !isSubsystemCase(id: $0.id, domain: $0.domain) }
            let subsystemCases = cases.filter { isSubsystemCase(id: $0.id, domain: $0.domain) }
            let chatTotals = scoreTotals(for: chatCases)
            let subsystemTotals = scoreTotals(for: subsystemCases)
            return EvalMatrixModelColumn(
                modelId: modelId,
                startedAt: startedByModel[modelId],
                perDomain: perDomain,
                totalPassed: cases.filter { $0.outcome == .passed }.count,
                totalScored: cases.filter { $0.outcome == .passed || $0.outcome == .failed }.count,
                chatModelPassed: chatTotals.passed,
                chatModelScored: chatTotals.scored,
                subsystemPassed: subsystemTotals.passed,
                subsystemScored: subsystemTotals.scored,
                meanDecodeTokensPerSecond: decodes.isEmpty ? nil : decodes.reduce(0, +) / Double(decodes.count),
                meanTtftMs: ttfts.isEmpty ? nil : ttfts.reduce(0, +) / Double(ttfts.count),
                peakPhysFootprintMb: rams.max(),
                meanCpuPercent: cpus.isEmpty ? nil : cpus.reduce(0, +) / Double(cpus.count),
                peakCpuPercent: telem.compactMap(\.peakCpuPercent).max(),
                meanPromptTokensPerTask: promptToks.isEmpty
                    ? nil : Double(promptToks.reduce(0, +)) / Double(promptToks.count),
                meanTotalTokensPerTask: totalToks.isEmpty
                    ? nil : Double(totalToks.reduce(0, +)) / Double(totalToks.count),
                flakyCases: trialed.isEmpty ? nil : trialed.filter(\.isFlaky).count,
                environment: envByModel[modelId]
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
