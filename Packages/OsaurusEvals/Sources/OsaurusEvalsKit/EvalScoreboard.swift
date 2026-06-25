//
//  EvalScoreboard.swift
//  OsaurusEvalsKit
//
//  Cross-bundle scoreboard artifacts for watcher-oriented eval runs.
//

import Foundation

public struct EvalScoreboardBundle: Sendable, Codable, Equatable {
    public let generatedAt: String
    public let sourceRoots: [String]
    public let releaseCandidate: EvalReleaseCandidateScoreSummary?
    public let noRegression: EvalScoreboardNoRegressionSummary
    public let runs: [EvalScoreboardRunSummary]
    public let models: [EvalScoreboardModelSummary]
    public let suites: [EvalScoreboardSuiteSummary]
    public let comparison: EvalScoreboardComparisonSummary

    public var hasBlockingRegressions: Bool {
        !noRegression.passed
    }

    public var hasRunFailures: Bool {
        guard let releaseCandidate else {
            return models.contains { $0.counts.failed > 0 || $0.counts.errored > 0 }
        }
        return (releaseCandidate.local + releaseCandidate.frontier)
            .contains { $0.counts.failed > 0 || $0.counts.errored > 0 }
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
        lines.append("# Eval Watcher Scoreboard")
        lines.append("")
        lines.append("- Generated: \(generatedAt)")
        lines.append("- Source roots: \(sourceRoots.map { "`\($0)`" }.joined(separator: ", "))")
        lines.append("- Runs: \(runs.count)")
        lines.append("- Verdict: \(verdictLabel())")
        lines.append(
            "- No-regression threshold: \(noRegression.observedRegressions)/"
                + "\(noRegression.allowedRegressions) "
                + "\(noRegression.passed ? "within threshold" : "breached")"
        )
        if let releaseCandidate {
            lines.append("")
            lines.append("## Release Candidate Summary")
            lines.append("")
            lines.append("- Artifact ID: `\(releaseCandidate.artifactId)`")
            lines.append("- Generated: \(releaseCandidate.generatedAt)")
            lines.append("- Channel: \(releaseCandidate.channel ?? "unknown")")
            lines.append("- Branch: `\(releaseCandidate.branch)`")
            lines.append("- Commit: `\(releaseCandidate.commit)`")
            lines.append("- Artifact: `\(releaseCandidate.artifactPath)`")
            if let baselinePath = releaseCandidate.baselinePath {
                lines.append("- Baseline: `\(baselinePath)`")
            } else {
                lines.append("- Baseline: not run")
            }
            lines.append("- Verdict: \(releaseCandidate.verdict)")
            lines.append(
                "- No-regression threshold: \(releaseCandidate.noRegressionObserved)/"
                    + "\(releaseCandidate.noRegressionAllowed) "
                    + "\(releaseCandidate.noRegressionPassed ? "within threshold" : "breached")"
            )
            lines.append("- Local preset: \(presetLine(releaseCandidate.local))")
            lines.append("- Frontier preset: \(presetLine(releaseCandidate.frontier))")
        }
        lines.append("")
        lines.append("## Model Scoreboard")
        lines.append("")
        lines.append("| Role | Model | Runs | Total | Passed | Failed | Errored | Skipped | Pass Rate | Blocking Regressions | New Failures |")
        lines.append("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        for model in models {
            lines.append(
                "| \(model.role.rawValue) | \(markdownCell(model.modelId)) | "
                    + "\(model.runs) | \(model.counts.total) | \(model.counts.passed) | "
                    + "\(model.counts.failed) | \(model.counts.errored) | \(model.counts.skipped) | "
                    + "\(formatRate(model.passRate)) | \(model.blockingRegressions) | \(model.newFailures) |"
            )
        }
        lines.append("")
        lines.append("## Suite Scoreboard")
        lines.append("")
        lines.append("| Role | Model | Suite | Runs | Total | Passed | Failed | Errored | Skipped | Pass Rate | Blocking Regressions |")
        lines.append("| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        for suite in suites {
            lines.append(
                "| \(suite.role.rawValue) | \(markdownCell(suite.modelId)) | \(markdownCell(suite.suite)) | "
                    + "\(suite.runs) | \(suite.counts.total) | \(suite.counts.passed) | "
                    + "\(suite.counts.failed) | \(suite.counts.errored) | \(suite.counts.skipped) | "
                    + "\(formatRate(suite.passRate)) | \(suite.blockingRegressions) |"
            )
        }
        lines.append("")
        lines.append("## Baseline Comparisons")
        lines.append("")
        lines.append("- Bundles with baseline: \(comparison.bundlesWithBaseline)")
        lines.append("- Blocking regressions: \(comparison.blockingRegressions)")
        lines.append("- New failing cases: \(comparison.newFailures)")
        lines.append("- Fixed cases: \(comparison.fixed)")
        lines.append("- Persistent failures: \(comparison.persistentFailures)")
        lines.append("- Changed skips: \(comparison.changedSkips)")
        lines.append("- New cases: \(comparison.newCases)")
        lines.append("- Removed cases: \(comparison.removedCases)")
        if !comparison.warnings.isEmpty {
            lines.append("")
            lines.append("## Warnings")
            lines.append("")
            for warning in comparison.warnings {
                lines.append("- \(markdownCell(warning))")
            }
        }
        lines.append("")
        lines.append("## Runs")
        lines.append("")
        lines.append("| Generated | Channel | Branch | Commit | Artifact ID | Artifact | Verdict | Baseline |")
        lines.append("| --- | --- | --- | --- | --- | --- | --- | --- |")
        for run in runs {
            lines.append(
                "| \(markdownCell(run.generatedAt)) | \(markdownCell(run.channel ?? "unknown")) | "
                    + "\(markdownCell(run.branch)) | `\(run.commit)` | "
                    + "`\(run.artifactId)` | `\(run.artifactPath)` | \(run.verdict) | "
                    + "\(run.baselinePath.map { "`\($0)`" } ?? "none") |"
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func verdictLabel() -> String {
        if hasBlockingRegressions { return "REGRESSED" }
        if hasRunFailures { return "EVAL FAILURES PRESENT" }
        return "PASS"
    }

    private func formatRate(_ rate: Double?) -> String {
        guard let rate else { return "n/a" }
        return String(format: "%.1f%%", rate * 100)
    }

    private func presetLine(_ scores: [EvalScoreboardReleaseModelScore]) -> String {
        guard !scores.isEmpty else { return "not run" }
        return scores.map { score in
            "\(score.modelId) \(score.counts.passed)/\(score.counts.total) (\(formatRate(score.passRate)))"
        }
        .joined(separator: ", ")
    }

    private func markdownCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
    }
}

public struct EvalScoreboardRunSummary: Sendable, Codable, Equatable {
    public let generatedAt: String
    public let channel: String?
    public let branch: String
    public let commit: String
    public let artifactId: String
    public let artifactPath: String
    public let summaryPath: String
    public let baselinePath: String?
    public let verdict: String
    public let counts: EvalReviewOutcomeCounts
    public let localModels: [String]
    public let frontierModels: [String]

    public init(
        bundle: EvalReviewReportBundle,
        summaryPath: String,
        allowedRegressions: Int = 0
    ) {
        generatedAt = bundle.manifest.generatedAt
        channel = EvalScoreboardRunSummary.channel(fromArtifactPath: bundle.manifest.artifactPath)
        branch = bundle.manifest.branch
        commit = bundle.manifest.commit
        artifactId = bundle.manifest.artifactId
            ?? EvalScoreboardRunSummary.derivedArtifactId(
                generatedAt: bundle.manifest.generatedAt,
                commit: bundle.manifest.commit,
                channel: channel
            )
        artifactPath = bundle.manifest.artifactPath
        self.summaryPath = summaryPath
        baselinePath = bundle.manifest.baselinePath
        let observedRegressions = (bundle.comparison?.regressions.count ?? 0)
            + (bundle.comparison?.newFailures.count ?? 0)
        if observedRegressions > allowedRegressions {
            verdict = "REGRESSED"
        } else if bundle.hasRunFailures {
            verdict = "EVAL FAILURES PRESENT"
        } else {
            verdict = "PASS"
        }
        counts = bundle.models.reduce(.zero) { $0.adding($1.counts) }
        localModels = bundle.models
            .filter { $0.role == .local }
            .map(\.modelId)
            .sorted()
        frontierModels = bundle.models
            .filter { $0.role == .frontier }
            .map(\.modelId)
            .sorted()
    }

    private static func channel(fromArtifactPath path: String) -> String? {
        let components = URL(fileURLWithPath: path).pathComponents
        guard let watcherIndex = components.firstIndex(of: "watcher"),
              components.indices.contains(watcherIndex + 1)
        else {
            return nil
        }
        return components[watcherIndex + 1]
    }

    private static func derivedArtifactId(
        generatedAt: String,
        commit: String,
        channel: String?
    ) -> String {
        let stamp = generatedAt
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "+0000", with: "Z")
        let prefix = String(commit.prefix(12))
        return [channel ?? "eval", stamp, prefix]
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}

public struct EvalReleaseCandidateScoreSummary: Sendable, Codable, Equatable {
    public let artifactId: String
    public let generatedAt: String
    public let channel: String?
    public let branch: String
    public let commit: String
    public let artifactPath: String
    public let baselinePath: String?
    public let verdict: String
    public let noRegressionAllowed: Int
    public let noRegressionObserved: Int
    public let noRegressionPassed: Bool
    public let local: [EvalScoreboardReleaseModelScore]
    public let frontier: [EvalScoreboardReleaseModelScore]
}

public struct EvalScoreboardReleaseModelScore: Sendable, Codable, Equatable {
    public let role: EvalReviewModelRole
    public let modelId: String
    public let counts: EvalReviewOutcomeCounts
    public let passRate: Double?
}

public struct EvalScoreboardNoRegressionSummary: Sendable, Codable, Equatable {
    public let allowedRegressions: Int
    public let observedRegressions: Int
    public let blockingRegressions: Int
    public let newFailures: Int
    public let passed: Bool
}

public struct EvalScoreboardModelSummary: Sendable, Codable, Equatable {
    public let role: EvalReviewModelRole
    public let modelId: String
    public let runs: Int
    public let counts: EvalReviewOutcomeCounts
    public let passRate: Double?
    public let blockingRegressions: Int
    public let newFailures: Int
    public let fixed: Int
    public let persistentFailures: Int
}

public struct EvalScoreboardSuiteSummary: Sendable, Codable, Equatable {
    public let role: EvalReviewModelRole
    public let modelId: String
    public let suite: String
    public let runs: Int
    public let counts: EvalReviewOutcomeCounts
    public let passRate: Double?
    public let blockingRegressions: Int
    public let newFailures: Int
    public let fixed: Int
    public let persistentFailures: Int
}

public struct EvalScoreboardComparisonSummary: Sendable, Codable, Equatable {
    public let bundlesWithBaseline: Int
    public let blockingRegressions: Int
    public let newFailures: Int
    public let fixed: Int
    public let persistentFailures: Int
    public let changedSkips: Int
    public let newCases: Int
    public let removedCases: Int
    public let warnings: [String]

    public static let zero = EvalScoreboardComparisonSummary(
        bundlesWithBaseline: 0,
        blockingRegressions: 0,
        newFailures: 0,
        fixed: 0,
        persistentFailures: 0,
        changedSkips: 0,
        newCases: 0,
        removedCases: 0,
        warnings: []
    )
}

public enum EvalScoreboardBuilder {
    public static func build(
        generatedAt: String? = nil,
        sourceRoots: [URL],
        bundles: [EvalScoreboardInput],
        allowedRegressions: Int = 0
    ) -> EvalScoreboardBundle {
        let sortedInputs = bundles.sorted {
            if $0.bundle.manifest.generatedAt == $1.bundle.manifest.generatedAt {
                return $0.summaryPath < $1.summaryPath
            }
            return $0.bundle.manifest.generatedAt < $1.bundle.manifest.generatedAt
        }
        let runs = sortedInputs.map {
            EvalScoreboardRunSummary(
                bundle: $0.bundle,
                summaryPath: $0.summaryPath,
                allowedRegressions: allowedRegressions
            )
        }
        let modelSummaries = modelScoreboard(from: sortedInputs)
        let suiteSummaries = suiteScoreboard(from: sortedInputs)
        let comparison = comparisonScoreboard(from: sortedInputs)
        let latestNoRegression = noRegressionCounts(for: sortedInputs.last)
        let noRegression = EvalScoreboardNoRegressionSummary(
            allowedRegressions: allowedRegressions,
            observedRegressions: latestNoRegression.blockingRegressions + latestNoRegression.newFailures,
            blockingRegressions: latestNoRegression.blockingRegressions,
            newFailures: latestNoRegression.newFailures,
            passed: latestNoRegression.blockingRegressions + latestNoRegression.newFailures <= allowedRegressions
        )

        return EvalScoreboardBundle(
            generatedAt: generatedAt ?? isoNowForEvalScoreboard(),
            sourceRoots: sourceRoots.map(\.path).sorted(),
            releaseCandidate: releaseCandidateSummary(
                from: sortedInputs.last,
                run: runs.last,
                allowedRegressions: allowedRegressions
            ),
            noRegression: noRegression,
            runs: runs,
            models: modelSummaries,
            suites: suiteSummaries,
            comparison: comparison
        )
    }

    public static func loadBundlesRecursively(from roots: [URL]) throws -> [EvalScoreboardInput] {
        let fm = FileManager.default
        let decoder = JSONDecoder()
        var inputs: [EvalScoreboardInput] = []
        for root in roots {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
                throw EvalScoreboardError.pathNotFound(root.path)
            }
            let urls: [URL]
            if isDirectory.boolValue {
                guard let enumerator = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    throw EvalScoreboardError.noBundles(root.path)
                }
                urls = enumerator.compactMap { item in
                    guard let url = item as? URL, url.lastPathComponent == "summary.json" else {
                        return nil
                    }
                    return url
                }
                .sorted { $0.path < $1.path }
            } else {
                urls = [root]
            }

            for url in urls {
                let data: Data
                do {
                    data = try Data(contentsOf: url)
                } catch {
                    throw EvalScoreboardError.invalidBundle(url.path, error.localizedDescription)
                }
                let bundle: EvalReviewReportBundle
                do {
                    bundle = try decoder.decode(EvalReviewReportBundle.self, from: data)
                } catch {
                    throw EvalScoreboardError.invalidBundle(url.path, error.localizedDescription)
                }
                inputs.append(EvalScoreboardInput(summaryPath: url.path, bundle: bundle))
            }
        }
        guard !inputs.isEmpty else {
            throw EvalScoreboardError.noBundles(roots.map(\.path).joined(separator: ", "))
        }
        return inputs
    }

