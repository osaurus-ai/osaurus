//
//  ThreadCache.swift
//  osaurus
//
//  Unified cache for message thread rendering.
//  Handles heights and parsed markdown caching.
//

import AppKit
import Foundation

/// Cached result for parsed markdown content
struct ParsedMarkdown {
    let blocks: [MessageBlock]
    let segments: [ContentSegment]
}

private final class ParsedMarkdownWrapper: NSObject {
    let value: ParsedMarkdown
    init(_ value: ParsedMarkdown) { self.value = value }
}

private final class NSImageWrapper: NSObject {
    let image: NSImage
    init(_ image: NSImage) { self.image = image }
}

/// Unified cache for message thread rendering.
///
/// Height cache uses NSCache for automatic memory-pressure eviction.
/// Cache keys are width-aware (e.g. "segmentId-w636") so entries at
/// different widths coexist without invalidation.
final class ThreadCache: @unchecked Sendable {
    static let shared = ThreadCache()

    private let heights: NSCache<NSString, NSNumber> = {
        let c = NSCache<NSString, NSNumber>()
        c.countLimit = 500
        return c
    }()

    private let markdownCache: NSCache<NSString, ParsedMarkdownWrapper> = {
        let c = NSCache<NSString, ParsedMarkdownWrapper>()
        c.countLimit = 200
        return c
    }()

    // MARK: - Heights

    func height(for key: String) -> CGFloat? {
        guard let number = heights.object(forKey: key as NSString) else { return nil }
        return CGFloat(number.doubleValue)
    }

    func setHeight(_ height: CGFloat, for key: String) {
        heights.setObject(NSNumber(value: Double(height)), forKey: key as NSString)
    }

    // MARK: - Markdown

    /// Lightweight cache key that avoids bridging the full text to NSString.
    /// Uses byte length + a short prefix/suffix fingerprint for uniqueness.
    private static func markdownKey(for text: String) -> NSString {
        let len = text.utf8.count
        let prefix = String(text.prefix(64))
        let suffix = len > 128 ? String(text.suffix(64)) : ""
        return "\(len)|\(prefix)|\(suffix)" as NSString
    }

    func markdown(for text: String) -> ParsedMarkdown? {
        markdownCache.object(forKey: Self.markdownKey(for: text))?.value
    }

    func setMarkdown(blocks: [MessageBlock], segments: [ContentSegment], for text: String) {
        let parsed = ParsedMarkdown(blocks: blocks, segments: segments)
        markdownCache.setObject(ParsedMarkdownWrapper(parsed), forKey: Self.markdownKey(for: text))
    }

    // MARK: - Images

    private let imageCache: NSCache<NSString, NSImageWrapper> = {
        let c = NSCache<NSString, NSImageWrapper>()
        c.countLimit = 40
        return c
    }()

    /// Derive a short, stable cache key from a URL string without hashing the entire
    /// multi-MB base64 payload. For data URIs we use the MIME type prefix + data length;
    /// for other URLs the string itself is short enough to use directly.
    static func imageCacheKey(for urlString: String) -> NSString {
        if urlString.hasPrefix("data:image/") {
            let len = urlString.utf8.count
            let prefix = String(urlString.prefix(40))
            let suffix = String(urlString.suffix(20))
            return "\(prefix)|\(len)|\(suffix)" as NSString
        }
        return urlString as NSString
    }

    func image(for urlString: String) -> NSImage? {
        let key = Self.imageCacheKey(for: urlString)
        return imageCache.object(forKey: key)?.image
    }

    func setImage(_ image: NSImage, for urlString: String) {
        let key = Self.imageCacheKey(for: urlString)
        imageCache.setObject(NSImageWrapper(image), forKey: key)
    }

    // MARK: - Clear

    func clear() {
        heights.removeAllObjects()
        markdownCache.removeAllObjects()
        // Intentionally keep imageCache across session loads — decoded images
        // are expensive to recreate and the NSCache evicts under memory pressure.
    }
}
