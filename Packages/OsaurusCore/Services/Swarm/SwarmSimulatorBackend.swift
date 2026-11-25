//
//  SwarmSimulatorBackend.swift
//  osaurus
//
//  In-process simulated Swarm nodes behind `SwarmMasterBackend`, for unit
//  tests and for building the master UI before the Swarm library is
//  vendored. Nothing here touches the network or a real engine: pairing
//  completes by itself a few seconds after a code is shown, installs tick
//  through fake progress, and inference streams a deterministic reply that
//  names the node and model it "ran" on. Dev builds reach it only when
//  launched with `OSAURUS_SWARM_SIMULATOR=1`; the UI labels it Simulator.
//
//  Deterministic hooks for tool-loop testing: a user message containing
//  `swarm-sim:call <tool_name> <json-args>` makes the node emit that tool
//  call; a tool result is answered with a reply quoting it.
//

import Foundation

actor SwarmSimulatorBackend: SwarmMasterBackend {
    nonisolated let kind: SwarmBackendKind = .simulator

    /// Timing knobs; tests shrink them.
    struct Timing: Sendable {
        var pairingDelay: Duration = .seconds(4)
        var installTick: Duration = .milliseconds(200)
        var installTicks: Int = 15
        var loadDelay: Duration = .milliseconds(1_200)
        var tokenDelay: Duration = .milliseconds(25)

        static let fast = Timing(
            pairingDelay: .milliseconds(20),
            installTick: .milliseconds(5),
            installTicks: 3,
            loadDelay: .milliseconds(10),
            tokenDelay: .milliseconds(1)
        )
    }

    private struct Persisted: Codable {
        var nodes: [SwarmNodeSnapshot]
        var pools: [SwarmPool]
    }

    private let timing: Timing
    private var stateFile: URL?
    private var nodesById: [SwarmNodeID: SwarmNodeSnapshot] = [:]
    private var nodeOrder: [SwarmNodeID] = []
    private var poolList: [SwarmPool] = []
    private var pairingTask: Task<Void, Never>?
    private var installTasks: [String: Task<Void, Never>] = [:]
    private var inferenceTasks: [String: Task<Void, Never>] = [:]
    private var pairedCount = 0
    /// Tests: make the next generation call this tool whether or not it was
    /// offered, as a misbehaving node would.
    private var rogueToolName: String?
    private var started = false
    private lazy var scheduler = SwarmLeaseScheduler { [weak self] poolId, nodeIds, modelId in
        await self?.leaseCandidates(poolId: poolId, nodeIds: nodeIds, modelId: modelId) ?? []
    }

    private let eventHub = SwarmEventHub()

    init(timing: Timing = Timing()) {
        self.timing = timing
    }

    // MARK: - Lifecycle

    func start(masterName: String, stateDirectory: URL) async throws {
        guard !started else { return }
        started = true
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let file = stateDirectory.appendingPathComponent("simulator-state.json")
        stateFile = file
        if let data = try? Data(contentsOf: file),
            let persisted = try? JSONDecoder().decode(Persisted.self, from: data)
        {
            for var node in persisted.nodes {
                // Models come back cold unless kept loaded, as after a node restart.
                node.models = node.models.map { model in
                    var m = model
                    m.loadState = model.preheat ? .warm : .cold
                    return m
                }
                node.telemetry.lastHeartbeat = Date()
                node.availability = .available
                nodesById[node.id] = node
                nodeOrder.append(node.id)
            }
            poolList = persisted.pools
            pairedCount = persisted.nodes.count
            recomputeMemory()
        }
    }

    func shutdown() async {
        pairingTask?.cancel()
        for task in installTasks.values { task.cancel() }
        for task in inferenceTasks.values { task.cancel() }
        installTasks.removeAll()
        inferenceTasks.removeAll()
        eventHub.finishAll()
    }

    nonisolated func events() -> AsyncStream<SwarmBackendEvent> {
        eventHub.stream()
    }

    // MARK: - Nodes

    func nodes() async -> [SwarmNodeSnapshot] {
        nodeOrder.compactMap { nodesById[$0] }
    }

    func beginPairing() async throws -> SwarmPairingOffer {
        pairingTask?.cancel()
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let code = String((0 ..< 12).map { _ in alphabet.randomElement()! })
        let offer = SwarmPairingOffer(
            code: code,
            qrPayload: "osaurus-swarm-pair:\(code)",
            expiresAt: Date().addingTimeInterval(300)
        )
        let delay = timing.pairingDelay
        pairingTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.completeSimulatedPairing()
        }
        return offer
    }

    func cancelPairing() async {
        pairingTask?.cancel()
        pairingTask = nil
    }

    func removeNode(_ id: SwarmNodeID) async throws {
        guard nodesById.removeValue(forKey: id) != nil else { throw SwarmError.nodeNotFound(id) }
        nodeOrder.removeAll { $0 == id }
        for index in poolList.indices { poolList[index].nodeIds.removeAll { $0 == id } }
        _ = await revoke(nodeId: id, reason: L("The node was removed."))
        persist()
        eventHub.send(.nodeRemoved(id))
        eventHub.send(.poolsChanged)
    }

    func renameNode(_ id: SwarmNodeID, name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var node = nodesById[id] else { throw SwarmError.nodeNotFound(id) }
        guard !trimmed.isEmpty else { return }
        node.name = trimmed
        update(node)
    }

    // MARK: - Library

    func installModel(on nodeId: SwarmNodeID, source: SwarmInstallSource) async throws {
        guard let node = nodesById[nodeId] else { throw SwarmError.nodeNotFound(nodeId) }
        guard let modelId = source.modelId else {
            if case .huggingFace(let text, _) = source { throw SwarmError.invalidHuggingFaceLink(text) }
            throw SwarmError.fitRefused(L("Unknown model source."))
        }
        if node.model(modelId) != nil { return }
        let size = Self.estimatedSizeBytes(modelId)
        if size > node.telemetry.diskFreeBytes {
            let fmt = ByteCountFormatter()
            throw SwarmError.fitRefused(
                String(
                    format: L("Needs %@ of disk, %@ is free on the node."),
                    fmt.string(fromByteCount: size),
                    fmt.string(fromByteCount: node.telemetry.diskFreeBytes)
                )
            )
        }
        if size > node.hardware.memoryCapBytes {
            throw SwarmError.capExceeded(
                cap: L("memory"),
                neededBytes: size,
                limitBytes: node.hardware.memoryCapBytes
            )
        }
        let key = "\(nodeId)|\(modelId)"
        installTasks[key]?.cancel()
        let ticks = max(1, timing.installTicks)
        let tick = timing.installTick
        eventHub.send(
            .installProgress(
                SwarmInstallProgress(nodeId: nodeId, modelId: modelId, bytesDone: 0, bytesTotal: size, state: .queued)
            )
        )
        installTasks[key] = Task { [weak self] in
            for step in 1 ... ticks {
                try? await Task.sleep(for: tick)
                if Task.isCancelled {
                    await self?.finishInstall(nodeId: nodeId, modelId: modelId, size: size, state: .cancelled)
                    return
                }
                let done = size * Int64(step) / Int64(ticks)
                await self?.emitInstall(
                    SwarmInstallProgress(
                        nodeId: nodeId,
                        modelId: modelId,
                        bytesDone: done,
                        bytesTotal: size,
                        state: step == ticks ? .verifying : .downloading
                    )
                )
            }
            await self?.finishInstall(nodeId: nodeId, modelId: modelId, size: size, state: .installed)
        }
    }

    func cancelInstall(on nodeId: SwarmNodeID, modelId: String) async {
        installTasks["\(nodeId)|\(modelId)"]?.cancel()
    }

    func deleteModel(on nodeId: SwarmNodeID, modelId: String) async throws {
        guard var node = nodesById[nodeId] else { throw SwarmError.nodeNotFound(nodeId) }
        guard let model = node.model(modelId) else {
            throw SwarmError.modelNotInstalled(model: modelId, node: node.name)
        }
        node.models.removeAll { $0.modelId == modelId }
        node.telemetry.diskFreeBytes += model.sizeBytes
        update(node)
        // A pool member is valid only while it has the model: drop the node
        // from pools that no longer have any of their models on it.
        var poolsChanged = false
        for index in poolList.indices where poolList[index].nodeIds.contains(nodeId) {
            let serves = poolList[index].modelIds.contains { node.model($0) != nil }
            if !serves {
                poolList[index].nodeIds.removeAll { $0 == nodeId }
                poolsChanged = true
            }
        }
        if poolsChanged {
            persist()
            eventHub.send(.poolsChanged)
        }
        await scheduler.nodesChanged()
    }

    func loadModel(on nodeId: SwarmNodeID, modelId: String) async throws {
        try await setLoad(nodeId: nodeId, modelId: modelId, warm: true)
    }

    func unloadModel(on nodeId: SwarmNodeID, modelId: String) async throws {
        try await setLoad(nodeId: nodeId, modelId: modelId, warm: false)
    }

    func setPreheat(on nodeId: SwarmNodeID, modelId: String, keepLoaded: Bool) async throws {
        guard var node = nodesById[nodeId] else { throw SwarmError.nodeNotFound(nodeId) }
        guard let index = node.models.firstIndex(where: { $0.modelId == modelId }) else {
            throw SwarmError.modelNotInstalled(model: modelId, node: node.name)
        }
        if keepLoaded {
            // Preheated models together must fit under the cap.
            let kept = node.models.enumerated()
                .filter { $0.offset == index || $0.element.preheat }
                .reduce(Int64(0)) { $0 + $1.element.sizeBytes }
            if kept > node.hardware.memoryCapBytes {
                throw SwarmError.capExceeded(
                    cap: L("memory"),
                    neededBytes: kept,
                    limitBytes: node.hardware.memoryCapBytes
                )
            }
        }
        node.models[index].preheat = keepLoaded
        update(node)
        if keepLoaded, node.models[index].loadState == .cold {
            try await setLoad(nodeId: nodeId, modelId: modelId, warm: true)
        }
    }

    // MARK: - Pools

    func pools() async -> [SwarmPool] { poolList }

    func createPool(_ draft: SwarmPoolDraft) async throws -> SwarmPool {
        let pool = SwarmPool(
            id: "pool_" + UUID().uuidString.lowercased(),
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            modelIds: draft.modelIds,
            nodeIds: draft.nodeIds,
            leaseSeconds: draft.leaseSeconds,
            maxQueueWaitSeconds: draft.maxQueueWaitSeconds,
            contextLength: draft.contextLength
        )
        poolList.append(pool)
        persist()
        eventHub.send(.poolsChanged)
        await scheduler.nodesChanged()
        return pool
    }

    func updatePool(_ id: SwarmPoolID, _ draft: SwarmPoolDraft) async throws -> SwarmPool {
        guard let index = poolList.firstIndex(where: { $0.id == id }) else { throw SwarmError.poolNotFound(id) }
        poolList[index].name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        poolList[index].modelIds = draft.modelIds
        poolList[index].nodeIds = draft.nodeIds
        poolList[index].leaseSeconds = draft.leaseSeconds
        poolList[index].maxQueueWaitSeconds = draft.maxQueueWaitSeconds
        poolList[index].contextLength = draft.contextLength
        persist()
        eventHub.send(.poolsChanged)
        await scheduler.nodesChanged()
        return poolList[index]
    }

    func deletePool(_ id: SwarmPoolID) async throws {
        guard poolList.contains(where: { $0.id == id }) else { throw SwarmError.poolNotFound(id) }
        poolList.removeAll { $0.id == id }
        persist()
        eventHub.send(.poolsChanged)
    }

    // MARK: - Leases

    func acquireLease(_ request: SwarmLeaseRequest) async throws -> SwarmLease {
        guard let pool = poolList.first(where: { $0.id == request.poolId }) else {
            throw SwarmError.poolNotFound(request.poolId)
        }
        let lease = try await scheduler.acquire(request, poolName: pool.name)
        markBusy(lease.nodeId, busy: true)
        return lease
    }

    func renewLease(_ leaseId: String) async throws -> SwarmLease {
        try await scheduler.renew(leaseId)
    }

    func releaseLease(_ leaseId: String) async {
        let node = await scheduler.activeLeases().first { $0.id == leaseId }?.nodeId
        await scheduler.release(leaseId)
        if let node { await refreshBusy(node) }
    }

    /// Activity tab / tests: leases the scheduler currently holds.
    func activeLeases() async -> [SwarmLease] {
        await scheduler.activeLeases()
    }

    func queuedCount() async -> Int {
        await scheduler.queuedCount()
    }

    // MARK: - Inference

    func infer(nodeId: SwarmNodeID, request: SwarmInferenceRequest) async throws
        -> AsyncThrowingStream<SwarmInferenceEvent, Error>
    {
        guard let node = nodesById[nodeId] else { throw SwarmError.nodeNotFound(nodeId) }
        guard node.availability.acceptsLeases else {
            throw SwarmError.leaseLost(reason: node.availability.detail ?? node.availability.label)
        }
        guard node.model(request.modelId) != nil else {
            throw SwarmError.modelNotInstalled(model: request.modelId, node: node.name)
        }
        let parsed = SimulatedChat(body: request.chatBodyJSON)
        let (stream, continuation) = AsyncThrowingStream<SwarmInferenceEvent, Error>.makeStream()
        let leaseId = request.leaseId
        let requestId = request.requestId
        await scheduler.beginRequest(leaseId)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runSimulatedGeneration(
                    nodeId: nodeId,
                    modelId: request.modelId,
                    chat: parsed,
                    continuation: continuation
                )
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            await self.requestEnded(requestId: requestId, leaseId: leaseId, nodeId: nodeId)
        }
        inferenceTasks[requestId] = task
        continuation.onTermination = { termination in
            if case .cancelled = termination { task.cancel() }
        }
        return stream
    }

    func cancelInference(requestId: String) async {
        inferenceTasks[requestId]?.cancel()
    }

    // MARK: - Simulation controls (tests)

    /// Pause a node as its owner would; leases on it are revoked.
    func simulatePause(_ nodeId: SwarmNodeID, reason: String) async {
        guard var node = nodesById[nodeId] else { return }
        node.availability = .paused(reason: reason)
        update(node)
        _ = await revoke(nodeId: nodeId, reason: reason)
    }

    func simulateResume(_ nodeId: SwarmNodeID) async {
        guard var node = nodesById[nodeId] else { return }
        node.availability = .available
        update(node)
        await scheduler.nodesChanged()
    }

    /// Pair a node immediately (tests), returning it.
    @discardableResult
    func simulatePairNode(name: String? = nil) async -> SwarmNodeSnapshot {
        completeSimulatedPairing(name: name)
    }

    /// The next generation calls `name` regardless of the offered tools.
    func simulateRogueToolCall(_ name: String?) {
        rogueToolName = name
    }

    /// Install a model with no fake progress (tests).
    func simulateInstalled(_ modelId: String, on nodeId: SwarmNodeID, warm: Bool = false) async {
        guard var node = nodesById[nodeId], node.model(modelId) == nil else { return }
        let size = Self.estimatedSizeBytes(modelId)
        node.models.append(
            SwarmInstalledModel(
                modelId: modelId,
                sizeBytes: size,
                digest: "sim-" + modelId,
                loadState: warm ? .warm : .cold,
                preheat: false
            )
        )
        node.telemetry.diskFreeBytes -= size
        update(node)
        recomputeMemory()
        await scheduler.nodesChanged()
    }

    // MARK: - Internals

    @discardableResult
    private func completeSimulatedPairing(name: String? = nil) -> SwarmNodeSnapshot {
        pairedCount += 1
        let names = ["Mac mini", "MacBook Pro", "Mac Studio", "iMac"]
        let base = names[(pairedCount - 1) % names.count]
        let display = name ?? (pairedCount > names.count ? "\(base) \(pairedCount)" : base)
        let memory: Int64 = [64, 48, 128, 32][(pairedCount - 1) % 4] * 1_073_741_824
        let node = SwarmNodeSnapshot(
            id: "sim-" + UUID().uuidString.lowercased().prefix(12),
            name: display,
            hardware: SwarmNodeHardware(
                os: "macOS 26.1",
                cpu: "Apple M4 Pro",
                gpu: "Apple M4 Pro (20-core GPU)",
                backend: .metal,
                trexVersion: "simulator",
                protocolVersion: 1,
                memoryTotalBytes: memory,
                memoryCapBytes: memory * 3 / 4
            ),
            telemetry: SwarmNodeTelemetry(
                memoryInUseBytes: 0,
                diskFreeBytes: 512 * 1_073_741_824,
                gpuUtilization: 0,
                lastHeartbeat: Date()
            ),
            availability: .available,
            path: pairedCount % 2 == 0 ? .thunderbolt : .lan,
            rttMs: pairedCount % 2 == 0 ? 0.6 : 2.4,
            models: []
        )
        nodesById[node.id] = node
        nodeOrder.append(node.id)
        persist()
        eventHub.send(.pairingCompleted(node))
        eventHub.send(.nodeUpdated(node))
        return node
    }

    private func update(_ node: SwarmNodeSnapshot) {
        var updated = node
        updated.telemetry.lastHeartbeat = Date()
        nodesById[node.id] = updated
        persist()
        eventHub.send(.nodeUpdated(updated))
    }

    private func emitInstall(_ progress: SwarmInstallProgress) {
        eventHub.send(.installProgress(progress))
    }

    private func finishInstall(nodeId: SwarmNodeID, modelId: String, size: Int64, state: SwarmInstallState) async {
        installTasks.removeValue(forKey: "\(nodeId)|\(modelId)")
        if state == .installed, var node = nodesById[nodeId], node.model(modelId) == nil {
            node.models.append(
                SwarmInstalledModel(
                    modelId: modelId,
                    sizeBytes: size,
                    digest: "sim-" + modelId,
                    loadState: .cold,
                    preheat: false
                )
            )
            node.telemetry.diskFreeBytes -= size
            update(node)
        }
        eventHub.send(
            .installProgress(
                SwarmInstallProgress(
                    nodeId: nodeId,
                    modelId: modelId,
                    bytesDone: state == .installed ? size : 0,
                    bytesTotal: size,
                    state: state
                )
            )
        )
        await scheduler.nodesChanged()
    }

    private func setLoad(nodeId: SwarmNodeID, modelId: String, warm: Bool) async throws {
        guard var node = nodesById[nodeId] else { throw SwarmError.nodeNotFound(nodeId) }
        guard let index = node.models.firstIndex(where: { $0.modelId == modelId }) else {
            throw SwarmError.modelNotInstalled(model: modelId, node: node.name)
        }
        if !warm {
            node.models[index].loadState = .cold
            update(node)
            recomputeMemory()
            return
        }
        guard node.models[index].loadState != .warm else { return }
        let resident = node.models.filter { $0.loadState != .cold }.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let needed = resident + node.models[index].sizeBytes
        if needed > node.hardware.memoryCapBytes {
            throw SwarmError.capExceeded(
                cap: L("memory"),
                neededBytes: needed,
                limitBytes: node.hardware.memoryCapBytes
            )
        }
        node.models[index].loadState = .loading
        update(node)
        try? await Task.sleep(for: timing.loadDelay)
        guard var current = nodesById[nodeId],
            let i = current.models.firstIndex(where: { $0.modelId == modelId })
        else { return }
        current.models[i].loadState = .warm
        update(current)
        recomputeMemory()
        await scheduler.nodesChanged()
    }

    private func recomputeMemory() {
        for id in nodeOrder {
            guard var node = nodesById[id] else { continue }
            node.telemetry.memoryInUseBytes =
                node.models.filter { $0.loadState == .warm }.reduce(Int64(0)) { $0 + $1.sizeBytes }
            nodesById[id] = node
            eventHub.send(.nodeUpdated(node))
        }
    }

    private func markBusy(_ nodeId: SwarmNodeID, busy: Bool) {
        guard var node = nodesById[nodeId] else { return }
        switch node.availability {
        case .available where busy:
            node.availability = .busy
        case .busy where !busy:
            node.availability = .available
        default:
            return
        }
        node.telemetry.gpuUtilization = busy ? 0.7 : 0
        nodesById[nodeId] = node
        eventHub.send(.nodeUpdated(node))
    }

    private func refreshBusy(_ nodeId: SwarmNodeID) async {
        let held = await scheduler.activeLeases().contains { $0.nodeId == nodeId }
        markBusy(nodeId, busy: held)
    }

    private func requestEnded(requestId: String, leaseId: String, nodeId: SwarmNodeID) async {
        inferenceTasks.removeValue(forKey: requestId)
        await scheduler.endRequest(leaseId)
        await refreshBusy(nodeId)
    }

    private func revoke(nodeId: SwarmNodeID, reason: String) async -> [(String, String)] {
        let lost = await scheduler.revokeLeases(onNode: nodeId)
        for lease in lost {
            eventHub.send(.leaseRevoked(leaseId: lease, reason: reason))
        }
        return lost.map { ($0, reason) }
    }

    private func leaseCandidates(poolId: SwarmPoolID, nodeIds: [SwarmNodeID], modelId: String)
        -> [SwarmLeaseScheduler.Candidate]
    {
        guard let pool = poolList.first(where: { $0.id == poolId }) else { return [] }
        let members = nodeIds.isEmpty ? pool.nodeIds : pool.nodeIds.filter(nodeIds.contains)
        return members.compactMap { id in
            guard let node = nodesById[id] else { return nil }
            let model = node.model(modelId)
            return SwarmLeaseScheduler.Candidate(
                nodeId: id,
                acceptsLeases: node.availability.acceptsLeases,
                hasModel: model != nil,
                warm: model?.loadState == .warm,
                load: node.telemetry.gpuUtilization,
                recentTokensPerSecond: nil
            )
        }
    }

    private func persist() {
        guard let stateFile else { return }
        let persisted = Persisted(nodes: nodeOrder.compactMap { nodesById[$0] }, pools: poolList)
        if let data = try? JSONEncoder().encode(persisted) {
            try? data.write(to: stateFile, options: .atomic)
        }
    }

    /// Rough on-disk size from the parameter count in the repo name, so fit
    /// checks have something to bite on. Simulator only.
    static func estimatedSizeBytes(_ modelId: String) -> Int64 {
        let name = modelId.lowercased()
        let gib: Int64 = 1_073_741_824
        if let match = name.firstMatch(of: /(\d+(?:\.\d+)?)b/), let billions = Double(match.1) {
            // ~4.5 bits per weight.
            return max(gib / 2, Int64(billions * 0.56 * Double(gib)))
        }
        return 4 * gib
    }

    // MARK: - Generation

    private func runSimulatedGeneration(
        nodeId: SwarmNodeID,
        modelId: String,
        chat: SimulatedChat,
        continuation: AsyncThrowingStream<SwarmInferenceEvent, Error>.Continuation
    ) async throws {
        let nodeName = nodesById[nodeId]?.name ?? nodeId
        if nodesById[nodeId]?.model(modelId)?.loadState != .warm {
            try await setLoad(nodeId: nodeId, modelId: modelId, warm: true)
        }
        let started = Date()
        let promptTokens = max(1, chat.promptCharacters / 4)
        continuation.yield(.prefillProgress(processed: promptTokens, total: promptTokens))

        // Everything the node will say, decided up front; streamed below.
        var script: [SwarmInferenceEvent] = []
        let finishReason: String
        if let rogue = rogueToolName {
            rogueToolName = nil
            script.append(.toolCall(index: 0, id: "call_rogue", name: rogue, argumentsJSON: "{}"))
            finishReason = "tool_calls"
        } else if let call = chat.requestedToolCall {
            script.append(.reasoning(String(format: L("Calling %@ as asked."), call.name)))
            script.append(
                .toolCall(
                    index: 0,
                    id: "call_" + UUID().uuidString.lowercased().prefix(12),
                    name: call.name,
                    argumentsJSON: call.arguments
                )
            )
            finishReason = "tool_calls"
        } else {
            let reply: String
            if let toolResult = chat.lastToolResult {
                reply = String(
                    format: L("Simulated %@ on %@ got the tool result: %@"),
                    modelId,
                    nodeName,
                    String(toolResult.prefix(200))
                )
            } else {
                let said = chat.lastUserText.map { String($0.prefix(200)) } ?? ""
                reply = String(format: L("Simulated reply from %@ running %@. You said: %@"), nodeName, modelId, said)
            }
            script.append(.reasoning(String(format: L("Simulated node %@ is answering."), nodeName)))
            for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
                script.append(.content(String(word) + " "))
            }
            let limit = chat.maxTokens ?? Int.max
            if script.count > limit { script = Array(script.prefix(limit)) }
            finishReason = script.count >= limit ? "length" : "stop"
        }

        var completionTokens = 0
        for event in script {
            try Task.checkCancellation()
            if let availability = nodesById[nodeId]?.availability, !availability.acceptsLeases {
                throw SwarmError.leaseLost(reason: availability.detail ?? availability.label)
            }
            continuation.yield(event)
            completionTokens += 1
            try await Task.sleep(for: timing.tokenDelay)
        }
        let elapsed = max(0.001, Date().timeIntervalSince(started))
        continuation.yield(
            .completion(
                SwarmCompletionInfo(
                    promptTokens: promptTokens,
                    completionTokens: completionTokens,
                    cachedPromptTokens: 0,
                    tokensPerSecond: Double(completionTokens) / elapsed,
                    prefillTokensPerSecond: nil,
                    finishReason: finishReason
                )
            )
        )
    }
}

