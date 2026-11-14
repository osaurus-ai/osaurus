//
//  AgentKey.swift
//  osaurus
//
//  Deterministic child key derivation for per-agent identities.
//  Keys are re-derived on demand from the Master Key via HMAC-SHA512
//  and never stored.
//
//  Two derivation layouts coexist:
//
//  - **v1** (`osaurus-agent-v1` || BE32(index)): the original scheme. The
//    index is allocated locally by `AgentManager.nextUnusedAgentIndex()`, so
//    two devices sharing one master would mint the SAME address for their
//    respective agent #0. Kept for agents that already exist so their
//    addresses (and every pairing / share / access key that references
//    them) stay valid.
//  - **v2** (`osaurus-agent-v2` || utf8(deviceScope) || 0x00 || BE32(index)):
//    the device-scoped scheme every newly minted or rotated agent uses. The
//    device scope is the minting device's `DeviceKey` ID, persisted on the
//    `Agent` as `agentDeviceScope` so the key can be re-derived on that
//    device forever — even after a re-attest changes the live device ID —
//    and so two devices sharing one master derive disjoint address spaces.
//
//  `AgentKeyPath` names which layout an agent uses; every derivation site
//  should go through it rather than calling the raw `index:` overloads.
//

import CryptoKit
import Foundation

/// Where an agent's child key sits under the master: derivation index plus,
/// for device-scoped (v2) agents, the device scope it was minted under.
/// `deviceScope == nil` selects the legacy v1 layout.
public struct AgentKeyPath: Codable, Hashable, Sendable {
    public let index: UInt32
    public let deviceScope: String?

    public init(index: UInt32, deviceScope: String? = nil) {
        self.index = index
        self.deviceScope = deviceScope
    }

    /// Legacy master-global derivation (`osaurus-agent-v1`).
    public static func legacy(index: UInt32) -> AgentKeyPath {
        AgentKeyPath(index: index, deviceScope: nil)
    }

    /// Device-scoped derivation (`osaurus-agent-v2`).
    public static func deviceScoped(index: UInt32, deviceScope: String) -> AgentKeyPath {
        AgentKeyPath(index: index, deviceScope: deviceScope)
    }

    /// `true` for the v2 layout, `false` for legacy v1.
    public var isDeviceScoped: Bool {
        guard let deviceScope else { return false }
        return !deviceScope.isEmpty
    }
}

public struct AgentKey: Sendable {

    // MARK: - v1 (legacy, master-global)

    static func derive(masterKey: Data, index: UInt32) -> Data {
        var indexBytes = Data(count: 4)
        indexBytes.withUnsafeMutableBytes { $0.storeBytes(of: index.bigEndian, as: UInt32.self) }
        let domain = Data("osaurus-agent-v1".utf8)
        let hmac = HMAC<SHA512>.authenticationCode(
            for: domain + indexBytes,
            using: SymmetricKey(data: masterKey)
        )
        return Data(hmac.prefix(32))
    }

    public static func deriveAddress(masterKey: Data, index: UInt32) throws -> OsaurusID {
        let childKey = derive(masterKey: masterKey, index: index)
        return try deriveOsaurusId(from: childKey)
    }

    static func sign(payload: Data, masterKey: Data, index: UInt32) throws -> Data {
        let childKey = derive(masterKey: masterKey, index: index)
        return try signAccessPayload(payload, privateKey: childKey)
    }

    // MARK: - v2 (device-scoped)

    static func derive(masterKey: Data, index: UInt32, deviceScope: String) -> Data {
        var indexBytes = Data(count: 4)
        indexBytes.withUnsafeMutableBytes { $0.storeBytes(of: index.bigEndian, as: UInt32.self) }
        let domain = Data("osaurus-agent-v2".utf8)
        // A zero byte terminates the variable-length scope so no two
        // (scope, index) pairs can collide by re-splitting the input.
        let scope = Data(deviceScope.utf8) + Data([0x00])
        let hmac = HMAC<SHA512>.authenticationCode(
            for: domain + scope + indexBytes,
            using: SymmetricKey(data: masterKey)
        )
        return Data(hmac.prefix(32))
    }

    // MARK: - Path-based entry points (preferred)

    /// Derive the child private key for `path`, picking v1 or v2 by whether
    /// the path carries a device scope.
    static func derive(masterKey: Data, path: AgentKeyPath) -> Data {
        if let scope = path.deviceScope, !scope.isEmpty {
            return derive(masterKey: masterKey, index: path.index, deviceScope: scope)
        }
        return derive(masterKey: masterKey, index: path.index)
    }

    public static func deriveAddress(masterKey: Data, path: AgentKeyPath) throws -> OsaurusID {
        let childKey = derive(masterKey: masterKey, path: path)
        return try deriveOsaurusId(from: childKey)
    }

    static func sign(payload: Data, masterKey: Data, path: AgentKeyPath) throws -> Data {
        let childKey = derive(masterKey: masterKey, path: path)
        return try signAccessPayload(payload, privateKey: childKey)
    }
}
