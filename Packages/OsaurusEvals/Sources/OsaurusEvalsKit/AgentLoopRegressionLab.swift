//
//  AgentLoopRegressionLab.swift
//  OsaurusEvalsKit
//
//  Baseline comparison and artifact rendering for the agent_loop eval lane.
//

import Foundation

public struct AgentLoopRegressionArtifact: Sendable, Codable, Equatable {
    public let kind: String
    public let path: String

    public init(kind: String, path: String) {
        self.kind = kind
        self.path = path
    }
}

public struct AgentLoopRegressionReportSet: Sendable {
    public struct NamedReport: Sendable {
        public let name: String
        public let url: URL?
        public let report: EvalReport

        public init(name: String, url: URL?, report: EvalReport) {
            self.name = name
            self.url = url
            self.report = report
        }
    }

    public let label: String
    public let reports: [NamedReport]

    public init(label: String, reports: [NamedReport]) {
        self.label = label
        self.reports = reports
    }

    public func filteringCaseIDs(containing filter: String?) -> AgentLoopRegressionReportSet {
        guard let filter, !filter.isEmpty else { return self }
        return AgentLoopRegressionReportSet(
            label: label,
            reports: reports.map { named in
                NamedReport(
                    name: named.name,
                    url: named.url,
                    report: EvalReport(
                        modelId: named.report.modelId,
                        startedAt: named.report.startedAt,
                        cases: named.report.cases.filter { $0.id.contains(filter) }
                    )
                )
            }
        )
    }

    public static func load(from url: URL, label: String? = nil) throws -> AgentLoopRegressionReportSet {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw AgentLoopRegressionLabError.pathNotFound(url.path)
        }

        let isDir = isDirectory.boolValue
        let reportURLs: [URL]
        if isDir {
            reportURLs = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if reportURLs.isEmpty {
                throw AgentLoopRegressionLabError.noReports(url.path)
            }
        } else {
            reportURLs = [url]
        }

        let decoder = JSONDecoder()
        let reports: [NamedReport]
        if isDir {
            // A loop run dir holds per-suite reports AND derived artifacts
            // (matrix.json, diff.json, notes). Skip anything that isn't a
            // non-empty EvalReport so `diff <prev-run-dir> <this-run-dir>`
            // works against the loop's own output dirs — mirrors the lenient
            // EvalMatrixBuilder.loadReports the `matrix` subcommand already
            // uses. Without this, every loop diff throws because the baseline
            // dir always contains its own matrix.json.
            reports = reportURLs.compactMap { reportURL -> NamedReport? in
                guard let data = try? Data(contentsOf: reportURL),
                    let report = try? decoder.decode(EvalReport.self, from: data),
                    !report.cases.isEmpty
                else { return nil }
                return NamedReport(
                    name: reportURL.deletingPathExtension().lastPathComponent,
                    url: reportURL,
                    report: report
                )
            }
            if reports.isEmpty {
                throw AgentLoopRegressionLabError.noReports(url.path)
            }
        } else {
            // An explicitly named single file must decode — surface a loud
            // error on a typo or a caller pointing at a non-report file.
            reports = try reportURLs.map { reportURL -> NamedReport in
                let data = try Data(contentsOf: reportURL)
                let report = try decoder.decode(EvalReport.self, from: data)
                return NamedReport(
                    name: reportURL.deletingPathExtension().lastPathComponent,
                    url: reportURL,
                    report: report
                )
            }
        }

        return AgentLoopRegressionReportSet(
            label: label ?? url.deletingPathExtension().lastPathComponent,
            reports: reports
        )
    }
}

public struct AgentLoopRegressionOutcomeCounts: Sendable, Codable, Equatable {
    public let total: Int
    public let passed: Int
    public let failed: Int
    public let skipped: Int
    public let errored: Int

    public init(cases: [AgentLoopRegressionCaseSnapshot]) {
        total = cases.count
        passed = cases.filter { $0.outcome == .passed }.count
        failed = cases.filter { $0.outcome == .failed }.count
        skipped = cases.filter { $0.outcome == .skipped }.count
        errored = cases.filter { $0.outcome == .errored }.count
    }
}

