//
//  ContextOptimizer.swift
//  OsaurusEvalsKit
//
//  The staged context-optimization search the `optimize-context` CLI
//  command drives:
//
//    stage 1  deterministic surface census (no model): price the
//             production baseline, then every one-factor ablation the
//             validator allows (each droppable section, each deferrable
//             tool, the compact-prompt toggle) through the REAL
//             composer via `PromptSurfaceEvaluator`.
//    stage 2  prune: axes that save fewer than the floor (or compose
//             invalid) are recorded but never cost a model run.
//    stage 3  combine: surviving axes are merged into combination
//             candidates (all-sections, all-tools, everything) so
//             interaction effects get measured too, plus the named
//             architecture candidates from the plan (hot tool set,
//             lean guidance, manifest replacement via the exact
//             capabilities_discover list mode, loaded-result
//             compaction) — those skip the savings floor because
//             their cost/benefit is only visible in model runs.
//    stage 4  quality proof (model runs, driven by the CLI): baseline
//             and each candidate run the SAME scoped suites in one
//             process, sequential and warm; every candidate report is
//             diffed against the baseline through the flake-aware
//             `EvalDiff` gate.
//    stage 5  Pareto: gate-passing candidates are ranked on quality,
//             first-step context, cumulative context, peak context,
//             TTFT, throughput, and RAM; the non-dominated set is the
//             promotable frontier.
//
//  This file holds the deterministic pieces (census planning, metrics
//  extraction, dominance ranking, artifact rendering) so they're unit
//  testable without a model; the CLI file owns process bootstrap and
//  run sequencing.
//

import Foundation
import OsaurusCore

// MARK: - Candidates

/// One search candidate: a validated profile plus its deterministic
/// surface pricing (stage-1 evidence).
public struct ContextOptimizerCandidate: Sendable, Codable {
    /// Which stage authored it: "compact" | "section" | "tool" | "combo" | "arch".
    public let kind: String
    public let profile: ExperimentProfile
    /// Census surface (prompt + tool schema estimate) under the profile.
    public let surfaceTokens: Int
    /// Baseline surface minus candidate surface (positive = cheaper).
    public let surfaceSavings: Int

    public init(kind: String, profile: ExperimentProfile, surfaceTokens: Int, surfaceSavings: Int) {
        self.kind = kind
        self.profile = profile
        self.surfaceTokens = surfaceTokens
        self.surfaceSavings = surfaceSavings
    }
}

/// Stage 1–3 output: what will be model-tested, what was pruned and why.
public struct ContextOptimizerPlan: Sendable, Codable {
    public let modelId: String
    /// Baseline surface census cost (prompt + tools).
    public let baselineSurfaceTokens: Int
    public let baselinePromptHash: String
    /// Candidates that survived pruning, largest surface savings first.
    public let candidates: [ContextOptimizerCandidate]
    /// Axes measured but excluded, `name: reason` strings.
    public let pruned: [String]

    public init(
        modelId: String,
        baselineSurfaceTokens: Int,
        baselinePromptHash: String,
        candidates: [ContextOptimizerCandidate],
        pruned: [String]
    ) {
        self.modelId = modelId
        self.baselineSurfaceTokens = baselineSurfaceTokens
        self.baselinePromptHash = baselinePromptHash
        self.candidates = candidates
        self.pruned = pruned
    }

    public func toJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

// MARK: - Stage 1–3: deterministic surface search

public enum ContextOptimizerSearch {

