//
//  ThemePreviewImageCache.swift
//  osaurus
//
//  Off-main base64 -> NSImage decode and NSCache for theme preview cards.
//  ThemePreviewCard previously decoded `theme.background.imageData` inside
//  its body, so every scroll-induced re-evaluation re-ran the decode for
//  every visible image-backed theme. This cache keys by the theme id so a
//  theme is only decoded once per session (or until the cache evicts it),
//  and the work happens on a detached task instead of the main actor.
//

import AppKit

struct ThemePreviewCacheHealth: Equatable, Sendable {
    let cachedEntryCount: Int
    let cachedCostBytes: Int
    let countLimit: Int
    let totalCostLimit: Int
    let inFlightDecodeCount: Int
    let failedDecodeCount: Int

    static let empty = ThemePreviewCacheHealth(
        cachedEntryCount: 0,
        cachedCostBytes: 0,
        countLimit: 0,
        totalCostLimit: 0,
        inFlightDecodeCount: 0,
        failedDecodeCount: 0
    )

    var isHealthy: Bool {
        failedDecodeCount == 0 && cachedEntryCount <= countLimit
    }
}

final class ThemePreviewImageCache: @unchecked Sendable {

    static let shared = ThemePreviewImageCache()

    private let cache = NSCache<NSString, NSImage>()
    private let state = CacheState()

    init(countLimit: Int = 64, totalCostLimit: Int = 50 * 1024 * 1024) {
        cache.countLimit = countLimit
        // ~50 MB cap. Themes with image backgrounds typically encode
        // ~200KB-2MB JPEG/PNG payloads; this leaves room for a generous
        // gallery without keeping every theme alive forever.
        cache.totalCostLimit = totalCostLimit
    }

    // MARK: - Synchronous lookup

    func cachedImage(for id: String) -> NSImage? {
        cache.object(forKey: id as NSString)
    }

    func healthSnapshot() async -> ThemePreviewCacheHealth {
        await state.snapshot(
            countLimit: cache.countLimit,
            totalCostLimit: cache.totalCostLimit
        )
    }

    func removeAll() async {
        cache.removeAllObjects()
        await state.removeAll()
    }

    // MARK: - Async decode

    /// Returns the decoded preview image for `theme`, decoding off the
    /// main thread when needed. Returns `nil` for non-image backgrounds
    /// or when the encoded payload fails to decode.
    func image(for theme: CustomTheme) async -> NSImage? {
        guard theme.background.type == .image,
            let payload = theme.background.imageData,
            !payload.isEmpty
        else { return nil }

        let id = theme.metadata.id.uuidString
        if let hit = cache.object(forKey: id as NSString) { return hit }

        if let existing = await state.inFlight(for: id) {
            return await existing.value
        }

        let task = Task<NSImage?, Never>.detached(priority: .userInitiated) {
            guard let data = Data(base64Encoded: payload),
                let img = NSImage(data: data)
            else { return nil }
            // Force decode now so the first paint doesn't stall on the
            // main thread when SwiftUI asks for a CGImage during layout.
            _ = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
            return img
        }
        await state.setInFlight(task, for: id)

        let result = await task.value
        await state.removeInFlight(for: id)

        if let img = result {
            // Cost roughly tracks the encoded payload size, which is a
            // reasonable proxy for the decoded bitmap's footprint here.
            let cost = payload.utf8.count
            cache.setObject(img, forKey: id as NSString, cost: cost)
            await state.recordCached(id: id, cost: cost)
        } else {
            await state.recordFailure()
        }
        return result
    }
}

// MARK: - Actor-based in-flight task registry

private actor CacheState {
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private var cachedCosts: [String: Int] = [:]
    private var failedDecodeCount = 0

    func inFlight(for id: String) -> Task<NSImage?, Never>? { inFlight[id] }
    func setInFlight(_ task: Task<NSImage?, Never>, for id: String) { inFlight[id] = task }
    func removeInFlight(for id: String) { inFlight.removeValue(forKey: id) }
    func recordCached(id: String, cost: Int) { cachedCosts[id] = cost }
    func recordFailure() { failedDecodeCount += 1 }

    func removeAll() {
        inFlight.removeAll()
        cachedCosts.removeAll()
        failedDecodeCount = 0
    }

    func snapshot(countLimit: Int, totalCostLimit: Int) -> ThemePreviewCacheHealth {
        ThemePreviewCacheHealth(
            cachedEntryCount: cachedCosts.count,
            cachedCostBytes: cachedCosts.values.reduce(0, +),
            countLimit: countLimit,
            totalCostLimit: totalCostLimit,
            inFlightDecodeCount: inFlight.count,
            failedDecodeCount: failedDecodeCount
        )
    }
}
