//
//  ContextOptimizeCLI.swift
//  osaurus-evals
//
//  `optimize-context` — the staged context-optimization command:
//
//    1. deterministic surface census + one-factor ablations (no model),
//    2. prune invalid / no-savings axes,
//    3. combination candidates from the survivors,
//    4. sequential warm-model quality runs: baseline first, then every
//       candidate, in ONE process (the model loads once; profiles are
//       swapped through `PromptComposerExperimentScope` between runs),
//    5. flake-aware no-regression gating vs the in-process baseline and
//       a Pareto ranking artifact (JSON + Markdown).
//
//  Artifacts (all under --out-dir):
//    plan.json               stage 1–3 census + pruned axes
//    baseline.json           merged baseline report (env-stamped)
//    candidate-<name>.json   merged per-candidate report (profile-stamped)
//    pareto.json / pareto.md ranking + gate failures
//
//  Resume: an existing, decodable report file skips its run — kill and
//  re-invoke to continue a long search.
//

import Foundation
import OsaurusCore
import OsaurusEvalsKit

extension OsaurusEvalsCLI {

    @MainActor
    static func runOptimizeContext(_ args: [String]) async -> Int32 {
        // Headless-harness hooks (mirrors runCommand).
        ProviderCredentialPromptService.bypassUI = { _ in .cancelled }

        let opts: OptimizeOptions
        do {
            opts = try OptimizeOptions.parse(args)
        } catch {
            FileHandle.standardError.write(
                Data(("argument error: \(error.localizedDescription)\n").utf8)
            )
            printUsage()
            return 2
        }

        let suites: [EvalSuite]
        do {
            suites = try opts.suites.map { try EvalSuite.load(from: $0) }
        } catch {
            FileHandle.standardError.write(
                Data(("failed to load suite: \(error.localizedDescription)\n").utf8)
            )
            return 2
        }

        let outDir = URL(fileURLWithPath: opts.outDir, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(
                Data(("failed to create --out-dir: \(error.localizedDescription)\n").utf8)
            )
            return 2
        }

        // One bootstrap for the whole search (hermetic storage, plugins,
        // indices) — identical to the `run` command's setup so candidate
        // runs measure the same world.
        let bootstrapPlan = EvalBootstrapPlan.merged(
            suites.map {
                EvalBootstrapPlan.make(suite: $0, filter: opts.filter, preference: .automatic)
            }
        )
        _ = EvalBootstrap.configureIsolatedRunStorage(for: bootstrapPlan)
        await EvalBootstrap.run(bootstrapPlan)
        let ephemeralProviderIds = await EvalRemoteProviderBootstrap.connectIfNeeded(
            modelIds: EvalRemoteProviderBootstrap.candidateModelIds(runModel: opts.model)
        )
        defer { EvalRemoteProviderBootstrap.teardown(ephemeralProviderIds) }

        // Census model id: the explicit --model, or the configured local
        // model when `auto` (same resolution the composer itself uses).
        let censusModelId: String
        switch opts.model {
        case .explicit(let provider, let name):
            censusModelId = provider.map { "\($0)/\(name)" } ?? name
        case .foundation:
            censusModelId = "foundation"
        case .keepCurrent:
            censusModelId = ChatConfigurationStore.load().coreModelIdentifier ?? "foundation"
        }

        // ── Stage 1–3: deterministic search plan ────────────────────
        status("census: pricing one-factor ablations for \(censusModelId) (no model calls)")
        let plan = await ContextOptimizerSearch.plan(
            modelId: censusModelId,
            minSavings: opts.minSavings,
            maxCandidates: opts.maxCandidates
        )
        do {
            try plan.toJSON().write(to: outDir.appendingPathComponent("plan.json"))
        } catch {
            status("WARN: failed to write plan.json: \(error.localizedDescription)")
        }
        status(
            "census: baseline surface \(plan.baselineSurfaceTokens) tok; "
                + "\(plan.candidates.count) candidate(s), \(plan.pruned.count) pruned"
        )
        for candidate in plan.candidates {
            status(
                "  candidate \(candidate.profile.name) [\(candidate.kind)] "
                    + "saves \(candidate.surfaceSavings) tok (surface \(candidate.surfaceTokens))"
            )
        }
        if opts.censusOnly {
            status("--census-only: stopping before model runs")
            return 0
        }

        // ── Stage 4: sequential warm quality runs ───────────────────
        // Baseline FIRST (same process, same world), then candidates in
        // plan order. Every run is suite-merged into one report so the
        // gate and Pareto extraction see the whole scoped surface.
        status(
            "baseline: running \(suites.count) suite(s) ×\(opts.repeatCount) trial(s) "
                + "on \(censusModelId)"
        )
        PromptComposerExperimentScope.current = nil
        let baselineReport = await runMergedReport(
            name: "baseline",
            profile: .baseline,
            suites: suites,
            opts: opts,
            censusModelId: censusModelId,
            outDir: outDir
        )
        status(
            "baseline: \(baselineReport.counts.passed)/\(baselineReport.counts.total) passed"
        )

        var metrics: [ParetoCandidateMetrics] = []
        for candidate in plan.candidates {
            let profile = candidate.profile
            status("candidate \(profile.name): running (saves \(candidate.surfaceSavings) tok surface)")
            PromptComposerExperimentScope.current = profile.experiment
            let report = await runMergedReport(
                name: "candidate-\(profile.name)",
                profile: profile,
                suites: suites,
                opts: opts,
                censusModelId: censusModelId,
                outDir: outDir
            )
            PromptComposerExperimentScope.current = nil

            let gate = EvalDiff.compare(
                baseline: AgentLoopRegressionReportSet(
                    label: "baseline",
                    reports: [.init(name: "baseline", url: nil, report: baselineReport)]
                ),
                current: AgentLoopRegressionReportSet(
                    label: profile.name,
                    reports: [.init(name: profile.name, url: nil, report: report)]
                )
            )
            var gateNotes: [String] = []
            for regression in gate.regressions {
                gateNotes.append(
                    "regression: \(regression.id) "
                        + "\(regression.baselineOutcome?.rawValue ?? "—") → "
                        + "\(regression.currentOutcome?.rawValue ?? "—")"
                )
            }
            for failure in gate.newFailures {
                gateNotes.append("new failure: \(failure.id)")
            }
            for flaky in gate.suspectedFlaky {
                gateNotes.append("suspected flaky flip (non-blocking): \(flaky.id)")
            }
            let m = ParetoCandidateMetrics.from(
                name: profile.name,
                report: report,
                gatePassed: !gate.hasBlockingRegressions,
                gateNotes: gateNotes
            )
            metrics.append(m)
            status(
                "candidate \(profile.name): \(m.passed)/\(m.scored) passed, "
                    + "gate \(m.gatePassed ? "PASS" : "FAIL")"
            )
        }

        // ── Stage 5: Pareto artifact ────────────────────────────────
        let ranking = ParetoRanking(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            baseline: ParetoCandidateMetrics.from(
                name: "baseline",
                report: baselineReport,
                gatePassed: true,
                gateNotes: []
            ),
            candidates: metrics
        )
        do {
            try ranking.toJSON().write(to: outDir.appendingPathComponent("pareto.json"))
            try Data(ranking.formatMarkdown().utf8)
                .write(to: outDir.appendingPathComponent("pareto.md"))
        } catch {
            status("WARN: failed to write pareto artifacts: \(error.localizedDescription)")
        }
        print(ranking.formatMarkdown())

        // ── Stage 6: finalist reruns + STRICT promotion gate ────────
        // The search phase's flake-aware diff triages; promotion is the
        // strict repeat-aware `PromotionGate` over a HIGHER-trial rerun
        // of both the baseline and every frontier candidate (paired: same
        // process, same trial count).
        if !opts.skipFinalists && !ranking.frontier.isEmpty {
            let finalistRepeat = max(opts.finalistRepeat, opts.repeatCount)
            status(
                "finalists: rerunning baseline + \(ranking.frontier.count) frontier "
                    + "candidate(s) ×\(finalistRepeat) trial(s)"
            )
            let finalistOpts = opts.withRepeat(finalistRepeat)
            PromptComposerExperimentScope.current = nil
            let finalBaseline = await runMergedReport(
                name: "finalist-baseline",
                profile: .baseline,
                suites: suites,
                opts: finalistOpts,
                censusModelId: censusModelId,
                outDir: outDir
            )
            var promotions: [String: PromotionGateResult] = [:]
            for name in ranking.frontier {
                guard let candidate = plan.candidates.first(where: { $0.profile.name == name })
                else { continue }
                PromptComposerExperimentScope.current = candidate.profile.experiment
                let finalReport = await runMergedReport(
                    name: "finalist-\(name)",
                    profile: candidate.profile,
                    suites: suites,
                    opts: finalistOpts,
                    censusModelId: censusModelId,
                    outDir: outDir
                )
                PromptComposerExperimentScope.current = nil
                let verdict = PromotionGate.evaluate(
                    baseline: finalBaseline,
                    candidate: finalReport,
                    maxFirstStepContextTokens: opts.contextBudget
                )
                promotions[name] = verdict
                status(
                    "finalist \(name): \(verdict.promotable ? "PROMOTABLE" : "BLOCKED")"
                        + (verdict.blocking.isEmpty
                            ? "" : " — \(verdict.blocking.joined(separator: "; "))")
                )
            }
            writePromotionArtifacts(promotions, outDir: outDir)
        }

        status("artifacts: \(outDir.path)")
        return 0
    }

