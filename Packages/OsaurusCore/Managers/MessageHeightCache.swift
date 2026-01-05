//
//  MessageHeightCache.swift
//  osaurus
//
//  Caches measured heights for message turns to prevent LazyVStack
//  height estimation issues during scrolling.
//

import Foundation

/// Caches measured heights for message views keyed by turn ID.
/// This prevents LazyVStack from using incorrect height estimates
/// when views are recycled, which causes scroll position issues.
final class MessageHeightCache: @unchecked Sendable {
    static let shared = MessageHeightCache()

    private var cache: [UUID: CGFloat] = [:]
    private let lock = NSLock()

    /// Maximum number of cached heights before eviction
    private let maxEntries = 1000

    private init() {}

    /// Get cached height for a turn ID
    func height(for turnId: UUID) -> CGFloat? {
        lock.lock()
        defer { lock.unlock() }
        return cache[turnId]
    }

    /// Set cached height for a turn ID
    func setHeight(_ height: CGFloat, for turnId: UUID) {
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

        cache[turnId] = height
    }

    /// Invalidate cached height for a turn ID (e.g., when content changes)
    func invalidate(turnId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: turnId)
    }

    /// Clear all cached heights
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }
}
