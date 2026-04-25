//
//  AtomicBool.swift
//  osaurus
//
//  Tiny lock-free Bool wrapper used by `StorageMigrationCoordinator`
//  for the synchronous fast path on `blockingAwaitReady()`.
//
//  We use `OSAllocatedUnfairLock<Bool>` rather than a raw atomic
//  primitive because:
//   - It's part of the Apple SDK (no extra SwiftPM dep, available
//     on macOS 13+).
//   - The contention pattern is "many readers, near-zero writers"
//     (writes happen on the main actor when migration completes
//     or rotation flips), where the unfair-lock cost is dominated
//     by the same memory barrier a `ManagedAtomic<Bool>` would
//     emit.
//
//  Callers that need a richer atomic API should reach for
//  `swift-atomics` directly — this type is intentionally just two
//  methods so the StorageMigrationCoordinator gate stays auditable.
//

import Foundation
import os

/// Lock-protected Bool with the same hot-path cost as a single
/// atomic load/store on Apple platforms.
public final class AtomicBool: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Bool>

    public init(_ initialValue: Bool) {
        self.lock = OSAllocatedUnfairLock(initialState: initialValue)
    }

    public func load() -> Bool {
        lock.withLock { $0 }
    }

    public func store(_ newValue: Bool) {
        lock.withLock { $0 = newValue }
    }
}
