//
//  AgentLoopRegressionLabCLI.swift
//  osaurus-evals
//
//  CLI surface for running and comparing agent_loop eval regression reports.
//

import Darwin
import Foundation
import OsaurusEvalsKit

extension OsaurusEvalsCLI {
    static func runAgentLoopLab(_ args: [String]) async -> Int32 {
        let opts: AgentLoopLabOptions
        do {
            opts = try AgentLoopLabOptions.parse(args)
        } catch {
            FileHandle.standardError.write(
                Data(("argument error: \(error.localizedDescription)\n").utf8)
            )
            printAgentLoopLabUsage()
            return 2
        }

        do {
            if let current = opts.current {
                return try compareExistingAgentLoopReports(options: opts, current: current)
            }
            return try await runAgentLoopLabSuites(options: opts)
        } catch {
            FileHandle.standardError.write(
                Data(("agent-loop lab failed: \(error.localizedDescription)\n").utf8)
            )
            return 2
        }
    }

    private static func compareExistingAgentLoopReports(
        options opts: AgentLoopLabOptions,
        current: URL
    ) throws -> Int32 {
        let baseline = try AgentLoopRegressionReportSet.load(
            from: opts.baseline,
            label: opts.baselineLabel
        ).filteringCaseIDs(containing: opts.filter)
        let currentSet = try AgentLoopRegressionReportSet.load(
            from: current,
            label: opts.currentLabel ?? current.deletingPathExtension().lastPathComponent
        ).filteringCaseIDs(containing: opts.filter)
        let summary = try AgentLoopRegressionLab.compare(
            baseline: baseline,
            current: currentSet,
            artifacts: [
                .init(kind: "baseline reports", path: opts.baseline.path),
                .init(kind: "current reports", path: current.path),
            ]
        )
        let written = try writeAgentLoopLabSummary(summary, outDir: opts.outDir)
        print(summary.formatMarkdown())
        print("wrote summary JSON to \(written.json.path)")
        print("wrote summary Markdown to \(written.markdown.path)")
        return summary.hasBlockingRegressions ? 1 : 0
    }

    @MainActor
    private static func runAgentLoopLabSuites(options opts: AgentLoopLabOptions) async throws -> Int32 {
        let suiteURLs = opts.suites.isEmpty ? defaultAgentLoopLabSuites() : opts.suites
        var loaded: [(url: URL, suite: EvalSuite)] = []
        for suiteURL in suiteURLs {
            let suite = try EvalSuite.load(from: suiteURL)
            try AgentLoopRegressionLab.validateAgentLoopSuite(suite, filter: opts.filter)
            loaded.append((suiteURL, suite))
        }

        let combinedSuite = EvalSuite(
            directory: URL(fileURLWithPath: "agent-loop-lab", isDirectory: true),
            cases: loaded.flatMap(\.suite.cases),
            decodeFailures: loaded.flatMap(\.suite.decodeFailures)
        )
        let bootstrapPlan = EvalBootstrapPlan.make(
            suite: combinedSuite,
            filter: opts.filter,
            preference: opts.pluginBootstrapPreference
        )
        _ = EvalBootstrap.configureIsolatedSearchStorageIfNeeded(for: bootstrapPlan)
        let startupWatchdog =
            bootstrapPlan.requiresWork
            ? makeAgentLoopLabStartupWatchdog(options: opts, suite: combinedSuite)
            : nil
        await EvalBootstrap.run(bootstrapPlan)
        startupWatchdog?.cancel()

        let ephemeralProviderIds = await EvalRemoteProviderBootstrap.connectIfNeeded(
            modelIds: EvalRemoteProviderBootstrap.candidateModelIds(runModel: opts.model)
        )
        defer { EvalRemoteProviderBootstrap.teardown(ephemeralProviderIds) }

        let reportsDir = opts.outDir.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: reportsDir,
            withIntermediateDirectories: true
        )

        var namedReports: [AgentLoopRegressionReportSet.NamedReport] = []
        var reportArtifacts: [AgentLoopRegressionArtifact] = []
        var usedNames: [String: Int] = [:]

