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

    /// Per-model continuations waiting for the count to reach zero. Keyed by
    /// model name; resumed in FIFO order when the last lease is released.
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    private init() {}

    // MARK: - Acquire / release

    /// Pin `name` against eviction. Pair with exactly one `release(name)` on
    /// every exit path of the holder (success, throw, cancel).
    public func acquire(_ name: String) {
        counts[name, default: 0] += 1
    }

    /// Drop one lease on `name`. When the count reaches zero, all `waitForZero`
    /// waiters for that name are resumed. Floors at zero so a buggy double-release
    /// can never poison the count.
    public func release(_ name: String) {
        let current = counts[name] ?? 0
        let next = current - 1
        if next <= 0 {
            counts.removeValue(forKey: name)
            wakeWaiters(for: name)
        } else {
            counts[name] = next
        }
    }

    private func wakeWaiters(for name: String) {
        guard let pending = waiters.removeValue(forKey: name) else { return }
        for continuation in pending { continuation.resume() }
    }

    // MARK: - Eviction-side gating

    /// Suspend until no leases are held on `name`.
    ///
    /// Re-checks after each wake so the `acquire → wake → re-acquire` race
    /// that can happen under sustained load is handled correctly: the waiter
    /// simply re-suspends until the count actually stabilises at zero.
    public func waitForZero(_ name: String) async {
        while (counts[name] ?? 0) > 0 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Re-check atomically inside the actor before parking.
                if (counts[name] ?? 0) == 0 {
                    continuation.resume()
                } else {
                    waiters[name, default: []].append(continuation)
                }
            }
        }
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
}
