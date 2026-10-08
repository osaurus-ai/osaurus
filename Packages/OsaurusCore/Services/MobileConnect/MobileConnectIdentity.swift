//
//  MobileConnectIdentity.swift
//  osaurus
//
//  The Mac's own Secure Channel identity for the paired phone. Custom agents
//  each sign the handshake with their own key, but the built-in Default agent
//  has none, so a Mac with no custom agents gave the phone nothing to pin:
//  every run then went out as plaintext and was refused with `426
//  secure_channel_required`. This identity fills that gap. It is derived from
//  the master key under its own domain, so it can never collide with an agent
//  key, and it is only ever accepted by `POST /secure/session` — it is not an
//  agent address, so the relay, Bonjour and access keys never see it.
//
//  The phone pins it under the Default agent's id (pairing payload and the
//  owner's `GET /agents` roster). Access control is unchanged: the inner
//  request's Bearer still decides what the caller may do.
//

import CryptoKit
import Foundation
import LocalAuthentication
import os

enum MobileConnectIdentity {
    /// The Secure Channel signing key. Device-scoped when this Mac has a
    /// device id, so a master restored on another Mac answers to a
    /// different address.
    static func derivePrivateKey(masterKey: Data, deviceScope: String?) -> Data {
        let domain = Data("osaurus-connect-v1".utf8)
        // A zero byte terminates the scope, as in `AgentKey`'s v2 layout.
        let scope = Data((deviceScope ?? "").utf8) + Data([0x00])
        let hmac = HMAC<SHA512>.authenticationCode(for: domain + scope, using: SymmetricKey(data: masterKey))
        return Data(hmac.prefix(32))
    }

    /// Runs `body` with the signing key, or returns nil when there is no
    /// master key to derive it from. Reads the Keychain: never call on main.
    static func withPrivateKey<T>(_ body: (Data) throws -> T) throws -> T? {
        guard MasterKey.exists() else { return nil }
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 300
        context.interactionNotAllowed = true
        var masterKeyData = try MasterKey.getPrivateKey(context: context)
        defer { masterKeyData.zeroOut() }
        var key = derivePrivateKey(masterKey: masterKeyData, deviceScope: try? DeviceKey.currentDeviceId())
        defer { key.zeroOut() }
        return try body(key)
    }

    /// The lowercased address the phone pins, or nil without a master key or
    /// when the Keychain can't be read right now. Read once, then kept: it is
    /// public, and fixed for a master key on this Mac, so a handshake naming
    /// some other address costs no Keychain read. Reads the Keychain the
    /// first time: never call on main.
    static func address() -> String? {
        if let known = cachedAddress.withLock({ $0 }) { return known }
        // `try?` flattens the optional result, so this is a plain `String?`.
        guard let derived = (try? withPrivateKey { try deriveOsaurusId(from: $0) })?.lowercased() else { return nil }
        cachedAddress.withLock { $0 = derived }
        return derived
    }

    /// Whether `wanted` is this identity: nil when that can't be told, as
    /// the master key exists but can't be read now (a locked Keychain).
    /// That is worth a retry, not the "unknown address" that makes the
    /// phone drop its pin.
    static func matches(_ wanted: String) -> Bool? {
        if let address = address() { return address == wanted.lowercased() }
        return MasterKey.exists() ? nil : false
    }

    private static let cachedAddress = OSAllocatedUnfairLock<String?>(initialState: nil)
}
