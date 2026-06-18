//
//  EvalReviewReport.swift
//  OsaurusEvalsKit
//
//  PR-review artifact bundling for local + frontier eval evidence.
//

import Foundation

public enum EvalReviewModelRole: String, Sendable, Codable, Equatable, Comparable {
    case local
    case frontier

    public static func < (lhs: EvalReviewModelRole, rhs: EvalReviewModelRole) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct EvalReviewModelRef: Sendable, Codable, Equatable, Hashable {
    public let role: EvalReviewModelRole
    public let modelId: String

    public init(role: EvalReviewModelRole, modelId: String) {
        self.role = role
        self.modelId = modelId
    }
}

public struct EvalReviewSuiteRef: Sendable, Codable, Equatable {
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public struct EvalReviewCommandRecord: Sendable, Codable, Equatable {
    public let role: EvalReviewModelRole
    public let modelId: String
    public let suite: String
    public let suitePath: String
    public let outputPath: String
    public let arguments: [String]
    public let exitCode: Int

    public init(
        role: EvalReviewModelRole,
        modelId: String,
        suite: String,
        suitePath: String,
        outputPath: String,
        arguments: [String],
        exitCode: Int
    ) {
        self.role = role
        self.modelId = modelId
        self.suite = suite
        self.suitePath = suitePath
        self.outputPath = outputPath
        self.arguments = arguments
        self.exitCode = exitCode
    }
}

public struct EvalReviewEnvironmentSummary: Sendable, Codable, Equatable {
    public let operatingSystem: String
    public let ci: Bool
    public let judgeModel: String?
    public let sandboxFrontierIncluded: Bool

    public init(
        operatingSystem: String,
        ci: Bool,
        judgeModel: String?,
        sandboxFrontierIncluded: Bool
    ) {
        self.operatingSystem = operatingSystem
        self.ci = ci
        self.judgeModel = judgeModel
        self.sandboxFrontierIncluded = sandboxFrontierIncluded
    }
}

public struct EvalReviewManifest: Sendable, Codable, Equatable {
    public let generatedAt: String
    public let branch: String
    public let commit: String
    public let runner: String
    public let artifactPath: String
    public let suites: [EvalReviewSuiteRef]
    public let models: [EvalReviewModelRef]
    public let commands: [EvalReviewCommandRecord]
    public let environment: EvalReviewEnvironmentSummary
    public let baselinePath: String?

    public init(
        generatedAt: String,
        branch: String,
        commit: String,
        runner: String,
        artifactPath: String,
        suites: [EvalReviewSuiteRef],
        models: [EvalReviewModelRef],
        commands: [EvalReviewCommandRecord],
        environment: EvalReviewEnvironmentSummary,
        baselinePath: String?
    ) {
        self.generatedAt = generatedAt
        self.branch = branch
        self.commit = commit
        self.runner = runner
        self.artifactPath = artifactPath
        self.suites = suites
        self.models = models
        self.commands = commands
        self.environment = environment
        self.baselinePath = baselinePath
    }
}

public struct EvalReviewOutcomeCounts: Sendable, Codable, Equatable {
    public let total: Int
    public let passed: Int
    public let failed: Int
    public let skipped: Int
    public let errored: Int

    public init(total: Int, passed: Int, failed: Int, skipped: Int, errored: Int) {
        self.total = total
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
        self.errored = errored
    }

    public init(cases: [EvalCaseReport]) {
        self.init(
            total: cases.count,
            passed: cases.filter { $0.outcome == .passed }.count,
            failed: cases.filter { $0.outcome == .failed }.count,
            skipped: cases.filter { $0.outcome == .skipped }.count,
            errored: cases.filter { $0.outcome == .errored }.count
        )
    }

    public static let zero = EvalReviewOutcomeCounts(
        total: 0,
        passed: 0,
        failed: 0,
        skipped: 0,
        errored: 0
    )

