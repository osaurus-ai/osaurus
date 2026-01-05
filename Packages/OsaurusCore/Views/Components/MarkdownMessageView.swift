//
//  MarkdownMessageView.swift
//  osaurus
//
//  Renders markdown text with proper typography, code blocks, images, and more
//  Optimized for streaming responses with stable block identity
//  Uses NSTextView for web-like text selection across blocks
//

import AppKit
import SwiftUI

struct MarkdownMessageView: View {
    let text: String
    let baseWidth: CGFloat

    var body: some View {
        // Use inner view with memoized parsing to avoid re-parsing on every render
        MemoizedMarkdownView(text: text, baseWidth: baseWidth)
    }
}

// MARK: - Memoized Inner View

/// Inner view that caches parsed segments and only recomputes when text changes
private struct MemoizedMarkdownView: View {
    let text: String
    let baseWidth: CGFloat

    @Environment(\.theme) private var theme

    // Memoized segments - only recomputed when text changes via .onChange
    @State private var cachedSegments: [ContentSegment] = []
    @State private var lastParsedText: String = ""
    // Cache for incremental parsing
    @State private var cachedBlocks: [MessageBlock] = []
    @State private var lastStableIndex: Int = 0  // Index of last "stable" block (not affected by streaming)
    // Track current parsing task to allow cancellation
    @State private var currentParseTask: Task<Void, Never>?
    // Track last parse request time for adaptive debouncing
    @State private var lastParseRequestTime: Date = .distantPast
    // Track the character position where stable blocks end (for incremental parsing)
    @State private var stableTextLength: Int = 0

