import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

@Suite
struct AgentLoopSpawnWaveEvalTests {
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static let mathID = "A11CE001-0000-4000-8000-000000000001"
    private static let writingID = "A11CE001-0000-4000-8000-000000000002"

    private static func arguments(agent: String, input: String) -> String {
        "{\"agent\":\"\(agent)\",\"input\":\"\(input)\"}"
    }

    private static func successEnvelope(model: String, summary: String) -> String {
        ToolEnvelope.success(
            tool: "spawn_agent",
            result: [
                "kind": "spawn_result",
                "model": model,
                "summary": summary,
                "session_id": UUID().uuidString,
                "needs_input": false,
            ]
        )
    }

    private static func failureEnvelope(kind: ToolEnvelope.Kind = .executionError) -> String {
        ToolEnvelope.failure(kind: kind, message: "worker failed", tool: "spawn_agent")
    }

    private static func call(
        agent: String, input: String, result: String, step: Int
    ) -> AgentLoopTranscript.ToolInvocation {
        let args = arguments(agent: agent, input: input)
        return .init(
            name: "spawn_agent",
            arguments: args,
            resultPreview: String(result.prefix(300)),
            wasDeduped: false,
            wasError: ToolEnvelope.isError(result),
            step: step,
            spawnCall: AgentLoopTranscript.spawnCallObservation(
                tool: "spawn_agent", arguments: args, result: result
            ),
            spawnSummary: AgentLoopTranscript.spawnSummary(from: result, tool: "spawn_agent")
        )
    }

    private static func transcript(_ calls: [AgentLoopTranscript.ToolInvocation]) -> AgentLoopTranscript {
        AgentLoopTranscript(
            toolCalls: calls,
            finalText: "done",
            iterations: 2,
            exit: "finalResponse",
            systemPrompt: "system",
            toolSchemaNames: ["spawn_agent"],
            error: nil
        )
    }

    /// Two calls in one model step: the canonical happy-path wave.
    private static func twoCallWave(secondOK: Bool = true) -> AgentLoopTranscript {
        transcript([
            call(
                agent: mathID, input: "Return BATCH_ALPHA_42",
                result: successEnvelope(model: "test/math-model", summary: "BATCH_ALPHA_42"),
                step: 1
            ),
            call(
                agent: writingID, input: "Return BATCH_BETA_BLUE",
                result: secondOK
                    ? successEnvelope(model: "test/writing-model", summary: "BATCH_BETA_BLUE")
                    : failureEnvelope(),
                step: 1
            ),
        ])
    }

    @Test func parsesSuccessAndFailureRows() throws {
        let ok = try #require(
            AgentLoopTranscript.spawnCallObservation(
                tool: "spawn_agent",
                arguments: Self.arguments(agent: Self.mathID, input: "x"),
                result: Self.successEnvelope(model: "test/math-model", summary: "BATCH_ALPHA_42")
            )
        )
        #expect(ok.target == Self.mathID)
        #expect(ok.ok)
        #expect(ok.model == "test/math-model")
        #expect(ok.summary == "BATCH_ALPHA_42")
        #expect(ok.sessionId != nil)
        #expect(ok.needsInput == false)
        #expect(ok.failureKind == nil)