public struct AgentLoopRegressionCaseSnapshot: Sendable, Codable, Equatable {
    public let suite: String
    public let id: String
    public let label: String
    public let outcome: EvalCaseOutcome
    public let modelId: String
    public let latencyMs: Double?
    public let notes: [String]
    public let toolCalls: Int?
    public let toolErrors: Int?
    public let toolDeduped: Int?

    public init(suite: String, row: EvalCaseReport) {
        let usage = row.toolUsage ?? []
        let calls = usage.map(\.calls).reduce(0, +)
        let errors = usage.map(\.errors).reduce(0, +)
        let deduped = usage.map(\.deduped).reduce(0, +)

        self.suite = suite
        self.id = row.id
        self.label = row.label
        self.outcome = row.outcome
        self.modelId = row.modelId
        self.latencyMs = row.latencyMs
        self.notes = row.notes
        self.toolCalls = usage.isEmpty ? nil : calls
        self.toolErrors = usage.isEmpty ? nil : errors
        self.toolDeduped = usage.isEmpty ? nil : deduped
    }
}

public struct AgentLoopRegressionCaseDelta: Sendable, Codable, Equatable {
    public let id: String
    public let suite: String
    public let baselineOutcome: EvalCaseOutcome?
    public let currentOutcome: EvalCaseOutcome?
    public let baselineLatencyMs: Double?
    public let currentLatencyMs: Double?
    public let latencyDeltaMs: Double?
    public let baselineToolCalls: Int?
    public let currentToolCalls: Int?
    public let toolCallDelta: Int?
    public let baselineToolErrors: Int?
    public let currentToolErrors: Int?
    public let toolErrorDelta: Int?
    public let baselineNotes: [String]
    public let currentNotes: [String]

    public init(
        baseline: AgentLoopRegressionCaseSnapshot?,
        current: AgentLoopRegressionCaseSnapshot?
    ) {
        let lhs = baseline
        let rhs = current
        id = rhs?.id ?? lhs?.id ?? "(unknown)"
        suite = rhs?.suite ?? lhs?.suite ?? "(unknown)"
        baselineOutcome = lhs?.outcome
        currentOutcome = rhs?.outcome
        baselineLatencyMs = lhs?.latencyMs
        currentLatencyMs = rhs?.latencyMs
        if let base = lhs?.latencyMs, let now = rhs?.latencyMs {
            latencyDeltaMs = now - base
        } else {
            latencyDeltaMs = nil
        }
        baselineToolCalls = lhs?.toolCalls
        currentToolCalls = rhs?.toolCalls
        if let base = lhs?.toolCalls, let now = rhs?.toolCalls {
            toolCallDelta = now - base
        } else {
            toolCallDelta = nil
        }
        baselineToolErrors = lhs?.toolErrors
        currentToolErrors = rhs?.toolErrors
        if let base = lhs?.toolErrors, let now = rhs?.toolErrors {
            toolErrorDelta = now - base
        } else {
            toolErrorDelta = nil
        }
        baselineNotes = lhs?.notes ?? []
        currentNotes = rhs?.notes ?? []
    }
}

public struct AgentLoopRegressionLabSummary: Sendable, Codable, Equatable {
    public let generatedAt: String
    public let baselineLabel: String
    public let currentLabel: String
    public let baselineModelId: String?
    public let currentModelId: String?
    public let baselineStartedAt: String?
    public let currentStartedAt: String?
    public let baselineCounts: AgentLoopRegressionOutcomeCounts
    public let currentCounts: AgentLoopRegressionOutcomeCounts
    public let regressions: [AgentLoopRegressionCaseDelta]
    public let newFailures: [AgentLoopRegressionCaseDelta]
    public let fixed: [AgentLoopRegressionCaseDelta]
    public let persistentFailures: [AgentLoopRegressionCaseDelta]
    public let newCases: [AgentLoopRegressionCaseDelta]
    public let removedCases: [AgentLoopRegressionCaseDelta]
    public let warnings: [String]
    public let artifacts: [AgentLoopRegressionArtifact]

