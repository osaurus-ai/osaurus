//
//  SwarmModelService.swift
//  osaurus
//
//  The Swarm provider on the model-service seam. Chat, agents, subagents,
//  workflows, schedules and the HTTP API (Chat Completions and Responses)
//  all reach a pool model through here, exactly like a remote provider:
//  the master keeps the agent loop, tools, memory and storage; only the
//  model request goes to a node. Per request this:
//
//  1. leases a node from the pool (FIFO queue up to the pool's max wait,
//     with a visible "Waiting for a Swarm node" state, then a typed
//     `swarm_pool_busy` error — never a silent fallback);
//  2. sends the OpenAI Chat Completions body with only the sampling values
//     the caller set explicitly, so the node's bundle defaults apply;
//  3. maps the node's structured events onto the in-band stream every
//     consumer already reads (content, reasoning, tool calls, prefill
//     progress, completion stats with token/s);
//  4. cancels on the node when the caller stops, and retries on another
//     node of the same pool with the same idempotency key when the lease is
//     lost before any output reached the caller.
//

import Foundation

/// One pool × model as pickers and routing see it.
struct SwarmCatalogEntry: Sendable, Equatable {
    let pickerModelId: String
    let pool: SwarmPool
    let modelId: String
    /// Pool members that have the model installed.
    let memberNodes: Int
    /// Of those, how many accept leases right now.
    let availableNodes: Int
    /// Of those, how many have the model loaded.
    let warmNodes: Int

    var displayName: String {
        "\(SwarmModelIdentity.shortModelName(modelId)) · \(pool.name)"
    }

    var capacityText: String {
        if availableNodes == 0 { return L("No nodes available") }
        var text = String(format: L("%d of %d nodes available"), availableNodes, memberNodes)
        if warmNodes > 0 { text += " · " + String(format: L("%d warm"), warmNodes) }
        return text
    }
}

extension SwarmCatalogEntry {
    /// One entry per pool × model, whether or not a node is free right now:
    /// a pool with no available node stays selectable and queues.
    static func entries(pools: [SwarmPool], nodes: [SwarmNodeSnapshot]) -> [SwarmCatalogEntry] {
        let byId = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var entries: [SwarmCatalogEntry] = []
        for pool in pools {
            for modelId in pool.modelIds {
                let pickerId = SwarmModelIdentity.make(poolName: pool.name, modelId: modelId)
                guard seen.insert(pickerId.lowercased()).inserted else { continue }
                let members = pool.nodeIds.compactMap { byId[$0] }.filter { $0.model(modelId) != nil }
                entries.append(
                    SwarmCatalogEntry(
                        pickerModelId: pickerId,
                        pool: pool,
                        modelId: modelId,
                        memberNodes: members.count,
                        availableNodes: members.filter { $0.availability.acceptsLeases }.count,
                        warmNodes: members.filter { $0.model(modelId)?.loadState == .warm }.count
                    )
                )
            }
        }
        return entries
    }
}

/// Lease and request lifecycle notifications for the Activity tab.
enum SwarmActivityEvent: Sendable {
    case waiting(requestId: String, pool: String, model: String)
    case leased(requestId: String, lease: SwarmLease, nodeName: String)
    case finished(
        requestId: String,
        lease: SwarmLease,
        nodeName: String,
        tokens: Int,
        tokensPerSecond: Double,
        finishReason: String?
    )
    case failed(requestId: String, pool: String, model: String, nodeName: String?, error: String)
    case cancelled(requestId: String, lease: SwarmLease?, nodeName: String?)
    case retrying(requestId: String, fromNode: String, reason: String)
}

final class SwarmModelService: ToolCapableService, @unchecked Sendable {
    let id = "osaurus-swarm"

    private let lock = NSLock()
    private var backend: (any SwarmMasterBackend)?
    private var catalog: [String: SwarmCatalogEntry] = [:]
    private var nodeNames: [SwarmNodeID: String] = [:]
    private let report: @Sendable (SwarmActivityEvent) -> Void

    init(report: @escaping @Sendable (SwarmActivityEvent) -> Void = { _ in }) {
        self.report = report
    }

    // MARK: - State pushed by SwarmManager

