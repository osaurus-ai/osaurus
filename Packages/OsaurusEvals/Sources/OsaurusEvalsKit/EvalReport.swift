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

/// Per-case generation + resource telemetry — the substrate the
/// optimization loop's speed/RAM workstream measures against. Every
/// field is optional so a row that didn't (or couldn't) sample a metric
/// reads as "no measurement" rather than a zeroed regression: remote
/// runs have no peak footprint, non-streaming steps have no decode tps,
/// and the very first case in a process has no meaningful KV delta.
public struct EvalCaseTelemetry: Sendable, Codable {
    /// Token-weighted mean decode speed (tokens/sec) across model steps.
    public let decodeTokensPerSecond: Double?
    /// First model step's prefill (prompt-processing) speed (tokens/sec).
    public let prefillTokensPerSecond: Double?
    /// Time-to-first-token for the first model step, milliseconds.
    public let ttftMs: Double?
    /// Total generated tokens across all model steps.
    public let completionTokens: Int?
    /// Peak physical footprint (Activity-Monitor "Memory") sampled across
    /// the case, in megabytes — the value the AGENTS.md RAM gate reads.
    public let peakPhysFootprintMb: Double?
    /// Mean process CPU utilization (% of a single core; >100% when multiple
    /// cores are busy) across the case window. On Apple silicon MLX decode is
    /// GPU-bound, so this is HOST overhead — tokenizer, sampler, JSON, stream
    /// plumbing, harness orchestration — not the model's matmuls. A high
    /// value is an optimization target in its own right, not GPU compute.
    public let meanCpuPercent: Double?
    /// Peak instantaneous process CPU utilization (%) across the sampling
    /// ticks — the burst, vs the sustained `meanCpuPercent`.
    public let peakCpuPercent: Double?
    /// KV prefix-cache hits gained during this case (after − before from
    /// `ModelRuntime.batchDiagnosticsSnapshot`). A positive value on a
    /// multi-step agent_loop case is the prefix-reuse proof — for
    /// full-attention models. Stays 0 for hybrid SSM models (Qwen3), whose
    /// reuse shows up in the SSM-companion counters below; reading KV alone
    /// for a hybrid model would falsely report "no reuse".
    public let kvPrefixHitsDelta: Int?
    /// KV prefix-cache misses gained during this case — pairs with hits
    /// to show whether later iterations reused or re-prefilled.
    public let kvPrefixMissesDelta: Int?
    /// SSM-companion cache hits gained during this case — the cache-reuse
    /// signal for hybrid SSM models (Qwen-style), where a KV-prefix hit
    /// alone is not sufficient proof (per AGENTS.md cache-proof rules).
    public let ssmCompanionHitsDelta: Int?
    /// SSM-companion re-derivations gained during this case. A re-derive
    /// is the SSM analog of a cold prefill; rising re-derives with flat
    /// hits means the companion cache isn't being reused.
    public let ssmCompanionReDerivesDelta: Int?
    /// Disk-L2 (block-disk) KV-cache hits gained during this case. The eval
    /// path exercises the `~/.osaurus/cache/kv_v2` lane, so this is a REAL
    /// runtime counter (not a paged-only concept): a hit proves a prefix was
    /// restored from the on-disk KV store rather than re-prefilled. Within a
    /// single run the in-memory cache usually serves a shared prefix first,
    /// so hits typically appear across runs (warm disk, cold memory).
    public let diskL2HitsDelta: Int?
    /// Disk-L2 KV-cache misses gained during this case (prefix not found on
    /// disk → had to prefill + store).
    public let diskL2MissesDelta: Int?
    /// Disk-L2 KV-cache stores gained during this case — proves the disk
    /// lane is actively persisting prefixes for later reuse.
    public let diskL2StoresDelta: Int?

