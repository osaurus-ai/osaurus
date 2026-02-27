//
//  OsaurusIdentityError.swift
//  osaurus
//
//  Error types for the Osaurus Identity system.
//

import Foundation

public enum OsaurusIdentityError: LocalizedError {
    case randomFailed
    case keychainWriteFailed
    case keychainReadFailed
    case attestNotSupported
    case deviceNotAttested
    case signingFailed

    public var errorDescription: String? {
        switch self {
        case .randomFailed:
            "Failed to generate cryptographically secure random bytes"
        case .keychainWriteFailed:
            "Failed to write Master Key to iCloud Keychain"
        case .keychainReadFailed:
            "Failed to read Master Key from iCloud Keychain"
        case .attestNotSupported:
            "App Attest is not supported on this device"
        case .deviceNotAttested:
            "Device has not been attested — run setup first"
        case .signingFailed:
            "Failed to produce a cryptographic signature"
        }
    }
}
