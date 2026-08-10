//
//  SpawnBatchTool.swift
//  osaurus
//
//  `spawn_batch(jobs)` — bounded heterogeneous fan-out over the exact agents
//  and models the user allowed for the launching agent.
//
//  Safety contract:
//  - every target is parsed, allow-list checked, model-resolved, and
//    permission-checked before the first local residency change;
//  - the batch contains at most the configured number of jobs;
//  - remote jobs start immediately and may overlap every admitted local wave;
//  - one owned local sequence serializes different canonical local models, so
//    they never race cold loads or residency handoffs;
//  - same-model local jobs share one admission slot and one handoff, then run
//    concurrently through the model's shared BatchEngine;
//  - results are returned in caller order with one honest envelope per job.
//

import Combine
import Foundation

public final class SpawnBatchTool: OsaurusTool, @unchecked Sendable {
    public let name = SubagentCapabilityRegistry.spawnBatchToolName
    public let description =
        "Run several independent bounded subtasks using the agents and models the user allowed. "
        + "Each job must name a caller-stable id, one target_type (`agent` or `model`), the exact "
        + "target name/id, and its input. Osaurus validates every job before changing local model "
        + "residency, runs remote jobs concurrently, batches jobs for the same local model without "
        + "reloading it between jobs, serializes different local models, and returns results in the "
        + "same order as the input jobs. Use this only for independent work that can safely fan out."

