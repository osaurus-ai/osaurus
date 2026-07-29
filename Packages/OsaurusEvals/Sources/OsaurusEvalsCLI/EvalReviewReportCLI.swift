//
//  EvalReviewReportCLI.swift
//  osaurus-evals
//
//  Maintainer-facing eval artifact bundle generation for PR review.
//

import Darwin
import Foundation
import OsaurusEvalsKit

extension OsaurusEvalsCLI {
    static func runEvalReviewReport(_ args: [String]) async -> Int32 {
        let opts: EvalReviewReportOptions
        do {
            opts = try EvalReviewReportOptions.parse(args)
        } catch {
            FileHandle.standardError.write(
                Data(("argument error: \(error.localizedDescription)\n").utf8)
            )
            printEvalReviewReportUsage()
            return 2
        }

        if let judgeModel = opts.judgeModel {
            setenv("JUDGE_MODEL", judgeModel, 1)
        }

        do {
            if let fromReports = opts.fromReports {
                return try writeEvalReviewReportFromExistingReports(
                    options: opts,
                    currentRoot: fromReports
                )
            }
            return try await runEvalReviewReportSuites(options: opts)
        } catch {
            FileHandle.standardError.write(
                Data(("eval report failed: \(error.localizedDescription)\n").utf8)
            )
            return 2
        }
    }

    @MainActor
    private static func runEvalReviewReportSuites(
        options opts: EvalReviewReportOptions
    ) async throws -> Int32 {
        let suiteURLs = opts.suiteURLsForLiveRun()
        let loadedSuites = try suiteURLs.map { url in
            (ref: EvalReviewSuiteRef(name: suiteName(for: url), path: url.path), suite: try EvalSuite.load(from: url))
        }

        let combinedSuite = EvalSuite(
            directory: URL(fileURLWithPath: "eval-review-report", isDirectory: true),
            cases: loadedSuites.flatMap(\.suite.cases),
            decodeFailures: loadedSuites.flatMap(\.suite.decodeFailures)
        )
        let bootstrapPlan = EvalBootstrapPlan.make(
            suite: combinedSuite,
            filter: opts.filter,
            preference: opts.pluginBootstrapPreference
        )
        _ = EvalBootstrap.configureIsolatedRunStorage(for: bootstrapPlan)
        let startupWatchdog =
            bootstrapPlan.requiresWork
            ? makeEvalReviewStartupWatchdog(options: opts, suite: combinedSuite)
            : nil
        await EvalBootstrap.run(bootstrapPlan)
        startupWatchdog?.cancel()

        let models = opts.runModels()

        var installedProviderIds: [UUID] = []
        for model in models {
            let ids = await EvalRemoteProviderBootstrap.connectIfNeeded(
                modelIds: EvalRemoteProviderBootstrap.candidateModelIds(runModel: model.selection)
            )
            installedProviderIds.append(contentsOf: ids)
        }
        defer { EvalRemoteProviderBootstrap.teardown(installedProviderIds) }

        var reports: [EvalReviewReportInput] = []
        var commands: [EvalReviewCommandRecord] = []
        var usedSuiteNames: [String: Int] = [:]

        for model in models {
            let modelReportDir = opts.outDir
                .appendingPathComponent("reports", isDirectory: true)
                .appendingPathComponent(model.role.rawValue, isDirectory: true)
                .appendingPathComponent(sanitizedPathSegment(model.rawModelId), isDirectory: true)
            try FileManager.default.createDirectory(at: modelReportDir, withIntermediateDirectories: true)

            for item in loadedSuites {
                let stableSuiteName = uniqueSuiteName(item.ref.name, usedNames: &usedSuiteNames)
                print("running \(model.role.rawValue) \(model.rawModelId) / \(stableSuiteName)...")

                let report = await EvalRunner.run(
                    suite: item.suite,
                    model: model.selection,
                    filter: opts.filter,
                    bootstrapMode: .alreadyLoaded
                )
                let outURL = modelReportDir.appendingPathComponent("\(stableSuiteName).json")
                try report.toJSON(prettyPrinted: true).write(to: outURL)

                let counts = report.counts
                let exitCode: Int = (counts.failed + counts.errored == 0) ? 0 : 1
                reports.append(
                    EvalReviewReportInput(
                        role: model.role,
                        suite: stableSuiteName,
                        suitePath: item.ref.path,
                        reportPath: outURL.path,
                        report: report
                    )
                )
                commands.append(
                    EvalReviewCommandRecord(
                        role: model.role,
                        modelId: model.rawModelId,
                        suite: stableSuiteName,
                        suitePath: item.ref.path,
                        outputPath: outURL.path,
                        arguments: runArguments(
                            suitePath: item.ref.path,
                            modelId: model.rawModelId,
                            outPath: outURL.path,
                            filter: opts.filter,
                            startupTimeoutSeconds: opts.startupTimeoutSeconds,
                            pluginBootstrapPreference: opts.pluginBootstrapPreference
                        ),
                        exitCode: exitCode
                    )
                )

                print(
                    "finished \(model.role.rawValue) \(stableSuiteName): "
                        + "\(counts.passed) passed, \(counts.failed) failed, "
                        + "\(counts.errored) errored, \(counts.skipped) skipped"
                )
            }
            usedSuiteNames.removeAll(keepingCapacity: true)
        }

        let baselineReports = try opts.baseline.map {
            try EvalReviewReportBuilder.loadReportsRecursively(from: $0)
        } ?? []
        let suiteRefs = loadedSuites.map(\.ref)
        let manifest = makeEvalReviewManifest(
            options: opts,
            suiteRefs: suiteRefs,
            modelRefs: reports.map { EvalReviewModelRef(role: $0.role, modelId: $0.report.modelId) },
            commands: commands
        )
        let bundle = EvalReviewReportBuilder.build(
            manifest: manifest,
            reports: reports,
            baselineReports: baselineReports
        )
        try writeEvalReviewBundle(bundle, outDir: opts.outDir)
        printEvalReviewArtifactSummary(bundle, outDir: opts.outDir)
        return bundle.hasRunFailures || bundle.hasBlockingRegressions ? 1 : 0
    }

