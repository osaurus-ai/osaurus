//
//  ServerConfigStoreTestLock.swift
//  OsaurusCoreTests
//
//  Process-wide serialization for tests that mutate the live
//  `ServerConfigurationStore` / `ServerRuntimeSettingsStore` state or flip
//  their `overrideDirectory` statics. `@Suite(.serialized)` only serializes
//  tests inside one suite; suites still run in parallel, so an override to a
//  temp sandbox in one suite makes every concurrent reader (e.g. the
//  declarative `ConfigExporter` / `ConfigApplier` round trips) observe
//  factory defaults mid-test — a nondeterministic failure that only
//  reproduces in the full parallel run, never in isolation.
//
//  Actor-based (not a `DispatchSemaphore`) so an `await acquire()` yields
//  the cooperative pool instead of blocking it — mirrors
//  `RemoteProviderTestLock`.
//

import Foundation

actor ServerConfigStoreTestLock {
    static let shared = ServerConfigStoreTestLock()

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

    func run<T: Sendable>(
        _ body: @MainActor @Sendable () async throws -> T
    ) async rethrows -> T {
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
