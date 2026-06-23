//
//  EvalDiffMatrixCLI.swift
//  osaurus-evals
//
//  `diff` and `matrix` subcommands — the optimization loop's
//  measure→compare surface. Both are pure file readers (no MLX/model
//  bootstrap), so they parse a tiny positional+flag grammar and exit
//  directly.
//
//    osaurus-evals diff <baseline-dir-or-json> <current-dir-or-json>
//                       [--out summary.json] [--markdown summary.md]
//                       [--decode-margin <pct>] [--ram-margin <mb>]
//                       [--fail-on-regression]
//    osaurus-evals matrix <reports-dir> [--out matrix.json] [--markdown matrix.md]
//

import Foundation
import OsaurusEvalsKit

extension OsaurusEvalsCLI {

    // MARK: - diff

    static func runDiff(_ args: [String]) -> Int32 {
        var positional: [String] = []
        var outPath: String?
        var markdownPath: String?
        var decodeMargin = 10.0
        var ramMargin = 200.0
        var failOnRegression = false

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--out":
                guard i + 1 < args.count else { return failDiff("flag --out requires a value") }
                outPath = args[i + 1]
                i += 2
            case "--markdown":
                guard i + 1 < args.count else { return failDiff("flag --markdown requires a value") }
                markdownPath = args[i + 1]
                i += 2
            case "--decode-margin":
                guard i + 1 < args.count, let v = Double(args[i + 1]) else {
                    return failDiff("flag --decode-margin requires a number")
                }
                decodeMargin = v
                i += 2
            case "--ram-margin":
                guard i + 1 < args.count, let v = Double(args[i + 1]) else {
                    return failDiff("flag --ram-margin requires a number")
                }
                ramMargin = v
                i += 2
            case "--fail-on-regression":
                failOnRegression = true
                i += 1
            case "--help", "-h":
                printDiffUsage()
                return 0
            default:
                if arg.hasPrefix("--") { return failDiff("unknown flag: \(arg)") }
                positional.append(arg)
                i += 1
            }
        }

        guard positional.count == 2 else {
            return failDiff("expected <baseline> <current>, got \(positional.count) positional arg(s)")
        }

        do {
            let baselineURL = URL(fileURLWithPath: positional[0])
            let currentURL = URL(fileURLWithPath: positional[1])
            let baseline = try AgentLoopRegressionReportSet.load(
                from: baselineURL,
                label: baselineURL.deletingPathExtension().lastPathComponent
            )
            let current = try AgentLoopRegressionReportSet.load(
                from: currentURL,
                label: currentURL.deletingPathExtension().lastPathComponent
            )
            let summary = EvalDiff.compare(
                baseline: baseline,
                current: current,
                margins: EvalDiff.PerfMargins(decodeTpsPct: decodeMargin, peakRamMb: ramMargin)
            )
            print(summary.formatConsole())
            if let outPath {
                try summary.toJSON().write(to: URL(fileURLWithPath: outPath))
                print("\nwrote diff JSON to \(outPath)")
            }
            if let markdownPath {
                try Data(summary.formatMarkdown().utf8).write(to: URL(fileURLWithPath: markdownPath))
                print("wrote diff Markdown to \(markdownPath)")
            }
            if failOnRegression && summary.hasBlockingRegressions { return 1 }
            return 0
        } catch {
            return failDiff(error.localizedDescription)
        }
    }

    private static func failDiff(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data(("diff error: \(message)\n").utf8))
        printDiffUsage()
        return 2
    }

    private static func printDiffUsage() {
        print(
            """
            osaurus-evals diff <baseline> <current> [flags]

            Compare two eval report sets (each a directory of *.json reports or a
            single report.json) across ALL domains. Classifies pass->fail / fail->pass
            / new / removed cases and surfaces decode-tps and peak-RAM movements.

            FLAGS:
                --out <path>            Write the full diff summary as JSON.
                --markdown <path>       Write a Markdown diff (PR-pasteable).
                --decode-margin <pct>   Min |decode tok/s change| to flag (default 10).
                --ram-margin <mb>       Min |peak RAM change| to flag (default 200).
                --fail-on-regression    Exit 1 when any pass->not-pass / new failure.
            """
        )
    }

    // MARK: - matrix

    static func runMatrix(_ args: [String]) -> Int32 {
        var positional: [String] = []
        var outPath: String?
        var markdownPath: String?
        var historyPath: String?
        var label: String?
        var commit: String?

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--out":
                guard i + 1 < args.count else { return failMatrix("flag --out requires a value") }
                outPath = args[i + 1]
                i += 2
            case "--markdown":
                guard i + 1 < args.count else { return failMatrix("flag --markdown requires a value") }
                markdownPath = args[i + 1]
                i += 2
            case "--history":
                guard i + 1 < args.count else { return failMatrix("flag --history requires a value") }
                historyPath = args[i + 1]
                i += 2
            case "--label":
                guard i + 1 < args.count else { return failMatrix("flag --label requires a value") }
                label = args[i + 1]
                i += 2
            case "--commit":
                guard i + 1 < args.count else { return failMatrix("flag --commit requires a value") }
                commit = args[i + 1]
                i += 2
            case "--help", "-h":
                printMatrixUsage()
                return 0
            default:
                if arg.hasPrefix("--") { return failMatrix("unknown flag: \(arg)") }
                positional.append(arg)
                i += 1
            }
        }

        guard positional.count == 1 else {
            return failMatrix("expected <reports-dir>, got \(positional.count) positional arg(s)")
        }

        do {
            let dir = URL(fileURLWithPath: positional[0])
            let reports = try EvalMatrixBuilder.loadReports(in: dir)
            let matrix = EvalMatrixBuilder.build(from: reports)
            print(matrix.formatConsole())
            if let outPath {
                try matrix.toJSON().write(to: URL(fileURLWithPath: outPath))
                print("\nwrote matrix JSON to \(outPath)")
            }
            if let markdownPath {
                try Data(matrix.formatMarkdown().utf8).write(to: URL(fileURLWithPath: markdownPath))
                print("wrote matrix Markdown to \(markdownPath)")
            }
            if let historyPath {
                let rows = EvalHistory.rows(from: matrix, commit: commit, label: label)
                try EvalHistory.append(rows, to: URL(fileURLWithPath: historyPath))
                print("appended \(rows.count) row(s) to history \(historyPath)")
            }
            return 0
        } catch {
            return failMatrix(error.localizedDescription)
        }
    }

    private static func failMatrix(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data(("matrix error: \(message)\n").utf8))
        printMatrixUsage()
        return 2
    }

    // MARK: - compat

    static func runCompat(_ args: [String]) -> Int32 {
        var positional: [String] = []
        var outPath: String?
        var markdownPath: String?
        var validateOnly = false

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--out":
                guard i + 1 < args.count else { return failCompat("flag --out requires a value") }
                outPath = args[i + 1]
                i += 2
            case "--markdown":
                guard i + 1 < args.count else { return failCompat("flag --markdown requires a value") }
                markdownPath = args[i + 1]
                i += 2
            case "--validate":
                validateOnly = true
                i += 1
            case "--help", "-h":
                printCompatUsage()
                return 0
            default:
                if arg.hasPrefix("--") { return failCompat("unknown flag: \(arg)") }
                positional.append(arg)
                i += 1
            }
        }

        guard positional.count == 1 else {
            return failCompat("expected <community-dir>, got \(positional.count) positional arg(s)")
        }
        let dir = URL(fileURLWithPath: positional[0])

        // --validate is the PR gate: every contribution must decode and carry
        // the provenance (chip + catalogHash) a trustworthy crowdsourced row
        // needs. Reports problems and exits 1 without building the leaderboard.
        if validateOnly {
            let problems = EvalCompatBuilder.validate(in: dir)
            if problems.isEmpty {
                print("[compat] all contributions valid (\(dir.path))")
                return 0
            }
            FileHandle.standardError.write(
                Data(
                    (["[compat] contribution validation failed:"] + problems.map { "  - \($0)" })
                        .joined(separator: "\n").appending("\n").utf8
                )
            )
            return 1
        }

        do {
            let matrices = try EvalCompatBuilder.loadContributions(in: dir)
            let report = EvalCompatBuilder.build(from: matrices)
            let worst = report.models.filter { $0.verdict == .broken }.map { CompatibilityReport.shortModel($0.model) }
            print(
                "compat: \(report.models.count) model(s) across \(report.contributions) contribution(s)"
                    + (worst.isEmpty ? "" : "  [broken: \(worst.joined(separator: ", "))]")
            )
            if let outPath {
                try report.toJSON().write(to: URL(fileURLWithPath: outPath))
                print("\nwrote compatibility JSON to \(outPath)")
            }
            if let markdownPath {
                try Data(report.formatMarkdown().utf8).write(to: URL(fileURLWithPath: markdownPath))
                print("wrote compatibility Markdown to \(markdownPath)")
            }
            return 0
        } catch {
            return failCompat(error.localizedDescription)
        }
    }

    private static func failCompat(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data(("compat error: \(message)\n").utf8))
        printCompatUsage()
        return 2
    }

    private static func printCompatUsage() {
        print(
            """
            osaurus-evals compat <community-dir> [flags]

            Fold crowdsourced contribution files (reports/community/*.json — each a
            matrix carrying a RunEnvironment, the shape `make evals-contribute` writes)
            into a single model-compatibility leaderboard: per model a works/partial/
            broken verdict plus hardware coverage (chips, RAM band), worst-case peak
            RAM, decode-speed range, and a comparability check (same catalog hash?).

            FLAGS:
                --out <path>        Write the compatibility report as JSON.
                --markdown <path>   Write COMPATIBILITY.md (the committed leaderboard).
                --validate          PR gate: verify every contribution decodes and
                                    carries provenance (chip + catalogHash). Exit 1 on
                                    any problem; does not build the leaderboard.
            """
        )
    }

    private static func printMatrixUsage() {
        print(
            """
            osaurus-evals matrix <reports-dir> [flags]

            Fold a directory of *.json eval reports (one per suite per model) into a
            cross-model scoreboard: domains x models with passed/scored cells, plus a
            per-model perf rollup (decode tok/s, TTFT, peak RAM).

            Point --out/--markdown at reports/SNAPSHOT.{json,md} to refresh the
            committed "latest snapshot", and --history at reports/history.jsonl to
            append one append-only row per model (the run-over-run trend log). Raw
            per-case reports stay local/gitignored; SNAPSHOT + history are committed.

            FLAGS:
                --out <path>        Write the matrix as JSON.
                --markdown <path>   Write the matrix as Markdown.
                --history <path>    Append one JSONL row per model (append-only log).
                --label <str>       Free-form run note recorded in each history row.
                --commit <sha>      Commit/provenance string recorded in each row.
            """
        )
    }
}
