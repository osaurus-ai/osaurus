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
}
