//
//  AgentChannelMessageFormatter.swift
//  osaurus
//
//  Renders agent Markdown into each channel's native outbound format and
//  splits the result into provider-sized chunks.
//
//  All three native providers previously sent the agent's raw Markdown as a
//  plain string (Slack even with parsing disabled), so replies looked like
//  literal `**bold**` markup. This formatter parses the sanitized agent
//  output with the same `parseBlocks` parser the chat UI uses and re-renders
//  it per platform:
//
//  - Slack: normalized standard Markdown for the `markdown_text` field
//    (Slack converts it to rich blocks server-side).
//  - Discord: Discord's Markdown subset (headings clamp to ###, tables and
//    math become code fences, images become masked links).
//  - Telegram: Bot API HTML with full entity escaping (`parse_mode: HTML`).
//
//  Chunking is structure-aware: it packs whole blocks first, then splits at
//  line boundaries, then at grapheme-cluster boundaries — so emoji are never
//  torn apart and code fences / HTML tags are re-balanced across chunks.
//  Formatting is presentation only: mention/broadcast protections stay in the
//  connection services and are validated on the pre-render text.
//

import Foundation

/// A rendered block whose `body` may be split across chunks. When it is,
/// every piece is re-wrapped in `prefix`/`suffix` so code fences and HTML
/// tags stay balanced.
struct AgentChannelRenderedBlock: Equatable, Sendable {
    var prefix: String = ""
    var body: String
    var suffix: String = ""

    var joined: String { prefix + body + suffix }
}

enum AgentChannelMessageFormatter {
    /// Slack `markdown_text` accepts up to 12,000 characters.
    static let slackChunkLimit = 12_000
    /// Discord message `content` caps at 2,000 UTF-16 code units.
    static let discordChunkLimit = 2_000
    /// Telegram message `text` caps at 4,096 UTF-16 code units.
    static let telegramChunkLimit = 4_096
    /// iMessage renders literal plain text (no Markdown). It has no hard
    /// per-message cap comparable to the others, but very long messages are
    /// split so a single logical reply doesn't produce one unwieldy bubble.
    static let plainTextChunkLimit = 8_000
    /// Upper bound on the number of native messages one logical send may
    /// produce. Beyond this the send fails as too long instead of flooding
    /// the room.
    static let maxChunksPerSend = 5

    // MARK: - Slack

    static func slackChunks(_ markdown: String, limit: Int = slackChunkLimit) -> [String] {
        pack(markdownBlocks(markdown, flavor: .slack), limit: limit)
    }

    // MARK: - Discord

    static func discordChunks(_ markdown: String, limit: Int = discordChunkLimit) -> [String] {
        pack(markdownBlocks(markdown, flavor: .discord), limit: limit)
    }

    // MARK: - Telegram

    static func telegramHTMLChunks(_ markdown: String, limit: Int = telegramChunkLimit) -> [String] {
        pack(telegramBlocks(markdown), limit: limit)
    }

    static func telegramHTML(_ markdown: String) -> String {
        telegramBlocks(markdown).map(\.joined).joined(separator: "\n\n")
    }

    // MARK: - Plain text (iMessage)

    /// Render agent Markdown to readable plain text (no markup) and pack it
    /// into `limit`-sized chunks. iMessage shows literal characters, so
    /// emphasis markers would otherwise appear as `**bold**` in the bubble.
    static func plainTextChunks(_ markdown: String, limit: Int = plainTextChunkLimit) -> [String] {
        pack(plainTextBlocks(markdown), limit: limit)
    }

    private static func plainTextBlocks(_ markdown: String) -> [AgentChannelRenderedBlock] {
        parseBlocks(markdown).map { block in
            switch block.kind {
            case .paragraph(let text):
                return AgentChannelRenderedBlock(body: stripInlineMarkdown(text))
            case .heading(_, let text):
                return AgentChannelRenderedBlock(body: stripInlineMarkdown(text))
            case .blockquote(let content):
                let quoted = content
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> \(stripInlineMarkdown(String($0)))" }
                    .joined(separator: "\n")
                return AgentChannelRenderedBlock(body: quoted)
            case .list(let items):
                let lines = items.map { item -> String in
                    let indent = String(repeating: "  ", count: max(0, item.indentLevel))
                    let marker = item.isOrdered ? "\(item.displayNumber)." : "•"
                    return "\(indent)\(marker) \(stripInlineMarkdown(item.text))"
                }
                return AgentChannelRenderedBlock(body: lines.joined(separator: "\n"))
            case .code(let code, _):
                return AgentChannelRenderedBlock(body: code)
            case .table(let headers, let rows):
                return AgentChannelRenderedBlock(body: renderPipeTable(headers: headers, rows: rows))
            case .math(let latex):
                return AgentChannelRenderedBlock(body: latex)
            case .image(let url, let altText):
                let label = altText.isEmpty ? "attachment" : altText
                return AgentChannelRenderedBlock(body: "\(label): \(url)")
            case .horizontalRule:
                return AgentChannelRenderedBlock(body: "———")
            }
        }
    }

