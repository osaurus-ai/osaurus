//
//  SpawnBatchToolTests.swift
//  OsaurusCoreTests
//
//  Model-free coverage for the explicit bounded batch contract. Live model
//  reuse, handoff, mixed local/remote fan-out, Stop, and UI persistence remain
//  Release-app acceptance rows.
//

import Foundation
import Testing

@testable import OsaurusCore

private actor BatchExecutionProbe {
    private var active = 0
    private var maxActive = 0
    private var total = 0

    func enter() {
        active += 1
        total += 1
        maxActive = max(maxActive, active)
    }

    func leave() {
        active = max(0, active - 1)
    }

    func snapshot() -> (maxActive: Int, total: Int) {
        (maxActive, total)
    }
}

private actor BatchHandoffCounter {
    private var count = 0

    func increment() { count += 1 }
    func snapshot() -> Int { count }
}

private struct CountingBatchHandoff: SubagentHandoff {
    private let counter = BatchHandoffCounter()

    func around(
        scope: SubagentScope,
        resolved: ResolvedModel,
        feed: SubagentFeed,
        run body: () async throws -> SubagentResult
    ) async throws -> SubagentResult {
        await counter.increment()
        return try await body()
    }

    func snapshot() async -> Int { await counter.snapshot() }
}

struct SpawnBatchToolTests {
    private final class ScriptedKind: SubagentKind, @unchecked Sendable {
        let capability = SubagentCapability(
            id: "batch-scripted",
            toolNames: ["batch-scripted"],
            gate: .delegation
        )
        let local: Bool
        let admission: SubagentAdmissionClass
        let probe: BatchExecutionProbe?
        let shouldFail: Bool

        init(
            local: Bool,
            admission: SubagentAdmissionClass,
            probe: BatchExecutionProbe? = nil,
            shouldFail: Bool = false
        ) {
            self.local = local
            self.admission = admission
            self.probe = probe
            self.shouldFail = shouldFail
        }

        func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
            ResolvedModel(name: "unused", isLocal: local)
        }

        func permission(
            _ scope: SubagentScope,
            _ resolved: ResolvedModel
        ) async -> SubagentDecision {
            .allow
        }

        func admissionClass(
            _ resolved: ResolvedModel
        ) -> SubagentAdmissionClass {
            admission
        }