/// Fan-out of library events to every subscriber.
final class SwarmEventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<SwarmBackendEvent>.Continuation] = [:]

    func stream() -> AsyncStream<SwarmBackendEvent> {
        let (stream, continuation) = AsyncStream<SwarmBackendEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let id = UUID()
        lock.lock()
        continuations[id] = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.continuations.removeValue(forKey: id)
            self.lock.unlock()
        }
        return stream
    }

    func send(_ event: SwarmBackendEvent) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets { continuation.yield(event) }
    }

    func finishAll() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in targets { continuation.finish() }
    }
}

/// The bits of an OpenAI chat body the simulator reacts to.
private struct SimulatedChat: Sendable {
    struct ToolCallRequest: Sendable {
        let name: String
        let arguments: String
    }

    var lastUserText: String?
    var lastToolResult: String?
    var requestedToolCall: ToolCallRequest?
    var promptCharacters = 0
    var maxTokens: Int?

    init(body: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return }
        maxTokens = (object["max_tokens"] as? Int) ?? (object["max_completion_tokens"] as? Int)
        let messages = object["messages"] as? [[String: Any]] ?? []
        let toolNames = Set(
            (object["tools"] as? [[String: Any]] ?? []).compactMap {
                ($0["function"] as? [String: Any])?["name"] as? String
            }
        )
        for message in messages {
            let text = Self.text(of: message["content"])
            promptCharacters += text.count
        }
        guard let last = messages.last else { return }
        let role = last["role"] as? String
        let text = Self.text(of: last["content"])
        if role == "tool" {
            lastToolResult = text
            return
        }
        if role == "user" {
            lastUserText = text
            if let match = text.firstMatch(of: /swarm-sim:call\s+([A-Za-z0-9_.\-]+)\s*(\{.*\})?/),
                toolNames.contains(String(match.1))
            {
                requestedToolCall = ToolCallRequest(name: String(match.1), arguments: match.2.map(String.init) ?? "{}")
            }
        }
    }

    private static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }
}
