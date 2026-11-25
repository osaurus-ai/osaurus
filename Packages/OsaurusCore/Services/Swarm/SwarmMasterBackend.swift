//
//  SwarmMasterBackend.swift
//  osaurus
//
//  The one seam between Osaurus and the Swarm master library. Everything
//  stateful about the swarm (pairing, node registry, transport, model
//  libraries, pools, lease scheduling, inference streams) lives behind this
//  protocol. The vendored library (`OsaurusSwarm`, when present) gets a thin
//  adapter; until then `SwarmSimulatorBackend` implements it in process for
//  tests and UI work.
//

import Foundation

/// Which implementation is behind the seam.
enum SwarmBackendKind: Sendable, Equatable {
    /// The vendored Swarm master library.
    case library(version: String)
    /// In-process simulated nodes (tests, and dev builds launched with
    /// `OSAURUS_SWARM_SIMULATOR=1`). Never reached by a real node.
    case simulator
}

protocol SwarmMasterBackend: AnyObject, Sendable {
    var kind: SwarmBackendKind { get }

    /// Load the master identity from `stateDirectory`, bind the endpoint and
    /// start discovery. Idempotent.
    func start(masterName: String, stateDirectory: URL) async throws
    func shutdown() async

    /// Library pushes. One stream per call; the manager holds one.
    func events() -> AsyncStream<SwarmBackendEvent>

    // MARK: Nodes

    func nodes() async -> [SwarmNodeSnapshot]
    func beginPairing() async throws -> SwarmPairingOffer
    func cancelPairing() async
    /// Revoke the node's credential and tell it to forget this master.
    func removeNode(_ id: SwarmNodeID) async throws
    func renameNode(_ id: SwarmNodeID, name: String) async throws

    // MARK: Model library

    func installModel(on node: SwarmNodeID, source: SwarmInstallSource) async throws
    func cancelInstall(on node: SwarmNodeID, modelId: String) async
    func deleteModel(on node: SwarmNodeID, modelId: String) async throws
    func loadModel(on node: SwarmNodeID, modelId: String) async throws
    func unloadModel(on node: SwarmNodeID, modelId: String) async throws
    func setPreheat(on node: SwarmNodeID, modelId: String, keepLoaded: Bool) async throws

    // MARK: Pools

    func pools() async -> [SwarmPool]
    func createPool(_ draft: SwarmPoolDraft) async throws -> SwarmPool
    func updatePool(_ id: SwarmPoolID, _ draft: SwarmPoolDraft) async throws -> SwarmPool
    func deletePool(_ id: SwarmPoolID) async throws

    // MARK: Leases

    /// Grant a lease on one node of the pool, waiting in the pool's FIFO
    /// queue up to `maxWaitSeconds`. Throws `SwarmError.poolBusy` at the
    /// deadline; never falls back to another pool, local or cloud.
    func acquireLease(_ request: SwarmLeaseRequest) async throws -> SwarmLease
    func renewLease(_ leaseId: String) async throws -> SwarmLease
    func releaseLease(_ leaseId: String) async

    // MARK: Inference

    func infer(nodeId: SwarmNodeID, request: SwarmInferenceRequest) async throws
        -> AsyncThrowingStream<SwarmInferenceEvent, Error>
    /// Stop generation on the node within a bounded time.
    func cancelInference(requestId: String) async
}