    /// Remove inline emphasis / code / link markup, keeping the human-readable
    /// text (link labels with the URL appended in parentheses).
    static func stripInlineMarkdown(_ text: String) -> String {
        var output = ""
        var index = text.startIndex

        while index < text.endIndex {
            let rest = text[index...]
            if rest.hasPrefix("`") {
                if let close = findClosing(in: text, after: text.index(index, offsetBy: 1), marker: "`") {
                    output += String(text[text.index(index, offsetBy: 1) ..< close])
                    index = text.index(after: close)
                    continue
                }
            } else if rest.hasPrefix("**") || rest.hasPrefix("__") {
                let marker = String(rest.prefix(2))
                let innerStart = text.index(index, offsetBy: 2)
                if let close = findClosing(in: text, after: innerStart, marker: marker) {
                    output += stripInlineMarkdown(String(text[innerStart ..< close]))
                    index = text.index(close, offsetBy: 2)
                    continue
                }
            } else if rest.hasPrefix("~~") {
                let innerStart = text.index(index, offsetBy: 2)
                if let close = findClosing(in: text, after: innerStart, marker: "~~") {
                    output += stripInlineMarkdown(String(text[innerStart ..< close]))
                    index = text.index(close, offsetBy: 2)
                    continue
                }
            } else if rest.hasPrefix("*") || rest.hasPrefix("_") {
                let marker = String(rest.prefix(1))
                let innerStart = text.index(index, offsetBy: 1)
                if let close = findClosing(in: text, after: innerStart, marker: marker), close > innerStart {
                    output += stripInlineMarkdown(String(text[innerStart ..< close]))
                    index = text.index(after: close)
                    continue
                }
            } else if rest.hasPrefix("["), let link = parseInlineLink(in: text, from: index) {
                if isSafeLinkURL(link.url) {
                    output += "\(link.label) (\(link.url))"
                } else {
                    output += link.label
                }
                index = link.end
                continue
            }
            output += String(text[index])
            index = text.index(after: index)
        }
        return output
    }

    // MARK: - Markdown flavors (Slack markdown_text / Discord content)

    private enum MarkdownFlavor {
        case slack
        case discord
    }

    private static func markdownBlocks(_ markdown: String, flavor: MarkdownFlavor) -> [AgentChannelRenderedBlock] {
        parseBlocks(markdown).map { block in
            switch block.kind {
            case .paragraph(let text):
                return AgentChannelRenderedBlock(body: text)
            case .heading(let level, let text):
                switch flavor {
                case .slack:
                    return AgentChannelRenderedBlock(body: String(repeating: "#", count: level) + " " + text)
                case .discord:
                    // Discord renders # / ## / ### only; deeper levels read
                    // better as bold text than as literal hash marks.
                    if level <= 3 {
                        return AgentChannelRenderedBlock(body: String(repeating: "#", count: level) + " " + text)
                    }
                    return AgentChannelRenderedBlock(body: "**\(text)**")
                }
            case .blockquote(let content):
                let quoted = content
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> \($0)" }
                    .joined(separator: "\n")
                return AgentChannelRenderedBlock(body: quoted)
            case .list(let items):
                return AgentChannelRenderedBlock(body: renderMarkdownList(items))
            case .code(let code, let lang):
                return AgentChannelRenderedBlock(
                    prefix: "```\(lang ?? "")\n",
                    body: code,
                    suffix: "\n```"
                )
            case .table(let headers, let rows):
                let table = renderPipeTable(headers: headers, rows: rows)
                switch flavor {
                case .slack:
                    // Slack's markdown converter has no table support either,
                    // but pipe rows in a fence keep columns readable.
                    return AgentChannelRenderedBlock(prefix: "```\n", body: table, suffix: "\n```")
                case .discord:
                    return AgentChannelRenderedBlock(prefix: "```\n", body: table, suffix: "\n```")
                }
            case .math(let latex):
                return AgentChannelRenderedBlock(prefix: "```\n", body: latex, suffix: "\n```")
            case .image(let url, let altText):
                let label = altText.isEmpty ? "attachment" : altText
                return AgentChannelRenderedBlock(body: "[\(label)](\(url))")
            case .horizontalRule:
                return AgentChannelRenderedBlock(body: "---")
            }
        }
    }

    private static func renderMarkdownList(_ items: [ListItem]) -> String {
        items.map { item in
            let indent = String(repeating: "  ", count: max(0, item.indentLevel))
            let marker = item.isOrdered ? "\(item.displayNumber)." : "-"
            return "\(indent)\(marker) \(item.text)"
        }
        .joined(separator: "\n")
    }

