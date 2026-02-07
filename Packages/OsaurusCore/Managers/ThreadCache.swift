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
