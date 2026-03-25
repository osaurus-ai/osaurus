//
//  KVCacheStore.swift
//  osaurus
//
//  Tiered KV cache management: hot RAM tier with LRU eviction backed by
//  cold SSD tier using safetensors persistence. Keyed by session_id so
//  multi-turn conversations skip redundant prefill.
//

import Foundation
import MLX
@preconcurrency import MLXLMCommon

/// Manages per-session KV caches across a hot RAM tier and cold SSD tier.
/// Must be used from within the `ModelRuntime` actor (not independently thread-safe).

private final class CacheBox: @unchecked Sendable {
    let cache: [any KVCache]
    init(_ cache: [any KVCache]) { self.cache = cache }
}

struct KVCacheStore {

    // MARK: - Entry

    final class Entry {
        var cache: [any KVCache]?
        var tokens: [Int]?
        var ssdPath: URL?
        var modelName: String
        var lastAccess: Date
        var sizeBytes: Int
        /// Set only for prefix cache entries; stores the hash that was used as
        /// part of the composite key so callers can inspect which context is cached.
        var contentHash: String?

        init(
            cache: [any KVCache]?,
            tokens: [Int]? = nil,
            ssdPath: URL? = nil,
            modelName: String,
            sizeBytes: Int,
            contentHash: String? = nil
        ) {
            self.cache = cache
            self.tokens = tokens
            self.ssdPath = ssdPath
            self.modelName = modelName
            self.lastAccess = Date()
            self.sizeBytes = sizeBytes
            self.contentHash = contentHash
        }
    }

    // MARK: - State

    private var entries: [String: Entry] = [:]
    private var lruOrder: [String] = []
    private(set) var totalHotBytes: Int = 0

    private let ssdCacheDir: URL = {
        let dir = OsaurusPaths.cache().appendingPathComponent("kv", isDirectory: true)
        OsaurusPaths.ensureExistsSilent(dir)
        return dir
    }()

    /// Maximum total SSD cache size in bytes (default 4 GB)
    private let maxSSDBytes: Int = 4 * 1024 * 1024 * 1024

    /// For tracking background disk writes in tests
    var lastSaveTask: Task<Void, Never>?

    // MARK: - Budget

    /// Computes the available memory budget for hot KV session caches.
    /// Uses half of the headroom after model weights to leave the other half
    /// for OS, apps, MLX intermediates, and breathing room.
    static func computeBudget(modelWeightsBytes: Int64) -> Int {
        let systemRAM = Int(ProcessInfo.processInfo.physicalMemory)
        let available = systemRAM - Int(modelWeightsBytes)
        let budget = available / 2
        return max(512 * 1024 * 1024, budget)
    }

    // MARK: - Hot tier

    /// Retrieves a hot cache for the given session, or restores it from SSD.
    /// Returns `nil` on a complete miss (caller must do full prefill).
    mutating func getCache(sessionId: String, modelName: String) -> ([any KVCache]?, [Int]?) {
        guard let entry = entries[sessionId] else { return (nil, nil) }

        // Invalidate if model changed
        if entry.modelName != modelName {
            evictEntry(sessionId: sessionId, saveSSD: false)
            return (nil, nil)
        }

        // Hot hit
        if let cache = entry.cache {
            touchLRU(sessionId)
            return (cache, entry.tokens)
        }

        // Cold hit: restore from SSD
        if entry.ssdPath != nil {
            do {
                let (cache, metadata) = try loadPromptCache(url: entry.ssdPath!)
                guard Self.isValidCache(cache) else {
                    print(
                        "[KVCacheStore] Session cache validation failed for \(sessionId.prefix(8)), removing stale SSD file"
                    )
                    evictEntry(sessionId: sessionId, saveSSD: false)
                    return (nil, nil)
                }
                entry.cache = cache
                if let tokensStr = metadata["tokens"], let data = tokensStr.data(using: .utf8) {
                    entry.tokens = try? JSONDecoder().decode([Int].self, from: data)
                }
                let bytes = Self.cacheBytes(cache)
                entry.sizeBytes = bytes
                totalHotBytes += bytes
                entry.lastAccess = Date()
                touchLRU(sessionId)
                print("[KVCacheStore] Restored session \(sessionId.prefix(8)) from SSD (\(bytes / 1024)KB)")
                return (cache, entry.tokens)
            } catch {
                print("[KVCacheStore] Failed to load SSD cache for \(sessionId.prefix(8)): \(error)")
                evictEntry(sessionId: sessionId, saveSSD: false)
                return (nil, nil)
            }
        }

        return (nil, nil)
    }

