//
//  SymbolImageCache.swift
//  osaurus
//
//  Shared memo for SF Symbol images used in the native chat cell views.
//

import AppKit

/// `NSImage(systemSymbolName:)` resolves a vector glyph through CUICatalog, a
/// lookup that runs on the main thread during table-cell construction (e.g.
/// `NativeThinkingView.buildViews`, the assistant-actions header) and has shown
/// up as app hangs while scrolling or streaming a conversation. The base symbol
/// image for a given name is immutable — callers tint via the hosting view and
/// derive sized copies with `withSymbolConfiguration` — so it is safe to resolve
/// once and serve the memo thereafter.
enum SymbolImageCache {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: NSImage] = [:]

    /// `pointSize`/`weight` bake a symbol configuration into the memoized
    /// image, so glyphs that swap between symbols with different aspect
    /// ratios (chevron.right ↔ chevron.down) share font metrics instead of
    /// being force-fit into the image view's frame.
    static func image(
        _ name: String,
        accessibilityDescription: String? = nil,
        pointSize: CGFloat? = nil,
        weight: NSFont.Weight = .regular
    ) -> NSImage? {
        let key = "\(name)\u{1}\(accessibilityDescription ?? "")\u{1}\(pointSize ?? -1)\u{1}\(weight.rawValue)"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard
            var image = NSImage(
                systemSymbolName: name,
                accessibilityDescription: accessibilityDescription
            )
        else {
            return nil
        }
        if let pointSize,
            let configured = image.withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
        {
            image = configured
        }
        lock.lock()
        // The distinct-symbol working set is small; the cap is a safety net
        // (reset-on-overflow, not LRU — entries are cheap to re-resolve).
        if cache.count >= 512 { cache.removeAll() }
        cache[key] = image
        lock.unlock()
        return image
    }

    /// Drop all memoized symbols (memory-pressure response). Entries are
    /// re-resolved lazily on next use.
    static func clear() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}