    private static func modelScoreboard(
        from inputs: [EvalScoreboardInput]
    ) -> [EvalScoreboardModelSummary] {
        struct Accumulator {
            var runs = 0
            var counts = EvalReviewOutcomeCounts.zero
            var blockingRegressions = 0
            var newFailures = 0
            var fixed = 0
            var persistentFailures = 0
        }
        var rows: [ModelKey: Accumulator] = [:]
        for input in inputs {
            for model in input.bundle.models {
                let key = ModelKey(role: model.role, modelId: model.modelId)
                var row = rows[key, default: Accumulator()]
                row.runs += 1
                row.counts = row.counts.adding(model.counts)
                rows[key] = row
            }
            guard let comparison = input.bundle.comparison else { continue }
            for delta in comparison.regressions {
                rows[ModelKey(role: role(for: delta.modelId, in: input.bundle), modelId: delta.modelId), default: Accumulator()]
                    .blockingRegressions += 1
            }
            for delta in comparison.newFailures {
                rows[ModelKey(role: role(for: delta.modelId, in: input.bundle), modelId: delta.modelId), default: Accumulator()]
                    .newFailures += 1
            }
            for delta in comparison.fixed {
                rows[ModelKey(role: role(for: delta.modelId, in: input.bundle), modelId: delta.modelId), default: Accumulator()]
                    .fixed += 1
            }
            for delta in comparison.persistentFailures {
                rows[ModelKey(role: role(for: delta.modelId, in: input.bundle), modelId: delta.modelId), default: Accumulator()]
                    .persistentFailures += 1
            }
        }
        return rows.map { key, row in
            EvalScoreboardModelSummary(
                role: key.role,
                modelId: key.modelId,
                runs: row.runs,
                counts: row.counts,
                passRate: passRate(row.counts),
                blockingRegressions: row.blockingRegressions,
                newFailures: row.newFailures,
                fixed: row.fixed,
                persistentFailures: row.persistentFailures
            )
        }
        .sorted {
            if $0.role == $1.role { return $0.modelId < $1.modelId }
            return $0.role < $1.role
        }
    }