    func update(
        backend: (any SwarmMasterBackend)?,
        catalog entries: [SwarmCatalogEntry],
        nodeNames: [SwarmNodeID: String]
    ) {
        lock.lock()
        self.backend = backend
        self.catalog = Dictionary(entries.map { ($0.pickerModelId.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        self.nodeNames = nodeNames
        lock.unlock()
    }

    func entry(for requestedModel: String?) -> SwarmCatalogEntry? {
        guard let requestedModel else { return nil }
        let key = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lock.lock()
        defer { lock.unlock() }
        return catalog[key]
    }

    private func snapshot() -> (backend: (any SwarmMasterBackend)?, names: [SwarmNodeID: String]) {
        lock.lock()
        defer { lock.unlock() }
        return (backend, nodeNames)
    }

    // MARK: - ModelService

    func isAvailable() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return backend != nil
    }

    func handles(requestedModel: String?) -> Bool {
        entry(for: requestedModel) != nil
    }

    func generateOneShot(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?
    ) async throws -> String {
        let stream = try await streamWithTools(
            messages: messages,
            parameters: parameters,
            stopSequences: [],
            tools: [],
            toolChoice: nil,
            requestedModel: requestedModel
        )
        var text = ""
        for try await delta in stream where !StreamingToolHint.isSentinel(delta) {
            text += delta
        }
        return text
    }

    func streamDeltas(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?,
        stopSequences: [String]
    ) async throws -> AsyncThrowingStream<String, Error> {
        try await streamWithTools(
            messages: messages,
            parameters: parameters,
            stopSequences: stopSequences,
            tools: [],
            toolChoice: nil,
            requestedModel: requestedModel
        )
    }

    func respondWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        requestedModel: String?
    ) async throws -> String {
        let stream = try await streamWithTools(
            messages: messages,
            parameters: parameters,
            stopSequences: stopSequences,
            tools: tools,
            toolChoice: toolChoice,
            requestedModel: requestedModel
        )
        var text = ""
        for try await delta in stream where !StreamingToolHint.isSentinel(delta) {
            text += delta
        }
        return text
    }

    func streamWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        requestedModel: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let entry = entry(for: requestedModel) else {
            throw SwarmError.poolNotFound(requestedModel ?? "")
        }
        guard let backend = snapshot().backend else { throw SwarmError.unavailable }
        let body = try Self.chatBody(
            modelId: entry.modelId,
            messages: messages,
            parameters: parameters,
            stopSequences: stopSequences,
            tools: tools,
            toolChoice: toolChoice
        )
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let task = Task { [weak self] in
            guard let self else {
                continuation.finish(throwing: SwarmError.unavailable)
                return
            }
            await self.run(
                entry: entry,
                backend: backend,
                body: body,
                offeredToolNames: Set(tools.map(\.function.name)),
                parameters: parameters,
                continuation: continuation
            )
        }
        continuation.onTermination = { termination in
            if case .cancelled = termination { task.cancel() }
        }
        return stream
    }

    // MARK: - Request lifecycle

    static let waitingHintDelay: Duration = .milliseconds(300)

    private struct Attempt {
        var lease: SwarmLease?
        var requestId: String
    }

