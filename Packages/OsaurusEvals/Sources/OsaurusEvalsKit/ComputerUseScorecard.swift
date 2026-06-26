//
//  ComputerUseScorecard.swift
//  OsaurusEvalsKit
//
//  Offline aggregation for Computer Use eval reports. This consumes the
//  JSON artifacts already emitted by `osaurus-evals run --out`; it never
//  calls a model or changes runtime behavior.
//

import Foundation

public struct ComputerUseScorecardReportSource: Sendable, Codable, Equatable {
    public let path: String
    public let modelId: String
    public let startedAt: String
    public let computerUseCases: Int

    public init(path: String, modelId: String, startedAt: String, computerUseCases: Int) {
        self.path = path
        self.modelId = modelId
        self.startedAt = startedAt
        self.computerUseCases = computerUseCases
    }
}

public struct ComputerUseScorecardEvidenceRef: Sendable, Codable, Equatable {
    public let caseId: String
    public let domain: String
    public let outcome: EvalCaseOutcome
    public let reportPath: String

    public init(caseId: String, domain: String, outcome: EvalCaseOutcome, reportPath: String) {
        self.caseId = caseId
        self.domain = domain
        self.outcome = outcome
        self.reportPath = reportPath
    }
}

public struct ComputerUseScorecardCounter: Sendable, Codable, Equatable {
    public let total: Int
    public let passed: Int
    public let failed: Int
    public let skipped: Int
    public let errored: Int

    public init(rows: [EvalCaseReport]) {
        total = rows.count
        passed = rows.filter { $0.outcome == .passed }.count
        failed = rows.filter { $0.outcome == .failed }.count
        skipped = rows.filter { $0.outcome == .skipped }.count
        errored = rows.filter { $0.outcome == .errored }.count
    }
}

public struct ComputerUseScorecardGateSummary: Sendable, Codable, Equatable {
    public let effects: [String: Int]
    public let dispositions: [String: Int]
    public let allowlistAllowed: Int
    public let allowlistBlocked: Int
    public let allowlistUnreported: Int

    public init(
        effects: [String: Int],
        dispositions: [String: Int],
        allowlistAllowed: Int,
        allowlistBlocked: Int,
        allowlistUnreported: Int
    ) {
        self.effects = effects
        self.dispositions = dispositions
        self.allowlistAllowed = allowlistAllowed
        self.allowlistBlocked = allowlistBlocked
        self.allowlistUnreported = allowlistUnreported
    }
}

public struct ComputerUseScorecardConfirmSummary: Sendable, Codable, Equatable {
    public let confirmedGateCases: Int
    public let autonomousGateCases: Int
    public let deniedGateCases: Int
    public let loopCasesRequestingConfirmation: Int
    public let loopConfirmationRequests: Int
    public let loopAutonomousActions: Int

    public init(
        confirmedGateCases: Int,
        autonomousGateCases: Int,
        deniedGateCases: Int,
        loopCasesRequestingConfirmation: Int,
        loopConfirmationRequests: Int,
        loopAutonomousActions: Int
    ) {
        self.confirmedGateCases = confirmedGateCases
        self.autonomousGateCases = autonomousGateCases
        self.deniedGateCases = deniedGateCases
        self.loopCasesRequestingConfirmation = loopCasesRequestingConfirmation
        self.loopConfirmationRequests = loopConfirmationRequests
        self.loopAutonomousActions = loopAutonomousActions
    }
}

public struct ComputerUseScorecardVerifySummary: Sendable, Codable, Equatable {
    public let actedCases: Int
    public let changedAfterActCases: Int
    public let passedAfterActCases: Int
    public let passRate: Double?
    public let changeRate: Double?

    public init(
        actedCases: Int,
        changedAfterActCases: Int,
        passedAfterActCases: Int,
        passRate: Double?,
        changeRate: Double?
    ) {
        self.actedCases = actedCases
        self.changedAfterActCases = changedAfterActCases
        self.passedAfterActCases = passedAfterActCases
        self.passRate = passRate
        self.changeRate = changeRate
    }
}

public struct ComputerUseScorecardStallSummary: Sendable, Codable, Equatable {
    public let unresolvedCases: Int
    public let deadEndCases: Int
    public let blockedEvents: Int
    public let invalidActionEvents: Int

