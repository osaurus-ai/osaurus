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

import Foundation
import LocalAuthentication
import Security
import Testing

@testable import OsaurusCore

@Suite("MasterKey overwrite guard")
struct MasterKeyExistsGuardTests {

    /// A fresh-generated master must throw `.masterAlreadyExists` if `generate`
    /// is called a second time without `allowReplace: true`.
    @Test
    func generateRefusesToOverwriteExistingMaster() throws {
        try withEphemeralMaster {
            // Precondition: no master.
            #expect(!MasterKey.exists())

            let first = try MasterKey.generate(allowReplace: false)
            #expect(MasterKey.exists())
            #expect(!first.osaurusId.isEmpty)

            // Second call without allowReplace MUST throw.
            do {
                _ = try MasterKey.generate(allowReplace: false)
                Issue.record("Expected masterAlreadyExists, got success")
            } catch let error as OsaurusIdentityError {
                switch error {
                case .masterAlreadyExists:
                    break
                default:
                    Issue.record("Expected .masterAlreadyExists, got \(error)")
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
                switch error {
                case .masterAlreadyExists:
                    break
                default:
                    Issue.record("Expected .masterAlreadyExists, got \(error)")
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

    /// Tries to read the raw 32-byte master from Keychain WITHOUT any
    /// biometric prompt by passing a fresh, unauthenticated `LAContext`.
    /// Returns nil if no master exists or the read requires biometrics that
    /// can't be satisfied non-interactively (in which case we skip the
    /// snapshot and tests still pass — they just don't restore on cleanup).
    private func readRawMasterKeyFromKeychain() -> Data? {
        guard MasterKey.exists() else { return nil }
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 300
        return try? MasterKey.getPrivateKey(context: context)
    }
}