    private func run(
        entry: SwarmCatalogEntry,
        backend: any SwarmMasterBackend,
        body: Data,
        offeredToolNames: Set<String>,
        parameters: GenerationParameters,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        let callerKey = parameters.sessionId.map { "session:\($0)" } ?? "activity:\(parameters.activityID.uuidString)"
        let idempotencyKey = parameters.idempotencyKey ?? "swarm-\(parameters.activityID.uuidString.lowercased())"
        let names = snapshot().names
        var excluded: Set<SwarmNodeID> = []
        var attempt = Attempt(lease: nil, requestId: UUID().uuidString.lowercased())
        var emittedOutput = false

        while true {
            do {
                let candidates = excluded.isEmpty ? [] : entry.pool.nodeIds.filter { !excluded.contains($0) }
                if !excluded.isEmpty, candidates.isEmpty {
                    throw SwarmError.poolBusy(pool: entry.pool.name, waitedSeconds: 0)
                }
                // Show "Waiting for a Swarm node" only when the grant is not
                // immediate (queued behind other callers, or no node free).
                let requestId = attempt.requestId
                let report = self.report
                let waitingHint = Task {
                    try? await Task.sleep(for: Self.waitingHintDelay)
                    guard !Task.isCancelled else { return }
                    report(.waiting(requestId: requestId, pool: entry.pool.name, model: entry.modelId))
                    guard !parameters.suppressProgressUI else { return }
                    continuation.yield(
                        StreamingPrefillProgressHint.encode(
                            PrefillProgressState(
                                stage: .queued,
                                completedUnitCount: 0,
                                totalUnitCount: 0,
                                detail: String(format: L("Waiting for a Swarm node in %@"), entry.pool.name)
                            )
                        )
                    )
                }
                let lease: SwarmLease
                do {
                    lease = try await backend.acquireLease(
                        SwarmLeaseRequest(
                            poolId: entry.pool.id,
                            nodeIds: candidates,
                            modelId: entry.modelId,
                            leaseSeconds: entry.pool.leaseSeconds,
                            maxWaitSeconds: entry.pool.maxQueueWaitSeconds,
                            callerKey: callerKey
                        )
                    )
                    waitingHint.cancel()
                } catch {
                    waitingHint.cancel()
                    throw error
                }
                attempt.lease = lease
                let nodeName = names[lease.nodeId] ?? lease.nodeId
                report(.leased(requestId: attempt.requestId, lease: lease, nodeName: nodeName))
                try Task.checkCancellation()

                let events = try await backend.infer(
                    nodeId: lease.nodeId,
                    request: SwarmInferenceRequest(
                        requestId: attempt.requestId,
                        leaseId: lease.id,
                        idempotencyKey: idempotencyKey,
                        modelId: entry.modelId,
                        chatBodyJSON: body,
                        cacheChainId: parameters.sessionId,
                        cacheIntent: parameters.auxiliaryCacheIntent
                            ? "auxiliary" : (parameters.warmupPrefill ? "warmup" : nil)
                    )
                )
                var mapper = SwarmEventMapper(
                    requireCompleteOutput: parameters.requireCompleteOutput,
                    offeredToolNames: offeredToolNames
                )
                for try await event in events {
                    for delta in mapper.map(event) {
                        continuation.yield(delta)
                    }
                    if mapper.emittedOutput { emittedOutput = true }
                    // A node that calls a tool it was not offered is
                    // misbehaving: stop it and fail the request typed.
                    if let violation = mapper.violation {
                        await backend.cancelInference(requestId: attempt.requestId)
                        throw violation
                    }
                }
                if Task.isCancelled { throw CancellationError() }
                let info = mapper.completion
                report(
                    .finished(
                        requestId: attempt.requestId,
                        lease: lease,
                        nodeName: nodeName,
                        tokens: info?.completionTokens ?? mapper.outputEvents,
                        tokensPerSecond: info?.tokensPerSecond ?? 0,
                        finishReason: info?.finishReason
                    )
                )
                if let error = mapper.terminalError() {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
                return
            } catch is CancellationError {
                await backend.cancelInference(requestId: attempt.requestId)
                report(
                    .cancelled(
                        requestId: attempt.requestId,
                        lease: attempt.lease,
                        nodeName: attempt.lease.map { names[$0.nodeId] ?? $0.nodeId }
                    )
                )
                continuation.finish(throwing: CancellationError())
                return
            } catch {
                if Task.isCancelled {
                    await backend.cancelInference(requestId: attempt.requestId)
                    continuation.finish(throwing: CancellationError())
                    return
                }
                let swarmError = error as? SwarmError
                let nodeName = attempt.lease.map { names[$0.nodeId] ?? $0.nodeId }
                // A lost lease before any output is safe to retry on another
                // node: the idempotency key stays the same.
                if let swarmError, swarmError.isRetryableOnAnotherNode, !emittedOutput,
                    let lost = attempt.lease
                {
                    excluded.insert(lost.nodeId)
                    report(
                        .retrying(
                            requestId: attempt.requestId,
                            fromNode: nodeName ?? lost.nodeId,
                            reason: swarmError.localizedDescription
                        )
                    )
                    await backend.releaseLease(lost.id)
                    attempt = Attempt(lease: nil, requestId: UUID().uuidString.lowercased())
                    continue
                }
                report(
                    .failed(
                        requestId: attempt.requestId,
                        pool: entry.pool.name,
                        model: entry.modelId,
                        nodeName: nodeName,
                        error: error.localizedDescription
                    )
                )
                // Mid-generation loss is a typed lease-lost failure, never a
                // silent retry that could duplicate visible output.
                if let swarmError, swarmError.isRetryableOnAnotherNode, emittedOutput {
                    if case .leaseLost = swarmError {
                        continuation.finish(throwing: swarmError)
                    } else {
                        continuation.finish(throwing: SwarmError.leaseLost(reason: swarmError.localizedDescription))
                    }
                } else {
                    continuation.finish(throwing: error)
                }
                return
            }
        }
    }

    // MARK: - Request body

    /// The OpenAI Chat Completions body for the node. Sampling values are
    /// sent only when the caller set them explicitly, so the node's model
    /// bundle `generation_config.json` stays the default.
    static func chatBody(
        modelId: String,
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?
    ) throws -> Data {
        func json<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
        }
        var body: [String: Any] = [
            "model": modelId,
            "messages": try json(messages),
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if !tools.isEmpty {
            body["tools"] = try json(tools)
            if let toolChoice { body["tool_choice"] = try json(toolChoice) }
        }
        if parameters.maxTokensExplicit { body["max_tokens"] = parameters.maxTokens }
        if !parameters.samplingParametersAreImplicit {
            if let t = parameters.temperature { body["temperature"] = Double(t) }
            if let p = parameters.topPOverride { body["top_p"] = Double(p) }
            if let k = parameters.topKOverride { body["top_k"] = k }
            if let m = parameters.minPOverride { body["min_p"] = Double(m) }
            if let r = parameters.repetitionPenalty { body["repetition_penalty"] = Double(r) }
        }
        if let f = parameters.frequencyPenalty { body["frequency_penalty"] = Double(f) }
        if let p = parameters.presencePenalty { body["presence_penalty"] = Double(p) }
        if let seed = parameters.seed { body["seed"] = seed }
        if !stopSequences.isEmpty { body["stop"] = stopSequences }
        if let schema = parameters.responseSchema {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": "response", "schema": try json(schema), "strict": true],
            ]
        } else if let schemaText = parameters.jsonSchema,
            let schema = try? JSONSerialization.jsonObject(with: Data(schemaText.utf8))
        {
            body["response_format"] = [
                "type": "json_schema", "json_schema": ["name": "response", "schema": schema, "strict": true],
            ]
        } else if parameters.jsonMode {
            body["response_format"] = ["type": "json_object"]
        }
        var templateKwargs: [String: Any] = [:]
        if let kwargs = parameters.templateKwargs, let object = try json(kwargs) as? [String: Any] {
            templateKwargs = object
        }
        // Only an explicit user choice turns reasoning off; otherwise the
        // template's own default stands.
        if RemoteReasoningPolicy.requestsReasoningOff(parameters.modelOptions),
            templateKwargs["enable_thinking"] == nil
        {
            templateKwargs["enable_thinking"] = false
        }
        if !templateKwargs.isEmpty { body["chat_template_kwargs"] = templateKwargs }
        if let effort = parameters.modelOptions["reasoningEffort"]?.stringValue, !effort.isEmpty {
            body["reasoning_effort"] = effort
        }
        if let budget = parameters.reasoningBudgetTokens { body["thinking_budget"] = budget }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}

/// Node events → the in-band string stream (`StreamingToolHint` and
/// friends) every Osaurus consumer reads.
///
/// A node is an untrusted peer, like a cloud API: its text cannot carry the
/// stream's private `U+FFFE` hint sentinels (they are stripped, so node text
/// can never forge a tool, stats, billing or progress hint), it may only call
/// tools this request offered, with arguments that parse as a JSON object,
/// and its finish reason is reduced to a plain token before it rides the
/// stats hint.
struct SwarmEventMapper {
    let requireCompleteOutput: Bool
    let offeredToolNames: Set<String>
    private(set) var toolCalls: [Int: ServiceToolInvocation] = [:]
    private(set) var completion: SwarmCompletionInfo?
    private(set) var emittedOutput = false
    private(set) var outputEvents = 0
    /// Set when the node broke the tool contract; the request fails with it.
    private(set) var violation: SwarmError?

