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
//  - one wave contains at most the configured number of jobs;
//  - remote jobs may overlap;
//  - a wave contains at most one canonical local model, so different local
//    models never race cold loads or residency handoffs;
//  - same-model local jobs share one admission slot and one handoff, then run
//    concurrently through the model's shared BatchEngine;
//  - results are returned in caller order with one honest envelope per job.
//

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
                                "Exact allowed agent name or model id for target_type."
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
            ]),
        ]),
        "required": .array([.string("jobs")]),
    ])

    public var bypassRegistryTimeout: Bool { true }

    public init() {}

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
        let maxParallel = await Self.effectiveMaxParallel(scope: parentScope)
        if let limitFailure = Self.batchLimitFailure(
            jobCount: jobs.count,
            maxJobs: maxParallel,
            tool: name
        ) {
            return limitFailure
        }

        // Reject-before-load: resolve and authorize EVERY job before one child
        // can acquire admission or change local residency.
        var prepared: [PreparedJob] = []
        prepared.reserveCapacity(jobs.count)
        var preparationFailures: [(id: String, envelope: String)] = []
        for job in jobs {
            let childScope = SubagentScope(
                sessionId: parentScope.sessionId,
                toolCallId: "\(parentScope.toolCallId):\(job.id)",
                agentId: parentScope.agentId,
                enableThinking: parentScope.enableThinking
            )
            let kind: TextSubagentKind
            switch job.targetType {
            case .agent:
                kind = TextSubagentKind(agentName: job.target, input: job.input)
            case .model:
                kind = TextSubagentKind(model: job.target, input: job.input)
            }
            switch await SubagentSession.prepare(
                kind,
                tool: name,
                scope: childScope
            ) {
            case .ready(let run):
                prepared.append(PreparedJob(job: job, run: run))
            case .failure(let envelope):
                preparationFailures.append((job.id, envelope))
            }
        }

        guard preparationFailures.isEmpty else {
            let details = preparationFailures.map { failure in
                "\(failure.id): \(ToolEnvelope.failureMessage(failure.envelope))"
            }.joined(separator: "; ")
            return ToolEnvelope.failure(
                kind: .rejected,
                message:
                    "No batch jobs were started because target validation failed. \(details)",
                tool: name,
                retryable: false
            )
        }

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
            "validated",
            detail: "\(jobs.count) jobs · max \(maxParallel) parallel"
        )

        let results = await Self.runPreparedJobs(
            prepared,
            maxParallel: maxParallel,
            feed: feed,
            interrupt: interrupt,
            tool: name
        )
        let ordered = results.sorted { $0.job.index < $1.job.index }
        let rows = ordered.map(Self.resultRow)
        let succeeded = rows.reduce(0) { count, row in
            count + ((row["ok"] as? Bool) == true ? 1 : 0)
        }
        let failed = rows.count - succeeded
        let summary =
            "\(rows.count) batch jobs finished: \(succeeded) succeeded, \(failed) failed."
        feed.finish(success: failed == 0, summary: summary)

        return ToolEnvelope.success(
            tool: name,
            result: [
                "kind": "spawn_batch_result",
                "summary": summary,
                "max_parallel": maxParallel,
                "succeeded": succeeded,
                "failed": failed,
                "results": rows,
            ]
        )
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

    @MainActor
    static func effectiveMaxParallel(scope: SubagentScope) -> Int {
        let config = SubagentConfigurationStore.snapshot()
        let isDefault = scope.agentId == Agent.defaultId
        let settings = AgentManager.shared.agent(for: scope.agentId)?.settings
        return SubagentToolVisibility.effectiveBudgets(
            isDefault: isDefault,
            config: config,
            settings: settings
        ).normalized.maxParallelSpawns
    }

    /// Create bounded waves. A wave can contain any number of remote jobs up
    /// to the remaining capacity, but only one canonical local grouping key.
    /// Different local models therefore serialize without preventing remote
    /// work from overlapping the active local group.
    static func makeWaves(
        _ jobs: [PreparedJob],
        maxParallel: Int
    ) -> [[PreparedJob]] {
        let limit = max(
            SubagentBudgets.parallelSpawnBounds.lowerBound,
            min(maxParallel, SubagentBudgets.parallelSpawnBounds.upperBound)
        )
        var pending = jobs
        var waves: [[PreparedJob]] = []
        while !pending.isEmpty {
            var wave: [PreparedJob] = []
            var deferred: [PreparedJob] = []
            var localKey: String?
            for job in pending {
                guard wave.count < limit else {
                    deferred.append(job)
                    continue
                }
                guard let key = job.localGroupingKey else {
                    wave.append(job)
                    continue
                }
                if localKey == nil || localKey == key {
                    localKey = key
                    wave.append(job)
                } else {
                    deferred.append(job)
                }
            }
            // The loop always takes at least the first pending job.
            waves.append(wave)
            pending = deferred
        }
        return waves
    }

    static func runPreparedJobs(
        _ jobs: [PreparedJob],
        maxParallel: Int,
        feed: SubagentFeed,
        interrupt: InterruptToken,
        tool: String
    ) async -> [RawJobResult] {
        let waves = makeWaves(jobs, maxParallel: maxParallel)
        var results: [RawJobResult] = []
        for (waveIndex, wave) in waves.enumerated() {
            if interrupt.isInterrupted || Task.isCancelled {
                results.append(
                    contentsOf: wave.flatMap { job in
                        [Self.cancelledResult(job, tool: tool)]
                    }
                )
                let remaining = waves.dropFirst(waveIndex + 1).flatMap { $0 }
                results.append(
                    contentsOf: remaining.map {
                        Self.cancelledResult($0, tool: tool)
                    }
                )
                break
            }
            feed.emitPhase(
                "batch wave \(waveIndex + 1)",
                detail: "\(wave.count) job\(wave.count == 1 ? "" : "s")"
            )
            results.append(
                contentsOf: await runWave(
                    wave,
                    feed: feed,
                    interrupt: interrupt,
                    tool: tool
                )
            )
        }
        return results
    }

    static func runWave(
        _ jobs: [PreparedJob],
        feed: SubagentFeed,
        interrupt: InterruptToken,
        tool: String
    ) async -> [RawJobResult] {
        let remote = jobs.filter { $0.run.admissionModelKey == nil }
        let local = jobs.filter { $0.run.admissionModelKey != nil }
        return await withTaskGroup(of: [RawJobResult].self) { group in
            for job in remote {
                group.addTask {
                    [
                        await runOne(
                            job,
                            feed: feed,
                            interrupt: interrupt
                        )
                    ]
                }
            }
            if !local.isEmpty {
                group.addTask {
                    await runLocalGroup(
                        local,
                        feed: feed,
                        interrupt: interrupt,
                        tool: tool
                    )
                }
            }
            var results: [RawJobResult] = []
            for await chunk in group {
                results.append(contentsOf: chunk)
            }
            return results
        }
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
        let envelope = await SubagentSession.runPrepared(
            job.run,
            presentation: SubagentRunPresentation(
                feed: childFeed,
                interrupt: interrupt,
                registerWithUI: false
            ),
            skipAdmission: skipAdmission,
            handoffOverride: skipAdmission ? PassthroughHandoff() : nil
        )
        return RawJobResult(job: job.job, envelope: envelope)
    }

    /// Run one canonical local-model group under one admission slot and one
    /// residency handoff. Child runs skip their individual admission/handoff,
    /// so a different parent model is unloaded once, the shared local model is
    /// loaded/coalesced once, and the parent is restored once.
    static func runLocalGroup(
        _ jobs: [PreparedJob],
        feed: SubagentFeed,
        interrupt: InterruptToken,
        tool: String
    ) async -> [RawJobResult] {
        guard let first = jobs.first else { return [] }
        let admissionClass = first.run.admissionClass
        let modelKey = first.run.admissionModelKey
        let admission = await SubagentAdmission.shared.admit(
            admissionClass,
            modelKey: modelKey,
            onWait: { [feed] active in
                feed.emitPhase("waiting for local GPU", detail: active)
            }
        )
        switch admission {
        case .admitted:
            break
        case .timedOut(let active):
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
            return jobs.map { cancelledResult($0, tool: tool) }
        }

        let box = SpawnBatchResultBox()
        do {
            _ = try await first.run.handoff.around(
                scope: first.run.scope,
                resolved: first.run.resolved,
                feed: feed
            ) {
                box.results = await withTaskGroup(
                    of: RawJobResult.self
                ) { group in
                    for job in jobs {
                        group.addTask {
                            await runOne(
                                job,
                                feed: feed,
                                interrupt: interrupt,
                                skipAdmission: true
                            )
                        }
                    }
                    var values: [RawJobResult] = []
                    for await value in group {
                        values.append(value)
                    }
                    return values
                }
                return SubagentResult(payload: [:])
            }
            await SubagentAdmission.shared.release(
                admissionClass,
                modelKey: modelKey
            )
            return box.results
        } catch {
            await SubagentAdmission.shared.release(
                admissionClass,
                modelKey: modelKey
            )
            let envelope = SubagentSession.envelope(for: error, tool: tool)
            if box.results.isEmpty {
                return jobs.map {
                    RawJobResult(job: $0.job, envelope: envelope)
                }
            }
            return box.results
        }
    }

    static func cancelledResult(
        _ job: PreparedJob,
        tool: String
    ) -> RawJobResult {
        RawJobResult(
            job: job.job,
            envelope: ToolEnvelope.failure(
                kind: .executionError,
                message: "Batch job was cancelled before it started.",
                tool: tool,
                retryable: false
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
        allowedAgentNames: [String],
        allowedModelIds: [String],
        maxParallel: Int
    ) -> Tool {
        let agents = Array(
            Dictionary(
                allowedAgentNames
                    .map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    .filter { !$0.isEmpty }
                    .map { ($0.lowercased(), $0) },
                uniquingKeysWith: { first, _ in first }
            ).values
        ).sorted()
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
            "Exact allowed target. Agents: \(agents.joined(separator: ", ")). "
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
}