    public func adding(_ other: EvalReviewOutcomeCounts) -> EvalReviewOutcomeCounts {
        EvalReviewOutcomeCounts(
            total: total + other.total,
            passed: passed + other.passed,
            failed: failed + other.failed,
            skipped: skipped + other.skipped,
            errored: errored + other.errored
        )
    }
}

public struct EvalReviewCaseSummary: Sendable, Codable, Equatable {
    public let id: String
    public let label: String
    public let outcome: EvalCaseOutcome
    public let notes: [String]

    public init(row: EvalCaseReport) {
        id = row.id
        label = row.label
        outcome = row.outcome
        notes = row.notes
    }
}

public struct EvalReviewSuiteSummary: Sendable, Codable, Equatable {
    public let suite: String
    public let reportPath: String
    public let counts: EvalReviewOutcomeCounts
    public let failures: [EvalReviewCaseSummary]
    public let errors: [EvalReviewCaseSummary]
    public let skipped: [EvalReviewCaseSummary]

    public init(suite: String, reportPath: String, report: EvalReport) {
        self.suite = suite
        self.reportPath = reportPath
        counts = EvalReviewOutcomeCounts(cases: report.cases)
        failures = report.cases
            .filter { $0.outcome == .failed }
            .map(EvalReviewCaseSummary.init(row:))
        errors = report.cases
            .filter { $0.outcome == .errored }
            .map(EvalReviewCaseSummary.init(row:))
        skipped = report.cases
            .filter { $0.outcome == .skipped }
            .map(EvalReviewCaseSummary.init(row:))
    }
}

public struct EvalReviewModelSummary: Sendable, Codable, Equatable {
    public let role: EvalReviewModelRole
    public let modelId: String
    public let counts: EvalReviewOutcomeCounts
    public let suites: [EvalReviewSuiteSummary]

    public init(role: EvalReviewModelRole, modelId: String, suites: [EvalReviewSuiteSummary]) {
        self.role = role
        self.modelId = modelId
        self.suites = suites
        counts = suites.reduce(.zero) { $0.adding($1.counts) }
    }
}

public struct EvalReviewReportInput: Sendable {
    public let role: EvalReviewModelRole
    public let suite: String
    public let suitePath: String
    public let reportPath: String
    public let report: EvalReport

    public init(
        role: EvalReviewModelRole,
        suite: String,
        suitePath: String,
        reportPath: String,
        report: EvalReport
    ) {
        self.role = role
        self.suite = suite
        self.suitePath = suitePath
        self.reportPath = reportPath
        self.report = report
    }
}

public struct EvalReviewCaseDelta: Sendable, Codable, Equatable {
    public let modelId: String
    public let suite: String
    public let id: String
    public let baselineOutcome: EvalCaseOutcome?
    public let currentOutcome: EvalCaseOutcome?
    public let baselineNotes: [String]
    public let currentNotes: [String]

    public init(baseline: EvalReviewCaseSnapshot?, current: EvalReviewCaseSnapshot?) {
        modelId = current?.modelId ?? baseline?.modelId ?? "(unknown)"
        suite = current?.suite ?? baseline?.suite ?? "(unknown)"
        id = current?.id ?? baseline?.id ?? "(unknown)"
        baselineOutcome = baseline?.outcome
        currentOutcome = current?.outcome
        baselineNotes = baseline?.notes ?? []
        currentNotes = current?.notes ?? []
    }
}

public struct EvalReviewComparisonSummary: Sendable, Codable, Equatable {
    public let baselinePath: String
    public let regressions: [EvalReviewCaseDelta]
    public let newFailures: [EvalReviewCaseDelta]
    public let fixed: [EvalReviewCaseDelta]
    public let persistentFailures: [EvalReviewCaseDelta]
    public let changedSkips: [EvalReviewCaseDelta]
    public let newCases: [EvalReviewCaseDelta]
    public let removedCases: [EvalReviewCaseDelta]
    public let warnings: [String]

    public var hasBlockingRegressions: Bool {
        !regressions.isEmpty || !newFailures.isEmpty
    }
}

public struct EvalReviewReportBundle: Sendable, Codable, Equatable {
    public let manifest: EvalReviewManifest
    public let models: [EvalReviewModelSummary]
    public let comparison: EvalReviewComparisonSummary?

