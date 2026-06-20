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

    private static func printMatrixUsage() {
        print(
            """
            osaurus-evals matrix <reports-dir> [flags]

            Fold a directory of *.json eval reports (one per suite per model) into a
            cross-model scoreboard: domains x models with passed/scored cells, plus a
            per-model perf rollup (decode tok/s, TTFT, peak RAM).

            FLAGS:
                --out <path>        Write the matrix as JSON.
                --markdown <path>   Write the matrix as Markdown.
            """
        )
    }
}
