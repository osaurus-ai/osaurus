//
//  WhitelistStore.swift
//  osaurus
//
//  Hybrid address whitelist with Keychain persistence.
//  Master-level entries apply to all agents; per-agent overrides
//  add addresses for a specific agent only.
//

import Foundation

public final class WhitelistStore: @unchecked Sendable {
    public static let shared = WhitelistStore()

    private let queue = DispatchQueue(label: "com.osaurus.whitelist", attributes: .concurrent)
    private var masterAddresses: Set<String> = []
    private var agentAddresses: [String: Set<String>] = [:]

    private static let keychainService = "com.osaurus.whitelist"
    private static let keychainAccount = "whitelist-data"

    private init() {
        load()
    }

    // MARK: - Master-Level

    public func addMaster(address: OsaurusID) {
        queue.sync(flags: .barrier) {
            masterAddresses.insert(address.lowercased())
            save()
        }
        APIKeyValidatorEpoch.shared.bump()
    }

    public func removeMaster(address: OsaurusID) {
        queue.sync(flags: .barrier) {
            masterAddresses.remove(address.lowercased())
            save()
        }
        APIKeyValidatorEpoch.shared.bump()
    }

    public func masterWhitelist() -> Set<OsaurusID> {
        queue.sync { masterAddresses }
    }

    // MARK: - Per-Agent Overrides

    public func addAgent(address: OsaurusID, forAgent agentAddress: OsaurusID) {
        queue.sync(flags: .barrier) {
            let key = agentAddress.lowercased()
            var set = agentAddresses[key] ?? []
            set.insert(address.lowercased())
            agentAddresses[key] = set
            save()
        }
        APIKeyValidatorEpoch.shared.bump()
    }

    public func removeAgent(address: OsaurusID, forAgent agentAddress: OsaurusID) {
        queue.sync(flags: .barrier) {
            let key = agentAddress.lowercased()
            agentAddresses[key]?.remove(address.lowercased())
            if agentAddresses[key]?.isEmpty == true {
                agentAddresses.removeValue(forKey: key)
            }
            save()
        }
        APIKeyValidatorEpoch.shared.bump()
    }

    public func agentWhitelist(forAgent agentAddress: OsaurusID) -> Set<OsaurusID> {
        queue.sync { agentAddresses[agentAddress.lowercased()] ?? [] }
    }

    // MARK: - Effective Whitelist

    /// Compute the effective whitelist for a given agent.
    /// Result = master WL + agent-specific WL + {agentAddress, masterAddress} (implicit).
    public func effectiveWhitelist(
        forAgent agentAddress: OsaurusID,
        masterAddress: OsaurusID
    ) -> Set<OsaurusID> {
        queue.sync {
            var result = masterAddresses
            if let agentSpecific = agentAddresses[agentAddress.lowercased()] {
                result.formUnion(agentSpecific)
            }
            result.insert(agentAddress.lowercased())
            result.insert(masterAddress.lowercased())
            return result
        }
    }

    // MARK: - Keychain Persistence

    private struct StorageModel: Codable {
        var master: [String]
        var agents: [String: [String]]
    }

    // The whitelist blob is read/written through the shared `Keychain` helper.
    private func save() {
        let model = StorageModel(
            master: Array(masterAddresses),
            agents: agentAddresses.mapValues { Array($0) }
        )
        guard let data = try? JSONEncoder().encode(model) else { return }
        Keychain.writeInBackground(
            service: Self.keychainService, account: Self.keychainAccount, data: data)
    }

    private func load() {
        guard let data = Keychain.read(service: Self.keychainService, account: Self.keychainAccount),
            let model = try? JSONDecoder().decode(StorageModel.self, from: data)
        else { return }

        masterAddresses = Set(model.master)
        agentAddresses = model.agents.mapValues { Set($0) }
    }

    /// Force reload from Keychain.
    public func reload() {
        queue.sync(flags: .barrier) {
            load()
        }
        APIKeyValidatorEpoch.shared.bump()
    }
}
