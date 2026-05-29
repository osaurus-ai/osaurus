//
//  KeychainQueryHelpers.swift
//  osaurus
//
//  Shared Keychain query helpers.
//

import Foundation
import LocalAuthentication
import Security

enum KeychainQueryHelpers {
    /// Live proof/test launches set this to guarantee wrappers do not touch the
    /// user's login Keychain at all. This is stronger than noninteractive
    /// queries: reads return nil, writes return false, and deletes become
    /// no-ops so validation cannot produce "wants to use your confidential
    /// information" prompts.
    static var disablesKeychainForProcess: Bool {
        ProcessInfo.processInfo.environment["OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS"] == "1"
    }

    /// Unit tests need deterministic secret storage without touching the user's
    /// login Keychain or the CI runner's flaky transient Keychain state.
    static var usesInMemoryKeychainStoreForTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || ProcessInfo.processInfo.processName == "xctest"
            || Bundle.main.bundlePath.hasSuffix(".xctest")
    }

    /// Build an authentication context that refuses interactive prompts.
    ///
    /// `kSecUseAuthenticationUISkip` is still kept on every query, but adding a
    /// matching `LAContext` prevents accidental password/biometric UI if the
    /// system decides the stored item needs an authentication context.
    static func nonInteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    // MARK: - Data-protection keychain

    /// Why we route every item through the data-protection keychain:
    ///
    /// On the legacy (file-based login) keychain, macOS authorizes reads of a
    /// generic-password item against a per-item ACL bound to the *exact* code
    /// signature of the binary that created it. Whenever the running binary's
    /// signature differs from the one that saved the item (a routine occurrence
    /// across rebuilds, re-signs, and app updates), macOS shows the
    /// "<app> wants to use your confidential information stored in
    /// '<service>' in your keychain" password prompt — once per item.
    /// `kSecUseAuthenticationUISkip` does *not* suppress that prompt; it only
    /// governs the data-protection keychain's biometric/passcode UI.
    ///
    /// The data-protection keychain (`kSecUseDataProtectionKeychain`) instead
    /// authorizes access by the app's keychain access group, which is derived
    /// from the `keychain-access-groups` entitlement / signing identity. Reads
    /// by the same app then never trigger the password prompt regardless of
    /// signature churn. We omit an explicit `kSecAttrAccessGroup`, so the
    /// system uses the app's single entitled group as the default.
    ///
    /// Unsigned / un-entitled hosts (e.g. `swift test` binaries) can't use the
    /// data-protection keychain and return `errSecMissingEntitlement`; callers
    /// fall back to the legacy keychain in that case so behavior is unchanged
    /// there.
    static func dataProtection(_ query: [String: Any]) -> [String: Any] {
        var q = query
        q[kSecUseDataProtectionKeychain as String] = true
        return q
    }

    /// `errSecMissingEntitlement` means the data-protection keychain is
    /// unavailable for this process; callers should retry against the legacy
    /// keychain.
    static func isMissingEntitlement(_ status: OSStatus) -> Bool {
        status == errSecMissingEntitlement
    }
}
