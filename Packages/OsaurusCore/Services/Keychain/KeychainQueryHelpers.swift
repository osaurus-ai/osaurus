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
            // `swift test` (SwiftPM + swift-testing) runs suites inside this
            // helper without any of the XCTest markers above.
            || ProcessInfo.processInfo.processName == "swiftpm-testing-helper"
            || Bundle.main.bundlePath.hasSuffix(".xctest")
    }

    /// Build an authentication context that refuses interactive prompts.
    ///
    /// `kSecUseAuthenticationUISkip` is still kept on every query, but adding a
    /// matching `LAContext` prevents accidental password/biometric UI if the
    /// system decides the stored item needs an authentication context.
    ///
    /// The context is created once and reused. `LAContext.init` performs a
    /// synchronous XPC round-trip to `coreauthd`, and every Keychain read and
    /// enumeration builds one — on the main thread that has stalled the UI for
    /// seconds. A non-interactive context carries no per-query state, so a
    /// single shared instance is safe to reuse across queries and threads.
    ///
    /// The context is built on one background thread and callers wait at most
    /// `contextCreationWaitLimit` for it. When coreauthd does not answer (#3109)
    /// this returns nil and the query runs with `kSecUseAuthenticationUISkip`
    /// alone, which still refuses UI, instead of every Keychain read in the app
    /// queueing forever behind one stuck `LAContext()`. A later call picks the
    /// context up once the background creation finishes. After one caller has
    /// timed out, later callers skip the wait until that creation finishes, so
    /// a long coreauthd stall costs one 2 s wait instead of one per read.
    static func nonInteractiveContext() -> LAContext? {
        contextCondition.lock()
        defer { contextCondition.unlock() }
        if let cached = sharedNonInteractiveContext { return cached }
        if contextCreationInFlight, contextCreationTimedOut { return nil }
        if !contextCreationInFlight {
            contextCreationInFlight = true
            contextCreationTimedOut = false
            Thread.detachNewThread {
                let context = LAContext()
                context.interactionNotAllowed = true
                contextCondition.lock()
                sharedNonInteractiveContext = context
                contextCreationInFlight = false
                contextCondition.broadcast()
                contextCondition.unlock()
            }
        }
        let deadline = Date().addingTimeInterval(contextCreationWaitLimit)
        while sharedNonInteractiveContext == nil {
            guard contextCondition.wait(until: deadline) else { break }
        }
        if sharedNonInteractiveContext == nil { contextCreationTimedOut = true }
        return sharedNonInteractiveContext
    }

    /// Upper bound on how long a Keychain query waits for the shared context.
    static let contextCreationWaitLimit: TimeInterval = 2

    private static let contextCondition = NSCondition()
    nonisolated(unsafe) private static var sharedNonInteractiveContext: LAContext?
    nonisolated(unsafe) private static var contextCreationInFlight = false
    /// Set once a caller gave up waiting on the in-flight creation.
    nonisolated(unsafe) private static var contextCreationTimedOut = false

    /// The non-interactive query options. The context is added only when it
    /// is available; `kSecUseAuthenticationUISkip` is always set.
    static func nonInteractiveQueryOptions() -> [String: Any] {
        var options: [String: Any] = [kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip]
        if let context = nonInteractiveContext() {
            options[kSecUseAuthenticationContext as String] = context
        }
        return options
    }
}
