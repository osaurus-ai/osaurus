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
    case masterAlreadyExists
    case mnemonicInvalidWordCount
    case mnemonicUnknownWord(String)
    case mnemonicChecksumFailed
    case mnemonicAddressMismatch(expected: String, got: String)
    case invalidEndpointURL(String)

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
        case .masterAlreadyExists:
            "A Master Key already exists. Refusing to overwrite without explicit confirmation."
        case .mnemonicInvalidWordCount:
            "Recovery phrase must be exactly 24 words."
        case .mnemonicUnknownWord(let word):
            "Recovery phrase contains a word that isn't in the BIP39 English wordlist: \(word)"
        case .mnemonicChecksumFailed:
            "Recovery phrase checksum is invalid. Double-check each word."
        case .mnemonicAddressMismatch(let expected, let got):
            "Recovery phrase derives a different identity (\(got)) than the one your agents were derived from (\(expected))."
        case .invalidEndpointURL(let value):
            "Could not form a valid request URL from \(value)."
        }
    }
}
