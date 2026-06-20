//
//  EvalCompat.swift
//  OsaurusEvalsKit
//
//  Crowdsourced model-compatibility aggregation. The core team can't run
//  every model/quant on every Mac, so contributors run the suite for a model
//  on THEIR hardware and PR a single self-contained contribution file under
//  `reports/community/` (a matrix JSON carrying a `RunEnvironment`). One file
//  per contribution = zero merge conflicts (a new file every time, never an
//  edit to a shared blob).
//
//  This aggregator folds all contributions into a single compatibility
//  leaderboard: per model, a `works / partial / broken` verdict plus the
//  hardware coverage (chips, RAM band), worst-case footprint, decode-speed
//  range, and a comparability check (did everyone grade the same catalog?).
//
//    contribute (per machine) ─▶ reports/community/*.json ─▶ compat ─▶ COMPATIBILITY.{md,json}
//

import Foundation

/// One model's rolled-up compatibility across every contribution that ran it.
public struct ModelCompatibility: Codable, Sendable, Equatable {
    /// Coarse compatibility bucket. Distinguishes "the harness couldn't run
    /// this model" (`broken` — error-dominated / never scored) from "it runs
    /// but quality/robustness is shaky" (`partial`) and "runs cleanly"
    /// (`works`). Quality is a separate axis from compatibility, but a model
    /// that errors out on every case is the headline incompatibility signal.
    public enum Verdict: String, Codable, Sendable, Equatable {
        case works
        case partial
        case broken
        case unknown
    }

    public let model: String
    public let verdict: Verdict
    /// How many contributions (machine × run) reported this model.
    public let contributions: Int
    public let passed: Int
    public let scored: Int
    public let skipped: Int
    public let errored: Int
    /// Distinct chips that reported (hardware coverage).
    public let chips: [String]
    /// RAM band of reporting machines, MB.
    public let minRamMb: Int?
    public let maxRamMb: Int?
    /// Worst observed peak physical footprint (MB) — the RAM-gate headline.
    public let peakPhysFootprintMb: Double?
    /// Decode throughput spread across contributions (tok/s).
    public let decodeTokensPerSecondMin: Double?
    public let decodeTokensPerSecondMax: Double?
    /// Distinct catalog hashes seen. >1 means contributions graded different
    /// case sets, so the aggregate pass-rate mixes denominators — surfaced as
    /// a comparability caveat rather than silently averaged.
    public let catalogHashes: [String]
    /// Distinct Osaurus builds (version or commit) that reported.
    public let builds: [String]
    /// True when any contribution self-judged an LLM-judged suite (weaker
    /// grade) — a trust caveat on the pass-rate.
    public let hasSelfJudged: Bool

    public var passRate: Double? { scored > 0 ? Double(passed) / Double(scored) : nil }
    public var comparable: Bool { catalogHashes.count <= 1 }
}