        func run(
            _ scope: SubagentScope,
            _ resolved: ResolvedModel,
            feed: SubagentFeed,
            interrupt: InterruptToken
        ) async throws -> SubagentResult {
            if let probe {
                await probe.enter()
                try? await Task.sleep(for: .milliseconds(80))
                await probe.leave()
            }
            if shouldFail {
                throw BatchScriptedError.failed
            }
            return SubagentResult(payload: ["summary": "ok"])
        }
    }

    private enum BatchScriptedError: Error {
        case failed
    }

    private func prepared(
        index: Int,
        id: String,
        targetType: SpawnBatchTool.TargetType,
        target: String,
        model: String,
        isLocal: Bool,
        admission: SubagentAdmissionClass,
        probe: BatchExecutionProbe? = nil,
        shouldFail: Bool = false,
        handoff: any SubagentHandoff = PassthroughHandoff()
    ) -> SpawnBatchTool.PreparedJob {
        let kind = ScriptedKind(
            local: isLocal,
            admission: admission,
            probe: probe,
            shouldFail: shouldFail
        )
        let scope = SubagentScope(
            sessionId: "session",
            toolCallId: "call:\(id)",
            agentId: Agent.defaultId,
            enableThinking: true
        )
        return SpawnBatchTool.PreparedJob(
            job: SpawnBatchTool.Job(
                index: index,
                id: id,
                targetType: targetType,
                target: target,
                input: "task \(id)"
            ),
            run: PreparedSubagentRun(
                kind: kind,
                tool: "spawn_batch",
                scope: scope,
                resolved: ResolvedModel(
                    name: model,
                    isLocal: isLocal
                ),
                handoff: handoff
            )
        )
    }

    @Test("valid jobs preserve order and exact target kinds")
    func parsesValidJobs() throws {
        let parsed = SpawnBatchTool.parseJobs(
            """
            {
              "jobs": [
                {
                  "id": "alpha",
                  "target_type": "agent",
                  "target": "Researcher",
                  "input": "read A"
                },
                {
                  "id": "beta",
                  "target_type": "model",
                  "target": "remote/model",
                  "input": "read B"
                }
              ]
            }
            """,
            tool: "spawn_batch"
        )
        let jobs = try parsed.get()
        #expect(jobs.map(\.id) == ["alpha", "beta"])
        #expect(jobs.map(\.targetType) == [.agent, .model])
        #expect(jobs.map(\.index) == [0, 1])
    }

    @Test("duplicate ids and malformed targets fail before preparation")
    func rejectsMalformedJobs() {
        let duplicate = SpawnBatchTool.parseJobs(
            """
            {"jobs":[
              {"id":"same","target_type":"agent","target":"A","input":"x"},
              {"id":"same","target_type":"model","target":"M","input":"y"}
            ]}
            """,
            tool: "spawn_batch"
        )
        #expect(duplicate.failureEnvelope?.contains("duplicate id") == true)

        let badType = SpawnBatchTool.parseJobs(
            """
            {"jobs":[
              {"id":"a","target_type":"automatic","target":"A","input":"x"}
            ]}
            """,
            tool: "spawn_batch"
        )
        #expect(badType.failureEnvelope?.contains("agent") == true)
        #expect(badType.failureEnvelope?.contains("model") == true)

        let empty = SpawnBatchTool.parseJobs(
            #"{"jobs":[]}"#,
            tool: "spawn_batch"
        )
        #expect(empty.failureEnvelope?.contains("1-32") == true)
    }

    @Test("waves cap concurrency and never mix different local models")
    func boundedWavesRespectLocalResidency() {
        let jobs = [
            prepared(
                index: 0,
                id: "local-a-1",
                targetType: .model,
                target: "A",
                model: "Local-A",
                isLocal: true,
                admission: .localInPlace
            ),
            prepared(
                index: 1,
                id: "remote-1",
                targetType: .model,
                target: "cloud/one",
                model: "cloud/one",
                isLocal: false,
                admission: .remote
            ),
            prepared(
                index: 2,
                id: "local-b",
                targetType: .model,
                target: "B",
                model: "Local-B",
                isLocal: true,
                admission: .localInPlace
            ),
            prepared(
                index: 3,
                id: "local-a-2",
                targetType: .agent,
                target: "A helper",
                model: "local-a",
                isLocal: true,
                admission: .localInPlace
            ),
            prepared(
                index: 4,
                id: "remote-2",
                targetType: .model,
                target: "cloud/two",
                model: "cloud/two",
                isLocal: false,
                admission: .remote
            ),
        ]

        let waves = SpawnBatchTool.makeWaves(jobs, maxParallel: 3)
        #expect(waves.flatMap { $0 }.count == jobs.count)
        #expect(waves.allSatisfy { $0.count <= 3 })
        #expect(
            waves.allSatisfy { wave in
                Set(wave.compactMap(\.localGroupingKey)).count <= 1
            }
        )
        #expect(
            waves.first?.map(\.job.id)
                == ["local-a-1", "remote-1", "local-a-2"]
        )
        #expect(waves.dropFirst().first?.map(\.job.id) == ["local-b", "remote-2"])
    }

    @Test("request-local schema publishes only configured targets and limit")
    func constrainedSchemaUsesExactPool() throws {
        let base = SpawnBatchTool().asOpenAITool()
        let constrained = SpawnBatchTool.constrainedSpec(
            base,
            allowedAgentNames: [" Researcher ", "researcher", "Writer"],
            allowedModelIds: ["local/model", "cloud/model", "local/model"],
            maxParallel: 2
        )
        let params = try #require(constrained.function.parameters)
        guard case .object(let root) = params,
            case .object(let properties)? = root["properties"],
            case .object(let jobs)? = properties["jobs"],
            case .number(let maxItems)? = jobs["maxItems"],
            case .object(let items)? = jobs["items"],
            case .object(let jobProperties)? = items["properties"],
            case .object(let target)? = jobProperties["target"],
            case .array(let values)? = target["enum"]
        else {
            Issue.record("constrained spawn_batch schema has the wrong shape")
            return
        }
        #expect(maxItems == 2)
        let targetNames = values.compactMap { value -> String? in
            guard case .string(let name) = value else { return nil }
            return name
        }
        #expect(
            Set(targetNames)
                == Set([
                    "Researcher",
                    "Writer",
                    "cloud/model",
                    "local/model",
                ])
        )
    }

    @Test("configured fan-out rejects oversized batches before preparation")
    func configuredFanOutIsAnExecutionLimit() {
        #expect(
            SpawnBatchTool.batchLimitFailure(
                jobCount: 2,
                maxJobs: 2,
                tool: "spawn_batch"
            ) == nil
        )
        let rejected = SpawnBatchTool.batchLimitFailure(
            jobCount: 3,
            maxJobs: 2,
            tool: "spawn_batch"
        )
        #expect(rejected?.contains("at most 2 subagents per batch") == true)
        #expect(rejected?.contains(#""field":"jobs""#) == true)
        #expect(rejected?.contains(#""retryable":true"#) == true)
    }

    @Test("result rows retain ids and nested tool envelopes")
    func resultRowsAreDeterministic() {
        let job = SpawnBatchTool.Job(
            index: 0,
            id: "alpha",
            targetType: .model,
            target: "model-a",
            input: "x"
        )
        let row = SpawnBatchTool.resultRow(
            SpawnBatchTool.RawJobResult(
                job: job,
                envelope: ToolEnvelope.success(
                    tool: "spawn_batch",
                    result: ["summary": "done"]
                )
            )
        )
        #expect(row["id"] as? String == "alpha")
        #expect(row["ok"] as? Bool == true)
        #expect((row["envelope"] as? [String: Any])?["ok"] as? Bool == true)
    }

    @Test("two same-local jobs and one remote overlap under one local handoff")
    func executionGroupsLocalAndOverlapsRemote() async {
        let probe = BatchExecutionProbe()
        let handoff = CountingBatchHandoff()
        let jobs = [
            prepared(
                index: 0,
                id: "local-1",
                targetType: .model,
                target: "Local-A",
                model: "Local-A",
                isLocal: true,
                admission: .localExclusive,
                probe: probe,
                handoff: handoff
            ),
            prepared(
                index: 1,
                id: "local-2",
                targetType: .agent,
                target: "Worker A",
                model: "local-a",
                isLocal: true,
                admission: .localExclusive,
                probe: probe,
                handoff: handoff
            ),
            prepared(
                index: 2,
                id: "remote",
                targetType: .model,
                target: "cloud/model",
                model: "cloud/model",
                isLocal: false,
                admission: .remote,
                probe: probe
            ),
        ]
        let results = await SpawnBatchTool.runPreparedJobs(
            jobs,
            maxParallel: 3,
            feed: SubagentFeed(
                toolCallId: "batch-parent",
                kindId: "spawn",
                title: "batch"
            ),
            interrupt: InterruptToken(),
            tool: "spawn_batch"
        )
        let execution = await probe.snapshot()

        #expect(results.count == 3)
        #expect(results.allSatisfy { $0.envelope.contains(#""ok":true"#) })
        #expect(execution.total == 3)
        #expect(execution.maxActive == 3)
        #expect(await handoff.snapshot() == 1)
    }

    @Test("one failed job stays isolated and preserves sibling results")
    func failedJobDoesNotCancelSiblings() async {
        let jobs = [
            prepared(
                index: 0,
                id: "ok",
                targetType: .model,
                target: "cloud/ok",
                model: "cloud/ok",
                isLocal: false,
                admission: .remote
            ),
            prepared(
                index: 1,
                id: "failed",
                targetType: .model,
                target: "cloud/failed",
                model: "cloud/failed",
                isLocal: false,
                admission: .remote,
                shouldFail: true
            ),
        ]
        let results = await SpawnBatchTool.runPreparedJobs(
            jobs,
            maxParallel: 2,
            feed: SubagentFeed(
                toolCallId: "batch-parent",
                kindId: "spawn",
                title: "batch"
            ),
            interrupt: InterruptToken(),
            tool: "spawn_batch"
        ).sorted { $0.job.index < $1.job.index }

        #expect(results.count == 2)
        #expect(results[0].envelope.contains(#""ok":true"#))
        #expect(results[1].envelope.contains(#""ok":false"#))
    }

    @Test("pre-interrupted batch starts no jobs and returns every row")
    func cancellationBeforeFirstWave() async {
        let probe = BatchExecutionProbe()
        let jobs = [
            prepared(
                index: 0,
                id: "a",
                targetType: .model,
                target: "cloud/a",
                model: "cloud/a",
                isLocal: false,
                admission: .remote,
                probe: probe
            ),
            prepared(
                index: 1,
                id: "b",
                targetType: .model,
                target: "cloud/b",
                model: "cloud/b",
                isLocal: false,
                admission: .remote,
                probe: probe
            ),
        ]
        let interrupt = InterruptToken()
        interrupt.interrupt()
        let results = await SpawnBatchTool.runPreparedJobs(
            jobs,
            maxParallel: 2,
            feed: SubagentFeed(
                toolCallId: "batch-parent",
                kindId: "spawn",
                title: "batch"
            ),
            interrupt: interrupt,
            tool: "spawn_batch"
        )
        let execution = await probe.snapshot()

        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.envelope.contains("cancelled") })
        #expect(execution.total == 0)
    }
}
