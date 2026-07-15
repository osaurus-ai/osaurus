//
//  EvalHistory.swift
//  OsaurusEvalsKit
//
//  Append-only run history for `reports/history.jsonl`. Raw per-case reports
//  are intentionally NOT committed (noisy, large, merge-conflict-prone when
//  several maintainers run evals). Instead each recorded run appends one
//  compact, single-line JSON row PER MODEL here, and overwrites the rolled-up
//  `reports/SNAPSHOT.{md,json}` scoreboard. JSONL is the right shape for this:
//  every run only ever adds lines at the end, so concurrent maintainer commits
//  merge cleanly (keep-both) instead of clobbering a shared blob.
//
//    measure ─▶ matrix ─▶ overwrite SNAPSHOT (latest) + append history (trend)
//

import Foundation

/// One model's scoreboard at a single point in time. `commit`/`label` carry
/// provenance (which tree produced it, and an optional maintainer note) so a
/// shared `history.jsonl` stays attributable across contributors.
public struct EvalHistoryRow: Codable, Sendable, Equatable {
    public let ts: String
    public let commit: String?
    public let label: String?
    public let model: String
    public let passed: Int
    public let scored: Int
    public let skipped: Int
    public let errored: Int
    public let decodeTokensPerSecond: Double?
    public let ttftMs: Double?
    public let peakPhysFootprintMb: Double?
    /// Mean / peak HOST CPU utilization (%) for this model's model-driven
    /// rows. Optional so pre-CPU history lines still decode as nil.
    public let meanCpuPercent: Double?
    public let peakCpuPercent: Double?
    /// Mean estimated context tokens per task (prompt + tool schema) and
    /// total tokens per task for this model's model-driven rows — the
    /// context-cost trend the optimization loop tracks across runs. Optional
    /// so pre-existing history lines still decode.
    public let meanPromptTokensPerTask: Double?
    public let meanTotalTokensPerTask: Double?
    /// Number of cases whose `--repeat` trials disagreed in this run — the
    /// flake-rate trend. nil for single-execution runs (no trial evidence)
    /// and for pre-existing history lines.
    public let flakyCases: Int?
    /// Run provenance (hardware, OS, build, judge, catalog hash). Optional so
    /// pre-existing history lines still decode; populated for runs recorded
    /// after the provenance block shipped so a crowdsourced trend stays
    /// attributable to a machine + catalog.
    public let environment: RunEnvironment?

    public init(
        ts: String,
        commit: String?,
        label: String?,
        model: String,
        passed: Int,
        scored: Int,
        skipped: Int,
        errored: Int,
        decodeTokensPerSecond: Double?,
        ttftMs: Double?,
        peakPhysFootprintMb: Double?,
        meanCpuPercent: Double? = nil,
        peakCpuPercent: Double? = nil,
        meanPromptTokensPerTask: Double? = nil,
        meanTotalTokensPerTask: Double? = nil,
        flakyCases: Int? = nil,
        environment: RunEnvironment? = nil
    ) {
        self.ts = ts
        self.commit = commit
        self.label = label
        self.model = model
        self.passed = passed
        self.scored = scored
        self.skipped = skipped
        self.errored = errored
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.ttftMs = ttftMs
        self.peakPhysFootprintMb = peakPhysFootprintMb
        self.meanCpuPercent = meanCpuPercent
        self.peakCpuPercent = peakCpuPercent
        self.meanPromptTokensPerTask = meanPromptTokensPerTask
        self.meanTotalTokensPerTask = meanTotalTokensPerTask
        self.flakyCases = flakyCases
        self.environment = environment
    }
}

public enum EvalHistory {
    /// Project a matrix into one row per model column. `skipped`/`errored`
    /// totals are summed from the per-domain cells (the matrix keeps them
    /// out of the pass/scored denominator).
    public static func rows(from matrix: EvalMatrix, commit: String?, label: String?) -> [EvalHistoryRow] {
        let cleanCommit = commit?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        return matrix.models.map { col in
            EvalHistoryRow(
                ts: matrix.generatedAt,
                commit: (cleanCommit?.isEmpty ?? true) ? nil : cleanCommit,
                label: (cleanLabel?.isEmpty ?? true) ? nil : cleanLabel,
                model: col.modelId,
                passed: col.totalPassed,
                scored: col.totalScored,
                skipped: col.perDomain.values.reduce(0) { $0 + $1.skipped },
                errored: col.perDomain.values.reduce(0) { $0 + $1.errored },
                decodeTokensPerSecond: col.meanDecodeTokensPerSecond,
                ttftMs: col.meanTtftMs,
                peakPhysFootprintMb: col.peakPhysFootprintMb,
                meanCpuPercent: col.meanCpuPercent,
                peakCpuPercent: col.peakCpuPercent,
                meanPromptTokensPerTask: col.meanPromptTokensPerTask,
                meanTotalTokensPerTask: col.meanTotalTokensPerTask,
                flakyCases: col.flakyCases,
                environment: col.environment
            )
        }
    }

    /// Append `rows` to `url` as JSONL (one single-line object per row),
    /// creating the parent directory and file if missing. Append-only: never
    /// rewrites existing lines, so it is safe for many maintainers to add to
    /// the same committed log.
    public static func append(_ rows: [EvalHistoryRow], to url: URL) throws {
        guard !rows.isEmpty else { return }
        let encoder = JSONEncoder()
        // No `.prettyPrinted` — one compact line per row is what makes JSONL
        // append-friendly and diff-readable. `.withoutEscapingSlashes` keeps
        // model ids like `mlx-community/Qwen3-4B-4bit` legible.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var blob = Data()
        for row in rows {
            blob.append(try encoder.encode(row))
            blob.append(0x0A)  // newline
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: blob)
        } else {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try blob.write(to: url)
        }
    }

    /// Read every parseable row back from a JSONL log. Blank lines and
    /// non-decodable lines are skipped so a hand-edited or partially-merged
    /// file never crashes tooling.
    public static func load(from url: URL) throws -> [EvalHistoryRow] {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let rowData = trimmed.data(using: .utf8) else { return nil }
            return try? decoder.decode(EvalHistoryRow.self, from: rowData)
        }
    }
}
