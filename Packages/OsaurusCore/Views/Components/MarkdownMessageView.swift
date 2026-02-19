//
//  MarkdownMessageView.swift
//  osaurus
//
//  Renders markdown text with proper typography, code blocks, images, and more.
//  Optimized for streaming responses with stable block identity.
//  Uses NSTextView for web-like text selection across blocks.
//

import AppKit
import SwiftUI

struct MarkdownMessageView: View {
    let text: String
    let baseWidth: CGFloat
    /// Optional cache key passed to SelectableTextView for width-aware height caching
    var cacheKey: String? = nil
    /// Whether content is actively streaming - when true, uses lighter rendering for large content
    var isStreaming: Bool = false

    var body: some View {
        // Use inner view with memoized parsing to avoid re-parsing on every render
        MemoizedMarkdownView(text: text, baseWidth: baseWidth, cacheKey: cacheKey, isStreaming: isStreaming)
    }
}

// MARK: - Memoized Inner View

/// Inner view that caches parsed segments and only recomputes when text changes
private struct MemoizedMarkdownView: View {
    let text: String
    let baseWidth: CGFloat
    let cacheKey: String?
    let isStreaming: Bool

    @Environment(\.theme) private var theme

    @State private var cachedSegments: [ContentSegment] = []
    @State private var lastParsedText: String = ""
    @State private var cachedBlocks: [MessageBlock] = []
    @State private var lastStableIndex: Int = 0
    @State private var currentParseTask: Task<Void, Never>?
    @State private var lastParseRequestTime: Date = .distantPast

    init(text: String, baseWidth: CGFloat, cacheKey: String?, isStreaming: Bool) {
        self.text = text
        self.baseWidth = baseWidth
        self.cacheKey = cacheKey
        self.isStreaming = isStreaming

        // Initialize from cache if available synchronously
        if let cached = ThreadCache.shared.markdown(for: text) {
            _cachedSegments = State(initialValue: cached.segments)
            _cachedBlocks = State(initialValue: cached.blocks)
            _lastParsedText = State(initialValue: text)
        }
    }

    // Debounce interval in milliseconds - scales with content size
    // With paragraph-based rendering, each paragraph is smaller so debounce can be shorter
    private var debounceIntervalMs: UInt64 {
        let charCount = text.utf8.count
        switch charCount {
        case 0 ..< 500:
            return 30  // Very small: fast updates
        case 500 ..< 1_000:
            return 50
        case 1_000 ..< 2_000:
            return 80
        case 2_000 ..< 5_000:
            return 120
        default:
            return 200  // Large content: moderate debounce
        }
    }

    /// Cheap fallback text that strips data-URI images to avoid SwiftUI laying out
    /// multi-MB base64 strings while the background parse is in flight.
    private var fallbackText: String {
        guard text.contains("data:image/") else { return text }
        return text.replacingOccurrences(
            of: #"!\[[^\]]*\]\(data:image/[^)]+\)"#,
            with: "![image]",
            options: .regularExpression
        )
    }