    public var hasRunFailures: Bool {
        models.contains { $0.counts.failed > 0 || $0.counts.errored > 0 }
    }

    public var hasBlockingRegressions: Bool {
        comparison?.hasBlockingRegressions ?? false
    }

    public func toJSON(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting =
            prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func formatMarkdown() -> String {
        var lines: [String] = []
        lines.append("# Eval Review Report")
        lines.append("")
        lines.append("- Generated: \(manifest.generatedAt)")
        lines.append("- Branch: `\(manifest.branch)`")
        lines.append("- Commit: `\(manifest.commit)`")
        lines.append("- Artifact: `\(manifest.artifactPath)`")
        lines.append("- Verdict: \(verdictLabel())")
        if let baseline = manifest.baselinePath {
            lines.append("- Baseline: `\(baseline)`")
        }
        if let judge = manifest.environment.judgeModel {
            lines.append("- Judge model: `\(judge)`")
        }
        lines.append("")
        lines.append("## PR Evidence")
        lines.append("")
        appendPREvidence(into: &lines)
        lines.append("")
        lines.append("## Model Totals")
        lines.append("")
        lines.append("| Role | Model | Total | Passed | Failed | Errored | Skipped |")
        lines.append("| --- | --- | ---: | ---: | ---: | ---: | ---: |")
        for model in models.sorted(by: modelSort) {
            lines.append(
                "| \(model.role.rawValue) | \(markdownCell(model.modelId)) | "
                    + "\(model.counts.total) | \(model.counts.passed) | "
                    + "\(model.counts.failed) | \(model.counts.errored) | \(model.counts.skipped) |"
            )
        }
        lines.append("")
        lines.append("## Suite Reports")
        lines.append("")
        lines.append("| Role | Model | Suite | Passed | Failed | Errored | Skipped | Report |")
        lines.append("| --- | --- | --- | ---: | ---: | ---: | ---: | --- |")
        for model in models.sorted(by: modelSort) {
            for suite in model.suites.sorted(by: { $0.suite < $1.suite }) {
                lines.append(
                    "| \(model.role.rawValue) | \(markdownCell(model.modelId)) | "
                        + "\(markdownCell(suite.suite)) | \(suite.counts.passed) | "
                        + "\(suite.counts.failed) | \(suite.counts.errored) | "
                        + "\(suite.counts.skipped) | `\(suite.reportPath)` |"
                )
            }
        }
        appendCasesSection(title: "Failures", outcomes: [.failed], into: &lines)
        appendCasesSection(title: "Errors", outcomes: [.errored], into: &lines)
        appendCasesSection(title: "Skipped Cases", outcomes: [.skipped], into: &lines)
        appendComparison(into: &lines)
        lines.append("")
        lines.append("## Commands")
        lines.append("")
        for command in manifest.commands {
            lines.append("- `\(command.arguments.joined(separator: " "))`")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func formatComparisonMarkdown() -> String {
        guard let comparison else {
            return "# Eval Review Comparison\n\nNo baseline comparison was requested.\n"
        }
        var lines: [String] = []
        lines.append("# Eval Review Comparison")
        lines.append("")
        lines.append("- Baseline: `\(comparison.baselinePath)`")
        lines.append("- Verdict: \(comparison.hasBlockingRegressions ? "REGRESSED" : "PASS")")
        appendDeltaSection("Blocking Regressions", comparison.regressions, into: &lines)
        appendDeltaSection("New Failing Cases", comparison.newFailures, into: &lines)
        appendDeltaSection("Fixed Cases", comparison.fixed, into: &lines)
        appendDeltaSection("Persistent Failures", comparison.persistentFailures, into: &lines)
        appendDeltaSection("Changed Skips", comparison.changedSkips, into: &lines)
        appendDeltaSection("Suite Drift", comparison.newCases + comparison.removedCases, into: &lines)
        if !comparison.warnings.isEmpty {
            lines.append("")
            lines.append("## Warnings")
            lines.append("")
            for warning in comparison.warnings {
                lines.append("- \(markdownCell(warning))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func verdictLabel() -> String {
        if hasBlockingRegressions { return "REGRESSED" }
        if hasRunFailures { return "EVAL FAILURES PRESENT" }
        return "PASS"
    }

    private func appendPREvidence(into lines: inout [String]) {
        let local = models.first { $0.role == .local }
        let frontier = models.first { $0.role == .frontier }
        lines.append("Eval evidence:")
        lines.append("- Local: \(evidenceLine(local))")
        lines.append("- Frontier: \(evidenceLine(frontier))")
        if let comparison {
            let regressions = comparison.regressions.count + comparison.newFailures.count
            lines.append("- Regressions vs baseline: \(regressions == 0 ? "none" : "\(regressions)")")
        } else {
            lines.append("- Regressions vs baseline: not run")
        }
        lines.append("- Artifact: \(manifest.artifactPath)")
    }

    private func evidenceLine(_ model: EvalReviewModelSummary?) -> String {
        guard let model else { return "not run" }
        let suiteParts = model.suites.sorted(by: { $0.suite < $1.suite }).map { suite in
            "\(suite.suite) \(suite.counts.passed)/\(suite.counts.total)"
        }
        return "\(model.modelId), \(suiteParts.joined(separator: ", "))"
    }

    private func appendCasesSection(
        title: String,
        outcomes: Set<EvalCaseOutcome>,
        into lines: inout [String]
    ) {
        let rows = models.flatMap { model in
            model.suites.flatMap { suite in
                cases(for: suite, outcomes: outcomes).map { row in
                    (model: model, suite: suite, row: row)
                }
            }
        }
        guard !rows.isEmpty else { return }
        lines.append("")
        lines.append("## \(title)")
        lines.append("")
        lines.append("| Role | Model | Suite | Case | Notes |")
        lines.append("| --- | --- | --- | --- | --- |")
        for item in rows {
            lines.append(
                "| \(item.model.role.rawValue) | \(markdownCell(item.model.modelId)) | "
                    + "\(markdownCell(item.suite.suite)) | \(markdownCell(item.row.id)) | "
                    + "\(markdownCell(item.row.notes.prefix(2).joined(separator: " / "))) |"
            )
        }
    }

    private func cases(
        for suite: EvalReviewSuiteSummary,
        outcomes: Set<EvalCaseOutcome>
    ) -> [EvalReviewCaseSummary] {
        var rows: [EvalReviewCaseSummary] = []
        if outcomes.contains(.failed) { rows.append(contentsOf: suite.failures) }
        if outcomes.contains(.errored) { rows.append(contentsOf: suite.errors) }
        if outcomes.contains(.skipped) { rows.append(contentsOf: suite.skipped) }
        return rows.sorted { $0.id < $1.id }
    }

    private func appendComparison(into lines: inout [String]) {
        guard let comparison else { return }
        lines.append("")
        lines.append("## Baseline Comparison")
        lines.append("")
        lines.append("- Blocking regressions: \(comparison.regressions.count)")
        lines.append("- New failing cases: \(comparison.newFailures.count)")
        lines.append("- Fixed cases: \(comparison.fixed.count)")
        lines.append("- Persistent failures: \(comparison.persistentFailures.count)")
        lines.append("- Changed skips: \(comparison.changedSkips.count)")
    }

    private func appendDeltaSection(
        _ title: String,
        _ rows: [EvalReviewCaseDelta],
        into lines: inout [String]
    ) {
        guard !rows.isEmpty else { return }
        lines.append("")
        lines.append("## \(title)")
        lines.append("")
        lines.append("| Model | Suite | Case | Baseline | Current | Notes |")
        lines.append("| --- | --- | --- | --- | --- | --- |")
        for row in rows {
            let notes = row.currentNotes.isEmpty ? row.baselineNotes : row.currentNotes
            lines.append(
                "| \(markdownCell(row.modelId)) | \(markdownCell(row.suite)) | "
                    + "\(markdownCell(row.id)) | \(outcomeLabel(row.baselineOutcome)) | "
                    + "\(outcomeLabel(row.currentOutcome)) | "
                    + "\(markdownCell(notes.prefix(2).joined(separator: " / "))) |"
            )
        }
    }

    private func outcomeLabel(_ outcome: EvalCaseOutcome?) -> String {
        outcome?.rawValue ?? "missing"
    }

    private func markdownCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    private func modelSort(_ lhs: EvalReviewModelSummary, _ rhs: EvalReviewModelSummary) -> Bool {
        if lhs.role == rhs.role { return lhs.modelId < rhs.modelId }
        return lhs.role < rhs.role
    }
}

public enum EvalReviewReportBuilder {
    public static func build(
        manifest: EvalReviewManifest,
        reports: [EvalReviewReportInput],
        baselineReports: [EvalReviewReportInput] = []
    ) -> EvalReviewReportBundle {
        let grouped = Dictionary(grouping: reports) { input in
            EvalReviewModelRef(role: input.role, modelId: input.report.modelId)
        }
        let unsortedModels = grouped.map { key, inputs in
            EvalReviewModelSummary(
                role: key.role,
                modelId: key.modelId,
                suites: inputs
                    .sorted { $0.suite < $1.suite }
                    .map {
                        EvalReviewSuiteSummary(
                            suite: $0.suite,
                            reportPath: $0.reportPath,
                            report: $0.report
                        )
                    }
            )
        }
        let models = unsortedModels.sorted { lhs, rhs in
            if lhs.role == rhs.role { return lhs.modelId < rhs.modelId }
            return lhs.role < rhs.role
        }

        let comparison = manifest.baselinePath.map { baselinePath in
            compare(
                baselinePath: baselinePath,
                baselineReports: baselineReports,
                currentReports: reports
            )
        }

        return EvalReviewReportBundle(
            manifest: manifest,
            models: models,
            comparison: comparison
        )
    }

    public static func missingReport(
        role: EvalReviewModelRole,
        modelId: String,
        suite: EvalReviewSuiteRef,
        reportPath: String,
        note: String
    ) -> EvalReviewReportInput {
        let row = EvalCaseReport.terminal(
            id: "missing-report.\(suite.name)",
            label: "missing report for \(suite.name)",
            domain: "agent_loop",
            outcome: .errored,
            notes: [note],
            modelId: modelId
        )
        return EvalReviewReportInput(
            role: role,
            suite: suite.name,
            suitePath: suite.path,
            reportPath: reportPath,
            report: EvalReport(
                modelId: modelId,
                startedAt: isoNowForEvalReviewReport(),
                cases: [row]
            )
        )
    }

    public static func loadReportsRecursively(
        from root: URL,
        role: EvalReviewModelRole = .local
    ) throws -> [EvalReviewReportInput] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw EvalReviewReportError.pathNotFound(root.path)
        }

        let urls: [URL]
        if isDirectory.boolValue {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                throw EvalReviewReportError.noReports(root.path)
            }
            urls = enumerator.compactMap { item in
                guard let url = item as? URL, url.pathExtension.lowercased() == "json" else {
                    return nil
                }
                return url
            }
            .sorted { $0.path < $1.path }
        } else {
            urls = [root]
        }

        let decoder = JSONDecoder()
        let reports = urls.compactMap { url -> EvalReviewReportInput? in
            guard let data = try? Data(contentsOf: url),
                  let report = try? decoder.decode(EvalReport.self, from: data)
            else {
                return nil
            }
            return EvalReviewReportInput(
                role: roleFromPath(url, fallback: role),
                suite: url.deletingPathExtension().lastPathComponent,
                suitePath: url.path,
                reportPath: url.path,
                report: report
            )
        }

        guard !reports.isEmpty else {
            throw EvalReviewReportError.noReports(root.path)
        }
        return reports
    }

    private static func compare(
        baselinePath: String,
        baselineReports: [EvalReviewReportInput],
        currentReports: [EvalReviewReportInput]
    ) -> EvalReviewComparisonSummary {
        let baseline = index(baselineReports)
        let current = index(currentReports)
        let baselineKeys = Set(baseline.byKey.keys)
        let currentKeys = Set(current.byKey.keys)

        var regressions: [EvalReviewCaseDelta] = []
        var newFailures: [EvalReviewCaseDelta] = []
        var fixed: [EvalReviewCaseDelta] = []
        var persistentFailures: [EvalReviewCaseDelta] = []
        var changedSkips: [EvalReviewCaseDelta] = []
        var newCases: [EvalReviewCaseDelta] = []
        var removedCases: [EvalReviewCaseDelta] = []

        for key in baselineKeys.intersection(currentKeys).sorted() {
            let lhs = baseline.byKey[key]
            let rhs = current.byKey[key]
            let delta = EvalReviewCaseDelta(baseline: lhs, current: rhs)
            if lhs?.outcome == .passed && isFailing(rhs?.outcome) {
                regressions.append(delta)
            } else if isFailing(lhs?.outcome) && rhs?.outcome == .passed {
                fixed.append(delta)
            } else if isFailing(lhs?.outcome) && isFailing(rhs?.outcome) {
                persistentFailures.append(delta)
            } else if lhs?.outcome == .skipped || rhs?.outcome == .skipped,
                      lhs?.outcome != rhs?.outcome {
                changedSkips.append(delta)
            }
        }

        for key in currentKeys.subtracting(baselineKeys).sorted() {
            let rhs = current.byKey[key]
            let delta = EvalReviewCaseDelta(baseline: nil, current: rhs)
            if isFailing(rhs?.outcome) {
                newFailures.append(delta)
            } else {
                newCases.append(delta)
            }
        }

        for key in baselineKeys.subtracting(currentKeys).sorted() {
            removedCases.append(
                EvalReviewCaseDelta(baseline: baseline.byKey[key], current: nil)
            )
        }

        return EvalReviewComparisonSummary(
            baselinePath: baselinePath,
            regressions: regressions,
            newFailures: newFailures,
            fixed: fixed,
            persistentFailures: persistentFailures,
            changedSkips: changedSkips,
            newCases: newCases,
            removedCases: removedCases,
            warnings: (baseline.warnings + current.warnings).sorted()
        )
    }

    private static func index(
        _ reports: [EvalReviewReportInput]
    ) -> (byKey: [String: EvalReviewCaseSnapshot], warnings: [String]) {
        var byKey: [String: EvalReviewCaseSnapshot] = [:]
        var warnings: [String] = []
        for input in reports {
            for row in input.report.cases {
                let snapshot = EvalReviewCaseSnapshot(suite: input.suite, row: row)
                let key = snapshot.key
                if let existing = byKey[key] {
                    warnings.append(
                        "duplicate case '\(snapshot.id)' for \(snapshot.modelId)/\(snapshot.suite); keeping \(existing.suite)"
                    )
                } else {
                    byKey[key] = snapshot
                }
            }
        }
        return (byKey, warnings)
    }

    private static func isFailing(_ outcome: EvalCaseOutcome?) -> Bool {
        outcome == .failed || outcome == .errored
    }

    private static func roleFromPath(_ url: URL, fallback: EvalReviewModelRole) -> EvalReviewModelRole {
        let parts = url.pathComponents.map { $0.lowercased() }
        if parts.contains(EvalReviewModelRole.frontier.rawValue) { return .frontier }
        if parts.contains(EvalReviewModelRole.local.rawValue) { return .local }
        return fallback
    }
}

public enum EvalReviewReportError: Error, LocalizedError, Equatable {
    case pathNotFound(String)
    case noReports(String)

    public var errorDescription: String? {
        switch self {
        case .pathNotFound(let path):
            return "path does not exist: \(path)"
        case .noReports(let path):
            return "no eval report JSON files found at: \(path)"
        }
    }
}

public struct EvalReviewCaseSnapshot: Sendable, Codable, Equatable {
    public let modelId: String
    public let suite: String
    public let id: String
    public let outcome: EvalCaseOutcome
    public let notes: [String]

    public var key: String { "\(modelId)\u{1F}\(suite)\u{1F}\(id)" }

    public init(suite: String, row: EvalCaseReport) {
        modelId = row.modelId
        self.suite = suite
        id = row.id
        outcome = row.outcome
        notes = row.notes
    }
}

private func isoNowForEvalReviewReport() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}