    /// Run every scoped suite under the CURRENT experiment scope and
    /// merge rows into one env-stamped report written to `<name>.json`.
    /// Resumable: an existing decodable report is reused.
    @MainActor
    private static func runMergedReport(
        name: String,
        profile: ExperimentProfile?,
        suites: [EvalSuite],
        opts: OptimizeOptions,
        censusModelId: String,
        outDir: URL
    ) async -> EvalReport {
        let url = outDir.appendingPathComponent("\(name).json")
        if opts.resume,
            let data = try? Data(contentsOf: url),
            let report = try? JSONDecoder().decode(EvalReport.self, from: data),
            !report.cases.isEmpty
        {
            status("\(name): resume — reusing \(url.lastPathComponent)")
            return report
        }
        var rows: [EvalCaseReport] = []
        var startedAt: String?
        for suite in suites {
            let report = await EvalRunner.run(
                suite: suite,
                model: opts.model,
                filter: opts.filter,
                bootstrapMode: .alreadyLoaded,
                repeatCount: opts.repeatCount
            )
            startedAt = startedAt ?? report.startedAt
            rows.append(contentsOf: report.cases)
        }
        var environment = RunEnvironment.current(
            caseIDs: rows.map(\.id),
            runModel: censusModelId
        )
        if let profile {
            environment = environment.withExperiment(profile)
        }
        let merged = EvalReport(
            modelId: censusModelId,
            startedAt: startedAt ?? "",
            cases: rows,
            environment: environment
        )
        do {
            try merged.toJSON().write(to: url)
        } catch {
            status("WARN: failed to write \(name).json: \(error.localizedDescription)")
        }
        return merged
    }

