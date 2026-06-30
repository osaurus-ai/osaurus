//
//  EvalScoreboardCLI.swift
//  osaurus-evals
//
//  CLI surface for watcher scoreboard artifacts.
//

import Darwin
import Foundation
import OsaurusEvalsKit

extension OsaurusEvalsCLI {
    static func runEvalScoreboard(_ args: [String]) -> Int32 {
        let opts: EvalScoreboardOptions
        do {
            opts = try EvalScoreboardOptions.parse(args)
        } catch {
            FileHandle.standardError.write(
                Data(("argument error: \(error.localizedDescription)\n").utf8)
            )
            printEvalScoreboardUsage()
            return 2
        }

        do {
            let inputs = try EvalScoreboardBuilder.loadBundlesRecursively(from: opts.reportRoots)
            let scoreboard = EvalScoreboardBuilder.build(
                sourceRoots: opts.reportRoots,
                bundles: inputs,
                allowedRegressions: opts.allowedRegressions
            )
            try writeEvalScoreboard(scoreboard, outDir: opts.outDir)
            print("wrote eval watcher scoreboard to \(opts.outDir.path)")
            print("  json: \(opts.outDir.appendingPathComponent(EvalScoreboardBundle.jsonFileName).path)")
            print("  registry: \(opts.outDir.appendingPathComponent(EvalScoreboardBundle.evidenceRegistryFileName).path)")
            print("  markdown: \(opts.outDir.appendingPathComponent("scoreboard.md").path)")
            print("  verdict: \(scoreboard.hasBlockingRegressions ? "REGRESSED" : (scoreboard.hasRunFailures ? "EVAL FAILURES PRESENT" : "PASS"))")
            return scoreboard.hasBlockingRegressions || scoreboard.hasRunFailures ? 1 : 0
        } catch {
            FileHandle.standardError.write(
                Data(("eval scoreboard failed: \(error.localizedDescription)\n").utf8)
            )
            return 2
        }
    }

    private static func writeEvalScoreboard(
        _ scoreboard: EvalScoreboardBundle,
        outDir: URL
    ) throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let scoreboardURL = outDir.appendingPathComponent(EvalScoreboardBundle.jsonFileName)
        try scoreboard.toJSON(prettyPrinted: true).write(
            to: scoreboardURL,
            options: .atomic
        )
        try scoreboard.evidenceRegistryJSON(scoreboardPath: scoreboardURL.path).write(
            to: outDir.appendingPathComponent(EvalScoreboardBundle.evidenceRegistryFileName),
            options: .atomic
        )
        try scoreboard.formatMarkdown().write(
            to: outDir.appendingPathComponent("scoreboard.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    static func printEvalScoreboardUsage() {
        let usage = """
            osaurus-evals scoreboard - aggregate stored eval report bundles

            USAGE:
                osaurus-evals scoreboard --reports-root <dir> [--reports-root <dir> ...]
                                         [--out-dir <dir>]
                                         [--max-regressions <n>]

            FLAGS:
                --reports-root <dir>  Directory or evidence-registry.json file. May be repeated.
                                      Directories are scanned recursively for registry snapshots.
                --out-dir <dir>       Output directory. Defaults to
                                      build/evals/scoreboard/<timestamp>.
                --max-regressions <n> No-regression threshold. Defaults to 0.

            ARTIFACTS:
                scoreboard.json
                evidence-registry.json
                scoreboard.md

            EXAMPLES:
                osaurus-evals scoreboard --reports-root build/evals/watcher/main
                osaurus-evals scoreboard --reports-root build/evals/pr-report --out-dir build/evals/scoreboard/main
            """
        print(usage)
    }

    struct EvalScoreboardOptions {
        let reportRoots: [URL]
        let outDir: URL
        let allowedRegressions: Int

        static func parse(_ args: [String]) throws -> EvalScoreboardOptions {
            var reportRoots: [URL] = []
            var outDir: URL?
            var allowedRegressions = 0

            var i = 0
            while i < args.count {
                let arg = args[i]
                switch arg {
                case "--reports-root":
                    reportRoots.append(try urlForArg(args, after: i, flag: arg))
                    i += 2
                case "--out-dir":
                    outDir = try urlForArg(args, after: i, flag: arg)
                    i += 2
                case "--max-regressions":
                    let raw = try valueForArg(args, after: i, flag: arg)
                    guard let value = Int(raw), value >= 0 else {
                        throw CLIError.invalidValue(arg, raw)
                    }
                    allowedRegressions = value
                    i += 2
                case "--help", "-h":
                    printEvalScoreboardUsage()
                    Darwin.exit(0)
                default:
                    throw CLIError.unknownArg(arg)
                }
            }

            guard !reportRoots.isEmpty else {
                throw CLIError.missingValue("--reports-root")
            }

            return EvalScoreboardOptions(
                reportRoots: reportRoots,
                outDir: outDir ?? defaultEvalScoreboardOutDir(),
                allowedRegressions: allowedRegressions
            )
        }
    }

    private static func defaultEvalScoreboardOutDir() -> URL {
        URL(fileURLWithPath: "build/evals/scoreboard", isDirectory: true)
            .appendingPathComponent(timestampForEvalScoreboardPath(), isDirectory: true)
    }

    private static func timestampForEvalScoreboardPath() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }
}
