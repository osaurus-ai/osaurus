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

    static func image(
        _ name: String,
        accessibilityDescription: String? = nil
    ) -> NSImage? {
        let key = "\(name)\u{1}\(accessibilityDescription ?? "")"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard
            let image = NSImage(
                systemSymbolName: name,
                accessibilityDescription: accessibilityDescription
            )
        else {
            return nil
        }
        lock.lock()
        cache[key] = image
        lock.unlock()
        return image
    }
}
