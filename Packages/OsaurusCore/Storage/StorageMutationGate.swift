//
//  StorageMutationGate.swift
//  osaurus
//
//  Slim readiness gate for at-rest storage. The only thing the gate
//  guards is key rotation: `StorageExportService.rotateStorageKey`
//  calls `beginMutating()` before it quiesces + rekeys every database and
//  `endMutating()` after. While `isMutating` is true, any
//  `*Database.open()` that hits `blockingAwaitNotMutating()` parks so
//  it can't open a half-rekeyed file with the wrong key.
//
//  Fast path is completely lock-free and main-actor-free: a single
//  atomic load that returns immediately when no rotation is running
//  (the overwhelmingly common case, including every launch).
//

import Foundation

@MainActor
public final class StorageMutationGate {
    public static let shared = StorageMutationGate()

    /// True only while a key rotation is actively re-encrypting
    /// databases. Mirrored to the lock-free `Self.isMutatingAtomic`
    /// so `blockingAwaitNotMutating()` can poll without hopping onto
    /// the main actor.
    public private(set) var isMutating: Bool = false {
        didSet { Self.isMutatingAtomic.store(isMutating) }
    }

    /// Cross-thread mirror of `isMutating` for the blocking fast
    /// path. Reads happen from arbitrary threads (every
    /// `*Database.open()` hits the gate defensively); writes happen
    /// on the main actor via the `didSet` above.
    nonisolated private static let isMutatingAtomic = AtomicBool(false)

    /// Lock-free check for main-actor launch paths that prefer to defer
    /// (and retry later) rather than park the UI while a rotation runs.
    nonisolated public static var isRotationInFlight: Bool { isMutatingAtomic.load() }

    /// Posted after a key rotation finishes (`endMutating`). Launch paths
    /// that skipped a load while a rotation was in flight observe this to
    /// retry once storage has settled.
    public static let didFinishMutatingNotification = Notification.Name(
        "StorageMutationGate.didFinishMutating"
    )

    /// Continuations parked by `awaitNotMutating` while a rotation is
    /// in flight. Drained by `endMutating()`.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    // MARK: - Rotation hooks

    /// Called by `StorageExportService.rotateStorageKey` before it
    /// starts re-encrypting. Blocks every subsequent
    /// `blockingAwaitNotMutating` / `awaitNotMutating` caller until
    /// `endMutating()` runs.
    public func beginMutating() {
        isMutating = true
    }

    /// Companion to `beginMutating`. Wakes up everything parked in
    /// `awaitNotMutating`.
    public func endMutating() {
        isMutating = false
        let parked = waiters
        waiters.removeAll()
        for cont in parked { cont.resume() }
        NotificationCenter.default.post(name: Self.didFinishMutatingNotification, object: nil)
    }

    // MARK: - Gating

    /// Async gate: resolves immediately unless a rotation is in
    /// flight, in which case it parks until `endMutating()` runs.
    public func awaitNotMutating() async {
        while isMutating {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if !isMutating {
                    cont.resume()
                } else {
                    waiters.append(cont)
                }
            }
        }
    }

    /// Synchronous gate for callers that can't go async (the
    /// `*Database.open()` paths). Fast path is a lock-free atomic
    /// poll. The slow path (only while a rotation is running) spins
    /// the main run loop so the UI keeps painting while it waits.
    nonisolated public static func blockingAwaitNotMutating() {
        if StorageKeyManager.disablesKeychainForProcess {
            return
        }

        if RuntimeEnvironment.isUnderTests {
            // Tests use isolated temporary databases and don't rotate
            // the real storage key under the gate. Bypassing this
            // prevents Swift Concurrency deadlocks when tests run on
            // the MainActor and hit the semaphore wait.
            return
        }

        // Fast path: no rotation running.
        if !isMutatingAtomic.load() {
            return
        }

        // Slow path: park until the rotation finishes.
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await shared.awaitNotMutating()
            semaphore.signal()
        }

        if Thread.isMainThread {
            while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
        } else {
            semaphore.wait()
        }
    }
}
