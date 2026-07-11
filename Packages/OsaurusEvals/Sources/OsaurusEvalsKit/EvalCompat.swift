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
//  leaderboard with LATEST-RUN PRECEDENCE: per model, the newest contribution
//  (and any others that graded the SAME catalog — the same exam on other
//  devices) defines the headline row. Older-catalog runs are never pooled
//  into the headline pass-rate; they are kept as per-model History. Each row
//  carries the full ran/passed/failed/skipped/errored funnel, a per-domain
//  breakdown (what the model is great at / weak at, and why cases skipped),
//  hardware coverage, worst-case footprint, and decode-speed range.
//
//    contribute (per machine) ─▶ reports/community/*.json ─▶ compat ─▶ COMPATIBILITY.{md,json}
//

import Foundation

/// One contribution as loaded from disk: the matrix plus a file-level
/// fallback contributor (the git author who added the file) for columns whose
/// environment predates the self-declared `contributor` field.
public struct EvalContribution: Sendable {
    public let matrix: EvalMatrix
    public let fallbackContributor: String?

    public init(matrix: EvalMatrix, fallbackContributor: String? = nil) {
        self.matrix = matrix
        self.fallbackContributor = fallbackContributor
    }
}

/// One row of the contributor ranking: who has contributed the most runs,
/// across how many distinct models and device shapes.
public struct ContributorRank: Codable, Sendable, Equatable {
    public let name: String
    /// Contribution columns attributed to this person (current + superseded —
    /// every run counts; the ranking rewards volume and coverage).
    public let contributions: Int
    /// Distinct models this person has reported.
    public let models: Int
    /// Distinct device shapes (chip × RAM) this person has reported from.
    public let devices: Int
}

/// One superseded (older-catalog) run of a model — kept as history so recency
/// is explicit instead of silently pooled into the headline pass-rate.
public struct PriorRunSummary: Codable, Sendable, Equatable {
    public let startedAt: String?
    public let build: String?
    public let catalogHash: String?
    public let passed: Int
    public let scored: Int
    public let skipped: Int
    public let errored: Int
    public let chip: String?
    public let totalRamMb: Int?
    public let contributor: String?

    public var passRate: Double? { scored > 0 ? Double(passed) / Double(scored) : nil }
}

/// Per-domain rollup for a model's CURRENT result set — the "what is this
/// model great at (and what did it skip, and why)" signal.
public struct DomainCompatibility: Codable, Sendable, Equatable {
    public let passed: Int
    public let scored: Int
    public let skipped: Int
    public let errored: Int
    /// Skip-reason histogram (reason → count) merged across the current
    /// contributions. May account for fewer than `skipped` cases when a
    /// contribution predates skip-reason recording.
    public let skipReasons: [String: Int]?

    public var passRate: Double? { scored > 0 ? Double(passed) / Double(scored) : nil }
}

