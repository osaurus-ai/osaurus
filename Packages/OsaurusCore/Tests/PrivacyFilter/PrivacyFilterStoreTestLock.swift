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
//  Usage: every @Test that touches the store calls
//  `withPrivacyFilterStoreLock { ... }` (or pairs `.lock()` with a
//  `defer .unlock()` if its body needs async). NSLock is the right
//  primitive here: same-thread lock/unlock from inside the test
//  body (the closure runs on whichever thread Swift Testing
//  scheduled the @Test on, and lock/unlock both fire from there).
//

import Foundation

@testable import OsaurusCore

/// Process-wide lock for `PrivacyFilterStore` test access. Thread-
/// agnostic (`DispatchSemaphore`) so an async test body can lock on
/// one thread, suspend on `await`, resume on another thread, and
/// unlock from `defer` without crashing (`NSLock` /
/// `os_unfair_lock` would).
enum PrivacyFilterStoreTestLock {
    private static let semaphore = DispatchSemaphore(value: 1)

    static func lock() { semaphore.wait() }
    static func unlock() { semaphore.signal() }
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
        PrivacyFilterStoreTestLock.unlock()
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
@discardableResult
func acquirePrivacyStoreSandbox(_ name: String) -> PrivacyStoreSandboxGuard {
    PrivacyFilterStoreTestLock.lock()
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "osaurus-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    PrivacyFilterStore.setOverrideDirectory(dir)
    return PrivacyStoreSandboxGuard(sandbox: dir)
}
