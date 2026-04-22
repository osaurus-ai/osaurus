//
//  DynamicCatalogTestLock.swift
//  OsaurusCoreTests
//
//  Process-wide serialization for tests that mutate or assert on the
//  global `ToolRegistry` dynamic catalog. `@Suite(.serialized)` only
//  serializes tests within a single suite, so cross-suite races (e.g.
//  `MCPHTTPHandlerTests` registering a dynamic tool while
//  `PluginCreatorInjectionTests` asserts `dynamicCatalogIsEmpty()`)
//  still happen — both suites are `@MainActor`, but every `await`
//  releases the MainActor and lets the other suite interleave.
//
//  Tests that touch the dynamic catalog should wrap their critical
//  section in `await DynamicCatalogTestLock.shared.run { ... }`.
//

import Foundation

actor DynamicCatalogTestLock {
    static let shared = DynamicCatalogTestLock()

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
            // Next waiter inherits the held lock; `holder` stays true.
            next.resume()
        } else {
            holder = false
        }
    }

    /// Runs `body` with exclusive access to the dynamic catalog. The body
    /// runs on the MainActor so it can use `defer` for synchronous
    /// `ToolRegistry` cleanup, mirroring the ergonomics of the existing
    /// `@MainActor` test bodies.
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