        let failed = try #require(
            AgentLoopTranscript.spawnCallObservation(
                tool: "spawn_agent",
                arguments: Self.arguments(agent: Self.writingID, input: "x"),
                result: Self.failureEnvelope(kind: .userDenied)
            )
        )
        #expect(failed.target == Self.writingID)
        #expect(!failed.ok)
        #expect(failed.failureKind == "user_denied")
        #expect(failed.summary == "worker failed")

        let continued = try #require(
            AgentLoopTranscript.spawnCallObservation(
                tool: "spawn_agent",
                arguments: "{\"continue\":\"SESSION-1\",\"input\":\"more\"}",
                result: Self.successEnvelope(model: "m", summary: "s")
            )
        )
        #expect(continued.target == nil)
        #expect(continued.continuedSessionId == "SESSION-1")

        #expect(
            AgentLoopTranscript.spawnCallObservation(
                tool: "file_read", arguments: "{}", result: Self.successEnvelope(model: "m", summary: "s")
            ) == nil
        )
    }

    @Test func exportedTranscriptKeepsRowsAndStepBeyondPreview() throws {
        let observation = try #require(
            AgentLoopTranscript.spawnCallObservation(
                tool: "spawn_agent",
                arguments: Self.arguments(agent: Self.mathID, input: "x"),
                result: Self.successEnvelope(model: "test/math-model", summary: "BATCH_ALPHA_42")
            )
        )
        let event = EvalCaseTranscript.ToolEvent(
            name: "spawn_agent", arguments: "{}", resultPreview: "truncated before children",
            step: 3, spawnCall: observation
        )
        let decoded = try JSONDecoder().decode(
            EvalCaseTranscript.ToolEvent.self, from: JSONEncoder().encode(event))
        #expect(decoded.spawnCall == observation)
        #expect(decoded.step == 3)
        #expect(decoded.spawnCall?.summary == "BATCH_ALPHA_42")
    }

    @MainActor
    @Test func oneMessageTwoCallsScoresAsOneWave() {
        let assertion = EvalCase.AgentLoopExpectations.SpawnWaveAssertion(
            exactCallCount: 2,
            expectedTargets: [Self.mathID, Self.writingID],
            expectedSucceeded: 2,
            expectedFailed: 0,
            expectedWaveSizes: [2],
            expectedRows: [
                .init(target: Self.mathID, ok: true, model: "test/math-model", summaryEquals: "BATCH_ALPHA_42"),
                .init(target: Self.writingID, ok: true, summaryContains: ["BATCH_BETA_BLUE"]),
            ]
        )
        let result = EvalRunner.scoreSpawnWave(assertion, transcript: Self.twoCallWave())
        #expect(result.passed, "\(result.note)")
        #expect(result.note.contains("waveSizes=[2]"))
    }

    /// `spawn_agent` accepts a name, a UUID or an address; a case that pins
    /// the fixture UUID must still pass when the model addressed the worker
    /// by its visible name and the runtime resolved it to that UUID (Raptor
    /// nothink lane, `route-by-agent-description`, 2026-09-29). A different
    /// resolved worker still fails.
    @MainActor
    @Test func expectedTargetsAcceptResolvedNameOrUUID() {
        func resolvedEnvelope(agentName: String, agentId: String) -> String {
            ToolEnvelope.success(
                tool: "spawn_agent",
                result: [
                    "kind": "spawn_result",
                    "model": "test/math-model",
                    "agent": agentName,
                    "agent_id": agentId,
                    "summary": "42",
                    "session_id": UUID().uuidString,
                    "needs_input": false,
                ]
            )
        }
        let byName = Self.transcript([
            Self.call(
                agent: "Agent B", input: "17 + 25",
                result: resolvedEnvelope(agentName: "Agent B", agentId: Self.writingID),
                step: 1
            )
        ])
        let assertion = EvalCase.AgentLoopExpectations.SpawnWaveAssertion(
            exactCallCount: 1,
            expectedTargets: [Self.writingID],
            expectedSucceeded: 1,
            expectedRows: [.init(target: Self.writingID, ok: true)]
        )
        let scored = EvalRunner.scoreSpawnWave(assertion, transcript: byName)
        #expect(scored.passed, "\(scored.note)")

        let wrongWorker = Self.transcript([
            Self.call(
                agent: "Agent A", input: "17 + 25",
                result: resolvedEnvelope(agentName: "Agent A", agentId: Self.mathID),
                step: 1
            )
        ])
        let wrong = EvalRunner.scoreSpawnWave(assertion, transcript: wrongWorker)
        #expect(!wrong.passed)
        #expect(wrong.note.contains("targets"))
    }

    @MainActor
    @Test func sequentialCallsAreTwoWavesNotOne() {
        let sequential = Self.transcript([
            Self.call(
                agent: Self.mathID, input: "a",
                result: Self.successEnvelope(model: "m", summary: "BATCH_ALPHA_42"), step: 1),
            Self.call(
                agent: Self.writingID, input: "b",
                result: Self.successEnvelope(model: "m", summary: "BATCH_BETA_BLUE"), step: 2),
        ])
        let oneWave = EvalCase.AgentLoopExpectations.SpawnWaveAssertion(expectedWaveSizes: [2])
        let twoWaves = EvalCase.AgentLoopExpectations.SpawnWaveAssertion(expectedWaveSizes: [1, 1])
        #expect(!EvalRunner.scoreSpawnWave(oneWave, transcript: sequential).passed)
        #expect(EvalRunner.scoreSpawnWave(twoWaves, transcript: sequential).passed)
        #expect(EvalRunner.scoreSpawnWave(oneWave, transcript: Self.twoCallWave()).passed)
        #expect(!EvalRunner.scoreSpawnWave(twoWaves, transcript: Self.twoCallWave()).passed)
    }

    @MainActor
    @Test func quotedMarkerInFailureExplanationDoesNotPassExactChildContract() {
        let assertion = EvalCase.AgentLoopExpectations.SpawnWaveAssertion(
            expectedRows: [
                .init(summaryEquals: "BATCH_ALPHA_42"),
                .init(summaryEquals: "BATCH_BETA_BLUE"),
            ]
        )
        #expect(EvalRunner.scoreSpawnWave(assertion, transcript: Self.twoCallWave()).passed)
        let bad = Self.transcript([
            Self.call(
                agent: Self.mathID, input: "a",
                result: Self.successEnvelope(
                    model: "m", summary: "I cannot calculate BATCH_ALPHA_42 without more context"),
                step: 1),
            Self.call(
                agent: Self.writingID, input: "b",
                result: Self.successEnvelope(model: "m", summary: "BATCH_BETA_BLUE"), step: 1),
        ])
        let scored = EvalRunner.scoreSpawnWave(assertion, transcript: bad)
        #expect(!scored.passed)
        #expect(scored.note.contains("exact expected output"))
    }

    @MainActor
    @Test func failedSiblingIsCountedAndRowDriftIsReported() {
        let assertion = EvalCase.AgentLoopExpectations.SpawnWaveAssertion(
            exactCallCount: 2,
            expectedSucceeded: 1,
            expectedFailed: 1,
            expectedRows: [
                .init(ok: true),
                .init(target: Self.writingID, ok: false, failureKind: "execution_error"),
            ]
        )
        #expect(EvalRunner.scoreSpawnWave(assertion, transcript: Self.twoCallWave(secondOK: false)).passed)
        let scored = EvalRunner.scoreSpawnWave(assertion, transcript: Self.twoCallWave())
        #expect(!scored.passed)
        #expect(scored.note.contains("failed 0 != 1"))
        #expect(scored.note.contains("row[1].ok"))
    }

    /// `continue` contract rows: row 0 is a NEEDS INPUT result carrying a
    /// session_id, row 1 continues THAT session (case-insensitive) and
    /// resolves. A second call that opens a fresh worker instead of
    /// continuing, or a row that lacks a session_id, must fail the row.
    @MainActor
    @Test func continueRowsScoreSessionIdNeedsInputAndContinuation() {
        let sessionId = UUID().uuidString
        let needsInput = ToolEnvelope.success(
            tool: "spawn_agent",
            result: [
                "kind": "spawn_result", "model": "m", "summary": "NEEDS INPUT: which color?",
                "session_id": sessionId, "needs_input": true,
            ])
        let resolved = ToolEnvelope.success(
            tool: "spawn_agent",
            result: [
                "kind": "spawn_result", "model": "m", "summary": "COLOR_BLUE",
                "session_id": sessionId, "needs_input": false,
            ])
        func continuing(_ id: String, result: String, step: Int) -> AgentLoopTranscript.ToolInvocation {
            let args = "{\"continue\":\"\(id)\",\"input\":\"blue\"}"
            return .init(
                name: "spawn_agent", arguments: args, resultPreview: String(result.prefix(300)),
                wasDeduped: false, wasError: false, step: step,
                spawnCall: AgentLoopTranscript.spawnCallObservation(
                    tool: "spawn_agent", arguments: args, result: result),
                spawnSummary: AgentLoopTranscript.spawnSummary(from: result, tool: "spawn_agent"))
        }
        let assertion = EvalCase.AgentLoopExpectations.SpawnWaveAssertion(
            exactCallCount: 2,
            expectedWaveSizes: [1, 1],
            expectedRows: [
                .init(ok: true, hasSessionId: true, needsInput: true),
                .init(ok: true, summaryEquals: "COLOR_BLUE", hasSessionId: true,
                      continuesEarlierRow: true, needsInput: false),
            ]
        )
        let good = Self.transcript([
            Self.call(agent: Self.mathID, input: "color token", result: needsInput, step: 1),
            continuing(sessionId.lowercased(), result: resolved, step: 2),
        ])
        let scored = EvalRunner.scoreSpawnWave(assertion, transcript: good)
        #expect(scored.passed, "\(scored.note)")

        // Fresh worker instead of `continue` → continuation row fails.
        let fresh = Self.transcript([
            Self.call(agent: Self.mathID, input: "color token", result: needsInput, step: 1),
            Self.call(agent: Self.mathID, input: "blue", result: resolved, step: 2),
        ])
        let freshScored = EvalRunner.scoreSpawnWave(assertion, transcript: fresh)
        #expect(!freshScored.passed)
        #expect(freshScored.note.contains("row[1]"))

        // `continue` pointing at an id no earlier row returned → fails.
        let stranger = Self.transcript([
            Self.call(agent: Self.mathID, input: "color token", result: needsInput, step: 1),
            continuing(UUID().uuidString, result: resolved, step: 2),
        ])
        #expect(!EvalRunner.scoreSpawnWave(assertion, transcript: stranger).passed)

        // needs_input flag mismatch (worker answered without asking) → row 0 fails.
        let noAsk = Self.transcript([
            Self.call(agent: Self.mathID, input: "color token", result: resolved, step: 1),
            continuing(sessionId, result: resolved, step: 2),
        ])
        let noAskScored = EvalRunner.scoreSpawnWave(assertion, transcript: noAsk)
        #expect(!noAskScored.passed)
        #expect(noAskScored.note.contains("needs_input"))

        // Background ack row: ok + session_id present, no summary.
        let ack = SubagentSession.backgroundAck(tool: "spawn_agent", helper: "Worker", sessionId: UUID())
        let ackAssertion = EvalCase.AgentLoopExpectations.SpawnWaveAssertion(
            exactCallCount: 1, expectedRows: [.init(ok: true, hasSessionId: true)])
        let ackTranscript = Self.transcript([
            Self.call(agent: Self.mathID, input: "bg", result: ack, step: 1)
        ])
        #expect(EvalRunner.scoreSpawnWave(ackAssertion, transcript: ackTranscript).passed)
        let noIdAck = SubagentSession.backgroundAck(tool: "spawn_agent", helper: "Worker", sessionId: nil)
        let noIdTranscript = Self.transcript([
            Self.call(agent: Self.mathID, input: "bg", result: noIdAck, step: 1)
        ])
        #expect(!EvalRunner.scoreSpawnWave(ackAssertion, transcript: noIdTranscript).passed)
    }

    @MainActor
    @Test func emptyTranscriptNeverPassesVacuously() {
        let assertion = EvalCase.AgentLoopExpectations.SpawnWaveAssertion()
        let scored = EvalRunner.scoreSpawnWave(assertion, transcript: Self.transcript([]))
        #expect(!scored.passed)
        #expect(scored.note.contains("no spawn_agent call was observed"))
    }

    @Test func productionFixtureDecodesAllowedTargetsAndNoSamplerOverrides() throws {
        let suite = try EvalSuite.load(
            from: Self.packageRoot.appendingPathComponent("Suites/AgentLoop")
        )
        let testCase = try #require(
            suite.cases.first { $0.id == "agent_loop.spawn-wave-two-configured-workers" }
        )
        let capabilities = try #require(testCase.fixtures.agentCapabilities)
        let runtimeConcurrency = try #require(testCase.fixtures.runtimeConcurrency)
        let expectation = try #require(testCase.expect.agentLoop)

        #expect(capabilities.spawnAgents?.map(\.name) == [
            "Osaurus Eval Wave Math",
            "Osaurus Eval Wave Writing",
        ])
        #expect(capabilities.spawnAgents?.compactMap { $0.id?.uuidString } == [
            Self.mathID, Self.writingID,
        ])
        #expect(capabilities.maxParallelSpawns == 2)
        #expect(capabilities.requestsAnyCapability)
        #expect(runtimeConcurrency.continuousBatching == true)
        #expect(runtimeConcurrency.maxConcurrentSequences == 2)
        #expect(expectation.enableThinking == nil)
        #expect(expectation.mustCallTools == ["spawn_agent"])
        #expect(expectation.mustNotCallTools == nil)
        #expect(expectation.maxToolCalls == 2)
        #expect(expectation.spawnWave?.exactCallCount == 2)
        #expect(expectation.spawnWave?.expectedTargets == [Self.mathID, Self.writingID])
        #expect(expectation.spawnWave?.expectedWaveSizes == [2])
        #expect(expectation.spawnWave?.expectedRows?.map(\.summaryEquals) == [
            "BATCH_ALPHA_42", "BATCH_BETA_BLUE",
        ])
        #expect(!testCase.query.contains("spawn_batch"))
        #expect(!testCase.query.contains("spawn_model"))
    }

    @Test func differentLocalFixtureDecodesExactModels() throws {
        let suite = try EvalSuite.load(
            from: Self.packageRoot.appendingPathComponent("Suites/AgentLoop")
        )
        let testCase = try #require(
            suite.cases.first { $0.id == "agent_loop.spawn-wave-two-different-local-workers" }
        )
        let capabilities = try #require(testCase.fixtures.agentCapabilities)
        let workers = try #require(capabilities.spawnAgents)
        let expectation = try #require(testCase.expect.agentLoop)

        #expect(workers.map(\.name) == [
            "Osaurus Eval Nanbeige Worker",
            "Osaurus Eval Ornith Worker",
        ])
        #expect(workers.map(\.modelId) == [
            "JANGQ-AI/Nanbeige4.2-3B-JANG_4M",
            "JANGQ-AI/Ornith-1.0-9B-JANG_4M",
        ])
        #expect(expectation.spawnWave?.expectedRows?.map(\.model) == [
            "JANGQ-AI/Nanbeige4.2-3B-JANG_4M",
            "JANGQ-AI/Ornith-1.0-9B-JANG_4M",
        ])
        #expect(expectation.spawnWave?.expectedRows?.map(\.target) == [
            "A11CE001-0000-4000-8000-000000000101",
            "A11CE001-0000-4000-8000-000000000102",
        ])
        #expect(expectation.spawnWave?.expectedWaveSizes == [2])
    }

    @Test func continuousBatchingOffFixtureKeepsWaveContract() throws {
        let suite = try EvalSuite.load(
            from: Self.packageRoot.appendingPathComponent("Suites/AgentLoop")
        )
        let testCase = try #require(
            suite.cases.first { $0.id == "agent_loop.spawn-wave-continuous-batching-off" }
        )
        #expect(testCase.fixtures.runtimeConcurrency?.continuousBatching == false)
        #expect(testCase.fixtures.runtimeConcurrency?.maxConcurrentSequences == 2)
        #expect(testCase.expect.agentLoop?.spawnWave?.expectedWaveSizes == [2])
        #expect(testCase.expect.agentLoop?.spawnWave?.expectedSucceeded == 2)
    }

    /// No suite may still reference the removed delegation tools.
    @Test func noSuiteReferencesRemovedSpawnTools() throws {
        let suitesRoot = Self.packageRoot.appendingPathComponent("Suites")
        let enumerator = FileManager.default.enumerator(atPath: suitesRoot.path)
        var offenders: [String] = []
        while let relative = enumerator?.nextObject() as? String {
            guard relative.hasSuffix(".json") else { continue }
            let url = suitesRoot.appendingPathComponent(relative)
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("spawn_batch") || text.contains("spawn_model") {
                offenders.append(relative)
            }
        }
        #expect(offenders.isEmpty, "suites still reference spawn_batch/spawn_model: \(offenders)")
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