    public init(
        unresolvedCases: Int,
        deadEndCases: Int,
        blockedEvents: Int,
        invalidActionEvents: Int
    ) {
        self.unresolvedCases = unresolvedCases
        self.deadEndCases = deadEndCases
        self.blockedEvents = blockedEvents
        self.invalidActionEvents = invalidActionEvents
    }
}

public struct ComputerUseScorecard: Sendable, Codable, Equatable {
    public let generatedAt: String
    public let sources: [ComputerUseScorecardReportSource]
    public let totals: ComputerUseScorecardCounter
    public let byDomain: [String: ComputerUseScorecardCounter]
    public let safetyGate: ComputerUseScorecardGateSummary
    public let confirmAutonomy: ComputerUseScorecardConfirmSummary
    public let verify: ComputerUseScorecardVerifySummary
    public let stalls: ComputerUseScorecardStallSummary
    public let evidence: [ComputerUseScorecardEvidenceRef]

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
        lines.append("# Computer Use Regression Scorecard")
        lines.append("")
        lines.append("- Generated: \(generatedAt)")
        lines.append("- Sources: \(sources.count)")
        lines.append(
            "- Privacy: case IDs and report paths only; raw prompts, notes, screen text, and field contents are omitted."
        )
        lines.append("")
        lines.append("## Totals")
        lines.append("")
        lines.append("| Scope | Total | Passed | Failed | Skipped | Errored |")
        lines.append("| --- | ---: | ---: | ---: | ---: | ---: |")
        lines.append(counterRow("all Computer Use", totals))
        for domain in byDomain.keys.sorted() {
            if let counter = byDomain[domain] {
                lines.append(counterRow(domain, counter))
            }
        }
        lines.append("")
        lines.append("## Safety Gate")
        lines.append("")
        lines.append("- Effects: \(formatMap(safetyGate.effects))")
        lines.append("- Dispositions: \(formatMap(safetyGate.dispositions))")
        lines.append(
            "- Allowlist: allowed \(safetyGate.allowlistAllowed), blocked \(safetyGate.allowlistBlocked), unreported \(safetyGate.allowlistUnreported)"
        )
        lines.append("")
        lines.append("## Confirm And Autonomy")
        lines.append("")
        lines.append(
            "- Gate cases: confirm \(confirmAutonomy.confirmedGateCases), allow \(confirmAutonomy.autonomousGateCases), deny \(confirmAutonomy.deniedGateCases)"
        )
        lines.append(
            "- Loop confirmations: \(confirmAutonomy.loopConfirmationRequests) request(s) across \(confirmAutonomy.loopCasesRequestingConfirmation) case(s)"
        )
        lines.append("- Loop autonomous actions: \(confirmAutonomy.loopAutonomousActions)")
        lines.append("")
        lines.append("## Verify")
        lines.append("")
        lines.append("- Acted loop cases: \(verify.actedCases)")
        lines.append("- Passed after act: \(verify.passedAfterActCases)\(formatRate(verify.passRate))")
        lines.append("- Changed after act: \(verify.changedAfterActCases)\(formatRate(verify.changeRate))")
        lines.append("")
        lines.append("## Unresolved And Dead Ends")
        lines.append("")
        lines.append("- Unresolved target cases: \(stalls.unresolvedCases)")
        lines.append("- Dead-end cases: \(stalls.deadEndCases)")
        lines.append("- Blocked events: \(stalls.blockedEvents)")
        lines.append("- Invalid action events: \(stalls.invalidActionEvents)")
        lines.append("")
        lines.append("## Evidence")
        lines.append("")
        lines.append("| Case | Domain | Outcome | Report |")
        lines.append("| --- | --- | --- | --- |")
        for ref in evidence {
            lines.append(
                "| `\(escapeMarkdown(ref.caseId))` | `\(escapeMarkdown(ref.domain))` | \(ref.outcome.rawValue) | `\(escapeMarkdown(ref.reportPath))` |"
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func counterRow(_ label: String, _ counter: ComputerUseScorecardCounter) -> String {
        "| \(label) | \(counter.total) | \(counter.passed) | \(counter.failed) | \(counter.skipped) | \(counter.errored) |"
    }

    private func formatMap(_ map: [String: Int]) -> String {
        if map.isEmpty { return "none reported" }
        return map.keys.sorted().map { "\($0) \(map[$0] ?? 0)" }.joined(separator: ", ")
    }

    private func formatRate(_ rate: Double?) -> String {
        guard let rate else { return "" }
        return String(format: " (%.1f%%)", rate * 100)
    }

    private func escapeMarkdown(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
    }
}

public enum ComputerUseScorecardBuilder {
    public struct InputReport: Sendable {
        public let report: EvalReport
        public let path: String

        public init(report: EvalReport, path: String) {
            self.report = report
            self.path = path
        }
    }

    private struct ReportCandidate {
        let url: URL
        let required: Bool
    }

    public static let computerUseDomains: Set<String> = ["computer_use", "computer_use_loop"]

    public static func loadReports(from paths: [URL]) throws -> [InputReport] {
        let files = try reportFiles(from: paths)
        let decoder = JSONDecoder()
        var reports: [InputReport] = []
        for candidate in files {
            let data: Data
            do {
                data = try Data(contentsOf: candidate.url)
            } catch {
                throw ComputerUseScorecardError.unreadableReport(
                    candidate.url.path,
                    error.localizedDescription
                )
            }
            do {
                let report = try decoder.decode(EvalReport.self, from: data)
                reports.append(InputReport(report: report, path: privacySafePath(candidate.url)))
            } catch {
                if candidate.required {
                    throw ComputerUseScorecardError.malformedReport(
                        candidate.url.path,
                        error.localizedDescription
                    )
                }
                continue
            }
        }
        if reports.isEmpty {
            let joined = paths.map(\.path).joined(separator: ", ")
            throw ComputerUseScorecardError.noReports(joined)
        }
        return reports
    }

    public static func build(
        from inputReports: [InputReport],
        generatedAt: String? = nil
    ) -> ComputerUseScorecard {
        var sourceSummaries: [ComputerUseScorecardReportSource] = []
        var rowsWithPath: [(EvalCaseReport, String)] = []
        for input in inputReports {
            let cuRows = input.report.cases.filter { computerUseDomains.contains($0.domain) }
            if cuRows.isEmpty { continue }
            sourceSummaries.append(
                ComputerUseScorecardReportSource(
                    path: input.path,
                    modelId: input.report.modelId,
                    startedAt: input.report.startedAt,
                    computerUseCases: cuRows.count
                )
            )
            rowsWithPath.append(contentsOf: cuRows.map { ($0, input.path) })
        }

        let rows = rowsWithPath.map(\.0)
        let byDomain = Dictionary(
            uniqueKeysWithValues: computerUseDomains.sorted().compactMap { domain in
                let domainRows = rows.filter { $0.domain == domain }
                return domainRows.isEmpty ? nil : (domain, ComputerUseScorecardCounter(rows: domainRows))
            }
        )
        let gateFacts = rows.filter { $0.domain == "computer_use" }.map(GateFacts.init(row:))
        let loopFacts = rows.filter { $0.domain == "computer_use_loop" }.map(LoopFacts.init(row:))

        var effects: [String: Int] = [:]
        var dispositions: [String: Int] = [:]
        var allowlistAllowed = 0
        var allowlistBlocked = 0
        var allowlistUnreported = 0
        for fact in gateFacts {
            if let effect = fact.effect { effects[effect, default: 0] += 1 }
            if let disposition = fact.disposition { dispositions[disposition, default: 0] += 1 }
            switch fact.allowlist {
            case .allowed: allowlistAllowed += 1
            case .blocked: allowlistBlocked += 1
            case .unreported: allowlistUnreported += 1
            }
        }

        let actedLoopFacts = loopFacts.filter { ($0.acted ?? 0) > 0 }
        let changedAfterAct = actedLoopFacts.filter { ($0.verifyChanged ?? 0) > 0 }.count
        let passedAfterAct = actedLoopFacts.filter { $0.outcome == .passed }.count
        let loopConfirmRequests = loopFacts.compactMap(\.confirms).reduce(0, +)
        let loopActed = loopFacts.compactMap(\.acted).reduce(0, +)
        // The loop reports total acted driver calls and confirmation requests,
        // not a per-action autonomy flag, so this is a conservative estimate.
        let loopAutonomousActions = max(0, loopActed - loopConfirmRequests)
        let blockedEvents = loopFacts.compactMap(\.blocked).reduce(0, +)
        let invalidActions = loopFacts.compactMap(\.invalidActions).reduce(0, +)
        let unresolvedCases = loopFacts.filter { fact in
            guard let attempts = fact.targetResolveAttempts, attempts > 0 else { return false }
            return (fact.targetResolveSuccesses ?? 0) < attempts
        }.count

        return ComputerUseScorecard(
            generatedAt: generatedAt ?? isoNow(),
            sources: sourceSummaries.sorted { $0.path < $1.path },
            totals: ComputerUseScorecardCounter(rows: rows),
            byDomain: byDomain,
            safetyGate: ComputerUseScorecardGateSummary(
                effects: effects,
                dispositions: dispositions,
                allowlistAllowed: allowlistAllowed,
                allowlistBlocked: allowlistBlocked,
                allowlistUnreported: allowlistUnreported
            ),
            confirmAutonomy: ComputerUseScorecardConfirmSummary(
                confirmedGateCases: gateFacts.filter { $0.disposition == "confirm" }.count,
                autonomousGateCases: gateFacts.filter { $0.disposition == "allow" }.count,
                deniedGateCases: gateFacts.filter { $0.disposition == "deny" }.count,
                loopCasesRequestingConfirmation: loopFacts.filter { ($0.confirms ?? 0) > 0 }.count,
                loopConfirmationRequests: loopConfirmRequests,
                loopAutonomousActions: loopAutonomousActions
            ),
            verify: ComputerUseScorecardVerifySummary(
                actedCases: actedLoopFacts.count,
                changedAfterActCases: changedAfterAct,
                passedAfterActCases: passedAfterAct,
                passRate: actedLoopFacts.isEmpty ? nil : Double(passedAfterAct) / Double(actedLoopFacts.count),
                changeRate: actedLoopFacts.isEmpty ? nil : Double(changedAfterAct) / Double(actedLoopFacts.count)
            ),
            stalls: ComputerUseScorecardStallSummary(
                unresolvedCases: unresolvedCases,
                deadEndCases: loopFacts.filter(\.deadEnded).count,
                blockedEvents: blockedEvents,
                invalidActionEvents: invalidActions
            ),
            evidence: rowsWithPath.map {
                ComputerUseScorecardEvidenceRef(
                    caseId: $0.0.id,
                    domain: $0.0.domain,
                    outcome: $0.0.outcome,
                    reportPath: $0.1
                )
            }.sorted { lhs, rhs in
                if lhs.reportPath != rhs.reportPath { return lhs.reportPath < rhs.reportPath }
                return lhs.caseId < rhs.caseId
            }
        )
    }

    private static func reportFiles(from paths: [URL]) throws -> [ReportCandidate] {
        guard !paths.isEmpty else { throw ComputerUseScorecardError.noInputPaths }
        let fm = FileManager.default
        var result: [ReportCandidate] = []
        for path in paths {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path.path, isDirectory: &isDir) else {
                throw ComputerUseScorecardError.pathNotFound(path.path)
            }
            if isDir.boolValue {
                let enumerator = fm.enumerator(at: path, includingPropertiesForKeys: nil)
                let files = (enumerator?.allObjects as? [URL] ?? [])
                    .filter { $0.pathExtension.lowercased() == "json" }
                    .sorted { $0.path < $1.path }
                result.append(contentsOf: files.map { ReportCandidate(url: $0, required: false) })
            } else {
                result.append(ReportCandidate(url: path, required: true))
            }
        }
        return result
    }

    private static func privacySafePath(_ url: URL) -> String {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .standardizedFileURL
        let standardized = url.standardizedFileURL
        let cwdPath = cwd.path.hasSuffix("/") ? cwd.path : cwd.path + "/"
        if standardized.path.hasPrefix(cwdPath) {
            return String(standardized.path.dropFirst(cwdPath.count))
        }
        return standardized.lastPathComponent
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}

public enum ComputerUseScorecardError: Error, LocalizedError, Equatable {
    case noInputPaths
    case pathNotFound(String)
    case unreadableReport(String, String)
    case malformedReport(String, String)
    case noReports(String)

    public var errorDescription: String? {
        switch self {
        case .noInputPaths:
            return "at least one report path is required"
        case .pathNotFound(let path):
            return "report path does not exist: \(path)"
        case .unreadableReport(let path, let detail):
            return "could not read report at \(path): \(detail)"
        case .malformedReport(let path, let detail):
            return "malformed EvalReport JSON at \(path): \(detail)"
        case .noReports(let path):
            return "no report JSON files found under: \(path)"
        }
    }
}

private struct GateFacts {
    enum Allowlist {
        case allowed
        case blocked
        case unreported
    }

    let effect: String?
    let disposition: String?
    let allowlist: Allowlist

    init(row: EvalCaseReport) {
        let joined = row.notes.joined(separator: "\n")
        effect = Self.firstMatch(
            in: joined,
            patterns: [
                #"effect ok: ([A-Za-z_]+)"#,
                #"effect mismatch: expected [A-Za-z_]+, got ([A-Za-z_]+)"#,
                #"recorded: effect=([A-Za-z_]+)"#,
            ]
        )
        disposition = Self.firstMatch(
            in: joined,
            patterns: [
                #"disposition ok: ([A-Za-z_]+)"#,
                #"disposition mismatch: expected [A-Za-z_]+, got ([A-Za-z_]+)"#,
                #"disposition=([A-Za-z_]+)"#,
            ]
        )
        if let raw = Self.firstMatch(
            in: joined,
            patterns: [
                #"allowlist ok: allowed=(true|false)"#,
                #"allowlist mismatch: expected allowed=(?:true|false), got (true|false)"#,
                #"allowed=(true|false)"#,
            ]
        ) {
            allowlist = raw == "true" ? .allowed : .blocked
        } else {
            allowlist = .unreported
        }
    }

    private static func firstMatch(in string: String, patterns: [String]) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(string.startIndex ..< string.endIndex, in: string)
            guard let match = regex.firstMatch(in: string, range: nsRange),
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: string)
            else { continue }
            return String(string[range])
        }
        return nil
    }
}

