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
//  These tests deliberately exercise the real Keychain through a unique,
//  per-run service namespace. They never select the production identity slot;
//  a pre-existing item in the generated namespace still fails closed.
//
//  The normal test process disables real Keychain access and never evaluates
//  this suite. The separately filtered proof lane must set
//  `OSAURUS_ALLOW_REAL_KEYCHAIN_FOR_TESTS=1`; once requested, unavailable or
//  misconfigured Keychain access is a test failure rather than a silent skip.
//

import Foundation
import LocalAuthentication
import Security
import Testing

@testable import OsaurusCore

@Suite("MasterKey service isolation")
struct MasterKeyServiceIsolationTests {
    @Test
    func proofNamespaceNeverUsesProductionService() {
        #expect(
            MasterKey.serviceName(realKeychainTestNamespace: nil)
                == "com.osaurus.account"
        )
        #expect(
            MasterKey.serviceName(
                realKeychainTestNamespace: "01234567-89ab-cdef-0123-456789abcdef"
            ) == "com.osaurus.tests.master-key.01234567-89ab-cdef-0123-456789abcdef"
        )
    }

    @Test
    func mnemonicAndExistenceCacheFollowEffectiveServiceNamespace() {
        let production = MasterKey.serviceName(realKeychainTestNamespace: nil)
        let proof = MasterKey.serviceName(
            realKeychainTestNamespace: "01234567-89ab-cdef-0123-456789abcdef"
        )

        #expect(
            MasterKey.cachedExistsValue(
                cachedService: production,
                cachedValue: true,
                currentService: production
            ) == true
        )
        #expect(
            MasterKey.cachedExistsValue(
                cachedService: production,
                cachedValue: true,
                currentService: proof
            ) == nil
        )
        #expect(MasterMnemonicStore.service == MasterKey.service)
    }

    @Test
    func securityOperationRequiresStableServiceAndEnabledPolicy() {
        let production = MasterKey.serviceName(realKeychainTestNamespace: nil)
        let proof = MasterKey.serviceName(
            realKeychainTestNamespace: "01234567-89ab-cdef-0123-456789abcdef"
        )
        var operationCount = 0

        let allowed = KeychainQueryHelpers.performIfServiceAccessRemainsAllowed(
            capturedService: production,
            currentService: { production },
            isDisabled: { false },
            operation: {
                operationCount += 1
                return errSecSuccess
            }
        )
        #expect(allowed == errSecSuccess)
        #expect(operationCount == 1)

        let namespaceChanged = KeychainQueryHelpers.performIfServiceAccessRemainsAllowed(
            capturedService: production,
            currentService: { proof },
            isDisabled: { false },
            operation: {
                operationCount += 1
                return errSecSuccess
            }
        )
        #expect(namespaceChanged == nil)
        #expect(operationCount == 1)

        let policyDisabled = KeychainQueryHelpers.performIfServiceAccessRemainsAllowed(
            capturedService: production,
            currentService: { production },
            isDisabled: { true },
            operation: {
                operationCount += 1
                return errSecSuccess
            }
        )
        #expect(policyDisabled == nil)
        #expect(operationCount == 1)
    }
}

