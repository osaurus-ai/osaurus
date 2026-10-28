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
//  are keyed by file URL so switching `overrideDirectory` (tests) never
//  serves a value from another directory.
//

import Foundation

final class ConnectionConfigurationCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    private var value: Value?

    init() {}

    /// Return the cached value for `url`, or compute it with `load`, cache it,
    /// and return it. `load` runs outside the lock so a slow read never blocks
    /// other readers on the lock itself.
    func value(for url: URL, load: () -> Value) -> Value {
        lock.lock()
        if self.url == url, let value {
            lock.unlock()
            return value
        }
        lock.unlock()

        let loaded = load()
        store(loaded, for: url)
        return loaded
    }

    /// Record the value just persisted at `url`.
    func store(_ value: Value, for url: URL) {
        lock.lock()
        self.url = url
        self.value = value
        lock.unlock()
    }

    /// Drop the cached value so the next read hits disk.
    func reset() {
        lock.lock()
        url = nil
        value = nil
        lock.unlock()
    }
}
