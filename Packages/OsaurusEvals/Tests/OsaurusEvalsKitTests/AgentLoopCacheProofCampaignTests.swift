import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

@Suite
struct AgentLoopCacheProofCampaignTests {
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func pendingTodoFinalizationCaseDecodesItsStepCeiling() throws {
        let suite = try EvalSuite.load(
            from: Self.packageRoot.appendingPathComponent("Suites/AgentLoop")
        )
        let testCase = try #require(
            suite.cases.first {
                $0.id == "agent_loop.final-after-success-with-pending-todo"
            }
        )
        let expectation = try #require(testCase.expect.agentLoop)

        #expect(expectation.maxIterations == 10)
        #expect(expectation.maxModelSteps == 6)
        #expect(expectation.maxToolCalls == 5)
        #expect(expectation.noDuplicateExecutedCalls == nil)
        #expect(expectation.allowedExits == ["finalResponse"])
    }

    @Test func crossSessionDiskRestoreCaseDecodesStructuredProofGates() throws {
        let suite = try EvalSuite.load(
            from: Self.packageRoot.appendingPathComponent("Suites/CacheProof")
        )
        let testCase = try #require(
            suite.cases.first {
                $0.id == "cache_proof.cross-session-partial-disk-restore"
            }
        )
        let expectation = try #require(testCase.expect.cacheProof)

        #expect(expectation.startNewSessionBeforeTurns == [2])
        #expect(expectation.maxTokens == 512)
        #expect(expectation.systemPrompt?.contains("shared operating reference") == true)
        #expect(expectation.minCacheRestoredTokens == 128)
        #expect(expectation.requirePartialCacheRestore == true)
        #expect(expectation.requireDiskCacheRestore == true)
        #expect(expectation.requireNonEmptyVisibleTurns == true)
        #expect(expectation.requireClosedReasoning == true)
    }

    @Test func olderCacheProofTranscriptsDecodeWithoutTurnMetrics() throws {
        let data = Data(
            """
            {
              "visibleTurns": ["ok"],
              "error": null,
              "skipReason": null,
              "kvPrefixHitsDelta": 1,
              "kvPrefixMissesDelta": 0,
              "ssmCompanionHitsDelta": 0,
              "ssmCompanionMissesDelta": 0,
              "ssmCompanionReDerivesDelta": 0,
              "diskL2HitsDelta": 0,
              "diskL2MissesDelta": 0,
              "diskL2StoresDelta": 1,
              "hybridTopology": false,
              "decodeTokensPerSecond": 10,
              "footprintAfterTurnMb": [1024]
            }
            """.utf8
        )

        let transcript = try JSONDecoder().decode(CacheProofTranscript.self, from: data)
        #expect(transcript.visibleTurns == ["ok"])
        #expect(transcript.turnMetrics == nil)
    }
}
