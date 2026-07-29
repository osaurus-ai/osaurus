import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

@Suite
struct AgentLoopSpawnBatchEvalTests {
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func batchEnvelope(
        aggregateStatus: String = "succeeded",
        reportedSucceeded: Int = 2,
        reportedFailed: Int = 0,
        secondRowOK: Bool = true,
        secondNestedOK: Bool = true,
        remoteJobs: Int = 0,
        effectiveLocalSlots: Int = 2,
        localSubwaves: [Int] = [2],
        limitingFactors: [String] = [],
        cacheAvailable: Bool = true,
        omitEffectiveLocalSlots: Bool = false
    ) -> String {
        var wave: [String: Any] = [
            "wave": 0,
            "jobs": 2,
            "remote_jobs": remoteJobs,
            "local_jobs": 2 - remoteJobs,
            "local_subwaves": localSubwaves,
            "limited_by": limitingFactors,
            "verdict": "admitted",
        ]
        if !omitEffectiveLocalSlots {
            wave["effective_local_slots"] = effectiveLocalSlots
        }

        return ToolEnvelope.success(
            tool: "spawn_batch",
            result: [
                "kind": "spawn_batch_result",
                "max_parallel": 2,
                "succeeded": reportedSucceeded,
                "failed": reportedFailed,
                "aggregate_status": aggregateStatus,
                "execution": [
                    "configured_max_subagents": 2,
                    "waves": [wave],
                    "cache": ["available": cacheAvailable],
                ],
                "results": [
                    [
                        "id": "math",
                        "target_type": "agent",
                        "target": "Math Worker",
                        "ok": true,
                        "envelope": [
                            "ok": true,
                            "result": [
                                "kind": "spawn_result",
                                "model": "test/math-model",
                                "summary": "BATCH_ALPHA_42",
                            ],
                        ],
                    ],
                    [
                        "id": "writing",
                        "target_type": "model",
                        "target": "test/writing-model",
                        "ok": secondRowOK,
                        "envelope": [
                            "ok": secondNestedOK,
                            "kind": secondNestedOK ? "success" : "execution_error",
                            "message": secondNestedOK ? "BATCH_BETA_BLUE" : "worker failed",
                            "result": secondNestedOK
                                ? [
                                    "kind": "spawn_result",
                                    "model": "test/writing-model",
                                    "summary": "BATCH_BETA_BLUE",
                                ]
                                : ["kind": "spawn_error"],
                        ],
                    ],
                ],
            ]
        )
    }

    private static func transcript(
        observation: AgentLoopTranscript.SpawnBatchObservation?
    ) -> AgentLoopTranscript {
        AgentLoopTranscript(
            toolCalls: [
                .init(
                    name: "spawn_batch",
                    arguments: #"{"jobs":[]}"#,
                    resultPreview: "bounded",
                    wasDeduped: false,
                    spawnBatch: observation
                )
            ],
            finalText: "done",
            iterations: 2,
            exit: "finalResponse",
            systemPrompt: "system",
            toolSchemaNames: ["spawn_batch"],
            error: nil
        )
    }

    @Test func parsesOrderedSettledRowsAndAggregateCounts() throws {
        let observation = try #require(
            AgentLoopTranscript.spawnBatchObservation(from: Self.batchEnvelope())
        )