        for item in loaded {
            let suiteName = uniqueSuiteName(suiteURL: item.url, usedNames: &usedNames)
            print("running \(suiteName)...")
            let report = await EvalRunner.run(
                suite: item.suite,
                model: opts.model,
                filter: opts.filter,
                bootstrapMode: .alreadyLoaded
            )
            let outURL = reportsDir.appendingPathComponent("\(suiteName).json")
            try report.toJSON(prettyPrinted: true).write(to: outURL)
            namedReports.append(.init(name: suiteName, url: outURL, report: report))
            reportArtifacts.append(.init(kind: "\(suiteName) report", path: outURL.path))

            let counts = report.counts
            print(
                "finished \(suiteName): \(counts.passed) passed, "
                    + "\(counts.failed) failed, \(counts.errored) errored, "
                    + "\(counts.skipped) skipped"
            )
            if opts.verbose {
                print("")
                print(report.formatHumanReadable(verbose: true))
                print("")
            }
        }

        let baseline = try AgentLoopRegressionReportSet.load(
            from: opts.baseline,
            label: opts.baselineLabel
        ).filteringCaseIDs(containing: opts.filter)
        let current = AgentLoopRegressionReportSet(
            label: opts.currentLabel ?? "current run",
            reports: namedReports
        ).filteringCaseIDs(containing: opts.filter)
        let summary = try AgentLoopRegressionLab.compare(
            baseline: baseline,
            current: current,
            artifacts: [.init(kind: "baseline reports", path: opts.baseline.path)] + reportArtifacts
        )
        let written = try writeAgentLoopLabSummary(summary, outDir: opts.outDir)
        print("")
        print(summary.formatMarkdown())
        print("wrote summary JSON to \(written.json.path)")
        print("wrote summary Markdown to \(written.markdown.path)")
        return summary.hasBlockingRegressions ? 1 : 0
    }

    private static func writeAgentLoopLabSummary(
        _ summary: AgentLoopRegressionLabSummary,
        outDir: URL
    ) throws -> (json: URL, markdown: URL) {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let jsonURL = outDir.appendingPathComponent("regression-summary.json")
        let markdownURL = outDir.appendingPathComponent("regression-summary.md")
        try summary.toJSON(prettyPrinted: true).write(to: jsonURL)
        try summary.formatMarkdown().write(to: markdownURL, atomically: true, encoding: .utf8)
        return (jsonURL, markdownURL)
    }

    @MainActor
    private static func makeAgentLoopLabStartupWatchdog(
        options opts: AgentLoopLabOptions,
        suite: EvalSuite
    ) -> EvalStartupWatchdog? {
        guard let timeoutSeconds = opts.startupTimeoutSeconds else { return nil }
        let reportData = try? EvalTimeoutReport.makeReport(
            suite: suite,
            modelId: ModelOverride.describe(opts.model),
            filter: opts.filter,
            timeoutSeconds: timeoutSeconds,
            phase: "startup bootstrap"
        ).toJSON(prettyPrinted: true)

        return EvalStartupWatchdog(
            timeoutSeconds: timeoutSeconds,
            payload: EvalStartupWatchdog.Payload(
                phase: "startup bootstrap",
                timeoutLabel: EvalTimeoutReport.formatSeconds(timeoutSeconds),
                reportData: reportData,
                outPath: opts.outDir.appendingPathComponent("startup-timeout.json").path
            )
        )
    }

    private static func defaultAgentLoopLabSuites() -> [URL] {
        let repoRootAgentLoop = URL(fileURLWithPath: "Packages/OsaurusEvals/Suites/AgentLoop", isDirectory: true)
        let repoRootFrontier = URL(fileURLWithPath: "Packages/OsaurusEvals/Suites/AgentLoopFrontier", isDirectory: true)
        if FileManager.default.fileExists(atPath: repoRootAgentLoop.path) {
            return [repoRootAgentLoop, repoRootFrontier]
        }
        return [
            URL(fileURLWithPath: "Suites/AgentLoop", isDirectory: true),
            URL(fileURLWithPath: "Suites/AgentLoopFrontier", isDirectory: true),
        ]
    }

    private static func uniqueSuiteName(
        suiteURL: URL,
        usedNames: inout [String: Int]
    ) -> String {
        let base =
            suiteURL.lastPathComponent.isEmpty
            ? suiteURL.deletingLastPathComponent().lastPathComponent
            : suiteURL.lastPathComponent
        let count = usedNames[base, default: 0]
        usedNames[base] = count + 1
        return count == 0 ? base : "\(base)-\(count + 1)"
    }

    static func printAgentLoopLabUsage() {
        let usage = """
            osaurus-evals agent-loop-lab - compare agent_loop reports against a baseline

            USAGE:
                osaurus-evals agent-loop-lab --baseline <path> [--suite <dir> ...] [--model <id>]
                                                [--filter <substr>] [--out-dir <dir>]
                osaurus-evals agent-loop-lab --baseline <path> --current <path> [--out-dir <dir>]

            FLAGS:
                --baseline <path>       Required. Baseline EvalReport JSON file or directory
                                        of per-suite JSON reports.
                --current <path>        Compare-only mode. Reads current EvalReport JSON
                                        file or directory instead of running model evals.
                --suite <dir>           Agent-loop suite to run. May be repeated. Defaults
                                        to AgentLoop and AgentLoopFrontier.
                --model <id>            Same model grammar as `run`; default is auto.
                --filter <substr>       Only run/compare cases whose id contains <substr>.
                --out-dir <dir>         Artifact directory. Defaults to
                                        build/evals/agent-loop-regression-lab/<timestamp>.
                --baseline-label <text> Label used in JSON/Markdown summary.
                --current-label <text>  Label used in JSON/Markdown summary.
                --verbose, -v           Print full per-suite reports after each run.
                --startup-timeout <s>   Startup bootstrap watchdog. Use 0 to disable.
                --bootstrap-plugins     Force installed native plugin loading.
                --no-plugin-bootstrap   Disable installed native plugin loading.

            ARTIFACTS:
                reports/<Suite>.json
                regression-summary.json
                regression-summary.md

            EXAMPLES:
                osaurus-evals agent-loop-lab --baseline reports/main-agentloop
                osaurus-evals agent-loop-lab --baseline baseline.json --current current.json --out-dir build/evals/lab-smoke
            """
        print(usage)
    }

    struct AgentLoopLabOptions {
        let baseline: URL
        let current: URL?
        let suites: [URL]
        let model: ModelSelection
        let filter: String?
        let outDir: URL
        let baselineLabel: String?
        let currentLabel: String?
        let verbose: Bool
        let startupTimeoutSeconds: Double?
        let pluginBootstrapPreference: EvalInstalledPluginBootstrapPreference

        static func parse(_ args: [String]) throws -> AgentLoopLabOptions {
            var baseline: URL?
            var current: URL?
            var suites: [URL] = []
            var modelRaw: String?
            var filter: String?
            var outDir: URL?
            var baselineLabel: String?
            var currentLabel: String?
            var verbose = false
            var startupTimeoutSeconds = EvalTimeoutReport.configuredStartupTimeoutSeconds()
            var pluginBootstrapPreference: EvalInstalledPluginBootstrapPreference = .automatic

            var i = 0
            while i < args.count {
                let arg = args[i]
                switch arg {
                case "--baseline":
                    baseline = try urlForArg(args, after: i, flag: arg)
                    i += 2
                case "--current":
                    current = try urlForArg(args, after: i, flag: arg)
                    i += 2
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
                    outDir = try urlForArg(args, after: i, flag: arg)
                    i += 2
                case "--baseline-label":
                    baselineLabel = try valueForArg(args, after: i, flag: arg)
                    i += 2
                case "--current-label":
                    currentLabel = try valueForArg(args, after: i, flag: arg)
                    i += 2
                case "--verbose", "-v":
                    verbose = true
                    i += 1
                case "--startup-timeout":
                    let raw = try valueForArg(args, after: i, flag: arg)
                    guard let value = EvalTimeoutReport.parseTimeoutSeconds(raw) else {
                        throw CLIError.invalidValue(arg, raw)
                    }
                    startupTimeoutSeconds = value > 0 ? value : nil
                    i += 2
                case "--bootstrap-plugins":
                    pluginBootstrapPreference = .force
                    i += 1
                case "--no-plugin-bootstrap":
                    pluginBootstrapPreference = .disabled
                    i += 1
                case "--help", "-h":
                    printAgentLoopLabUsage()
                    Darwin.exit(0)
                default:
                    throw CLIError.unknownArg(arg)
                }
            }

            guard let baseline else { throw CLIError.missingFlag("--baseline") }
            return AgentLoopLabOptions(
                baseline: baseline,
                current: current,
                suites: suites,
                model: ModelSelection.parse(modelRaw),
                filter: filter,
                outDir: outDir ?? defaultAgentLoopLabOutDir(),
                baselineLabel: baselineLabel,
                currentLabel: currentLabel,
                verbose: verbose,
                startupTimeoutSeconds: startupTimeoutSeconds,
                pluginBootstrapPreference: pluginBootstrapPreference
            )
        }

        private static func defaultAgentLoopLabOutDir() -> URL {
            URL(fileURLWithPath: "build/evals/agent-loop-regression-lab", isDirectory: true)
                .appendingPathComponent(timestampForPath(), isDirectory: true)
        }

        private static func timestampForPath() -> String {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return formatter.string(from: Date())
        }
    }
}