/// The full crowdsourced leaderboard.
public struct CompatibilityReport: Codable, Sendable, Equatable {
    public let generatedAt: String
    public let contributions: Int
    public let models: [ModelCompatibility]

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
        lines.append("# Osaurus Model Compatibility (community)")
        lines.append("")
        lines.append(
            "Crowdsourced from \(contributions) contribution(s). "
                + "Verdicts: **works** (runs cleanly), **partial** (runs with errors or low pass-rate), "
                + "**broken** (error-dominated / never scored)."
        )
        lines.append("")
        lines.append(
            "| Model | Verdict | Pass | Contrib | Chips | RAM band | peak RAM | decode tok/s | builds |"
        )
        lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
        for m in models {
            let pass =
                m.passRate.map { String(format: "%.0f%% (%d/%d)", $0 * 100, m.passed, m.scored) }
                ?? "— (\(m.passed)/\(m.scored))"
            let chips = m.chips.isEmpty ? "—" : m.chips.joined(separator: ", ")
            let ramBand = Self.formatRamBand(minMb: m.minRamMb, maxMb: m.maxRamMb)
            let peak = m.peakPhysFootprintMb.map { String(format: "%.0fMB", $0) } ?? "—"
            let decode = Self.formatRange(m.decodeTokensPerSecondMin, m.decodeTokensPerSecondMax, fmt: "%.0f")
            let builds = m.builds.isEmpty ? "—" : m.builds.joined(separator: ", ")
            var verdict = m.verdict.rawValue
            if !m.comparable { verdict += " ⚠" }
            lines.append(
                "| `\(Self.shortModel(m.model))` | \(verdict) | \(pass) | \(m.contributions) "
                    + "| \(chips) | \(ramBand) | \(peak) | \(decode) | \(builds) |"
            )
        }
        let caveats = models.filter { !$0.comparable || $0.hasSelfJudged }
        if !caveats.isEmpty {
            lines.append("")
            lines.append("## Caveats")
            lines.append("")
            for m in caveats {
                if !m.comparable {
                    lines.append(
                        "- `\(Self.shortModel(m.model))`: ⚠ mixed catalog hashes "
                            + "(\(m.catalogHashes.joined(separator: ", "))) — contributions graded "
                            + "different case sets, so the aggregate pass-rate mixes denominators."
                    )
                }
                if m.hasSelfJudged {
                    lines.append(
                        "- `\(Self.shortModel(m.model))`: at least one contribution self-judged an "
                            + "LLM-judged suite — those rubric grades are weaker."
                    )
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func formatRamBand(minMb: Int?, maxMb: Int?) -> String {
        func gb(_ mb: Int) -> String { "\(Int((Double(mb) / 1024).rounded()))GB" }
        switch (minMb, maxMb) {
        case let (lo?, hi?): return lo == hi ? gb(lo) : "\(gb(lo))–\(gb(hi))"
        case let (lo?, nil): return gb(lo)
        case let (nil, hi?): return gb(hi)
        default: return "—"
        }
    }

    private static func formatRange(_ lo: Double?, _ hi: Double?, fmt: String) -> String {
        switch (lo, hi) {
        case let (l?, h?):
            return l == h
                ? String(format: fmt, l)
                : String(format: fmt, l) + "–" + String(format: fmt, h)
        case let (l?, nil): return String(format: fmt, l)
        case let (nil, h?): return String(format: fmt, h)
        default: return "—"
        }
    }

    public static func shortModel(_ id: String) -> String {
        id.contains("/") ? String(id.split(separator: "/").last ?? Substring(id)) : id
    }
}

public enum EvalCompatBuilder {
    /// Fold a set of contribution matrices into the compatibility leaderboard.
    /// Each `EvalMatrix` may carry one or more model columns; columns are
    /// grouped by `modelId` and aggregated across every contribution.
    public static func build(from matrices: [EvalMatrix], generatedAt: String? = nil) -> CompatibilityReport {
        var columnsByModel: [String: [EvalMatrixModelColumn]] = [:]
        for matrix in matrices {
            for col in matrix.models {
                columnsByModel[col.modelId, default: []].append(col)
            }
        }
        let models = columnsByModel.keys.sorted().map { model -> ModelCompatibility in
            aggregate(model: model, columns: columnsByModel[model] ?? [])
        }
        return CompatibilityReport(
            generatedAt: generatedAt ?? isoNow(),
            contributions: matrices.count,
            models: models
        )
    }

    private static func aggregate(model: String, columns: [EvalMatrixModelColumn]) -> ModelCompatibility {
        let passed = columns.reduce(0) { $0 + $1.totalPassed }
        let scored = columns.reduce(0) { $0 + $1.totalScored }
        let skipped = columns.reduce(0) { acc, col in
            acc + col.perDomain.values.reduce(0) { $0 + $1.skipped }
        }
        let errored = columns.reduce(0) { acc, col in
            acc + col.perDomain.values.reduce(0) { $0 + $1.errored }
        }
        let envs = columns.compactMap(\.environment)
        let chips = orderedUnique(envs.compactMap(\.chip))
        let rams = envs.compactMap(\.totalRamMb)
        let decodes = columns.compactMap(\.meanDecodeTokensPerSecond)
        let catalogHashes = orderedUnique(envs.compactMap(\.catalogHash))
        let builds = orderedUnique(envs.compactMap { $0.osaurusVersion ?? $0.commit })
        let hasSelfJudged = envs.contains { $0.judge == "self-judge" }

        return ModelCompatibility(
            model: model,
            verdict: verdict(passed: passed, scored: scored, errored: errored),
            contributions: columns.count,
            passed: passed,
            scored: scored,
            skipped: skipped,
            errored: errored,
            chips: chips,
            minRamMb: rams.min(),
            maxRamMb: rams.max(),
            peakPhysFootprintMb: columns.compactMap(\.peakPhysFootprintMb).max(),
            decodeTokensPerSecondMin: decodes.min(),
            decodeTokensPerSecondMax: decodes.max(),
            catalogHashes: catalogHashes,
            builds: builds,
            hasSelfJudged: hasSelfJudged
        )
    }

    /// Verdict heuristic (documented in `reports/community/README.md`):
    ///   - `unknown` when nothing ran or was gradeable.
    ///   - `broken` when the harness errored on a majority of attempted cases
    ///     (the model couldn't be driven through the loop).
    ///   - `partial` when it ran but with any errors, or a sub-40% pass-rate.
    ///   - `works` when it ran cleanly with a ≥40% pass-rate.
    static func verdict(passed: Int, scored: Int, errored: Int) -> ModelCompatibility.Verdict {
        let attempted = scored + errored
        if attempted == 0 { return .unknown }
        if scored == 0 || Double(errored) / Double(attempted) > 0.5 { return .broken }
        let rate = Double(passed) / Double(scored)
        if errored > 0 || rate < 0.4 { return .partial }
        return .works
    }

    /// Load contribution files under `dir`. Each `*.json` is decoded as an
    /// `EvalMatrix` (the shape `evals-contribute` writes) or, failing that, as
    /// a raw `EvalReport` folded into a single-report matrix — so a community
    /// dir tolerates both contribution matrices and raw reports.
    public static func loadContributions(in dir: URL) throws -> [EvalMatrix] {
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
        var matrices: [EvalMatrix] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let matrix = try? decoder.decode(EvalMatrix.self, from: data), !matrix.models.isEmpty {
                matrices.append(matrix)
            } else if let report = try? decoder.decode(EvalReport.self, from: data), !report.cases.isEmpty {
                matrices.append(EvalMatrixBuilder.build(from: [report]))
            }
        }
        if matrices.isEmpty { throw EvalMatrixError.noReports(dir.path) }
        return matrices
    }

    /// Validate a community dir: every `*.json` must decode to a contribution
    /// and carry the provenance that makes a crowdsourced row trustworthy
    /// (chip, RAM, catalog hash). Returns one problem string per offending
    /// file; an empty array means the dir is clean.
    public static func validate(in dir: URL) -> [String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir) else {
            return ["path does not exist: \(dir.path)"]
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
        var problems: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            guard let data = try? Data(contentsOf: url) else {
                problems.append("\(name): unreadable")
                continue
            }
            let columns: [EvalMatrixModelColumn]
            if let matrix = try? decoder.decode(EvalMatrix.self, from: data), !matrix.models.isEmpty {
                columns = matrix.models
            } else if let report = try? decoder.decode(EvalReport.self, from: data), !report.cases.isEmpty {
                columns = EvalMatrixBuilder.build(from: [report]).models
            } else {
                problems.append("\(name): not a decodable contribution (EvalMatrix or EvalReport)")
                continue
            }
            for col in columns {
                guard let env = col.environment else {
                    problems.append("\(name): model `\(col.modelId)` has no environment block")
                    continue
                }
                if env.chip == nil {
                    problems.append("\(name): model `\(col.modelId)` env missing chip")
                }
                if env.catalogHash == nil {
                    problems.append("\(name): model `\(col.modelId)` env missing catalogHash")
                }
            }
        }
        return problems
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for v in values where seen.insert(v).inserted { out.append(v) }
        return out.sorted()
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
