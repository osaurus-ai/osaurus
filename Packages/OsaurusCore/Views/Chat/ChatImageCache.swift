//
//  ChatImageCache.swift
//  osaurus
//
//  Async image decode + NSCache for chat attachment thumbnails.
//  Decoding is done off the main thread to avoid blocking the table during
//  fast streaming or scroll.
//

import AppKit

// MARK: - ChatImageCache

final class ChatImageCache: @unchecked Sendable {

    static let shared = ChatImageCache()

    private let cache = NSCache<NSString, NSImage>()
    private let state = CacheState()

    private init() {
        cache.countLimit = 200
        // ~100 MB
        cache.totalCostLimit = 100 * 1024 * 1024
    }

    // MARK: - Synchronous Lookup

    func cachedImage(for id: String) -> NSImage? {
        cache.object(forKey: id as NSString)
    }

    // MARK: - Async Decode

    @discardableResult
    func decode(_ data: Data, id: String) async -> NSImage? {
        // fast path — already cached
        if let hit = cache.object(forKey: id as NSString) { return hit }

        // coalesce concurrent requests for the same id
        if let existing = await state.inFlight(for: id) {
            return await existing.value
        }

        let task = Task<NSImage?, Never>.detached(priority: .userInitiated) {
            guard let img = NSImage(data: data) else { return nil }
            _ = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
            return img
        }
        await state.setInFlight(task, for: id)

        let result = await task.value

        await state.removeInFlight(for: id)
        if let img = result {
            cache.setObject(img, forKey: id as NSString, cost: data.count)
        }
        return result
    }

    // MARK: - Prefetch

    func prefetch(_ attachments: [(data: Data, id: String)]) {
        for a in attachments {
            Task { await decode(a.data, id: a.id) }
        }
    }

    /// Drop every decoded thumbnail (memory-pressure response). Thumbnails
    /// are re-decoded lazily from attachment data on next display.
    func removeAll() {
        cache.removeAllObjects()
    }
}

// MARK: - Actor-based in-flight task registry

private actor CacheState {
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    func inFlight(for id: String) -> Task<NSImage?, Never>? { inFlight[id] }
    func setInFlight(_ task: Task<NSImage?, Never>, for id: String) { inFlight[id] = task }
    func removeInFlight(for id: String) { inFlight.removeValue(forKey: id) }
}
