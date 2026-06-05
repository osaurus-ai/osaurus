//
//  TestGlobalStateLock.swift
//  osaurusTests
//
//  swift-testing runs suites in parallel. A handful of tests mutate
//  process-wide state — `OsaurusPaths.overrideRoot`, the static
//  `ModelSizeCache` / `ExternalModelLocator` registries — that can't be
//  isolated per-test. They acquire this shared lock for their full duration
//  so they run serially relative to one another regardless of which suite
//  they live in.
//

import Foundation

enum OsaurusTestGlobals {
    static let pathsLock = NSLock()

    /// Run `body` while holding the shared global-state lock.
    static func withPathsLock<T>(_ body: () throws -> T) rethrows -> T {
        pathsLock.lock()
        defer { pathsLock.unlock() }
        return try body()
    }
}
