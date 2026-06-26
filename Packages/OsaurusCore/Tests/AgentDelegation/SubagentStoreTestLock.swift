//
//  SubagentStoreTestLock.swift
//  osaurus / AgentDelegation Tests
//
//  Process-wide lock shared by every test that mutates
//  `SubagentConfigurationStore`'s `nonisolated(unsafe)` static
//  `overrideDirectory` / `cachedSnapshot` (the production store keeps
//  them for test sandboxing).
//
//  Why we need it: `SubagentToolAvailabilityTests` and
//  `SubagentConfigurationStoreTests` each declare `@Suite(.serialized)`,
//  which only serializes tests WITHIN a suite. Swift Testing still runs
//  the two suites in parallel, and both stamp the same global override +
//  snapshot cache, so a write in one suite flips the shared snapshot
//  mid-test in the other. Concretely:
//  `imageToolEntersSchemaWhenMasterAndImageDelegationAreEnabled` reads
//  `ToolRegistry.alwaysLoadedSpecs`, whose `image`/`spawn` gate calls
//  `SubagentConfigurationStore.snapshot()`; a parallel
//  `setOverrideDirectory` from the store suite redirects that snapshot to
//  an empty/default config, the delegation gate reads "off", and the
//  `image` tool vanishes from the schema — a nondeterministic failure
//  that only reproduces in the full parallel run, never in isolation.
//
//  Actor-based (not a `DispatchSemaphore`) so an `await acquire()` yields
//  the cooperative pool instead of blocking it — mirrors
//  `PrivacyFilterStoreTestLock`, see that file for the MainActor deadlock
//  a semaphore-based lock would cause.
//

import Foundation

@testable import OsaurusCore

/// Process-wide lock for `SubagentConfigurationStore` test access.
actor SubagentStoreTestLock {
    static let shared = SubagentStoreTestLock()

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
        // Hop onto the actor on a detached Task so the sync
        // `defer { lease.release() }` callsite stays synchronous. FIFO
        // hand-off via `waiters` preserves ordering.
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

/// Per-test sandbox returned by `acquireSubagentStoreSandbox`. Hold it for
/// the lifetime of the test body (e.g. via `defer lease.release()`).
/// `release()` is idempotent — safe on error / early-return paths and from
/// `deinit`.
final class SubagentStoreSandboxGuard {
    let sandbox: URL
    private var released = false

    init(sandbox: URL) {
        self.sandbox = sandbox
    }

    func release() {
        guard !released else { return }
        released = true
        SubagentConfigurationStore.setOverrideDirectory(nil)
        try? FileManager.default.removeItem(at: sandbox)
        SubagentStoreTestLock.shared.release()
    }

    deinit {
        // Belt-and-suspenders: `defer` is the documented release path, but
        // if a test forgets, deinit still resets the override + unlocks.
        release()
    }
}

/// Acquire the cross-suite lock AND point the store override at a fresh
/// temp sandbox. Pair with `lease.release()` in `defer` to reset the
/// override and release the lock. `name` is a human-readable prefix on the
/// temp path so a failing run identifies which suite owns the dir.
@discardableResult
func acquireSubagentStoreSandbox(_ name: String) async -> SubagentStoreSandboxGuard {
    await SubagentStoreTestLock.shared.acquire()
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("osaurus-\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    SubagentConfigurationStore.setOverrideDirectory(dir)
    return SubagentStoreSandboxGuard(sandbox: dir)
}
