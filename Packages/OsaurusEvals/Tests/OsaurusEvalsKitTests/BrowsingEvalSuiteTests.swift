import Darwin
import Foundation
import Testing

@testable import OsaurusEvalsKit

@Suite(.serialized)
struct BrowsingEvalSuiteTests {
    private func loadSuite() throws -> EvalSuite {
        let suiteDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OsaurusEvalsKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // OsaurusEvals
            .appendingPathComponent("Suites/Browsing", isDirectory: true)
        return try EvalSuite.load(from: suiteDir)
    }

    @Test func suiteDecodesAsCurrentBehaviorAgentLoopCases() throws {
        let suite = try loadSuite()
        #expect(suite.decodeFailures.isEmpty, "decode failures: \(suite.decodeFailures)")
        #expect(suite.cases.count >= 3, "Browsing suite shrank; got \(suite.cases.count)")

        for testCase in suite.cases {
            #expect(testCase.domain == "agent_loop", "\(testCase.id) must be an agent_loop case")
            #expect(testCase.id.hasPrefix("browsing."), "\(testCase.id) id prefix")
            #expect(testCase.fixtures.requirePlugins == ["osaurus.browser"])
            #expect(testCase.fixtures.requireEnvironment == ["OSAURUS_EVALS_BROWSER_FIXTURE_URL"])
            #expect(testCase.notes?.contains("Current-behavior scaffold only") == true)
            #expect(testCase.notes?.contains("intentionally does not assert unsafe URL blocking") == true)

            let exp = try #require(testCase.expect.agentLoop, "\(testCase.id) missing expect.agentLoop")
            let requiredTools = (exp.mustCallTools ?? []) + (exp.mustCallAnyTools ?? [])
            #expect(
                requiredTools.contains { $0.hasPrefix("browser_") },
                "\(testCase.id) must require at least one browser tool"
            )
            #expect(
                (exp.files ?? []).contains { $0.path.hasPrefix("browsing-") },
                "\(testCase.id) must ground the browser result in a workspace file"
            )
        }
    }

    @Test func suiteDoesNotPinFutureSecurityResults() throws {
        let suiteDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Suites/Browsing", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: suiteDir,
            includingPropertiesForKeys: nil
        )
        let jsonFiles = files.filter { $0.pathExtension == "json" }
        #expect(!jsonFiles.isEmpty)

        let forbidden = [
            "SSRF_BLOCKED",
            "SECRET_IN_URL",
            "UNSAFE_SCHEME",
            "redirect/private target blocked",
            "cookie/password/token value does not appear",
        ]
        for url in jsonFiles {
            let text = try String(contentsOf: url, encoding: .utf8)
            for needle in forbidden {
                #expect(!text.contains(needle), "\(url.lastPathComponent) contains future security assertion \(needle)")
            }
        }
    }

    @MainActor
    @Test func requiredFixtureSkipReportsMissingPluginAndEnvironment() {
        let envName = "OSAURUS_EVALS_BROWSER_FIXTURE_URL_TEST_MISSING"
        let previous = getenv(envName).map { String(cString: $0) }
        unsetenv(envName)
        defer {
            if let previous {
                setenv(envName, previous, 1)
            } else {
                unsetenv(envName)
            }
        }

        let testCase = EvalCase(
            id: "browsing.skip-fixture",
            domain: "agent_loop",
            query: "query",
            fixtures: .init(
                requirePlugins: ["osaurus.browser.missing-for-test"],
                requireEnvironment: [envName]
            ),
            expect: .init(agentLoop: .init(mustCallTools: ["browser_navigate"]))
        )

        let row = EvalRunner.requiredFixtureSkipReport(
            testCase,
            label: "label",
            modelId: "model"
        )

        #expect(row?.outcome == .skipped)
        #expect(row?.notes.contains("missing plugins: osaurus.browser.missing-for-test") == true)
        #expect(row?.notes.contains("missing environment: \(envName)") == true)
    }
}
