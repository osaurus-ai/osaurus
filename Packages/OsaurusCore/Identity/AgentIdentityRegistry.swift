//
//  AgentIdentityRegistry.swift
//  osaurus
//
//  Thread-safe snapshot of the current agents' crypto addresses and key
//  indices. Maintained by `AgentManager` (on the main actor) so off-main
//  components — chiefly the NIO `APIKeyValidator` builder — can enumerate the
//  accepted token audiences without hopping to the main actor on a request
//  hot path.
//

import Foundation

public final class AgentIdentityRegistry: @unchecked Sendable {
    public static let shared = AgentIdentityRegistry()

    private let lock = NSLock()
    private var addresses: Set<String> = []
    private var indices: Set<UInt32> = []
    private var addressByAgentId: [UUID: String] = [:]

    private init() {}

    /// Replace the snapshot. Called whenever the agent list changes.
    public func update(addresses: Set<String>, indices: Set<UInt32>, addressByAgentId: [UUID: String]) {
        lock.lock()
        defer { lock.unlock() }
        self.addresses = Set(addresses.map { $0.lowercased() })
        self.indices = indices
        self.addressByAgentId = addressByAgentId.mapValues { $0.lowercased() }
    }

    /// Lowercased crypto address for an agent UUID, if it has one.
    public func address(forAgentId id: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return addressByAgentId[id]
    }

    /// Reverse of `address(forAgentId:)`: the agent UUID whose crypto address
    /// matches `address` (case-insensitive), if any. Lets off-main components
    /// (e.g. the NIO request path) resolve a `0x...` agent address to its local
    /// UUID without hopping to the main actor.
    public func agentId(forAddress address: String) -> UUID? {
        let target = address.lowercased()
        lock.lock()
        defer { lock.unlock() }
        return addressByAgentId.first(where: { $0.value == target })?.key
    }

    /// Lowercased set of every agent's crypto address.
    public func currentAddresses() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return addresses
    }

    /// Every agent key index currently in use.
    public func currentIndices() -> Set<UInt32> {
        lock.lock()
        defer { lock.unlock() }
        return indices
    }
}
