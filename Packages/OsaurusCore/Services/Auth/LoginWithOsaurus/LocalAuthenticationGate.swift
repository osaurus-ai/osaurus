//
//  LocalAuthenticationGate.swift
//  OsaurusCore
//
//  An explicit user-presence check before the master key signs a login.
//  Touch ID when the Mac has it, otherwise the login password. Every check
//  uses a fresh `LAContext` with no reuse window, so an unlock from a few
//  minutes ago never approves a sign-in on its own.
//

import Foundation
import LocalAuthentication

/// An `LAContext` that has passed `evaluatePolicy`, handed to the Keychain
/// read so the master key is fetched under the same authentication.
public struct AuthenticatedContext: @unchecked Sendable {
    public let context: LAContext
}

public enum LocalAuthenticationOutcome: Sendable {
    case authenticated(AuthenticatedContext)
    /// The user cancelled, or the system did (another app took focus, the
    /// lid closed, too many failed attempts).
    case cancelled
    /// No passcode or biometry is configured.
    case unavailable(String)
    case failed(String)
}

public protocol LocalAuthenticationGate: Sendable {
    func authenticate(reason: String) async -> LocalAuthenticationOutcome
}

public struct LiveLocalAuthenticationGate: LocalAuthenticationGate {
    public init() {}

    public func authenticate(reason: String) async -> LocalAuthenticationOutcome {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedCancelTitle = L("Cancel")

        var probeError: NSError?
        let policy: LAPolicy =
            context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &probeError)
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
        if policy == .deviceOwnerAuthentication {
            var fallbackError: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &fallbackError) else {
                return .unavailable(fallbackError?.localizedDescription ?? L("No passcode is set on this Mac."))
            }
        }

        return await evaluate(policy, context: context, reason: reason)
    }

    private func evaluate(_ policy: LAPolicy, context: LAContext, reason: String) async
        -> LocalAuthenticationOutcome
    {
        do {
            let ok = try await context.evaluatePolicy(policy, localizedReason: reason)
            return ok ? .authenticated(AuthenticatedContext(context: context)) : .cancelled
        } catch let error as LAError {
            switch error.code {
            case .userFallback where policy == .deviceOwnerAuthenticationWithBiometrics:
                // "Use Password…" on the Touch ID sheet.
                return await evaluate(.deviceOwnerAuthentication, context: context, reason: reason)
            case .userCancel, .systemCancel, .appCancel, .userFallback:
                return .cancelled
            case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
                return .unavailable(error.localizedDescription)
            default:
                return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
