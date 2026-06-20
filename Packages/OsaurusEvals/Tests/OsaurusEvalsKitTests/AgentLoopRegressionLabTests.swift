import Foundation
import Testing

@testable import OsaurusEvalsKit

struct AgentLoopRegressionLabTests {
    @Test func fixtureReportsProduceExpectedMarkdownAndJSON() throws {
        let fixtures = try fixturesURL()
        let baseline = try AgentLoopRegressionReportSet.load(
            from: fixtures.appendingPathComponent("baseline.json"),
            label: "fixture baseline"
        )
        let current = try AgentLoopRegressionReportSet.load(
            from: fixtures.appendingPathComponent("current.json"),
            label: "fixture current"
        )

        let summary = try AgentLoopRegressionLab.compare(
            baseline: baseline,
            current: current,
            generatedAt: "2026-06-18T12:00:00Z"
        )

        #expect(summary.hasBlockingRegressions)
        #expect(summary.baselineCounts.total == 5)
        #expect(summary.currentCounts.errored == 1)
        #expect(summary.regressions.map(\.id) == ["agent_loop.search-then-multi-file-edit"])
        #expect(summary.newFailures.map(\.id) == ["agent_loop.write-new-file"])
        #expect(summary.fixed.map(\.id) == ["agent_loop.compaction-stress"])
        #expect(summary.persistentFailures.map(\.id) == ["agent_loop.legacy-case"])

        let expectedMarkdown = try String(
            contentsOf: fixtures.appendingPathComponent("expected-summary.md"),
            encoding: .utf8
        )
        #expect(summary.formatMarkdown() == expectedMarkdown)

        let encoded = try summary.toJSON(prettyPrinted: true)
        let decoded = try JSONDecoder().decode(
            AgentLoopRegressionLabSummary.self,
            from: encoded
        )
        #expect(decoded.regressions.first?.toolErrorDelta == 1)
        #expect(decoded.newCases.map(\.id) == ["agent_loop.new-stable"])
        #expect(decoded.removedCases.map(\.id) == ["agent_loop.removed-case"])
    }

    @Test func suiteValidationRejectsNonAgentLoopSelections() {
        let suite = EvalSuite(
            directory: URL(fileURLWithPath: "/tmp/MixedSuite", isDirectory: true),
            cases: [
                makeCase(id: "agent_loop.ok", domain: "agent_loop"),
                makeCase(id: "schema.minimum-bound", domain: "schema"),
            ]
        )

        #expect(throws: AgentLoopRegressionLabError.self) {
            try AgentLoopRegressionLab.validateAgentLoopSuite(suite, filter: nil)
        }
    }

    @Test func suiteValidationHonorsFilterBeforeRejecting() throws {
        let suite = EvalSuite(
            directory: URL(fileURLWithPath: "/tmp/MixedSuite", isDirectory: true),
            cases: [
                makeCase(id: "agent_loop.ok", domain: "agent_loop"),
                makeCase(id: "schema.minimum-bound", domain: "schema"),
            ]
        )

        try AgentLoopRegressionLab.validateAgentLoopSuite(suite, filter: "agent_loop.ok")
    }

    @Test func reportSetFilteringKeepsBaselineAndCurrentAligned() throws {
        let fixtures = try fixturesURL()
        let baseline = try AgentLoopRegressionReportSet.load(
            from: fixtures.appendingPathComponent("baseline.json"),
            label: "fixture baseline"
        ).filteringCaseIDs(containing: "search-then")
        let current = try AgentLoopRegressionReportSet.load(
            from: fixtures.appendingPathComponent("current.json"),
            label: "fixture current"
        ).filteringCaseIDs(containing: "search-then")

        let summary = try AgentLoopRegressionLab.compare(
            baseline: baseline,
            current: current,
            generatedAt: "2026-06-18T12:00:00Z"
        )

        #expect(summary.baselineCounts.total == 1)
        #expect(summary.currentCounts.total == 1)
        #expect(summary.regressions.map(\.id) == ["agent_loop.search-then-multi-file-edit"])
        #expect(summary.removedCases.isEmpty)
    }

    private func fixturesURL() throws -> URL {
        try #require(Bundle.module.resourceURL)
            .appendingPathComponent("Fixtures/AgentLoopRegressionLab", isDirectory: true)
    }

    private func makeCase(id: String, domain: String) -> EvalCase {
        EvalCase(
            id: id,
            domain: domain,
            query: "query",
            fixtures: .init(),
            expect: .init(agentLoop: domain == "agent_loop" ? .init() : nil)
        )
    }
}