    private static func suiteScoreboard(
        from inputs: [EvalScoreboardInput]
    ) -> [EvalScoreboardSuiteSummary] {
        struct Accumulator {
            var runs = 0
            var counts = EvalReviewOutcomeCounts.zero
            var blockingRegressions = 0
            var newFailures = 0
            var fixed = 0
            var persistentFailures = 0
        }
        var rows: [SuiteKey: Accumulator] = [:]
        for input in inputs {
            for model in input.bundle.models {
                for suite in model.suites {
                    let key = SuiteKey(role: model.role, modelId: model.modelId, suite: suite.suite)
                    var row = rows[key, default: Accumulator()]
                    row.runs += 1
                    row.counts = row.counts.adding(suite.counts)
                    rows[key] = row
                }
            }
            guard let comparison = input.bundle.comparison else { continue }
            for delta in comparison.regressions {
                rows[suiteKey(for: delta, in: input.bundle), default: Accumulator()]
                    .blockingRegressions += 1
            }
            for delta in comparison.newFailures {
                rows[suiteKey(for: delta, in: input.bundle), default: Accumulator()]
                    .newFailures += 1
            }
            for delta in comparison.fixed {
                rows[suiteKey(for: delta, in: input.bundle), default: Accumulator()]
                    .fixed += 1
            }
            for delta in comparison.persistentFailures {
                rows[suiteKey(for: delta, in: input.bundle), default: Accumulator()]
                    .persistentFailures += 1
            }
        }
        return rows.map { key, row in
            EvalScoreboardSuiteSummary(
                role: key.role,
                modelId: key.modelId,
                suite: key.suite,
                runs: row.runs,
                counts: row.counts,
                passRate: passRate(row.counts),
                blockingRegressions: row.blockingRegressions,
                newFailures: row.newFailures,
                fixed: row.fixed,
                persistentFailures: row.persistentFailures
            )
        }
        .sorted {
            if $0.role != $1.role { return $0.role < $1.role }
            if $0.modelId != $1.modelId { return $0.modelId < $1.modelId }
            return $0.suite < $1.suite
        }
    }

