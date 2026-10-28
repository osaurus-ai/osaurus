import Foundation
import Testing

@testable import OsaurusEvalsKit

struct AgentLoopRejectionFixtureTests {
    @Test func rejectionFixturePinsAnUnsupportedFormatAndImmediateStop() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let suite = try EvalSuite.load(from: root.appendingPathComponent("Suites/AgentLoop"))
        let fixture = try #require(suite.cases.first { $0.id == "agent_loop.rejection-stops-run" })
        let expect = try #require(fixture.expect.agentLoop)
        #expect(fixture.query.contains("path report.pptm"))
        #expect(fixture.query.contains("content exactly hello"))
        #expect(!fixture.query.contains("report.pptx"))
        #expect(expect.stopOnToolRejection == true)
        #expect(expect.allowedExits == ["toolRejected"])
        #expect(expect.mustCallTools == ["file_write"])
        #expect(expect.maxIterations == 4)
        #expect(expect.maxModelSteps == 1)
        #expect(expect.maxToolCalls == 1)
        let file = try #require(expect.files?.first)
        #expect(expect.files?.count == 1)
        #expect(file.path == "report.pptm")
        #expect(file.exists == false)
        #expect(expect.maxTokens == nil)
        #expect(expect.enableThinking == nil)
    }
}