private struct LoopFacts {
    let outcome: EvalCaseOutcome
    let acted: Int?
    let verifyChanged: Int?
    let blocked: Int?
    let confirms: Int?
    let invalidActions: Int?
    let targetResolveSuccesses: Int?
    let targetResolveAttempts: Int?
    let deadEnded: Bool

    init(row: EvalCaseReport) {
        outcome = row.outcome
        let joined = row.notes.joined(separator: "\n")
        acted = Self.intValue(named: "acted", in: joined)
        verifyChanged = Self.intValue(named: "verifyChanged", in: joined)
        blocked = Self.intValue(named: "blocked", in: joined)
        confirms = Self.intValue(named: "confirms", in: joined)
        invalidActions = Self.intValue(named: "invalidActions", in: joined)
        if let resolve = Self.resolveRate(in: joined) {
            targetResolveSuccesses = resolve.successes
            targetResolveAttempts = resolve.attempts
        } else {
            targetResolveSuccesses = nil
            targetResolveAttempts = nil
        }
        deadEnded =
            joined.contains("outcome ok: deadEnd")
            || joined.contains("outcome 'deadEnd'")
            || joined.contains("outcomeName=deadEnd")
    }

    private static func intValue(named name: String, in string: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"\b\#(name)=(\d+)"#) else { return nil }
        let nsRange = NSRange(string.startIndex ..< string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, range: nsRange),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: string)
        else { return nil }
        return Int(string[range])
    }

    private static func resolveRate(in string: String) -> (successes: Int, attempts: Int)? {
        guard let regex = try? NSRegularExpression(pattern: #"axResolvableRate: [0-9.]+ \((\d+)/(\d+)\)"#)
        else { return nil }
        let nsRange = NSRange(string.startIndex ..< string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, range: nsRange),
            match.numberOfRanges > 2,
            let successRange = Range(match.range(at: 1), in: string),
            let attemptsRange = Range(match.range(at: 2), in: string),
            let successes = Int(string[successRange]),
            let attempts = Int(string[attemptsRange])
        else { return nil }
        return (successes, attempts)
    }
}
