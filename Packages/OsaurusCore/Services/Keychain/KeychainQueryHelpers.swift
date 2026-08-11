//
//  KeychainQueryHelpers.swift
//  osaurus
//
//  Shared Keychain query helpers.
//

import Foundation
import LocalAuthentication
import OsaurusRepository
import Security

enum KeychainQueryHelpers {
    /// Revalidate the service captured in a query immediately before invoking
    /// Security.framework. Test-host recognition can latch while a query is
    /// being assembled, so an entry guard alone is not sufficient for identity
    /// reads, writes, or deletes.
    static func performIfServiceAccessRemainsAllowed<Result>(
        capturedService: String,
        currentService: () -> String,
        isDisabled: () -> Bool,
        operation: () -> Result
    ) -> Result? {
        guard !isDisabled(), capturedService == currentService() else {
            return nil
        }
        return operation()
    }

    /// Live proof/test launches set this to guarantee wrappers do not touch the
    /// user's login Keychain at all. This is stronger than noninteractive
    /// queries: reads return nil, writes return false, and deletes become
    /// no-ops so validation cannot produce "wants to use your confidential
    /// information" prompts.
    static var disablesKeychainForProcess: Bool {
        ProcessDataRootPolicy.shouldDisableKeychain(
            environment: ProcessInfo.processInfo.environment,
            recognizedTestHost: ProcessDataRootPolicy.isRecognizedTestHostProcess
        )
    }

    static var realKeychainTestsAreExplicitlyEnabled: Bool {
        realKeychainTestNamespace != nil
    }

    /// Keep the explicit proof opt-in separate from namespace validation. A
    /// malformed or missing namespace must make the proof fail, not disable
    /// the suite and silently report zero tests.
    static var realKeychainProofWasRequested: Bool {
        ProcessDataRootPolicy.explicitlyAllowsRealKeychainForTests(
            environment: ProcessInfo.processInfo.environment
        )
    }

    /// The manual proof lane may reach only its namespaced MasterKey item.
    /// Every other Keychain wrapper remains disabled in the test host so
    /// filtered test discovery or incidental global initialization cannot
    /// touch a user's production secrets.
    static var disablesIdentityKeyForProcess: Bool {
        disablesKeychainForProcess && !realKeychainTestsAreExplicitlyEnabled
    }

    static var realKeychainTestNamespace: String? {
        ProcessDataRootPolicy.realKeychainTestNamespace(
            environment: ProcessInfo.processInfo.environment,
            recognizedTestHost: ProcessDataRootPolicy.isRecognizedTestHostProcess
        )
    }

    /// Unit tests need deterministic secret storage without touching the user's
    /// login Keychain or the CI runner's flaky transient Keychain state.
    static var usesInMemoryKeychainStoreForTests: Bool {
        ProcessDataRootPolicy.isRecognizedTestHostProcess && disablesKeychainForProcess
    }

    /// Build an authentication context that refuses interactive prompts.
    ///
    /// `kSecUseAuthenticationUISkip` is still kept on every query, but adding a
    /// matching `LAContext` prevents accidental password/biometric UI if the
    /// system decides the stored item needs an authentication context.
    ///
    /// `LAContext.init` performs a synchronous XPC round-trip to `coreauthd`,
    /// and creating one for every Keychain query has stalled the main thread.
    /// Cache one immutable, non-interactive context per calling thread instead:
    /// synchronous queries reuse it without sharing mutable framework state
    /// across the concurrent Keychain read executor.
    static func nonInteractiveContext() -> LAContext {
        let threadDictionary = Thread.current.threadDictionary
        if let cached = threadDictionary[nonInteractiveContextThreadKey] as? LAContext {
            return cached
        }
        let context = LAContext()
        context.interactionNotAllowed = true
        threadDictionary[nonInteractiveContextThreadKey] = context
        return context
    }

    private static let nonInteractiveContextThreadKey =
        "ai.osaurus.keychain.non-interactive-context"
}