    /// Stores or updates the hot cache for a session after generation.
    mutating func putCache(sessionId: String, cache: [any KVCache], tokens: [Int]?, modelName: String) {
        let bytes = Self.cacheBytes(cache)

        if let existing = entries[sessionId] {
            totalHotBytes -= existing.sizeBytes
            existing.cache = cache
            existing.tokens = tokens
            existing.sizeBytes = bytes
            existing.lastAccess = Date()
            existing.modelName = modelName
            // Invalidate stale SSD copy so evictToSSD re-persists the updated cache
            existing.ssdPath = nil
        } else {
            let entry = Entry(cache: cache, tokens: tokens, modelName: modelName, sizeBytes: bytes)
            entries[sessionId] = entry
        }

        totalHotBytes += bytes
        touchLRU(sessionId)
    }

    /// Ensures total hot cache bytes stay within the given budget by evicting
    /// least-recently-used sessions to SSD.
    mutating func ensureBudget(_ budgetBytes: Int) {
        while totalHotBytes > budgetBytes, let coldest = lruOrder.last {
            evictToSSD(sessionId: coldest)
        }
    }

    /// Evicts a specific session's hot cache to SSD.
    mutating func evictToSSD(sessionId: String) {
        guard let entry = entries[sessionId], let cache = entry.cache else {
            lruOrder.removeAll { $0 == sessionId }
            return
        }

        // Save to SSD if not already persisted (saveToDisk calls pruneSSDIfNeeded internally)
        if entry.ssdPath == nil {
            saveToDisk(sessionId: sessionId, cache: cache, tokens: entry.tokens, modelName: entry.modelName)
        }

        totalHotBytes -= entry.sizeBytes
        entry.cache = nil
        entry.sizeBytes = 0
        lruOrder.removeAll { $0 == sessionId }
    }

    /// Saves the given session's cache to SSD asynchronously in a background task.
    /// Sets `ssdPath` optimistically before the write completes so duplicate saves are avoided.
    /// Also calls `pruneSSDIfNeeded()` synchronously after scheduling the write.
    mutating func saveToDisk(sessionId: String, cache: [any KVCache], tokens: [Int]?, modelName: String) {
        let url = ssdCacheDir.appendingPathComponent("\(sessionId).safetensors")
        let bytes = Self.cacheBytes(cache)
        let start = Date()
        
        let box = CacheBox(cache)
        
        // Optimistically set the SSD path so we don't try to save it again
        self.entries[sessionId]?.ssdPath = url
        
        let task = Task.detached(priority: .background) {
            do {
                var metadata = ["model": modelName]
                if let tokens = tokens, let data = try? JSONEncoder().encode(tokens),
                    let str = String(data: data, encoding: .utf8)
                {
                    metadata["tokens"] = str
                }
                try savePromptCache(url: url, cache: box.cache, metadata: metadata)
                let durationMs = Date().timeIntervalSince(start) * 1000
                print("[KVCacheStore] [BENCHMARK] Saved session \(sessionId.prefix(8)) to SSD (\(bytes / 1024)KB) asynchronously in \(String(format: "%.1f", durationMs))ms")
            } catch {
                let durationMs = Date().timeIntervalSince(start) * 1000
                print("[KVCacheStore] [BENCHMARK] SSD save failed for \(sessionId.prefix(8)) after \(String(format: "%.1f", durationMs))ms: \(error)")
            }
        }
        self.lastSaveTask = task
        pruneSSDIfNeeded()
    }

    // MARK: - Invalidation

    /// Removes a session's cache entirely (RAM + SSD).
    mutating func invalidate(sessionId: String) {
        evictEntry(sessionId: sessionId, saveSSD: false)
    }

