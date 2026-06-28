//
//  MasterKeyExistsGuardTests.swift
//  OsaurusCoreTests
//
//  Verifies that MasterKey.generate / MasterKey.install refuse to overwrite
//  an existing master unless the caller explicitly opts in via
//  `allowReplace: true`. This is the post-#950 fix for the silent-overwrite
//  bug that stranded every derived agent / access key whenever onboarding
//  was re-run.
//
//  These tests deliberately exercise the real Keychain, which means they
//  modify the running user's `com.osaurus.account` Master Key. We isolate
//  by snapshotting the existing master (if any) before each test and
//  restoring it afterwards, so the developer's identity is not destroyed.
//
//  CI gating: GitHub Actions macOS runners have no signed-in iCloud account
//  and a constrained keychain. `SecItemAdd` with `kSecAttrSynchronizable: true`
//  hangs there for several seconds before returning, which makes these tests
//  flaky in CI. The whole suite is gated on `keychainAvailable`, which both
//  sniffs `CI` / `GITHUB_ACTIONS` env vars and probes a throwaway keychain
//  write before agreeing to run.
//

import Foundation
import LocalAuthentication
import Security
import Testing

@testable import OsaurusCore

// `.serialized` is required because every test in this suite mutates the same
// `com.osaurus.account` Master Key slot in Keychain. Without it Swift Testing
// runs the four tests in parallel, races on the shared slot, and tests fail
// non-deterministically with `.keychainWriteFailed` from `SecItemAdd`
// returning `errSecDuplicateItem` mid-race.
@Suite("MasterKey overwrite guard", .enabled(if: keychainAvailable), .serialized)
struct MasterKeyExistsGuardTests {

    /// A fresh-generated master must throw `.masterAlreadyExists` if `generate`
    /// is called a second time without `allowReplace: true`.
    @Test
    func generateRefusesToOverwriteExistingMaster() throws {
        try withEphemeralMaster {
            #expect(!MasterKey.exists())

            let first = try MasterKey.generate(allowReplace: false)
            #expect(MasterKey.exists())
            #expect(!first.osaurusId.isEmpty)

            do {
                _ = try MasterKey.generate(allowReplace: false)
                Issue.record("Expected masterAlreadyExists, got success")
            } catch let error as OsaurusIdentityError {
                guard case .masterAlreadyExists = error else {
                    Issue.record("Expected .masterAlreadyExists, got \(error)")
                    return
                }
            }
        }
    }

    /// `generate(allowReplace: true)` overwrites and returns a fresh address.
    @Test
    func generateAllowReplaceOverwrites() throws {
        try withEphemeralMaster {
            let first = try MasterKey.generate(allowReplace: false)
            let second = try MasterKey.generate(allowReplace: true)
            #expect(first.osaurusId != second.osaurusId)
        }
    }

    /// `install(seed:)` mirrors the same guard.
    @Test
    func installRefusesToOverwriteExistingMaster() throws {
        try withEphemeralMaster {
            _ = try MasterKey.generate(allowReplace: false)

            do {
                _ = try MasterKey.install(seed: TestKeys.alicePrivateKey, allowReplace: false)
                Issue.record("Expected masterAlreadyExists, got success")
            } catch let error as OsaurusIdentityError {
                guard case .masterAlreadyExists = error else {
                    Issue.record("Expected .masterAlreadyExists, got \(error)")
                    return
                }
            }
        }
    }

    /// `install(seed:allowReplace: true)` reproduces the seed's address.
    @Test
    func installAllowReplaceReproducesSeedAddress() throws {
        try withEphemeralMaster {
            _ = try MasterKey.generate(allowReplace: false)
            let installed = try MasterKey.install(
                seed: TestKeys.alicePrivateKey,
                allowReplace: true
            )
            #expect(installed.lowercased() == TestKeys.aliceAddress.lowercased())
        }
    }

    // MARK: - Keychain Snapshot