    private static func comparisonScoreboard(
        from inputs: [EvalScoreboardInput]
    ) -> EvalScoreboardComparisonSummary {
        var bundlesWithBaseline = 0
        var blockingRegressions = 0
        var newFailures = 0
        var fixed = 0
        var persistentFailures = 0
        var changedSkips = 0
        var newCases = 0
        var removedCases = 0
        var warnings: [String] = []
        for input in inputs {
            guard let comparison = input.bundle.comparison else { continue }
            bundlesWithBaseline += 1
            blockingRegressions += comparison.regressions.count
            newFailures += comparison.newFailures.count
            fixed += comparison.fixed.count
            persistentFailures += comparison.persistentFailures.count
            changedSkips += comparison.changedSkips.count
            newCases += comparison.newCases.count
            removedCases += comparison.removedCases.count
            warnings.append(contentsOf: comparison.warnings)
        }
        return EvalScoreboardComparisonSummary(
            bundlesWithBaseline: bundlesWithBaseline,
            blockingRegressions: blockingRegressions,
            newFailures: newFailures,
            fixed: fixed,
            persistentFailures: persistentFailures,
            changedSkips: changedSkips,
            newCases: newCases,
            removedCases: removedCases,
            warnings: Array(Set(warnings)).sorted()
        )
    }

