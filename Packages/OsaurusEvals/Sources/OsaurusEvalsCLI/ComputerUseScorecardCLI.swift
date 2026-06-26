//
//  ComputerUseScorecardCLI.swift
//  osaurus-evals
//
//  Offline Computer Use report aggregation. Reads existing EvalReport JSON
//  artifacts and emits privacy-safe Markdown + JSON scorecards.
//

import Foundation
import OsaurusEvalsKit

func runComputerUseScorecard(_ args: [String]) -> Int32 {
    let options: ComputerUseScorecardOptions
    do {
        options = try ComputerUseScorecardOptions.parse(args)
    } catch {
        if case ComputerUseScorecardCLIError.helpRequested = error {
            print(computerUseScorecardUsage())
            return 0
        }
        FileHandle.standardError.write(
            Data(("argument error: \(error.localizedDescription)\n").utf8)
        )
        return 2
    }

    do {
        let reports = try ComputerUseScorecardBuilder.loadReports(from: options.inputs)
        let scorecard = ComputerUseScorecardBuilder.build(from: reports)
        try FileManager.default.createDirectory(
            at: options.jsonOutput.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: options.markdownOutput.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try scorecard.toJSON(prettyPrinted: true).write(to: options.jsonOutput)
        try scorecard.formatMarkdown().write(
            to: options.markdownOutput,
            atomically: true,
            encoding: .utf8
        )
        print("wrote \(options.jsonOutput.path)")
        print("wrote \(options.markdownOutput.path)")
        return scorecard.totals.failed + scorecard.totals.errored == 0 ? 0 : 1
    } catch {
        FileHandle.standardError.write(
            Data(("scorecard error: \(error.localizedDescription)\n").utf8)
        )
        return 2
    }
}

struct ComputerUseScorecardOptions {
    let inputs: [URL]
    let jsonOutput: URL
    let markdownOutput: URL

    static func parse(_ args: [String]) throws -> ComputerUseScorecardOptions {
        var inputs: [URL] = []
        var outputDirectory = URL(fileURLWithPath: "build/evals/computer-use-scorecard", isDirectory: true)
        var jsonOutput: URL?
        var markdownOutput: URL?

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--out-dir":
                outputDirectory = try urlForArg(args, after: i, flag: arg, isDirectory: true)
                i += 2
            case "--out":
                jsonOutput = try urlForArg(args, after: i, flag: arg, isDirectory: false)
                i += 2
            case "--markdown":
                markdownOutput = try urlForArg(args, after: i, flag: arg, isDirectory: false)
                i += 2
            case "--help", "-h":
                throw ComputerUseScorecardCLIError.helpRequested
            default:
                if arg.hasPrefix("--") { throw ComputerUseScorecardCLIError.unknownArg(arg) }
                inputs.append(URL(fileURLWithPath: arg))
                i += 1
            }
        }

        guard !inputs.isEmpty else {
            throw ComputerUseScorecardCLIError.missingInput
        }

        let resolvedJSON = jsonOutput ?? outputDirectory.appendingPathComponent("scorecard.json")
        let resolvedMarkdown =
            markdownOutput
            ?? (jsonOutput == nil
                ? outputDirectory.appendingPathComponent("scorecard.md")
                : resolvedJSON.deletingLastPathComponent().appendingPathComponent("scorecard.md"))

        return ComputerUseScorecardOptions(
            inputs: inputs,
            jsonOutput: resolvedJSON,
            markdownOutput: resolvedMarkdown
        )
    }

    private static func urlForArg(
        _ args: [String],
        after index: Int,
        flag: String,
        isDirectory: Bool
    ) throws -> URL {
        guard index + 1 < args.count else { throw ComputerUseScorecardCLIError.missingValue(flag) }
        return URL(fileURLWithPath: args[index + 1], isDirectory: isDirectory)
    }

}

enum ComputerUseScorecardCLIError: Error, LocalizedError {
    case helpRequested
    case missingInput
    case missingValue(String)
    case unknownArg(String)

    var errorDescription: String? {
        switch self {
        case .helpRequested:
            return computerUseScorecardUsage()
        case .missingInput:
            return "missing report path. Usage: \(computerUseScorecardUsage())"
        case .missingValue(let flag):
            return "flag \(flag) requires a value"
        case .unknownArg(let arg):
            return "unknown argument: \(arg)"
        }
    }
}

func computerUseScorecardUsage() -> String {
    """
    osaurus-evals scorecard <report.json|reports-dir> [...] [--out-dir <dir>] [--out <json>] [--markdown <md>]
    """
}
