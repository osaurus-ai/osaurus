import Foundation
import Testing

@testable import OsaurusEvalsKit

@Suite("Agent-loop filesystem fixtures")
struct AgentLoopFilesystemFixtureTests {
    private static var suiteURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Suites/AgentLoop")
    }

    @Test("filesystem grounding accepts equivalent inspection tools")
    func filesystemGroundingAcceptsEquivalentInspectionTools() throws {
        let suite = try EvalSuite.load(from: Self.suiteURL)
        let expected = Set(["file_read", "file_search", "shell_run"])

        for id in [
            "agent_loop.list-folder-contents",
            "agent_loop.targeted-read-and-report",
        ] {
            let testCase = try #require(suite.cases.first { $0.id == id })
            let loop = try #require(testCase.expect.agentLoop)
            #expect(loop.mustCallTools == nil)
            #expect(Set(loop.mustCallAnyTools ?? []) == expected)
            #expect(loop.noToolErrors == true)
        }
    }
}