/// One model's compatibility row: the CURRENT result set (newest catalog),
/// plus its superseded history.
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
    /// Verdict computed from the CURRENT result set only.
    public let verdict: Verdict
    /// How many contributions (machine × run) are in the current result set
    /// (same catalog as the newest run).
    public let contributions: Int
    /// Current-set funnel: every case either scored (passed + failed),
    /// skipped (didn't apply on that host), or errored (harness broke).
    public let passed: Int
    public let scored: Int
    public let skipped: Int
    public let errored: Int
    /// Per-domain breakdown of the current set (pass-rate, skips + reasons).
    public let perDomain: [String: DomainCompatibility]
    /// Domains the model is great at: ≥90% pass-rate with ≥5 scored cases.
    public let strengths: [String]
    /// Weakest domain (lowest pass-rate with ≥5 scored, below 90%). nil when
    /// every qualifying domain is strong.
    public let weakest: String?
    /// Distinct chips in the current set (hardware coverage).
    public let chips: [String]
    /// RAM band of current-set machines, MB.
    public let minRamMb: Int?
    public let maxRamMb: Int?
    /// Worst observed peak physical footprint (MB) — the RAM-gate headline.
    public let peakPhysFootprintMb: Double?
    /// Decode throughput spread across current contributions (tok/s).
    public let decodeTokensPerSecondMin: Double?
    public let decodeTokensPerSecondMax: Double?
    /// Catalog hash the current set graded — the comparability key.
    public let catalogHash: String?
    /// Osaurus build (version or commit) of the newest run.
    public let build: String?
    /// `startedAt` of the newest run — the row's recency stamp.
    public let asOf: String?
    /// True when the current catalog is older than the newest catalog seen
    /// anywhere in the contribution set — this model needs a fresh run.
    public let stale: Bool
    /// True when any current contribution self-judged an LLM-judged suite
    /// (weaker grade) — a trust caveat on the pass-rate.
    public let hasSelfJudged: Bool
    /// Who ran the current set (self-declared `contributor`, or the git
    /// author who added the contribution file). Empty when unattributable.
    public let contributors: [String]
    /// Older-catalog runs, newest first. Never pooled into the headline.
    public let superseded: [PriorRunSummary]

    public var passRate: Double? { scored > 0 ? Double(passed) / Double(scored) : nil }
    /// Total cases the current set attempted (scored + skipped + errored).
    public var attempted: Int { scored + skipped + errored }
}

/// One distinct machine that has contributed at least one run — the
/// "comprehensive list of devices and sizes" axis of the crowdsourced
/// leaderboard. Keyed by (chip, RAM): two M4 Pros with different RAM are
/// different fit-envelopes and count as separate devices. Superseded runs
/// still count here — device coverage is about who CAN run, not recency.
public struct DeviceCoverage: Codable, Sendable, Equatable {
    public let chip: String
    public let totalRamMb: Int?
    /// How many contribution columns came from this device shape.
    public let contributions: Int
    /// Distinct macOS versions seen on this device shape.
    public let osVersions: [String]
}

