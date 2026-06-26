import Foundation
import Testing

@testable import OsaurusEvalsKit

struct ComputerUseScorecardTests {
    @Test func fixtureReportAggregatesComputerUseCounts() throws {
        let reports = try ComputerUseScorecardBuilder.loadReports(from: [fixtureReportURL()])
        let scorecard = ComputerUseScorecardBuilder.build(
            from: reports,
            generatedAt: "2026-06-22T12:00:00Z"
        )

        #expect(scorecard.sources.count == 1)
        #expect(scorecard.sources.first?.computerUseCases == 4)
        #expect(scorecard.totals.total == 4)
        #expect(scorecard.totals.passed == 3)
        #expect(scorecard.totals.failed == 1)
        #expect(scorecard.byDomain["computer_use"]?.passed == 2)
        #expect(scorecard.byDomain["computer_use_loop"]?.failed == 1)

        #expect(scorecard.safetyGate.effects == ["edit": 1, "navigate": 1])
        #expect(scorecard.safetyGate.dispositions == ["confirm": 1, "deny": 1])
        #expect(scorecard.safetyGate.allowlistBlocked == 1)
        #expect(scorecard.safetyGate.allowlistUnreported == 1)

        #expect(scorecard.confirmAutonomy.confirmedGateCases == 1)
        #expect(scorecard.confirmAutonomy.deniedGateCases == 1)
        #expect(scorecard.confirmAutonomy.loopCasesRequestingConfirmation == 1)
        #expect(scorecard.confirmAutonomy.loopConfirmationRequests == 1)
        #expect(scorecard.confirmAutonomy.loopAutonomousActions == 1)

        #expect(scorecard.verify.actedCases == 1)
        #expect(scorecard.verify.changedAfterActCases == 1)
        #expect(scorecard.verify.passedAfterActCases == 1)
        #expect(scorecard.verify.passRate == 1)
        #expect(scorecard.verify.changeRate == 1)

        #expect(scorecard.stalls.unresolvedCases == 1)
        #expect(scorecard.stalls.deadEndCases == 1)
        #expect(scorecard.stalls.blockedEvents == 2)
        #expect(scorecard.stalls.invalidActionEvents == 1)
    }

    @Test func markdownIsPrivacySafeAndRendersEvidencePaths() throws {
        let reports = try ComputerUseScorecardBuilder.loadReports(from: [fixtureReportURL()])
        let scorecard = ComputerUseScorecardBuilder.build(
            from: reports,
            generatedAt: "2026-06-22T12:00:00Z"
        )
        let markdown = scorecard.formatMarkdown()

        #expect(markdown.contains("# Computer Use Regression Scorecard"))
        #expect(markdown.contains("| all Computer Use | 4 | 3 | 1 | 0 | 0 |"))
        #expect(markdown.contains("- Effects: edit 1, navigate 1"))
        #expect(markdown.contains("- Loop confirmations: 1 request(s) across 1 case(s)"))
        #expect(markdown.contains("`computer_use_loop.compose-and-send`"))
        #expect(markdown.contains("mixed-report.json"))

        #expect(!markdown.contains("ALPHA-SECRET-42"))
        #expect(!markdown.contains("Running late, sorry"))
        #expect(!markdown.contains("private recipient"))
        #expect(!markdown.contains("final values"))

        let encoded = try scorecard.toJSON(prettyPrinted: true)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains("ALPHA-SECRET-42"))
        #expect(!json.contains("Running late, sorry"))
        #expect(!json.contains("final values"))
    }

    @Test func loaderFailsForMissingRequiredReport() {
        #expect(throws: ComputerUseScorecardError.self) {
            _ = try ComputerUseScorecardBuilder.loadReports(
                from: [URL(fileURLWithPath: "/tmp/osaurus-missing-scorecard-report.json")]
            )
        }
    }

    @Test func loaderFailsForMalformedRequiredReport() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComputerUseScorecardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let malformed = dir.appendingPathComponent("malformed.json")
        try "{ not valid json".write(to: malformed, atomically: true, encoding: .utf8)

        #expect(throws: ComputerUseScorecardError.self) {
            _ = try ComputerUseScorecardBuilder.loadReports(from: [malformed])
        }
    }

    @Test func loaderSkipsNonEvalReportJSONInsideDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComputerUseScorecardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixtureReportURL(),
            to: dir.appendingPathComponent("computer-use-report.json")
        )
        try #"{"generatedAt":"2026-06-22T12:00:00Z","totals":{"failed":1}}"#
            .write(
                to: dir.appendingPathComponent("scorecard.json"),
                atomically: true,
                encoding: .utf8
            )

        let reports = try ComputerUseScorecardBuilder.loadReports(from: [dir])

        #expect(reports.count == 1)
        #expect(reports.first?.report.modelId == "fixture-model")
    }

    private func fixtureReportURL() throws -> URL {
        try #require(Bundle.module.resourceURL)
            .appendingPathComponent("Fixtures/ComputerUseScorecard/mixed-report.json")
    }
}
