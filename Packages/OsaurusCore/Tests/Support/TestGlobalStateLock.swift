//
//  TestGlobalStateLock.swift
//  osaurusTests
//
//  Backward-compatible entrypoint for tests that predate
//  `StoragePathsTestLock`. Keep all path/global-state mutation on the same
//  async lock so swift-testing's parallel runner cannot interleave roots.
//

import Foundation

enum OsaurusTestGlobals {
    /// Run `body` while holding the shared global-state lock.
    static func withPathsLock<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        try await StoragePathsTestLock.shared.run(body)
    }
}