    /// Save the current master (if any), wipe Keychain, run `body`, then
    /// restore the snapshotted master so we never destroy the developer's
    /// real identity. If no master existed beforehand, the slot is left
    /// empty after the test.
    private func withEphemeralMaster(_ body: () throws -> Void) throws {
        let snapshot = readRawMasterKeyFromKeychain()
        defer {
            MasterKey.delete()
            if let snapshot {
                _ = try? MasterKey.install(seed: snapshot, allowReplace: true)
            }
        }
        MasterKey.delete()
        try body()
    }

    /// Tries to read the raw 32-byte master from Keychain WITHOUT prompting
    /// for biometrics. Items written with `kSecAttrAccessibleWhenUnlocked`
    /// don't gate on biometric ACL, so an empty `LAContext` is fine here —
    /// any failure is silently absorbed (the test still runs, it just won't
    /// restore on cleanup).
    private func readRawMasterKeyFromKeychain() -> Data? {
        guard MasterKey.exists() else { return nil }
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 300
        return try? MasterKey.getPrivateKey(context: context)
    }
}

// MARK: - Keychain Availability Probe

/// `true` when the runtime has a working keychain we can write to using the
/// same synchronizable path `MasterKey.generate` uses. False on:
///
/// - GitHub Actions macOS runners (no iCloud account, restricted keychain).
/// - Any unsigned `swift test` bundle without an `application-identifier`
///   entitlement — `SecItemAdd` fails with `errSecMissingEntitlement` (-34018)
///   or hangs trying to talk to the iCloud Keychain daemon.
///
/// The probe runs once per process. Result is cached in this `let`.
private let keychainAvailable: Bool = {
    if isContinuousIntegrationEnvironment() { return false }
    // Under OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1, `MasterKey` deliberately
    // no-ops every read/write/delete (the documented hermetic contract), so the
    // overwrite-guard semantics this suite asserts don't apply — skip it rather
    // than fail on the intentional no-ops.
    if KeychainQueryHelpers.disablesKeychainForProcess { return false }
    return canProbeMasterKeyWritePath()
}()

private func isContinuousIntegrationEnvironment() -> Bool {
    let env = ProcessInfo.processInfo.environment
    let signals = ["CI", "GITHUB_ACTIONS", "BUILDKITE", "JENKINS_HOME", "TF_BUILD"]
    return signals.contains(where: { env[$0] != nil })
}

/// Mirror `MasterKey.addToKeychain`'s exact write path on a unique throwaway
/// service so we can tell whether the real generate flow would succeed in
/// this environment. We attempt `synchronizable: true` first (matching the
/// production code), then `synchronizable: false` as fallback. Both must
/// succeed within a short watchdog window — if SecItemAdd hangs, we treat
/// the environment as unavailable.
private func canProbeMasterKeyWritePath() -> Bool {
    let probeService = "com.osaurus.tests.keychain-probe"
    let probeAccount = "probe-\(UUID().uuidString)"

    defer {
        let cleanup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: probeAccount,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(cleanup as CFDictionary)
    }

    func attemptAdd(synchronizable: Bool) -> OSStatus {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: probeAccount,
            kSecValueData as String: Data([0x01]),
        ]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = true
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        return SecItemAdd(query as CFDictionary, nil)
    }

    return runWithWatchdog(timeoutSeconds: 1.0) {
        let primary = attemptAdd(synchronizable: true)
        if primary == errSecSuccess { return true }
        return attemptAdd(synchronizable: false) == errSecSuccess
    } ?? false
}

/// Run `body` on a background queue and wait up to `timeoutSeconds` for the
/// result. Returns `nil` if the body did not complete in time — used here to
/// catch the multi-second `SecItemAdd` hang that happens in unsigned test
/// bundles trying to talk to the iCloud Keychain daemon.
private func runWithWatchdog<T>(
    timeoutSeconds: TimeInterval,
    _ body: @escaping () -> T
) -> T? {
    let semaphore = DispatchSemaphore(value: 0)
    var result: T?
    DispatchQueue.global(qos: .userInitiated).async {
        result = body()
        semaphore.signal()
    }
    return semaphore.wait(timeout: .now() + timeoutSeconds) == .success ? result : nil
}
