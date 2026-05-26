//
//  PrivacyFilterStoreTestLock.swift
//  osaurus / PrivacyFilter Tests
//
//  Process-wide lock shared by every test that mutates
//  `PrivacyFilterStore._overrideDirectory` (a `nonisolated(unsafe)`
//  static the production store uses for test sandboxing).
//
//  Why we need it: the three participating suites —
//  `PrivacyReviewServiceTests`, `PrivacyFilterPipelineCancelTests`,
//  `PrivacyFilterStorePersistenceTests` — each declare
//  `@Suite(.serialized)` internally, which only serializes WITHIN
//  the suite. Swift Testing still runs OTHER suites in parallel and
//  they all stamp the override directory through the same global
//  static. PR #1244 CI run 26423000638 hit the race —
//  `presenterToken_unregisterOnlyMatching` failed because a parallel
//  `alwaysApprove_persists` write in
//  `PrivacyFilterStorePersistenceTests` flipped the shared snapshot
//  mid-test.
//
//  IMPORTANT: this MUST be an actor-based lock, not a
//  `DispatchSemaphore`. The first two suites are `@MainActor`, and
//  their async test bodies acquire the lock and then suspend on
//  `await` (e.g. `await outcomeTask.value`). A semaphore-based
//  `wait()` from a sibling `@MainActor` test would block the
//  MainActor cooperative scheduler while the lock-holding test is
//  suspended — the holder can never resume to release the lock and
//  the entire test process hangs. PR #1244 CI run 26464436962
//  reproduced this exactly: `resetForAgent_savesPreviousSessionUnderOldAgent`
//  hit the 60s xctest timeout while the spindump showed the main
//  thread parked in `semaphore_wait_trap` called from
//  `presenterCancel_resolvesAsCanceled`. The actor pattern below
//  composes with Swift Concurrency — `await acquire()` yields the
//  MainActor instead of blocking it.
//
//  Usage: every @Test that touches the store calls
//  `await acquirePrivacyStoreSandbox(name)` and pairs the returned
//  guard with `defer guard.release()` (sync release is fine — only
//  acquisition needs to suspend).
//

import Foundation

@testable import OsaurusCore

/// Process-wide lock for `PrivacyFilterStore` test access.
/// Actor-backed so an `await acquire()` from a `@MainActor` test
/// yields the MainActor (rather than blocking it like a
/// `DispatchSemaphore.wait()` would) — see the file header for the
/// CI hang this prevents.
actor PrivacyFilterStoreTestLock {
    static let shared = PrivacyFilterStoreTestLock()

    private var holder = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !holder {
            holder = true
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    nonisolated func release() {
        // Hop into the actor's executor on a detached Task so the
        // sync `defer { guard.release() }` callsite doesn't have to
        // be async. The hand-off is FIFO via `waiters`, so ordering
        // is preserved even though release runs slightly later than
        // the defer point.
        Task { await self.handoff() }
    }

    private func handoff() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            holder = false
        }
    }
}

/// Per-test sandbox returned by `acquirePrivacyStoreSandbox`. The
/// caller MUST hold the returned guard for the lifetime of the
/// test body (e.g. via `defer guard.release()`) — `release()` is
/// idempotent so it's safe in error / early-return paths too.
final class PrivacyStoreSandboxGuard {
    let sandbox: URL
    private var released = false

    init(sandbox: URL) {
        self.sandbox = sandbox
    }

    func release() {
        guard !released else { return }
        released = true
        PrivacyFilterStore.setOverrideDirectory(nil)
        PrivacyFilterStoreTestLock.shared.release()
    }

    deinit {
        // Belt-and-suspenders — Swift's defer is the documented
        // release path, but if a test forgets, deinit still runs
        // when the local goes out of scope and we recover.
        release()
    }
}

/// Acquire the cross-suite lock AND set the override directory to a
/// fresh temp sandbox. Pair with `guard.release()` in `defer` to
/// release the lock and reset the override at the end of the test.
///
/// `name` is a human-readable prefix on the temp path so debug
/// output from a failing run identifies which suite owns the dir.
///
/// `async` because acquisition routes through an actor (see
/// `PrivacyFilterStoreTestLock` for the MainActor-deadlock this
/// prevents). Sync test bodies should be converted to
/// `@Test func ... async throws` — see the persistence suite for the
/// pattern.
@discardableResult
func acquirePrivacyStoreSandbox(_ name: String) async -> PrivacyStoreSandboxGuard {
    await PrivacyFilterStoreTestLock.shared.acquire()
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "osaurus-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    PrivacyFilterStore.setOverrideDirectory(dir)
    return PrivacyStoreSandboxGuard(sandbox: dir)
}
