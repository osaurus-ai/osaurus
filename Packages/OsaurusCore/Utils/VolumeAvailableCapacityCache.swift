//
//  VolumeAvailableCapacityCache.swift
//  osaurus
//
//  Background cache of each volume's purgeable-inclusive free space.
//

import Darwin
import Foundation
import os

/// Background cache of each volume's "available for important usage"
/// capacity: free space including what macOS purges on demand (APFS local
/// snapshots, purgeable caches). That is the figure Finder and System
/// Settings show. The strict `.systemFreeSize` excludes it, so on a Mac with
/// a large purgeable pool it reads as nearly full (one 8 TB Mac: 18 GB
/// strict vs 1.44 TB available).
///
/// The query can enter CacheDelete and take a long time on some volumes, so
/// it never runs on the caller's thread: `cachedBytes(forPath:)` returns the
/// last value (nil until the first refresh lands) and schedules a
/// background refresh when the value is missing or stale.
final class VolumeAvailableCapacityCache: @unchecked Sendable {
    static let shared = VolumeAvailableCapacityCache()

    private struct Entry {
        var bytes: Int64?
        var refreshedAt: Date?
        var refreshing = false
    }

    private let entries = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])
    private let maxAge: TimeInterval
    private let now: @Sendable () -> Date
    private let query: @Sendable (String) -> Int64?

    init(
        maxAge: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() },
        query: @escaping @Sendable (String) -> Int64? = VolumeAvailableCapacityCache.importantUsageBytes
    ) {
        self.maxAge = maxAge
        self.now = now
        self.query = query
    }

    /// Last known purgeable-inclusive free bytes on the volume hosting
    /// `path`, or nil before the first background refresh completes.
    /// Never blocks on the capacity query.
    func cachedBytes(forPath path: String) -> Int64? {
        let volume = Self.volumeKey(forPath: path)
        let time = now()
        let maxAge = maxAge
        let (bytes, startRefresh) = entries.withLock { entries -> (Int64?, Bool) in
            var entry = entries[volume] ?? Entry()
            let stale = entry.refreshedAt.map { time.timeIntervalSince($0) >= maxAge } ?? true
            let start = stale && !entry.refreshing
            if start {
                entry.refreshing = true
                entries[volume] = entry
            }
            return (entry.bytes, start)
        }
        if startRefresh {
            Task.detached(priority: .utility) { [self] in
                refresh(path: path, volume: volume)
            }
        }
        return bytes
    }

    /// Runs the capacity query on the calling thread and stores the result.
    /// For background callers and tests; UI and load paths use
    /// `cachedBytes(forPath:)`.
    func refreshNow(forPath path: String) {
        refresh(path: path, volume: Self.volumeKey(forPath: path))
    }

    private func refresh(path: String, volume: String) {
        let bytes = query(path)
        let time = now()
        entries.withLock { entries in
            var entry = entries[volume] ?? Entry()
            // A failed query keeps the last good value rather than erasing it.
            if let bytes { entry.bytes = bytes }
            entry.refreshedAt = time
            entry.refreshing = false
            entries[volume] = entry
        }
    }

    /// Mount point of the volume hosting `path`, so every path on one volume
    /// shares an entry. Falls back to the path itself when `statfs` fails.
    static func volumeKey(forPath path: String) -> String {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return path }
        return withUnsafeBytes(of: &info.f_mntonname) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    static func importantUsageBytes(forPath path: String) -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        return (try? URL(fileURLWithPath: path).resourceValues(forKeys: keys))?
            .volumeAvailableCapacityForImportantUsage
    }
}
