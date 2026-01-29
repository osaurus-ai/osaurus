//
//  ThreadCache.swift
//  osaurus
//
//  Unified cache for message thread rendering.
//  Handles heights, parsed markdown, and width-aware invalidation.
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
/// Handles heights, parsed markdown, and width-aware invalidation.
final class ThreadCache: @unchecked Sendable {
    static let shared = ThreadCache()

    private let lock = NSLock()
    private var currentWidth: CGFloat = 0
    private let widthThreshold: CGFloat = 20
    private var heights: [String: CGFloat] = [:]
    private let maxHeights = 500
    private let markdownCache = NSCache<NSString, ParsedMarkdownWrapper>()

    // MARK: - Width

    /// Update layout width - invalidates height cache on significant change
    func setWidth(_ width: CGFloat) {
        lock.lock()
        defer { lock.unlock() }
        if currentWidth > 0 && abs(width - currentWidth) > widthThreshold {
            heights.removeAll()
        }
        currentWidth = width
    }

    // MARK: - Heights

    func height(for key: String) -> CGFloat? {
        lock.lock()
        defer { lock.unlock() }
        return heights[key]
    }

    func setHeight(_ height: CGFloat, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        if heights.count >= maxHeights {
            let removeCount = maxHeights / 5
            for key in heights.keys.prefix(removeCount) {
                heights.removeValue(forKey: key)
            }
        }
        heights[key] = height
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
        lock.lock()
        defer { lock.unlock() }
        heights.removeAll()
        markdownCache.removeAllObjects()
        currentWidth = 0
    }
}