    /// Write the strict promotion verdicts (JSON + Markdown).
    private static func writePromotionArtifacts(
        _ promotions: [String: PromotionGateResult],
        outDir: URL
    ) {
        var md: [String] = ["# Context Optimization — Promotion Verdicts", ""]
        for name in promotions.keys.sorted() {
            guard let verdict = promotions[name] else { continue }
            md.append("## \(name) — \(verdict.promotable ? "PROMOTABLE" : "BLOCKED")")
            md.append("")
            for line in verdict.blocking { md.append("- BLOCKING: \(line)") }
            for line in verdict.advisories { md.append("- advisory: \(line)") }
            if verdict.blocking.isEmpty && verdict.advisories.isEmpty {
                md.append("- clean pass")
            }
            md.append("")
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(promotions)
                .write(to: outDir.appendingPathComponent("promotion.json"))
            try Data(md.joined(separator: "\n").utf8)
                .write(to: outDir.appendingPathComponent("promotion.md"))
        } catch {
            status("WARN: failed to write promotion artifacts: \(error.localizedDescription)")
        }
        print(md.joined(separator: "\n"))
    }

    private static func status(_ message: String) {
        FileHandle.standardError.write(Data(("[optimize] " + message + "\n").utf8))
    }

    // MARK: - Args