    private static func writeEvalReviewReportFromExistingReports(
        options opts: EvalReviewReportOptions,
        currentRoot: URL
    ) throws -> Int32 {
        let loadedReports = try EvalReviewReportBuilder.loadReportsRecursively(from: currentRoot)
        let reports = try copyEvalReportsIntoArtifact(
            loadedReports,
            outDir: opts.outDir
        )
        let baselineReports = try opts.baseline.map {
            try EvalReviewReportBuilder.loadReportsRecursively(from: $0)
        } ?? []
        let suiteRefs = opts.suiteRefsForExistingReports(reports)
        let command = EvalReviewCommandRecord(
            role: .local,
            modelId: "existing reports",
            suite: "existing reports",
            suitePath: currentRoot.path,
            outputPath: opts.outDir.path,
            arguments: existingReportArguments(options: opts, currentRoot: currentRoot),
            exitCode: 0
        )
        let manifest = makeEvalReviewManifest(
            options: opts,
            suiteRefs: suiteRefs,
            modelRefs: reports.map { EvalReviewModelRef(role: $0.role, modelId: $0.report.modelId) },
            commands: [command]
        )
        let bundle = EvalReviewReportBuilder.build(
            manifest: manifest,
            reports: reports,
            baselineReports: baselineReports
        )
        try writeEvalReviewBundle(bundle, outDir: opts.outDir)
        printEvalReviewArtifactSummary(bundle, outDir: opts.outDir)
        return bundle.hasRunFailures || bundle.hasBlockingRegressions ? 1 : 0
    }