    private static func releaseCandidateSummary(
        from input: EvalScoreboardInput?,
        run: EvalScoreboardRunSummary?,
        allowedRegressions: Int
    ) -> EvalReleaseCandidateScoreSummary? {
        guard let input, let run else { return nil }
        let observedRegressions = (input.bundle.comparison?.regressions.count ?? 0)
            + (input.bundle.comparison?.newFailures.count ?? 0)
        let scores = input.bundle.models.map { model in
            EvalScoreboardReleaseModelScore(
                role: model.role,
                modelId: model.modelId,
                counts: model.counts,
                passRate: passRate(model.counts)
            )
        }
        return EvalReleaseCandidateScoreSummary(
            artifactId: run.artifactId,
            generatedAt: run.generatedAt,
            channel: run.channel,
            branch: run.branch,
            commit: run.commit,
            artifactPath: run.artifactPath,
            baselinePath: run.baselinePath,
            verdict: run.verdict,
            noRegressionAllowed: allowedRegressions,
            noRegressionObserved: observedRegressions,
            noRegressionPassed: observedRegressions <= allowedRegressions,
            local: scores.filter { $0.role == .local }.sorted { $0.modelId < $1.modelId },
            frontier: scores.filter { $0.role == .frontier }.sorted { $0.modelId < $1.modelId }
        )
    }