    public init(
        decodeTokensPerSecond: Double? = nil,
        prefillTokensPerSecond: Double? = nil,
        ttftMs: Double? = nil,
        completionTokens: Int? = nil,
        peakPhysFootprintMb: Double? = nil,
        meanCpuPercent: Double? = nil,
        peakCpuPercent: Double? = nil,
        kvPrefixHitsDelta: Int? = nil,
        kvPrefixMissesDelta: Int? = nil,
        ssmCompanionHitsDelta: Int? = nil,
        ssmCompanionReDerivesDelta: Int? = nil,
        diskL2HitsDelta: Int? = nil,
        diskL2MissesDelta: Int? = nil,
        diskL2StoresDelta: Int? = nil
    ) {
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.ttftMs = ttftMs
        self.completionTokens = completionTokens
        self.peakPhysFootprintMb = peakPhysFootprintMb
        self.meanCpuPercent = meanCpuPercent
        self.peakCpuPercent = peakCpuPercent
        self.kvPrefixHitsDelta = kvPrefixHitsDelta
        self.kvPrefixMissesDelta = kvPrefixMissesDelta
        self.ssmCompanionHitsDelta = ssmCompanionHitsDelta
        self.ssmCompanionReDerivesDelta = ssmCompanionReDerivesDelta
        self.diskL2HitsDelta = diskL2HitsDelta
        self.diskL2MissesDelta = diskL2MissesDelta
        self.diskL2StoresDelta = diskL2StoresDelta
    }

    /// True when no field carries a measurement — used to avoid emitting
    /// an all-null telemetry object on deterministic (no-model) rows.
    public var isEmpty: Bool {
        decodeTokensPerSecond == nil && prefillTokensPerSecond == nil
            && ttftMs == nil && completionTokens == nil
            && peakPhysFootprintMb == nil && meanCpuPercent == nil
            && peakCpuPercent == nil && kvPrefixHitsDelta == nil
            && kvPrefixMissesDelta == nil && ssmCompanionHitsDelta == nil
            && ssmCompanionReDerivesDelta == nil && diskL2HitsDelta == nil
            && diskL2MissesDelta == nil && diskL2StoresDelta == nil
    }
}

/// Per-tool usage counters for one `agent_loop` case — the
/// tool-discipline scorecard. `calls` counts every processed call
/// (executed + dedupe replays), `errors` counts error envelopes,
/// `deduped` counts dedupe replays.
public struct ToolUsageStat: Sendable, Codable {
    public let tool: String
    public let calls: Int
    public let errors: Int
    public let deduped: Int