        #expect(observation.resultKind == "spawn_batch_result")
        #expect(observation.maxParallel == 2)
        #expect(observation.reportedSucceeded == 2)
        #expect(observation.reportedFailed == 0)
        #expect(observation.observedSucceeded == 2)
        #expect(observation.observedFailed == 0)
        #expect(observation.orderedJobIds == ["math", "writing"])
        #expect(observation.childRows.map(\.targetType) == ["agent", "model"])
        #expect(observation.childRows.map(\.target) == ["Math Worker", "test/writing-model"])
        #expect(observation.childRows.map(\.model) == [
            "test/math-model",
            "test/writing-model",
        ])
        #expect(observation.childRows.map(\.summary) == [
            "BATCH_ALPHA_42",
            "BATCH_BETA_BLUE",
        ])
        #expect(observation.everyRowSettled)
        #expect(observation.aggregateStatus == "succeeded")
        #expect(observation.executionWaves?.count == 1)
        #expect(observation.executionWaves?.first?.remoteJobs == 0)
        #expect(observation.executionWaves?.first?.effectiveLocalSlots == 2)
        #expect(observation.executionWaves?.first?.localSubwaves == [2])
        #expect(observation.executionWaves?.first?.limitingFactors == [])
        #expect(observation.everyExecutionWaveWellFormed == true)
        #expect(observation.cacheAvailable == true)
    }

    @Test func parsesPartialFailureAggregateAndSettledRows() throws {
        let observation = try #require(
            AgentLoopTranscript.spawnBatchObservation(
                from: Self.batchEnvelope(
                    aggregateStatus: "partial_failure",
                    reportedSucceeded: 1,
                    reportedFailed: 1,
                    secondRowOK: false,
                    secondNestedOK: false,
                    remoteJobs: 1,
                    effectiveLocalSlots: 1,
                    localSubwaves: [1],
                    limitingFactors: ["engine_slot_limit"],
                    cacheAvailable: false
                )
            )
        )

        #expect(observation.aggregateStatus == "partial_failure")
        #expect(observation.observedSucceeded == 1)
        #expect(observation.observedFailed == 1)
        #expect(observation.everyRowSettled)
        #expect(observation.executionWaves?.first?.remoteJobs == 1)
        #expect(observation.executionWaves?.first?.effectiveLocalSlots == 1)
        #expect(observation.executionWaves?.first?.localSubwaves == [1])
        #expect(observation.executionWaves?.first?.limitingFactors == ["engine_slot_limit"])
        #expect(observation.cacheAvailable == false)
    }

    @Test func rejectsNonBatchAndMarksNestedStatusMismatchUnsettled() throws {
        let ordinary = ToolEnvelope.success(tool: "file_read", result: ["text": "ok"])
        #expect(AgentLoopTranscript.spawnBatchObservation(from: ordinary) == nil)

        let mismatch = try #require(
            AgentLoopTranscript.spawnBatchObservation(
                from: Self.batchEnvelope(
                    aggregateStatus: "partial_failure",
                    reportedSucceeded: 1,
                    reportedFailed: 1,
                    secondRowOK: false,
                    secondNestedOK: true,
                    omitEffectiveLocalSlots: true
                )
            )
        )
        #expect(!mismatch.everyRowSettled)
        #expect(mismatch.orderedJobIds == ["math"])
        #expect(mismatch.everyExecutionWaveWellFormed == false)
        #expect(mismatch.executionWaves?.first?.effectiveLocalSlots == nil)
    }

    @MainActor
    @Test func structuredScorerPassesAndCatchesCountDrift() throws {
        let observation = try #require(
            AgentLoopTranscript.spawnBatchObservation(from: Self.batchEnvelope())
        )
        let assertion = EvalCase.AgentLoopExpectations.SpawnBatchAssertion(
            exactCallCount: 1,
            expectedJobIds: ["math", "writing"],
            expectedSucceeded: 2,
            expectedFailed: 0,
            expectedMaxParallel: 2,
            requireEveryRowSettled: true,
            requireReportedCountsMatchRows: true,
            expectedAggregateStatus: "succeeded",
            requireEveryExecutionWaveWellFormed: true,
            expectedCacheAvailable: true,
            expectedRows: [
                .init(
                    id: "math",
                    targetType: "agent",
                    target: "Math Worker",
                    ok: true,
                    model: "test/math-model",
                    summaryContains: ["BATCH_ALPHA_42"]
                ),
                .init(
                    id: "writing",
                    targetType: "model",
                    target: "test/writing-model",
                    ok: true,
                    model: "test/writing-model",
                    summaryContains: ["BATCH_BETA_BLUE"]
                ),
            ]
        )
        let passing = EvalRunner.scoreSpawnBatch(
            assertion,
            transcript: Self.transcript(observation: observation)
        )
        #expect(passing.passed)
        #expect(passing.note.contains("slots=2"))
        #expect(passing.note.contains("subwaves=[2]"))

        let drift = try #require(
            AgentLoopTranscript.spawnBatchObservation(
                from: Self.batchEnvelope(
                    reportedSucceeded: 1,
                    reportedFailed: 1
                )
            )
        )
        let failing = EvalRunner.scoreSpawnBatch(
            assertion,
            transcript: Self.transcript(observation: drift)
        )
        #expect(!failing.passed)
        #expect(failing.note.contains("reported counts"))
    }

    @MainActor
    @Test func structuredScorerRejectsMissingCallAndWrongChildTruth() throws {
        let assertion = EvalCase.AgentLoopExpectations.SpawnBatchAssertion(
            expectedRows: [
                .init(
                    id: "math",
                    targetType: "agent",
                    target: "Wrong Worker",
                    ok: true,
                    model: "wrong/model",
                    summaryContains: ["NEVER_RETURNED"]
                )
            ]
        )
        let empty = AgentLoopTranscript(
            toolCalls: [],
            finalText: "the parent echoed NEVER_RETURNED",
            iterations: 1,
            exit: "finalResponse",
            systemPrompt: "system",
            toolSchemaNames: ["spawn_batch"],
            error: nil
        )
        let vacuous = EvalRunner.scoreSpawnBatch(assertion, transcript: empty)
        #expect(!vacuous.passed)
        #expect(vacuous.note.contains("no spawn_batch call"))

        let observation = try #require(
            AgentLoopTranscript.spawnBatchObservation(from: Self.batchEnvelope())
        )
        let wrong = EvalRunner.scoreSpawnBatch(
            assertion,
            transcript: Self.transcript(observation: observation)
        )
        #expect(!wrong.passed)
        #expect(wrong.note.contains("child rows 2 != 1"))
        #expect(wrong.note.contains("child[0].target"))
        #expect(wrong.note.contains("child[0].model"))
        #expect(wrong.note.contains("child[0].summary"))
    }

    @MainActor
    @Test func settingsDerivedWaveAssertionsPassAndCatchDrift() throws {
        let assertion = EvalCase.AgentLoopExpectations.SpawnBatchAssertion(
            exactCallCount: 1,
            expectedAggregateStatus: "succeeded",
            expectedExecutionWaves: [
                .init(
                    wave: 0,
                    remoteJobs: 1,
                    effectiveLocalSlots: 1,
                    localSubwaves: [1, 1],
                    limitingFactors: ["continuous_batching_disabled"]
                )
            ],
            requireEveryExecutionWaveWellFormed: true,
            expectedCacheAvailable: false
        )
        let matching = try #require(
            AgentLoopTranscript.spawnBatchObservation(
                from: Self.batchEnvelope(
                    remoteJobs: 1,
                    effectiveLocalSlots: 1,
                    localSubwaves: [1, 1],
                    limitingFactors: ["continuous_batching_disabled"],
                    cacheAvailable: false
                )
            )
        )
        let passing = EvalRunner.scoreSpawnBatch(
            assertion,
            transcript: Self.transcript(observation: matching)
        )
        #expect(passing.passed)

        let drifted = try #require(
            AgentLoopTranscript.spawnBatchObservation(
                from: Self.batchEnvelope(
                    remoteJobs: 1,
                    effectiveLocalSlots: 2,
                    localSubwaves: [2],
                    limitingFactors: [],
                    cacheAvailable: true
                )
            )
        )
        let failing = EvalRunner.scoreSpawnBatch(
            assertion,
            transcript: Self.transcript(observation: drifted)
        )
        #expect(!failing.passed)
        #expect(failing.note.contains("effective_local_slots"))
        #expect(failing.note.contains("local_subwaves"))
        #expect(failing.note.contains("limited_by"))
        #expect(failing.note.contains("cache available"))
    }

    @MainActor
    @Test func scorerRejectsMalformedExecutionAndUnsettledRows() throws {
        let malformed = try #require(
            AgentLoopTranscript.spawnBatchObservation(
                from: Self.batchEnvelope(
                    aggregateStatus: "partial_failure",
                    reportedSucceeded: 1,
                    reportedFailed: 1,
                    secondRowOK: false,
                    secondNestedOK: true,
                    omitEffectiveLocalSlots: true
                )
            )
        )
        let assertion = EvalCase.AgentLoopExpectations.SpawnBatchAssertion(
            exactCallCount: 1,
            requireEveryRowSettled: true,
            expectedAggregateStatus: "partial_failure",
            requireEveryExecutionWaveWellFormed: true
        )
        let result = EvalRunner.scoreSpawnBatch(
            assertion,
            transcript: Self.transcript(observation: malformed)
        )
        #expect(!result.passed)
        #expect(result.note.contains("child rows were not settled"))
        #expect(result.note.contains("execution waves were absent or malformed"))
    }

    @Test func productionFixtureDecodesAllowedTargetsAndNoSamplerOverrides() throws {
        let suite = try EvalSuite.load(
            from: Self.packageRoot.appendingPathComponent("Suites/AgentLoop")
        )
        let testCase = try #require(
            suite.cases.first {
                $0.id == "agent_loop.spawn-batch-two-configured-workers"
            }
        )
        let capabilities = try #require(testCase.fixtures.agentCapabilities)
        let runtimeConcurrency = try #require(testCase.fixtures.runtimeConcurrency)
        let expectation = try #require(testCase.expect.agentLoop)

        #expect(capabilities.spawnAgents?.map(\.name) == [
            "Osaurus Eval Batch Math",
            "Osaurus Eval Batch Writing",
        ])
        #expect(capabilities.spawnAgents?.compactMap { $0.id?.uuidString } == [
            "A11CE001-0000-4000-8000-000000000001",
            "A11CE001-0000-4000-8000-000000000002",
        ])
        #expect(capabilities.maxParallelSpawns == 2)
        #expect(capabilities.requestsAnyCapability)
        #expect(runtimeConcurrency.continuousBatching == true)
        #expect(runtimeConcurrency.maxConcurrentSequences == 2)
        #expect(expectation.enableThinking == nil)
        #expect(expectation.spawnBatch?.expectedJobIds == ["math", "writing"])
        #expect(expectation.spawnBatch?.requireEveryRowSettled == true)
        #expect(expectation.spawnBatch?.expectedAggregateStatus == "succeeded")
        let waves = try #require(expectation.spawnBatch?.expectedExecutionWaves)
        #expect(waves.count == 1)
        #expect(waves.first?.wave == 1)
        #expect(waves.first?.remoteJobs == 0)
        #expect(waves.first?.effectiveLocalSlots == 2)
        #expect(waves.first?.localSubwaves == [2])
        #expect(expectation.spawnBatch?.requireEveryExecutionWaveWellFormed == true)
        #expect(expectation.spawnBatch?.expectedCacheAvailable == true)
        #expect(expectation.maxToolCalls == 1)
    }

    @Test func differentLocalFixtureDecodesExactModelsAndSerializedWaves() throws {
        let suite = try EvalSuite.load(
            from: Self.packageRoot.appendingPathComponent("Suites/AgentLoop")
        )
        let testCase = try #require(
            suite.cases.first {
                $0.id == "agent_loop.spawn-batch-two-different-local-workers"
            }
        )
        let capabilities = try #require(testCase.fixtures.agentCapabilities)
        let runtimeConcurrency = try #require(testCase.fixtures.runtimeConcurrency)
        let workers = try #require(capabilities.spawnAgents)
        let expectation = try #require(testCase.expect.agentLoop)
        let waves = try #require(expectation.spawnBatch?.expectedExecutionWaves)

        #expect(workers.map(\.name) == [
            "Osaurus Eval Nanbeige Worker",
            "Osaurus Eval Ornith Worker",
        ])
        #expect(workers.compactMap { $0.id?.uuidString } == [
            "A11CE001-0000-4000-8000-000000000101",
            "A11CE001-0000-4000-8000-000000000102",
        ])
        #expect(workers.map(\.modelId) == [
            "JANGQ-AI/Nanbeige4.2-3B-JANG_4M",
            "JANGQ-AI/Ornith-1.0-9B-JANG_4M",
        ])
        #expect(capabilities.maxParallelSpawns == 2)
        #expect(runtimeConcurrency.continuousBatching == true)
        #expect(runtimeConcurrency.maxConcurrentSequences == 2)
        #expect(expectation.enableThinking == nil)
        #expect(expectation.spawnBatch?.expectedJobIds == ["nanbeige", "ornith"])
        #expect(expectation.spawnBatch?.expectedRows?.map(\.model) == [
            "JANGQ-AI/Nanbeige4.2-3B-JANG_4M",
            "JANGQ-AI/Ornith-1.0-9B-JANG_4M",
        ])
        #expect(expectation.spawnBatch?.expectedRows?.map(\.target) == [
            "A11CE001-0000-4000-8000-000000000101",
            "A11CE001-0000-4000-8000-000000000102",
        ])
        #expect(expectation.spawnBatch?.expectedRows?.map(\.summaryContains) == [
            ["DIFFERENT_LOCAL_ALPHA"],
            ["DIFFERENT_LOCAL_BETA"],
        ])
        #expect(waves.count == 2)
        #expect(waves.map(\.wave) == [1, 2])
        #expect(waves.allSatisfy { $0.remoteJobs == 0 })
        #expect(waves.allSatisfy { $0.effectiveLocalSlots == 1 })
        #expect(waves.allSatisfy { $0.localSubwaves == [1] })
    }

    @MainActor
    @Test func workerInstallUsesExplicitOrCaseModelAndCleanupRemovesRecords() throws {
        let suffix = UUID().uuidString
        let fallbackName = "Osaurus Eval Fallback \(suffix)"
        let explicitName = "Osaurus Eval Explicit \(suffix)"
        let installed = EvalRunner.installEvalSpawnTargets(
            [
                .init(name: fallbackName),
                .init(name: explicitName, modelId: "JANGQ-AI/explicit-test-model"),
            ],
            modelId: "JANGQ-AI/case-test-model"
        )
        let ids = installed.ids
        var cleanupIds = ids
        defer {
            for id in cleanupIds {
                EvalRunner.removeEvalAgent(id)
            }
        }

        #expect(installed.error == nil)
        #expect(ids.count == 2)
        let agents = AgentStore.loadAll().filter { ids.contains($0.id) }
        #expect(agents.count == 2)
        #expect(agents.first { $0.name == fallbackName }?.defaultModel
            == "JANGQ-AI/case-test-model")
        #expect(agents.first { $0.name == explicitName }?.defaultModel
            == "JANGQ-AI/explicit-test-model")
        #expect(agents.allSatisfy { $0.temperature == nil && $0.maxTokens == nil })

        for id in ids {
            EvalRunner.removeEvalAgent(id)
        }
        cleanupIds.removeAll()
        #expect(AgentStore.loadAll().allSatisfy { !ids.contains($0.id) })
    }

    @MainActor
    @Test func blankExplicitWorkerModelFailsBeforeInstallingAnything() {
        let name = "Osaurus Eval Blank Model \(UUID().uuidString)"
        let installed = EvalRunner.installEvalSpawnTargets(
            [.init(name: name, modelId: "  ")],
            modelId: "JANGQ-AI/case-test-model"
        )

        #expect(installed.ids.isEmpty)
        #expect(installed.error?.contains("blank model id") == true)
        #expect(!AgentStore.loadAll().contains { $0.name == name })
    }
}
