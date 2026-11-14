//
//  WorkspaceRosterTestLock.swift
//  OsaurusCoreTests
//
//  Process-wide serialization for tests that seed or reset
//  `WorkspaceRosterStore.shared` (the roster the spawn pool, the HTTP
//  exclusion check and the liveness probe all read). `@Suite(.serialized)`
//  only serializes tests inside one suite; two suites resetting the shared
//  store at once make each other's fixtures vanish mid-test.
//

import Foundation

@testable import OsaurusCore

actor WorkspaceRosterTestLock {
    static let shared = WorkspaceRosterTestLock()

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

    /// Run `body` with exclusive access to the shared roster store, which is
    /// reset before and after so every caller starts from — and leaves — the
    /// never-loaded state.
    func run<T: Sendable>(
        _ body: @MainActor @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire()
        await MainActor.run { WorkspaceRosterStore.shared.resetForTesting() }
        do {
            let value = try await body()
            await MainActor.run { WorkspaceRosterStore.shared.resetForTesting() }
            release()
            return value
        } catch {
            await MainActor.run { WorkspaceRosterStore.shared.resetForTesting() }
            release()
            throw error
        }
    }
}
