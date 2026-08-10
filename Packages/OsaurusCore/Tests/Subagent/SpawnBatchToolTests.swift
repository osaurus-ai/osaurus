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

private actor BatchLaneProbe {
    private var activeLocalModels: [String: Int] = [:]
    private var observedLocalModels: Set<String> = []
    private var activeRemote = 0
    private var maxConcurrentLocalModels = 0
    private var sawRemoteLocalOverlap = false
    private var sawSecondLocalModelWhileRemoteActive = false

    func enter(model: String, isLocal: Bool) {
        if isLocal {
            activeLocalModels[model, default: 0] += 1
            observedLocalModels.insert(model)
            if activeRemote > 0, observedLocalModels.count >= 2 {
                sawSecondLocalModelWhileRemoteActive = true
            }
        } else {
            activeRemote += 1
        }
        maxConcurrentLocalModels = max(
            maxConcurrentLocalModels,
            activeLocalModels.values.filter { $0 > 0 }.count
        )
        if activeRemote > 0, activeLocalModels.values.contains(where: { $0 > 0 }) {
            sawRemoteLocalOverlap = true
        }
    }

    func leave(model: String, isLocal: Bool) {
        if isLocal {
            let next = max(0, (activeLocalModels[model] ?? 0) - 1)
            activeLocalModels[model] = next
        } else {
            activeRemote = max(0, activeRemote - 1)
        }
    }

    func snapshot() -> (
        maxConcurrentLocalModels: Int,
        sawRemoteLocalOverlap: Bool,
        sawSecondLocalModelWhileRemoteActive: Bool
    ) {
        (
            maxConcurrentLocalModels,
            sawRemoteLocalOverlap,
            sawSecondLocalModelWhileRemoteActive
        )
    }
}

private actor BatchHandoffCounter {
    private var count = 0

    func increment() { count += 1 }
    func snapshot() -> Int { count }
}

private actor BatchLivePlanProbe {
    private var calls = 0

    func record() {
        calls += 1
    }

    func nextCall() -> Int {
        calls += 1
        return calls
    }

    func snapshot() -> Int {
        calls
    }
}

private actor BatchExecutionAuthorityProbe {
    private var revoked = false
    private var validations = 0
    private var runs = 0

    func revoke() {
        revoked = true
    }

    func validate() throws {
        validations += 1
        if revoked {
            throw SubagentError.denied(
                "batch authority revoked while waiting for admission"
            )
        }
    }

    func recordRun() {
        runs += 1
    }

    func snapshot() -> (validations: Int, runs: Int) {
        (validations, runs)
    }
}

private actor BatchTransitionProbe {
    private var transitions: [String] = []
    private var admissionTransitionCounts: [Int] = []
    private var transitionFinished = false

    func recordTransition(previous: String, next: String) {
        transitions.append("\(previous)->\(next)")
    }

    func recordAdmission() {
        admissionTransitionCounts.append(transitions.count)
    }

    func finishTransition() {
        transitionFinished = true
    }

    func snapshot() -> (
        transitions: [String],
        admissionTransitionCounts: [Int],
        transitionFinished: Bool
    ) {
        (transitions, admissionTransitionCounts, transitionFinished)
    }
}

private actor BatchParentLifecycleProbe {
    private var unloads = 0
    private var restores = 0

    func recordUnload() {
        unloads += 1
    }

    func recordRestore() {
        restores += 1
    }

    func snapshot() -> (unloads: Int, restores: Int) {
        (unloads, restores)
    }
}

