import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

@Suite
struct HarnessReliabilityEvalTests {
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func minesweeperFixtureRequiresAutonomousWebKitEvidence() throws {
        let suite = try EvalSuite.load(
            from: Self.packageRoot.appendingPathComponent("Suites/AgentLoop", isDirectory: true)
        )
        let testCase = try #require(
            suite.cases.first(where: {
                $0.id == "agent_loop.minesweeper-autonomous-web-smoke"
            })
        )
        #expect(!testCase.query.lowercased().contains("verify"))
        let expectations = try #require(testCase.expect.agentLoop)
        #expect(expectations.noDuplicateExecutedCalls == true)
        let readAudit = try #require(
            expectations.toolUsageAudit?.first(where: { $0.tool == "file_read" })
        )
        #expect(readAudit.argsMustContain == "web_smoke")
        #expect(readAudit.verificationStatus == "passed")
        #expect(readAudit.maxVerificationErrors == 0)
        #expect(readAudit.minBoardElements == 144)
    }

    @Test func webVerificationObservationRetainsScoringEvidenceBeyondPreview() throws {
        let envelope = ToolEnvelope.success(
            tool: "file_read",
            result: [
                "path": "minesweeper.html",
                "verification": [
                    "status": "passed",
                    "level": "behavior_smoke",
                    "content_sha256": String(repeating: "a", count: 64),
                    "errors": [String](),
                    "dom": [
                        "board_element_count": 144,
                        "selector_count": 144,
                    ],
                ],
            ] as [String: Any]
        )

        let observation = try #require(
            AgentLoopTranscript.webVerificationObservation(from: envelope)
        )
        #expect(observation.path == "minesweeper.html")
        #expect(observation.status == "passed")
        #expect(observation.level == "behavior_smoke")
        #expect(observation.runtimeErrors.isEmpty)
        #expect(observation.boardElementCount == 144)
        #expect(observation.selectorCount == 144)
    }
}