    init(requireCompleteOutput: Bool = false, offeredToolNames: Set<String> = []) {
        self.requireCompleteOutput = requireCompleteOutput
        self.offeredToolNames = offeredToolNames
    }

    /// Removes the noncharacters the in-band protocol reserves (`U+FFFE`
    /// starts every hint; `U+FFFF` is reserved alongside it).
    static func stripSentinels(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value == 0xFFFE || $0.value == 0xFFFF }) else { return text }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { $0.value != 0xFFFE && $0.value != 0xFFFF })
        return String(scalars)
    }

    /// `stop`, `length`, `tool_calls`, …: letters, digits and `_` only, so a
    /// node cannot smuggle extra stats flags (`,` / `;` / `=`).
    static func plainFinishReason(_ reason: String?) -> String? {
        guard let reason else { return nil }
        let kept = String(
            reason.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" }.map(Character.init)
        )
        return kept.isEmpty ? nil : String(kept.prefix(32))
    }

    mutating func map(_ event: SwarmInferenceEvent) -> [String] {
        switch event {
        case .content(let raw):
            let text = Self.stripSentinels(raw)
            guard !text.isEmpty else { return [] }
            emittedOutput = true
            outputEvents += 1
            return [text]
        case .reasoning(let raw):
            let text = Self.stripSentinels(raw)
            guard !text.isEmpty else { return [] }
            emittedOutput = true
            outputEvents += 1
            return [StreamingReasoningHint.encode(text)]
        case .toolCall(let index, let rawId, let rawName, let rawArguments):
            let name = Self.stripSentinels(rawName)
            let arguments = Self.stripSentinels(rawArguments)
            guard offeredToolNames.contains(name) else {
                violation = .invalidToolCall(
                    name: name,
                    reason: offeredToolNames.isEmpty ? .noToolsOffered : .notOffered
                )
                return []
            }
            emittedOutput = true
            toolCalls[index] = ServiceToolInvocation(
                toolName: name,
                jsonArguments: arguments.isEmpty ? "{}" : arguments,
                toolCallId: Self.stripSentinels(rawId)
            )
            return [StreamingToolHint.encode(name), StreamingToolHint.encodeArgs(arguments)]
        case .toolCallProgress(let raw):
            let text = Self.stripSentinels(raw)
            return text.isEmpty ? [] : [StreamingToolCallProgressHint.encode(text)]
        case .prefillProgress(let processed, let total):
            return [
                StreamingPrefillProgressHint.encode(
                    PrefillProgressState(
                        stage: processed >= total ? .complete : .prefill,
                        completedUnitCount: processed,
                        totalUnitCount: total,
                        detail: nil
                    )
                )
            ]
        case .completion(let reported):
            var info = reported
            info.finishReason = Self.plainFinishReason(reported.finishReason)
            completion = info
            return [
                StreamingStatsHint.encode(
                    tokenCount: max(0, info.completionTokens),
                    tokensPerSecond: info.tokensPerSecond.isFinite ? max(0, info.tokensPerSecond) : 0,
                    stopReason: info.finishReason,
                    prefillTokensPerSecond: info.prefillTokensPerSecond,
                    inputTokenCount: info.promptTokens,
                    cachedInputTokenCount: info.cachedPromptTokens
                )
            ]
        }
    }

    /// How the stream must end: tool calls finish by throwing the batch
    /// (the agent loop's dispatch contract); a tool call cut off by the
    /// output budget is never run; one-shot callers that need a complete
    /// reply get a typed truncation error.
    func terminalError() -> Error? {
        if let violation { return violation }
        let invocations = toolCalls.keys.sorted().compactMap { toolCalls[$0] }
        let finishReason = completion?.finishReason
        if !invocations.isEmpty {
            if finishReason == "length" {
                return ServiceToolResponseExhausted(toolCallCount: invocations.count)
            }
            // A complete call's arguments must be one JSON object.
            for invocation in invocations {
                let object = try? JSONSerialization.jsonObject(with: Data(invocation.jsonArguments.utf8))
                guard object is [String: Any] else {
                    return SwarmError.invalidToolCall(name: invocation.toolName, reason: .argumentsNotObject)
                }
            }
            return RemoteProviderService.toolInvocationFinishError(invocations)
        }
        if requireCompleteOutput, let finishReason, finishReason == "length" {
            return RemoteProviderServiceError.outputTruncated(finishReason: finishReason)
        }
        return nil
    }
}