    private static func renderPipeTable(headers: [String], rows: [[String]]) -> String {
        var lines: [String] = []
        if !headers.isEmpty {
            lines.append("| " + headers.joined(separator: " | ") + " |")
            lines.append("|" + Array(repeating: " --- |", count: headers.count).joined())
        }
        for row in rows {
            lines.append("| " + row.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Telegram HTML

    private static func telegramBlocks(_ markdown: String) -> [AgentChannelRenderedBlock] {
        parseBlocks(markdown).map { block in
            switch block.kind {
            case .paragraph(let text):
                return AgentChannelRenderedBlock(body: telegramInlineHTML(text))
            case .heading(_, let text):
                // Telegram has no heading entity; bold is the native idiom.
                return AgentChannelRenderedBlock(body: "<b>\(telegramInlineHTML(text))</b>")
            case .blockquote(let content):
                return AgentChannelRenderedBlock(
                    prefix: "<blockquote>",
                    body: telegramInlineHTML(content),
                    suffix: "</blockquote>"
                )
            case .list(let items):
                let lines = items.map { item in
                    let indent = String(repeating: "   ", count: max(0, item.indentLevel))
                    let marker = item.isOrdered ? "\(item.displayNumber)." : "•"
                    return "\(indent)\(marker) \(telegramInlineHTML(item.text))"
                }
                return AgentChannelRenderedBlock(body: lines.joined(separator: "\n"))
            case .code(let code, let lang):
                let language = lang?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let openTag = language.isEmpty
                    ? "<pre>"
                    : "<pre><code class=\"language-\(escapeHTMLAttribute(language))\">"
                let closeTag = language.isEmpty ? "</pre>" : "</code></pre>"
                return AgentChannelRenderedBlock(prefix: openTag, body: escapeHTML(code), suffix: closeTag)
            case .table(let headers, let rows):
                return AgentChannelRenderedBlock(
                    prefix: "<pre>",
                    body: escapeHTML(renderPipeTable(headers: headers, rows: rows)),
                    suffix: "</pre>"
                )
            case .math(let latex):
                return AgentChannelRenderedBlock(prefix: "<pre>", body: escapeHTML(latex), suffix: "</pre>")
            case .image(let url, let altText):
                let label = altText.isEmpty ? "attachment" : altText
                guard isSafeLinkURL(url) else {
                    return AgentChannelRenderedBlock(body: escapeHTML("\(label): \(url)"))
                }
                return AgentChannelRenderedBlock(
                    body: "<a href=\"\(escapeHTMLAttribute(url))\">\(escapeHTML(label))</a>"
                )
            case .horizontalRule:
                return AgentChannelRenderedBlock(body: "———")
            }
        }
    }

    /// Converts one span of inline Markdown into Telegram HTML: escapes
    /// `& < >` and maps `**bold**`, `__bold__`, `*italic*`, `_italic_`,
    /// `~~strike~~`, `` `code` ``, and `[text](url)` to their HTML entities.
    /// Unclosed markers are emitted literally (escaped).
    static func telegramInlineHTML(_ text: String) -> String {
        var output = ""
        var index = text.startIndex

        func remainder(_ from: String.Index) -> Substring { text[from...] }

        while index < text.endIndex {
            let rest = remainder(index)

            if rest.hasPrefix("`") {
                if let close = findClosing(in: text, after: text.index(index, offsetBy: 1), marker: "`") {
                    let inner = text[text.index(index, offsetBy: 1) ..< close]
                    output += "<code>\(escapeHTML(String(inner)))</code>"
                    index = text.index(after: close)
                    continue
                }
            } else if rest.hasPrefix("**") || rest.hasPrefix("__") {
                let marker = String(rest.prefix(2))
                let innerStart = text.index(index, offsetBy: 2)
                if let close = findClosing(in: text, after: innerStart, marker: marker) {
                    let inner = text[innerStart ..< close]
                    output += "<b>\(telegramInlineHTML(String(inner)))</b>"
                    index = text.index(close, offsetBy: 2)
                    continue
                }
            } else if rest.hasPrefix("~~") {
                let innerStart = text.index(index, offsetBy: 2)
                if let close = findClosing(in: text, after: innerStart, marker: "~~") {
                    let inner = text[innerStart ..< close]
                    output += "<s>\(telegramInlineHTML(String(inner)))</s>"
                    index = text.index(close, offsetBy: 2)
                    continue
                }
            } else if rest.hasPrefix("*") || rest.hasPrefix("_") {
                let marker = String(rest.prefix(1))
                let innerStart = text.index(index, offsetBy: 1)
                if let close = findClosing(in: text, after: innerStart, marker: marker),
                   close > innerStart {
                    let inner = text[innerStart ..< close]
                    output += "<i>\(telegramInlineHTML(String(inner)))</i>"
                    index = text.index(after: close)
                    continue
                }
            } else if rest.hasPrefix("["),
                      let link = parseInlineLink(in: text, from: index) {
                if isSafeLinkURL(link.url) {
                    output += "<a href=\"\(escapeHTMLAttribute(link.url))\">\(telegramInlineHTML(link.label))</a>"
                } else {
                    output += escapeHTML("\(link.label) (\(link.url))")
                }
                index = link.end
                continue
            }

            output += escapeHTML(String(text[index]))
            index = text.index(after: index)
        }
        return output
    }

    /// Finds the next occurrence of `marker` at or after `start`.
    private static func findClosing(in text: String, after start: String.Index, marker: String) -> String.Index? {
        guard start <= text.endIndex else { return nil }
        return text.range(of: marker, range: start ..< text.endIndex)?.lowerBound
    }

    private static func parseInlineLink(
        in text: String,
        from start: String.Index
    ) -> (label: String, url: String, end: String.Index)? {
        guard text[start] == "[" else { return nil }
        guard let labelEnd = text.range(of: "]", range: text.index(after: start) ..< text.endIndex)?.lowerBound
        else { return nil }
        let afterLabel = text.index(after: labelEnd)
        guard afterLabel < text.endIndex, text[afterLabel] == "(" else { return nil }
        guard let urlEnd = text.range(of: ")", range: text.index(after: afterLabel) ..< text.endIndex)?.lowerBound
        else { return nil }
        let label = String(text[text.index(after: start) ..< labelEnd])
        let url = String(text[text.index(after: afterLabel) ..< urlEnd])
        guard !label.isEmpty, !url.isEmpty, !url.contains(" ") else { return nil }
        return (label, url, text.index(after: urlEnd))
    }

    private static func isSafeLinkURL(_ url: String) -> Bool {
        let lowered = url.lowercased()
        return lowered.hasPrefix("https://") || lowered.hasPrefix("http://")
    }

    static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeHTMLAttribute(_ text: String) -> String {
        escapeHTML(text).replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Chunk packing

    /// Packs rendered blocks into chunks no larger than `limit` UTF-16 code
    /// units. Whole blocks are kept together when possible; an oversized
    /// block body is split at line boundaries, then grapheme boundaries,
    /// with the block's prefix/suffix re-applied to every piece.
    static func pack(
        _ blocks: [AgentChannelRenderedBlock],
        limit: Int,
        separator: String = "\n\n"
    ) -> [String] {
        precondition(limit > 0, "chunk limit must be positive")
        var chunks: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(trimmed) }
            current = ""
        }

        for block in blocks {
            let whole = block.joined
            if utf16Length(whole) <= limit {
                let candidate = current.isEmpty ? whole : current + separator + whole
                if utf16Length(candidate) <= limit {
                    current = candidate
                } else {
                    flush()
                    current = whole
                }
                continue
            }

            // Oversized block: emit what we have, then split the body.
            flush()
            let overhead = utf16Length(block.prefix) + utf16Length(block.suffix)
            let budget = max(1, limit - overhead)
            for piece in splitBody(block.body, budget: budget) {
                chunks.append(block.prefix + piece + block.suffix)
            }
        }
        flush()
        return chunks.isEmpty ? [] : chunks
    }

    /// Splits `body` into pieces of at most `budget` UTF-16 code units,
    /// preferring line boundaries and falling back to grapheme-cluster
    /// boundaries for single overlong lines (so emoji and other multi-scalar
    /// clusters are never split).
    static func splitBody(_ body: String, budget: Int) -> [String] {
        guard utf16Length(body) > budget else { return [body] }
        var pieces: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty {
                pieces.append(current)
                current = ""
            }
        }

        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineString = String(line)
            if utf16Length(lineString) > budget {
                flush()
                pieces.append(contentsOf: splitLineByGraphemes(lineString, budget: budget))
                continue
            }
            let candidate = current.isEmpty ? lineString : current + "\n" + lineString
            if utf16Length(candidate) <= budget {
                current = candidate
            } else {
                flush()
                current = lineString
            }
        }
        flush()
        return pieces.isEmpty ? [body] : pieces
    }

    private static func splitLineByGraphemes(_ line: String, budget: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        var currentLength = 0
        for character in line {
            let characterLength = String(character).utf16.count
            if currentLength + characterLength > budget, !current.isEmpty {
                pieces.append(current)
                current = ""
                currentLength = 0
            }
            current.append(character)
            currentLength += characterLength
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    private static func utf16Length(_ text: String) -> Int {
        text.utf16.count
    }
}
