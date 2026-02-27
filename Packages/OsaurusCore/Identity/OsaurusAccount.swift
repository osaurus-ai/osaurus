//
//  OsaurusAccount.swift
//  osaurus
//
//  Public entry point for the Osaurus Identity system.
//  Orchestrates Master Key, Device Key, counter, and recovery code
//  to produce two-layer signed tokens for every API request.
//

import CryptoKit
import Foundation
import LocalAuthentication

public struct OsaurusAccount: Sendable {

    // MARK: - Setup

    /// Full account setup: generates Master Key, attests device, generates recovery code.
    public static func setup() async throws -> AccountInfo {
        let osaurusId = try MasterKey.generate()
        let deviceId = try await DeviceKey.attest()
        let recovery = RecoveryManager.configure(address: osaurusId)

        return AccountInfo(
            osaurusId: osaurusId,
            deviceId: deviceId,
            recovery: recovery
        )
    }

    /// Whether an account already exists (no biometric prompt).
    public static func exists() -> Bool {
        MasterKey.exists()
    }

    // MARK: - Request Signing

    /// Sign an API request as the user account.
    /// Returns a URLRequest with `Authorization: Bearer <token>`.
    public static func signRequest(
        method: String,
        path: String,
        audience: String
    ) async throws -> URLRequest {
        let context = OsaurusIdentityContext.biometric()
        let osaurusId = try MasterKey.getOsaurusId(context: context)

        return try await buildSignedRequest(
            osaurusId: osaurusId,
            method: method,
            path: path,
            audience: audience,
            context: context
        )
    }

    // MARK: - Private

    private static func buildSignedRequest(
        osaurusId: OsaurusID,
        method: String,
        path: String,
        audience: String,
        context: LAContext
    ) async throws -> URLRequest {
        let deviceId = try DeviceKey.currentDeviceId()
        let counter = CounterStore.shared.next()
        let now = Int(Date().timeIntervalSince1970)

        let payload = TokenPayload(
            iss: osaurusId,
            dev: deviceId,
            cnt: counter,
            iat: now,
            exp: now + 60,
            aud: audience,
            act: "\(method) \(path)",
            par: nil,
            idx: nil
        )

        let payloadData = try JSONEncoder().encode(payload)

        // Layer 1: Account signature (secp256k1)
        let accountSig = try MasterKey.sign(payload: payloadData, context: context)

        // Layer 2: Device assertion (App Attest)
        let payloadHash = Data(SHA256.hash(data: payloadData))
        let deviceAssertion = try await DeviceKey.assert(payloadHash: payloadHash)

        // Assemble 4-part token
        let headerData = try JSONEncoder().encode(TokenHeader.current)
        let token = [
            headerData.base64urlEncoded,
            payloadData.base64urlEncoded,
            accountSig.hexEncodedString,
            deviceAssertion.base64urlEncoded,
        ].joined(separator: ".")

        var request = URLRequest(url: URL(string: "https://\(audience)\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