    var body: some View {
        Group {
            if cachedSegments.isEmpty && !text.isEmpty {
                Text(fallbackText)
                    .font(Typography.body(baseWidth, theme: theme))
                    .foregroundColor(theme.primaryText)
                    .textSelection(.enabled)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(cachedSegments.enumerated()), id: \.element.id) { index, segment in
                        segmentView(for: segment, isFirst: index == 0)
                    }
                }
            }
        }
        .onAppear {
            if lastParsedText != text {
                scheduleBackgroundParse(for: text, oldText: "", debounce: false)
            }
        }
        .onChange(of: text) { oldText, newText in
            if lastParsedText != newText {
                scheduleBackgroundParse(for: newText, oldText: oldText, debounce: true)
            }
        }
        .onChange(of: isStreaming) { _, newValue in
            // When streaming ends, parse synchronously so the segments
            // are up-to-date before the table re-measures row height.
            // Background parsing would race with noteHeightOfRows.
            if !newValue && lastParsedText != text {
                currentParseTask?.cancel()
                currentParseTask = nil
                let blocks = parseBlocks(text)
                let segments = groupBlocksIntoSegments(blocks)
                cachedBlocks = blocks
                cachedSegments = segments
                lastParsedText = text
                lastStableIndex = max(0, blocks.count - 1)
                ThreadCache.shared.setMarkdown(blocks: blocks, segments: segments, for: text)
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
        let debounceMs = debounce ? debounceIntervalMs : 0
        lastParseRequestTime = Date()

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
            // Note: We always do a full parse to avoid the complexity and bugs of incremental parsing.
            // The debouncing and background execution provide sufficient performance improvement.
            let (newBlocks, newSegments) = await Task.detached(priority: .userInitiated) {
                let blocks = parseBlocks(textSnapshot)
                let segments = groupBlocksIntoSegments(blocks)
                return (blocks, segments)
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

                // Update cache
                ThreadCache.shared.setMarkdown(blocks: newBlocks, segments: newSegments, for: textSnapshot)
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

            let segmentCacheKey = cacheKey.map { "\($0)-\(segment.id)" }

            switch segment.kind {
            case .textGroup(let textBlocks):
                SelectableTextWithOverlays(
                    blocks: textBlocks,
                    baseWidth: baseWidth,
                    theme: theme,
                    cacheKey: segmentCacheKey
                )

            case .image(let url, let altText):
                MarkdownImageView(urlString: url, altText: altText, baseWidth: baseWidth)
            }
        }
    }
}

// MARK: - Content Segment

/// Represents a segment of content - either a group of selectable text blocks or a standalone image
struct ContentSegment: Identifiable {
    enum Kind {
        case textGroup([SelectableTextBlock])
        case image(url: String, altText: String)
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

/// Groups consecutive text blocks into segments for efficient rendering with NSTextView.
/// Code blocks, horizontal rules, and tables are kept inline in the text group for continuous
/// selection. Only images break the text group since they cannot be rendered as attributed text.
private func groupBlocksIntoSegments(_ blocks: [MessageBlock]) -> [ContentSegment] {
    var segments: [ContentSegment] = []
    var currentTextBlocks: [SelectableTextBlock] = []
    var segmentIndex = 0
    func flushTextGroup() {
        if !currentTextBlocks.isEmpty {
            let spacing = segments.isEmpty ? 0 : imageSpacing
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

        case .list(let items):
            for item in items {
                currentTextBlocks.append(
                    .listItem(
                        text: item.text,
                        index: item.displayNumber - 1,  // Convert 1-based display number to 0-based index
                        ordered: item.isOrdered,
                        indentLevel: item.indentLevel
                    )
                )
            }

        case .code(let code, let lang):
            // Keep code blocks inline in the text group for continuous selection
            currentTextBlocks.append(.codeBlock(code: code, language: lang))

        case .image(let url, let altText):
            // Images are the only blocks that break text groups (can't be attributed text)
            flushTextGroup()
            let spacing = imageSpacing
            segments.append(
                ContentSegment(
                    id: "image-\(segmentIndex)",
                    kind: .image(url: url, altText: altText),
                    spacingBefore: spacing
                )
            )
            segmentIndex += 1

        case .horizontalRule:
            // Keep horizontal rules inline in the text group
            currentTextBlocks.append(.horizontalRule)

        case .table(let headers, let rows):
            // Keep tables inline in the text group for continuous selection
            currentTextBlocks.append(.table(headers: headers, rows: rows))
        }

    }

    flushTextGroup()

    return segments
}

/// Spacing around images (the only block type that breaks text groups)
private let imageSpacing: CGFloat = 16

// MARK: - Message Block

/// Represents a list item with its text, indentation level, and display number
struct ListItem: Equatable, Hashable {
    let text: String
    let indentLevel: Int
    let displayNumber: Int  // The number to display (1, 2, 3...) for ordered lists
    let isOrdered: Bool  // Whether this specific item is ordered or unordered
}

struct MessageBlock: Identifiable {
    enum Kind: Equatable {
        case paragraph(String)
        case code(String, String?)
        case image(url: String, altText: String)
        case heading(level: Int, text: String)
        case blockquote(String)
        case horizontalRule
        case list(items: [ListItem])
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
            case .list(let items):
                hasher.combine("l")
                hasher.combine(items)
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
    var currentListItems: [ListItem] = []
    // Track numbering at each indent level for ordered lists
    var orderedCounters: [Int: Int] = [:]  // indentLevel -> current count
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
            blocks.append(MessageBlock(index: blockIndex, kind: .list(items: currentListItems)))
            blockIndex += 1
            currentListItems.removeAll(keepingCapacity: true)
            // Always reset counters when a list ends - the next list is a new list
            orderedCounters.removeAll(keepingCapacity: true)
        }
    }

