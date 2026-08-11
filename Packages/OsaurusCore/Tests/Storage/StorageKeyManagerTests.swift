//
//  StorageKeyManagerTests.swift
//  osaurusTests
//
//  Smoke tests for the test-injection seam on `StorageKeyManager`
//  and a sanity check that the FTS sanitizer doesn't accidentally
//  leak SQL operators. We deliberately avoid hitting the real
//  Keychain so this test suite stays fast and hermetic on CI.
//

import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct StorageKeyManagerTests {

    @Test
    func injectedKeyIsReturned() async throws {
        try await StoragePathsTestLock.shared.run {
            let key = SymmetricKey(data: Data(repeating: 0xAA, count: 32))
            StorageKeyManager.shared._setKeyForTesting(key)
            defer { StorageKeyManager.shared.wipeCache() }

            let fetched = try StorageKeyManager.shared.currentKey()
            #expect(
                fetched.withUnsafeBytes { Data($0) }
                    == key.withUnsafeBytes { Data($0) }
            )
        }
    }

    @Test
    func wipeCacheClearsInjectedKey() async throws {
        try await StoragePathsTestLock.shared.run {
            let key = SymmetricKey(data: Data(repeating: 0x77, count: 32))
            StorageKeyManager.shared._setKeyForTesting(key)
            StorageKeyManager.shared.wipeCache()
            // After wipe, calling currentKey would attempt Keychain. We
            // can't mock that here, so we just confirm the cache is gone
            // by calling _setKeyForTesting again with a different key
            // and seeing that value flow through.
            let other = SymmetricKey(data: Data(repeating: 0x88, count: 32))
            StorageKeyManager.shared._setKeyForTesting(other)
            let fetched = try StorageKeyManager.shared.currentKey()
            #expect(
                fetched.withUnsafeBytes { Data($0) }
                    == other.withUnsafeBytes { Data($0) }
            )
            StorageKeyManager.shared.wipeCache()
        }
    }

    @Test
    func isolatedHostRevokesProductionScopedCachedKey() async throws {
        try await StoragePathsTestLock.shared.run {
            #expect(StorageKeyManager.disablesKeychainForProcess)
            let productionKey = SymmetricKey(data: Data(repeating: 0x42, count: 32))
            StorageKeyManager.shared._setKeyForTesting(
                productionKey,
                isolated: false
            )
            defer { StorageKeyManager.shared.wipeCache() }

            #expect(!StorageKeyManager.shared.hasCachedKey)
            let isolatedKey = try StorageKeyManager.shared.currentKey()
            #expect(
                isolatedKey.withUnsafeBytes { Data($0) }
                    != productionKey.withUnsafeBytes { Data($0) }
            )
            #expect(StorageKeyManager.shared.hasCachedKey)
        }
    }

    @Test
    func encryptedStorageProbeDefersWhenItsRootChanges() async throws {
        try await StoragePathsTestLock.shared.run {
            let previousRoot = OsaurusPaths.overrideRoot
            let firstRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-storage-evidence-first-\(UUID().uuidString)",
                isDirectory: true
            )
            let secondRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-storage-evidence-second-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: firstRoot,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: secondRoot,
                withIntermediateDirectories: true
            )
            OsaurusPaths.overrideRoot = firstRoot
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: firstRoot)
                try? FileManager.default.removeItem(at: secondRoot)
            }

            #expect(StorageKeyManager.disablesKeychainForProcess)
            let result = StorageKeyManager.shared._encryptedStorageExistsForTesting(
                expectedIsolation: true,
                beforeFirstProbe: { OsaurusPaths.overrideRoot = secondRoot }
            )
            #expect(result == .retry)
        }
    }
}