    // Debounce interval in milliseconds - scales with content size
    private var debounceIntervalMs: UInt64 {
        let charCount = text.count
        switch charCount {
        case 0 ..< 1_000:
            return 30  // Fast updates for small content
        case 1_000 ..< 3_000:
            return 50
        case 3_000 ..< 8_000:
            return 80
        case 8_000 ..< 20_000:
            return 120
        default:
            return 200  // Slower updates for large content
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(cachedSegments.enumerated()), id: \.element.id) { index, segment in
                segmentView(for: segment, isFirst: index == 0)
            }
        }
        .onAppear {
            // Initial parse - no debounce needed
            if lastParsedText != text {
                scheduleBackgroundParse(for: text, oldText: "", debounce: false)
            }
        }
        .onChange(of: text) { oldText, newText in
            // Only reparse when text actually changes
            if lastParsedText != newText {
                scheduleBackgroundParse(for: newText, oldText: oldText, debounce: true)
            }
        }
    }

    /// Schedule parsing on a background thread to avoid blocking the main thread
    /// - Parameters:
    ///   - textToParse: The text to parse
    ///   - oldText: The previous text (for detecting append-only changes)
    ///   - debounce: Whether to apply debouncing delay
    private func scheduleBackgroundParse(for textToParse: String, oldText: String, debounce: Bool) {
        // Cancel any in-flight parsing task
        currentParseTask?.cancel()

        // Capture state for the background task
        let textSnapshot = textToParse
        let oldTextSnapshot = oldText
        let debounceMs = debounce ? debounceIntervalMs : 0
        lastParseRequestTime = Date()

        // Detect if this is an append-only change (streaming)
        let isAppendOnly = !oldTextSnapshot.isEmpty && textSnapshot.hasPrefix(oldTextSnapshot)

        // Capture stable blocks for incremental parsing
        let stableBlocksSnapshot =
            isAppendOnly && lastStableIndex > 0
            ? Array(cachedBlocks.prefix(max(0, lastStableIndex - 1)))
            : []
        let stableTextLengthSnapshot = isAppendOnly ? stableTextLength : 0

        currentParseTask = Task {
            // Apply debounce delay if requested
            if debounceMs > 0 {
                do {
                    try await Task.sleep(nanoseconds: debounceMs * 1_000_000)
                } catch {
                    // Task was cancelled during sleep - exit early
                    return
                }
            }

            // Check if task was cancelled
            if Task.isCancelled { return }

            // Run parsing on a background thread
            let (newBlocks, newSegments, newStableLength) = await Task.detached(priority: .userInitiated) {
                let blocks: [MessageBlock]
                var computedStableLength = 0

                if isAppendOnly && !stableBlocksSnapshot.isEmpty && stableTextLengthSnapshot > 0 {
                    // Incremental parsing: only parse from the stable position forward
                    // Find a safe position to start parsing (after stable blocks)
                    let startPosition = stableTextLengthSnapshot
                    let textToParse =
                        startPosition < textSnapshot.count
                        ? String(textSnapshot.dropFirst(startPosition))
                        : ""

                    // Parse only the new portion
                    let newPortionBlocks = parseBlocks(textToParse)

                    // Re-index new blocks to continue from stable block count
                    let reindexedBlocks = newPortionBlocks.enumerated().map { offset, block in
                        MessageBlock(index: stableBlocksSnapshot.count + offset, kind: block.kind)
                    }

                    // Combine stable blocks with newly parsed blocks
                    blocks = stableBlocksSnapshot + reindexedBlocks

                    // Calculate new stable length - everything except the last block
                    if blocks.count > 1 {
                        computedStableLength = computeStableTextLength(blocks: blocks, fullText: textSnapshot)
                    }
                } else {
                    // Full parse
                    blocks = parseBlocks(textSnapshot)

                    // Calculate stable length - everything except the last block
                    if blocks.count > 1 {
                        computedStableLength = computeStableTextLength(blocks: blocks, fullText: textSnapshot)
                    }
                }

                let segments = groupBlocksIntoSegments(blocks)
                return (blocks, segments, computedStableLength)
            }.value

            // Check if task was cancelled while parsing
            if Task.isCancelled { return }

            // Update UI state on main thread
            await MainActor.run {
                // Double-check we're still processing the same text
                // (prevents race conditions if text changed while parsing)
                guard textSnapshot == text else { return }

                cachedBlocks = newBlocks
                cachedSegments = newSegments
                lastParsedText = textSnapshot
                lastStableIndex = max(0, newBlocks.count - 1)
                stableTextLength = newStableLength
            }
        }
    }

    @ViewBuilder
    private func segmentView(for segment: ContentSegment, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Add spacing before non-first segments
            if !isFirst {
                Spacer()
                    .frame(height: segment.spacingBefore)
            }

            switch segment.kind {
            case .textGroup(let textBlocks):
                SelectableTextView(
                    blocks: textBlocks,
                    baseWidth: baseWidth,
                    theme: theme
                )
                // Let the NSTextView self-size via intrinsicContentSize instead of doing a separate
                // height calculation pass (which duplicates layout work and can freeze the UI during streaming).
                .frame(width: baseWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            case .codeBlock(let code, let lang):
                CodeBlockView(code: code, language: lang, baseWidth: baseWidth)

            case .image(let url, let altText):
                MarkdownImageView(urlString: url, altText: altText, baseWidth: baseWidth)

            case .horizontalRule:
                HorizontalRuleView()

            case .table(let headers, let rows):
                TableView(headers: headers, rows: rows, baseWidth: baseWidth)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Content Segment

/// Represents a segment of content - either a group of selectable text blocks or a special element
private struct ContentSegment: Identifiable {
    enum Kind {
        case textGroup([SelectableTextBlock])
        case codeBlock(code: String, language: String?)
        case image(url: String, altText: String)
        case horizontalRule
        case table(headers: [String], rows: [[String]])
    }

    let id: String
    let kind: Kind
    let spacingBefore: CGFloat

    init(id: String, kind: Kind, spacingBefore: CGFloat = 0) {
        self.id = id
        self.kind = kind
        self.spacingBefore = spacingBefore
    }
}

// MARK: - Block Grouping

/// Groups consecutive text blocks into segments for efficient rendering with NSTextView
private func groupBlocksIntoSegments(_ blocks: [MessageBlock]) -> [ContentSegment] {
    var segments: [ContentSegment] = []
    var currentTextBlocks: [SelectableTextBlock] = []
    var segmentIndex = 0
    var previousBlockKind: MessageBlock.Kind? = nil

    func flushTextGroup() {
        if !currentTextBlocks.isEmpty {
            let spacing = segments.isEmpty ? 0 : spacingBeforeTextGroup(previousNonTextKind: previousBlockKind)
            segments.append(
                ContentSegment(
                    id: "text-\(segmentIndex)",
                    kind: .textGroup(currentTextBlocks),
                    spacingBefore: spacing
                )
            )
            segmentIndex += 1
            currentTextBlocks.removeAll()
        }
    }

    for block in blocks {
        switch block.kind {
        case .paragraph(let text):
            currentTextBlocks.append(.paragraph(text))

        case .heading(let level, let text):
            currentTextBlocks.append(.heading(level: level, text: text))

        case .blockquote(let content):
            currentTextBlocks.append(.blockquote(content))

        case .list(let items, let ordered):
            for (index, item) in items.enumerated() {
                currentTextBlocks.append(.listItem(text: item, index: index, ordered: ordered))
            }

        case .code(let code, let lang):
            flushTextGroup()
            let spacing = spacingForSpecialBlock(.code(code, lang), previousKind: previousBlockKind)
            segments.append(
                ContentSegment(
                    id: "code-\(segmentIndex)",
                    kind: .codeBlock(code: code, language: lang),
                    spacingBefore: spacing
                )
            )
            segmentIndex += 1
            previousBlockKind = block.kind

        case .image(let url, let altText):
            flushTextGroup()
            let spacing = spacingForSpecialBlock(.image(url: url, altText: altText), previousKind: previousBlockKind)
            segments.append(
                ContentSegment(
                    id: "image-\(segmentIndex)",
                    kind: .image(url: url, altText: altText),
                    spacingBefore: spacing
                )
            )
            segmentIndex += 1
            previousBlockKind = block.kind

        case .horizontalRule:
            flushTextGroup()
            let spacing = spacingForSpecialBlock(.horizontalRule, previousKind: previousBlockKind)
            segments.append(
                ContentSegment(
                    id: "hr-\(segmentIndex)",
                    kind: .horizontalRule,
                    spacingBefore: spacing
                )
            )
            segmentIndex += 1
            previousBlockKind = block.kind

        case .table(let headers, let rows):
            flushTextGroup()
            let spacing = spacingForSpecialBlock(.table(headers: headers, rows: rows), previousKind: previousBlockKind)
            segments.append(
                ContentSegment(
                    id: "table-\(segmentIndex)",
                    kind: .table(headers: headers, rows: rows),
                    spacingBefore: spacing
                )
            )
            segmentIndex += 1
            previousBlockKind = block.kind
        }

        // Track last text block kind for spacing
        if case .paragraph = block.kind {
            previousBlockKind = block.kind
        } else if case .heading = block.kind {
            previousBlockKind = block.kind
        } else if case .blockquote = block.kind {
            previousBlockKind = block.kind
        } else if case .list = block.kind {
            previousBlockKind = block.kind
        }
    }

    flushTextGroup()

    return segments
}

/// Calculate spacing before a special block (code, image, hr, table)
private func spacingForSpecialBlock(_ kind: MessageBlock.Kind, previousKind: MessageBlock.Kind?) -> CGFloat {
    guard previousKind != nil else { return 0 }

    switch kind {
    case .code:
        return 14
    case .image:
        return 16
    case .horizontalRule:
        return 8
    case .table:
        return 14
    default:
        return 12
    }
}

/// Calculate spacing before a text group that follows a special block
private func spacingBeforeTextGroup(previousNonTextKind: MessageBlock.Kind?) -> CGFloat {
    guard let prev = previousNonTextKind else { return 0 }

    switch prev {
    case .code:
        return 14
    case .image:
        return 16
    case .horizontalRule:
        return 8
    case .table:
        return 14
    default:
        return 12
    }
}

// MARK: - Message Block

private struct MessageBlock: Identifiable {
    enum Kind: Equatable {
        case paragraph(String)
        case code(String, String?)
        case image(url: String, altText: String)
        case heading(level: Int, text: String)
        case blockquote(String)
        case horizontalRule
        case list(items: [String], ordered: Bool)
        case table(headers: [String], rows: [[String]])

        /// Generate a stable hash for the block kind
        var contentHash: Int {
            var hasher = Hasher()
            switch self {
            case .paragraph(let text):
                hasher.combine("p")
                hasher.combine(text)
            case .code(let code, let lang):
                hasher.combine("c")
                hasher.combine(code)
                hasher.combine(lang)
            case .image(let url, let alt):
                hasher.combine("i")
                hasher.combine(url)
                hasher.combine(alt)
            case .heading(let level, let text):
                hasher.combine("h")
                hasher.combine(level)
                hasher.combine(text)
            case .blockquote(let content):
                hasher.combine("q")
                hasher.combine(content)
            case .horizontalRule:
                hasher.combine("hr")
            case .list(let items, let ordered):
                hasher.combine("l")
                hasher.combine(items)
                hasher.combine(ordered)
            case .table(let headers, let rows):
                hasher.combine("t")
                hasher.combine(headers)
                hasher.combine(rows)
            }
            return hasher.finalize()
        }
    }

    let index: Int
    let kind: Kind

    /// Stable identifier combining index and content for efficient diffing
    var stableId: String {
        "\(index)-\(kind.contentHash)"
    }

    var id: String { stableId }
}

// MARK: - Parser

/// Optimized line iterator that avoids creating intermediate arrays
private struct LineIterator: IteratorProtocol {
    private let string: String
    private var currentIndex: String.Index
    private let endIndex: String.Index

    init(_ string: String) {
        self.string = string
        self.currentIndex = string.startIndex
        self.endIndex = string.endIndex
    }

    mutating func next() -> Substring? {
        guard currentIndex < endIndex else { return nil }

        // Find the next newline or end of string
        let lineStart = currentIndex
        while currentIndex < endIndex && string[currentIndex] != "\n" {
            currentIndex = string.index(after: currentIndex)
        }

        let lineEnd = currentIndex

        // Skip past the newline for next iteration
        if currentIndex < endIndex {
            currentIndex = string.index(after: currentIndex)
        }

        return string[lineStart ..< lineEnd]
    }
}

private func parseBlocks(_ input: String) -> [MessageBlock] {
    var blocks: [MessageBlock] = []
    var currentParagraphLines: [Substring] = []
    var currentBlockquoteLines: [Substring] = []
    var currentListItems: [String] = []
    var isOrderedList = false
    var blockIndex = 0

    // Normalize line endings once
    let normalizedInput = input.contains("\r\n") ? input.replacingOccurrences(of: "\r\n", with: "\n") : input

    // Collect lines into array for index-based access (needed for code blocks)
    // Use lazy evaluation for better memory efficiency
    var lines: [Substring] = []
    var iter = LineIterator(normalizedInput)
    while let line = iter.next() {
        lines.append(line)
    }

    @inline(__always)
    func flushParagraph() {
        if !currentParagraphLines.isEmpty {
            let paragraphText = currentParagraphLines.map { String($0) }.joined(separator: "\n")
            // Check if paragraph contains standalone image
            if let imageKind = extractStandaloneImageKind(from: paragraphText) {
                blocks.append(MessageBlock(index: blockIndex, kind: imageKind))
            } else {
                blocks.append(MessageBlock(index: blockIndex, kind: .paragraph(paragraphText)))
            }
            blockIndex += 1
            currentParagraphLines.removeAll(keepingCapacity: true)
        }
    }

    @inline(__always)
    func flushBlockquote() {
        if !currentBlockquoteLines.isEmpty {
            let quoteText = currentBlockquoteLines.map { String($0) }.joined(separator: "\n")
            blocks.append(
                MessageBlock(index: blockIndex, kind: .blockquote(quoteText))
            )
            blockIndex += 1
            currentBlockquoteLines.removeAll(keepingCapacity: true)
        }
    }

    @inline(__always)
    func flushList() {
        if !currentListItems.isEmpty {
            blocks.append(MessageBlock(index: blockIndex, kind: .list(items: currentListItems, ordered: isOrderedList)))
            blockIndex += 1
            currentListItems.removeAll(keepingCapacity: true)
        }
    }

    /// Check if the next non-blank line is a list item of the same type
    func nextNonBlankIsListItem(from startIndex: Int, ordered: Bool) -> Bool {
        var j = startIndex
        while j < lines.count {
            let nextTrimmed = lines[j].trimmingWhitespace()
            if !nextTrimmed.isEmpty {
                if ordered {
                    return parseOrderedListItemFast(nextTrimmed) != nil
                } else {
                    return parseUnorderedListItemFast(nextTrimmed) != nil
                }
            }
            j += 1
        }
        return false
    }

    var i = 0
    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingWhitespace()

        // Fenced code block - check prefix efficiently
        if trimmed.hasPrefix("```") {
            flushParagraph()
            flushBlockquote()
            flushList()

            let langPart = trimmed.dropFirst(3)
            let lang = langPart.trimmingWhitespace()
            let langStr = lang.isEmpty ? nil : String(lang)

            i += 1
            var codeLines: [Substring] = []
            while i < lines.count {
                let l = lines[i]
                if l.trimmingWhitespace().hasPrefix("```") { break }
                codeLines.append(l)
                i += 1
            }
            let codeText = codeLines.map { String($0) }.joined(separator: "\n")
            blocks.append(MessageBlock(index: blockIndex, kind: .code(codeText, langStr)))
            blockIndex += 1
            if i < lines.count { i += 1 }
            continue
        }

        // Table detection: | header | header | followed by | --- | --- |
        if trimmed.hasPrefix("|"), i + 1 < lines.count {
            let nextLine = lines[i + 1].trimmingWhitespace()
            if isTableSeparatorLine(nextLine) {
                flushParagraph()
                flushBlockquote()
                flushList()

                // Parse headers from the current line
                let headers = parseTableRow(trimmed)

                // Skip the separator line
                i += 2

                // Parse data rows
                var rows: [[String]] = []
                while i < lines.count {
                    let rowLine = lines[i].trimmingWhitespace()
                    if rowLine.hasPrefix("|") {
                        rows.append(parseTableRow(rowLine))
                        i += 1
                    } else {
                        break
                    }
                }

                blocks.append(MessageBlock(index: blockIndex, kind: .table(headers: headers, rows: rows)))
                blockIndex += 1
                continue
            }
        }

        // Horizontal rule (---, ***, ___)
        if isHorizontalRuleFast(trimmed) {
            flushParagraph()
            flushBlockquote()
            flushList()
            blocks.append(MessageBlock(index: blockIndex, kind: .horizontalRule))
            blockIndex += 1
            i += 1
            continue
        }

        // Heading (# to ######)
        if let headingMatch = parseHeadingFast(trimmed) {
            flushParagraph()
            flushBlockquote()
            flushList()
            blocks.append(
                MessageBlock(index: blockIndex, kind: .heading(level: headingMatch.level, text: headingMatch.text))
            )
            blockIndex += 1
            i += 1
            continue
        }

        // Blockquote (> ...)
        if trimmed.hasPrefix(">") {
            flushParagraph()
            flushList()
            let quoteContent = trimmed.dropFirst().trimmingWhitespace()
            currentBlockquoteLines.append(quoteContent)
            i += 1
            continue
        } else if !currentBlockquoteLines.isEmpty {
            flushBlockquote()
        }

        // Unordered list (- or * or +)
        if let listItem = parseUnorderedListItemFast(trimmed) {
            flushParagraph()
            flushBlockquote()
            if !currentListItems.isEmpty && isOrderedList {
                flushList()
            }
            isOrderedList = false
            currentListItems.append(String(listItem))
            i += 1
            continue
        }

        // Ordered list (1. 2. etc.)
        if let listItem = parseOrderedListItemFast(trimmed) {
            flushParagraph()
            flushBlockquote()
            if !currentListItems.isEmpty && !isOrderedList {
                flushList()
            }
            isOrderedList = true
            currentListItems.append(String(listItem))
            i += 1
            continue
        }

        // Blank line handling
        if trimmed.isEmpty {
            flushParagraph()
            flushBlockquote()

            // For lists: only flush if the next non-blank line is NOT a list item of the same type
            // This allows "loose" lists (lists with blank lines between items) to render with proper numbering
            if !currentListItems.isEmpty {
                if !nextNonBlankIsListItem(from: i + 1, ordered: isOrderedList) {
                    flushList()
                }
            }

            i += 1
            continue
        }

        // Flush list if we encounter non-list, non-empty content
        if !currentListItems.isEmpty {
            flushList()
        }

        // Regular paragraph line
        currentParagraphLines.append(line)
        i += 1
    }

    // Final flush
    flushParagraph()
    flushBlockquote()
    flushList()

    return blocks
}

// MARK: - Incremental Parsing Helpers

/// Compute the character length of text covered by stable blocks (all except the last one)
/// This is used to determine where to start incremental parsing on the next update
private func computeStableTextLength(blocks: [MessageBlock], fullText: String) -> Int {
    // If we have fewer than 2 blocks, nothing is stable yet
    guard blocks.count >= 2 else { return 0 }

    // Find the position in the text where the second-to-last block ends
    // We need to find a line boundary that represents where stable content ends

    // Strategy: Find approximate position by counting content in stable blocks
    // This is a heuristic - we look for the last blank line or block separator
    // before the final block

    let stableBlockCount = blocks.count - 1
    var approximateLength = 0

    for i in 0 ..< stableBlockCount {
        let block = blocks[i]
        switch block.kind {
        case .paragraph(let text):
            approximateLength += text.count + 2  // +2 for potential newlines
        case .code(let code, _):
            approximateLength += code.count + 10  // Account for ``` markers
        case .heading(_, let text):
            approximateLength += text.count + 4  // Account for # markers
        case .blockquote(let content):
            approximateLength += content.count + 4  // Account for > markers
        case .list(let items, _):
            for item in items {
                approximateLength += item.count + 4  // Account for list markers
            }
        case .table(let headers, let rows):
            for header in headers {
                approximateLength += header.count + 3
            }
            for row in rows {
                for cell in row {
                    approximateLength += cell.count + 3
                }
            }
        case .image(let url, let altText):
            approximateLength += url.count + altText.count + 6
        case .horizontalRule:
            approximateLength += 5
        }
    }

    // Find a safe boundary (previous blank line or paragraph break)
    // Don't go beyond the actual text length
    let safeLength = min(approximateLength, max(0, fullText.count - 100))

    // Find the last newline before this position
    if safeLength > 0 {
        let endIndex =
            fullText.index(fullText.startIndex, offsetBy: safeLength, limitedBy: fullText.endIndex) ?? fullText.endIndex
        let searchRange = fullText.startIndex ..< endIndex
        if let lastNewline = fullText.range(of: "\n\n", options: .backwards, range: searchRange) {
            return fullText.distance(from: fullText.startIndex, to: lastNewline.upperBound)
        }
    }

    return 0  // Fall back to full parse if we can't find a safe boundary
}

// MARK: - Table Parsing Helpers

/// Check if a line is a table separator line (e.g., | --- | --- |)
@inline(__always)
private func isTableSeparatorLine(_ line: Substring) -> Bool {
    guard line.hasPrefix("|") else { return false }

    // A separator line contains only |, -, :, and whitespace
    for char in line {
        if char != "|" && char != "-" && char != ":" && !char.isWhitespace {
            return false
        }
    }

    // Must have at least one dash
    return line.contains("-")
}

/// Parse a table row into cells
private func parseTableRow(_ line: Substring) -> [String] {
    var cells: [String] = []
    var currentCell = ""
    var inCell = false

    for char in line {
        if char == "|" {
            if inCell {
                cells.append(currentCell.trimmingCharacters(in: .whitespaces))
                currentCell = ""
            }
            inCell = true
        } else if inCell {
            currentCell.append(char)
        }
    }

    // Don't append the last cell if it's empty (trailing |)
    if !currentCell.trimmingCharacters(in: .whitespaces).isEmpty {
        cells.append(currentCell.trimmingCharacters(in: .whitespaces))
    }

    return cells
}

// MARK: - Substring Extension for Efficient Trimming

extension Substring {
    /// Efficiently trim whitespace without creating intermediate String
    @inline(__always)
    fileprivate func trimmingWhitespace() -> Substring {
        var start = startIndex
        var end = endIndex

        while start < end && self[start].isWhitespace {
            start = index(after: start)
        }

        while end > start {
            let prevIndex = index(before: end)
            if self[prevIndex].isWhitespace {
                end = prevIndex
            } else {
                break
            }
        }

        return self[start ..< end]
    }
}

// MARK: - Parser Helpers (Optimized for Substring)

/// Fast horizontal rule check without regex
@inline(__always)
private func isHorizontalRuleFast(_ line: Substring) -> Bool {
    guard line.count >= 3 else { return false }

    guard let first = line.first, first == "-" || first == "*" || first == "_" else { return false }

    var count = 0
    for char in line {
        if char == first {
            count += 1
        } else if !char.isWhitespace {
            return false
        }
    }
    return count >= 3
}

/// Fast heading parser without regex
@inline(__always)
private func parseHeadingFast(_ line: Substring) -> (level: Int, text: String)? {
    var level = 0
    var index = line.startIndex

    while index < line.endIndex && line[index] == "#" && level < 6 {
        level += 1
        index = line.index(after: index)
    }

    guard level > 0, index < line.endIndex, line[index] == " " else { return nil }

    var textStart = line.index(after: index)
    var textEnd = line.endIndex

    // Trim leading whitespace
    while textStart < textEnd && line[textStart].isWhitespace {
        textStart = line.index(after: textStart)
    }

    // Trim trailing # and whitespace
    while textEnd > textStart {
        let prevIndex = line.index(before: textEnd)
        let char = line[prevIndex]
        if char == "#" || char.isWhitespace {
            textEnd = prevIndex
        } else {
            break
        }
    }

    return (level, String(line[textStart ..< textEnd]))
}

/// Fast unordered list item parser
@inline(__always)
private func parseUnorderedListItemFast(_ line: Substring) -> Substring? {
    guard line.count >= 2 else { return nil }
    let first = line.first!
    let secondIndex = line.index(after: line.startIndex)

    if (first == "-" || first == "*" || first == "+") && line[secondIndex] == " " {
        return line[line.index(secondIndex, offsetBy: 1)...]
    }
    return nil
}

/// Fast ordered list item parser without regex
@inline(__always)
private func parseOrderedListItemFast(_ line: Substring) -> Substring? {
    var index = line.startIndex

    // Skip digits
    while index < line.endIndex && line[index].isNumber {
        index = line.index(after: index)
    }

    // Check for ". "
    guard index > line.startIndex,
        index < line.endIndex,
        line[index] == "."
    else { return nil }

    let afterDot = line.index(after: index)
    guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }

    let textStart = line.index(after: afterDot)
    return line[textStart...]
}

// Legacy functions for compatibility
private func isHorizontalRule(_ line: String) -> Bool {
    isHorizontalRuleFast(Substring(line))
}

private func parseHeading(_ line: String) -> (level: Int, text: String)? {
    parseHeadingFast(Substring(line))
}

private func parseUnorderedListItem(_ line: String) -> String? {
    guard let result = parseUnorderedListItemFast(Substring(line)) else { return nil }
    return String(result)
}

private func parseOrderedListItem(_ line: String) -> String? {
    guard let result = parseOrderedListItemFast(Substring(line)) else { return nil }
    return String(result)
}

private func extractStandaloneImageKind(from text: String) -> MessageBlock.Kind? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // Match ![alt](url) pattern for standalone images
    let pattern = #"^!\[([^\]]*)\]\(([^)]+)\)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
        let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed))
    else { return nil }

    guard let altRange = Range(match.range(at: 1), in: trimmed),
        let urlRange = Range(match.range(at: 2), in: trimmed)
    else { return nil }

    let altText = String(trimmed[altRange])
    let url = String(trimmed[urlRange])
    return .image(url: url, altText: altText)
}