    private static func copyEvalReportsIntoArtifact(
        _ reports: [EvalReviewReportInput],
        outDir: URL
    ) throws -> [EvalReviewReportInput] {
        var copied: [EvalReviewReportInput] = []
        var usedNamesByModel: [String: [String: Int]] = [:]
        for input in reports {
            let modelDir = outDir
                .appendingPathComponent("reports", isDirectory: true)
                .appendingPathComponent(input.role.rawValue, isDirectory: true)
                .appendingPathComponent(sanitizedPathSegment(input.report.modelId), isDirectory: true)
            try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
            let modelKey = "\(input.role.rawValue)\u{1F}\(input.report.modelId)"
            var usedNames = usedNamesByModel[modelKey, default: [:]]
            let suite = uniqueSuiteName(input.suite, usedNames: &usedNames)
            usedNamesByModel[modelKey] = usedNames
            let outURL = modelDir.appendingPathComponent("\(suite).json")
            try input.report.toJSON(prettyPrinted: true).write(to: outURL)
            copied.append(
                EvalReviewReportInput(
                    role: input.role,
                    suite: suite,
                    suitePath: input.suitePath,
                    reportPath: outURL.path,
                    report: input.report
                )
            )
        }
        return copied
    }

    private static func makeEvalReviewManifest(
        options opts: EvalReviewReportOptions,
        suiteRefs: [EvalReviewSuiteRef],
        modelRefs: [EvalReviewModelRef],
        commands: [EvalReviewCommandRecord]
    ) -> EvalReviewManifest {
        EvalReviewManifest(
            generatedAt: isoNowForEvalReviewCLI(),
            branch: gitValue(["rev-parse", "--abbrev-ref", "HEAD"]) ?? "(unknown)",
            commit: gitValue(["rev-parse", "HEAD"]) ?? "(unknown)",
            runner: "osaurus-evals report",
            artifactPath: opts.outDir.path,
            artifactId: opts.artifactId,
            suites: uniqueSuiteRefs(suiteRefs),
            models: uniqueModelRefs(modelRefs),
            commands: commands,
            environment: EvalReviewEnvironmentSummary(
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                ci: isCIEnvironment(),
                judgeModel: opts.judgeModel ?? ProcessInfo.processInfo.environment["JUDGE_MODEL"],
                sandboxFrontierIncluded: opts.includeSandboxFrontier
            ),
            baselinePath: opts.baseline?.path
        )
    }

    private static func writeEvalReviewBundle(
        _ bundle: EvalReviewReportBundle,
        outDir: URL
    ) throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let summaryURL = outDir.appendingPathComponent(EvalReviewReportBundle.summaryFileName)