    /// Removes all caches for a given model (e.g., on model unload).
    mutating func invalidateModel(_ modelName: String) {
        let toRemove = entries.filter { $0.value.modelName == modelName }.map(\.key)
        for sid in toRemove {
            evictEntry(sessionId: sid, saveSSD: false)
        }
    }

    /// Removes all caches.
    mutating func clearAll() {
        for sid in Array(entries.keys) {
            evictEntry(sessionId: sid, saveSSD: false)
        }
    }

    // MARK: - SSD maintenance

    /// Evicts oldest SSD cache files when total disk usage exceeds the cap.
    /// Clears `ssdPath` on any entry whose file was deleted.
    mutating func pruneSSDIfNeeded() {
        let fm = FileManager.default
        guard
            let items = try? fm.contentsOfDirectory(
                at: ssdCacheDir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            )
        else { return }

        var files = items.compactMap { url -> (URL, Int, Date)? in
            guard url.pathExtension == "safetensors" else { return nil }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (url, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
        }

        let totalSize = files.reduce(0) { $0 + $1.1 }
        guard totalSize > maxSSDBytes else { return }

        files.sort { $0.2 < $1.2 }
        var freed = 0
        var deletedURLs = Set<URL>()
        let target = totalSize - maxSSDBytes
        for (url, size, _) in files {
            guard freed < target else { break }
            try? fm.removeItem(at: url)
            deletedURLs.insert(url)
            freed += size
        }

        if freed > 0 {
            for entry in entries.values where entry.ssdPath != nil {
                if deletedURLs.contains(entry.ssdPath!) {
                    entry.ssdPath = nil
                }
            }
            print("[KVCacheStore] Pruned \(freed / 1024 / 1024)MB from SSD cache")
        }
    }

    // MARK: - Content-aware prefix cache

    /// Builds the cache key for a given model and content hash.
    /// The hash is always 32 hex chars so `_` is an unambiguous delimiter
    /// that is also safe for use in filenames (session IDs become path components).
    static func prefixKey(modelName: String, hash: String) -> String {
        "prefix_\(modelName)_\(hash)"
    }

    /// Returns a **fresh copy** of the prefix cache for this model + content hash.
    /// Always loads from SSD so each caller gets independent KVCache objects
    /// that won't corrupt the stored prefix when mutated during generation.
    mutating func getPrefixCache(modelName: String, hash: String) -> ([any KVCache]?, [Int]?) {
        let key = Self.prefixKey(modelName: modelName, hash: hash)
        guard let entry = entries[key], entry.modelName == modelName else { return (nil, nil) }
        guard let ssdPath = entry.ssdPath else { return (nil, nil) }
        do {
            let (cache, metadata) = try loadPromptCache(url: ssdPath)
            guard Self.isValidCache(cache) else {
                print("[KVCacheStore] Prefix cache validation failed, removing stale SSD file")
                evictEntry(sessionId: key, saveSSD: false)
                return (nil, nil)
            }
            if entry.tokens == nil, let tokensStr = metadata["tokens"], let data = tokensStr.data(using: .utf8) {
                entry.tokens = try? JSONDecoder().decode([Int].self, from: data)
            }
            return (cache, entry.tokens)
        } catch {
            print("[KVCacheStore] Failed to load prefix cache from SSD: \(error)")
            evictEntry(sessionId: key, saveSSD: false)
            return (nil, nil)
        }
    }

    private static let maxPrefixCachesPerModel = 2

    /// Stores a prefix cache keyed by model + content hash.
    /// Caps prefix entries to `maxPrefixCachesPerModel` per model, evicting
    /// the oldest when the limit is exceeded.
    mutating func putPrefixCache(_ cache: [any KVCache], tokens: [Int]?, modelName: String, hash: String) {
        let key = Self.prefixKey(modelName: modelName, hash: hash)
        putCache(sessionId: key, cache: cache, tokens: tokens, modelName: modelName)
        if let entry = entries[key] {
            entry.contentHash = hash
        }
        saveToDisk(sessionId: key, cache: cache, tokens: tokens, modelName: modelName)
        prunePrefixCaches(modelName: modelName, keepKey: key)
    }

    /// Evicts the oldest prefix caches for `modelName` that exceed the per-model cap.
    private mutating func prunePrefixCaches(modelName: String, keepKey: String) {
        let prefix = "prefix_\(modelName)_"
        let prefixEntries =
            entries
            .filter { $0.key.hasPrefix(prefix) && $0.key != keepKey }
            .sorted { $0.value.lastAccess < $1.value.lastAccess }
        let excess = (prefixEntries.count + 1) - Self.maxPrefixCachesPerModel
        guard excess > 0 else { return }
        for entry in prefixEntries.prefix(excess) {
            evictEntry(sessionId: entry.key, saveSSD: false)
        }
    }

    /// Returns true if a prefix cache exists for this model + content hash.
    func hasPrefixCache(modelName: String, hash: String) -> Bool {
        let key = Self.prefixKey(modelName: modelName, hash: hash)
        return entries[key] != nil
    }

    /// Removes a prefix cache entry (RAM + SSD) for a specific model and content hash.
    mutating func invalidatePrefixCache(modelName: String, hash: String) {
        let key = Self.prefixKey(modelName: modelName, hash: hash)
        evictEntry(sessionId: key, saveSSD: false)
    }

    // MARK: - Helpers

    static func cacheBytes(_ cache: [any KVCache]) -> Int {
        cache.flatMap(\.state).reduce(0) { $0 + $1.nbytes }
    }

    /// Returns true when the cache has populated state and at least one
    /// full-attention (non-ArraysCache) layer has a positive offset.
    /// Hybrid models like Qwen3.5-27B interleave MambaCache layers (offset always
    /// 0) with KVCacheSimple layers (offset > 0 after prefill), so checking
    /// `allSatisfy { offset > 0 }` would incorrectly reject valid hybrid caches.
    private static func isValidCache(_ cache: [any KVCache]) -> Bool {
        guard !cache.isEmpty, cache.allSatisfy({ !$0.state.isEmpty }) else { return false }
        // At least one non-Mamba layer must have a positive offset.
        return cache.contains(where: { !($0 is ArraysCache) && $0.offset > 0 })
    }

    #if DEBUG
        /// Test-only: exposes `isValidCache` for unit tests without making it internal.
        static func _testIsValidCache(_ cache: [any KVCache]) -> Bool {
            isValidCache(cache)
        }

        /// Test-only: injects a cache entry with a specified byte size, bypassing MLX
        /// array creation which requires Metal. The entry has a hot cache reference
        /// (a zero-byte KVCacheSimple) but reports `sizeBytes` for budget accounting.
        mutating func _testPutSized(sessionId: String, modelName: String, sizeBytes: Int) {
            if let existing = entries[sessionId] {
                totalHotBytes -= existing.sizeBytes
                existing.sizeBytes = sizeBytes
                existing.cache = [KVCacheSimple()]
                existing.modelName = modelName
                existing.lastAccess = Date()
                existing.ssdPath = nil
            } else {
                let entry = Entry(cache: [KVCacheSimple()], modelName: modelName, sizeBytes: sizeBytes)
                entries[sessionId] = entry
            }
            totalHotBytes += sizeBytes
            touchLRU(sessionId)
        }
    #endif

    private mutating func touchLRU(_ sessionId: String) {
        lruOrder.removeAll { $0 == sessionId }
        lruOrder.insert(sessionId, at: 0)
    }

    private mutating func evictEntry(sessionId: String, saveSSD: Bool) {
        guard let entry = entries[sessionId] else { return }

        if saveSSD, entry.cache != nil, entry.ssdPath == nil {
            saveToDisk(sessionId: sessionId, cache: entry.cache!, tokens: entry.tokens, modelName: entry.modelName)
        }

        if entry.cache != nil {
            totalHotBytes -= entry.sizeBytes
        }

        // Clean up SSD file
        if let path = entry.ssdPath {
            try? FileManager.default.removeItem(at: path)
        }

        entries.removeValue(forKey: sessionId)
        lruOrder.removeAll { $0 == sessionId }
    }
}