// MARK: - String Extension

extension String {
    fileprivate var nilIfEmpty: String? { self.isEmpty ? nil : self }
}

// MARK: - Preview

#if DEBUG
    struct MarkdownMessageView_Previews: PreviewProvider {
        static let sampleMarkdown = """
            # Welcome to Osaurus

            Here's a **bold** statement and some *italic* text.

            ## Code Example

            This is a code example:

            ```swift
            func greet(name: String) -> String {
                return "Hello, \\(name)!"
            }
            ```

            ---

            ### Lists

            Unordered list:
            - First item
            - Second item
            - Third item

            Ordered list:
            1. Step one
            2. Step two
            3. Step three

            Loose ordered list (with blank lines):

            1. First item

            2. Second item

            3. Third item

            > This is a blockquote with some important information
            > that spans multiple lines.

            ### Table Example

            | Name | Age | City |
            | --- | --- | --- |
            | Alice | 30 | New York |
            | Bob | 25 | San Francisco |
            | Charlie | 35 | Chicago |

            Here's an image:

            ![Cat Image](https://placekitten.com/400/300)

            And that's all folks!
            """

        static var previews: some View {
            ScrollView {
                MarkdownMessageView(text: sampleMarkdown, baseWidth: 600)
                    .padding()
                    .frame(width: 600, alignment: .leading)
            }
            .background(Color(hex: "0f0f10"))
        }
    }
#endif