    private static func noRegressionCounts(
        for input: EvalScoreboardInput?
    ) -> (blockingRegressions: Int, newFailures: Int) {
        guard let comparison = input?.bundle.comparison else {
            return (0, 0)
        }
        return (comparison.regressions.count, comparison.newFailures.count)
    }

    private static func passRate(_ counts: EvalReviewOutcomeCounts) -> Double? {
        guard counts.total > 0 else { return nil }
        return Double(counts.passed) / Double(counts.total)
    }

    private static func role(for modelId: String, in bundle: EvalReviewReportBundle) -> EvalReviewModelRole {
        bundle.models.first { $0.modelId == modelId }?.role ?? .local
    }

    private static func suiteKey(
        for delta: EvalReviewCaseDelta,
        in bundle: EvalReviewReportBundle
    ) -> SuiteKey {
        SuiteKey(
            role: role(for: delta.modelId, in: bundle),
            modelId: delta.modelId,
            suite: delta.suite
        )
    }
}

public struct EvalScoreboardInput: Sendable, Equatable {
    public let summaryPath: String
    public let bundle: EvalReviewReportBundle

    public init(summaryPath: String, bundle: EvalReviewReportBundle) {
        self.summaryPath = summaryPath
        self.bundle = bundle
    }
}

public enum EvalScoreboardError: Error, LocalizedError, Equatable {
    case pathNotFound(String)
    case noBundles(String)
    case invalidBundle(String, String)

    public var errorDescription: String? {
        switch self {
        case .pathNotFound(let path):
            return "path does not exist: \(path)"
        case .noBundles(let path):
            return "no eval review summary.json bundles found at: \(path)"
        case .invalidBundle(let path, let reason):
            return "invalid eval review summary.json at \(path): \(reason)"
        }
    }
}

private struct ModelKey: Hashable {
    let role: EvalReviewModelRole
    let modelId: String
}

private struct SuiteKey: Hashable {
    let role: EvalReviewModelRole
    let modelId: String
    let suite: String
}

private func isoNowForEvalScoreboard() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}
