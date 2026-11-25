//
//  SwarmLibraryBackend.swift
//  osaurus
//
//  `SwarmMasterBackend` over the vendored Swarm master library
//  (`OsaurusSwarm`, UniFFI bindings over the Rust master). Compiled only when
//  the package is vendored (`scripts/update-osaurus-swarm.sh`); public
//  builds without it never see this file's contents.
//
//  The library's calls block (they drive its own runtime), so each runs on a
//  detached task off the main actor. Library events and inference listeners
//  arrive on library threads and are forwarded into async streams. Library
//  errors become `SwarmError`. The library runs in this process, so the
//  app's Local Network approval covers its discovery and dials.
//

#if canImport(OsaurusSwarm)

    import Foundation
    import OsaurusSwarm

    final class SwarmLibraryBackend: SwarmMasterBackend, @unchecked Sendable {
        var kind: SwarmBackendKind { .library(version: "api \(apiVersion()) · protocol \(protocolVersion())") }

        private let lock = NSLock()
        private var master: SwarmMaster?
        private let hub = SwarmEventHub()
        /// Pool names for typed `swarm_pool_busy` text.
        private var poolNames: [String: String] = [:]

        init() {}

        private func requireMaster() throws -> SwarmMaster {
            guard let master = lock.withLock({ master }) else { throw SwarmError.unavailable }
            return master
        }

        /// Runs a blocking library call off the caller's actor.
        private func call<T: Sendable>(_ body: @escaping @Sendable (SwarmMaster) throws -> T) async throws -> T {
            let master = try requireMaster()
            return try await Task.detached(priority: .userInitiated) {
                do {
                    return try body(master)
                } catch let error as SwarmFfiError {
                    throw Self.map(error)
                }
            }.value
        }

        // MARK: - Lifecycle

        func start(masterName: String, stateDirectory: URL) async throws {
            guard lock.withLock({ master == nil }) else { return }
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            let keyStore: SwarmKeyStore =
                KeychainQueryHelpers.disablesKeychainForProcess
                ? SwarmFileKeyStore(directory: stateDirectory)
                : KeychainSwarmKeyStore(service: "ai.osaurus.swarm", useDataProtectionKeychain: false)
            let listener = SwarmLibraryEventListener(hub: hub)
            let started = try await Task.detached(priority: .userInitiated) {
                do {
                    return try SwarmMaster.start(
                        masterName: masterName,
                        stateDir: stateDirectory.path,
                        keyStore: keyStore,
                        listener: listener,
                        mdns: true
                    )
                } catch let error as SwarmFfiError {
                    throw Self.map(error)
                }
            }.value
            lock.withLock { master = started }
        }

        func shutdown() async {
            let current: SwarmMaster? = lock.withLock {
                defer { master = nil }
                return master
            }
            if let current {
                await Task.detached { current.shutdown() }.value
            }
            hub.finishAll()
        }

        func events() -> AsyncStream<SwarmBackendEvent> {
            hub.stream()
        }

        // MARK: - Nodes

        func nodes() async -> [SwarmNodeSnapshot] {
            (try? await call { $0.nodes().map(Self.snapshot) }) ?? []
        }

        func beginPairing() async throws -> SwarmPairingOffer {
            try await call { master in
                let offer = master.beginPairing()
                return SwarmPairingOffer(
                    code: offer.code,
                    qrPayload: offer.qrPayload,
                    expiresAt: Date(timeIntervalSince1970: TimeInterval(offer.expiresAtMs) / 1000)
                )
            }
        }

        func cancelPairing() async {
            _ = try? await call { $0.cancelPairing() }
        }

        func removeNode(_ id: SwarmNodeID) async throws {
            try await call { try $0.removeNode(id: id) }
        }

        func renameNode(_ id: SwarmNodeID, name: String) async throws {
            try await call { try $0.renameNode(id: id, name: name) }
        }

        // MARK: - Model library

        /// The library's install blocks until the model is in place; progress
        /// arrives as events. This returns once the install has started and
        /// reports a failure as a failed progress event.
        func installModel(on node: SwarmNodeID, source: SwarmInstallSource) async throws {
            let master = try requireMaster()
            let ffiSource: OsaurusSwarm.ModelSource
            let modelId: String
            switch source {
            case .huggingFace(let repoOrURL, let revision):
                guard let repo = SwarmInstallSource.huggingFaceRepoId(from: repoOrURL) else {
                    throw SwarmError.invalidHuggingFaceLink(repoOrURL)
                }
                ffiSource = .huggingFace(repo: repo, revision: revision)
                modelId = repo
            case .peer(let id, let fromNode):
                ffiSource = .peer(modelId: id, fromNode: fromNode)
                modelId = id
            }
            let hub = self.hub
            hub.send(
                .installProgress(
                    SwarmInstallProgress(nodeId: node, modelId: modelId, bytesDone: 0, bytesTotal: nil, state: .queued)
                )
            )
            Task.detached(priority: .utility) {
                do {
                    let installed = try master.installModel(node: node, source: ffiSource)
                    hub.send(
                        .installProgress(
                            SwarmInstallProgress(
                                nodeId: node,
                                modelId: installed.modelId,
                                bytesDone: Int64(installed.sizeBytes),
                                bytesTotal: Int64(installed.sizeBytes),
                                state: .installed
                            )
                        )
                    )
                } catch {
                    let message =
                        (error as? SwarmFfiError).map { Self.map($0).localizedDescription }
                        ?? error.localizedDescription
                    hub.send(
                        .installProgress(
                            SwarmInstallProgress(
                                nodeId: node,
                                modelId: modelId,
                                bytesDone: 0,
                                bytesTotal: nil,
                                state: .failed(message)
                            )
                        )
                    )
                }
            }
        }

        func cancelInstall(on node: SwarmNodeID, modelId: String) async {
            _ = try? await call { try $0.cancelInstall(node: node, modelId: modelId) }
        }

        func deleteModel(on node: SwarmNodeID, modelId: String) async throws {
            try await call { try $0.deleteModel(node: node, modelId: modelId) }
        }

        func loadModel(on node: SwarmNodeID, modelId: String) async throws {
            _ = try await call { try $0.loadModel(node: node, modelId: modelId).loadSeconds }
        }

        func unloadModel(on node: SwarmNodeID, modelId: String) async throws {
            try await call { try $0.unloadModel(node: node, modelId: modelId) }
        }

        func setPreheat(on node: SwarmNodeID, modelId: String, keepLoaded: Bool) async throws {
            try await call { try $0.setPreheat(node: node, modelId: modelId, keep: keepLoaded) }
        }

        // MARK: - Pools

        func pools() async -> [SwarmPool] {
            let pools = (try? await call { $0.pools().map(Self.pool) }) ?? []
            rememberPoolNames(pools)
            return pools
        }

        func createPool(_ draft: SwarmPoolDraft) async throws -> SwarmPool {
            let spec = PoolSpec(
                name: draft.name,
                models: draft.modelIds,
                members: draft.nodeIds,
                leaseSeconds: UInt64(max(1, draft.leaseSeconds)),
                maxWaitSeconds: UInt64(max(0, draft.maxQueueWaitSeconds)),
                contextLength: draft.contextLength.map { UInt64(max(1, $0)) }
            )
            let pool = try await call { Self.pool(try $0.createPool(spec: spec)) }
            rememberPoolNames([pool])
            return pool
        }

        func updatePool(_ id: SwarmPoolID, _ draft: SwarmPoolDraft) async throws -> SwarmPool {
            let update = PoolUpdate(
                name: draft.name,
                models: draft.modelIds,
                members: draft.nodeIds,
                leaseSeconds: UInt64(max(1, draft.leaseSeconds)),
                maxWaitSeconds: UInt64(max(0, draft.maxQueueWaitSeconds)),
                contextLength: draft.contextLength.map { UInt64(max(1, $0)) },
                clearContextLength: draft.contextLength == nil
            )
            let pool = try await call { Self.pool(try $0.updatePool(id: id, update: update)) }
            rememberPoolNames([pool])
            return pool
        }

        func deletePool(_ id: SwarmPoolID) async throws {
            try await call { try $0.deletePool(id: id) }
        }

        // MARK: - Leases

        func acquireLease(_ request: SwarmLeaseRequest) async throws -> SwarmLease {
            do {
                return try await call { master in
                    Self.lease(
                        try master.acquireLease(
                            poolId: request.poolId,
                            nodeIds: request.nodeIds,
                            modelId: request.modelId,
                            leaseSeconds: UInt64(max(1, request.leaseSeconds)),
                            maxWaitSeconds: UInt64(max(0, request.maxWaitSeconds)),
                            callerKey: request.callerKey
                        )
                    )
                }
            } catch SwarmError.poolBusy {
                throw SwarmError.poolBusy(pool: poolName(request.poolId), waitedSeconds: request.maxWaitSeconds)
            }
        }

        func renewLease(_ leaseId: String) async throws -> SwarmLease {
            try await call { Self.lease(try $0.renewLease(id: leaseId)) }
        }

        func releaseLease(_ leaseId: String) async {
            _ = try? await call { try $0.releaseLease(id: leaseId) }
        }

        // MARK: - Inference

        func infer(nodeId: SwarmNodeID, request: SwarmInferenceRequest) async throws
            -> AsyncThrowingStream<SwarmInferenceEvent, Error>
        {
            let (stream, continuation) = AsyncThrowingStream<SwarmInferenceEvent, Error>.makeStream()
            let listener = SwarmLibraryInferenceListener(continuation: continuation)
            let ffiRequest = InferenceRequest(
                requestId: request.requestId,
                leaseId: request.leaseId,
                idempotencyKey: request.idempotencyKey,
                modelId: request.modelId,
                openAiChatBodyJson: String(decoding: request.chatBodyJSON, as: UTF8.self),
                cacheChainId: request.cacheChainId,
                cacheIntent: request.cacheIntent
            )
            try await call { try $0.infer(nodeId: nodeId, request: ffiRequest, listener: listener) }
            return stream
        }

        func cancelInference(requestId: String) async {
            _ = try? await call { $0.cancelInference(requestId: requestId) }
        }

        // MARK: - Mapping

        private func rememberPoolNames(_ pools: [SwarmPool]) {
            lock.withLock {
                for pool in pools { poolNames[pool.id] = pool.name }
            }
        }

        private func poolName(_ id: SwarmPoolID) -> String {
            lock.withLock { poolNames[id] ?? id }
        }

        static func snapshot(_ node: NodeSnapshot) -> SwarmNodeSnapshot {
            let backend: SwarmEngineBackend
            switch node.backend {
            case .metal: backend = .metal
            case .cuda: backend = .cuda
            case .some(.none), nil: backend = .none
            }
            let availability: SwarmNodeAvailability
            switch node.availability {
            case .available: availability = .available
            case .busy: availability = .busy
            case .paused(let reason): availability = .paused(reason: reason)
            case .offline: availability = .offline
            case .unreachableNoDirectPath: availability = .unreachableNoDirectPath
            case .updateRequired: availability = .updateRequired(side: "node")
            }
            let path: SwarmConnectionPath?
            switch node.path {
            case .lan: path = .lan
            case .thunderbolt: path = .thunderbolt
            case .internetDirect: path = .internetDirect
            case .relay, .unknown, nil: path = nil
            }
            return SwarmNodeSnapshot(
                id: node.id,
                name: node.name,
                hardware: SwarmNodeHardware(
                    os: node.os,
                    cpu: node.cpu,
                    gpu: node.gpu ?? "",
                    backend: backend,
                    trexVersion: node.trexVersion ?? "",
                    protocolVersion: Int(node.protocolVersion ?? 0),
                    memoryTotalBytes: Int64(clamping: node.memTotal),
                    memoryCapBytes: Int64(clamping: node.memCap ?? node.memTotal)
                ),
                telemetry: SwarmNodeTelemetry(
                    memoryInUseBytes: Int64(clamping: node.memInUse ?? 0),
                    diskFreeBytes: Int64(clamping: node.diskFree ?? 0),
                    gpuUtilization: Double(node.gpuUtil ?? 0),
                    lastHeartbeat: Date()
                ),
                availability: availability,
                path: path,
                rttMs: node.rttMs,
                models: node.models.map { model in
                    let state: SwarmModelLoadState
                    switch model.state {
                    case .cold: state = .cold
                    case .loading: state = .loading
                    case .warm: state = .warm
                    }
                    return SwarmInstalledModel(
                        modelId: model.modelId,
                        sizeBytes: Int64(clamping: model.sizeBytes),
                        digest: model.digest,
                        loadState: state,
                        preheat: model.preheat
                    )
                }
            )
        }

        static func pool(_ pool: Pool) -> SwarmPool {
            SwarmPool(
                id: pool.id,
                name: pool.name,
                modelIds: pool.models,
                nodeIds: pool.members,
                leaseSeconds: Int(clamping: pool.leaseSeconds),
                maxQueueWaitSeconds: Int(clamping: pool.maxWaitSeconds),
                contextLength: pool.contextLength.map { Int(clamping: $0) }
            )
        }

        static func lease(_ lease: OsaurusSwarm.Lease) -> SwarmLease {
            SwarmLease(
                id: lease.id,
                poolId: lease.poolId,
                nodeId: lease.nodeId,
                modelId: lease.modelId,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(lease.expiresAtMs) / 1000),
                warm: lease.warm
            )
        }

        static func map(_ error: SwarmFfiError) -> SwarmError {
            switch error {
            case .NotPaired: return .notPaired
            case .NodeOffline(let detail): return .nodeOffline(detail)
            case .NoDirectPath(let detail): return .noDirectPath(detail)
            case .NodePaused(let reason, let detail): return .nodePaused(node: detail, reason: reason)
            case .FitRefused(let detail): return .fitRefused(detail)
            case .CapExceeded(let cap, let needed, let limit, _):
                return .capExceeded(
                    cap: cap.replacingOccurrences(of: "_", with: " "),
                    neededBytes: Int64(clamping: needed),
                    limitBytes: Int64(clamping: limit)
                )
            case .ModelNotInstalled(let detail): return .modelNotInstalled(model: detail, node: "")
            case .ProtocolVersionMismatch(let side, _):
                return .updateRequired(side: side == "local" ? "master" : "node")
            case .LeaseLost(let reason): return .leaseLost(reason: reason)
            case .PoolBusy(let detail): return .poolBusy(pool: detail, waitedSeconds: 0)
            case .Cancelled: return .cancelled
            case .Engine(let status, let detail, _): return .engine(status: Int(status), message: detail)
            case .Transport(let detail): return .transport(detail)
            case .InvalidInput(let detail): return .rejected(detail)
            case .NotFound(let detail): return .notFound(detail)
            case .KeyStore(let detail): return .internalError(detail)
            case .Internal(let detail): return .internalError(detail)
            }
        }

        /// `Failed` inference events carry the swarm error code as text.
        static func map(failedCode code: String, message: String, detailJSON: String) -> SwarmError {
            let detail = (try? JSONSerialization.jsonObject(with: Data(detailJSON.utf8))) as? [String: Any]
            switch code {
            case "cancelled": return .cancelled
            case "lease_lost", "lease_expired", "unknown_lease": return .leaseLost(reason: message)
            case "paused": return .nodePaused(node: "", reason: (detail?["reason"] as? String) ?? message)
            case "node_offline": return .nodeOffline(message)
            case "unreachable": return .noDirectPath(message)
            case "engine":
                let status = (detail?["status"] as? Int) ?? 502
                return .engine(status: status, message: message)
            case "model_not_installed", "model_not_loaded": return .modelNotInstalled(model: message, node: "")
            case "cap_exceeded":
                return .capExceeded(
                    cap: ((detail?["cap"] as? String) ?? "memory").replacingOccurrences(of: "_", with: " "),
                    neededBytes: Int64((detail?["needed_bytes"] as? Int) ?? 0),
                    limitBytes: Int64((detail?["limit_bytes"] as? Int) ?? 0)
                )
            case "swarm_pool_busy", "node_busy": return .poolBusy(pool: message, waitedSeconds: 0)
            case "update_required": return .updateRequired(side: "node")
            default: return .transport(message.isEmpty ? code : message)
            }
        }
    }

    /// Library events → the backend event hub.
    private final class SwarmLibraryEventListener: SwarmEventListener, @unchecked Sendable {
        let hub: SwarmEventHub

        init(hub: SwarmEventHub) { self.hub = hub }

        func onEvent(event: SwarmEvent) {
            switch event {
            case .nodeUpdated(let node):
                hub.send(.nodeUpdated(SwarmLibraryBackend.snapshot(node)))
            case .nodeRemoved(let id):
                hub.send(.nodeRemoved(id))
            case .pairingCompleted(let node):
                let snapshot = SwarmLibraryBackend.snapshot(node)
                hub.send(.pairingCompleted(snapshot))
                hub.send(.nodeUpdated(snapshot))
            case .pairingFailed(let reason):
                hub.send(.pairingFailed(reason))
            case .installProgress(let node, let model, let done, let total, let state):
                let mapped: SwarmInstallState
                switch state {
                case "installed": mapped = .installed
                case "failed": mapped = .failed(L("The node couldn't install the model."))
                case "cancelled": mapped = .cancelled
                case "verifying", "finalizing": mapped = .verifying
                case "resolving": mapped = .queued
                default: mapped = .downloading
                }
                hub.send(
                    .installProgress(
                        SwarmInstallProgress(
                            nodeId: node,
                            modelId: model,
                            bytesDone: Int64(clamping: done),
                            bytesTotal: total > 0 ? Int64(clamping: total) : nil,
                            state: mapped
                        )
                    )
                )
            case .leaseRevoked(let leaseId, let reason):
                hub.send(.leaseRevoked(leaseId: leaseId, reason: reason))
            }
        }
    }

    /// One request's events → its async stream; ends at `Completion` or `Failed`.
    private final class SwarmLibraryInferenceListener: InferenceListener, @unchecked Sendable {
        let continuation: AsyncThrowingStream<SwarmInferenceEvent, Error>.Continuation

        init(continuation: AsyncThrowingStream<SwarmInferenceEvent, Error>.Continuation) {
            self.continuation = continuation
        }

        func onEvent(event: InferenceEvent) {
            switch event {
            case .started:
                break
            case .content(let text):
                continuation.yield(.content(text))
            case .reasoning(let text):
                continuation.yield(.reasoning(text))
            case .toolCall(let index, let id, let name, let argumentsJson):
                continuation.yield(.toolCall(index: Int(index), id: id, name: name, argumentsJSON: argumentsJson))
            case .toolCallProgress(let text):
                continuation.yield(.toolCallProgress(text))
            case .prefillProgress(let processed, let total):
                continuation.yield(.prefillProgress(processed: Int(clamping: processed), total: Int(clamping: total)))
            case .completion(
                let prompt,
                let completion,
                let cached,
                let tokensPerSecond,
                let prefillTokensPerSecond,
                let finishReason,
                _
            ):
                continuation.yield(
                    .completion(
                        SwarmCompletionInfo(
                            promptTokens: Int(clamping: prompt),
                            completionTokens: Int(clamping: completion),
                            cachedPromptTokens: Int(clamping: cached),
                            tokensPerSecond: tokensPerSecond ?? 0,
                            prefillTokensPerSecond: prefillTokensPerSecond,
                            finishReason: finishReason
                        )
                    )
                )
                continuation.finish()
            case .failed(let code, let message, let detailJson):
                continuation.finish(
                    throwing: SwarmLibraryBackend.map(failedCode: code, message: message, detailJSON: detailJson)
                )
            }
        }
    }

    /// The master's device key in a 0600 file in the Swarm state directory.
    /// Only for keychain-disabled test and proof launches
    /// (`OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1`); real launches use the Keychain.
    private final class SwarmFileKeyStore: SwarmKeyStore, @unchecked Sendable {
        let directory: URL

        init(directory: URL) { self.directory = directory }

        private func url(_ name: String) -> URL {
            directory.appendingPathComponent("\(name).key")
        }

        func load(name: String) throws -> Data? {
            try? Data(contentsOf: url(name))
        }

        func store(name: String, value: Data) throws {
            let target = url(name)
            do {
                try value.write(to: target, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            } catch {
                throw SwarmFfiError.KeyStore(detail: error.localizedDescription)
            }
        }

        func delete(name: String) throws {
            try? FileManager.default.removeItem(at: url(name))
        }
    }

#endif
