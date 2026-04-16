//
//  PairingKey.swift
//  osaurus
//
//  Deterministic pairing key derivation for per-device connector identities.
//  Derived from the Master Key via HMAC-SHA512 with domain "osaurus-pair-v1".
//  Never stored — re-derived on demand.
//

import CryptoKit
import Foundation

public struct PairingKey: Sendable {
    private static let domain = Data("osaurus-pair-v1".utf8)

    static func derive(masterKey: Data) -> Data {
        let hmac = HMAC<SHA512>.authenticationCode(
            for: domain,
            using: SymmetricKey(data: masterKey)
        )
        return Data(hmac.prefix(32))
    }

    public static func deriveAddress(masterKey: Data) throws -> OsaurusID {
        let childKey = derive(masterKey: masterKey)
        return try deriveOsaurusId(from: childKey)
    }

    static func sign(payload: Data, masterKey: Data) throws -> Data {
        let childKey = derive(masterKey: masterKey)
        return try signPairingPayload(payload, privateKey: childKey)
    }
}
