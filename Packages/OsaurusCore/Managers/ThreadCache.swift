//
//  ThreadCache.swift
//  osaurus
//
//  Unified cache for message thread rendering.
//  Handles heights and parsed markdown caching.
//

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

/// Unified cache for message thread rendering.
///
/// Height cache uses NSCache for automatic memory-pressure eviction.
/// Width invalidation is handled by the view layer calling `invalidateHeights()`
/// when the container width changes significantly.
final class ThreadCache: @unchecked Sendable {
    static let shared = ThreadCache()

    private let heights = NSCache<NSString, NSNumber>()
    private let markdownCache = NSCache<NSString, ParsedMarkdownWrapper>()

    // MARK: - Heights

    func height(for key: String) -> CGFloat? {
        guard let number = heights.object(forKey: key as NSString) else { return nil }
        return CGFloat(number.doubleValue)
    }

    func setHeight(_ height: CGFloat, for key: String) {
        heights.setObject(NSNumber(value: Double(height)), forKey: key as NSString)
    }

    /// Invalidate all cached heights (e.g. on significant width change).
    func invalidateHeights() {
        heights.removeAllObjects()
    }

    // MARK: - Markdown

    func markdown(for text: String) -> ParsedMarkdown? {
        markdownCache.object(forKey: text as NSString)?.value
    }

    func setMarkdown(blocks: [MessageBlock], segments: [ContentSegment], for text: String) {
        let parsed = ParsedMarkdown(blocks: blocks, segments: segments)
        markdownCache.setObject(ParsedMarkdownWrapper(parsed), forKey: text as NSString)
    }

    // MARK: - Clear

    func clear() {
        heights.removeAllObjects()
        markdownCache.removeAllObjects()
    }
}
