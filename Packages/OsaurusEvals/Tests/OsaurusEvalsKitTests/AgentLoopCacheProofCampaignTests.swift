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
        #expect(expectation.todoCompletedBeforeFinal == nil)
        #expect(testCase.query.contains("First call todo with all three items unchecked"))
        #expect(testCase.query.contains("After file_write succeeds"))
    }

    @Test func todoDisciplineCaseRequiresFullyCheckedFinalSnapshot() throws {
        let suite = try EvalSuite.load(
            from: Self.packageRoot.appendingPathComponent("Suites/AgentLoop")
        )
        let testCase = try #require(
            suite.cases.first {
                $0.id == "agent_loop.todo-discipline-multistep"
            }
        )
        let expectation = try #require(testCase.expect.agentLoop)

        #expect(expectation.todoUpdatedBeforeComplete == true)
        #expect(expectation.todoCompletedBeforeFinal == true)
        #expect(expectation.enableThinking == true)
        #expect(expectation.maxModelSteps == 14)
    }

    @Test func multiFileTodoCaseLeavesRoomForFinalChecklistAndAnswer() throws {
        let suite = try EvalSuite.load(
            from: Self.packageRoot.appendingPathComponent("Suites/AgentLoopFrontier")
        )
        let testCase = try #require(
            suite.cases.first {
                $0.id == "frontier.multi-file-refactor-with-todo"
            }
        )
        let expectation = try #require(testCase.expect.agentLoop)

        // A valid model may update each import and call-site separately,
        // consume one corrective read after an exact-edit miss, and still
        // need a final Todo snapshot plus final answer. Keep this aligned
        // with the product's 30-step default; the dedicated pending-Todo
        // fixture supplies the strict six-step no-repeat regression gate.
        #expect(expectation.maxIterations == 30)
        #expect(expectation.maxModelSteps == 30)
        #expect(expectation.todoCompletedBeforeFinal == true)
    }

    @Test func todoGuidanceRequiresOneAccurateFinalToolSnapshotWithoutReopeningFinals() {
        #expect(SystemPromptTemplates.agentLoopGuidance.contains("not as prose"))
        #expect(SystemPromptTemplates.agentLoopGuidance.contains("Then answer exactly once and stop"))
        #expect(SystemPromptTemplates.agentLoopGuidance.contains("never keep the turn open"))
        #expect(SystemPromptTemplates.agentLoopGuidanceCompact.contains("do not print the checklist as prose"))
        #expect(TodoTool().description.contains("not as prose"))
        #expect(TodoTool().description.contains("answer the user exactly once and stop"))
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
        #expect(expectation.requireFinalDiskCacheRestore == true)
        #expect(expectation.requirePrefillProgressAccounting == true)
        #expect(expectation.requireNonEmptyVisibleTurns == true)
        #expect(expectation.requireClosedReasoning == true)
    }

    @Test func longestDiskPrefixCaseDecodesThreeSessionProofGates() throws {
        let suite = try EvalSuite.load(
            from: Self.packageRoot.appendingPathComponent("Suites/CacheProof")
        )
        let testCase = try #require(
            suite.cases.first {
                $0.id == "cache_proof.cross-session-longest-disk-prefix"
            }
        )
        let expectation = try #require(testCase.expect.cacheProof)

        #expect(expectation.startNewSessionBeforeTurns == [2, 3])
        #expect(expectation.systemPrompt?.contains("shared operating reference") == true)
        #expect(expectation.systemPromptsPerSession == nil)
        #expect(expectation.followUpTurns?.count == 2)
        #expect(expectation.followUpTurns?[0] == expectation.followUpTurns?[1])
        #expect(expectation.minStructuredCacheRestoreTurns == 2)
        #expect(expectation.requireFinalDiskCacheRestore == true)
        #expect(expectation.minFinalRestoreGainTokens == 128)
        #expect(expectation.requirePrefillProgressAccounting == true)
    }

    @Test func settingsRevisionCaseRejectsStaleWarmupAndRestoresNewestRevision() throws {
        let suite = try EvalSuite.load(
            from: Self.packageRoot.appendingPathComponent("Suites/CacheProof")
        )
        let testCase = try #require(
            suite.cases.first {
                $0.id == "cache_proof.settings-prompt-revision"
            }
        )
        let expectation = try #require(testCase.expect.cacheProof)

        #expect(expectation.startNewSessionBeforeTurns == [2, 3])
        #expect(expectation.systemPromptsPerSession?.count == 3)
        #expect(expectation.systemPromptsPerSession?[0] != expectation.systemPromptsPerSession?[1])
        #expect(expectation.systemPromptsPerSession?[1] == expectation.systemPromptsPerSession?[2])
        #expect(expectation.requireNoCacheRestoreOnTurns == [2])
        #expect(expectation.requireDiskCacheRestoreOnTurns == [3])
        #expect(expectation.requirePartialCacheRestoreOnTurns == [3])
        #expect(expectation.minCacheRestoredTokens == 64)
        #expect(expectation.requireFinalDiskCacheRestore == true)
        #expect(expectation.requirePrefillProgressAccounting == true)
        #expect(expectation.requireNonEmptyVisibleTurns == true)
        #expect(expectation.requireClosedReasoning == true)
    }

    @MainActor
    @Test func repeatedCacheProofTrialsReceiveDistinctButInternallyStableNamespaces() {
        let first = EvalRunner.cacheProofTrialInputs(
            queries: ["one", "two"],
            systemPrompt: "shared system",
            systemPromptsPerSession: nil,
            nonce: "trial-a"
        )
        let second = EvalRunner.cacheProofTrialInputs(
            queries: ["one", "two"],
            systemPrompt: "shared system",
            systemPromptsPerSession: nil,
            nonce: "trial-b"
        )

        #expect(first.queries == ["one", "two"])
        #expect(first.systemPrompt?.contains("trial-a") == true)
        #expect(second.systemPrompt?.contains("trial-b") == true)
        #expect(first.systemPrompt != second.systemPrompt)
    }

    @MainActor
    @Test func cacheProofWithoutSystemPromptNamespacesEveryTurnQuery() {
        let inputs = EvalRunner.cacheProofTrialInputs(
            queries: ["same", "same"],
            systemPrompt: nil,
            systemPromptsPerSession: nil,
            nonce: "trial-c"
        )

        #expect(inputs.systemPrompt == nil)
        #expect(inputs.systemPromptsPerSession == nil)
        #expect(inputs.queries[0] == inputs.queries[1])
        #expect(inputs.queries[0].contains("trial-c"))
    }

    @MainActor
    @Test func finalTodoCompletionUsesLastParseableSnapshotBeforeTerminal() throws {
        let calls = [
            AgentLoopTranscript.ToolInvocation(
                name: "todo",
                arguments: #"{"markdown":"- [ ] Write file\n- [ ] Verify"}"#,
                resultPreview: "Todo updated",
                wasDeduped: false
            ),
            AgentLoopTranscript.ToolInvocation(
                name: "file_write",
                arguments: #"{"path":"result.txt","content":"ok"}"#,
                resultPreview: "Wrote result.txt",
                wasDeduped: false
            ),
            AgentLoopTranscript.ToolInvocation(
                name: "todo",
                arguments: #"{"markdown":"- [x] Write file\n- [x] Verify"}"#,
                resultPreview: "Todo updated",
                wasDeduped: false
            ),
            AgentLoopTranscript.ToolInvocation(
                name: "complete",
                arguments: #"{"summary":"done"}"#,
                resultPreview: "Complete",
                wasDeduped: false
            ),
            AgentLoopTranscript.ToolInvocation(
                name: "todo",
                arguments: #"{"markdown":"- [ ] Too late"}"#,
                resultPreview: "Todo updated",
                wasDeduped: false
            ),
        ]

        let todo = try #require(EvalRunner.lastTodoBeforeTerminal(in: calls))
        #expect(todo.doneCount == 2)
        #expect(todo.totalCount == 2)
    }

    @MainActor
    @Test func prefillProgressAccountingAcceptsRestorePrefillCompleteLifecycle() {
        let metrics = CacheProofTurnMetrics(
            turnNumber: 2,
            sessionNumber: 2,
            ttftMs: 125,
            prefillTokensPerSecond: 900,
            promptTokenCount: 100,
            cacheRestoredTokens: 64,
            remainingPrefillTokens: 36,
            cacheRestoreDetail: "disk",
            stopReason: "stop",
            unclosedReasoning: false,
            visibleCharacterCount: 2,
            reasoningCharacterCount: 0,
            prefillProgressEvents: [
                .init(stage: "queued", completedUnitCount: 0, totalUnitCount: 100, detail: nil),
                .init(stage: "cacheLookup", completedUnitCount: 0, totalUnitCount: 100, detail: nil),
                .init(stage: "cacheRestore", completedUnitCount: 64, totalUnitCount: 100, detail: "disk"),
                .init(stage: "prefill", completedUnitCount: 64, totalUnitCount: 100, detail: nil),
                .init(stage: "prefill", completedUnitCount: 100, totalUnitCount: 100, detail: nil),
                .init(stage: "complete", completedUnitCount: 100, totalUnitCount: 100, detail: nil),
            ]
        )

        #expect(EvalRunner.prefillProgressAccountingProblem(for: metrics) == nil)
    }

    @MainActor
    @Test func prefillProgressAccountingRejectsBackwardCompletedCount() {
        let metrics = CacheProofTurnMetrics(
            turnNumber: 2,
            sessionNumber: 2,
            ttftMs: nil,
            prefillTokensPerSecond: nil,
            promptTokenCount: 100,
            cacheRestoredTokens: 64,
            remainingPrefillTokens: 36,
            cacheRestoreDetail: "disk",
            stopReason: "stop",
            unclosedReasoning: false,
            visibleCharacterCount: 2,
            reasoningCharacterCount: 0,
            prefillProgressEvents: [
                .init(stage: "cacheRestore", completedUnitCount: 64, totalUnitCount: 100, detail: "disk"),
                .init(stage: "prefill", completedUnitCount: 32, totalUnitCount: 100, detail: nil),
                .init(stage: "complete", completedUnitCount: 100, totalUnitCount: 100, detail: nil),
            ]
        )

        #expect(
            EvalRunner.prefillProgressAccountingProblem(for: metrics)?
                .contains("completed count regressed") == true
        )
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
