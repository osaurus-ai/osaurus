//
//  AgentKey.swift
//  osaurus
//
//  Deterministic child key derivation for per-agent identities.
//  Keys are re-derived on demand from the Master Key via HMAC-SHA512
//  and never stored.
//

import CryptoKit
import Foundation

public struct AgentKey: Sendable {

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
}
