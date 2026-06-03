//
//  ModelLease.swift
//  osaurus
//
//  Refcounted leases on loaded model names. Acts as the single source of truth
//  for "this model is in use right now, do not unload it" so that GC paths,
//  strict eviction, and manual unload all funnel through the same gate.
//
//  Without this, an in-flight MLX generation can have its weights/buffers
//  freed mid-stream and the next Metal command buffer submission crashes with
//  `notifyExternalReferencesNonZeroOnDealloc` (the Metal command buffer still
//  references freed AGXG buffers).
//
//  Lease lifetime is tied to the lifetime of a single generation stream:
//  acquired right after `loadContainer` succeeds and released when the gated
//  generation task completes (on success, throw, or cancellation).
//

import Foundation
import os

private let leaseLog = Logger(subsystem: "ai.osaurus", category: "ModelLease")

/// Refcount + waiter actor for pinning loaded models against eviction.
///
/// Eviction-side callers (`unload`, `loadContainer` strict eviction,
/// `unloadModelsNotIn`) MUST `await waitForZero(name)` before tearing down
/// the model's container/buffers. Generation-side callers wrap their stream
/// lifetime with `acquire` / `release`.
public actor ModelLease {
    public static let shared = ModelLease()

    /// Per-model active refcount. A name is removed from the dictionary
    /// when it drops to zero so `activeNames()` is cheap.
    private var counts: [String: Int] = [:]

    /// A parked `waitForZero` caller. `timeoutItem` (if any) fires the timed
    /// variant's deadline off a Dispatch queue; it is cancelled the moment the
    /// waiter is resumed by a release so a drained lease never leaves a timer
    /// running. A Dispatch timer (rather than `Task.sleep`) is used so the
    /// deadline fires even when the cooperative pool is saturated by the
    /// quit-teardown awaits this drain backstops.
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Never>
        let timeoutItem: DispatchWorkItem?
    }

    /// Per-model continuations waiting for the count to reach zero. Keyed by
    /// model name; resumed in FIFO order when the last lease is released.
    private var waiters: [String: [Waiter]] = [:]

    /// Monotonic id source so the timed variant can find and remove its own
    /// waiter on timeout without disturbing other parked callers.
    private var nextWaiterID: UInt64 = 0

    /// Count of unbalanced `release` calls (more releases than acquires for a
    /// name). A non-zero value means a generation path is missing a paired
    /// `acquire` (or releasing twice) — dangerous because a phantom release
    /// could let `waitForZero` succeed while Metal work is still live.
    /// Surfaced for diagnostics instead of being silently floored away.
    private var underflowCount: Int = 0

    private init() {}

    // MARK: - Acquire / release

    /// Pin `name` against eviction. Pair with exactly one `release(name)` on
    /// every exit path of the holder (success, throw, cancel).
    public func acquire(_ name: String) {
        counts[name, default: 0] += 1
    }

    /// Drop one lease on `name`. When the count reaches zero, all `waitForZero`
    /// waiters for that name are resumed.
    ///
    /// An unbalanced release (no active lease) is a programming error — a
    /// missing `defer { release }` pairing or a double release. Rather than
    /// silently flooring at zero (which hides the bug and risks a phantom
    /// release letting `waitForZero` win while Metal work is live), we count
    /// it, log it, and trap in debug builds.
    public func release(_ name: String) {
        let current = counts[name] ?? 0
        guard current > 0 else {
            // Detect (don't silently floor): count + log loudly so the
            // acquire/release pairing bug is observable via `releaseUnderflows()`
            // / `/health`. We deliberately do NOT `fatalError`/`assertionFailure`
            // here — a phantom release is a bug, but trapping would turn a
            // latent imbalance into a hard crash, which is worse for a server.
            underflowCount += 1
            leaseLog.error(
                "release underflow for \(name, privacy: .public) — released with no active lease (total underflows: \(self.underflowCount, privacy: .public))"
            )
            return
        }
        let next = current - 1
        if next == 0 {
            counts.removeValue(forKey: name)
            wakeWaiters(for: name)
        } else {
            counts[name] = next
        }
    }

    private func wakeWaiters(for name: String) {
        guard let pending = waiters.removeValue(forKey: name) else { return }
        for waiter in pending {
            waiter.timeoutItem?.cancel()
            waiter.continuation.resume()
        }
    }

    /// Called by the timed variant's deadline task. Removes only the waiter
    /// with `id` (if it's still parked) and resumes it so the timed caller
    /// returns `false`. A no-op if the lease already drained and the release
    /// path resumed/removed it first.
    private func timeoutWaiter(name: String, id: UInt64) {
        guard var pending = waiters[name],
            let index = pending.firstIndex(where: { $0.id == id })
        else { return }
        let waiter = pending.remove(at: index)
        if pending.isEmpty {
            waiters.removeValue(forKey: name)
        } else {
            waiters[name] = pending
        }
        waiter.continuation.resume()
    }

    // MARK: - Eviction-side gating

    /// Suspend until no leases are held on `name`.
    ///
    /// Re-checks after each wake so the `acquire → wake → re-acquire` race
    /// that can happen under sustained load is handled correctly: the waiter
    /// simply re-suspends until the count actually stabilises at zero.
    public func waitForZero(_ name: String) async {
        while (counts[name] ?? 0) > 0 {
            let id = nextWaiterID
            nextWaiterID &+= 1
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Re-check atomically inside the actor before parking.
                if (counts[name] ?? 0) == 0 {
                    continuation.resume()
                } else {
                    waiters[name, default: []].append(
                        Waiter(id: id, continuation: continuation, timeoutItem: nil)
                    )
                }
            }
        }
    }

    /// Bounded variant of `waitForZero` for the app-quit path. Suspends until
    /// no leases are held on `name` OR until `timeoutSeconds` elapses,
    /// whichever comes first.
    ///
    /// - Returns: `true` if the count reached zero, `false` on timeout. On
    ///   timeout the waiter is removed (and the deadline timer is the only
    ///   thing that resumes it), so a stuck/never-released lease can't hang
    ///   quit. Unlike the untimed variant this does not loop — a single
    ///   bounded wait is exactly what teardown wants.
    @discardableResult
    public func waitForZero(_ name: String, timeoutSeconds: Double) async -> Bool {
        if (counts[name] ?? 0) == 0 { return true }

        let id = nextWaiterID
        nextWaiterID &+= 1

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if (counts[name] ?? 0) == 0 {
                continuation.resume()
                return
            }
            // Fire the deadline from a Dispatch timer instead of `Task.sleep`:
            // the quit path that uses this drain can saturate the cooperative
            // pool, and a `Task.sleep` deadline would then wake late, stranding
            // `clearAll` — the exact hang this bound exists to prevent. The
            // work item hops back into the actor to remove/resume the waiter;
            // `timeoutWaiter` is a no-op if a release already drained it, and
            // `wakeWaiters` cancels this item so the timer never fires post-drain.
            let timeoutItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                Task { await self.timeoutWaiter(name: name, id: id) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + max(0, timeoutSeconds),
                execute: timeoutItem
            )
            waiters[name, default: []].append(
                Waiter(id: id, continuation: continuation, timeoutItem: timeoutItem)
            )
        }

        return (counts[name] ?? 0) == 0
    }

    // MARK: - Inspection

    /// Snapshot of model names currently pinned by at least one lease.
    /// Callers use this to merge into "do not GC" sets when computing which
    /// models to unload after a chat window closes.
    public func activeNames() -> Set<String> {
        Set(counts.keys)
    }

    /// Current refcount for `name`. Primarily for diagnostics / tests.
    public func count(for name: String) -> Int {
        counts[name] ?? 0
    }

    /// Number of unbalanced `release` calls observed since launch. Non-zero
    /// indicates a lease acquire/release pairing bug. Surfaced for `/health`
    /// and tests.
    public func releaseUnderflows() -> Int {
        underflowCount
    }

    /// Atomic snapshot of all per-model in-flight counts. Used by `/health`
    /// to surface contention so external observers can detect when one
    /// model is starving the others without having to scrape logs.
    public func snapshot() -> [String: Int] {
        counts
    }
}