// `.serialized` is required because every test in this suite mutates the same
// per-run Master Key slot in Keychain. Without it Swift Testing runs the four
// tests in parallel, races on that slot, and tests fail
// non-deterministically with `.keychainWriteFailed` from `SecItemAdd`
// returning `errSecDuplicateItem` mid-race.
@Suite("MasterKey overwrite guard", .enabled(if: realKeychainProofRequested), .serialized)
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

    /// The proof exception is intentionally limited to `MasterKey`. Recovery
    /// phrases and every other wrapper must remain behind the disabled gate.
    @Test
    func mnemonicStoreRemainsDisabledInProofLane() throws {
        try requireRealKeychainProofLane()
        #expect(KeychainQueryHelpers.disablesKeychainForProcess)

        do {
            try MasterMnemonicStore.store(Array(repeating: "abandon", count: 24))
            Issue.record("The proof lane unexpectedly wrote a recovery phrase")
        } catch let error as OsaurusIdentityError {
            guard case .keychainWriteFailed = error else {
                Issue.record("Expected .keychainWriteFailed, got \(error)")
                return
            }
        }
        #expect(!MasterMnemonicStore.exists())
        #expect(MasterMnemonicStore.delete())
    }

    // MARK: - Keychain Isolation

    /// Run against a known-empty, per-run Master Key slot. The production
    /// service identifier is never selected by this proof lane.
    private func withEphemeralMaster(_ body: () throws -> Void) throws {
        try requireRealKeychainProofLane()
        let existingKeyMaterial = try readRawMasterKeyFromKeychain()
        try #require(
            existingKeyMaterial == nil,
            "Refusing to modify an existing Master Key; run this proof on an ephemeral Keychain"
        )
        defer {
            if !MasterKey.delete() {
                Issue.record("The proof lane could not clear its temporary Master Key")
            }
        }
        #expect(!MasterKey.exists())
        try body()
        try verifyProofItemIsLocalOnly()
    }

    /// Reads the raw 32-byte master without allowing authentication UI. The
    /// direct status check distinguishes a genuinely absent item from an access
    /// failure; treating either case as `MasterKey.exists() == false` before a
    /// delete would make this proof lane destructive.
    private func readRawMasterKeyFromKeychain() throws -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = true
        context.touchIDAuthenticationAllowableReuseDuration = 300
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MasterKey.service,
            kSecAttrAccount as String: MasterKey.account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            guard let data = result as? Data else {
                throw NSError(
                    domain: NSOSStatusErrorDomain,
                    code: Int(errSecDecode)
                )
            }
            return data
        default:
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    /// The proof lane uses a local-only item so normal deferred cleanup cannot
    /// create another synchronizable item. A hard-killed run can leave a
    /// UUID-scoped local item; the preflight above queries
    /// `kSecAttrSynchronizableAny` so that residue, including an item from an
    /// older proof implementation, fails closed instead of being overwritten.
    private func verifyProofItemIsLocalOnly() throws {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MasterKey.service,
            kSecAttrAccount as String: MasterKey.account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        try #require(status == errSecSuccess, "The proof Master Key was not stored as a local-only item")
        try #require(
            (result as? Data)?.count == 32,
            "The proof Master Key local-only item did not contain a 32-byte seed"
        )

        var synchronizableQuery = query
        synchronizableQuery[kSecAttrSynchronizable as String] = true
        var synchronizableResult: AnyObject?
        let synchronizableStatus = SecItemCopyMatching(
            synchronizableQuery as CFDictionary,
            &synchronizableResult
        )
        try #require(
            synchronizableStatus == errSecItemNotFound,
            "The proof Master Key unexpectedly has a synchronizable duplicate"
        )
    }
}

// MARK: - Real-Keychain Proof Policy

private let realKeychainProofRequested =
    KeychainQueryHelpers.realKeychainProofWasRequested

private func requireRealKeychainProofLane() throws {
    try #require(
        KeychainQueryHelpers.realKeychainProofWasRequested,
        "Real-Keychain proof requires OSAURUS_ALLOW_REAL_KEYCHAIN_FOR_TESTS=1"
    )
    try #require(
        KeychainQueryHelpers.realKeychainTestNamespace != nil,
        "Real-Keychain proof requires a valid per-run namespace"
    )
    try #require(
        !KeychainQueryHelpers.disablesIdentityKeyForProcess,
        "Real-Keychain MasterKey proof is not enabled"
    )
    try #require(
        KeychainQueryHelpers.disablesKeychainForProcess
            && KeychainQueryHelpers.usesInMemoryKeychainStoreForTests,
        "Non-MasterKey Keychain wrappers must remain isolated in the proof lane"
    )
    try #require(
        MasterKey.service.hasPrefix("com.osaurus.tests.master-key.")
            && MasterKey.service != "com.osaurus.account",
        "Real-Keychain proof must not select the production identity slot"
    )
    try verifyRealKeychainWriteAndCleanup()
}

/// Verify that this process reaches Security.framework with the same
/// local-only write contract used by the namespaced proof Master Key. The
/// probe is intentionally direct so it creates no detached watchdog thread
/// that can outlive the suite.
private func verifyRealKeychainWriteAndCleanup() throws {
    let namespace = try #require(KeychainQueryHelpers.realKeychainTestNamespace)
    let probeService = "com.osaurus.tests.keychain-probe.\(namespace)"
    let probeAccount = "probe"

    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: probeService,
        kSecAttrAccount as String: probeAccount,
        kSecValueData as String: Data([0x01]),
        kSecAttrSynchronizable as String: false,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    try #require(
        status == errSecSuccess,
        "The host could not write a throwaway real-Keychain item (status \(status))"
    )

    let cleanup: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: probeService,
        kSecAttrAccount as String: probeAccount,
        kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
    ]
    let cleanupStatus = SecItemDelete(cleanup as CFDictionary)
    try #require(
        cleanupStatus == errSecSuccess,
        "The host could not remove its throwaway real-Keychain item (status \(cleanupStatus))"
    )
}
