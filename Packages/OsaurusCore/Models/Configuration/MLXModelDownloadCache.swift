//
//  MLXModelDownloadCache.swift
//  osaurus
//
//  Process-wide cache for `MLXModel.isDownloaded` results, keyed by
//  model id. Without this cache every SwiftUI body that asked
//  `filter { $0.isDownloaded }` paid for several
//  `FileManager.fileExists` probes plus a directory enumerator open
//  per model — the dominant cost of the Models tab grid + the sidebar
//  badge while the user idled on the Settings shell.
//
//  Invalidated on `.localModelsChanged` (already posted by
//  `ModelDownloadService` on completion / delete and by the
//  directory-picker when the models root changes), so the cached
//  truth keeps up with on-disk state.
//

import Foundation

public enum MLXModelDownloadCache {
    /// `NSLock` guards `storage`. The cache is read from every SwiftUI
    /// `body` that touches `MLXModel.isDownloaded` (potentially on
    /// MainActor today, but accessor isolation is left intentionally
    /// flexible so we don't have to retrofit `@MainActor` onto
    /// `MLXModel` itself).
    private static let lock = NSLock()
    private nonisolated(unsafe) static var storage: [String: Bool] = [:]
    private nonisolated(unsafe) static var didInstallObserver = false
    private nonisolated(unsafe) static var observerToken: NSObjectProtocol?

    public static func value(for modelId: String) -> Bool? {
        ensureObserverInstalled()
        lock.lock()
        defer { lock.unlock() }
        return storage[modelId]
    }

    public static func set(_ value: Bool, for modelId: String) {
        ensureObserverInstalled()
        lock.lock()
        storage[modelId] = value
        lock.unlock()
    }

    /// Invalidate a single entry. Call after a targeted change that
    /// flips a specific model's downloaded state.
    public static func invalidate(modelId: String) {
        lock.lock()
        storage.removeValue(forKey: modelId)
        lock.unlock()
    }

    /// Drop everything. Cheap (the cache is a `[String: Bool]`),
    /// fired off `.localModelsChanged` so a single notification covers
    /// download completion, deletion, and directory-root changes.
    public static func invalidateAll() {
        lock.lock()
        storage.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Lazy install of the notification listener on first read/write
    /// (rather than at app start) so the cache file has no init-order
    /// requirements on the rest of OsaurusCore.
    private static func ensureObserverInstalled() {
        lock.lock()
        let already = didInstallObserver
        didInstallObserver = true
        lock.unlock()
        if already { return }

        let token = NotificationCenter.default.addObserver(
            forName: .localModelsChanged,
            object: nil,
            queue: nil
        ) { _ in
            MLXModelDownloadCache.invalidateAll()
        }
        lock.lock()
        observerToken = token
        lock.unlock()
    }
}
