//
//  ConnectionConfigurationCache.swift
//  osaurus
//
//  Write-through, in-memory cache for the native connector configuration
//  stores (Discord, Slack, Telegram, iMessage, WhatsApp).
//
//  `AgentChannelAutoDestinationResolver.liveSources()` reads every
//  connector's configuration on each MainActor prompt-preview recompute.
//  Re-running `fileExists` + read + JSON decode (and default construction)
//  for all five files on every debounced signal parked the main thread for
//  seconds under I/O contention (Sentry APPLE-MACOS-3C5). The stores are the
//  only writers of these files, so `save` keeps the cache coherent; entries
//  are keyed by file URL so each account's file caches separately and
//  switching `overrideDirectory` (tests) never serves a value from another
//  directory.
//

import Foundation

final class ConnectionConfigurationCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL: Value] = [:]
    /// Bumped by every write (`store`, `update`, `remove`, `reset`). A load
    /// that raced a write must not cache what it read: the disk read may
    /// predate the write, and caching it would serve a stale value until the
    /// next reset (an `update` on a not-yet-cached URL is otherwise lost).
    private var generation: UInt64 = 0

    init() {}

    /// Return the cached value for `url`, or compute it with `load`, cache it,
    /// and return it. `load` runs outside the lock so a slow read never blocks
    /// other readers on the lock itself. If a write lands while `load` runs,
    /// the loaded value is returned to this caller but not cached, so the next
    /// read sees the write.
    func value(for url: URL, load: () -> Value) -> Value {
        lock.lock()
        if let value = values[url] {
            lock.unlock()
            return value
        }
        let startGeneration = generation
        lock.unlock()

        let loaded = load()

        lock.lock()
        defer { lock.unlock() }
        if generation == startGeneration {
            values[url] = loaded
            return loaded
        }
        return values[url] ?? loaded
    }

    /// Record the value just persisted at `url`.
    func store(_ value: Value, for url: URL) {
        lock.lock()
        values[url] = value
        generation &+= 1
        lock.unlock()
    }

    /// Rewrite the cached value for `url` in place. Nothing is cached when
    /// nothing was, so the next `value(for:load:)` still reads the truth from
    /// disk (and a load already in flight won't cache its pre-write read).
    func update(for url: URL, _ transform: (Value) -> Value) {
        lock.lock()
        if let value = values[url] {
            values[url] = transform(value)
        }
        generation &+= 1
        lock.unlock()
    }

    /// Drop the cached value for a file that was deleted.
    func remove(for url: URL) {
        lock.lock()
        values[url] = nil
        generation &+= 1
        lock.unlock()
    }

    /// Drop every cached value so the next read hits disk.
    func reset() {
        lock.lock()
        values.removeAll()
        generation &+= 1
        lock.unlock()
    }
}