    static let jobCountBounds: ClosedRange<Int> = 1 ... 32

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "jobs": .object([
                "type": .string("array"),
                "minItems": .number(Double(jobCountBounds.lowerBound)),
                "maxItems": .number(Double(jobCountBounds.upperBound)),
                "description": .string(
                    "Independent jobs. Results preserve this array's order."
                ),
                "items": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "properties": .object([
                        "id": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Caller-stable unique id used to match the result."
                            ),
                        ]),
                        "target_type": .object([
                            "type": .string("string"),
                            "enum": .array([.string("agent"), .string("model")]),
                            "description": .string(
                                "`agent` uses a configured agent; `model` uses a bare allowed model."
                            ),
                        ]),
                        "target": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Exact allowed agent UUID or model id for target_type."
                            ),
                        ]),
                        "input": .object([
                            "type": .string("string"),
                            "description": .string(SpawnInputContract.schemaDescription),
                        ]),
                    ]),
                    "required": .array([
                        .string("id"),
                        .string("target_type"),
                        .string("target"),
                        .string("input"),
                    ]),
                ]),
            ])
        ]),
        "required": .array([.string("jobs")]),
    ])

    public var bypassRegistryTimeout: Bool { true }

    public init() {}

    /// Model-free preparation seam for permission-ordering tests. Production
    /// never binds this value; the explicit target still passes the real
    /// per-agent allow-list before the existing TextSubagentKind eval seam
    /// bypasses provider/residency resolution.
    @TaskLocal
    static var modelOverrideForTests: String?

    /// Model-free production-path eval seam. The scripted lane binds this
    /// value so it can exercise this tool's real parser, prepare-all barrier,
    /// one permission gate, admission/grouping scheduler, and ordered
    /// aggregation without resolving or loading a live model. Production
    /// never binds it.
    struct EvaluationOverrides: Sendable {
        let kindForJob: @Sendable (Job) -> any SubagentKind
        let maxParallel: Int
        let localParallelism: Int
        let localAdmissionPlan: SubagentBatchAdmissionPlan
    }

    @TaskLocal
    static var evaluationOverrides: EvaluationOverrides?

    enum TargetType: String, Sendable, Equatable {
        case agent
        case model
    }

    struct Job: Sendable, Equatable {
        let index: Int
        let id: String
        let targetType: TargetType
        let target: String
        let input: String
    }

    struct PreparedJob: Sendable {
        let job: Job
        let run: PreparedSubagentRun

        var localGroupingKey: String? {
            guard let modelKey = run.admissionModelKey else { return nil }
            return "\(modelKey)|\(run.admissionClass.rawValue)"
        }
    }

    struct RawJobResult: Sendable {
        let job: Job
        let envelope: String
    }

    enum BatchPreparationResult: Sendable {
        case ready([PreparedJob])
        case failures([(id: String, envelope: String)])
        case cancelled
    }

    struct BatchTargetAuthority: Sendable, Equatable {
        let id: UUID
        let target: SpawnTargetAuthority?
        let revision: UInt64
    }

    struct BatchAuthorityFingerprint: Sendable, Equatable {
        let configurationRevision: SpawnConfigurationAuthorityRevision
        /// Canonical Server-owned Spawn/BatchEngine ceiling. Kept beside the
        /// scoped Subagent-store generations so a headless/API settings change
        /// during approval cannot escape the final authority comparison merely
        /// because no UI controller was present to update the persisted mirror.
        let maxParallelSpawns: Int
        let launcher: SpawnLauncherAuthority
        let launcherAgentRevisions: SpawnAgentAuthorityRevisions
        let targets: [BatchTargetAuthority]
        let isDefaultLauncher: Bool
        let effectivePermission: SubagentPermissionPolicy
    }

    struct EngineAdmissionWindow: Sendable, Equatable {
        let parallelLimit: Int
        let queued: Bool
    }

    /// Multiplex one private child feed into the batch's visible parent row.
    ///
    /// Child feeds cannot be registered independently because their tool-call
    /// ids are implementation details and a batch must expose one Stop owner.
    /// Relaying their events preserves per-job reasoning/tool/lifecycle
    /// visibility without creating colliding registry rows. The relay tracks
    /// event ids because `CurrentValueSubject` republishes the full child
    /// snapshot after every append.
    private final class ChildFeedRelay: @unchecked Sendable {
        private let child: SubagentFeed
        private let parent: SubagentFeed
        private let jobID: String
        private let lock = NSLock()
        private var relayedEvents: [UUID: SubagentActivityEvent] = [:]
        private var relayedTerminalStatus = false
        private var eventSubscription: AnyCancellable?
        private var statusSubscription: AnyCancellable?

        init(
            child: SubagentFeed,
            parent: SubagentFeed,
            jobID: String
        ) {
            self.child = child
            self.parent = parent
            self.jobID = jobID
            eventSubscription = child.eventsPublisher.sink { [weak self] events in
                self?.relay(events)
            }
            statusSubscription = child.statusPublisher.sink { [weak self] status in
                self?.relay(status)
            }
        }

        /// Flush the synchronous terminal publication and release Combine
        /// ownership. Safe to call once `runPrepared` returns.
        func stop() {
            relay(child.currentEvents())
            relay(child.currentStatus())
            eventSubscription?.cancel()
            statusSubscription?.cancel()
            eventSubscription = nil
            statusSubscription = nil
        }

        private func relay(_ events: [SubagentActivityEvent]) {
            lock.lock()
            let changed = events.filter { event in
                guard relayedEvents[event.id] != event else { return false }
                relayedEvents[event.id] = event
                return true
            }
            lock.unlock()
            for event in changed {
                parent.upsert(
                    SubagentActivityEvent(
                        id: event.id,
                        timestamp: event.timestamp,
                        step: event.step,
                        kind: event.kind,
                        title: "job \(jobID) · \(event.title)",
                        detail: event.detail,
                        success: event.success,
                        fraction: event.fraction
                    )
                )
            }
        }

        private func relay(_ status: SubagentRunStatus) {
            guard case .finished(let success, let summary) = status else { return }
            lock.lock()
            guard !relayedTerminalStatus else {
                lock.unlock()
                return
            }
            relayedTerminalStatus = true
            lock.unlock()
            parent.emit(
                SubagentActivityEvent(
                    kind: .outcome,
                    title: "job \(jobID) finished",
                    detail: summary.isEmpty ? nil : summary,
                    success: success
                )
            )
        }
    }

    struct BatchWaveDiagnostic: Sendable, Equatable {
        let wave: Int
        let jobs: Int
        let remoteJobs: Int
        let localJobs: Int
        let localModelKey: String?
        let effectiveLocalSlots: Int
        let engineSlots: Int?
        let ramSlots: Int?
        let localSubwaveSizes: [Int]
        let limitingFactors: [String]
        let verdict: String
        let admissionWaitSeconds: Double?
        let residencyMode: String?
        let engineOccupancy: ModelBatchCapacitySnapshot?
        let engineQueuedAtAdmission: Bool

        init(
            wave: Int,
            jobs: Int,
            remoteJobs: Int,
            localJobs: Int,
            localModelKey: String?,
            effectiveLocalSlots: Int,
            engineSlots: Int?,
            ramSlots: Int?,
            localSubwaveSizes: [Int],
            limitingFactors: [String],
            verdict: String,
            admissionWaitSeconds: Double?,
            residencyMode: String?,
            engineOccupancy: ModelBatchCapacitySnapshot? = nil,
            engineQueuedAtAdmission: Bool = false
        ) {
            self.wave = wave
            self.jobs = jobs
            self.remoteJobs = remoteJobs
            self.localJobs = localJobs
            self.localModelKey = localModelKey
            self.effectiveLocalSlots = effectiveLocalSlots
            self.engineSlots = engineSlots
            self.ramSlots = ramSlots
            self.localSubwaveSizes = localSubwaveSizes
            self.limitingFactors = limitingFactors
            self.verdict = verdict
            self.admissionWaitSeconds = admissionWaitSeconds
            self.residencyMode = residencyMode
            self.engineOccupancy = engineOccupancy
            self.engineQueuedAtAdmission = engineQueuedAtAdmission
        }

        var payload: [String: Any] {
            [
                "wave": wave,
                "jobs": jobs,
                "remote_jobs": remoteJobs,
                "local_jobs": localJobs,
                "local_model": localModelKey ?? NSNull(),
                "effective_local_slots": effectiveLocalSlots,
                "engine_slots": engineSlots ?? NSNull(),
                "ram_slots": ramSlots ?? NSNull(),
                "local_subwaves": localSubwaveSizes,
                "limited_by": limitingFactors,
                "verdict": verdict,
                "admission_wait_seconds":
                    admissionWaitSeconds.map { ($0 * 1_000).rounded() / 1_000 }
                    ?? NSNull(),
                "residency_mode": residencyMode ?? NSNull(),
                "capacity_snapshot":
                    localJobs > 0 ? "post_admission_capacity_plan" : "not_applicable",
                "engine_capacity_source":
                    engineOccupancy == nil ? "configured_cold_start" : "atomic_live",
                "engine_configured_max":
                    engineOccupancy?.configuredMaximum ?? NSNull(),
                "engine_active_at_admission":
                    engineOccupancy?.activeCount ?? NSNull(),
                "engine_pending_at_admission":
                    engineOccupancy?.pendingCount ?? NSNull(),
                "engine_nominal_available_at_admission":
                    engineOccupancy?.nominalAvailableCount ?? NSNull(),
                "engine_accepting_at_admission":
                    engineOccupancy?.isAcceptingRequests ?? NSNull(),
                "engine_queued_at_admission": engineQueuedAtAdmission,
            ]
        }
    }

    /// Batch-level before/after counters from the one production vMLX
    /// diagnostics surface. Per-child snapshots are process aggregates and
    /// cannot honestly attribute a hit to one worker when siblings overlap;
    /// the parent batch therefore publishes the exact aggregate boundary and
    /// signed delta instead of relabeling absolute counters as child-local.
    struct BatchCacheDiagnostic: Sendable, Equatable {
        let before: BatchDiagnosticsSnapshot?
        let after: BatchDiagnosticsSnapshot?

        var payload: [String: Any] {
            guard let before, let after else {
                return [
                    "available": false,
                    "before_available": before != nil,
                    "after_available": after != nil,
                ]
            }

            let beforeCounters = Self.counters(before)
            let afterCounters = Self.counters(after)
            var deltas: [String: Int] = [:]
            for key in beforeCounters.keys {
                deltas[key] = (afterCounters[key] ?? 0) - (beforeCounters[key] ?? 0)
            }
            return [
                "available": true,
                "before": beforeCounters,
                "after": afterCounters,
                "delta": deltas,
                "active_before": before.activeCount,
                "active_after": after.activeCount,
                "pending_before": before.pendingCount,
                "pending_after": after.pendingCount,
                "process_lifetime_active_high_watermark_before":
                    before.activeHighWatermark,
                "process_lifetime_active_high_watermark_after":
                    after.activeHighWatermark,
                "high_watermark_scope": "process_lifetime_not_batch_scoped",
                "loaded_models_before": before.loadedModelCount,
                "loaded_models_after": after.loadedModelCount,
            ]
        }

        private static func counters(
            _ snapshot: BatchDiagnosticsSnapshot
        ) -> [String: Int] {
            [
                "prefix_hits": snapshot.prefixHits,
                "prefix_misses": snapshot.prefixMisses,
                "paged_evictions": snapshot.pagedEvictions,
                "disk_l2_hits": snapshot.diskL2Hits,
                "disk_l2_misses": snapshot.diskL2Misses,
                "disk_l2_stores": snapshot.diskL2Stores,
                "ssm_companion_hits": snapshot.ssmCompanionHits,
                "ssm_companion_misses": snapshot.ssmCompanionMisses,
                "ssm_companion_rederives": snapshot.ssmCompanionReDerives,
            ]
        }
    }

    actor BatchDiagnosticsCollector {
        private var values: [BatchWaveDiagnostic] = []

        func append(_ value: BatchWaveDiagnostic) {
            values.append(value)
        }

        func snapshot() -> [BatchWaveDiagnostic] {
            values.sorted { $0.wave < $1.wave }
        }
    }

    private enum BatchTaskOutput: Sendable {
        case results([RawJobResult])
        case interrupted
        case monitorStopped
    }

    private struct ResolvedLocalGroup: Sendable {
        let jobs: [PreparedJob]
        let initialResidencyPlan: ResidencyPlan
    }

    /// Owned transition between two DIFFERENT local child-model groups.
    ///
    /// The aggregate handoff owns the parent chat model exactly once. This
    /// transition owns only the previous CHILD model: cancel/drain/unload it
    /// before the next child's live RAM admission is recomputed. Returning an
    /// envelope fails the not-yet-started groups without discarding results
    /// already produced by earlier groups.
    typealias LocalModelTransition =
        @Sendable (
            _ previous: PreparedSubagentRun,
            _ next: PreparedSubagentRun,
            _ feed: SubagentFeed,
            _ tool: String
        ) async -> String?

    /// Owned cleanup for the final cold-loaded local child in a sequence. An
    /// exact ownership token makes this safe for swapped, coexistence, and
    /// no-parent batches: a pre-existing resident returns `.notOwned` and is
    /// intentionally preserved.
    typealias FinalLocalModelCleanup =
        @Sendable (
            _ current: PreparedSubagentRun,
            _ feed: SubagentFeed,
            _ tool: String
        ) async throws -> Void

    public func execute(argumentsJSON: String) async throws -> String {
        let parsed = Self.parseJobs(argumentsJSON, tool: name)
        guard case .success(let jobs) = parsed else {
            return parsed.failureEnvelope ?? ""
        }
        for job in jobs {
            if let failure = SpawnInputContract.validationFailure(
                input: job.input,
                field: "jobs[\(job.index)].input",
                tool: name
            ) {
                return failure
            }
        }

        let parentScope = SubagentScope.current()
        let evaluationOverrides = Self.evaluationOverrides
        let preflightMaxParallel: Int
        if let evaluationOverrides {
            preflightMaxParallel = evaluationOverrides.maxParallel
        } else {
            preflightMaxParallel = await Self.effectiveMaxParallel(scope: parentScope)
        }
        if let limitFailure = Self.batchLimitFailure(
            jobCount: jobs.count,
            maxJobs: preflightMaxParallel,
            tool: name
        ) {
            return limitFailure
        }

        // Register the visible feed and Stop token before target resolution or
        // permission. Provider discovery and an interactive policy gate can
        // both take long enough that waiting until after preparation leaves
        // the row spinning with no cancellable run behind its Stop control.
        let feed = SubagentFeed(
            toolCallId: parentScope.toolCallId,
            kindId: SubagentCapabilityRegistry.spawn.id,
            title: "spawn batch (\(jobs.count))"
        )
        let interrupt = InterruptToken()
        SubagentFeedRegistry.shared.register(feed)
        SubagentInterruptCenter.shared.register(
            interrupt,
            for: parentScope.toolCallId
        )
        defer {
            SubagentInterruptCenter.shared.unregister(parentScope.toolCallId)
            SubagentFeedRegistry.shared.unregister(
                toolCallId: parentScope.toolCallId
            )
        }

        feed.emitPhase(
            "validating targets",
            detail: "\(jobs.count) jobs · fan-out limit \(preflightMaxParallel)"
        )

        // A persisted deny is cheaper and stronger than target lookup, so
        // reject it immediately. Ask/Always continue through target validation:
        // malformed, recursive, unavailable, or disallowed jobs must never
        // summon an approval panel. Preparation resolves only a residency plan;
        // it does not admit, unload, or load a model.
        let initialBatchPolicy = await SpawnPermissionGate.effectivePolicy(
            for: parentScope
        )
        if initialBatchPolicy == .deny {
            let decision = await SpawnPermissionGate.authorize(
                scope: parentScope,
                policy: initialBatchPolicy,
                toolName: name,
                description:
                    "Allow this agent to spawn \(jobs.count) independent bounded subagents?",
                argumentsJSON: argumentsJSON
            )
            if case .denied(let reason) = decision {
                feed.finish(success: false, summary: reason)
                return ToolEnvelope.failure(
                    kind: .rejected,
                    message: reason,
                    tool: name,
                    retryable: false
                )
            }
        }

        // Reject-before-load: resolve EVERY job before one child can acquire
        // admission or change local residency. Child permission is owned by
        // the one batch gate below, so preparation never shows N panels.
        switch await Self.prepareJobs(
            jobs,
            parentScope: parentScope,
            interrupt: interrupt,
            tool: name,
            evaluationOverrides: evaluationOverrides
        ) {
        case .ready:
            break
        case .failures(let failures):
            let message = Self.preparationFailureMessage(failures)
            feed.finish(success: false, summary: message)
            return ToolEnvelope.failure(
                kind: .rejected,
                message: message,
                tool: name,
                retryable: false
            )
        case .cancelled:
            let message =
                "Batch preparation was cancelled before any jobs started."
            feed.finish(success: false, summary: message)
            return Self.earlyCancellationEnvelope(
                tool: name,
                userInterrupted: interrupt.isInterrupted
            )
        }

        feed.emitPhase(
            "authorizing batch",
            detail: "\(jobs.count) validated jobs · max \(preflightMaxParallel) parallel"
        )

        // Capture the exact authority on both sides of the policy read. A
        // setting may change while provider/target validation is suspended;
        // rejecting a torn policy/fingerprint pair is safer than showing a
        // panel for one policy and later executing under another.
        let authorityBeforePolicyRead = await Self.authorityFingerprint(
            jobs: jobs,
            parentScope: parentScope
        )
        let batchPolicy = await SpawnPermissionGate.effectivePolicy(
            for: parentScope
        )
        let approvalAuthority = await Self.authorityFingerprint(
            jobs: jobs,
            parentScope: parentScope
        )
        guard approvalAuthority == authorityBeforePolicyRead else {
            let message =
                "Batch settings, launcher, or target agents changed before approval. "
                + "No jobs were started; review the current Subagents settings and retry."
            feed.finish(success: false, summary: message)
            return ToolEnvelope.failure(
                kind: .rejected,
                message: message,
                tool: name,
                retryable: false
            )
        }

        // This is the batch's one permission decision: Ask presents exactly
        // one panel; Always Allow skips it; Deny rejects. No admission or
        // residency handoff has begun.
        let batchDecision = await SpawnPermissionGate.authorize(
            scope: parentScope,
            policy: batchPolicy,
            toolName: name,
            description:
                "Allow this agent to spawn \(jobs.count) independent bounded subagents?",
            argumentsJSON: argumentsJSON,
            cancellationRequested: {
                interrupt.isInterrupted
            }
        )
        switch batchDecision {
        case .allow:
            break
        case .denied(let reason):
            feed.finish(success: false, summary: reason)
            return ToolEnvelope.failure(
                kind: .rejected,
                message: reason,
                tool: name,
                retryable: false
            )
        case .userDenied(let reason):
            let cancelled = interrupt.isInterrupted || Task.isCancelled
            let message =
                cancelled
                ? "Batch preparation was cancelled before any jobs started."
                : reason
            feed.finish(success: false, summary: message)
            if cancelled {
                return Self.earlyCancellationEnvelope(
                    tool: name,
                    userInterrupted: interrupt.isInterrupted
                )
            }
            return ToolEnvelope.failure(
                kind: .userDenied,
                message: reason,
                tool: name,
                retryable: false
            )
        }

        let approvedAuthority = await Self.authorityFingerprint(
            jobs: jobs,
            parentScope: parentScope
        )
        guard
            Self.matchesApprovedAuthority(
                approvalAuthority,
                current: approvedAuthority
            )
        else {
            let message =
                "Batch settings, launcher, or target agents changed while approval was open. "
                + "No jobs were started; review the current Subagents settings and retry."
            feed.finish(success: false, summary: message)
            return ToolEnvelope.failure(
                kind: .rejected,
                message: message,
                tool: name,
                retryable: false
            )
        }

        // The approval panel is an asynchronous trust boundary. A user may
        // remove a target, reduce the fan-out limit, or revoke child tools
        // while it is open. Re-resolve every target from the latest persisted
        // settings after approval and before admission/model loading; prepared
        // values intentionally do not survive this boundary.
        let maxParallel: Int
        if let evaluationOverrides {
            maxParallel = evaluationOverrides.maxParallel
        } else {
            maxParallel = await Self.effectiveMaxParallel(scope: parentScope)
        }
        if let limitFailure = Self.batchLimitFailure(
            jobCount: jobs.count,
            maxJobs: maxParallel,
            tool: name
        ) {
            feed.finish(
                success: false,
                summary: "Batch settings changed before execution; revalidation failed."
            )
            return limitFailure
        }
        feed.emitPhase(
            "revalidating approved batch",
            detail: "\(jobs.count) jobs · current fan-out limit \(maxParallel)"
        )
        let prepared: [PreparedJob]
        switch await Self.prepareJobs(
            jobs,
            parentScope: parentScope,
            interrupt: interrupt,
            tool: name,
            evaluationOverrides: evaluationOverrides
        ) {
        case .ready(let current):
            prepared = current
        case .failures(let failures):
            let message =
                "Batch settings or targets changed before execution. "
                + Self.preparationFailureMessage(failures)
            feed.finish(success: false, summary: message)
            return ToolEnvelope.failure(
                kind: .rejected,
                message: message,
                tool: name,
                retryable: false
            )
        case .cancelled:
            let message =
                "Batch preparation was cancelled before any jobs started."
            feed.finish(success: false, summary: message)
            return Self.earlyCancellationEnvelope(
                tool: name,
                userInterrupted: interrupt.isInterrupted
            )
        }

        feed.emitPhase(
            "validated",
            detail: "\(jobs.count) jobs · permission granted"
        )

        let diagnostics = BatchDiagnosticsCollector()
        let cacheBefore = await ModelRuntime.batchDiagnosticsSnapshot()
        let executionAuthority = await Self.authorityFingerprint(
            jobs: jobs,
            parentScope: parentScope
        )
        guard executionAuthority == approvedAuthority else {
            let message =
                "Batch settings, launcher, or target agents changed after approval. "
                + "No jobs were started; review the current Subagents settings and retry."
            feed.finish(success: false, summary: message)
            return ToolEnvelope.failure(
                kind: .rejected,
                message: message,
                tool: name,
                retryable: false
            )
        }
        let localAdmissionPlanOverride: (@Sendable () async -> SubagentBatchAdmissionPlan)?
        if let plan = evaluationOverrides?.localAdmissionPlan {
            localAdmissionPlanOverride = { plan }
        } else {
            localAdmissionPlanOverride = nil
        }
        let results = await Self.runPreparedJobs(
            prepared,
            maxParallel: maxParallel,
            feed: feed,
            interrupt: interrupt,
            tool: name,
            localParallelismOverride: evaluationOverrides?.localParallelism,
            localAdmissionPlanOverride: localAdmissionPlanOverride,
            diagnostics: diagnostics
        )
        let cacheAfter = await ModelRuntime.batchDiagnosticsSnapshot()
        let executionWaves = await diagnostics.snapshot()
        let ordered = results.sorted { $0.job.index < $1.job.index }
        let rows = ordered.map(Self.resultRow)
        let succeeded = rows.reduce(0) { count, row in
            count + ((row["ok"] as? Bool) == true ? 1 : 0)
        }
        // A child that was already running when the batch Stop control fired
        // returns the host's honest `user_denied` envelope; a child that had
        // not started yet carries the explicit `cancelled` marker. Count both
        // only when this batch's interrupt token was actually tripped so an
        // unrelated child refusal can never be mislabeled as cancellation.
        let batchWasInterrupted = interrupt.isInterrupted
        let cancelled = rows.reduce(0) { count, row in
            let envelope = row["envelope"] as? [String: Any]
            let explicitlyCancelled = envelope?["cancelled"] as? Bool == true
            let runningChildStopped =
                batchWasInterrupted
                && envelope?["kind"] as? String
                    == ToolEnvelope.Kind.userDenied.rawValue
            return count + (explicitlyCancelled || runningChildStopped ? 1 : 0)
        }
        let failed = rows.count - succeeded
        let aggregateStatus = Self.aggregateStatus(
            succeeded: succeeded,
            failed: failed,
            cancelled: cancelled
        )
        let summary =
            "\(rows.count) batch jobs finished: \(succeeded) succeeded, \(failed) failed."
        feed.finish(success: failed == 0, summary: summary)

        let payload: [String: Any] = [
            "kind": "spawn_batch_result",
            "summary": summary,
            "max_parallel": maxParallel,
            "succeeded": succeeded,
            "failed": failed,
            "cancelled": cancelled,
            "aggregate_status": aggregateStatus,
            "execution": [
                "configured_max_subagents": maxParallel,
                "waves": executionWaves.map(\.payload),
                "cache": BatchCacheDiagnostic(
                    before: cacheBefore,
                    after: cacheAfter
                ).payload,
            ],
            "results": rows,
        ]
        return Self.aggregateEnvelope(
            tool: name,
            payload: payload,
            rows: rows,
            succeeded: succeeded,
            failed: failed
        )
    }

    /// Canonical pre-execution cancellation envelope. Keep user Stop classified
    /// as `user_denied` and parent-task cancellation as `execution_error`, while
    /// giving both paths the same machine-readable cancellation marker.
    static func earlyCancellationEnvelope(
        tool: String,
        userInterrupted: Bool
    ) -> String {
        ToolEnvelope.failure(
            kind: userInterrupted ? .userDenied : .executionError,
            message: "Batch preparation was cancelled before any jobs started.",
            tool: tool,
            retryable: false,
            metadata: ["cancelled": true]
        )
    }

    private static func prepareJobs(
        _ jobs: [Job],
        parentScope: SubagentScope,
        interrupt: InterruptToken,
        tool: String,
        evaluationOverrides: EvaluationOverrides?
    ) async -> BatchPreparationResult {
        var prepared: [PreparedJob] = []
        prepared.reserveCapacity(jobs.count)
        var failures: [(id: String, envelope: String)] = []

        for job in jobs {
            if interrupt.isInterrupted || Task.isCancelled {
                return .cancelled
            }
            let childScope = SubagentScope(
                sessionId: parentScope.sessionId,
                toolCallId: "\(parentScope.toolCallId):\(job.id)",
                agentId: parentScope.agentId,
                parentModelName: parentScope.parentModelName,
                enableThinking: parentScope.enableThinking
            )
            let kind: any SubagentKind
            if let evaluationOverrides {
                kind = evaluationOverrides.kindForJob(job)
            } else {
                switch job.targetType {
                case .agent:
                    guard let agentID = UUID(uuidString: job.target) else {
                        failures.append(
                            (
                                id: job.id,
                                envelope: ToolEnvelope.failure(
                                    kind: .invalidArgs,
                                    message:
                                        "Agent job '\(job.id)' has a target that is not a UUID.",
                                    field: "jobs[\(job.index)].target",
                                    expected: "spawnable agent UUID",
                                    tool: tool,
                                    retryable: true
                                )
                            )
                        )
                        continue
                    }
                    kind = TextSubagentKind(
                        agentID: agentID,
                        input: job.input,
                        modelOverride: Self.modelOverrideForTests,
                        permissionPreauthorized: true
                    )
                case .model:
                    kind = TextSubagentKind(
                        model: job.target,
                        input: job.input,
                        modelOverride: Self.modelOverrideForTests,
                        permissionPreauthorized: true
                    )
                }
            }
            switch await SubagentSession.prepare(
                kind,
                tool: tool,
                scope: childScope,
                interrupt: interrupt
            ) {
            case .ready(let run):
                prepared.append(PreparedJob(job: job, run: run))
            case .failure(let envelope):
                failures.append((job.id, envelope))
            }
        }

        return failures.isEmpty ? .ready(prepared) : .failures(failures)
    }

    private static func authorityFingerprint(
        jobs: [Job],
        parentScope: SubagentScope
    ) async -> BatchAuthorityFingerprint {
        // Capture configuration plus Spawn-scoped monotonic revisions in one
        // linearizable read. A cold load must not look like a mutation.
        let storeSnapshot =
            SubagentConfigurationStore
            .snapshotWithSpawnAuthorityRevisions()
        let configuration = storeSnapshot.configuration
        let isDefaultLauncher = parentScope.agentId == Agent.defaultId
        var targetAgentIDs = Set<UUID>()
        for job in jobs where job.targetType == .agent {
            if let id = UUID(uuidString: job.target) {
                targetAgentIDs.insert(id)
            }
        }
        let sortedTargetIDs = targetAgentIDs.sorted {
            $0.uuidString < $1.uuidString
        }
        let authorities = await MainActor.run {
            let launcher = AgentManager.shared.spawnAuthoritySnapshot(
                for: parentScope.agentId
            )
            return (
                launcher: launcher,
                targets: sortedTargetIDs.map { id in
                    let snapshot =
                        AgentManager.shared.spawnAuthoritySnapshot(for: id)
                    return BatchTargetAuthority(
                        id: id,
                        target: snapshot.agent.map(SpawnTargetAuthority.init),
                        revision: snapshot.revisions.target
                    )
                }
            )
        }
        let launcherSettings = authorities.launcher.agent?.settings
        let effectivePermission =
            SubagentToolVisibility.effectivePermission(
                capabilityId: SubagentCapabilityRegistry.spawn.id,
                isDefault: isDefaultLauncher,
                config: configuration,
                settings: launcherSettings
            )
        let maxParallelSpawns =
            SpawnBatchConcurrencyContract.configuredLimit(
                for: ServerRuntimeSettingsStore.snapshot()
            )

        return BatchAuthorityFingerprint(
            configurationRevision: SpawnConfigurationAuthorityRevision(
                shared: storeSnapshot.spawnSharedRevision,
                defaultLauncher:
                    isDefaultLauncher
                    ? storeSnapshot.spawnDefaultRevision
                    : nil
            ),
            maxParallelSpawns: maxParallelSpawns,
            launcher: SpawnLauncherAuthority(
                id: parentScope.agentId,
                isDefault: isDefaultLauncher,
                configuration: configuration,
                agent: authorities.launcher.agent,
                sharedParallelLimit: maxParallelSpawns
            ),
            launcherAgentRevisions: authorities.launcher.revisions,
            targets: authorities.targets,
            isDefaultLauncher: isDefaultLauncher,
            effectivePermission: effectivePermission
        )
    }

    private static func matchesApprovedAuthority(
        _ approved: BatchAuthorityFingerprint,
        current: BatchAuthorityFingerprint
    ) -> Bool {
        guard approved.launcher == current.launcher,
            approved.launcherAgentRevisions.launcher
                == current.launcherAgentRevisions.launcher,
            approved.targets == current.targets,
            approved.isDefaultLauncher == current.isDefaultLauncher,
            approved.maxParallelSpawns == current.maxParallelSpawns,
            approved.configurationRevision.shared
                == current.configurationRevision.shared
        else { return false }

        if approved.effectivePermission == current.effectivePermission {
            return current.configurationRevision.defaultLauncher
                == approved.configurationRevision.defaultLauncher
                && current.launcherAgentRevisions.permission
                    == approved.launcherAgentRevisions.permission
        }

        // The permission panel's own Ask → Always Allow write is the sole
        // permitted semantic transition. Default/main chat persists it in the
        // scoped Default Spawn authority; custom agents persist it on the
        // launcher and do not touch the shared configuration revisions.
        guard approved.effectivePermission == .ask,
            current.effectivePermission == .alwaysAllow
        else { return false }
        if approved.isDefaultLauncher {
            guard
                let approvedDefault =
                    approved.configurationRevision.defaultLauncher,
                let currentDefault =
                    current.configurationRevision.defaultLauncher
            else { return false }
            return approvedDefault < UInt64.max
                && currentDefault == approvedDefault + 1
        }
        return current.configurationRevision.defaultLauncher
            == approved.configurationRevision.defaultLauncher
            && approved.launcherAgentRevisions.permission < UInt64.max
            && current.launcherAgentRevisions.permission
                == approved.launcherAgentRevisions.permission + 1
    }

    private static func preparationFailureMessage(
        _ failures: [(id: String, envelope: String)]
    ) -> String {
        let details = failures.map { failure in
            "\(failure.id): \(ToolEnvelope.failureMessage(failure.envelope))"
        }.joined(separator: "; ")
        return "No batch jobs were started because target validation failed. \(details)"
    }

    static func parseJobs(
        _ argumentsJSON: String,
        tool: String
    ) -> Result<[Job], SpawnBatchParseError> {
        guard let data = argumentsJSON.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            return .failure(
                SpawnBatchParseError(
                    envelope: ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message: "Arguments must be a JSON object containing `jobs`.",
                        field: "jobs",
                        expected: "an array of spawn jobs",
                        tool: tool
                    )
                )
            )
        }
        let unsupportedRootFields = Set(root.keys)
            .subtracting(["jobs"])
            .sorted()
        guard unsupportedRootFields.isEmpty else {
            let fields = unsupportedRootFields.map { "`\($0)`" }
                .joined(separator: ", ")
            return .failure(
                SpawnBatchParseError(
                    envelope: ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message: "Unsupported spawn_batch argument field(s): \(fields).",
                        field: unsupportedRootFields[0],
                        expected: "only the documented `jobs` field",
                        tool: tool
                    )
                )
            )
        }
        guard let rawJobs = root["jobs"] as? [Any] else {
            return .failure(
                SpawnBatchParseError(
                    envelope: ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message: "`jobs` must be a JSON array.",
                        field: "jobs",
                        expected: "an array of spawn jobs",
                        tool: tool
                    )
                )
            )
        }
        guard jobCountBounds.contains(rawJobs.count) else {
            return .failure(
                SpawnBatchParseError(
                    envelope: ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message:
                            "`jobs` must contain \(jobCountBounds.lowerBound)-\(jobCountBounds.upperBound) items.",
                        field: "jobs",
                        expected:
                            "\(jobCountBounds.lowerBound)-\(jobCountBounds.upperBound) jobs",
                        tool: tool
                    )
                )
            )
        }

        var ids = Set<String>()
        var jobs: [Job] = []
        jobs.reserveCapacity(rawJobs.count)
        for (index, raw) in rawJobs.enumerated() {
            guard let object = raw as? [String: Any] else {
                return .failure(
                    SpawnBatchParseError.invalidJob(
                        index: index,
                        message: "must be an object",
                        tool: tool
                    )
                )
            }
            let unsupportedJobFields = Set(object.keys)
                .subtracting(["id", "target_type", "target", "input"])
                .sorted()
            guard unsupportedJobFields.isEmpty else {
                let fields = unsupportedJobFields.map { "`\($0)`" }
                    .joined(separator: ", ")
                return .failure(
                    SpawnBatchParseError.invalidJob(
                        index: index,
                        message: "contains unsupported field(s): \(fields)",
                        tool: tool
                    )
                )
            }
            guard let rawId = object["id"] as? String else {
                return .failure(
                    SpawnBatchParseError.invalidJob(
                        index: index,
                        message: "is missing string `id`",
                        tool: tool
                    )
                )
            }
            let id = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                return .failure(
                    SpawnBatchParseError.invalidJob(
                        index: index,
                        message: "has a blank `id`",
                        tool: tool
                    )
                )
            }
            guard ids.insert(id).inserted else {
                return .failure(
                    SpawnBatchParseError.invalidJob(
                        index: index,
                        message: "reuses duplicate id `\(id)`",
                        tool: tool
                    )
                )
            }
            guard let rawType = object["target_type"] as? String,
                let targetType = TargetType(
                    rawValue:
                        rawType.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).lowercased()
                )
            else {
                return .failure(
                    SpawnBatchParseError.invalidJob(
                        index: index,
                        message: "needs target_type `agent` or `model`",
                        tool: tool
                    )
                )
            }
            guard let rawTarget = object["target"] as? String else {
                return .failure(
                    SpawnBatchParseError.invalidJob(
                        index: index,
                        message: "is missing string `target`",
                        tool: tool
                    )
                )
            }
            guard let rawInput = object["input"] as? String else {
                return .failure(
                    SpawnBatchParseError.invalidJob(
                        index: index,
                        message: "is missing string `input`",
                        tool: tool
                    )
                )
            }
            let target = rawTarget.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let input = rawInput.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !target.isEmpty, !input.isEmpty else {
                return .failure(
                    SpawnBatchParseError.invalidJob(
                        index: index,
                        message: "has a blank `target` or `input`",
                        tool: tool
                    )
                )
            }
            if targetType == .agent, UUID(uuidString: target) == nil {
                return .failure(
                    SpawnBatchParseError.invalidJob(
                        index: index,
                        message: "needs an exact agent UUID in `target`",
                        tool: tool
                    )
                )
            }
            jobs.append(
                Job(
                    index: index,
                    id: id,
                    targetType: targetType,
                    target: target,
                    input: input
                )
            )
        }
        return .success(jobs)
    }

    /// The visible per-agent limit is both the maximum fan-out and the maximum
    /// concurrency for one batch. Enforce it before target resolution so an
    /// oversized call cannot acquire admission, load a model, or unload the
    /// parent even if a provider ignores the request-local JSON Schema limit.
    static func batchLimitFailure(
        jobCount: Int,
        maxJobs: Int,
        tool: String
    ) -> String? {
        let limit = max(
            SubagentBudgets.parallelSpawnBounds.lowerBound,
            min(maxJobs, SubagentBudgets.parallelSpawnBounds.upperBound)
        )
        guard jobCount <= limit else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "`jobs` contains \(jobCount) items, but this agent allows at most \(limit) subagents per batch.",
                field: "jobs",
                expected: "1-\(limit) jobs",
                tool: tool,
                retryable: true
            )
        }
        return nil
    }

    static func aggregateStatus(
        succeeded: Int,
        failed: Int,
        cancelled: Int = 0
    ) -> String {
        if failed == 0 { return "succeeded" }
        if succeeded == 0, cancelled == failed { return "all_cancelled" }
        if succeeded == 0 { return "all_failed" }
        return "partial_failure"
    }

    static func aggregateEnvelope(
        tool: String,
        payload: [String: Any],
        rows: [[String: Any]],
        succeeded: Int,
        failed: Int
    ) -> String {
        guard failed > 0, succeeded == 0 else {
            return ToolEnvelope.success(tool: tool, result: payload)
        }

        let envelopes = rows.compactMap { $0["envelope"] as? [String: Any] }
        let kinds = Set(envelopes.compactMap { $0["kind"] as? String })
        let kind: ToolEnvelope.Kind
        if kinds.count == 1,
            let raw = kinds.first,
            let exact = ToolEnvelope.Kind(rawValue: raw)
        {
            kind = exact
        } else {
            kind = .executionError
        }
        // Retrying the whole batch is safe only when every child explicitly
        // reported a retryable failure. One non-retryable child makes an
        // aggregate retry liable to repeat a denied or invalid side effect.
        let retryable =
            !envelopes.isEmpty
            && envelopes.allSatisfy { $0["retryable"] as? Bool == true }
        let summary =
            payload["summary"] as? String
            ?? "\(failed) batch jobs failed."
        return ToolEnvelope.failure(
            kind: kind,
            message: summary,
            tool: tool,
            retryable: retryable,
            metadata: ["result": payload]
        )
    }

    @MainActor
    static func effectiveMaxParallel(scope: SubagentScope) -> Int {
        let config = SubagentConfigurationStore.snapshot()
        let isDefault = scope.agentId == Agent.defaultId
        let settings = AgentManager.shared.agent(for: scope.agentId)?.settings
        return SubagentToolVisibility.effectiveBudgets(
            isDefault: isDefault,
            config: config,
            settings: settings,
            sharedParallelLimit: SpawnBatchConcurrencyContract.configuredLimit(
                for: ServerRuntimeSettingsStore.snapshot()
            )
        ).normalized.maxParallelSpawns
    }

    /// Group local work by canonical model identity while preserving the first
    /// appearance of each model and the caller order within each group. Remote
    /// jobs are intentionally absent: they run in one independent lane for the
    /// full batch instead of being attached to a local wave (which used to make
    /// a slow provider response block the next local model).
    static func makeLocalGroups(_ jobs: [PreparedJob]) -> [[PreparedJob]] {
        var order: [String] = []
        var grouped: [String: [PreparedJob]] = [:]
        for job in jobs {
            guard let key = job.localGroupingKey else { continue }
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = []
            }
            grouped[key, default: []].append(job)
        }
        return order.compactMap { grouped[$0] }
    }

    static func runPreparedJobs(
        _ jobs: [PreparedJob],
        maxParallel: Int,
        feed: SubagentFeed,
        interrupt: InterruptToken,
        tool: String,
        localParallelismOverride: Int? = nil,
        localAdmissionPlanOverride:
            (@Sendable () async -> SubagentBatchAdmissionPlan)? = nil,
        diagnostics: BatchDiagnosticsCollector? = nil
    ) async -> [RawJobResult] {
        if interrupt.isInterrupted || Task.isCancelled {
            return jobs.map {
                cancelledResult(
                    $0,
                    tool: tool,
                    userInterrupted: interrupt.isInterrupted
                )
            }
        }

        let remote = jobs.filter { $0.run.admissionModelKey == nil }
        let local = jobs.filter { $0.run.admissionModelKey != nil }
        if local.isEmpty {
            await diagnostics?.append(
                BatchWaveDiagnostic(
                    wave: 1,
                    jobs: jobs.count,
                    remoteJobs: remote.count,
                    localJobs: 0,
                    localModelKey: nil,
                    effectiveLocalSlots: 0,
                    engineSlots: nil,
                    ramSlots: nil,
                    localSubwaveSizes: [],
                    limitingFactors: [],
                    verdict: "remote_only",
                    admissionWaitSeconds: nil,
                    residencyMode: nil
                )
            )
        }
        let workerCount = remote.count + (local.isEmpty ? 0 : 1)
        return await withTaskGroup(of: BatchTaskOutput.self) { group in
            // Every remote worker starts immediately and remains independent
            // of the serial local residency lane. A slow remote R therefore
            // cannot hold local model C behind earlier local model A.
            for job in remote {
                group.addTask {
                    .results([
                        await runOne(
                            job,
                            feed: feed,
                            interrupt: interrupt
                        )
                    ])
                }
            }
            if !local.isEmpty {
                group.addTask {
                    .results(
                        await runLocalSequence(
                            local,
                            remoteJobCount: remote.count,
                            maxParallel: maxParallel,
                            localParallelismOverride: localParallelismOverride,
                            feed: feed,
                            interrupt: interrupt,
                            tool: tool,
                            diagnostics: diagnostics,
                            localAdmissionPlanOverride: localAdmissionPlanOverride
                        )
                    )
                }
            }

            // The activity-pane Stop control trips `InterruptToken`, not the
            // parent chat task. Monitor it inside the structured group and
            // actively cancel every provider/local child when it changes.
            // Child loops still receive the same token for their own
            // boundary-level cancellation and honest result mapping.
            group.addTask {
                while !Task.isCancelled {
                    if interrupt.isInterrupted {
                        return .interrupted
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(25))
                    } catch {
                        return .monitorStopped
                    }
                }
                return .monitorStopped
            }

            var results: [RawJobResult] = []
            var completedWorkers = 0
            var wasInterrupted = false
            for await output in group {
                switch output {
                case .results(let chunk):
                    results.append(contentsOf: chunk)
                    completedWorkers += 1
                    if completedWorkers == workerCount {
                        // Stop the monitor immediately after the real work
                        // finishes; otherwise it would keep the task group open.
                        group.cancelAll()
                    }
                case .interrupted:
                    wasInterrupted = true
                    group.cancelAll()
                case .monitorStopped:
                    break
                }
            }

            if wasInterrupted || interrupt.isInterrupted || Task.isCancelled {
                let completedIDs = Set(results.map(\.job.id))
                results.append(
                    contentsOf:
                        jobs
                        .filter { !completedIDs.contains($0.job.id) }
                        .map {
                            cancelledResult(
                                $0,
                                tool: tool,
                                userInterrupted: interrupt.isInterrupted
                            )
                        }
                )
            }
            return results
        }
    }

    static func localAdmissionPlan(
        localJobs: [PreparedJob],
        remoteJobCount: Int,
        maxParallel: Int,
        residencyPlanOverride: ResidencyPlan? = nil
    ) async -> SubagentBatchAdmissionPlan {
        guard let first = localJobs.first else {
            return SubagentBatchAdmissionPlanner.plan(
                SubagentBatchAdmissionInput(
                    localJobCount: 0,
                    remoteJobCount: remoteJobCount,
                    agentParallelLimit: maxParallel,
                    engineParallelLimit: 1,
                    continuousBatchingEnabled: false,
                    ramSafetyEnabled: false,
                    failClosedWhenEstimateUnknown: false,
                    memory: nil
                )
            )
        }

        let runtime = ServerRuntimeSettingsStore.snapshot()
        let configuredEngineSlots = InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(
            in: .standard,
            runtime: runtime
        )
        let engineOccupancy = await ModelRuntime.shared.batchEngineCapacitySnapshot(
            for: first.run.resolved.name,
            reconcilingTo: configuredEngineSlots
        )
        let engineWindow = engineAdmissionWindow(
            configuredMaximum: configuredEngineSlots,
            snapshot: engineOccupancy
        )
        let residencyPlan = residencyPlanOverride ?? first.run.textResidencyPlan
        let memoryFacts: SubagentBatchMemoryFacts?
        if let residencyPlan {
            memoryFacts = await ModelRuntime.shared.subagentBatchMemoryFacts(
                for: first.run.resolved.name,
                residencyPlan: residencyPlan
            )
        } else {
            // Non-text local kinds exist only in model-free test seams today.
            // Production `spawn_batch` resolves every local child through
            // `TextSubagentKind`, which always carries the actual handoff plan.
            memoryFacts = nil
        }

        var plan = makeLocalAdmissionPlan(
            localJobCount: localJobs.count,
            remoteJobCount: remoteJobCount,
            maxParallel: maxParallel,
            engineParallelLimit: engineWindow.parallelLimit,
            continuousBatchingEnabled: runtime.concurrency.continuousBatching,
            residencyPlan: residencyPlan,
            memoryFacts: memoryFacts,
            failClosedWhenEstimateUnknown: true
        )
        plan.engineOccupancy = engineOccupancy
        plan.engineQueuedAtAdmission = engineWindow.queued
        return plan
    }

    /// Bound only this caller's new submissions from an actor-consistent vMLX
    /// snapshot. This is deliberately not a reservation: BatchEngine remains
    /// the final admission authority if another chat/API/tool request races
    /// after the observation.
    static func engineAdmissionWindow(
        configuredMaximum: Int,
        snapshot: ModelBatchCapacitySnapshot?
    ) -> EngineAdmissionWindow {
        let configured = max(1, configuredMaximum)
        guard let snapshot else {
            return EngineAdmissionWindow(
                parallelLimit: configured,
                queued: false
            )
        }
        let queued =
            !snapshot.isAcceptingRequests
            || snapshot.pendingCount > 0
            || snapshot.nominalAvailableCount == 0
        guard !queued else {
            // Keep one explicit queued child rather than enqueueing the whole
            // wave behind unrelated chat/API/tool work.
            return EngineAdmissionWindow(parallelLimit: 1, queued: true)
        }
        return EngineAdmissionWindow(
            parallelLimit: max(
                1,
                min(configured, snapshot.nominalAvailableCount)
            ),
            queued: false
        )
    }

    /// Pure residency-to-capacity bridge used by production after resolving
    /// live runtime facts and by model-free tests. Keeping this mapping in one
    /// place prevents a same-resident `.none` shortcut from silently disabling
    /// the global RAM-safety policy before the admission planner sees it.
    static func makeLocalAdmissionPlan(
        localJobCount: Int,
        remoteJobCount: Int,
        maxParallel: Int,
        engineParallelLimit: Int,
        continuousBatchingEnabled: Bool,
        residencyPlan: ResidencyPlan?,
        memoryFacts: SubagentBatchMemoryFacts?,
        failClosedWhenEstimateUnknown: Bool
    ) -> SubagentBatchAdmissionPlan {
        SubagentBatchAdmissionPlanner.plan(
            SubagentBatchAdmissionInput(
                localJobCount: localJobCount,
                remoteJobCount: remoteJobCount,
                agentParallelLimit: maxParallel,
                engineParallelLimit: engineParallelLimit,
                continuousBatchingEnabled: continuousBatchingEnabled,
                ramSafetyEnabled: residencyPlan?.ramSafetyEnabled ?? false,
                failClosedWhenEstimateUnknown: failClosedWhenEstimateUnknown,
                memory: memoryFacts
            )
        )
    }

    static func runOne(
        _ job: PreparedJob,
        feed: SubagentFeed,
        interrupt: InterruptToken,
        skipAdmission: Bool = false
    ) async -> RawJobResult {
        feed.emitPhase(
            "job \(job.job.id)",
            detail: "\(job.job.targetType.rawValue): \(job.job.target)"
        )
        let childFeed = SubagentFeed(
            toolCallId: job.run.scope.toolCallId,
            kindId: SubagentCapabilityRegistry.spawn.id,
            title: "batch \(job.job.id)"
        )
        let relay = ChildFeedRelay(
            child: childFeed,
            parent: feed,
            jobID: job.job.id
        )
        let envelope = await SubagentSession.runPrepared(
            job.run,
            presentation: SubagentRunPresentation(
                feed: childFeed,
                interrupt: interrupt,
                registerWithUI: false
            ),
            skipAdmission: skipAdmission,
            handoffOverride: skipAdmission ? PassthroughHandoff() : nil,
            captureProcessCacheSnapshot: false
        )
        relay.stop()
        return RawJobResult(job: job.job, envelope: envelope)
    }

    /// Re-check every prepared child's mutable launcher/target/config
    /// authority at a batch-owned execution boundary. Text children captured
    /// this fingerprint during the post-approval prepare pass; other kinds use
    /// the protocol's no-op default.
    private static func executionAuthorityFailure(
        for jobs: [PreparedJob],
        tool: String
    ) async -> String? {
        for job in jobs {
            do {
                try await job.run.kind.validateExecutionAuthority(
                    job.run.scope,
                    resolved: job.run.resolved
                )
            } catch {
                return SubagentSession.envelope(for: error, tool: tool)
            }
        }
        return nil
    }

    /// Run every local target in one process-wide residency sequence.
    ///
    /// The sequence owns one exclusive admission lease. Same-parent/in-place
    /// groups run first, coexistence groups share one idle drain, and all
    /// different-local groups share one parent unload/restore. Remote workers
    /// are not awaited here; `runPreparedJobs` starts them in an independent
    /// lane before this sequence begins.
    static func runLocalSequence(
        _ jobs: [PreparedJob],
        firstGroupIndex: Int = 1,
        remoteJobCount: Int,
        maxParallel: Int,
        localParallelismOverride: Int?,
        feed: SubagentFeed,
        interrupt: InterruptToken,
        tool: String,
        diagnostics: BatchDiagnosticsCollector?,
        admissionController: SubagentAdmission = .shared,
        localAdmissionPlanOverride:
            (@Sendable () async -> SubagentBatchAdmissionPlan)? = nil,
        liveResidencyPlanOverride:
            (@Sendable (PreparedSubagentRun) async throws -> ResidencyPlan)? = nil,
        localModelTransitionOverride: LocalModelTransition? = nil,
        finalLocalModelCleanupOverride: FinalLocalModelCleanup? = nil
    ) async -> [RawJobResult] {
        let groups = makeLocalGroups(jobs)
        guard !groups.isEmpty else { return [] }

        // A single canonical group that is already resident can share the
        // model's BatchEngine with other same-model spawn calls. Reserve its
        // process-wide sequence width before falling back to the exclusive
        // residency lane. Multiple models, coexistence loads, and swapped
        // targets still require one aggregate exclusive handoff.
        if groups.count == 1,
            let inPlaceResults = await runReservedInPlaceGroupIfEligible(
                groups[0],
                waveIndex: firstGroupIndex,
                remoteJobCount: remoteJobCount,
                maxParallel: maxParallel,
                localParallelismOverride: localParallelismOverride,
                feed: feed,
                interrupt: interrupt,
                tool: tool,
                diagnostics: diagnostics,
                admissionController: admissionController,
                localAdmissionPlanOverride: localAdmissionPlanOverride,
                liveResidencyPlanOverride: liveResidencyPlanOverride
            )
        {
            return inPlaceResults
        }

        let admissionClass = SubagentAdmissionClass.localExclusive
        let sequenceModelKey = groups.compactMap {
            $0.first?.run.admissionModelKey
        }.joined(separator: " → ")
        let admissionStarted = Date()
        let admission = await admissionController.admit(
            admissionClass,
            modelKey: sequenceModelKey,
            onWait: { [feed] active in
                feed.emitPhase("waiting for local GPU", detail: active)
            },
            cancellationRequested: { interrupt.isInterrupted }
        )
        let admissionWaitSeconds = Date().timeIntervalSince(admissionStarted)

        switch admission {
        case .admitted:
            break
        case .timedOut(let active):
            await appendSequenceFailureDiagnostics(
                groups: groups,
                firstGroupIndex: firstGroupIndex,
                remoteJobCount: remoteJobCount,
                verdict: "admission_timed_out",
                admissionWaitSeconds: admissionWaitSeconds,
                diagnostics: diagnostics
            )
            return jobs.map {
                RawJobResult(
                    job: $0.job,
                    envelope: ToolEnvelope.failure(
                        kind: .unavailable,
                        message:
                            "\(tool) waited on \(active) and did not start in time.",
                        tool: tool,
                        retryable: true
                    )
                )
            }
        case .cancelled:
            await appendSequenceFailureDiagnostics(
                groups: groups,
                firstGroupIndex: firstGroupIndex,
                remoteJobCount: remoteJobCount,
                verdict: "admission_cancelled",
                admissionWaitSeconds: admissionWaitSeconds,
                diagnostics: diagnostics
            )
            return jobs.map {
                cancelledResult($0, tool: tool, userInterrupted: true)
            }
        }

        if interrupt.isInterrupted || Task.isCancelled {
            await admissionController.release(
                admissionClass,
                modelKey: sequenceModelKey
            )
            return jobs.map {
                cancelledResult(
                    $0,
                    tool: tool,
                    userInterrupted: interrupt.isInterrupted
                )
            }
        }

        if let authorityFailure = await executionAuthorityFailure(
            for: jobs,
            tool: tool
        ) {
            await admissionController.release(
                admissionClass,
                modelKey: sequenceModelKey
            )
            return jobs.map {
                RawJobResult(job: $0.job, envelope: authorityFailure)
            }
        }

        // Resolve all plans only after admission. This preserves the existing
        // reject-before-load phase while ensuring settings, parent residency,
        // and RAM pressure are current when the one sequence begins.
        var resolvedGroups: [ResolvedLocalGroup] = []
        var results: [RawJobResult] = []
        for (offset, groupJobs) in groups.enumerated() {
            guard let first = groupJobs.first else { continue }
            do {
                let plan: ResidencyPlan
                if let liveResidencyPlanOverride {
                    plan = try await liveResidencyPlanOverride(first.run)
                } else if let textKind = first.run.kind as? TextSubagentKind {
                    plan = try await textKind.refreshedResidencyPlanAfterAdmission(
                        for: first.run.resolved
                    )
                } else {
                    plan = first.run.textResidencyPlan ?? .none
                }
                resolvedGroups.append(
                    ResolvedLocalGroup(
                        jobs: groupJobs,
                        initialResidencyPlan: plan
                    )
                )
            } catch {
                let envelope = SubagentSession.envelope(for: error, tool: tool)
                results.append(
                    contentsOf: groupJobs.map {
                        RawJobResult(job: $0.job, envelope: envelope)
                    }
                )
                await diagnostics?.append(
                    BatchWaveDiagnostic(
                        wave: firstGroupIndex + offset,
                        jobs: groupJobs.count + remoteJobCount,
                        remoteJobs: remoteJobCount,
                        localJobs: groupJobs.count,
                        localModelKey: first.run.admissionModelKey,
                        effectiveLocalSlots: 0,
                        engineSlots: nil,
                        ramSlots: nil,
                        localSubwaveSizes: [],
                        limitingFactors: [],
                        verdict: "live_residency_rejected",
                        admissionWaitSeconds: admissionWaitSeconds,
                        residencyMode: nil
                    )
                )
            }
        }

        if !resolvedGroups.isEmpty {
            let allText = resolvedGroups.allSatisfy {
                $0.jobs.first?.run.kind is TextSubagentKind
            }
            if allText {
                // Independent batch jobs may be reordered by residency mode.
                // Run any same-parent groups while that parent is still
                // resident, then coexistence jobs, then the swapped targets.
                let inPlace = resolvedGroups.filter {
                    !$0.initialResidencyPlan.shouldUnload
                        && !$0.initialResidencyPlan.coexists
                }
                let coexist = resolvedGroups.filter {
                    $0.initialResidencyPlan.coexists
                }
                let swapped = resolvedGroups.filter {
                    $0.initialResidencyPlan.shouldUnload
                }

                if !inPlace.isEmpty {
                    results.append(
                        contentsOf: await runLocalGroups(
                            inPlace,
                            around: ResidencyOwnershipHandoff(
                                wrapping: PassthroughHandoff()
                            ),
                            firstGroupIndex: firstGroupIndex,
                            remoteJobCount: remoteJobCount,
                            maxParallel: maxParallel,
                            localParallelismOverride: localParallelismOverride,
                            admissionWaitSeconds: admissionWaitSeconds,
                            feed: feed,
                            interrupt: interrupt,
                            tool: tool,
                            diagnostics: diagnostics,
                            localAdmissionPlanOverride: localAdmissionPlanOverride,
                            localModelTransition:
                                localModelTransitionOverride
                                ?? productionLocalModelTransition,
                            finalLocalModelCleanup:
                                finalLocalModelCleanupOverride
                                ?? productionFinalLocalModelCleanup
                        )
                    )
                }
                if !coexist.isEmpty {
                    let plan = aggregateResidencyPlan(
                        coexist.map(\.initialResidencyPlan),
                        shouldUnload: false,
                        coexists: true
                    )
                    results.append(
                        contentsOf: await runLocalGroups(
                            coexist,
                            around: ResidencyOwnershipHandoff(
                                wrapping: SubagentResidency.handoff(for: plan)
                            ),
                            firstGroupIndex: firstGroupIndex + inPlace.count,
                            remoteJobCount: remoteJobCount,
                            maxParallel: maxParallel,
                            localParallelismOverride: localParallelismOverride,
                            admissionWaitSeconds: admissionWaitSeconds,
                            feed: feed,
                            interrupt: interrupt,
                            tool: tool,
                            diagnostics: diagnostics,
                            localAdmissionPlanOverride: localAdmissionPlanOverride,
                            localModelTransition:
                                localModelTransitionOverride
                                ?? productionLocalModelTransition,
                            finalLocalModelCleanup:
                                finalLocalModelCleanupOverride
                                ?? productionFinalLocalModelCleanup
                        )
                    )
                }
                if !swapped.isEmpty {
                    let plan = aggregateResidencyPlan(
                        swapped.map(\.initialResidencyPlan),
                        shouldUnload: true,
                        coexists: false
                    )
                    results.append(
                        contentsOf: await runLocalGroups(
                            swapped,
                            around: SubagentResidency.handoff(for: plan),
                            firstGroupIndex:
                                firstGroupIndex + inPlace.count + coexist.count,
                            remoteJobCount: remoteJobCount,
                            maxParallel: maxParallel,
                            localParallelismOverride: localParallelismOverride,
                            admissionWaitSeconds: admissionWaitSeconds,
                            feed: feed,
                            interrupt: interrupt,
                            tool: tool,
                            diagnostics: diagnostics,
                            localAdmissionPlanOverride: localAdmissionPlanOverride,
                            localModelTransition:
                                localModelTransitionOverride
                                ?? productionLocalModelTransition,
                            finalLocalModelCleanup:
                                finalLocalModelCleanupOverride
                                ?? productionFinalLocalModelCleanup
                        )
                    )
                }
            } else {
                // Model-free test kinds and any future non-text local kind own
                // their handoff directly. One sequence still means exactly one
                // invocation, never one unload/restore per canonical target.
                let handoff =
                    resolvedGroups.first?.jobs.first?.run.handoff
                    ?? PassthroughHandoff()
                results.append(
                    contentsOf: await runLocalGroups(
                        resolvedGroups,
                        around: handoff,
                        firstGroupIndex: firstGroupIndex,
                        remoteJobCount: remoteJobCount,
                        maxParallel: maxParallel,
                        localParallelismOverride: localParallelismOverride,
                        admissionWaitSeconds: admissionWaitSeconds,
                        feed: feed,
                        interrupt: interrupt,
                        tool: tool,
                        diagnostics: diagnostics,
                        localAdmissionPlanOverride: localAdmissionPlanOverride,
                        localModelTransition: localModelTransitionOverride,
                        finalLocalModelCleanup:
                            resolvedGroups.allSatisfy {
                                $0.initialResidencyPlan.shouldUnload
                                    && !$0.initialResidencyPlan.coexists
                            }
                            ? finalLocalModelCleanupOverride : nil
                    )
                )
            }
        }

        await admissionController.release(
            admissionClass,
            modelKey: sequenceModelKey
        )
        return results
    }

    /// Run one already-resident canonical local group under a process-wide
    /// same-model slot reservation. Returns `nil` only when a fresh residency
    /// check says the target now needs coexistence or an unload, in which case
    /// the caller retries through the exclusive aggregate sequence.
    private static func runReservedInPlaceGroupIfEligible(
        _ groupJobs: [PreparedJob],
        waveIndex: Int,
        remoteJobCount: Int,
        maxParallel: Int,
        localParallelismOverride: Int?,
        feed: SubagentFeed,
        interrupt: InterruptToken,
        tool: String,
        diagnostics: BatchDiagnosticsCollector?,
        admissionController: SubagentAdmission,
        localAdmissionPlanOverride:
            (@Sendable () async -> SubagentBatchAdmissionPlan)?,
        liveResidencyPlanOverride:
            (@Sendable (PreparedSubagentRun) async throws -> ResidencyPlan)?
    ) async -> [RawJobResult]? {
        guard let first = groupJobs.first else { return [] }

        // Preparation already classified this run from the then-current
        // residency state. Use that side-effect-free classification only to
        // choose the candidate lane; the authoritative live plan is refreshed
        // after admission, where a different-model run cannot race it.
        guard first.run.admissionClass == .localInPlace else { return nil }
        let initialResidency = first.run.textResidencyPlan ?? .none
        guard
            !initialResidency.shouldUnload,
            !initialResidency.coexists
        else {
            return nil
        }

        let initialGroup = ResolvedLocalGroup(
            jobs: groupJobs,
            initialResidencyPlan: initialResidency
        )
        let initialPlan: SubagentBatchAdmissionPlan
        if let localAdmissionPlanOverride {
            initialPlan = await localAdmissionPlanOverride()
        } else {
            initialPlan = await localAdmissionPlan(
                localJobs: groupJobs,
                remoteJobCount: remoteJobCount,
                maxParallel: maxParallel,
                residencyPlanOverride: initialResidency
            )
        }
        guard case .admitted = initialPlan.verdict else {
            return await rejectedLocalGroupResults(
                initialGroup,
                plan: initialPlan,
                waveIndex: waveIndex,
                remoteJobCount: remoteJobCount,
                admissionWaitSeconds: 0,
                tool: tool,
                diagnostics: diagnostics
            )
        }

        let desiredSlots =
            localParallelismOverride.map {
                max(1, min($0, initialPlan.localParallelism))
            }
            ?? initialPlan.localParallelism
        let admissionStarted = Date()
        let reservation = await admissionController.reserveLocalInPlace(
            modelKey: first.run.admissionModelKey,
            requestedSlots: desiredSlots,
            slotCapacity: initialPlan.localCapacity,
            onWait: { [feed] active in
                feed.emitPhase("waiting for local GPU", detail: active)
            },
            cancellationRequested: { interrupt.isInterrupted }
        )
        let admissionWaitSeconds = Date().timeIntervalSince(admissionStarted)

        let grantedSlots: Int
        switch reservation {
        case .admitted(let slots):
            grantedSlots = slots
        case .timedOut(let active):
            await diagnostics?.append(
                BatchWaveDiagnostic(
                    wave: waveIndex,
                    jobs: groupJobs.count + remoteJobCount,
                    remoteJobs: remoteJobCount,
                    localJobs: groupJobs.count,
                    localModelKey: first.run.admissionModelKey,
                    effectiveLocalSlots: 0,
                    engineSlots: initialPlan.engineSlots,
                    ramSlots: initialPlan.ramSlots,
                    localSubwaveSizes: [],
                    limitingFactors:
                        initialPlan.limitingFactors.map(\.rawValue).sorted(),
                    verdict: "admission_timed_out",
                    admissionWaitSeconds: admissionWaitSeconds,
                    residencyMode: residencyMode(initialResidency),
                    engineOccupancy: initialPlan.engineOccupancy,
                    engineQueuedAtAdmission: initialPlan.engineQueuedAtAdmission
                )
            )
            return groupJobs.map {
                RawJobResult(
                    job: $0.job,
                    envelope: ToolEnvelope.failure(
                        kind: .unavailable,
                        message:
                            "\(tool) waited on \(active) and did not start in time.",
                        tool: tool,
                        retryable: true
                    )
                )
            }
        case .cancelled:
            return groupJobs.map {
                cancelledResult($0, tool: tool, userInterrupted: true)
            }
        }

        if interrupt.isInterrupted || Task.isCancelled {
            await admissionController.releaseLocalInPlace(
                modelKey: first.run.admissionModelKey,
                slots: grantedSlots
            )
            return groupJobs.map {
                cancelledResult(
                    $0,
                    tool: tool,
                    userInterrupted: interrupt.isInterrupted
                )
            }
        }

        if let authorityFailure = await executionAuthorityFailure(
            for: groupJobs,
            tool: tool
        ) {
            await admissionController.releaseLocalInPlace(
                modelKey: first.run.admissionModelKey,
                slots: grantedSlots
            )
            return groupJobs.map {
                RawJobResult(job: $0.job, envelope: authorityFailure)
            }
        }

        // Residency and settings may change while this call waits. Re-check
        // after the atomic reservation; if a handoff is now required, release
        // every slot and let the exclusive path re-plan from the new state.
        let liveResidency: ResidencyPlan
        do {
            liveResidency = try await refreshedResidencyPlan(
                for: first.run,
                override: liveResidencyPlanOverride
            )
        } catch {
            await admissionController.releaseLocalInPlace(
                modelKey: first.run.admissionModelKey,
                slots: grantedSlots
            )
            return nil
        }
        guard
            !liveResidency.shouldUnload,
            !liveResidency.coexists
        else {
            await admissionController.releaseLocalInPlace(
                modelKey: first.run.admissionModelKey,
                slots: grantedSlots
            )
            return nil
        }

        let livePlan: SubagentBatchAdmissionPlan
        if let localAdmissionPlanOverride {
            livePlan = await localAdmissionPlanOverride()
        } else {
            livePlan = await localAdmissionPlan(
                localJobs: groupJobs,
                remoteJobCount: remoteJobCount,
                maxParallel: maxParallel,
                residencyPlanOverride: liveResidency
            )
        }
        guard case .admitted = livePlan.verdict else {
            await admissionController.releaseLocalInPlace(
                modelKey: first.run.admissionModelKey,
                slots: grantedSlots
            )
            return await rejectedLocalGroupResults(
                ResolvedLocalGroup(
                    jobs: groupJobs,
                    initialResidencyPlan: liveResidency
                ),
                plan: livePlan,
                waveIndex: waveIndex,
                remoteJobCount: remoteJobCount,
                admissionWaitSeconds: admissionWaitSeconds,
                tool: tool,
                diagnostics: diagnostics
            )
        }

        let effectiveSlots = await admissionController.resizeLocalInPlace(
            modelKey: first.run.admissionModelKey,
            heldSlots: grantedSlots,
            requestedSlots: min(grantedSlots, livePlan.localParallelism),
            slotCapacity: livePlan.localCapacity
        )
        guard effectiveSlots > 0 else {
            await diagnostics?.append(
                BatchWaveDiagnostic(
                    wave: waveIndex,
                    jobs: groupJobs.count + remoteJobCount,
                    remoteJobs: remoteJobCount,
                    localJobs: groupJobs.count,
                    localModelKey: first.run.admissionModelKey,
                    effectiveLocalSlots: 0,
                    engineSlots: livePlan.engineSlots,
                    ramSlots: livePlan.ramSlots,
                    localSubwaveSizes: [],
                    limitingFactors:
                        livePlan.limitingFactors.map(\.rawValue).sorted(),
                    verdict: "rejected:capacity_changed",
                    admissionWaitSeconds: admissionWaitSeconds,
                    residencyMode: residencyMode(liveResidency),
                    engineOccupancy: livePlan.engineOccupancy,
                    engineQueuedAtAdmission: livePlan.engineQueuedAtAdmission
                )
            )
            return groupJobs.map {
                RawJobResult(
                    job: $0.job,
                    envelope: ToolEnvelope.failure(
                        kind: .unavailable,
                        message:
                            "Local batch capacity changed while \(tool) was waiting; "
                            + "this batch did not start. Retry with the current "
                            + "Server and RAM-safety settings.",
                        tool: tool,
                        retryable: true
                    )
                )
            }
        }
        let liveGroup = ResolvedLocalGroup(
            jobs: groupJobs,
            initialResidencyPlan: liveResidency
        )
        let results = await runAdmittedLocalGroups(
            [liveGroup],
            firstGroupIndex: waveIndex,
            remoteJobCount: remoteJobCount,
            maxParallel: maxParallel,
            localParallelismOverride: effectiveSlots,
            admissionWaitSeconds: admissionWaitSeconds,
            feed: feed,
            interrupt: interrupt,
            tool: tool,
            diagnostics: diagnostics,
            localAdmissionPlanOverride: { livePlan },
            localModelTransition: nil
        )
        await admissionController.releaseLocalInPlace(
            modelKey: first.run.admissionModelKey,
            slots: effectiveSlots
        )
        return results
    }

    private static func refreshedResidencyPlan(
        for run: PreparedSubagentRun,
        override:
            (@Sendable (PreparedSubagentRun) async throws -> ResidencyPlan)?
    ) async throws -> ResidencyPlan {
        if let override {
            return try await override(run)
        }
        if let textKind = run.kind as? TextSubagentKind {
            return try await textKind.refreshedResidencyPlanAfterAdmission(
                for: run.resolved
            )
        }
        return run.textResidencyPlan ?? .none
    }

    private static func rejectedLocalGroupResults(
        _ group: ResolvedLocalGroup,
        plan: SubagentBatchAdmissionPlan,
        waveIndex: Int,
        remoteJobCount: Int,
        admissionWaitSeconds: Double,
        tool: String,
        diagnostics: BatchDiagnosticsCollector?
    ) async -> [RawJobResult] {
        guard let first = group.jobs.first else { return [] }
        let reason: SubagentBatchAdmissionRejection
        if case .rejected(let rejection) = plan.verdict {
            reason = rejection
        } else {
            preconditionFailure("admitted batch plan cannot use rejection results")
        }
        await diagnostics?.append(
            BatchWaveDiagnostic(
                wave: waveIndex,
                jobs: group.jobs.count + remoteJobCount,
                remoteJobs: remoteJobCount,
                localJobs: group.jobs.count,
                localModelKey: first.run.admissionModelKey,
                effectiveLocalSlots: 0,
                engineSlots: plan.engineSlots,
                ramSlots: plan.ramSlots,
                localSubwaveSizes: [],
                limitingFactors: plan.limitingFactors.map(\.rawValue).sorted(),
                verdict: "rejected:\(reason.rawValue)",
                admissionWaitSeconds: admissionWaitSeconds,
                residencyMode: residencyMode(group.initialResidencyPlan),
                engineOccupancy: plan.engineOccupancy,
                engineQueuedAtAdmission: plan.engineQueuedAtAdmission
            )
        )
        return group.jobs.map {
            RawJobResult(
                job: $0.job,
                envelope: ToolEnvelope.failure(
                    kind: .unavailable,
                    message:
                        "Local batch admission rejected before handoff: \(reason.rawValue).",
                    tool: tool,
                    retryable: reason != .invalidParallelLimit
                )
            )
        }
    }

    /// Backward-compatible focused-test seam for one local group.
    static func runLocalGroup(
        _ jobs: [PreparedJob],
        waveIndex: Int,
        remoteJobCount: Int,
        maxParallel: Int,
        localParallelismOverride: Int?,
        feed: SubagentFeed,
        interrupt: InterruptToken,
        tool: String,
        diagnostics: BatchDiagnosticsCollector?,
        admissionController: SubagentAdmission = .shared,
        localAdmissionPlanOverride:
            (@Sendable () async -> SubagentBatchAdmissionPlan)? = nil,
        liveResidencyPlanOverride:
            (@Sendable (PreparedSubagentRun) async throws -> ResidencyPlan)? = nil,
        localModelTransitionOverride: LocalModelTransition? = nil,
        finalLocalModelCleanupOverride: FinalLocalModelCleanup? = nil
    ) async -> [RawJobResult] {
        await runLocalSequence(
            jobs,
            firstGroupIndex: waveIndex,
            remoteJobCount: remoteJobCount,
            maxParallel: maxParallel,
            localParallelismOverride: localParallelismOverride,
            feed: feed,
            interrupt: interrupt,
            tool: tool,
            diagnostics: diagnostics,
            admissionController: admissionController,
            localAdmissionPlanOverride: localAdmissionPlanOverride,
            liveResidencyPlanOverride: liveResidencyPlanOverride,
            localModelTransitionOverride: localModelTransitionOverride,
            finalLocalModelCleanupOverride: finalLocalModelCleanupOverride
        )
    }

    private static func runLocalGroups(
        _ groups: [ResolvedLocalGroup],
        around handoff: any SubagentHandoff,
        firstGroupIndex: Int,
        remoteJobCount: Int,
        maxParallel: Int,
        localParallelismOverride: Int?,
        admissionWaitSeconds: Double,
        feed: SubagentFeed,
        interrupt: InterruptToken,
        tool: String,
        diagnostics: BatchDiagnosticsCollector?,
        localAdmissionPlanOverride:
            (@Sendable () async -> SubagentBatchAdmissionPlan)?,
        localModelTransition: LocalModelTransition?,
        finalLocalModelCleanup: FinalLocalModelCleanup?
    ) async -> [RawJobResult] {
        guard let first = groups.first?.jobs.first else { return [] }
        let allJobs = groups.flatMap(\.jobs)
        if let authorityFailure = await executionAuthorityFailure(
            for: allJobs,
            tool: tool
        ) {
            return allJobs.map {
                RawJobResult(job: $0.job, envelope: authorityFailure)
            }
        }
        let box = SpawnBatchResultBox()
        do {
            _ = try await handoff.around(
                scope: first.run.scope,
                resolved: first.run.resolved,
                feed: feed
            ) {
                box.results = await runAdmittedLocalGroups(
                    groups,
                    firstGroupIndex: firstGroupIndex,
                    remoteJobCount: remoteJobCount,
                    maxParallel: maxParallel,
                    localParallelismOverride: localParallelismOverride,
                    admissionWaitSeconds: admissionWaitSeconds,
                    feed: feed,
                    interrupt: interrupt,
                    tool: tool,
                    diagnostics: diagnostics,
                    localAdmissionPlanOverride: localAdmissionPlanOverride,
                    localModelTransition: localModelTransition,
                    onGroupStarted: { run, jobIDs in
                        box.lastStartedRun = run
                        box.lastStartedJobIDs = jobIDs
                    }
                )
                if let finalLocalModelCleanup,
                    let finalRun = box.lastStartedRun
                {
                    try await finalLocalModelCleanup(finalRun, feed, tool)
                }
                return SubagentResult(payload: [:])
            }
            return box.results
        } catch {
            let completedIDs = Set(box.results.map(\.job.id))
            let envelope = SubagentSession.envelope(for: error, tool: tool)
            let pending: [RawJobResult] = groups.flatMap(\.jobs).compactMap {
                job -> RawJobResult? in
                guard !completedIDs.contains(job.job.id) else { return nil }
                return RawJobResult(job: job.job, envelope: envelope)
            }
            guard pending.isEmpty else {
                return box.results + pending
            }

            // A post-body cleanup/restore failure occurs after every child has
            // already produced an envelope. Replace one result from the last
            // resident group so the batch cannot aggregate to false success,
            // while preserving the exact child envelope as structured context.
            var reported = box.results
            let affectedIDs = Set(box.lastStartedJobIDs)
            guard
                let index = reported.lastIndex(where: {
                    affectedIDs.contains($0.job.id)
                })
            else {
                return reported
            }
            let original = reported[index]
            reported[index] = RawJobResult(
                job: original.job,
                envelope: ToolEnvelope.failure(
                    kind: .executionError,
                    message: error.localizedDescription,
                    tool: tool,
                    retryable: true,
                    metadata: [
                        "child_envelope_before_handoff_failure": original.envelope
                    ]
                )
            )
            return reported
        }
    }

    private static func runAdmittedLocalGroups(
        _ groups: [ResolvedLocalGroup],
        firstGroupIndex: Int,
        remoteJobCount: Int,
        maxParallel: Int,
        localParallelismOverride: Int?,
        admissionWaitSeconds: Double,
        feed: SubagentFeed,
        interrupt: InterruptToken,
        tool: String,
        diagnostics: BatchDiagnosticsCollector?,
        localAdmissionPlanOverride:
            (@Sendable () async -> SubagentBatchAdmissionPlan)?,
        localModelTransition: LocalModelTransition?,
        onGroupStarted:
            (@Sendable (_ run: PreparedSubagentRun, _ jobIDs: [String]) -> Void)? = nil
    ) async -> [RawJobResult] {
        var results: [RawJobResult] = []
        var previousGroup: ResolvedLocalGroup?
        for (offset, group) in groups.enumerated() {
            if let previousGroup,
                let localModelTransition,
                let previous = previousGroup.jobs.first?.run,
                let next = group.jobs.first?.run
            {
                // Cleanup is owned state transition, not cancellable child
                // work. Even when Stop arrives between groups, finish draining
                // the previous child before returning cancellation rows.
                if let failure = await localModelTransition(
                    previous,
                    next,
                    feed,
                    tool
                ) {
                    results.append(
                        contentsOf: groups.dropFirst(offset).flatMap(\.jobs).map {
                            RawJobResult(job: $0.job, envelope: failure)
                        }
                    )
                    break
                }
            }

            if interrupt.isInterrupted || Task.isCancelled {
                results.append(
                    contentsOf: groups.dropFirst(offset).flatMap(\.jobs).map {
                        cancelledResult(
                            $0,
                            tool: tool,
                            userInterrupted: interrupt.isInterrupted
                        )
                    }
                )
                break
            }
            if let run = group.jobs.first?.run {
                onGroupStarted?(run, group.jobs.map(\.job.id))
            }
            results.append(
                contentsOf: await runAdmittedLocalGroup(
                    group,
                    waveIndex: firstGroupIndex + offset,
                    remoteJobCount: remoteJobCount,
                    maxParallel: maxParallel,
                    localParallelismOverride: localParallelismOverride,
                    admissionWaitSeconds: admissionWaitSeconds,
                    feed: feed,
                    interrupt: interrupt,
                    tool: tool,
                    diagnostics: diagnostics,
                    localAdmissionPlanOverride: localAdmissionPlanOverride
                )
            )
            previousGroup = group
        }
        return results
    }

    private static func runAdmittedLocalGroup(
        _ group: ResolvedLocalGroup,
        waveIndex: Int,
        remoteJobCount: Int,
        maxParallel: Int,
        localParallelismOverride: Int?,
        admissionWaitSeconds: Double,
        feed: SubagentFeed,
        interrupt: InterruptToken,
        tool: String,
        diagnostics: BatchDiagnosticsCollector?,
        localAdmissionPlanOverride:
            (@Sendable () async -> SubagentBatchAdmissionPlan)?
    ) async -> [RawJobResult] {
        guard let first = group.jobs.first else { return [] }
        let plan: SubagentBatchAdmissionPlan
        if let localAdmissionPlanOverride {
            plan = await localAdmissionPlanOverride()
        } else {
            // The enclosing group handoff has already performed every actual
            // parent unload. Per-group admission MUST NOT count any currently
            // resident model as "releasable parent" because no child-level
            // handoff runs (`skipAdmission` uses PassthroughHandoff). For
            // different local groups, the explicit child transition above has
            // already unloaded the prior target before these live facts are
            // sampled.
            var postHandoffPlan = group.initialResidencyPlan
            postHandoffPlan.shouldUnload = false
            plan = await localAdmissionPlan(
                localJobs: group.jobs,
                remoteJobCount: remoteJobCount,
                maxParallel: maxParallel,
                residencyPlanOverride: postHandoffPlan
            )
        }
        guard case .admitted = plan.verdict else {
            let reason: SubagentBatchAdmissionRejection
            if case .rejected(let rejection) = plan.verdict {
                reason = rejection
            } else {
                preconditionFailure("non-admitted batch plan must carry a rejection")
            }
            await diagnostics?.append(
                BatchWaveDiagnostic(
                    wave: waveIndex,
                    jobs: group.jobs.count + remoteJobCount,
                    remoteJobs: remoteJobCount,
                    localJobs: group.jobs.count,
                    localModelKey: first.run.admissionModelKey,
                    effectiveLocalSlots: 0,
                    engineSlots: plan.engineSlots,
                    ramSlots: plan.ramSlots,
                    localSubwaveSizes: [],
                    limitingFactors: plan.limitingFactors.map(\.rawValue).sorted(),
                    verdict: "rejected:\(reason.rawValue)",
                    admissionWaitSeconds: admissionWaitSeconds,
                    residencyMode: residencyMode(group.initialResidencyPlan),
                    engineOccupancy: plan.engineOccupancy,
                    engineQueuedAtAdmission: plan.engineQueuedAtAdmission
                )
            )
            return group.jobs.map {
                RawJobResult(
                    job: $0.job,
                    envelope: ToolEnvelope.failure(
                        kind: .unavailable,
                        message:
                            "Local batch admission rejected before handoff: \(reason.rawValue).",
                        tool: tool,
                        retryable: reason != .invalidParallelLimit
                    )
                )
            }
        }

        let slots =
            localParallelismOverride.map {
                max(1, min($0, plan.localParallelism))
            }
            ?? plan.localParallelism
        let subwaves = SubagentBatchAdmissionPlanner.subwaveSizes(
            jobCount: group.jobs.count,
            slots: slots
        )
        let ram = plan.ramSlots.map(String.init) ?? "unbounded/unknown"
        let limiting =
            plan.limitingFactors.map(\.rawValue).sorted().joined(separator: ", ")
        feed.emitPhase(
            "local batch capacity",
            detail:
                "\(group.jobs.count) requested · up to \(slots) scheduled · "
                + "engine \(plan.engineSlots) · RAM \(ram)"
                + (limiting.isEmpty ? "" : " · limited by \(limiting)")
        )
        await diagnostics?.append(
            BatchWaveDiagnostic(
                wave: waveIndex,
                jobs: group.jobs.count + remoteJobCount,
                remoteJobs: remoteJobCount,
                localJobs: group.jobs.count,
                localModelKey: first.run.admissionModelKey,
                effectiveLocalSlots: slots,
                engineSlots: plan.engineSlots,
                ramSlots: plan.ramSlots,
                localSubwaveSizes: subwaves,
                limitingFactors: plan.limitingFactors.map(\.rawValue).sorted(),
                verdict: "admitted",
                admissionWaitSeconds: admissionWaitSeconds,
                residencyMode: residencyMode(group.initialResidencyPlan),
                engineOccupancy: plan.engineOccupancy,
                engineQueuedAtAdmission: plan.engineQueuedAtAdmission
            )
        )

        var results: [RawJobResult] = []
        var start = 0
        while start < group.jobs.count {
            if interrupt.isInterrupted || Task.isCancelled {
                results.append(
                    contentsOf: group.jobs[start...].map {
                        cancelledResult(
                            $0,
                            tool: tool,
                            userInterrupted: interrupt.isInterrupted
                        )
                    }
                )
                break
            }
            let end = min(start + slots, group.jobs.count)
            let subwave = Array(group.jobs[start ..< end])
            feed.emitPhase(
                "local subwave",
                detail:
                    "\(subwave.count) submitted · jobs \(start + 1)-\(end) "
                    + "of \(group.jobs.count)"
            )
            results.append(
                contentsOf: await withTaskGroup(of: RawJobResult.self) { taskGroup in
                    for job in subwave {
                        taskGroup.addTask {
                            await runOne(
                                job,
                                feed: feed,
                                interrupt: interrupt,
                                skipAdmission: true
                            )
                        }
                    }
                    var values: [RawJobResult] = []
                    for await value in taskGroup {
                        values.append(value)
                    }
                    return values
                }
            )
            start = end
        }
        return results
    }

    /// Production A → B local child transition. `ModelRuntime.unload` owns the
    /// complete cancellation/BatchEngine shutdown/lease drain/Metal teardown
    /// sequence. Its lease drain is bounded and fail-closed: a non-cooperative
    /// producer leaves the old model intact, reports an honest failure, and B
    /// is never started. The teardown itself is still fully awaited, so Stop
    /// cannot abandon live Metal work.
    private static func productionLocalModelTransition(
        previous: PreparedSubagentRun,
        next: PreparedSubagentRun,
        feed: SubagentFeed,
        tool: String
    ) async -> String? {
        guard previous.admissionModelKey != next.admissionModelKey else { return nil }

        let previousName = runtimeModelName(for: previous)
        let nextName = runtimeModelName(for: next)
        let unloaded = await unloadLocalSubagentModel(
            previous,
            feed: feed,
            phase: "transitioning local subagent model",
            detail: "unloading \(previousName) before \(nextName)"
        )
        guard unloaded else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message:
                    "Could not safely finish unloading local subagent model '\(previousName)' "
                    + "within the lease-drain budget "
                    + "before starting '\(nextName)'. The remaining batch jobs were not started.",
                tool: tool,
                retryable: true
            )
        }
        return nil
    }

    /// Release the final swapped child before the aggregate handoff restores
    /// its parent. Flexible coexistence never binds this cleanup; it is solely
    /// the terminal leg of an explicit non-coexistence sequence.
    private static func productionFinalLocalModelCleanup(
        current: PreparedSubagentRun,
        feed: SubagentFeed,
        tool: String
    ) async throws {
        let currentName = runtimeModelName(for: current)
        let unloaded = await unloadLocalSubagentModel(
            current,
            feed: feed,
            phase: "releasing final local subagent model",
            detail: "unloading \(currentName) before restoring the orchestrator"
        )
        guard unloaded else {
            throw SubagentError.executionFailed(
                message:
                    "Could not safely finish unloading final local subagent model "
                    + "'\(currentName)' before restoring the orchestrator.",
                retryable: true
            )
        }
    }

    /// One owned child teardown implementation for both A → B transitions and
    /// final-child release. The detached operation does not inherit Stop
    /// cancellation. The timeout passed to `ModelRuntime.unload` bounds its
    /// model-lease drain only; the preceding BatchEngine producer/Metal drain
    /// remains correctness-first and can take longer. Do not describe this as
    /// a bounded end-to-end Stop/teardown deadline.
    private static func unloadLocalSubagentModel(
        _ run: PreparedSubagentRun,
        feed: SubagentFeed,
        phase: String,
        detail: String
    ) async -> Bool {
        let name = runtimeModelName(for: run)
        feed.emitPhase(phase, detail: detail)
        let leaseDrainTimeoutSeconds = min(
            Double(run.textResidencyPlan?.maxElapsedSeconds ?? 300),
            5.0
        )
        guard let ownershipToken = ModelResidencyOwnershipContext.childOwnershipToken else {
            // No aggregate handoff means this batch did not cold-load and own
            // a swappable child. Never fall back to unloading by model name.
            return true
        }
        let operation = Task.detached(priority: .userInitiated) {
            let result = await ModelRuntime.shared.unloadChildOwned(
                name: name,
                by: ownershipToken,
                leaseDrainTimeoutSeconds: leaseDrainTimeoutSeconds
            )
            switch result {
            case .unloaded, .notResident:
                return true
            case .notOwned:
                // A pre-existing API/plugin/local target is intentionally
                // preserved. The next load/parent restore will either coexist
                // under policy or fail closed; this cleanup never steals it.
                return true
            case .identityChanged, .drainTimedOut:
                return false
            }
        }
        return await operation.value
    }

    /// Runtime containers are keyed by the installed bundle's canonical name,
    /// while prepared jobs may carry a full repository id. Resolve the same
    /// canonical key ModelRuntime uses before requesting an unload.
    private static func runtimeModelName(
        for run: PreparedSubagentRun
    ) -> String {
        let lookup = run.resolved.id ?? run.resolved.name
        return
            ModelManager.findInstalledModel(named: lookup)?.name
            ?? ModelManager.findInstalledModel(named: run.resolved.name)?.name
            ?? run.resolved.name
    }

    private static func aggregateResidencyPlan(
        _ plans: [ResidencyPlan],
        shouldUnload: Bool,
        coexists: Bool
    ) -> ResidencyPlan {
        ResidencyPlan(
            shouldUnload: shouldUnload,
            requiredBytes: plans.map(\.requiredBytes).max() ?? 0,
            ramSafetyEnabled: plans.contains { $0.ramSafetyEnabled },
            maxElapsedSeconds: plans.map(\.maxElapsedSeconds).max() ?? 300,
            coexists: coexists
        )
    }

    private static func appendSequenceFailureDiagnostics(
        groups: [[PreparedJob]],
        firstGroupIndex: Int,
        remoteJobCount: Int,
        verdict: String,
        admissionWaitSeconds: Double,
        diagnostics: BatchDiagnosticsCollector?
    ) async {
        for (offset, group) in groups.enumerated() {
            await diagnostics?.append(
                BatchWaveDiagnostic(
                    wave: firstGroupIndex + offset,
                    jobs: group.count + remoteJobCount,
                    remoteJobs: remoteJobCount,
                    localJobs: group.count,
                    localModelKey: group.first?.run.admissionModelKey,
                    effectiveLocalSlots: 0,
                    engineSlots: nil,
                    ramSlots: nil,
                    localSubwaveSizes: [],
                    limitingFactors: [],
                    verdict: verdict,
                    admissionWaitSeconds: admissionWaitSeconds,
                    residencyMode: nil
                )
            )
        }
    }

    private static func residencyMode(_ plan: ResidencyPlan) -> String {
        if plan.shouldUnload { return "unload_restore" }
        if plan.coexists { return "coexist_idle_drain" }
        return "in_place"
    }

    static func cancelledResult(
        _ job: PreparedJob,
        tool: String,
        userInterrupted: Bool = false
    ) -> RawJobResult {
        RawJobResult(
            job: job.job,
            envelope: ToolEnvelope.failure(
                kind: userInterrupted ? .userDenied : .executionError,
                message: "Batch job was cancelled before it started.",
                tool: tool,
                retryable: false,
                metadata: ["cancelled": true]
            )
        )
    }

    static func resultRow(_ result: RawJobResult) -> [String: Any] {
        let envelopeObject: [String: Any]
        if let data = result.envelope.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        {
            envelopeObject = decoded
        } else {
            envelopeObject = [
                "ok": false,
                "kind": "execution_error",
                "message": "Worker returned an unreadable result envelope.",
            ]
        }
        return [
            "id": result.job.id,
            "target_type": result.job.targetType.rawValue,
            "target": result.job.target,
            "ok": envelopeObject["ok"] as? Bool ?? false,
            "envelope": envelopeObject,
        ]
    }

    /// Request-local schema narrowing. The executor independently enforces the
    /// target-specific allow-lists; this union enum gives local models and
    /// providers exact spelling guidance without pretending JSON Schema can
    /// express a target_type-dependent enum portably.
    static func constrainedSpec(
        _ tool: Tool,
        allowedAgentIDs: [UUID],
        allowedModelIds: [String],
        maxParallel: Int
    ) -> Tool {
        let agents = SpawnableAgentIdentity.normalizedIDs(allowedAgentIDs)
            .map(\.uuidString)
            .sorted()
        let models = SubagentConfiguration.normalizedSpawnableModelNames(
            allowedModelIds
        )
        let targets = Array(Set(agents + models)).sorted()
        guard !targets.isEmpty,
            case .object(var root)? = tool.function.parameters,
            case .object(var properties)? = root["properties"],
            case .object(var jobs)? = properties["jobs"],
            case .object(var items)? = jobs["items"],
            case .object(var jobProperties)? = items["properties"],
            case .object(var target)? = jobProperties["target"]
        else { return tool }

        target["enum"] = .array(targets.map(JSONValue.string))
        target["description"] = .string(
            "Exact allowed target. Agent UUIDs: \(agents.joined(separator: ", ")). "
                + "Models: \(models.joined(separator: ", "))."
        )
        jobProperties["target"] = .object(target)
        items["properties"] = .object(jobProperties)
        jobs["items"] = .object(items)
        let batchLimit = max(
            SubagentBudgets.parallelSpawnBounds.lowerBound,
            min(maxParallel, SubagentBudgets.parallelSpawnBounds.upperBound)
        )
        jobs["maxItems"] = .number(Double(batchLimit))
        jobs["description"] = .string(
            "Independent jobs. This agent allows at most \(batchLimit) jobs in one batch, "
                + "and at most \(batchLimit) execute concurrently; results preserve input order."
        )
        properties["jobs"] = .object(jobs)
        root["properties"] = .object(properties)
        return Tool(
            type: tool.type,
            function: ToolFunction(
                name: tool.function.name,
                description: tool.function.description,
                parameters: .object(root)
            )
        )
    }
}

struct SpawnBatchParseError: Error, Sendable {
    let envelope: String

    static func invalidJob(
        index: Int,
        message: String,
        tool: String
    ) -> SpawnBatchParseError {
        SpawnBatchParseError(
            envelope: ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "jobs[\(index)] \(message).",
                field: "jobs[\(index)]",
                expected:
                    "an object with unique id, target_type, target, and input",
                tool: tool
            )
        )
    }
}

extension Result where Failure == SpawnBatchParseError {
    var failureEnvelope: String? {
        guard case .failure(let error) = self else { return nil }
        return error.envelope
    }
}

private final class SpawnBatchResultBox: @unchecked Sendable {
    var results: [SpawnBatchTool.RawJobResult] = []
    var lastStartedRun: PreparedSubagentRun?
    var lastStartedJobIDs: [String] = []
}
