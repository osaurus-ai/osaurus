//
//  DeviceKey.swift
//  osaurus
//
//  Manages the App Attest device key in the Secure Enclave.
//  Hardware-bound P-256 key that proves which physical device is making a request.
//  Falls back to a software device ID when App Attest is unavailable (development).
//

import CryptoKit
import DeviceCheck
import Foundation

public struct DeviceKey: Sendable {
    private static let keyIdKey = "com.osaurus.device.keyId"
    private static let deviceIdKey = "com.osaurus.device.deviceId"
    private static let softwareMarker = "com.osaurus.device.software"

    // MARK: - Attestation

    /// Generate and attest a new device key. Returns the 8-char device ID.
    /// Falls back to a software-generated ID when App Attest is unavailable.
    public static func attest() async throws -> String {
        let service = DCAppAttestService.shared

        if service.isSupported {
            let keyId = try await service.generateKey()
            UserDefaults.standard.set(keyId, forKey: keyIdKey)

            let deviceId = deriveDeviceId(from: keyId)
            UserDefaults.standard.set(deviceId, forKey: deviceIdKey)
            UserDefaults.standard.set(false, forKey: softwareMarker)
            return deviceId
        }

        // App Attest unavailable — generate a stable software device ID
        let deviceId = generateSoftwareDeviceId()
        UserDefaults.standard.set(deviceId, forKey: deviceIdKey)
        UserDefaults.standard.set(true, forKey: softwareMarker)
        return deviceId
    }

    /// Retrieve the attestation object for server registration (Phase 1b).
    public static func getAttestation(challenge: Data) async throws -> Data {
        guard let keyId = UserDefaults.standard.string(forKey: keyIdKey) else {
            throw OsaurusIdentityError.deviceNotAttested
        }
        let challengeHash = Data(SHA256.hash(data: challenge))
        return try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: challengeHash)
    }

    // MARK: - Assertion

    /// Generate an assertion for an API request.
    /// Returns empty data for software-only devices (no hardware assertion available).
    public static func assert(payloadHash: Data) async throws -> Data {
        if let keyId = UserDefaults.standard.string(forKey: keyIdKey) {
            return try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: payloadHash)
        }
        // Software fallback — no hardware assertion
        return Data()
    }

    // MARK: - Device ID

    /// Read the stored device ID.
    public static func currentDeviceId() throws -> String {
        guard let id = UserDefaults.standard.string(forKey: deviceIdKey) else {
            throw OsaurusIdentityError.deviceNotAttested
        }
        return id
    }

    /// Whether this device has been attested (hardware or software).
    public static var isAttested: Bool {
        UserDefaults.standard.string(forKey: deviceIdKey) != nil
    }

    /// Whether App Attest hardware attestation is active (vs software fallback).
    public static var isHardwareAttested: Bool {
        !UserDefaults.standard.bool(forKey: softwareMarker)
            && UserDefaults.standard.string(forKey: keyIdKey) != nil
    }

    // MARK: - Internal

    private static func deriveDeviceId(from keyId: String) -> String {
        let hash = SHA256.hash(data: Data(keyId.utf8))
        return hash.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func generateSoftwareDeviceId() -> String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey) {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
