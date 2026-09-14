import Foundation
import OsaurusCore
import Testing
@testable import OsaurusEvalsKit

@Suite(.serialized)
@MainActor
struct RAMAdmissionEvalTests {
    private var suites: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Suites")
    }

    @Test func committedMemoryScenariosRunThroughProductionPolicy() async throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: suites.appendingPathComponent("RAMAdmission"), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
        #expect(files.count == 12)
        for file in files {
            let fixture = try JSONDecoder().decode(EvalCase.self, from: Data(contentsOf: file))
            let report = await EvalRunner.runSubagentCase(fixture, modelId: "injected-host-facts")
            #expect(report.outcome == .passed, "\(file.lastPathComponent): \(report.notes)")
        }
    }

    @Test func liveReporterScenarioRetainsThreeFreshChatsAndStrictChildren() throws {
        let fixture = try JSONDecoder().decode(EvalCase.self, from: Data(contentsOf:
            suites.appendingPathComponent("AgentLoopRAMAdmission/three-fresh-chats-then-sequential.json")))
        let exp = try #require(fixture.expect.agentLoop)
        #expect(exp.freshChatWarmups?.count == 3)
        #expect(exp.spawnSummaries == ["RAM_FIRST_OK", "RAM_SECOND_OK"])
        #expect(fixture.fixtures.delegationSettings == .init(ramSafety: true, handoff: true, coexistence: false))
        #expect(fixture.fixtures.runtimeConcurrency?.maxConcurrentSequences == 1)
        #expect(fixture.fixtures.agentCapabilities?.childBudgets?.maxDelegateTokens == 2048)
    }

    private func transcript(_ calls: [AgentLoopTranscript.ToolInvocation]) -> AgentLoopTranscript {
        .init(toolCalls: calls, finalText: "RAM_FIRST_OK RAM_SECOND_OK", iterations: 3,
            exit: "finalResponse", systemPrompt: "", toolSchemaNames: ["spawn_agent"], error: nil)
    }

    @Test func parentEchoOrPreviewCannotPassMissingOrWrongChild() {
        let expected = ["RAM_FIRST_OK", "RAM_SECOND_OK"]
        let good = expected.map { summary in
            AgentLoopTranscript.ToolInvocation(name: "spawn_agent", arguments: "{}",
                resultPreview: "truncated", wasDeduped: false, spawnSummary: summary)
        }
        #expect(EvalRunner.scoreSpawnSummaries(expected, transcript: transcript(good)).passed)
        #expect(!EvalRunner.scoreSpawnSummaries(expected, transcript: transcript(Array(good.reversed()))).passed)
        #expect(!EvalRunner.scoreSpawnSummaries(expected, transcript: transcript([])).passed)
        for (summary, error, deduped) in [
            (Optional("I cannot return RAM_SECOND_OK"), false, false),
            (Optional("RAM_SECOND_OK"), true, false),
            (Optional("RAM_SECOND_OK"), false, true),
            (nil, false, false)
        ] {
            let bad = AgentLoopTranscript.ToolInvocation(name: "spawn_agent", arguments: "{}",
                resultPreview: "RAM_SECOND_OK", wasDeduped: deduped, wasError: error, spawnSummary: summary)
            #expect(!EvalRunner.scoreSpawnSummaries(expected, transcript: transcript([good[0], bad])).passed)
        }
    }

    @Test func completeDigestIsParsedBeforePreviewTruncation() {
        let digest = String(repeating: "x", count: 400) + "RAM_FIRST_OK"
        let envelope = ToolEnvelope.success(tool: "spawn_agent", result: ["kind": "spawn_result", "summary": digest])
        #expect(AgentLoopTranscript.spawnSummary(from: envelope, tool: "spawn_agent") == digest)
        #expect(AgentLoopTranscript.spawnSummary(from: envelope, tool: "spawn_batch") == nil)
        #expect(AgentLoopTranscript.spawnSummary(from: "RAM_FIRST_OK", tool: "spawn_agent") == nil)
        #expect(AgentLoopTranscript.spawnSummary(from:
            ToolEnvelope.failure(kind: .rejected, message: digest, tool: "spawn_agent"), tool: "spawn_agent") == nil)
    }
}