    /// Census the baseline, price every allowed one-factor ablation,
    /// prune no-savers, and build combination candidates. Deterministic
    /// and model-free (compose-only), so the whole plan costs seconds.
    ///
    /// `minSavings` is the prune floor in estimated tokens: a one-factor
    /// axis must save at least this much surface to earn a model run.
    /// `maxCandidates` caps the model-tested set (largest savers win).
    @MainActor
    public static func plan(
        modelId: String,
        minSavings: Int = 25,
        maxCandidates: Int = 10
    ) async -> ContextOptimizerPlan {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-ctxopt-census-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        // Warm the gated stores (see EvalRunnerPromptSurface) so the
        // baseline is order-independent.
        var warmHash = ""
        for _ in 0..<10 {
            let warm = await PromptSurfaceEvaluator.census(workspace: workspace, model: modelId)
            if warm.promptHash == warmHash { break }
            warmHash = warm.promptHash
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let baseline = await PromptSurfaceEvaluator.census(workspace: workspace, model: modelId)

        var singles: [ContextOptimizerCandidate] = []
        var pruned: [String] = []

        /// Price one profile; classify into candidates/pruned.
        func consider(_ kind: String, _ profile: ExperimentProfile) async {
            let errors = profile.validationErrors()
            guard errors.isEmpty else {
                pruned.append("\(profile.name): invalid (\(errors.joined(separator: "; ")))")
                return
            }
            let census = await PromptSurfaceEvaluator.census(
                workspace: workspace,
                model: modelId,
                experiment: profile.experiment
            )
            let savings = baseline.surfaceTokens - census.surfaceTokens
            if savings < minSavings {
                pruned.append(
                    "\(profile.name): saves \(savings) tok < floor \(minSavings)"
                )
                return
            }
            singles.append(
                ContextOptimizerCandidate(
                    kind: kind,
                    profile: profile,
                    surfaceTokens: census.surfaceTokens,
                    surfaceSavings: savings
                )
            )
        }

        // Compact toggle (only meaningful when baseline composed full).
        if !baseline.prefersCompactPrompt {
            await consider(
                "compact",
                ExperimentProfile(
                    name: "compact-prompt",
                    description: "Force the compact prompt variant.",
                    forceCompactPrompt: true
                )
            )
        }

        // One section drop per baseline section (validator refuses the
        // protected ids, so those land in `pruned` with the reason).
        for id in baseline.sectionIds where !PromptComposerExperiment.protectedSectionIds.contains(id) {
            await consider(
                "section",
                ExperimentProfile(
                    name: "drop-\(slug(id))",
                    description: "Drop the '\(id)' prompt section.",
                    dropSections: [id]
                )
            )
        }

        // One tool deferral per baseline schema tool.
        for name in baseline.toolNames where !PromptComposerExperiment.protectedToolNames.contains(name) {
            await consider(
                "tool",
                ExperimentProfile(
                    name: "defer-\(slug(name))",
                    description: "Defer the '\(name)' tool to capability discovery.",
                    deferTools: [name]
                )
            )
        }

        singles.sort { $0.surfaceSavings > $1.surfaceSavings }

        // Combination candidates from the surviving axes: all section
        // drops together, all tool deferrals together, and everything
        // combined — the interaction-effect probes.
        var combos: [ContextOptimizerCandidate] = []
        let sectionIds = Set(singles.filter { $0.kind == "section" }.flatMap { $0.profile.dropSections ?? [] })
        let toolNames = Set(singles.filter { $0.kind == "tool" }.flatMap { $0.profile.deferTools ?? [] })
        let compactWon = singles.contains { $0.kind == "compact" }
        func considerCombo(_ profile: ExperimentProfile) async {
            let census = await PromptSurfaceEvaluator.census(
                workspace: workspace,
                model: modelId,
                experiment: profile.experiment
            )
            combos.append(
                ContextOptimizerCandidate(
                    kind: "combo",
                    profile: profile,
                    surfaceTokens: census.surfaceTokens,
                    surfaceSavings: baseline.surfaceTokens - census.surfaceTokens
                )
            )
        }
        if sectionIds.count > 1 {
            await considerCombo(
                ExperimentProfile(
                    name: "combo-sections",
                    description: "All surviving section drops together.",
                    dropSections: sectionIds.sorted()
                )
            )
        }
        if toolNames.count > 1 {
            await considerCombo(
                ExperimentProfile(
                    name: "combo-tools",
                    description: "All surviving tool deferrals together.",
                    deferTools: toolNames.sorted()
                )
            )
        }
        if (sectionIds.isEmpty ? 0 : 1) + (toolNames.isEmpty ? 0 : 1) + (compactWon ? 1 : 0) > 1 {
            await considerCombo(
                ExperimentProfile(
                    name: "combo-all",
                    description: "Every surviving axis together.",
                    forceCompactPrompt: compactWon ? true : nil,
                    dropSections: sectionIds.isEmpty ? nil : sectionIds.sorted(),
                    deferTools: toolNames.isEmpty ? nil : toolNames.sorted()
                )
            )
        }

        // Architecture candidates (plan §5) — the named designs, priced
        // through the same census. They are EXEMPT from the savings floor:
        // two of them (loaded-result compaction; manifest replacement's
        // discovery cost) move history/cumulative tokens that only model
        // runs can price, so a small census delta must not prune them.
        var archs: [ContextOptimizerCandidate] = []
        func considerArch(_ profile: ExperimentProfile) async {
            let errors = profile.validationErrors()
            guard errors.isEmpty else {
                pruned.append("\(profile.name): invalid (\(errors.joined(separator: "; ")))")
                return
            }
            let census = await PromptSurfaceEvaluator.census(
                workspace: workspace,
                model: modelId,
                experiment: profile.experiment
            )
            archs.append(
                ContextOptimizerCandidate(
                    kind: "arch",
                    profile: profile,
                    surfaceTokens: census.surfaceTokens,
                    surfaceSavings: baseline.surfaceTokens - census.surfaceTokens
                )
            )
        }

        // Smaller immutable hot tool set: defer every baseline schema tool
        // outside `hotSetToolNames` (the loop contract + first-turn
        // primitives). Gated built-ins outside the hot set become
        // dynamic-only in the same move.
        let hotDeferred = baseline.toolNames
            .filter { !PromptComposerExperiment.hotSetToolNames.contains($0) }
            .sorted()
        if !hotDeferred.isEmpty {
            await considerArch(
                ExperimentProfile(
                    name: "arch-hot-set",
                    description:
                        "Immutable hot tool set: only the loop contract + first-turn "
                        + "primitives stay in the schema; everything else defers to "
                        + "capability discovery.",
                    deferTools: hotDeferred
                )
            )
        }

        // Selective guidance loading: drop the static guidance prose
        // sections together (they would load on demand in the shipped
        // design; the ablation measures what always-on guidance is worth).
        let guidanceIds = [
            "modelFamilyGuidance", "agentLoopGuidance", "codeStyle",
            "riskAware", "selfImprovement", "capabilityNudge",
        ].filter { baseline.sectionIds.contains($0) }
        if guidanceIds.count > 1 {
            await considerArch(
                ExperimentProfile(
                    name: "arch-lean-guidance",
                    description: "Drop the always-on guidance prose sections together.",
                    dropSections: guidanceIds
                )
            )
        }

        // Manifest replacement: drop the enabled-capabilities manifest.
        // Valid only because `capabilities_discover {\"list\": \"enabled\"}`
        // now provides the exact paginated listing; the capability-claim
        // and tool-use gates decide whether the replacement holds.
        if baseline.sectionIds.contains("enabledManifest") {
            await considerArch(
                ExperimentProfile(
                    name: "arch-manifest-replacement",
                    description:
                        "Replace the prompt manifest with the exact paginated "
                        + "capabilities_discover list mode.",
                    dropSections: ["enabledManifest"]
                )
            )
        }

        // Loaded-result compaction: smaller skill-reference budget +
        // skeleton schemas for capabilities_load results. Zero surface
        // delta by construction — the win (if any) is cumulative.
        await considerArch(
            ExperimentProfile(
                name: "arch-compact-loaded-results",
                description:
                    "Compact capabilities_load results (skill references + loaded "
                    + "schemas) in history.",
                compactLoadedResults: true
            )
        )

        // Cap the model-tested set: architecture designs and combos first
        // (they answer the headline questions), then the largest
        // single-axis savers. Dedupe by profile hash — e.g. the
        // one-factor `drop-enabledmanifest` composes identically to
        // `arch-manifest-replacement`, and paying for the same variant
        // twice buys nothing.
        var selected: [ContextOptimizerCandidate] = []
        var selectedHashes = Set<String>()
        func select(_ candidate: ContextOptimizerCandidate) -> Bool {
            guard selectedHashes.insert(candidate.profile.profileHash).inserted else {
                pruned.append(
                    "\(candidate.profile.name): composes identically to an already-selected candidate"
                )
                return false
            }
            selected.append(candidate)
            return true
        }
        for candidate in archs + combos.sorted(by: { $0.surfaceSavings > $1.surfaceSavings }) {
            _ = select(candidate)
        }
        for single in singles {
            if selected.count >= maxCandidates {
                pruned.append(
                    "\(single.profile.name): saves \(single.surfaceSavings) tok but candidate "
                        + "cap \(maxCandidates) reached"
                )
                continue
            }
            _ = select(single)
        }

        return ContextOptimizerPlan(
            modelId: modelId,
            baselineSurfaceTokens: baseline.surfaceTokens,
            baselinePromptHash: baseline.promptHash,
            candidates: selected,
            pruned: pruned
        )
    }

    /// Profile-name-safe slug for a section/tool id.
    static func slug(_ raw: String) -> String {
        raw.map { $0.isLetter || $0.isNumber ? Character($0.lowercased()) : "-" }
            .reduce(into: "") { acc, ch in
                if ch == "-" && acc.hasSuffix("-") { return }
                acc.append(ch)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

// MARK: - Stage 5: Pareto ranking

/// One profile's quality + context + perf objectives, extracted from its
/// (suite-merged) report. Directions: passRate ↑; every token/latency/RAM
/// objective ↓ except decode tok/s ↑.
public struct ParetoCandidateMetrics: Sendable, Codable {
    public let name: String
    public let profileHash: String?
    public let passed: Int
    public let scored: Int
    public let meanFirstStepTokens: Double?
    public let meanCumulativeTokens: Double?
    public let meanPeakContextTokens: Double?
    public let meanTtftMs: Double?
    public let meanDecodeTps: Double?
    public let peakRamMb: Double?
    /// Whether the no-regression gate vs baseline passed. Baseline rows
    /// carry `true` by definition.
    public let gatePassed: Bool
    public let gateNotes: [String]

    public var passRate: Double {
        scored > 0 ? Double(passed) / Double(scored) : 0
    }

    public init(
        name: String,
        profileHash: String?,
        passed: Int,
        scored: Int,
        meanFirstStepTokens: Double?,
        meanCumulativeTokens: Double?,
        meanPeakContextTokens: Double?,
        meanTtftMs: Double?,
        meanDecodeTps: Double?,
        peakRamMb: Double?,
        gatePassed: Bool,
        gateNotes: [String]
    ) {
        self.name = name
        self.profileHash = profileHash
        self.passed = passed
        self.scored = scored
        self.meanFirstStepTokens = meanFirstStepTokens
        self.meanCumulativeTokens = meanCumulativeTokens
        self.meanPeakContextTokens = meanPeakContextTokens
        self.meanTtftMs = meanTtftMs
        self.meanDecodeTps = meanDecodeTps
        self.peakRamMb = peakRamMb
        self.gatePassed = gatePassed
        self.gateNotes = gateNotes
    }

    /// Extract objectives from a report (all rows, telemetry means).
    public static func from(
        name: String,
        report: EvalReport,
        gatePassed: Bool,
        gateNotes: [String]
    ) -> ParetoCandidateMetrics {
        let rows = report.cases
        let scoredRows = rows.filter { $0.outcome == .passed || $0.outcome == .failed }
        func mean(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        let telem = rows.compactMap(\.telemetry)
        let attributed = rows.compactMap(\.context)
        return ParetoCandidateMetrics(
            name: name,
            profileHash: report.environment?.experimentProfileHash,
            passed: scoredRows.filter { $0.outcome == .passed }.count,
            scored: scoredRows.count,
            meanFirstStepTokens: mean(attributed.compactMap { $0.firstStepInputTokens.map(Double.init) }),
            meanCumulativeTokens: mean(telem.compactMap { $0.promptTokensTotal.map(Double.init) }),
            meanPeakContextTokens: mean(telem.compactMap { $0.peakContextTokens.map(Double.init) }),
            meanTtftMs: mean(telem.compactMap(\.ttftMs)),
            meanDecodeTps: mean(telem.compactMap(\.decodeTokensPerSecond)),
            peakRamMb: telem.compactMap(\.peakPhysFootprintMb).max(),
            gatePassed: gatePassed,
            gateNotes: gateNotes
        )
    }
}

/// The ranking artifact: every candidate's objectives plus the
/// non-dominated frontier among gate-passing candidates.
public struct ParetoRanking: Sendable, Codable {
    public let generatedAt: String
    public let baseline: ParetoCandidateMetrics
    public let candidates: [ParetoCandidateMetrics]
    /// Names of the gate-passing, non-dominated candidates (the
    /// promotable set), sorted by first-step savings descending.
    public let frontier: [String]

    public init(
        generatedAt: String,
        baseline: ParetoCandidateMetrics,
        candidates: [ParetoCandidateMetrics]
    ) {
        self.generatedAt = generatedAt
        self.baseline = baseline
        self.candidates = candidates
        self.frontier = Self.frontier(candidates: candidates, baseline: baseline)
    }

    /// `a` dominates `b` when it is at least as good on every defined
    /// shared objective and strictly better on at least one. Objectives
    /// missing on either side are skipped (unknown ≠ worse), which makes
    /// dominance conservative — a candidate can only be excluded on
    /// measured evidence.
    static func dominates(_ a: ParetoCandidateMetrics, _ b: ParetoCandidateMetrics) -> Bool {
        var strictlyBetter = false
        // (aValue, bValue, higherIsBetter)
        let axes: [(Double?, Double?, Bool)] = [
            (a.passRate, b.passRate, true),
            (a.meanFirstStepTokens, b.meanFirstStepTokens, false),
            (a.meanCumulativeTokens, b.meanCumulativeTokens, false),
            (a.meanPeakContextTokens, b.meanPeakContextTokens, false),
            (a.meanTtftMs, b.meanTtftMs, false),
            (a.meanDecodeTps, b.meanDecodeTps, true),
            (a.peakRamMb, b.peakRamMb, false),
        ]
        for (aValue, bValue, higherIsBetter) in axes {
            guard let aValue, let bValue else { continue }
            let better = higherIsBetter ? aValue > bValue : aValue < bValue
            let worse = higherIsBetter ? aValue < bValue : aValue > bValue
            if worse { return false }
            if better { strictlyBetter = true }
        }
        return strictlyBetter
    }

    static func frontier(
        candidates: [ParetoCandidateMetrics],
        baseline: ParetoCandidateMetrics
    ) -> [String] {
        // Only gate-passing candidates are promotable; the baseline also
        // competes (a candidate dominated by the baseline saves nothing).
        let eligible = candidates.filter(\.gatePassed)
        let field = eligible + [baseline]
        return eligible
            .filter { candidate in
                !field.contains { other in
                    other.name != candidate.name && dominates(other, candidate)
                }
            }
            .sorted {
                ($0.meanFirstStepTokens ?? .infinity) < ($1.meanFirstStepTokens ?? .infinity)
            }
            .map(\.name)
    }

    public func toJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func formatMarkdown() -> String {
        var lines: [String] = []
        lines.append("# Context Optimization — Pareto Ranking")
        lines.append("")
        lines.append("- Generated: \(generatedAt)")
        lines.append(
            "- Frontier (gate-passing, non-dominated): "
                + (frontier.isEmpty ? "(none)" : frontier.map { "`\($0)`" }.joined(separator: ", "))
        )
        lines.append("")
        lines.append(
            "| Profile | Gate | Pass | 1st-step tok | cum tok | peak tok | TTFT ms | tok/s | RAM MB |"
        )
        lines.append("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        func fmt(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "—" }
        func row(_ m: ParetoCandidateMetrics, marker: String) -> String {
            "| \(marker)\(m.name) | \(m.gatePassed ? "PASS" : "FAIL") "
                + "| \(m.passed)/\(m.scored) | \(fmt(m.meanFirstStepTokens)) "
                + "| \(fmt(m.meanCumulativeTokens)) | \(fmt(m.meanPeakContextTokens)) "
                + "| \(fmt(m.meanTtftMs)) | "
                + (m.meanDecodeTps.map { String(format: "%.1f", $0) } ?? "—")
                + " | \(fmt(m.peakRamMb)) |"
        }
        lines.append(row(baseline, marker: "**baseline** "))
        for candidate in candidates.sorted(by: {
            ($0.meanFirstStepTokens ?? .infinity) < ($1.meanFirstStepTokens ?? .infinity)
        }) {
            lines.append(row(candidate, marker: frontier.contains(candidate.name) ? "★ " : ""))
        }
        let failed = candidates.filter { !$0.gatePassed }
        if !failed.isEmpty {
            lines.append("")
            lines.append("## Gate Failures")
            lines.append("")
            for m in failed {
                lines.append("- `\(m.name)`:")
                for note in m.gateNotes { lines.append("  - \(note)") }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
