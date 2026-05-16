import Foundation
import Testing

@testable import OsaurusEvalsKit

struct EvalTimeoutReportTests {
    @Test func timeoutReportIncludesFilteredCasesAndDecodeFailures() throws {
        let matching = EvalCase(
            id: "capability_search.browser-prefix",
            domain: "capability_search",
            label: "browser prefix",
            query: "browser",
            fixtures: .init(requirePlugins: ["osaurus.browser"]),
            expect: .init()
        )
        let nonMatching = EvalCase(
            id: "capability_search.weather-natural",
            domain: "capability_search",
            query: "weather",
            fixtures: .init(),
            expect: .init()
        )
        let suite = EvalSuite(
            directory: URL(fileURLWithPath: "/tmp/CapabilitySearch", isDirectory: true),
            cases: [matching, nonMatching],
            decodeFailures: [("broken.json", "missing id")]
        )

        let report = EvalTimeoutReport.makeReport(
            suite: suite,
            modelId: "auto",
            filter: "browser",
            timeoutSeconds: 5,
            phase: "startup bootstrap",
            startedAt: "2026-05-16T00:00:00Z"
        )

        #expect(report.startedAt == "2026-05-16T00:00:00Z")
        #expect(report.counts.total == 2)
        #expect(report.counts.errored == 2)
        #expect(report.cases.map(\.id) == ["broken.json", "capability_search.browser-prefix"])
        #expect(report.cases[1].query == "browser")
        #expect(
            report.cases[1].notes == [
                "timeout: startup bootstrap exceeded 5s; eval aborted before case execution"
            ]
        )
    }

    @Test func configuredStartupTimeoutHonorsEnvironment() {
        #expect(EvalTimeoutReport.configuredStartupTimeoutSeconds(environment: [:]) == 120)
        #expect(EvalTimeoutReport.configuredStartupTimeoutSeconds(environment: ["CI": "true"]) == 30)
        #expect(EvalTimeoutReport.configuredStartupTimeoutSeconds(environment: ["CI": "1"]) == 30)
        #expect(
            EvalTimeoutReport.configuredStartupTimeoutSeconds(
                environment: ["OSAURUS_EVALS_STARTUP_TIMEOUT_SECONDS": "7.5", "CI": "true"]
            ) == 7.5
        )
        #expect(
            EvalTimeoutReport.configuredStartupTimeoutSeconds(
                environment: ["OSAURUS_EVALS_STARTUP_TIMEOUT_SECONDS": "0"]
            ) == nil
        )
    }
}
