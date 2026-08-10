//
//  SecretSaveOutcome.swift
//  osaurus
//
//  Typed result of persisting a channel credential (Slack/Discord/Telegram
//  bot tokens and friends), carrying enough detail to tell the user why a
//  save failed instead of the catch-all "empty or Keychain storage was
//  unavailable".
//

import Foundation
import Security

enum SecretSaveOutcome: Equatable, Sendable {
    case success
    /// The value was empty after trimming whitespace.
    case emptyValue
    /// The Keychain write failed; carries the typed mutation outcome so the
    /// OSStatus reaches the user-facing error.
    case keychainFailure(KeychainMutationOutcome)
    /// A save path that only reports success/failure (test doubles, legacy
    /// Bool wrappers) failed without further detail.
    case unknownFailure

    var isSuccess: Bool { self == .success }

    /// User-facing failure explanation, or nil on success. `label` names the
    /// credential in lowercase, e.g. "bot token".
    func failureDescription(label: String) -> String? {
        switch self {
        case .success:
            return nil
        case .emptyValue:
            return "The \(label) was empty."
        case .unknownFailure:
            return "The \(label) was empty or Keychain storage was unavailable."
        case .keychainFailure(let outcome):
            switch outcome {
            case .success:
                return nil
            case .unavailable(let status):
                return
                    "The \(label) could not be stored because the Keychain is locked or unavailable right now (OSStatus \(status)). Unlock the login keychain and try again."
            case .accessDenied(let status):
                return
                    "The \(label) could not be stored because macOS denied Osaurus access to its existing Keychain entry (OSStatus \(status)). In Keychain Access, delete the old Osaurus item for this credential and try again."
            case .failure(let status):
                return "The \(label) could not be stored, Keychain error OSStatus \(status)."
            case .disabled:
                return "The \(label) could not be stored because Keychain access is disabled for this process."
            }
        }
    }
}