/// The full crowdsourced leaderboard.
public struct CompatibilityReport: Codable, Sendable, Equatable {
    public let generatedAt: String
    /// Total contribution files folded (current + superseded).
    public let contributions: Int
    public let models: [ModelCompatibility]
    /// Distinct contributing device shapes (chip × RAM).
    public let devices: [DeviceCoverage]?
    /// Contributor ranking — most runs first (every run counts, current and
    /// superseded; volume and coverage are what the community leaderboard
    /// rewards). nil when no contribution could be attributed.
    public let contributors: [ContributorRank]?

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
            "Crowdsourced from \(contributions) contribution(s). Each row reflects the model's "
                + "**latest run** (newest case catalog); same-catalog runs on other devices fold in, "
                + "older runs live under the model's History and are never pooled into the headline. "
                + "Verdicts: **works** (runs cleanly), **partial** (runs with errors or low pass-rate), "
                + "**broken** (error-dominated / never scored). *stale* = the run predates the newest "
                + "catalog and needs refreshing."
        )

        // ── Contributors first: this board exists because people donate
        // machine-hours, so credit leads. ──
        if let contributors, !contributors.isEmpty {
            lines.append("")
            lines.append("## Contributors")
            lines.append("")
            let names = contributors.map(\.name)
            let honorRoll: String
            switch names.count {
            case 1: honorRoll = "**\(names[0])**"
            case 2: honorRoll = "**\(names[0])** and **\(names[1])**"
            default:
                honorRoll =
                    names.dropLast().map { "**\($0)**" }.joined(separator: ", ")
                    + ", and **\(names.last!)**"
            }
            lines.append(
                "This leaderboard exists because \(honorRoll) donated machine-hours to run "
                    + "the suites. Ranked by contributed runs (every run counts, current and "
                    + "superseded), then by breadth of models and device shapes covered. "
                    + "Attribution comes from the contribution's `contributor` provenance, "
                    + "falling back to the git author who added the file. Want on this list? "
                    + "See `reports/community/README.md` — one command, one PR."
            )
            lines.append("")
            lines.append("| # | Contributor | Runs | Models | Devices |")
            lines.append("| --- | --- | --- | --- | --- |")
            for (index, c) in contributors.enumerated() {
                let name = index == 0 ? "**\(c.name)**" : c.name
                lines.append(
                    "| \(index + 1) | \(name) | \(c.contributions) | \(c.models) | \(c.devices) |"
                )
            }
        }

        lines.append("")
        lines.append("## Models")
        lines.append("")
        lines.append(
            "| Model | Verdict | Pass | Fail | Skip | Err | Great at | Devices | peak RAM | decode tok/s | build | as of |"
        )
        lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
        for m in models {
            let pass =
                m.passRate.map { String(format: "%.0f%% (%d/%d)", $0 * 100, m.passed, m.scored) }
                ?? "— (\(m.passed)/\(m.scored))"
            let failed = m.scored - m.passed
            let devices = Self.formatDevices(chips: m.chips, minRamMb: m.minRamMb, maxRamMb: m.maxRamMb)
            let peak = m.peakPhysFootprintMb.map { String(format: "%.0fMB", $0) } ?? "—"
            let decode = Self.formatRange(m.decodeTokensPerSecondMin, m.decodeTokensPerSecondMax, fmt: "%.0f")
            var verdict = m.verdict.rawValue
            if m.stale { verdict += " *(stale)*" }
            var greatAt = m.strengths.isEmpty ? "—" : m.strengths.joined(separator: ", ")
            if let weakest = m.weakest { greatAt += " · weak: \(weakest)" }
            lines.append(
                "| `\(Self.shortModel(m.model))` | \(verdict) | \(pass) | \(failed) | \(m.skipped) "
                    + "| \(m.errored) | \(greatAt) | \(devices) | \(peak) | \(decode) "
                    + "| \(m.build ?? "—") | \(Self.formatDay(m.asOf)) |"
            )
        }

        // ── Per-model detail: domain breakdown, skipped areas, history ──
        lines.append("")
        lines.append("## Model details")
        for m in models {
            lines.append("")
            var heading = "### `\(Self.shortModel(m.model))`"
            if m.stale { heading += " *(stale — needs a fresh run)*" }
            lines.append(heading)
            lines.append("")
            var meta: [String] = []
            meta.append("as of \(Self.formatDay(m.asOf))")
            if let build = m.build { meta.append("build \(build)") }
            if let hash = m.catalogHash { meta.append("catalog \(hash)") }
            meta.append("\(m.contributions) contribution(s)")
            if !m.contributors.isEmpty {
                meta.append("by \(m.contributors.joined(separator: ", "))")
            }
            lines.append("Current run: \(meta.joined(separator: " · ")).")
            lines.append("")
            lines.append("| Domain | Pass | Fail | Skip | Err |")
            lines.append("| --- | --- | --- | --- | --- |")
            for domain in m.perDomain.keys.sorted() {
                guard let cell = m.perDomain[domain] else { continue }
                let pass =
                    cell.passRate.map {
                        String(format: "%.0f%% (%d/%d)", $0 * 100, cell.passed, cell.scored)
                    } ?? "— (\(cell.passed)/\(cell.scored))"
                lines.append(
                    "| \(domain) | \(pass) | \(cell.scored - cell.passed) | \(cell.skipped) | \(cell.errored) |"
                )
            }
            let skippedDomains = m.perDomain.filter { $0.value.skipped > 0 }.keys.sorted()
            if !skippedDomains.isEmpty {
                lines.append("")
                lines.append("Skipped areas:")
                for domain in skippedDomains {
                    guard let cell = m.perDomain[domain] else { continue }
                    lines.append("- \(domain): \(cell.skipped) — \(Self.formatSkipReasons(cell))")
                }
            }
            if !m.superseded.isEmpty {
                lines.append("")
                lines.append("History (superseded, not in the headline):")
                for prior in m.superseded {
                    let pass =
                        prior.passRate.map {
                            String(format: "%.0f%% (%d/%d)", $0 * 100, prior.passed, prior.scored)
                        } ?? "— (\(prior.passed)/\(prior.scored))"
                    var parts = ["\(Self.formatDay(prior.startedAt))"]
                    if let build = prior.build { parts.append("build \(build)") }
                    if let hash = prior.catalogHash { parts.append("catalog \(hash)") }
                    parts.append(pass)
                    if let chip = prior.chip {
                        let ram = prior.totalRamMb.map { " (\(Self.gb($0)))" } ?? ""
                        parts.append("\(chip)\(ram)")
                    }
                    if let contributor = prior.contributor {
                        parts.append("by \(contributor)")
                    }
                    lines.append("- \(parts.joined(separator: " · "))")
                }
            }
        }

        if let devices, !devices.isEmpty {
            lines.append("")
            lines.append("## Device coverage")
            lines.append("")
            lines.append(
                "Distinct contributing machines (chip × RAM). Missing shapes are the "
                    + "most valuable contributions — see `reports/community/README.md`."
            )
            lines.append("")
            lines.append("| Chip | RAM | Contributions | macOS |")
            lines.append("| --- | --- | --- | --- |")
            for d in devices {
                let ram = d.totalRamMb.map { Self.gb($0) } ?? "—"
                let os = d.osVersions.isEmpty ? "—" : d.osVersions.joined(separator: ", ")
                lines.append("| \(d.chip) | \(ram) | \(d.contributions) | \(os) |")
            }
        }
        let caveats = models.filter { $0.stale || $0.hasSelfJudged }
        if !caveats.isEmpty {
            lines.append("")
            lines.append("## Caveats")
            lines.append("")
            for m in caveats {
                if m.stale {
                    lines.append(
                        "- `\(Self.shortModel(m.model))`: stale — its newest run graded catalog "
                            + "`\(m.catalogHash ?? "?")`, older than the newest catalog in this report; "
                            + "a fresh `make evals-contribute` run would refresh the row."
                    )
                }
                if m.hasSelfJudged {
                    lines.append(
                        "- `\(Self.shortModel(m.model))`: the current run self-judged an "
                            + "LLM-judged suite — those rubric grades are weaker."
                    )
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func formatSkipReasons(_ cell: DomainCompatibility) -> String {
        let reasons = cell.skipReasons ?? [:]
        let recorded = reasons.values.reduce(0, +)
        var parts =
            reasons
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "\($0.key) (\($0.value))" }
        let unrecorded = cell.skipped - recorded
        if unrecorded > 0 {
            parts.append(
                parts.isEmpty
                    ? "reasons unrecorded (pre-schema contribution)"
                    : "\(unrecorded) unrecorded"
            )
        }
        return parts.joined(separator: ", ")
    }

    private static func formatDevices(chips: [String], minRamMb: Int?, maxRamMb: Int?) -> String {
        guard !chips.isEmpty else { return "—" }
        let ram: String
        switch (minRamMb, maxRamMb) {
        case let (lo?, hi?): ram = lo == hi ? gb(lo) : "\(gb(lo))–\(gb(hi))"
        case let (lo?, nil): ram = gb(lo)
        case let (nil, hi?): ram = gb(hi)
        default: ram = ""
        }
        let joined = chips.joined(separator: ", ")
        return ram.isEmpty ? joined : "\(joined) (\(ram))"
    }

    private static func gb(_ mb: Int) -> String { "\(Int((Double(mb) / 1024).rounded()))GB" }

    /// Day part of an ISO8601 stamp ("2026-07-10T22:30:22Z" → "2026-07-10").
    private static func formatDay(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "—" }
        return String(iso.prefix(10))
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
    /// One model column plus its resolved contributor (the column's
    /// self-declared `environment.contributor`, falling back to the
    /// file-level git author).
    struct AttributedColumn {
        let column: EvalMatrixModelColumn
        let contributor: String?
    }

    /// Convenience overload for matrices with no file-level attribution.
    public static func build(from matrices: [EvalMatrix], generatedAt: String? = nil) -> CompatibilityReport {
        build(from: matrices.map { EvalContribution(matrix: $0) }, generatedAt: generatedAt)
    }

    /// Fold a set of contributions into the compatibility leaderboard.
    /// Each contribution may carry one or more model columns; columns are
    /// grouped by `modelId`, then split into the CURRENT result set (newest
    /// catalog for that model) and superseded history. Contributor identity
    /// resolves per column (env block first, git-author fallback second) and
    /// feeds both per-model attribution and the contributor ranking.
    public static func build(
        from contributions: [EvalContribution],
        generatedAt: String? = nil
    ) -> CompatibilityReport {
        var columnsByModel: [String: [AttributedColumn]] = [:]
        for contribution in contributions {
            for col in contribution.matrix.models {
                let attributed = AttributedColumn(
                    column: col,
                    contributor: col.environment?.contributor ?? contribution.fallbackContributor
                )
                columnsByModel[col.modelId, default: []].append(attributed)
            }
        }
        // The newest catalog hash seen anywhere — the staleness reference.
        // ISO8601 Z-stamps sort lexicographically, so string max is newest.
        let latestCatalogHash =
            columnsByModel.values
            .flatMap { $0 }
            .filter { $0.column.environment?.catalogHash != nil }
            .max { ($0.column.startedAt ?? "") < ($1.column.startedAt ?? "") }?
            .column.environment?.catalogHash
        let models = columnsByModel.keys.sorted().map { model -> ModelCompatibility in
            aggregate(
                model: model,
                columns: columnsByModel[model] ?? [],
                latestCatalogHash: latestCatalogHash
            )
        }
        let ranking = rankContributors(columnsByModel.values.flatMap { $0 })
        return CompatibilityReport(
            generatedAt: generatedAt ?? isoNow(),
            contributions: contributions.count,
            models: models,
            devices: deviceCoverage(from: contributions.map(\.matrix)),
            contributors: ranking.isEmpty ? nil : ranking
        )
    }

    /// Rank contributors by volume, then breadth: contribution count,
    /// distinct models, distinct device shapes, name. Every attributed run
    /// counts — current and superseded alike (a superseded run was still
    /// work donated to the project).
    static func rankContributors(_ columns: [AttributedColumn]) -> [ContributorRank] {
        struct Acc {
            var contributions = 0
            var models = Set<String>()
            var devices = Set<String>()
        }
        var byName: [String: Acc] = [:]
        for attributed in columns {
            guard let name = attributed.contributor else { continue }
            var acc = byName[name] ?? Acc()
            acc.contributions += 1
            acc.models.insert(attributed.column.modelId)
            if let env = attributed.column.environment, let chip = env.chip {
                acc.devices.insert("\(chip)|\(env.totalRamMb ?? 0)")
            }
            byName[name] = acc
        }
        return byName
            .map { name, acc in
                ContributorRank(
                    name: name,
                    contributions: acc.contributions,
                    models: acc.models.count,
                    devices: acc.devices.count
                )
            }
            .sorted {
                if $0.contributions != $1.contributions { return $0.contributions > $1.contributions }
                if $0.models != $1.models { return $0.models > $1.models }
                if $0.devices != $1.devices { return $0.devices > $1.devices }
                return $0.name < $1.name
            }
    }

    /// Group every contribution column by (chip, RAM) into the distinct-device
    /// list. Columns without a chip are skipped (they already fail
    /// `--validate`, so a merged contribution always lands here).
    static func deviceCoverage(from matrices: [EvalMatrix]) -> [DeviceCoverage] {
        struct Key: Hashable {
            let chip: String
            let ramMb: Int?
        }
        var byDevice: [Key: (count: Int, osVersions: [String])] = [:]
        for matrix in matrices {
            for col in matrix.models {
                guard let env = col.environment, let chip = env.chip else { continue }
                let key = Key(chip: chip, ramMb: env.totalRamMb)
                var entry = byDevice[key] ?? (0, [])
                entry.count += 1
                if let os = env.osVersion, !entry.osVersions.contains(os) {
                    entry.osVersions.append(os)
                }
                byDevice[key] = entry
            }
        }
        return byDevice
            .map { key, entry in
                DeviceCoverage(
                    chip: key.chip,
                    totalRamMb: key.ramMb,
                    contributions: entry.count,
                    osVersions: entry.osVersions.sorted()
                )
            }
            .sorted {
                if $0.chip != $1.chip { return $0.chip < $1.chip }
                return ($0.totalRamMb ?? 0) < ($1.totalRamMb ?? 0)
            }
    }

    /// Split a model's columns into (current, superseded): the newest column
    /// defines the current catalog; every column that graded the SAME catalog
    /// folds into the current set (same exam, other devices). Everything else
    /// is superseded — never pooled into the headline. When the newest column
    /// has no catalog hash, comparability can't be verified, so the current
    /// set is that single column.
    static func splitCurrent(
        _ columns: [AttributedColumn]
    ) -> (current: [AttributedColumn], superseded: [AttributedColumn]) {
        let sorted = columns.sorted { ($0.column.startedAt ?? "") > ($1.column.startedAt ?? "") }
        guard let newest = sorted.first else { return ([], []) }
        guard let currentHash = newest.column.environment?.catalogHash else {
            return ([newest], Array(sorted.dropFirst()))
        }
        let current = sorted.filter { $0.column.environment?.catalogHash == currentHash }
        let superseded = sorted.filter { $0.column.environment?.catalogHash != currentHash }
        return (current, superseded)
    }

    private static func aggregate(
        model: String,
        columns: [AttributedColumn],
        latestCatalogHash: String?
    ) -> ModelCompatibility {
        let (currentAttributed, supersededAttributed) = splitCurrent(columns)
        let current = currentAttributed.map(\.column)
        let passed = current.reduce(0) { $0 + $1.totalPassed }
        let scored = current.reduce(0) { $0 + $1.totalScored }
        let perDomain = mergePerDomain(current)
        let skipped = perDomain.values.reduce(0) { $0 + $1.skipped }
        let errored = perDomain.values.reduce(0) { $0 + $1.errored }
        let envs = current.compactMap(\.environment)
        let chips = orderedUnique(envs.compactMap(\.chip))
        let rams = envs.compactMap(\.totalRamMb)
        let decodes = current.compactMap(\.meanDecodeTokensPerSecond)
        let newest = current.first
        let catalogHash = newest?.environment?.catalogHash
        let (strengths, weakest) = strengthsAndWeakest(perDomain)

        return ModelCompatibility(
            model: model,
            verdict: verdict(passed: passed, scored: scored, errored: errored),
            contributions: current.count,
            passed: passed,
            scored: scored,
            skipped: skipped,
            errored: errored,
            perDomain: perDomain,
            strengths: strengths,
            weakest: weakest,
            chips: chips,
            minRamMb: rams.min(),
            maxRamMb: rams.max(),
            peakPhysFootprintMb: current.compactMap(\.peakPhysFootprintMb).max(),
            decodeTokensPerSecondMin: decodes.min(),
            decodeTokensPerSecondMax: decodes.max(),
            catalogHash: catalogHash,
            build: newest?.environment.flatMap { $0.osaurusVersion ?? $0.commit },
            asOf: newest?.startedAt,
            stale: latestCatalogHash != nil && catalogHash != nil && catalogHash != latestCatalogHash,
            hasSelfJudged: envs.contains { $0.judge == "self-judge" },
            contributors: orderedUnique(currentAttributed.compactMap(\.contributor)),
            superseded: supersededAttributed.map(priorRunSummary)
        )
    }

    /// Merge per-domain cells across the current set: counts sum; skip-reason
    /// histograms merge (a cell with skips but no recorded reasons leaves the
    /// deficit visible as `skipped - Σreasons`).
    static func mergePerDomain(_ columns: [EvalMatrixModelColumn]) -> [String: DomainCompatibility] {
        var merged: [String: (passed: Int, scored: Int, skipped: Int, errored: Int, reasons: [String: Int])] =
            [:]
        for col in columns {
            for (domain, cell) in col.perDomain {
                var entry = merged[domain] ?? (0, 0, 0, 0, [:])
                entry.passed += cell.passed
                entry.scored += cell.scored
                entry.skipped += cell.skipped
                entry.errored += cell.errored
                for (reason, count) in cell.skipReasons ?? [:] {
                    entry.reasons[reason, default: 0] += count
                }
                merged[domain] = entry
            }
        }
        return merged.mapValues { entry in
            DomainCompatibility(
                passed: entry.passed,
                scored: entry.scored,
                skipped: entry.skipped,
                errored: entry.errored,
                skipReasons: entry.reasons.isEmpty ? nil : entry.reasons
            )
        }
    }

    /// Domains need ≥5 scored cases to qualify (a 2/2 domain isn't a
    /// "strength"). Strengths: pass-rate ≥90%, best first. Weakest: the
    /// lowest qualifying pass-rate, only when it's actually below the
    /// strength bar.
    static func strengthsAndWeakest(
        _ perDomain: [String: DomainCompatibility]
    ) -> (strengths: [String], weakest: String?) {
        let qualifying = perDomain.compactMap { domain, cell -> (String, Double)? in
            guard cell.scored >= 5, let rate = cell.passRate else { return nil }
            return (domain, rate)
        }
        let strengths =
            qualifying
            .filter { $0.1 >= 0.9 }
            .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
            .map(\.0)
        let weakest = qualifying.min { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
        return (strengths, (weakest?.1 ?? 1.0) < 0.9 ? weakest?.0 : nil)
    }

    static func priorRunSummary(_ attributed: AttributedColumn) -> PriorRunSummary {
        let col = attributed.column
        return PriorRunSummary(
            startedAt: col.startedAt,
            build: col.environment.flatMap { $0.osaurusVersion ?? $0.commit },
            catalogHash: col.environment?.catalogHash,
            passed: col.totalPassed,
            scored: col.totalScored,
            skipped: col.perDomain.values.reduce(0) { $0 + $1.skipped },
            errored: col.perDomain.values.reduce(0) { $0 + $1.errored },
            chip: col.environment?.chip,
            totalRamMb: col.environment?.totalRamMb,
            contributor: attributed.contributor
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
        try loadContributionFiles(in: dir).map(\.matrix)
    }

    /// Like `loadContributions(in:)`, but attaches a file-level fallback
    /// contributor per file (e.g. the git author who added it) for columns
    /// whose environment predates the self-declared `contributor` field.
    public static func loadContributionFiles(
        in dir: URL,
        fallbackContributor: (URL) -> String? = { _ in nil }
    ) throws -> [EvalContribution] {
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
        var contributions: [EvalContribution] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let matrix: EvalMatrix
            if let decoded = try? decoder.decode(EvalMatrix.self, from: data), !decoded.models.isEmpty {
                matrix = decoded
            } else if let report = try? decoder.decode(EvalReport.self, from: data), !report.cases.isEmpty {
                matrix = EvalMatrixBuilder.build(from: [report])
            } else {
                continue
            }
            let needsFallback = matrix.models.contains { $0.environment?.contributor == nil }
            contributions.append(
                EvalContribution(
                    matrix: matrix,
                    fallbackContributor: needsFallback ? fallbackContributor(url) : nil
                )
            )
        }
        if contributions.isEmpty { throw EvalMatrixError.noReports(dir.path) }
        return contributions
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
