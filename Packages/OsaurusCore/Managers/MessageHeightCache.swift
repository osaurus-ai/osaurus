//
//  MessageHeightCache.swift
//  osaurus
//
//  Caches measured heights for message turns to prevent LazyVStack
//  height estimation issues during scrolling.
//

import Foundation

/// Caches measured heights for message views keyed by block ID.
/// This prevents LazyVStack from using incorrect height estimates
/// when views are recycled, which causes scroll position issues.
final class MessageHeightCache: @unchecked Sendable {
    static let shared = MessageHeightCache()

    private var cache: [String: CGFloat] = [:]
    private let lock = NSLock()

    /// Maximum number of cached heights before eviction
    private let maxEntries = 2000  // Increased for block-level caching

    private init() {}

    /// Get cached height for a block ID
    func height(for id: String) -> CGFloat? {
        lock.lock()
        defer { lock.unlock() }
        return cache[id]
    }

    /// Set cached height for a block ID
    func setHeight(_ height: CGFloat, for id: String) {
        lock.lock()
        defer { lock.unlock() }

        // Simple eviction: if we're at capacity, remove oldest entries
        // This is a simple approach; for production, LRU would be better
        if cache.count >= maxEntries {
            // Remove roughly 20% of entries to avoid frequent evictions
            let toRemove = maxEntries / 5
            let keysToRemove = Array(cache.keys.prefix(toRemove))
            for key in keysToRemove {
                cache.removeValue(forKey: key)
            }
        }

        cache[id] = height
    }

    /// Invalidate cached height for a block ID
    func invalidate(id: String) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: id)
    }

    /// Invalidate all blocks for a given turn ID (prefix match)
    func invalidateTurn(_ turnId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        let prefix = turnId.uuidString
        let keysToRemove = cache.keys.filter { $0.contains(prefix) }
        for key in keysToRemove {
            cache.removeValue(forKey: key)
        }
    }

    /// Clear all cached heights
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }
}