    public init(tool: String, calls: Int, errors: Int, deduped: Int) {
        self.tool = tool
        self.calls = calls
        self.errors = errors
        self.deduped = deduped
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
    /// Per-tool usage counters for `agent_loop` rows. nil for other
    /// domains. Aggregated suite-wide into the console summary so each
    /// model gets a tool-discipline scorecard, not just pass/fail.
    public let toolUsage: [ToolUsageStat]?
    /// Generation + resource telemetry (decode tok/s, TTFT, prefill
    /// tok/s, peak RAM, KV prefix-hit delta). nil for deterministic
    /// (no-model) rows; populated for model-driven domains. The
    /// optimization loop's speed/RAM scoreboard reads this.
    public let telemetry: EvalCaseTelemetry?

    public init(
        id: String,
        label: String,
        domain: String,
        query: String? = nil,
        outcome: EvalCaseOutcome,
        capabilitySearch: CapabilitySearchEvaluation? = nil,
        notes: [String],
        modelId: String,
        latencyMs: Double?,
        toolUsage: [ToolUsageStat]? = nil,
        telemetry: EvalCaseTelemetry? = nil
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
        self.toolUsage = toolUsage
        self.telemetry = (telemetry?.isEmpty ?? true) ? nil : telemetry
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
    /// Run provenance (hardware, OS, Osaurus build, judge, catalog hash).
    /// nil on reports written before this block existed, and on internal
    /// constructions that don't attach it; the CLI's `run` path populates
    /// it so every emitted report JSON is self-describing — the substrate
    /// crowdsourced model-compatibility contributions are built from.
    public let environment: RunEnvironment?

    public var counts: Counts { Counts(cases: cases) }

    public init(
        modelId: String,
        startedAt: String,
        cases: [EvalCaseReport],
        environment: RunEnvironment? = nil
    ) {
        self.modelId = modelId
        self.startedAt = startedAt
        self.cases = cases
        self.environment = environment
    }

    /// Return a copy with `environment` attached — used by the CLI to stamp
    /// provenance onto the report the runner produced before it is printed
    /// and written to JSON.
    public func withEnvironment(_ environment: RunEnvironment) -> EvalReport {
        EvalReport(modelId: modelId, startedAt: startedAt, cases: cases, environment: environment)
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
            if let telemetryLine = Self.formatTelemetryLine(row.telemetry) {
                lines.append("       · \(telemetryLine)")
            }
            if verbose { appendVerboseDiagnostics(for: row, into: &lines) }
        }
        if let usageLines = formatAggregatedToolUsage() {
            lines.append("")
            lines.append(contentsOf: usageLines)
        }
        if let perfLines = formatAggregatedTelemetry() {
            lines.append("")
            lines.append(contentsOf: perfLines)
        }
        return lines.joined(separator: "\n")
    }

    /// Suite-wide tool-usage table aggregated across every `agent_loop`
    /// row that carried per-tool counters. nil when no row did (non-loop
    /// suites print nothing extra).
    private func formatAggregatedToolUsage() -> [String]? {
        var calls: [String: Int] = [:]
        var errors: [String: Int] = [:]
        var deduped: [String: Int] = [:]
        for row in cases {
            for stat in row.toolUsage ?? [] {
                calls[stat.tool, default: 0] += stat.calls
                errors[stat.tool, default: 0] += stat.errors
                deduped[stat.tool, default: 0] += stat.deduped
            }
        }
        guard !calls.isEmpty else { return nil }
        var lines = ["[tool usage] (agent_loop rows, suite-wide)"]
        for tool in calls.keys.sorted() {
            let total = calls[tool] ?? 0
            let err = errors[tool] ?? 0
            let dd = deduped[tool] ?? 0
            let toolCol = tool.padding(toLength: max(22, tool.count), withPad: " ", startingAt: 0)
            lines.append(
                "  \(toolCol) calls=\(total)  errors=\(err)  deduped=\(dd)"
            )
        }
        return lines
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

    /// One-line per-case perf annotation (`decode … TTFT … prefill …
    /// RAM … KV+…`), or nil when the row carried no telemetry. Static so
    /// the diff/scoreboard surfaces can reuse the exact same formatting.
    static func formatTelemetryLine(_ t: EvalCaseTelemetry?) -> String? {
        guard let t, !t.isEmpty else { return nil }
        var parts: [String] = []
        if let d = t.decodeTokensPerSecond { parts.append(String(format: "decode %.1f tok/s", d)) }
        if let ttft = t.ttftMs { parts.append(String(format: "TTFT %.0fms", ttft)) }
        if let p = t.prefillTokensPerSecond { parts.append(String(format: "prefill %.0f tok/s", p)) }
        if let ram = t.peakPhysFootprintMb { parts.append(String(format: "peakRAM %.0fMB", ram)) }
        if let cpu = t.meanCpuPercent {
            if let peak = t.peakCpuPercent, peak > cpu + 1 {
                parts.append(String(format: "CPU %.0f%%/peak %.0f%%", cpu, peak))
            } else {
                parts.append(String(format: "CPU %.0f%%", cpu))
            }
        }
        if let hits = t.kvPrefixHitsDelta {
            let misses = t.kvPrefixMissesDelta ?? 0
            parts.append("KV +\(hits)hit/+\(misses)miss")
        }
        if let ssmHits = t.ssmCompanionHitsDelta {
            let red = t.ssmCompanionReDerivesDelta ?? 0
            parts.append("SSM +\(ssmHits)hit/+\(red)rederive")
        }
        if let l2Hits = t.diskL2HitsDelta {
            let stores = t.diskL2StoresDelta ?? 0
            if l2Hits != 0 || stores != 0 {
                parts.append("L2 +\(l2Hits)hit/+\(stores)store")
            }
        }
        if let tokens = t.completionTokens { parts.append("\(tokens) tok") }
        return parts.isEmpty ? nil : "perf: " + parts.joined(separator: "  ")
    }

    /// Suite-wide perf rollup across every row that carried telemetry:
    /// mean decode tok/s, mean TTFT, and the peak-of-peak RAM. nil when
    /// no row sampled anything (deterministic-only suites print nothing).
    private func formatAggregatedTelemetry() -> [String]? {
        let telemetered = cases.compactMap(\.telemetry).filter { !$0.isEmpty }
        guard !telemetered.isEmpty else { return nil }
        var lines = ["[perf] (model-driven rows, suite-wide)"]
        let decodes = telemetered.compactMap(\.decodeTokensPerSecond)
        if !decodes.isEmpty {
            let mean = decodes.reduce(0, +) / Double(decodes.count)
            lines.append(
                String(
                    format: "  decode tok/s   mean=%.1f  min=%.1f  max=%.1f  (n=%d)",
                    mean,
                    decodes.min() ?? 0,
                    decodes.max() ?? 0,
                    decodes.count
                )
            )
        }
        let ttfts = telemetered.compactMap(\.ttftMs)
        if !ttfts.isEmpty {
            let mean = ttfts.reduce(0, +) / Double(ttfts.count)
            lines.append(
                String(
                    format: "  TTFT ms        mean=%.0f  min=%.0f  max=%.0f  (n=%d)",
                    mean,
                    ttfts.min() ?? 0,
                    ttfts.max() ?? 0,
                    ttfts.count
                )
            )
        }
        let prefills = telemetered.compactMap(\.prefillTokensPerSecond)
        if !prefills.isEmpty {
            let mean = prefills.reduce(0, +) / Double(prefills.count)
            lines.append(String(format: "  prefill tok/s  mean=%.0f  (n=%d)", mean, prefills.count))
        }
        let rams = telemetered.compactMap(\.peakPhysFootprintMb)
        if !rams.isEmpty {
            lines.append(String(format: "  peak RAM MB    max=%.0f  (n=%d)", rams.max() ?? 0, rams.count))
        }
        let cpus = telemetered.compactMap(\.meanCpuPercent)
        if !cpus.isEmpty {
            let mean = cpus.reduce(0, +) / Double(cpus.count)
            let peak = telemetered.compactMap(\.peakCpuPercent).max() ?? mean
            lines.append(
                String(format: "  CPU %%          mean=%.0f  peak=%.0f  (n=%d)", mean, peak, cpus.count)
            )
        }
        let kvHits = telemetered.compactMap(\.kvPrefixHitsDelta).reduce(0, +)
        let kvMisses = telemetered.compactMap(\.kvPrefixMissesDelta).reduce(0, +)
        if kvHits != 0 || kvMisses != 0 {
            lines.append("  KV prefix      +\(kvHits) hits  +\(kvMisses) misses (suite-wide delta)")
        }
        let l2Hits = telemetered.compactMap(\.diskL2HitsDelta).reduce(0, +)
        let l2Misses = telemetered.compactMap(\.diskL2MissesDelta).reduce(0, +)
        let l2Stores = telemetered.compactMap(\.diskL2StoresDelta).reduce(0, +)
        if l2Hits != 0 || l2Misses != 0 || l2Stores != 0 {
            lines.append(
                "  KV disk-L2     +\(l2Hits) hits  +\(l2Misses) misses  +\(l2Stores) stores (suite-wide delta)"
            )
        }
        return lines
    }
}