    public var hasBlockingRegressions: Bool {
        !regressions.isEmpty || !newFailures.isEmpty
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
        let verdict =
            hasBlockingRegressions
            ? "REGRESSED: \(regressions.count) regression(s), \(newFailures.count) new failing case(s)"
            : "PASS: no blocking agent_loop regressions"

        lines.append("# Agent Loop Regression Lab")
        lines.append("")
        lines.append("- Verdict: \(verdict)")
        lines.append("- Generated: \(generatedAt)")
        lines.append("- Baseline: \(baselineLabel)\(modelSuffix(baselineModelId, baselineStartedAt))")
        lines.append("- Current: \(currentLabel)\(modelSuffix(currentModelId, currentStartedAt))")
        lines.append("")
        lines.append("## Totals")
        lines.append("")
        lines.append("| Bucket | Baseline | Current |")
        lines.append("| --- | ---: | ---: |")
        lines.append("| total | \(baselineCounts.total) | \(currentCounts.total) |")
        lines.append("| passed | \(baselineCounts.passed) | \(currentCounts.passed) |")
        lines.append("| failed | \(baselineCounts.failed) | \(currentCounts.failed) |")
        lines.append("| errored | \(baselineCounts.errored) | \(currentCounts.errored) |")
        lines.append("| skipped | \(baselineCounts.skipped) | \(currentCounts.skipped) |")

        appendDeltaSection(
            title: "Blocking Regressions",
            rows: regressions,
            into: &lines
        )
        appendDeltaSection(
            title: "New Failing Cases",
            rows: newFailures,
            into: &lines
        )
        appendDeltaSection(
            title: "Fixed Cases",
            rows: fixed,
            into: &lines
        )
        appendDeltaSection(
            title: "Persistent Failures",
            rows: persistentFailures,
            into: &lines
        )
        appendDeltaSection(
            title: "Suite Drift",
            rows: newCases + removedCases,
            into: &lines
        )

        if !artifacts.isEmpty {
            lines.append("")
            lines.append("## Artifacts")
            lines.append("")
            for artifact in artifacts {
                lines.append("- \(markdownCell(artifact.kind)): `\(artifact.path)`")
            }
        }

        if !warnings.isEmpty {
            lines.append("")
            lines.append("## Warnings")
            lines.append("")
            for warning in warnings {
                lines.append("- \(markdownCell(warning))")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func appendDeltaSection(
        title: String,
        rows: [AgentLoopRegressionCaseDelta],
        into lines: inout [String]
    ) {
        guard !rows.isEmpty else { return }
        lines.append("")
        lines.append("## \(title)")
        lines.append("")
        lines.append("| Case | Baseline | Current | Latency | Tools | Notes |")
        lines.append("| --- | --- | --- | ---: | ---: | --- |")
        for row in rows {
            lines.append(
                "| \(markdownCell(row.id)) | \(outcomeLabel(row.baselineOutcome)) | "
                    + "\(outcomeLabel(row.currentOutcome)) | \(latencyLabel(row)) | "
                    + "\(toolLabel(row)) | \(notesLabel(row)) |"
            )
        }
    }

    private func modelSuffix(_ modelId: String?, _ startedAt: String?) -> String {
        let model = modelId ?? "unknown model"
        if let startedAt {
            return " (\(model), \(startedAt))"
        }
        return " (\(model))"
    }

    private func outcomeLabel(_ outcome: EvalCaseOutcome?) -> String {
        outcome?.rawValue ?? "missing"
    }

    private func latencyLabel(_ row: AgentLoopRegressionCaseDelta) -> String {
        guard let delta = row.latencyDeltaMs else { return "-" }
        return signedMs(delta)
    }

    private func toolLabel(_ row: AgentLoopRegressionCaseDelta) -> String {
        var parts: [String] = []
        if let calls = row.toolCallDelta {
            parts.append("calls \(signedInt(calls))")
        }
        if let errors = row.toolErrorDelta {
            parts.append("errors \(signedInt(errors))")
        }
        return parts.isEmpty ? "-" : markdownCell(parts.joined(separator: ", "))
    }

    private func notesLabel(_ row: AgentLoopRegressionCaseDelta) -> String {
        let notes = row.currentNotes.isEmpty ? row.baselineNotes : row.currentNotes
        if notes.isEmpty { return "-" }
        return markdownCell(notes.prefix(2).joined(separator: " / "))
    }

    private func signedMs(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return "\(signedInt(rounded))ms"
    }

    private func signedInt(_ value: Int) -> String {
        value >= 0 ? "+\(value)" : "\(value)"
    }

    private func markdownCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
    }
}

public enum AgentLoopRegressionLab {
    public static func compare(
        baseline: AgentLoopRegressionReportSet,
        current: AgentLoopRegressionReportSet,
        generatedAt: String? = nil,
        artifacts: [AgentLoopRegressionArtifact] = []
    ) throws -> AgentLoopRegressionLabSummary {
        let baselineIndex = indexAgentLoopCases(in: baseline)
        let currentIndex = indexAgentLoopCases(in: current)

        guard !baselineIndex.cases.isEmpty else {
            throw AgentLoopRegressionLabError.noAgentLoopCases("baseline")
        }
        guard !currentIndex.cases.isEmpty else {
            throw AgentLoopRegressionLabError.noAgentLoopCases("current")
        }

        let baselineIds = Set(baselineIndex.byId.keys)
        let currentIds = Set(currentIndex.byId.keys)
        let commonIds = baselineIds.intersection(currentIds).sorted()
        let currentOnlyIds = currentIds.subtracting(baselineIds).sorted()
        let baselineOnlyIds = baselineIds.subtracting(currentIds).sorted()

        var regressions: [AgentLoopRegressionCaseDelta] = []
        var fixed: [AgentLoopRegressionCaseDelta] = []
        var persistentFailures: [AgentLoopRegressionCaseDelta] = []
        var newFailures: [AgentLoopRegressionCaseDelta] = []
        var newCases: [AgentLoopRegressionCaseDelta] = []
        var removedCases: [AgentLoopRegressionCaseDelta] = []

        for id in commonIds {
            let baselineCase = baselineIndex.byId[id]
            let currentCase = currentIndex.byId[id]
            let delta = AgentLoopRegressionCaseDelta(
                baseline: baselineCase,
                current: currentCase
            )
            if isBlockingRegression(baseline: baselineCase?.outcome, current: currentCase?.outcome) {
                regressions.append(delta)
            } else if isFixed(baseline: baselineCase?.outcome, current: currentCase?.outcome) {
                fixed.append(delta)
            } else if isPersistentFailure(baseline: baselineCase?.outcome, current: currentCase?.outcome) {
                persistentFailures.append(delta)
            }
        }

        for id in currentOnlyIds {
            let currentCase = currentIndex.byId[id]
            let delta = AgentLoopRegressionCaseDelta(baseline: nil, current: currentCase)
            if isFailing(currentCase?.outcome) {
                newFailures.append(delta)
            } else {
                newCases.append(delta)
            }
        }

        for id in baselineOnlyIds {
            removedCases.append(
                AgentLoopRegressionCaseDelta(
                    baseline: baselineIndex.byId[id],
                    current: nil
                )
            )
        }

        return AgentLoopRegressionLabSummary(
            generatedAt: generatedAt ?? isoNowForAgentLoopRegressionLab(),
            baselineLabel: baseline.label,
            currentLabel: current.label,
            baselineModelId: commonModelId(in: baseline),
            currentModelId: commonModelId(in: current),
            baselineStartedAt: commonStartedAt(in: baseline),
            currentStartedAt: commonStartedAt(in: current),
            baselineCounts: AgentLoopRegressionOutcomeCounts(cases: baselineIndex.cases),
            currentCounts: AgentLoopRegressionOutcomeCounts(cases: currentIndex.cases),
            regressions: regressions,
            newFailures: newFailures,
            fixed: fixed,
            persistentFailures: persistentFailures,
            newCases: newCases,
            removedCases: removedCases,
            warnings: (baselineIndex.warnings + currentIndex.warnings).sorted(),
            artifacts: artifacts
        )
    }

    public static func validateAgentLoopSuite(
        _ suite: EvalSuite,
        filter: String?
    ) throws {
        let selected = suite.cases.filter { testCase in
            filter.map { testCase.id.contains($0) } ?? true
        }
        guard !selected.isEmpty else {
            throw AgentLoopRegressionLabError.noSelectedCases(suite.directory.path)
        }
        let nonAgentLoop = selected.filter { $0.domain != "agent_loop" }.map(\.id)
        guard nonAgentLoop.isEmpty else {
            throw AgentLoopRegressionLabError.nonAgentLoopCases(nonAgentLoop.sorted())
        }
    }

    private static func indexAgentLoopCases(
        in set: AgentLoopRegressionReportSet
    ) -> (
        cases: [AgentLoopRegressionCaseSnapshot],
        byId: [String: AgentLoopRegressionCaseSnapshot],
        warnings: [String]
    ) {
        var cases: [AgentLoopRegressionCaseSnapshot] = []
        var byId: [String: AgentLoopRegressionCaseSnapshot] = [:]
        var warnings: [String] = []

        for named in set.reports.sorted(by: { $0.name < $1.name }) {
            for row in named.report.cases where row.domain == "agent_loop" {
                let snapshot = AgentLoopRegressionCaseSnapshot(suite: named.name, row: row)
                cases.append(snapshot)
                if let existing = byId[snapshot.id] {
                    warnings.append(
                        "duplicate agent_loop case id '\(snapshot.id)' in \(existing.suite) and \(snapshot.suite); keeping \(existing.suite)"
                    )
                } else {
                    byId[snapshot.id] = snapshot
                }
            }
        }

        cases.sort { lhs, rhs in
            if lhs.suite == rhs.suite { return lhs.id < rhs.id }
            return lhs.suite < rhs.suite
        }
        return (cases, byId, warnings)
    }

    private static func isBlockingRegression(
        baseline: EvalCaseOutcome?,
        current: EvalCaseOutcome?
    ) -> Bool {
        guard let baseline, let current else { return false }
        if baseline == .passed && current != .passed { return true }
        if baseline == .failed && current == .errored { return true }
        if baseline == .skipped && current == .errored { return true }
        return false
    }

    private static func isFixed(
        baseline: EvalCaseOutcome?,
        current: EvalCaseOutcome?
    ) -> Bool {
        guard let baseline, let current else { return false }
        return (baseline == .failed || baseline == .errored) && current == .passed
    }

    private static func isPersistentFailure(
        baseline: EvalCaseOutcome?,
        current: EvalCaseOutcome?
    ) -> Bool {
        guard let baseline, let current else { return false }
        return isFailing(baseline) && isFailing(current)
            && !isBlockingRegression(
                baseline: baseline,
                current: current
            )
    }

    private static func isFailing(_ outcome: EvalCaseOutcome?) -> Bool {
        outcome == .failed || outcome == .errored
    }

    private static func commonModelId(in set: AgentLoopRegressionReportSet) -> String? {
        commonValue(set.reports.map(\.report.modelId))
    }

    private static func commonStartedAt(in set: AgentLoopRegressionReportSet) -> String? {
        commonValue(set.reports.map(\.report.startedAt))
    }

    private static func commonValue(_ values: [String]) -> String? {
        let unique = Set(values)
        if unique.count == 1 { return unique.first }
        if values.isEmpty { return nil }
        return "mixed"
    }
}

public enum AgentLoopRegressionLabError: Error, LocalizedError, Equatable {
    case pathNotFound(String)
    case noReports(String)
    case noAgentLoopCases(String)
    case noSelectedCases(String)
    case nonAgentLoopCases([String])

    public var errorDescription: String? {
        switch self {
        case .pathNotFound(let path):
            return "path does not exist: \(path)"
        case .noReports(let path):
            return "no JSON eval reports found at: \(path)"
        case .noAgentLoopCases(let label):
            return "\(label) report set has no agent_loop cases"
        case .noSelectedCases(let path):
            return "suite selection has no cases: \(path)"
        case .nonAgentLoopCases(let ids):
            return "agent-loop lab only accepts agent_loop cases; non-agent cases: \(ids.joined(separator: ", "))"
        }
    }
}

private func isoNowForAgentLoopRegressionLab() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}
