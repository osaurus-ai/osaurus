//
//  MarkdownBlockParsing.swift
//  osaurus
//
//  Shared, view-neutral Markdown block model and parser.
//
//  Extracted from MarkdownMessageView so both the chat renderer (which turns
//  blocks into AppKit views) and the Agent Channel outbound formatters (which
//  turn blocks into Slack/Discord/Telegram native payloads) consume the same
//  parsed structure. Keep this file free of AppKit/SwiftUI imports.
//

import Foundation

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
        case math(String)

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
            case .math(let latex):
                hasher.combine("m")
                hasher.combine(latex)
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

func parseBlocks(_ input: String) -> [MessageBlock] {
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

        // Block math: $$ ... $$ or \[ ... \]
        if let result = tryParseBlockMath(trimmed, lines: lines, from: i) {
            flushParagraph()
            flushBlockquote()
            flushList()
            blocks.append(MessageBlock(index: blockIndex, kind: .math(result.latex)))
            blockIndex += 1
            i = result.nextIndex
            continue
        }

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

        // Table detection: pipe-delimited header followed by a separator-ish row
        // or at minimum another pipe-delimited row. Tolerate blank lines between
        // rows and malformed separators (some small models emit `| :/| :---/|`).
        if trimmed.hasPrefix("|"), pipeCount(trimmed) >= 2 {
            var nextIdx: Int? = nil
            var j = i + 1
            while j < lines.count {
                let lt = lines[j].trimmingWhitespace()
                if lt.isEmpty {
                    j += 1
                    continue
                }
                if lt.hasPrefix("|") && pipeCount(lt) >= 2 {
                    nextIdx = j
                }
                break
            }

            if let ni = nextIdx {
                flushParagraph()
                flushBlockquote()
                flushList()

                let headers = parseTableRow(trimmed)

                // If the next line looks like a separator, skip it. Otherwise treat
                // it as the first data row (headerless/separatorless tables).
                var start = ni
                let nextLine = lines[ni].trimmingWhitespace()
                if isTableSeparatorLine(nextLine) || looksLikeSeparatorRow(nextLine) {
                    start = ni + 1
                }

                var rows: [[String]] = []
                i = start
                while i < lines.count {
                    let rowLine = lines[i].trimmingWhitespace()
                    if rowLine.isEmpty {
                        var k = i + 1
                        while k < lines.count, lines[k].trimmingWhitespace().isEmpty { k += 1 }
                        if k < lines.count, lines[k].trimmingWhitespace().hasPrefix("|") {
                            i = k
                            continue
                        }
                        break
                    }
                    if rowLine.hasPrefix("|") {
                        if isTableSeparatorLine(rowLine) || looksLikeSeparatorRow(rowLine) {
                            i += 1
                            continue
                        }
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

// MARK: - Block Math Parsing

private struct BlockMathResult {
    let latex: String
    let nextIndex: Int
}

/// Try to parse a block math expression starting at the current line.
/// Supports `$$...$$` and `\[...\]` delimiters, both single-line and multi-line.
/// Returns nil if the line doesn't start a block math expression or the delimiter is unclosed.
private func tryParseBlockMath(_ trimmed: Substring, lines: [Substring], from i: Int) -> BlockMathResult? {
    struct Delimiter {
        let open: String
        let close: String
    }
    let delimiters = [
        Delimiter(open: "$$", close: "$$"),
        Delimiter(open: "\\[", close: "\\]"),
    ]

    for delim in delimiters {
        guard trimmed.hasPrefix(delim.open) else { continue }
        let afterOpener = trimmed.dropFirst(delim.open.count).trimmingWhitespace()

        // Single-line: open content close
        if afterOpener.hasSuffix(delim.close) && afterOpener.count > delim.close.count {
            let latex = String(afterOpener.dropLast(delim.close.count)).trimmingCharacters(in: .whitespaces)
            guard !latex.isEmpty, looksLikeLatex(latex) else { return nil }
            return BlockMathResult(latex: latex, nextIndex: i + 1)
        }

        // Multi-line: scan forward for closing delimiter
        var mathLines: [Substring] = []
        if !afterOpener.isEmpty { mathLines.append(afterOpener) }
        var j = i + 1
        while j < lines.count {
            let ml = lines[j].trimmingWhitespace()
            if ml.hasSuffix(delim.close) {
                let before = ml.dropLast(delim.close.count).trimmingWhitespace()
                if !before.isEmpty { mathLines.append(before) }
                let latex = mathLines.map { String($0) }.joined(separator: "\n")
                guard looksLikeLatex(latex) else { return nil }
                return BlockMathResult(latex: latex, nextIndex: j + 1)
            }
            mathLines.append(lines[j])
            j += 1
        }
        // Unclosed delimiter during streaming — fall through
        return nil
    }
    return nil
}

/// A block-math segment only counts as math when its content contains a LaTeX-ish
/// character (`\`, `^`, `_`, `{`). Prevents currency or stray `$$` runs from being typeset.
@inline(__always)
private func looksLikeLatex(_ s: String) -> Bool {
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\\", "^", "_", "{": return true
        default: continue
        }
    }
    return false
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

/// Loose separator detection — catches malformed separators that some small models emit
/// (e.g., `| :/| :---/|`). Accepts any pipe-delimited row with no letters/digits and
/// at least one `-` or `:`.
@inline(__always)
private func looksLikeSeparatorRow(_ line: Substring) -> Bool {
    guard line.hasPrefix("|") else { return false }
    var hasMarker = false
    for char in line {
        if char.isLetter || char.isNumber { return false }
        if char == "-" || char == ":" { hasMarker = true }
    }
    return hasMarker
}

/// Count of `|` characters in a line — used to detect multi-column pipe-delimited rows.
@inline(__always)
private func pipeCount(_ line: Substring) -> Int {
    var n = 0
    for char in line where char == "|" { n += 1 }
    return n
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
