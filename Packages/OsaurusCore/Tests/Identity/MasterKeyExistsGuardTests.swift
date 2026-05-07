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

@Suite("MasterKey overwrite guard", .enabled(if: keychainAvailable))
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

/// `true` when the runtime has a working keychain we can write to. False on
/// GitHub Actions macOS runners (no iCloud account, restricted keychain) and
/// any other environment where a probe `SecItemAdd` fails or is suspected to
/// hang. The check is cheap and runs once per process.
private let keychainAvailable: Bool = {
    if isContinuousIntegrationEnvironment() {
        return false
    }
    return canProbeKeychain()
}()

private func isContinuousIntegrationEnvironment() -> Bool {
    let env = ProcessInfo.processInfo.environment
    let signals = ["CI", "GITHUB_ACTIONS", "BUILDKITE", "JENKINS_HOME", "TF_BUILD"]
    return signals.contains(where: { env[$0] != nil })
}

/// Attempt a no-op write into a unique throwaway keychain item. Round-trip
/// success means we have a usable keychain; any failure means the runner
/// environment is too constrained for the overwrite-guard tests.
private func canProbeKeychain() -> Bool {
    let probeService = "com.osaurus.tests.keychain-probe"
    let probeAccount = "probe-\(UUID().uuidString)"
    let payload = Data([0x01])

    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: probeService,
        kSecAttrAccount as String: probeAccount,
        kSecValueData as String: payload,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]

    let addStatus = SecItemAdd(query as CFDictionary, nil)
    guard addStatus == errSecSuccess else { return false }

    let deleteQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: probeService,
        kSecAttrAccount as String: probeAccount,
    ]
    SecItemDelete(deleteQuery as CFDictionary)
    return true
}
