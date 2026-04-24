//
//  OsaurusEvalsCLI.swift
//  osaurus-evals
//
//  Tiny CLI over `OsaurusEvalsKit`. Deliberately no
//  swift-argument-parser dependency — the surface is small enough that
//  manual parsing is clearer than wiring a fourth-party dep just for
//  three flags. Add a real arg parser if/when a subcommand surface
//  appears (`run`, `diff`, `score`, ...).
//
//  Usage:
//    osaurus-evals run --suite Suites/Preflight [--model foundation] [--filter browser] [--out report.json]
//
//  Exit codes:
//    0  every non-skipped case passed (or no cases ran)
//    1  at least one case failed or errored
//    2  invalid arguments / suite path
//

import Foundation
import OsaurusCore
import OsaurusEvalsKit

@main
struct OsaurusEvalsCLI {

    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let first = args.first, first == "run" else {
            printUsage()
            exit(args.isEmpty ? 0 : 2)
        }

        let opts: Options
        do {
            opts = try Options.parse(Array(args.dropFirst()))
        } catch {
            FileHandle.standardError.write(
                Data(("argument error: \(error.localizedDescription)\n").utf8)
            )
            printUsage()
            exit(2)
        }

        let suite: EvalSuite
        do {
            suite = try EvalSuite.load(from: opts.suite)
        } catch {
            FileHandle.standardError.write(
                Data(("failed to load suite: \(error.localizedDescription)\n").utf8)
            )
            exit(2)
        }

        let report = await EvalRunner.run(
            suite: suite,
            model: opts.model,
            filter: opts.filter
        )

        print(report.formatHumanReadable(verbose: opts.verbose))

        if let outPath = opts.out {
            do {
                let data = try report.toJSON(prettyPrinted: true)
                let url = URL(fileURLWithPath: outPath)
                try data.write(to: url)
                print("\nwrote \(report.cases.count) cases to \(url.path)")
            } catch {
                FileHandle.standardError.write(
                    Data(("failed to write report: \(error.localizedDescription)\n").utf8)
                )
                // Don't fail the run for an output write hiccup — the
                // human-readable report already printed and is the
                // primary deliverable.
            }
        }

        let counts = report.counts
        let exitCode: Int32 = (counts.failed + counts.errored == 0) ? 0 : 1
        exit(exitCode)
    }

    // MARK: - Args

    struct Options {
        let suite: URL
        let model: ModelSelection
        let filter: String?
        let out: String?
        let verbose: Bool

        static func parse(_ args: [String]) throws -> Options {
            var suite: URL?
            var modelRaw: String?
            var filter: String?
            var out: String?
            var verbose = false

            var i = 0
            while i < args.count {
                let arg = args[i]
                switch arg {
                case "--suite":
                    suite = try urlForArg(args, after: i, flag: arg)
                    i += 2
                case "--model":
                    modelRaw = try valueForArg(args, after: i, flag: arg)
                    i += 2
                case "--filter":
                    filter = try valueForArg(args, after: i, flag: arg)
                    i += 2
                case "--out":
                    out = try valueForArg(args, after: i, flag: arg)
                    i += 2
                case "--verbose", "-v":
                    verbose = true
                    i += 1
                case "--help", "-h":
                    printUsage()
                    exit(0)
                default:
                    throw CLIError.unknownArg(arg)
                }
            }

            guard let suite else { throw CLIError.missingFlag("--suite") }
            return Options(
                suite: suite,
                model: ModelSelection.parse(modelRaw),
                filter: filter,
                out: out,
                verbose: verbose
            )
        }
    }

    static func valueForArg(_ args: [String], after index: Int, flag: String) throws -> String {
        guard index + 1 < args.count else { throw CLIError.missingValue(flag) }
        return args[index + 1]
    }

    static func urlForArg(_ args: [String], after index: Int, flag: String) throws -> URL {
        let raw = try valueForArg(args, after: index, flag: flag)
        return URL(fileURLWithPath: raw)
    }

    static func printUsage() {
        let usage = """
            osaurus-evals — run behaviour evals against a chosen model

            USAGE:
                osaurus-evals run --suite <dir> [--model <id>] [--filter <substr>] [--out <path>]

            FLAGS:
                --suite <dir>     Required. Directory of *.json eval cases
                                  (e.g. Suites/Preflight).
                --model <id>      Model to route through CoreModelService for
                                  this run. Forms:
                                    auto                — keep current config
                                    foundation          — Apple Foundation Models
                                    openai/gpt-4o-mini  — provider/name pair
                                    qwen3-4b            — bare local id
                                  Default: auto.
                --filter <substr> Only run cases whose id contains <substr>.
                --out <path>      Also write a JSON report to <path>.
                --verbose, -v     Print per-case diagnostics: the user query,
                                  the raw LLM response (truncated), and the
                                  pre-guardrail picks. Use when iterating on
                                  the preflight prompt.

            EXAMPLES:
                osaurus-evals run --suite Suites/Preflight --model foundation
                osaurus-evals run --suite Suites/Preflight --filter browser --out report.json
            """
        print(usage)
    }
}

enum CLIError: Error, LocalizedError {
    case unknownArg(String)
    case missingFlag(String)
    case missingValue(String)

    var errorDescription: String? {
        switch self {
        case .unknownArg(let a): return "unknown argument: \(a)"
        case .missingFlag(let f): return "missing required flag: \(f)"
        case .missingValue(let f): return "flag \(f) requires a value"
        }
    }
}
