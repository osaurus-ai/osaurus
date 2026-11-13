//
//  SandboxMemoryReservation.swift
//  OsaurusCore
//
//  Unified memory the running sandbox VM holds, readable synchronously by
//  the Memory Safety plan so model admission leaves room for it.
//

import Foundation

public enum SandboxMemoryReservation {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bytes: UInt64 = 0

    /// Guest RAM the running VM was booted with; 0 when no VM is running.
    public static var currentBytes: UInt64 {
        lock.withLock { bytes }
    }

    static func vmStarted(bytes value: UInt64) {
        lock.withLock { bytes = value }
    }

    static func vmStopped() {
        lock.withLock { bytes = 0 }
    }
}