    /// Check if the next non-blank line is any list item (ordered or unordered)
    @inline(__always)
    func nextNonBlankIsAnyListItem(from startIndex: Int) -> Bool {
        var j = startIndex
        while j < lines.count {
            let nextLine = lines[j]
            let trimmed = nextLine.trimmingWhitespace()
            if !trimmed.isEmpty {
                // Pass pre-trimmed content to avoid redundant trimming
                return parseUnorderedListItemWithIndent(nextLine, trimmed: trimmed) != nil
                    || parseOrderedListItemWithIndent(nextLine, trimmed: trimmed) != nil
            }
            j += 1
        }
        return false
    }

    var i = 0
    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingWhitespace()

        // Fenced code block
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

        // Unordered list (- * +)
        if let parsed = parseUnorderedListItemWithIndent(line, trimmed: trimmed) {
            flushParagraph()
            flushBlockquote()
            currentListItems.append(
                ListItem(
                    text: String(parsed.text),
                    indentLevel: parsed.indentLevel,
                    displayNumber: 0,
                    isOrdered: false
                )
            )
            i += 1
            continue
        }

        // Ordered list (1. 2. etc.)
        if let parsed = parseOrderedListItemWithIndent(line, trimmed: trimmed) {
            flushParagraph()
            flushBlockquote()

            let indentLevel = parsed.indentLevel
            let currentCount = orderedCounters[indentLevel, default: 0] + 1
            orderedCounters[indentLevel] = currentCount

            // Reset deeper indent counters when returning to shallower level
            for key in orderedCounters.keys where key > indentLevel {
                orderedCounters.removeValue(forKey: key)
            }

            currentListItems.append(
                ListItem(
                    text: String(parsed.text),
                    indentLevel: indentLevel,
                    displayNumber: currentCount,
                    isOrdered: true
                )
            )
            i += 1
            continue
        }

        // Blank line handling
        if trimmed.isEmpty {
            flushParagraph()
            flushBlockquote()

            // For lists: only flush if the next non-blank line is NOT any list item
            // This allows "loose" lists (lists with blank lines between items) to stay together
            if !currentListItems.isEmpty {
                if !nextNonBlankIsAnyListItem(from: i + 1) {
                    flushList()
                }
            }

            i += 1
            continue
        }

