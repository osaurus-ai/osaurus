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

    /// A 90°-clockwise-rotated copy of `image(name, ...)`, memoized. Used for
    /// the expand chevron: chevron.right and chevron.down are distinct glyphs
    /// with different proportions (9×11 vs 11×8 at 10pt), so swapping symbols
    /// visibly changes size — rotating the right chevron keeps the exact same
    /// glyph mass. Baked into the bitmap (unlike a layer transform) so
    /// table-cell relayout can't reset it.
    static func rotatedDownChevron(pointSize: CGFloat, weight: NSFont.Weight) -> NSImage? {
        let key = "chevron.right\u{1}rot90\u{1}\(pointSize)\u{1}\(weight.rawValue)"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let base = image("chevron.right", pointSize: pointSize, weight: weight) else {
            return nil
        }
        let size = NSSize(width: base.size.height, height: base.size.width)
        // Drawing-handler image: re-renders at the destination context's
        // scale, so the rotated glyph stays crisp on retina displays.
        let rotated = NSImage(size: size, flipped: false) { _ in
            let transform = NSAffineTransform()
            transform.translateX(by: size.width / 2, yBy: size.height / 2)
            transform.rotate(byDegrees: -90)
            transform.concat()
            base.draw(
                at: NSPoint(x: -base.size.width / 2, y: -base.size.height / 2),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
        rotated.isTemplate = base.isTemplate

        lock.lock()
        if cache.count >= 512 { cache.removeAll() }
        cache[key] = rotated
        lock.unlock()
        return rotated
    }

    /// Drop all memoized symbols (memory-pressure response). Entries are
    /// re-resolved lazily on next use.
    static func clear() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}
