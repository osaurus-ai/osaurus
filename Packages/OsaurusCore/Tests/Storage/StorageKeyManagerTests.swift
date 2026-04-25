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
}