    struct OptimizeOptions {
        let suites: [URL]
        let model: ModelSelection
        let filter: String?
        let outDir: String
        let repeatCount: Int
        let minSavings: Int
        let maxCandidates: Int
        let resume: Bool
        /// Stop after the deterministic census/plan (no model runs).
        let censusOnly: Bool
        /// Trials for the finalist (frontier) reruns; effective count is
        /// `max(finalistRepeat, repeatCount)`. Plan floor: 5.
        let finalistRepeat: Int
        /// Skip stage 6 (finalist reruns + strict promotion gate).
        let skipFinalists: Bool
        /// Hard mean first-step context budget for the promotion gate.
        let contextBudget: Int?

        /// Same options with a different trial count (finalist reruns).
        func withRepeat(_ count: Int) -> OptimizeOptions {
            OptimizeOptions(
                suites: suites,
                model: model,
                filter: filter,
                outDir: outDir,
                repeatCount: count,
                minSavings: minSavings,
                maxCandidates: maxCandidates,
                resume: resume,
                censusOnly: censusOnly,
                finalistRepeat: finalistRepeat,
                skipFinalists: skipFinalists,
                contextBudget: contextBudget
            )
        }

        static func parse(_ args: [String]) throws -> OptimizeOptions {
            var suites: [URL] = []
            var modelRaw: String?
            var filter: String?
            var outDir: String?
            var repeatCount = 3
            var minSavings = 25
            var maxCandidates = 10
            var resume = false
            var censusOnly = false
            var finalistRepeat = 5
            var skipFinalists = false
            var contextBudget: Int?

            var i = 0
            while i < args.count {
                let arg = args[i]
                switch arg {
                case "--suite":
                    suites.append(try urlForArg(args, after: i, flag: arg))
                    i += 2
                case "--model":
                    modelRaw = try valueForArg(args, after: i, flag: arg)
                    i += 2
                case "--filter":
                    filter = try valueForArg(args, after: i, flag: arg)
                    i += 2
                case "--out-dir":
                    outDir = try valueForArg(args, after: i, flag: arg)
                    i += 2
                case "--repeat":
                    let raw = try valueForArg(args, after: i, flag: arg)
                    guard let value = Int(raw), value >= 1 else {
                        throw CLIError.invalidValue(arg, raw)
                    }
                    repeatCount = value
                    i += 2
                case "--min-savings":
                    let raw = try valueForArg(args, after: i, flag: arg)
                    guard let value = Int(raw), value >= 0 else {
                        throw CLIError.invalidValue(arg, raw)
                    }
                    minSavings = value
                    i += 2
                case "--max-candidates":
                    let raw = try valueForArg(args, after: i, flag: arg)
                    guard let value = Int(raw), value >= 1 else {
                        throw CLIError.invalidValue(arg, raw)
                    }
                    maxCandidates = value
                    i += 2
                case "--resume":
                    resume = true
                    i += 1
                case "--census-only":
                    censusOnly = true
                    i += 1
                case "--finalist-repeat":
                    let raw = try valueForArg(args, after: i, flag: arg)
                    guard let value = Int(raw), value >= 1 else {
                        throw CLIError.invalidValue(arg, raw)
                    }
                    finalistRepeat = value
                    i += 2
                case "--skip-finalists":
                    skipFinalists = true
                    i += 1
                case "--context-budget":
                    let raw = try valueForArg(args, after: i, flag: arg)
                    guard let value = Int(raw), value >= 1 else {
                        throw CLIError.invalidValue(arg, raw)
                    }
                    contextBudget = value
                    i += 2
                case "--help", "-h":
                    printUsage()
                    exit(0)
                default:
                    throw CLIError.unknownArg(arg)
                }
            }

            guard !suites.isEmpty else { throw CLIError.missingFlag("--suite") }
            guard let outDir else { throw CLIError.missingFlag("--out-dir") }
            return OptimizeOptions(
                suites: suites,
                model: ModelSelection.parse(modelRaw),
                filter: filter,
                outDir: outDir,
                repeatCount: repeatCount,
                minSavings: minSavings,
                maxCandidates: maxCandidates,
                resume: resume,
                censusOnly: censusOnly,
                finalistRepeat: finalistRepeat,
                skipFinalists: skipFinalists,
                contextBudget: contextBudget
            )
        }
    }
}
