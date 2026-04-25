//
//  StoragePathsTestLock.swift
//  OsaurusCoreTests
//
//  Process-wide serialization for tests that mutate
//  `OsaurusPaths.overrideRoot` or the `StorageKeyManager` cached key.
//  Both are global singletons, and `@Suite(.serialized)` only
//  serializes tests within a single suite — cross-suite tests can
//  trample on each other's setup state otherwise (e.g. one suite's
//  `tearDownEnv` removing the temp dir while another suite's test
//  is mid-flight).
//
//  Tests that touch either of these globals should wrap their
//  critical section in `await StoragePathsTestLock.shared.run { ... }`.
//

import Foundation

actor StoragePathsTestLock {
    static let shared = StoragePathsTestLock()

    private var holder = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !holder {
            holder = true
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            holder = false
        }
    }

    /// Run `body` with exclusive access to `OsaurusPaths.overrideRoot`
    /// and `StorageKeyManager.shared`'s cached key.
    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        do {
            let value = try await body()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }
}