        // Continuation line: indented content following a list item
        if !currentListItems.isEmpty {
            let leadingSpaces = countLeadingSpaces(line)
            if leadingSpaces >= 2 {
                // Append to previous list item
                let lastIndex = currentListItems.count - 1
                let lastItem = currentListItems[lastIndex]
                currentListItems[lastIndex] = ListItem(
                    text: lastItem.text + " " + String(trimmed),
                    indentLevel: lastItem.indentLevel,
                    displayNumber: lastItem.displayNumber,
                    isOrdered: lastItem.isOrdered
                )
                i += 1
                continue
            }
            // Non-list content encountered
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

// MARK: - List Parsing Helpers

/// Result of parsing a list item, including indentation info
private struct ParsedListItem {
    let text: Substring
    let indentLevel: Int
    let isOrdered: Bool
    let originalNumber: Int?  // Only set for ordered items
}

/// Count leading spaces in a line (tabs count as 4 spaces)
@inline(__always)
private func countLeadingSpaces(_ line: Substring) -> Int {
    var spaces = 0
    for char in line {
        if char == " " {
            spaces += 1
        } else if char == "\t" {
            spaces += 4
        } else {
            break
        }
    }
    return spaces
}

/// Calculate indentation level from leading whitespace
/// Returns the indent level (0 for no indent, 1 for 2-4 spaces, 2 for 4-6 spaces, etc.)
@inline(__always)
private func calculateIndentLevel(_ line: Substring) -> Int {
    let spaces = countLeadingSpaces(line)
    // Each indent level is approximately 2-4 spaces
    // Use 2 spaces per level for better nested list detection
    return spaces / 2
}

/// Parse an unordered list item, returning text and indentation info
/// - Parameters:
///   - line: The original line (used to calculate indent level)
///   - trimmed: Pre-trimmed version of the line (optimization to avoid redundant trimming)
@inline(__always)
private func parseUnorderedListItemWithIndent(_ line: Substring, trimmed: Substring? = nil) -> ParsedListItem? {
    let indentLevel = calculateIndentLevel(line)
    let content = trimmed ?? line.trimmingWhitespace()

    guard content.count >= 2 else { return nil }
    let first = content.first!
    let secondIndex = content.index(after: content.startIndex)

    // Accept any whitespace character after the bullet, not just ASCII space
    if (first == "-" || first == "*" || first == "+") && content[secondIndex].isWhitespace {
        // Skip any additional whitespace
        var textStart = content.index(after: secondIndex)
        while textStart < content.endIndex && content[textStart].isWhitespace {
            textStart = content.index(after: textStart)
        }
        let text = content[textStart...]
        return ParsedListItem(text: text, indentLevel: indentLevel, isOrdered: false, originalNumber: nil)
    }
    return nil
}

/// Parse an ordered list item, returning text, indentation info, and original number
/// - Parameters:
///   - line: The original line (used to calculate indent level)
///   - trimmed: Pre-trimmed version of the line (optimization to avoid redundant trimming)
@inline(__always)
private func parseOrderedListItemWithIndent(_ line: Substring, trimmed: Substring? = nil) -> ParsedListItem? {
    let indentLevel = calculateIndentLevel(line)
    let content = trimmed ?? line.trimmingWhitespace()

    var index = content.startIndex
    var numberStr = ""

    // Skip digits and collect them
    while index < content.endIndex && content[index].isNumber {
        numberStr.append(content[index])
        index = content.index(after: index)
    }

    // Check for "." followed by whitespace (or ")" for alternate syntax)
    guard index > content.startIndex,
        index < content.endIndex,
        (content[index] == "." || content[index] == ")")
    else { return nil }

    let afterDot = content.index(after: index)
    // Accept any whitespace character after the dot, not just ASCII space
    guard afterDot < content.endIndex, content[afterDot].isWhitespace else { return nil }

    // Skip any additional whitespace
    var textStart = content.index(after: afterDot)
    while textStart < content.endIndex && content[textStart].isWhitespace {
        textStart = content.index(after: textStart)
    }

    let originalNumber = Int(numberStr) ?? 1

    return ParsedListItem(
        text: content[textStart...],
        indentLevel: indentLevel,
        isOrdered: true,
        originalNumber: originalNumber
    )
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

            Nested list (ordered with unordered children):
            1. Shang Dynasty (c. 1600–1046 BCE)
              - First historically documented dynasty.
              - Known for bronze vessels and oracle bones.
            2. Zhou Dynasty (1046–256 BCE)
              - Founded by King Wu.
              - Introduced the "Mandate of Heaven".

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