        try encoder.encode(bundle.manifest).write(
            to: outDir.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        try bundle.toJSON(prettyPrinted: true).write(
            to: summaryURL,
            options: .atomic
        )
        try bundle.evidenceRegistryJSON(summaryPath: summaryURL.path).write(
            to: outDir.appendingPathComponent(EvalReviewReportBundle.evidenceRegistryFileName),
            options: .atomic
        )
        try bundle.formatMarkdown().write(
            to: outDir.appendingPathComponent("summary.md"),
            atomically: true,
            encoding: .utf8
        )

        if let comparison = bundle.comparison {
            try encoder.encode(comparison).write(
                to: outDir.appendingPathComponent("compare.json"),
                options: .atomic
            )
            try bundle.formatComparisonMarkdown().write(
                to: outDir.appendingPathComponent("compare.md"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private static func printEvalReviewArtifactSummary(
        _ bundle: EvalReviewReportBundle,
        outDir: URL
    ) {
        print("")
        print("wrote eval review report bundle to \(outDir.path)")
        print("  manifest: \(outDir.appendingPathComponent("manifest.json").path)")
        print("  registry: \(outDir.appendingPathComponent(EvalReviewReportBundle.evidenceRegistryFileName).path)")
        print("  summary:  \(outDir.appendingPathComponent("summary.md").path)")
        if bundle.comparison != nil {
            print("  compare:  \(outDir.appendingPathComponent("compare.md").path)")
        }
        print("  verdict:  \(bundle.hasBlockingRegressions ? "REGRESSED" : (bundle.hasRunFailures ? "EVAL FAILURES PRESENT" : "PASS"))")
    }

    @MainActor
    private static func makeEvalReviewStartupWatchdog(
        options opts: EvalReviewReportOptions,
        suite: EvalSuite
    ) -> EvalStartupWatchdog? {
        guard let timeoutSeconds = opts.startupTimeoutSeconds else { return nil }
        let reportData = try? EvalTimeoutReport.makeReport(
            suite: suite,
            modelId: "eval-review-report",
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

    static func printEvalReviewReportUsage() {
        let usage = """
            osaurus-evals report - generate a self-contained eval artifact bundle for PR review

            USAGE:
                osaurus-evals report [--suite <dir> ...]
                                      [--local-model <id>]
                                      [--frontier-model <provider/model>]
                                      [--baseline <dir>]
                                      [--out-dir <dir>]
                                      [--artifact-id <id>]
                                      [--preset local-frontier|local-only|frontier-only]
                                      [--judge-model <provider/model>]
                                      [--include-sandbox-frontier]

            FLAGS:
                --suite <dir>              Suite directory. May be repeated. Defaults to
                                           AgentLoop and AgentLoopFrontier.
                --local-model <id>         Local/default model evidence lane.
                                           Default: foundation.
                --frontier-model <id>      Frontier model evidence lane.
                                           Default: openai/gpt-4o-mini.
                --baseline <dir>           Optional baseline EvalReport file/directory.
                                           Adds compare.json and compare.md.
                --out-dir <dir>            Artifact directory. Defaults to
                                           build/evals/pr-report/<timestamp>.
                --artifact-id <id>         Stable artifact identifier written to the manifest.
                --preset <name>            Model lane preset. Defaults to local-frontier.
                --judge-model <id>         Sets JUDGE_MODEL for rubric grading.
                --filter <substr>          Only run cases whose id contains <substr>.
                --include-sandbox-frontier Also run SandboxFrontier. Off by default.
                --from-reports <dir>       Fixture/smoke mode. Builds the bundle from
                                           existing EvalReport JSON files without model calls.
                --startup-timeout <s>      Startup bootstrap watchdog. Use 0 to disable.
                --bootstrap-plugins        Force installed native plugin loading.
                --no-plugin-bootstrap      Disable installed native plugin loading.

            ARTIFACTS:
                manifest.json
                evidence-registry.json
                summary.md
                summary.json
                reports/<model>/<suite>.json
                compare.md / compare.json when --baseline is supplied

            EXAMPLES:
                osaurus-evals report --local-model foundation --frontier-model openai/gpt-4o-mini
                osaurus-evals report --baseline build/evals/main-report --out-dir build/evals/pr-report/current
                osaurus-evals report --from-reports Packages/OsaurusEvals/Tests/OsaurusEvalsKitTests/Fixtures/AgentLoopRegressionLab
            """
        print(usage)
    }

    struct EvalReviewReportOptions {
        let suites: [URL]
        let localModelId: String
        let frontierModelId: String
        let preset: EvalReviewReportPreset
        let baseline: URL?
        let outDir: URL
        let artifactId: String?
        let judgeModel: String?
        let filter: String?
        let includeSandboxFrontier: Bool
        let fromReports: URL?
        let startupTimeoutSeconds: Double?
        let pluginBootstrapPreference: EvalInstalledPluginBootstrapPreference

        static func parse(_ args: [String]) throws -> EvalReviewReportOptions {
            var suites: [URL] = []
            var localModelId = "foundation"
            var frontierModelId = "openai/gpt-4o-mini"
            var preset = EvalReviewReportPreset.localFrontier
            var baseline: URL?
            var outDir: URL?
            var artifactId: String?
            var judgeModel: String?
            var filter: String?
            var includeSandboxFrontier = false
            var fromReports: URL?
            var startupTimeoutSeconds = EvalTimeoutReport.configuredStartupTimeoutSeconds()
            var pluginBootstrapPreference: EvalInstalledPluginBootstrapPreference = .automatic

            var i = 0
            while i < args.count {
                let arg = args[i]
                switch arg {
                case "--suite":
                    suites.append(try urlForArg(args, after: i, flag: arg))
                    i += 2
                case "--local-model":
                    localModelId = try valueForArg(args, after: i, flag: arg)
                    i += 2
                case "--frontier-model":
                    frontierModelId = try valueForArg(args, after: i, flag: arg)
                    i += 2
                case "--preset":
                    let raw = try valueForArg(args, after: i, flag: arg)
                    guard let parsed = EvalReviewReportPreset(rawValue: raw) else {
                        throw CLIError.invalidValue(arg, raw)
                    }
                    preset = parsed
                    i += 2
                case "--baseline":
                    baseline = try urlForArg(args, after: i, flag: arg)
                    i += 2
                case "--out-dir":
                    outDir = try urlForArg(args, after: i, flag: arg)
                    i += 2
                case "--artifact-id":
                    artifactId = try valueForArg(args, after: i, flag: arg)
                    i += 2
                case "--judge-model":
                    judgeModel = try valueForArg(args, after: i, flag: arg)
                    i += 2
                case "--filter":
                    filter = try valueForArg(args, after: i, flag: arg)
                    i += 2
                case "--include-sandbox-frontier":
                    includeSandboxFrontier = true
                    i += 1
                case "--from-reports":
                    fromReports = try urlForArg(args, after: i, flag: arg)
                    i += 2
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
                    printEvalReviewReportUsage()
                    Darwin.exit(0)
                default:
                    throw CLIError.unknownArg(arg)
                }
            }

            return EvalReviewReportOptions(
                suites: suites,
                localModelId: localModelId,
                frontierModelId: frontierModelId,
                preset: preset,
                baseline: baseline,
                outDir: outDir ?? defaultEvalReviewOutDir(),
                artifactId: artifactId,
                judgeModel: judgeModel,
                filter: filter,
                includeSandboxFrontier: includeSandboxFrontier,
                fromReports: fromReports,
                startupTimeoutSeconds: startupTimeoutSeconds,
                pluginBootstrapPreference: pluginBootstrapPreference
            )
        }

        func suiteURLsForLiveRun() -> [URL] {
            var selected = suites.isEmpty ? defaultEvalReviewSuiteURLs() : suites
            if includeSandboxFrontier {
                selected.append(defaultSandboxFrontierSuiteURL())
            }
            return selected
        }

        func suiteRefsForExistingReports(_ reports: [EvalReviewReportInput]) -> [EvalReviewSuiteRef] {
            if !suites.isEmpty {
                return suites.map { EvalReviewSuiteRef(name: suiteName(for: $0), path: $0.path) }
            }
            return reports.map {
                EvalReviewSuiteRef(name: $0.suite, path: $0.suitePath)
            }
        }

        func runModels() -> [EvalReviewRunModel] {
            var models: [EvalReviewRunModel] = []
            if preset.includesLocal {
                models.append(
                    EvalReviewRunModel(
                        role: .local,
                        rawModelId: localModelId,
                        selection: ModelSelection.parse(localModelId)
                    )
                )
            }
            if preset.includesFrontier {
                models.append(
                    EvalReviewRunModel(
                        role: .frontier,
                        rawModelId: frontierModelId,
                        selection: ModelSelection.parse(frontierModelId)
                    )
                )
            }
            return models
        }
    }

    enum EvalReviewReportPreset: String {
        case localFrontier = "local-frontier"
        case localOnly = "local-only"
        case frontierOnly = "frontier-only"

        var includesLocal: Bool {
            self == .localFrontier || self == .localOnly
        }

        var includesFrontier: Bool {
            self == .localFrontier || self == .frontierOnly
        }
    }

    struct EvalReviewRunModel {
        let role: EvalReviewModelRole
        let rawModelId: String
        let selection: ModelSelection
    }

    private static func defaultEvalReviewOutDir() -> URL {
        URL(fileURLWithPath: "build/evals/pr-report", isDirectory: true)
            .appendingPathComponent(timestampForEvalReviewPath(), isDirectory: true)
    }

    private static func defaultEvalReviewSuiteURLs() -> [URL] {
        [
            defaultSuiteURL(named: "AgentLoop"),
            defaultSuiteURL(named: "AgentLoopFrontier"),
        ]
    }

    private static func defaultSandboxFrontierSuiteURL() -> URL {
        defaultSuiteURL(named: "SandboxFrontier")
    }

    private static func defaultSuiteURL(named name: String) -> URL {
        let repoRoot = URL(
            fileURLWithPath: "Packages/OsaurusEvals/Suites/\(name)",
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: repoRoot.path) {
            return repoRoot
        }
        return URL(fileURLWithPath: "Suites/\(name)", isDirectory: true)
    }

    private static func suiteName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.deletingLastPathComponent().lastPathComponent : name
    }

    private static func uniqueSuiteName(
        _ base: String,
        usedNames: inout [String: Int]
    ) -> String {
        let count = usedNames[base, default: 0]
        usedNames[base] = count + 1
        return count == 0 ? base : "\(base)-\(count + 1)"
    }

    private static func uniqueSuiteRefs(_ refs: [EvalReviewSuiteRef]) -> [EvalReviewSuiteRef] {
        var seen: Set<String> = []
        var result: [EvalReviewSuiteRef] = []
        for ref in refs.sorted(by: { $0.name < $1.name }) {
            let key = "\(ref.name)\u{1F}\(ref.path)"
            guard seen.insert(key).inserted else { continue }
            result.append(ref)
        }
        return result
    }

    private static func uniqueModelRefs(_ refs: [EvalReviewModelRef]) -> [EvalReviewModelRef] {
        var seen: Set<String> = []
        var result: [EvalReviewModelRef] = []
        for ref in refs.sorted(by: { lhs, rhs in
            if lhs.role == rhs.role { return lhs.modelId < rhs.modelId }
            return lhs.role < rhs.role
        }) {
            let key = "\(ref.role.rawValue)\u{1F}\(ref.modelId)"
            guard seen.insert(key).inserted else { continue }
            result.append(ref)
        }
        return result
    }

    private static func sanitizedPathSegment(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = raw.unicodeScalars.map { scalar -> String in
            allowed.contains(scalar) ? String(scalar) : "_"
        }
        let segment = scalars.joined()
        return segment.isEmpty ? "model" : segment
    }

    private static func runArguments(
        suitePath: String,
        modelId: String,
        outPath: String,
        filter: String?,
        startupTimeoutSeconds: Double?,
        pluginBootstrapPreference: EvalInstalledPluginBootstrapPreference
    ) -> [String] {
        var args = [
            "osaurus-evals",
            "run",
            "--suite",
            suitePath,
            "--model",
            modelId,
            "--out",
            outPath,
        ]
        if let filter {
            args += ["--filter", filter]
        }
        if let startupTimeoutSeconds {
            args += ["--startup-timeout", String(startupTimeoutSeconds)]
        } else {
            args += ["--startup-timeout", "0"]
        }
        switch pluginBootstrapPreference {
        case .automatic:
            break
        case .force:
            args.append("--bootstrap-plugins")
        case .disabled:
            args.append("--no-plugin-bootstrap")
        }
        return args
    }

    private static func existingReportArguments(
        options opts: EvalReviewReportOptions,
        currentRoot: URL
    ) -> [String] {
        var args = [
            "osaurus-evals",
            "report",
            "--from-reports",
            currentRoot.path,
            "--out-dir",
            opts.outDir.path,
        ]
        if let baseline = opts.baseline {
            args += ["--baseline", baseline.path]
        }
        args += ["--preset", opts.preset.rawValue]
        if let artifactId = opts.artifactId {
            args += ["--artifact-id", artifactId]
        }
        if let filter = opts.filter {
            args += ["--filter", filter]
        }
        return args
    }

    private static func gitValue(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        } catch {
            return nil
        }
    }

    private static func isCIEnvironment() -> Bool {
        let value = ProcessInfo.processInfo.environment["CI"]?.lowercased()
        return value == "true" || value == "1"
    }

    private static func timestampForEvalReviewPath() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }
}

private func isoNowForEvalReviewCLI() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}
