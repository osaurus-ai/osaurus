//
//  WelcomeCreditDeviceID.swift
//  osaurus
//
//  Stable per-Mac identifier for the Router's one-time welcome-credit claim
//  (`POST /credits/welcome/claim`). The integration contract requires an id
//  that survives app restarts and reinstalls — so one machine can't claim
//  repeatedly through reinstall — while never shipping the raw hardware UUID
//  off the machine: the client sends `SHA-256(IOPlatformUUID + fixed app
//  salt)` and the router HMAC-hashes that again before storage.
//

import CryptoKit
import Foundation
import IOKit

enum WelcomeCreditDeviceID {
    /// Fixed app salt from the integration contract. Not a secret — its job
    /// is domain separation, so the derived id can't be correlated with any
    /// other product's hash of the same hardware UUID.
    static let salt = "ai.osaurus.welcome-credit.v1"

    /// The claim's `device_id`: 64 lowercase hex chars (within the server's
    /// 8–128 bound). `nil` when the platform UUID can't be read — the claim
    /// must be skipped then, since the server rejects a missing id and a
    /// random fallback would break the one-per-Mac invariant.
    static func current() -> String? {
        guard let uuid = platformUUID(), !uuid.isEmpty else { return nil }
        return derive(platformUUID: uuid)
    }

    /// Deterministic derivation, split out so tests can pin the exact
    /// contract without IOKit.
    static func derive(platformUUID: String) -> String {
        let digest = SHA256.hash(data: Data((platformUUID + salt).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// `IOPlatformUUID` from the `IOPlatformExpertDevice` registry node —
    /// the same hardware UUID "About This Mac" shows. Stays on-device; only
    /// the salted hash above ever crosses the wire.
    private static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard
            let uuid = IORegistryEntryCreateCFProperty(
                service,
                kIOPlatformUUIDKey as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? String
        else { return nil }
        return uuid.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
