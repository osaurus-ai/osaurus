//
//  APIKeyValidatorEpoch.swift
//  osaurus
//
//  A monotonically increasing counter bumped whenever any input to the
//  `APIKeyValidator` changes (keys minted/revoked, whitelist edits,
//  revocations, or the agent set). The server's cached validator snapshot
//  compares the epoch it was built at against the current epoch and rebuilds
//  when stale, so newly minted pairing keys take effect and revoked keys stop
//  working without a server restart.
//

import Foundation

public final class APIKeyValidatorEpoch: @unchecked Sendable {
    public static let shared = APIKeyValidatorEpoch()

    private let lock = NSLock()
    private var value: UInt64 = 0

    private init() {}

    /// Current epoch value.
    public func current() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// Invalidate any cached validator built before now.
    public func bump() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }
}
