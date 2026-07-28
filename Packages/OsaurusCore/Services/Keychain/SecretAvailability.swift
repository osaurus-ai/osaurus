//
//  SecretAvailability.swift
//  osaurus
//
//  Caller-facing availability of a stored secret, derived from the typed
//  Keychain outcomes.
//

import Foundation

/// Availability of a credential in the Keychain, for presence checks and
/// diagnostics. Unlike a plain `Bool`, this distinguishes "definitively not
/// stored" from "stored but unreadable right now" and "stored but corrupt",
/// so a locked keychain or a decode bug is never reported to the user as a
/// missing credential.
public enum SecretAvailability: Equatable, Sendable {
    /// The secret exists and decodes correctly.
    case present
    /// The secret definitively does not exist.
    case absent
    /// The keychain could not answer (locked, interaction required, denied,
    /// or another transient failure). Do not cache this as absence; retry.
    case unavailable
    /// Stored bytes exist but failed to decode into the expected shape.
    case corrupt

    /// Presence for UI badges: `unavailable` keeps the previous known value
    /// (or optimistically assumes present when there is none) so a transient
    /// keychain failure never flashes a false "missing credential" warning.
    /// `corrupt` counts as present — the item exists; deleting/re-entering it
    /// is a different affordance than "add a key".
    public func presenceForUI(previous: Bool?) -> Bool {  // swiftlint:disable:this discouraged_optional_boolean
        switch self {
        case .present, .corrupt: return true
        case .absent: return false
        case .unavailable: return previous ?? true
        }
    }
}