private actor BatchResidencyOrderProbe {
    private var steps: [String] = []

    func record(_ step: String) {
        steps.append(step)
    }

    func snapshot() -> [String] {
        steps
    }
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

private struct OrderedLifecycleBatchHandoff: SubagentHandoff {
    let probe: BatchResidencyOrderProbe

    func around(
        scope: SubagentScope,
        resolved: ResolvedModel,
        feed: SubagentFeed,
        run body: () async throws -> SubagentResult
    ) async throws -> SubagentResult {
        await probe.record("parent-unload")
        do {
            let result = try await body()
            await probe.record("parent-restore")
            return result
        } catch {
            await probe.record("parent-restore")
            throw error
        }
    }
}

private struct BatchRestoreFailure: Error, LocalizedError {
    var errorDescription: String? { "parent restore failed" }
}

private struct RestoreFailingBatchHandoff: SubagentHandoff {
    func around(
        scope: SubagentScope,
        resolved: ResolvedModel,
        feed: SubagentFeed,
        run body: () async throws -> SubagentResult
    ) async throws -> SubagentResult {
        _ = try await body()
        throw BatchRestoreFailure()
    }
}

private struct LifecycleBatchHandoff: SubagentHandoff {
    let probe: BatchParentLifecycleProbe

    func around(
        scope: SubagentScope,
        resolved: ResolvedModel,
        feed: SubagentFeed,
        run body: () async throws -> SubagentResult
    ) async throws -> SubagentResult {
        await probe.recordUnload()
        do {
            let result = try await body()
            await probe.recordRestore()
            return result
        } catch {
            await probe.recordRestore()
            throw error
        }
    }
}

@Suite(.serialized)
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
        let laneProbe: BatchLaneProbe?
        let shouldFail: Bool
        let delayMilliseconds: Int
        let emitsChannelDeltas: Bool
        let authorityProbe: BatchExecutionAuthorityProbe?

        init(
            local: Bool,
            admission: SubagentAdmissionClass,
            probe: BatchExecutionProbe? = nil,
            laneProbe: BatchLaneProbe? = nil,
            shouldFail: Bool = false,
            delayMilliseconds: Int = 80,
            emitsChannelDeltas: Bool = false,
            authorityProbe: BatchExecutionAuthorityProbe? = nil
        ) {
            self.local = local
            self.admission = admission
            self.probe = probe
            self.laneProbe = laneProbe
            self.shouldFail = shouldFail
            self.delayMilliseconds = delayMilliseconds
            self.emitsChannelDeltas = emitsChannelDeltas
            self.authorityProbe = authorityProbe
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

        func validateExecutionAuthority(
            _ scope: SubagentScope,
            resolved: ResolvedModel
        ) async throws {
            try await authorityProbe?.validate()
        }

        func run(
            _ scope: SubagentScope,
            _ resolved: ResolvedModel,
            feed: SubagentFeed,
            interrupt: InterruptToken
        ) async throws -> SubagentResult {
            await authorityProbe?.recordRun()
            feed.emitPhase("scripted start", detail: resolved.name)
            if emitsChannelDeltas {
                feed.emitStreamDelta(
                    kind: .reasoning,
                    title: "reasoning",
                    delta: "think "
                )
                feed.emitStreamDelta(
                    kind: .reasoning,
                    title: "reasoning",
                    delta: "again"
                )
                feed.emitStreamDelta(
                    kind: .response,
                    title: "response",
                    delta: "answer"
                )
            }
            if let laneProbe {
                await laneProbe.enter(model: resolved.name, isLocal: resolved.isLocal)
            }
            if let probe {
                await probe.enter()
            }
            if probe != nil || laneProbe != nil {
                do {
                    try await Task.sleep(for: .milliseconds(delayMilliseconds))
                } catch {
                    if let probe {
                        await probe.leave()
                    }
                    if let laneProbe {
                        await laneProbe.leave(
                            model: resolved.name,
                            isLocal: resolved.isLocal
                        )
                    }
                    throw error
                }
            }
            if let probe {
                await probe.leave()
            }
            if let laneProbe {
                await laneProbe.leave(model: resolved.name, isLocal: resolved.isLocal)
            }
            if interrupt.isInterrupted || Task.isCancelled {
                throw CancellationError()
            }
            if shouldFail {
                throw BatchScriptedError.failed
            }
            feed.emitPhase("scripted complete", detail: resolved.name)
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
        modelID: String? = nil,
        isLocal: Bool,
        admission: SubagentAdmissionClass,
        probe: BatchExecutionProbe? = nil,
        laneProbe: BatchLaneProbe? = nil,
        shouldFail: Bool = false,
        delayMilliseconds: Int = 80,
        emitsChannelDeltas: Bool = false,
        authorityProbe: BatchExecutionAuthorityProbe? = nil,
        handoff: any SubagentHandoff = PassthroughHandoff(),
        parentModelName: String? = nil
    ) -> SpawnBatchTool.PreparedJob {
        let kind = ScriptedKind(
            local: isLocal,
            admission: admission,
            probe: probe,
            laneProbe: laneProbe,
            shouldFail: shouldFail,
            delayMilliseconds: delayMilliseconds,
            emitsChannelDeltas: emitsChannelDeltas,
            authorityProbe: authorityProbe
        )
        let scope = SubagentScope(
            sessionId: "session",
            toolCallId: "call:\(id)",
            agentId: Agent.defaultId,
            parentModelName: parentModelName,
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
                    id: modelID,
                    isLocal: isLocal
                ),
                handoff: handoff
            )
        )
    }

    @Test("one batch feed relays ordered child channels without a child Stop owner")
    func batchRelayUpdatesStreamingRowsInPlace() async {
        let parentFeed = SubagentFeed(
            toolCallId: "batch-parent-\(UUID().uuidString)",
            kindId: "spawn",
            title: "batch"
        )
        let interrupt = InterruptToken()
        let child = prepared(
            index: 0,
            id: "alpha",
            targetType: .model,
            target: "remote/model",
            model: "remote/model",
            isLocal: false,
            admission: .remote,
            emitsChannelDeltas: true
        )

        let result = await SpawnBatchTool.runOne(
            child,
            feed: parentFeed,
            interrupt: interrupt,
            skipAdmission: true
        )

        #expect(ToolEnvelope.isSuccess(result.envelope))
        let events = parentFeed.currentEvents()
        let reasoningIndex = events.firstIndex {
            $0.kind == .reasoning && $0.title == "job alpha · reasoning"
        }
        let responseIndex = events.firstIndex {
            $0.kind == .response && $0.title == "job alpha · response"
        }
        let outcomeIndex = events.firstIndex {
            $0.kind == .outcome && $0.title == "job alpha finished"
        }
        #expect(reasoningIndex != nil)
        #expect(responseIndex != nil)
        #expect(outcomeIndex != nil)
        if let reasoningIndex, let responseIndex, let outcomeIndex {
            #expect(events[reasoningIndex].detail == "think again")
            #expect(reasoningIndex < responseIndex)
            #expect(responseIndex < outcomeIndex)
        }

        let childToolCallID = child.run.scope.toolCallId
        #expect(SubagentFeedRegistry.shared.feed(for: childToolCallID) == nil)
        #expect(SubagentInterruptCenter.shared.interrupt(childToolCallID) == false)
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
                  "target": "00000000-0000-4000-8000-000000000097",
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

    @Test("unknown fields, duplicate ids, and malformed targets fail before preparation")
    func rejectsMalformedJobs() {
        let staleRootSetting = SpawnBatchTool.parseJobs(
            #"{"jobs":[{"id":"a","target_type":"model","target":"M","input":"x"}],"max_parallel":2}"#,
            tool: "spawn_batch"
        )
        #expect(staleRootSetting.failureEnvelope?.contains("max_parallel") == true)
        #expect(staleRootSetting.failureEnvelope?.contains("Unsupported") == true)

        let unknownJobSetting = SpawnBatchTool.parseJobs(
            #"{"jobs":[{"id":"a","target_type":"model","target":"M","input":"x","temperature":0.2}]}"#,
            tool: "spawn_batch"
        )
        #expect(unknownJobSetting.failureEnvelope?.contains("temperature") == true)
        #expect(unknownJobSetting.failureEnvelope?.contains("unsupported") == true)

        let duplicate = SpawnBatchTool.parseJobs(
            """
            {"jobs":[
              {"id":"same","target_type":"agent","target":"00000000-0000-4000-8000-000000000096","input":"x"},
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

    @Test("local groups preserve model order and leave remotes in their own lane")
    func localGroupsPreserveModelOrder() {
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

        let groups = SpawnBatchTool.makeLocalGroups(jobs)
        #expect(groups.flatMap { $0 }.count == 3)
        #expect(
            groups.allSatisfy { group in
                Set(group.compactMap(\.localGroupingKey)).count == 1
            }
        )
        #expect(
            groups.first?.map(\.job.id)
                == ["local-a-1", "local-a-2"]
        )
        #expect(groups.dropFirst().first?.map(\.job.id) == ["local-b"])
        #expect(
            Set(groups.flatMap { $0.map(\.job.id) }).isDisjoint(
                with: Set(["remote-1", "remote-2"])
            )
        )
    }

    @Test("request-local schema publishes only configured targets and limit")
    func constrainedSchemaUsesExactPool() throws {
        let researcherID = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
        let writerID = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000002")!
        let base = SpawnBatchTool().asOpenAITool()
        let constrained = SpawnBatchTool.constrainedSpec(
            base,
            allowedAgentIDs: [researcherID, researcherID, writerID],
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
                    researcherID.uuidString,
                    writerID.uuidString,
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

    @Test("aggregate status distinguishes success, partial failure, and all failed")
    func aggregateStatusIsExplicit() {
        #expect(
            SpawnBatchTool.aggregateStatus(succeeded: 3, failed: 0)
                == "succeeded"
        )
        #expect(
            SpawnBatchTool.aggregateStatus(succeeded: 2, failed: 1)
                == "partial_failure"
        )
        #expect(
            SpawnBatchTool.aggregateStatus(succeeded: 0, failed: 3)
                == "all_failed"
        )
        #expect(
            SpawnBatchTool.aggregateStatus(
                succeeded: 0,
                failed: 3,
                cancelled: 3
            ) == "all_cancelled"
        )
    }

    @Test("early cancellation keeps cause semantics and publishes its marker")
    func earlyCancellationEnvelopeIsMachineReadable() throws {
        for (userInterrupted, expectedKind) in [
            (true, "user_denied"),
            (false, "execution_error"),
        ] {
            let envelope = SpawnBatchTool.earlyCancellationEnvelope(
                tool: "spawn_batch",
                userInterrupted: userInterrupted
            )
            let object = try #require(
                JSONSerialization.jsonObject(
                    with: Data(envelope.utf8)
                ) as? [String: Any]
            )
            #expect(object["kind"] as? String == expectedKind)
            #expect(object["cancelled"] as? Bool == true)
            #expect(object["retryable"] as? Bool == false)
        }
    }

    @Test("aggregate envelope fails only when every child failed")
    func aggregateEnvelopeReflectsTerminalChildren() throws {
        let succeededRow: [String: Any] = [
            "id": "ok",
            "envelope": [
                "ok": true,
                "result": ["summary": "done"],
            ],
        ]
        let failedRow: [String: Any] = [
            "id": "failed",
            "envelope": [
                "ok": false,
                "kind": "unavailable",
                "message": "worker unavailable",
                "retryable": true,
            ],
        ]

        let partialPayload: [String: Any] = [
            "summary": "2 jobs finished",
            "aggregate_status": "partial_failure",
            "results": [succeededRow, failedRow],
        ]
        let partial = SpawnBatchTool.aggregateEnvelope(
            tool: "spawn_batch",
            payload: partialPayload,
            rows: [succeededRow, failedRow],
            succeeded: 1,
            failed: 1
        )
        #expect(ToolEnvelope.isSuccess(partial))

        let allFailedPayload: [String: Any] = [
            "summary": "2 jobs failed",
            "aggregate_status": "all_failed",
            "results": [failedRow, failedRow],
        ]
        let allFailed = SpawnBatchTool.aggregateEnvelope(
            tool: "spawn_batch",
            payload: allFailedPayload,
            rows: [failedRow, failedRow],
            succeeded: 0,
            failed: 2
        )
        #expect(ToolEnvelope.isError(allFailed))
        let result = try #require(
            ToolEnvelope.resultPayload(allFailed) as? [String: Any]
        )
        #expect(result["aggregate_status"] as? String == "all_failed")
        #expect((result["results"] as? [[String: Any]])?.count == 2)
    }

    @Test("aggregate retryability requires every failed child to be retryable")
    func aggregateRetryabilityIsConservative() throws {
        let retryableRow: [String: Any] = [
            "envelope": [
                "ok": false,
                "kind": "unavailable",
                "message": "later",
                "retryable": true,
            ]
        ]
        let deniedRow: [String: Any] = [
            "envelope": [
                "ok": false,
                "kind": "user_denied",
                "message": "no",
                "retryable": false,
            ]
        ]
        let envelope = SpawnBatchTool.aggregateEnvelope(
            tool: "spawn_batch",
            payload: ["summary": "all failed"],
            rows: [retryableRow, deniedRow],
            succeeded: 0,
            failed: 2
        )
        let data = try #require(envelope.data(using: .utf8))
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(root["ok"] as? Bool == false)
        #expect(root["kind"] as? String == "execution_error")
        #expect(root["retryable"] as? Bool == false)
    }

    @Test("batch cache diagnostics report exact aggregate boundary and deltas")
    func cacheDiagnosticsAreAggregateDeltas() throws {
        let before = BatchDiagnosticsSnapshot(
            pendingCount: 0,
            activeCount: 0,
            activeHighWatermark: 1,
            decodeSplitCount: 0,
            turboQuantCompressions: 0,
            isAcceptingRequests: true,
            loadedModelCount: 1,
            prefixHits: 10,
            prefixMisses: 4,
            pagedEvictions: 2,
            diskL2Hits: 7,
            diskL2Misses: 5,
            diskL2Stores: 3,
            ssmCompanionHits: 6,
            ssmCompanionMisses: 2,
            ssmCompanionReDerives: 1
        )
        let after = BatchDiagnosticsSnapshot(
            pendingCount: 0,
            activeCount: 0,
            activeHighWatermark: 3,
            decodeSplitCount: 0,
            turboQuantCompressions: 0,
            isAcceptingRequests: true,
            loadedModelCount: 2,
            prefixHits: 14,
            prefixMisses: 5,
            pagedEvictions: 4,
            diskL2Hits: 10,
            diskL2Misses: 7,
            diskL2Stores: 8,
            ssmCompanionHits: 9,
            ssmCompanionMisses: 3,
            ssmCompanionReDerives: 3
        )

        let payload = SpawnBatchTool.BatchCacheDiagnostic(
            before: before,
            after: after
        ).payload
        #expect(payload["available"] as? Bool == true)
        #expect(payload["active_before"] as? Int == before.activeCount)
        #expect(payload["active_after"] as? Int == after.activeCount)
        #expect(payload["pending_before"] as? Int == before.pendingCount)
        #expect(payload["pending_after"] as? Int == after.pendingCount)
        #expect(
            payload["process_lifetime_active_high_watermark_before"] as? Int == 1
        )
        #expect(
            payload["process_lifetime_active_high_watermark_after"] as? Int == 3
        )
        #expect(
            payload["high_watermark_scope"] as? String
                == "process_lifetime_not_batch_scoped"
        )
        #expect(payload["loaded_models_before"] as? Int == 1)
        #expect(payload["loaded_models_after"] as? Int == 2)

        let boundaryBefore = try #require(payload["before"] as? [String: Int])
        let boundaryAfter = try #require(payload["after"] as? [String: Int])
        let delta = try #require(payload["delta"] as? [String: Int])
        #expect(boundaryBefore["disk_l2_hits"] == 7)
        #expect(boundaryAfter["disk_l2_hits"] == 10)
        #expect(delta["prefix_hits"] == 4)
        #expect(delta["prefix_misses"] == 1)
        #expect(delta["paged_evictions"] == 2)
        #expect(delta["disk_l2_hits"] == 3)
        #expect(delta["disk_l2_misses"] == 2)
        #expect(delta["disk_l2_stores"] == 5)
        #expect(delta["ssm_companion_hits"] == 3)
        #expect(delta["ssm_companion_misses"] == 1)
        #expect(delta["ssm_companion_rederives"] == 2)
    }

    @Test("batch cache diagnostics never fabricate missing snapshots")
    func cacheDiagnosticsFailClosedWhenUnavailable() {
        let payload = SpawnBatchTool.BatchCacheDiagnostic(
            before: nil,
            after: nil
        ).payload
        #expect(payload["available"] as? Bool == false)
        #expect(payload["before_available"] as? Bool == false)
        #expect(payload["after_available"] as? Bool == false)
        #expect(payload["before"] == nil)
        #expect(payload["delta"] == nil)
    }

    @Test("cold engine admission uses the configured maximum without queueing")
    func coldEngineAdmissionUsesConfiguredMaximum() {
        let window = SpawnBatchTool.engineAdmissionWindow(
            configuredMaximum: 4,
            snapshot: nil
        )

        #expect(window.parallelLimit == 4)
        #expect(window.queued == false)
    }

    @Test("one free live engine slot admits one child without queueing")
    func liveEngineAdmissionUsesNominalAvailability() {
        let window = SpawnBatchTool.engineAdmissionWindow(
            configuredMaximum: 4,
            snapshot: ModelBatchCapacitySnapshot(
                modelName: "Local-A",
                configuredMaximum: 4,
                activeCount: 3,
                pendingCount: 0,
                nominalAvailableCount: 1,
                activeHighWatermark: 3,
                isAcceptingRequests: true,
                isShutdown: false
            )
        )

        #expect(window.parallelLimit == 1)
        #expect(window.queued == false)
    }

    @Test("saturated engine queues exactly one child")
    func saturatedEngineAdmissionQueuesOneChild() {
        let window = SpawnBatchTool.engineAdmissionWindow(
            configuredMaximum: 4,
            snapshot: ModelBatchCapacitySnapshot(
                modelName: "Local-A",
                configuredMaximum: 4,
                activeCount: 4,
                pendingCount: 0,
                nominalAvailableCount: 0,
                activeHighWatermark: 4,
                isAcceptingRequests: true,
                isShutdown: false
            )
        )

        #expect(window.parallelLimit == 1)
        #expect(window.queued)
    }

    @Test("non-accepting engine queues exactly one child")
    func nonAcceptingEngineAdmissionQueuesOneChild() {
        let window = SpawnBatchTool.engineAdmissionWindow(
            configuredMaximum: 4,
            snapshot: ModelBatchCapacitySnapshot(
                modelName: "Local-A",
                configuredMaximum: 4,
                activeCount: 0,
                pendingCount: 0,
                nominalAvailableCount: 4,
                activeHighWatermark: 1,
                isAcceptingRequests: false,
                isShutdown: false
            )
        )

        #expect(window.parallelLimit == 1)
        #expect(window.queued)
    }

    @Test("execution diagnostics report effective local slots and subwaves")
    func executionDiagnosticsReportCapacity() async {
        let diagnostics = SpawnBatchTool.BatchDiagnosticsCollector()
        let jobs = [
            prepared(
                index: 0,
                id: "local-1",
                targetType: .model,
                target: "Local-A",
                model: "Local-A",
                isLocal: true,
                admission: .localExclusive
            ),
            prepared(
                index: 1,
                id: "local-2",
                targetType: .model,
                target: "Local-A",
                model: "Local-A",
                isLocal: true,
                admission: .localExclusive
            ),
            prepared(
                index: 2,
                id: "remote",
                targetType: .model,
                target: "cloud/model",
                model: "cloud/model",
                isLocal: false,
                admission: .remote
            ),
        ]

        _ = await SpawnBatchTool.runPreparedJobs(
            jobs,
            maxParallel: 3,
            feed: SubagentFeed(
                toolCallId: "batch-diagnostics",
                kindId: "spawn",
                title: "batch"
            ),
            interrupt: InterruptToken(),
            tool: "spawn_batch",
            localParallelismOverride: 1,
            diagnostics: diagnostics
        )

        let rows = await diagnostics.snapshot()
        #expect(rows.count == 1)
        #expect(rows[0].jobs == 3)
        #expect(rows[0].remoteJobs == 1)
        #expect(rows[0].localJobs == 2)
        #expect(rows[0].effectiveLocalSlots == 1)
        #expect(rows[0].localSubwaveSizes == [1, 1])
        #expect(rows[0].verdict == "admitted")
    }

    @Test("same-resident local batching retains RAM safety and computed slots")
    func sameResidentBatchUsesGlobalRAMSafety() throws {
        let gib = UInt64(1_073_741_824)
        let residency = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "Local-A",
            residentChatModels: ["local-a"],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: Int64(4 * gib),
            idleWaitSeconds: 120,
            deniedMessage: "unused"
        )
        #expect(residency.shouldUnload == false)
        #expect(residency.ramSafetyEnabled)
        #expect(residency.requiredBytes == Int64(4 * gib))

        let admission = SpawnBatchTool.makeLocalAdmissionPlan(
            localJobCount: 3,
            remoteJobCount: 0,
            maxParallel: 3,
            engineParallelLimit: 3,
            continuousBatchingEnabled: true,
            residencyPlan: residency,
            memoryFacts: SubagentBatchMemoryFacts(
                canonicalModelKey: "local-a",
                targetAlreadyResident: true,
                targetLoadFootprintBytes: 4 * gib,
                perActiveChildHeadroomBytes: 2 * gib,
                reclaimableBytes: 5 * gib,
                releasableParentBytes: 0,
                resolvedLoadBudgetBytes: 6 * gib,
                osHeadroomBytes: 3 * gib
            ),
            failClosedWhenEstimateUnknown: true
        )

        #expect(admission.verdict == .admitted)
        #expect(admission.ramSlots == 1)
        #expect(admission.localParallelism == 1)
        #expect(admission.localSubwaveSizes == [1, 1, 1])
        #expect(admission.limitingFactors.contains(.memoryCapacity))
    }

    @Test("queued local batch revalidates authority before handoff or execution")
    func queuedLocalBatchRejectsRevokedAuthority() async {
        let admission = SubagentAdmission(pollNanoseconds: 1_000_000)
        #expect(
            await admission.admit(
                .localExclusive,
                modelKey: "authority-blocker"
            ) == .admitted
        )

        let authority = BatchExecutionAuthorityProbe()
        let handoff = CountingBatchHandoff()
        let feed = SubagentFeed(
            toolCallId: "batch-queued-authority",
            kindId: "spawn",
            title: "batch"
        )
        let jobs = [
            prepared(
                index: 0,
                id: "local",
                targetType: .model,
                target: "Local-A",
                model: "Local-A",
                isLocal: true,
                admission: .localExclusive,
                authorityProbe: authority,
                handoff: handoff
            )
        ]

        let task = Task {
            await SpawnBatchTool.runLocalSequence(
                jobs,
                remoteJobCount: 0,
                maxParallel: 1,
                localParallelismOverride: 1,
                feed: feed,
                interrupt: InterruptToken(),
                tool: "spawn_batch",
                diagnostics: nil,
                admissionController: admission
            )
        }

        let deadline = Date().addingTimeInterval(2)
        while !feed.currentEvents().contains(
            where: { $0.title == "waiting for local GPU" }
        ), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(
            feed.currentEvents().contains {
                $0.title == "waiting for local GPU"
            }
        )

        await authority.revoke()
        await admission.release(
            .localExclusive,
            modelKey: "authority-blocker"
        )

        let results = await task.value
        let authoritySnapshot = await authority.snapshot()
        #expect(results.count == 1)
        #expect(ToolEnvelope.isError(results[0].envelope))
        #expect(
            ToolEnvelope.failureMessage(results[0].envelope).contains(
                "batch authority revoked while waiting for admission"
            )
        )
        #expect(authoritySnapshot.validations == 1)
        #expect(authoritySnapshot.runs == 0)
        #expect(await handoff.snapshot() == 0)
        let finalAdmission = await admission.snapshot()
        #expect(finalAdmission.exclusive == 0)
        #expect(finalAdmission.inPlace == 0)
    }

    @Test("local capacity and handoff plan refresh only after admission wait")
    func localPlanRefreshesAfterAdmission() async {
        let admission = SubagentAdmission(pollNanoseconds: 1_000_000)
        let blocker = await admission.admit(
            .localInPlace,
            modelKey: "other-local"
        )
        #expect(blocker == .admitted)

        let probe = BatchLivePlanProbe()
        let diagnostics = SpawnBatchTool.BatchDiagnosticsCollector()
        let jobs = [
            prepared(
                index: 0,
                id: "local",
                targetType: .model,
                target: "Local-A",
                model: "Local-A",
                isLocal: true,
                admission: .localInPlace
            )
        ]
        let task = Task {
            await SpawnBatchTool.runLocalGroup(
                jobs,
                waveIndex: 1,
                remoteJobCount: 0,
                maxParallel: 1,
                localParallelismOverride: 1,
                feed: SubagentFeed(
                    toolCallId: "batch-live-plan",
                    kindId: "spawn",
                    title: "batch"
                ),
                interrupt: InterruptToken(),
                tool: "spawn_batch",
                diagnostics: diagnostics,
                admissionController: admission,
                liveResidencyPlanOverride: { _ in
                    await probe.record()
                    return .none
                }
            )
        }

        try? await Task.sleep(for: .milliseconds(30))
        #expect(await probe.snapshot() == 0)
        await admission.release(.localInPlace, modelKey: "other-local")

        let results = await task.value
        let rows = await diagnostics.snapshot()
        #expect(results.count == 1)
        #expect(results[0].envelope.contains(#""ok":true"#))
        #expect(await probe.snapshot() == 1)
        #expect(rows.count == 1)
        #expect(rows[0].verdict == "admitted")
        #expect(rows[0].admissionWaitSeconds != nil)
        #expect(
            rows[0].payload["capacity_snapshot"] as? String
                == "post_admission_capacity_plan"
        )
        let snapshot = await admission.snapshot()
        #expect(snapshot.exclusive == 0)
        #expect(snapshot.inPlace == 0)
    }

    @Test("fresh post-admission capacity shrinks the scheduled local width")
    func localPlanCapacityShrinkResizesReservation() async {
        let admission = SubagentAdmission(pollNanoseconds: 1_000_000)
        let execution = BatchExecutionProbe()
        let planCalls = BatchLivePlanProbe()
        let diagnostics = SpawnBatchTool.BatchDiagnosticsCollector()
        let jobs = (0 ..< 2).map { index in
            prepared(
                index: index,
                id: "local-\(index)",
                targetType: .model,
                target: "Local-A",
                model: "Local-A",
                modelID: "Org/Local-A",
                isLocal: true,
                admission: .localInPlace,
                probe: execution,
                delayMilliseconds: 50
            )
        }

        let results = await SpawnBatchTool.runLocalGroup(
            jobs,
            waveIndex: 1,
            remoteJobCount: 0,
            maxParallel: 2,
            localParallelismOverride: 2,
            feed: SubagentFeed(
                toolCallId: "batch-capacity-shrink",
                kindId: "spawn",
                title: "batch"
            ),
            interrupt: InterruptToken(),
            tool: "spawn_batch",
            diagnostics: diagnostics,
            admissionController: admission,
            localAdmissionPlanOverride: {
                let call = await planCalls.nextCall()
                return SubagentBatchAdmissionPlanner.plan(
                    SubagentBatchAdmissionInput(
                        localJobCount: 2,
                        remoteJobCount: 0,
                        agentParallelLimit: 2,
                        engineParallelLimit: call == 1 ? 2 : 1,
                        continuousBatchingEnabled: true,
                        ramSafetyEnabled: false,
                        failClosedWhenEstimateUnknown: false,
                        memory: nil
                    )
                )
            },
            liveResidencyPlanOverride: { _ in .none }
        )
        let executionSnapshot = await execution.snapshot()
        let rows = await diagnostics.snapshot()
        let admissionSnapshot = await admission.snapshot()

        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.envelope.contains(#""ok":true"#) })
        #expect(executionSnapshot.maxActive == 1)
        #expect(rows.count == 1)
        #expect(rows[0].effectiveLocalSlots == 1)
        #expect(rows[0].localSubwaveSizes == [1, 1])
        #expect(admissionSnapshot.inPlace == 0)
    }

    @Test("concurrent same-model local sequences share slots without exceeding the process cap")
    func concurrentSameModelSequencesShareSlotCapacity() async {
        let admission = SubagentAdmission(pollNanoseconds: 1_000_000)
        let probe = BatchExecutionProbe()
        let firstJobs = (0 ..< 2).map { index in
            prepared(
                index: index,
                id: "first-\(index)",
                targetType: .model,
                target: "Local-A",
                model: "Local-A",
                modelID: "Org/Local-A",
                isLocal: true,
                admission: .localInPlace,
                probe: probe,
                delayMilliseconds: 250
            )
        }
        let secondJobs = (0 ..< 2).map { index in
            prepared(
                index: index,
                id: "second-\(index)",
                targetType: .model,
                target: "Local-A",
                model: "local-a",
                modelID: "Org/Local-A",
                isLocal: true,
                admission: .localInPlace,
                probe: probe,
                delayMilliseconds: 250
            )
        }
        let plan = SubagentBatchAdmissionPlanner.plan(
            SubagentBatchAdmissionInput(
                localJobCount: 2,
                remoteJobCount: 0,
                agentParallelLimit: 3,
                engineParallelLimit: 3,
                continuousBatchingEnabled: true,
                ramSafetyEnabled: false,
                failClosedWhenEstimateUnknown: false,
                memory: nil
            )
        )

        async let first = SpawnBatchTool.runLocalSequence(
            firstJobs,
            remoteJobCount: 0,
            maxParallel: 3,
            localParallelismOverride: 2,
            feed: SubagentFeed(
                toolCallId: "batch-concurrent-first",
                kindId: "spawn",
                title: "batch"
            ),
            interrupt: InterruptToken(),
            tool: "spawn_batch",
            diagnostics: nil,
            admissionController: admission,
            localAdmissionPlanOverride: { plan },
            liveResidencyPlanOverride: { _ in .none }
        )
        async let second = SpawnBatchTool.runLocalSequence(
            secondJobs,
            remoteJobCount: 0,
            maxParallel: 3,
            localParallelismOverride: 2,
            feed: SubagentFeed(
                toolCallId: "batch-concurrent-second",
                kindId: "spawn",
                title: "batch"
            ),
            interrupt: InterruptToken(),
            tool: "spawn_batch",
            diagnostics: nil,
            admissionController: admission,
            localAdmissionPlanOverride: { plan },
            liveResidencyPlanOverride: { _ in .none }
        )

        let batches = await [first, second]
        let execution = await probe.snapshot()
        let finalAdmission = await admission.snapshot()

        #expect(batches.flatMap { $0 }.count == 4)
        #expect(
            batches.flatMap { $0 }.allSatisfy {
                $0.envelope.contains(#""ok":true"#)
            }
        )
        #expect(execution.total == 4)
        #expect(execution.maxActive == 3)
        #expect(finalAdmission.exclusive == 0)
        #expect(finalAdmission.inPlace == 0)
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
            tool: "spawn_batch",
            localParallelismOverride: 2,
            localAdmissionPlanOverride: {
                SubagentBatchAdmissionPlanner.plan(
                    SubagentBatchAdmissionInput(
                        localJobCount: 2,
                        remoteJobCount: 1,
                        agentParallelLimit: 3,
                        engineParallelLimit: 2,
                        continuousBatchingEnabled: true,
                        ramSafetyEnabled: false,
                        failClosedWhenEstimateUnknown: false,
                        memory: nil
                    )
                )
            }
        )
        let execution = await probe.snapshot()

        #expect(results.count == 3)
        #expect(results.allSatisfy { $0.envelope.contains(#""ok":true"#) })
        #expect(execution.total == 3)
        #expect(execution.maxActive == 3)
        #expect(await handoff.snapshot() == 1)
    }

    @Test("different local models serialize while remote work overlaps a local wave")
    func differentLocalModelsSerializeAndRemoteOverlaps() async {
        let execution = BatchExecutionProbe()
        let lanes = BatchLaneProbe()
        let handoff = CountingBatchHandoff()
        let jobs = [
            prepared(
                index: 0,
                id: "local-a",
                targetType: .model,
                target: "Local-A",
                model: "Local-A",
                isLocal: true,
                admission: .localExclusive,
                probe: execution,
                laneProbe: lanes,
                handoff: handoff
            ),
            prepared(
                index: 1,
                id: "local-b",
                targetType: .model,
                target: "Local-B",
                model: "Local-B",
                isLocal: true,
                admission: .localExclusive,
                probe: execution,
                laneProbe: lanes,
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
                probe: execution,
                laneProbe: lanes,
                delayMilliseconds: 300
            ),
        ]

        let results = await SpawnBatchTool.runPreparedJobs(
            jobs,
            maxParallel: 3,
            feed: SubagentFeed(
                toolCallId: "batch-different-local",
                kindId: "spawn",
                title: "batch"
            ),
            interrupt: InterruptToken(),
            tool: "spawn_batch",
            localParallelismOverride: 1
        )
        let executionSnapshot = await execution.snapshot()
        let laneSnapshot = await lanes.snapshot()

        #expect(results.count == 3)
        #expect(results.allSatisfy { $0.envelope.contains(#""ok":true"#) })
        #expect(executionSnapshot.total == 3)
        #expect(executionSnapshot.maxActive == 2)
        #expect(laneSnapshot.maxConcurrentLocalModels == 1)
        #expect(laneSnapshot.sawRemoteLocalOverlap)
        #expect(laneSnapshot.sawSecondLocalModelWhileRemoteActive)
        #expect(await handoff.snapshot() == 1)
    }

    @Test("different local children transition before next admission under one parent handoff")
    func differentLocalChildrenTransitionBeforeAdmission() async {
        let execution = BatchExecutionProbe()
        let transition = BatchTransitionProbe()
        let parent = BatchParentLifecycleProbe()
        let handoff = LifecycleBatchHandoff(probe: parent)
        let jobs = [
            prepared(
                index: 0,
                id: "local-a",
                targetType: .model,
                target: "Local-A",
                model: "Local-A",
                isLocal: true,
                admission: .localExclusive,
                probe: execution,
                handoff: handoff
            ),
            prepared(
                index: 1,
                id: "local-b",
                targetType: .model,
                target: "Local-B",
                model: "Local-B",
                isLocal: true,
                admission: .localExclusive,
                probe: execution,
                handoff: handoff
            ),
        ]

        let results = await SpawnBatchTool.runLocalSequence(
            jobs,
            remoteJobCount: 0,
            maxParallel: 2,
            localParallelismOverride: 1,
            feed: SubagentFeed(
                toolCallId: "batch-transition-order",
                kindId: "spawn",
                title: "batch"
            ),
            interrupt: InterruptToken(),
            tool: "spawn_batch",
            diagnostics: nil,
            localAdmissionPlanOverride: {
                await transition.recordAdmission()
                return SubagentBatchAdmissionPlanner.plan(
                    SubagentBatchAdmissionInput(
                        localJobCount: 1,
                        remoteJobCount: 0,
                        agentParallelLimit: 2,
                        engineParallelLimit: 1,
                        continuousBatchingEnabled: true,
                        ramSafetyEnabled: false,
                        failClosedWhenEstimateUnknown: false,
                        memory: nil
                    )
                )
            },
            liveResidencyPlanOverride: { _ in
                ResidencyPlan(
                    shouldUnload: true,
                    requiredBytes: 1,
                    ramSafetyEnabled: true,
                    maxElapsedSeconds: 120,
                    coexists: false
                )
            },
            localModelTransitionOverride: { previous, next, _, _ in
                await transition.recordTransition(
                    previous: previous.resolved.name,
                    next: next.resolved.name
                )
                await transition.finishTransition()
                return nil
            }
        )
        let transitionSnapshot = await transition.snapshot()
        let parentSnapshot = await parent.snapshot()
        let executionSnapshot = await execution.snapshot()

        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.envelope.contains(#""ok":true"#) })
        #expect(transitionSnapshot.transitions == ["Local-A->Local-B"])
        #expect(transitionSnapshot.admissionTransitionCounts == [0, 1])
        #expect(transitionSnapshot.transitionFinished)
        #expect(parentSnapshot.unloads == 1)
        #expect(parentSnapshot.restores == 1)
        #expect(executionSnapshot.total == 2)
        #expect(executionSnapshot.maxActive == 1)
    }

    @Test("final swapped child unloads before the aggregate handoff restores its parent")
    func finalSwappedChildCleansUpBeforeParentRestore() async {
        let execution = BatchExecutionProbe()
        let order = BatchResidencyOrderProbe()
        let handoff = OrderedLifecycleBatchHandoff(probe: order)
        let jobs = [
            prepared(
                index: 0,
                id: "local-a",
                targetType: .model,
                target: "Local-A",
                model: "Local-A",
                isLocal: true,
                admission: .localExclusive,
                probe: execution,
                handoff: handoff
            ),
            prepared(
                index: 1,
                id: "local-b",
                targetType: .model,
                target: "Local-B",
                model: "Local-B",
                isLocal: true,
                admission: .localExclusive,
                probe: execution,
                handoff: handoff
            ),
        ]

        let results = await SpawnBatchTool.runLocalSequence(
            jobs,
            remoteJobCount: 0,
            maxParallel: 2,
            localParallelismOverride: 1,
            feed: SubagentFeed(
                toolCallId: "batch-final-cleanup-order",
                kindId: "spawn",
                title: "batch"
            ),
            interrupt: InterruptToken(),
            tool: "spawn_batch",
            diagnostics: nil,
            localAdmissionPlanOverride: {
                SubagentBatchAdmissionPlanner.plan(
                    SubagentBatchAdmissionInput(
                        localJobCount: 1,
                        remoteJobCount: 0,
                        agentParallelLimit: 2,
                        engineParallelLimit: 1,
                        continuousBatchingEnabled: true,
                        ramSafetyEnabled: false,
                        failClosedWhenEstimateUnknown: false,
                        memory: nil
                    )
                )
            },
            liveResidencyPlanOverride: { _ in
                ResidencyPlan(
                    shouldUnload: true,
                    requiredBytes: 1,
                    ramSafetyEnabled: true,
                    maxElapsedSeconds: 120,
                    coexists: false
                )
            },
            localModelTransitionOverride: { previous, next, _, _ in
                await order.record(
                    "transition-\(previous.resolved.name)-to-\(next.resolved.name)"
                )
                return nil
            },
            finalLocalModelCleanupOverride: { current, _, _ in
                await order.record("final-cleanup-\(current.resolved.name)")
            }
        )

        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.envelope.contains(#""ok":true"#) })
        #expect(
            await order.snapshot()
                == [
                    "parent-unload",
                    "transition-Local-A-to-Local-B",
                    "final-cleanup-Local-B",
                    "parent-restore",
                ]
        )
    }

    @Test("batch handoff carries exact parent identity and one ownership token through cleanup")
    func batchHandoffCarriesExactOwnership() async {
        let order = BatchResidencyOrderProbe()
        let token = ModelResidencyOwnershipToken()
        let handoff = ResidencyHandoff(
            plan: { _ in ResidencyPlan(shouldUnload: true) },
            preflight: { _, _, _ in },
            unload: { parent, _, _ in
                await order.record("unload-\(parent ?? "nil")")
                return ChatResidencyLease(
                    unloadedModelNames: ["Parent-Local"],
                    childOwnershipToken: token
                )
            },
            restore: { lease, _ in
                #expect(lease.childOwnershipToken == token)
                await order.record("restore")
                return lease.unloadedModelNames
            }
        )
        let jobs = [
            prepared(
                index: 0,
                id: "owned-local",
                targetType: .model,
                target: "Child-Local",
                model: "Child-Local",
                isLocal: true,
                admission: .localExclusive,
                handoff: handoff,
                parentModelName: "Parent-Local"
            )
        ]

        let results = await SpawnBatchTool.runLocalSequence(
            jobs,
            remoteJobCount: 0,
            maxParallel: 1,
            localParallelismOverride: 1,
            feed: SubagentFeed(
                toolCallId: "batch-exact-ownership",
                kindId: "spawn",
                title: "batch"
            ),
            interrupt: InterruptToken(),
            tool: "spawn_batch",
            diagnostics: nil,
            localAdmissionPlanOverride: {
                SubagentBatchAdmissionPlanner.plan(
                    SubagentBatchAdmissionInput(
                        localJobCount: 1,
                        remoteJobCount: 0,
                        agentParallelLimit: 1,
                        engineParallelLimit: 1,
                        continuousBatchingEnabled: true,
                        ramSafetyEnabled: false,
                        failClosedWhenEstimateUnknown: false,
                        memory: nil
                    )
                )
            },
            liveResidencyPlanOverride: { _ in
                ResidencyPlan(shouldUnload: true)
            },
            finalLocalModelCleanupOverride: { _, _, _ in
                #expect(ModelResidencyOwnershipContext.childOwnershipToken == token)
                await order.record("cleanup")
            }
        )

        #expect(results.count == 1)
        #expect(results[0].envelope.contains(#""ok":true"#))
        #expect(
            await order.snapshot()
                == ["unload-Parent-Local", "cleanup", "restore"]
        )
    }

    @Test("no-parent B→C transition and final cleanup share one exact ownership token")
    func noParentSequenceSharesExactOwnership() async throws {
        let token = ModelResidencyOwnershipToken()
        let order = BatchResidencyOrderProbe()
        let handoff = ResidencyOwnershipHandoff(
            wrapping: PassthroughHandoff(),
            ownershipToken: token
        )
        let noParentScope = SubagentScope(
            sessionId: "batch-no-parent",
            toolCallId: "batch-no-parent-call",
            agentId: Agent.defaultId,
            parentModelName: nil
        )

        let result = try await handoff.around(
            scope: noParentScope,
            resolved: ResolvedModel(name: "Local-B", id: "Org/Local-B", isLocal: true),
            feed: SubagentFeed(
                toolCallId: "batch-no-parent-call",
                kindId: "spawn",
                title: "batch"
            )
        ) {
            #expect(ModelResidencyOwnershipContext.childOwnershipToken == token)
            await order.record("run-Local-B")

            // Model-free equivalent of the B → C transition callback.
            #expect(ModelResidencyOwnershipContext.childOwnershipToken == token)
            await order.record("transition-Local-B-to-Local-C")

            // The final exact-owned cleanup must see that same token.
            #expect(ModelResidencyOwnershipContext.childOwnershipToken == token)
            await order.record("final-cleanup-Local-C")
            return SubagentResult(payload: ["summary": "ok"], summary: "ok")
        }

        #expect(result.summary == "ok")
        #expect(
            await order.snapshot()
                == [
                    "run-Local-B",
                    "transition-Local-B-to-Local-C",
                    "final-cleanup-Local-C",
                ]
        )
    }

    @Test("coexistence B→C transition and final cleanup share one exact ownership token")
    func coexistenceSequenceCleansUpExactOwnedFinalChild() async throws {
        let token = ModelResidencyOwnershipToken()
        let order = BatchResidencyOrderProbe()
        let coexistence = ResidencyHandoff(
            plan: { _ in
                ResidencyPlan(
                    shouldUnload: false,
                    requiredBytes: 1,
                    ramSafetyEnabled: true,
                    maxElapsedSeconds: 120,
                    coexists: true
                )
            },
            preflight: { _, _, _ in
                await order.record("coexistence-preflight")
            },
            unload: { _, _, _ in
                Issue.record("coexistence must not unload its parent")
                return ChatResidencyLease(unloadedModelNames: [])
            },
            restore: { _, _ in
                Issue.record("coexistence must not restore an unloaded parent")
                return []
            }
        )
        let handoff = ResidencyOwnershipHandoff(
            wrapping: coexistence,
            ownershipToken: token
        )
        let coexistenceScope = SubagentScope(
            sessionId: "batch-coexist",
            toolCallId: "batch-coexist-call",
            agentId: Agent.defaultId,
            parentModelName: "Parent-Local"
        )

        let result = try await handoff.around(
            scope: coexistenceScope,
            resolved: ResolvedModel(name: "Local-B", id: "Org/Local-B", isLocal: true),
            feed: SubagentFeed(
                toolCallId: "batch-coexist-owned-cleanup",
                kindId: "spawn",
                title: "batch"
            )
        ) {
            #expect(ModelResidencyOwnershipContext.childOwnershipToken == token)
            await order.record("run-Local-B")

            #expect(ModelResidencyOwnershipContext.childOwnershipToken == token)
            await order.record("transition-Local-B-to-Local-C")

            #expect(ModelResidencyOwnershipContext.childOwnershipToken == token)
            await order.record("final-cleanup-Local-C")
            return SubagentResult(payload: ["summary": "ok"], summary: "ok")
        }

        #expect(result.summary == "ok")
        #expect(
            await order.snapshot()
                == [
                    "coexistence-preflight",
                    "run-Local-B",
                    "transition-Local-B-to-Local-C",
                    "final-cleanup-Local-C",
                ]
        )
    }

    @Test("post-child parent restore failure cannot aggregate as batch success")
    func restoreFailureAfterCompletedBatchIsReported() async throws {
        let jobs = [
            prepared(
                index: 0,
                id: "completed-child",
                targetType: .model,
                target: "Local-A",
                model: "Local-A",
                isLocal: true,
                admission: .localExclusive,
                handoff: RestoreFailingBatchHandoff()
            )
        ]

        let results = await SpawnBatchTool.runLocalSequence(
            jobs,
            remoteJobCount: 0,
            maxParallel: 1,
            localParallelismOverride: 1,
            feed: SubagentFeed(
                toolCallId: "batch-restore-failure",
                kindId: "spawn",
                title: "batch"
            ),
            interrupt: InterruptToken(),
            tool: "spawn_batch",
            diagnostics: nil,
            localAdmissionPlanOverride: {
                SubagentBatchAdmissionPlanner.plan(
                    SubagentBatchAdmissionInput(
                        localJobCount: 1,
                        remoteJobCount: 0,
                        agentParallelLimit: 1,
                        engineParallelLimit: 1,
                        continuousBatchingEnabled: true,
                        ramSafetyEnabled: false,
                        failClosedWhenEstimateUnknown: false,
                        memory: nil
                    )
                )
            },
            liveResidencyPlanOverride: { _ in
                ResidencyPlan(
                    shouldUnload: true,
                    requiredBytes: 1,
                    ramSafetyEnabled: true,
                    maxElapsedSeconds: 120,
                    coexists: false
                )
            }
        )

        let result = try #require(results.first)
        let data = try #require(result.envelope.data(using: .utf8))
        let payload = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(payload["ok"] as? Bool == false)
        #expect(payload["message"] as? String == "parent restore failed")
        let original = try #require(
            payload["child_envelope_before_handoff_failure"] as? String
        )
        #expect(original.contains(#""ok":true"#))
    }

    @Test("Stop during different-local transition drains child and restores parent once")
    func stopDuringDifferentLocalTransitionFinishesCleanup() async {
        let execution = BatchExecutionProbe()
        let transition = BatchTransitionProbe()
        let parent = BatchParentLifecycleProbe()
        let handoff = LifecycleBatchHandoff(probe: parent)
        let interrupt = InterruptToken()
        let jobs = [
            prepared(
                index: 0,
                id: "local-a",
                targetType: .model,
                target: "Local-A",
                model: "Local-A",
                isLocal: true,
                admission: .localExclusive,
                probe: execution,
                handoff: handoff
            ),
            prepared(
                index: 1,
                id: "local-b",
                targetType: .model,
                target: "Local-B",
                model: "Local-B",
                isLocal: true,
                admission: .localExclusive,
                probe: execution,
                handoff: handoff
            ),
        ]

        let results = await SpawnBatchTool.runLocalSequence(
            jobs,
            remoteJobCount: 0,
            maxParallel: 2,
            localParallelismOverride: 1,
            feed: SubagentFeed(
                toolCallId: "batch-transition-stop",
                kindId: "spawn",
                title: "batch"
            ),
            interrupt: interrupt,
            tool: "spawn_batch",
            diagnostics: nil,
            localAdmissionPlanOverride: {
                SubagentBatchAdmissionPlanner.plan(
                    SubagentBatchAdmissionInput(
                        localJobCount: 1,
                        remoteJobCount: 0,
                        agentParallelLimit: 2,
                        engineParallelLimit: 1,
                        continuousBatchingEnabled: true,
                        ramSafetyEnabled: false,
                        failClosedWhenEstimateUnknown: false,
                        memory: nil
                    )
                )
            },
            liveResidencyPlanOverride: { _ in
                ResidencyPlan(
                    shouldUnload: true,
                    requiredBytes: 1,
                    ramSafetyEnabled: true,
                    maxElapsedSeconds: 120,
                    coexists: false
                )
            },
            localModelTransitionOverride: { previous, next, _, _ in
                await transition.recordTransition(
                    previous: previous.resolved.name,
                    next: next.resolved.name
                )
                interrupt.interrupt()
                try? await Task.sleep(for: .milliseconds(10))
                await transition.finishTransition()
                return nil
            }
        ).sorted { $0.job.index < $1.job.index }
        let transitionSnapshot = await transition.snapshot()
        let parentSnapshot = await parent.snapshot()
        let executionSnapshot = await execution.snapshot()

        #expect(results.map(\.job.id) == ["local-a", "local-b"])
        #expect(results[0].envelope.contains(#""ok":true"#))
        #expect(results[1].envelope.contains(#""ok":false"#))
        #expect(results[1].envelope.contains("cancelled"))
        #expect(transitionSnapshot.transitions == ["Local-A->Local-B"])
        #expect(transitionSnapshot.transitionFinished)
        #expect(parentSnapshot.unloads == 1)
        #expect(parentSnapshot.restores == 1)
        #expect(executionSnapshot.total == 1)
        #expect(executionSnapshot.maxActive == 1)
    }

    @Test("identical local basenames with different full ids use serialized handoffs")
    func identicalBasenamesFromDifferentOrganizationsSerialize() async {
        let execution = BatchExecutionProbe()
        let handoff = CountingBatchHandoff()
        let jobs = [
            prepared(
                index: 0,
                id: "org-a",
                targetType: .model,
                target: "Org-A/Shared-Bundle",
                model: "Shared-Bundle",
                modelID: "Org-A/Shared-Bundle",
                isLocal: true,
                admission: .localExclusive,
                probe: execution,
                handoff: handoff
            ),
            prepared(
                index: 1,
                id: "org-b",
                targetType: .model,
                target: "Org-B/Shared-Bundle",
                model: "Shared-Bundle",
                modelID: "Org-B/Shared-Bundle",
                isLocal: true,
                admission: .localExclusive,
                probe: execution,
                handoff: handoff
            ),
        ]

        let groups = SpawnBatchTool.makeLocalGroups(jobs)
        #expect(groups.map(\.count) == [1, 1])
        #expect(groups.compactMap { $0.first?.localGroupingKey }.count == 2)
        #expect(
            Set(groups.compactMap { $0.first?.localGroupingKey }).count == 2
        )

        let results = await SpawnBatchTool.runPreparedJobs(
            jobs,
            maxParallel: 2,
            feed: SubagentFeed(
                toolCallId: "batch-same-basename",
                kindId: "spawn",
                title: "batch"
            ),
            interrupt: InterruptToken(),
            tool: "spawn_batch",
            localParallelismOverride: 2
        )
        let snapshot = await execution.snapshot()

        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.envelope.contains(#""ok":true"#) })
        #expect(snapshot.total == 2)
        #expect(snapshot.maxActive == 1)
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

    @Test("private child lifecycle is multiplexed once per job into the parent feed")
    func childLifecycleIsVisibleAndTerminal() async {
        let parent = SubagentFeed(
            toolCallId: "batch-visible-children",
            kindId: "spawn",
            title: "batch"
        )
        let jobs = [
            prepared(
                index: 0,
                id: "alpha",
                targetType: .model,
                target: "cloud/alpha",
                model: "cloud/alpha",
                isLocal: false,
                admission: .remote
            ),
            prepared(
                index: 1,
                id: "beta",
                targetType: .model,
                target: "cloud/beta",
                model: "cloud/beta",
                isLocal: false,
                admission: .remote
            ),
        ]

        let results = await SpawnBatchTool.runPreparedJobs(
            jobs,
            maxParallel: 2,
            feed: parent,
            interrupt: InterruptToken(),
            tool: "spawn_batch"
        )
        let events = parent.currentEvents()

        #expect(results.count == 2)
        for id in ["alpha", "beta"] {
            #expect(events.contains { $0.title == "job \(id) · scripted start" })
            #expect(events.contains { $0.title == "job \(id) · scripted complete" })
            #expect(
                events.filter {
                    $0.title == "job \(id) finished"
                        && $0.kind == .outcome
                        && $0.success == true
                }.count == 1
            )
        }
    }

    @Test("effective one-slot local capacity runs subwaves under one handoff")
    func localCapacityCreatesSubwavesWithoutReloading() async {
        let probe = BatchExecutionProbe()
        let handoff = CountingBatchHandoff()
        let jobs = (0 ..< 3).map { index in
            prepared(
                index: index,
                id: "local-\(index)",
                targetType: .model,
                target: "Local-A",
                model: "Local-A",
                isLocal: true,
                admission: .localExclusive,
                probe: probe,
                handoff: handoff
            )
        }
        let results = await SpawnBatchTool.runPreparedJobs(
            jobs,
            maxParallel: 3,
            feed: SubagentFeed(
                toolCallId: "batch-parent",
                kindId: "spawn",
                title: "batch"
            ),
            interrupt: InterruptToken(),
            tool: "spawn_batch",
            localParallelismOverride: 1
        )
        let execution = await probe.snapshot()

        #expect(results.count == 3)
        #expect(results.allSatisfy { $0.envelope.contains(#""ok":true"#) })
        #expect(execution.total == 3)
        #expect(execution.maxActive == 1)
        #expect(await handoff.snapshot() == 1)
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
        #expect(
            results.allSatisfy {
                SpawnBatchTool.resultRow($0)["envelope"]
                    .flatMap { $0 as? [String: Any] }?["kind"] as? String
                    == "user_denied"
            }
        )
        #expect(execution.total == 0)
    }

    @Test("activity Stop cancels active siblings and settles every result row")
    func cancellationDuringWave() async {
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
                probe: probe,
                delayMilliseconds: 400
            ),
            prepared(
                index: 1,
                id: "b",
                targetType: .model,
                target: "cloud/b",
                model: "cloud/b",
                isLocal: false,
                admission: .remote,
                probe: probe,
                delayMilliseconds: 400
            ),
        ]
        let interrupt = InterruptToken()
        let parent = SubagentFeed(
            toolCallId: "batch-cancel-parent",
            kindId: "spawn",
            title: "batch"
        )
        let task = Task {
            await SpawnBatchTool.runPreparedJobs(
                jobs,
                maxParallel: 2,
                feed: parent,
                interrupt: interrupt,
                tool: "spawn_batch"
            )
        }

        // Wait for both jobs to actually ENTER execution rather than assuming a
        // fixed 20ms is long enough. The scripted jobs sleep 80ms, so the old
        // barrier left only a 60ms margin: on a contended runner
        // `Task.sleep(20ms)` oversleeps, both jobs finish before
        // `interrupt()` lands, and every assertion below inverts — results come
        // back `"ok":true` instead of `user_denied`. That is the CI failure
        // signature (3 or 4 issues depending on how the race lands), while the
        // same test passes on a fast machine. Mirrors the deadline+poll idiom
        // already used earlier in this file.
        let startDeadline = Date().addingTimeInterval(2)
        while await probe.snapshot().total < jobs.count, Date() < startDeadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        interrupt.interrupt()
        let results = await task.value.sorted { $0.job.index < $1.job.index }
        let execution = await probe.snapshot()

        #expect(results.map(\.job.id) == ["a", "b"])
        #expect(results.allSatisfy { $0.envelope.contains(#""ok":false"#) })
        #expect(
            results.allSatisfy {
                SpawnBatchTool.resultRow($0)["envelope"]
                    .flatMap { $0 as? [String: Any] }?["kind"] as? String
                    == "user_denied"
            }
        )
        #expect(execution.total == 2)
        #expect(execution.maxActive == 2)
        let events = parent.currentEvents()
        for id in ["a", "b"] {
            #expect(
                events.filter {
                    $0.title == "job \(id) finished"
                        && $0.kind == .outcome
                        && $0.success == false
                }.count == 1
            )
        }
    }
}
