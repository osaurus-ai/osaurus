//
//  DOCXEditor.swift
//  osaurus
//
//  In-place Word edits on the document XML: find/replace across runs,
//  paragraph insert/delete (new paragraphs clone the anchor's style),
//  table cell text, and appending Markdown. Paragraph numbers are the
//  1-based top-level body paragraphs that `file_read` structure mode lists;
//  tables are numbered the same way.
//

import Foundation

struct DOCXEditor {
    let package: OOXMLPackage
    private(set) var summaries: [String] = []
    private(set) var warnings: [String] = []

    private let ns = OOXMLNamespace.wordprocessing
    private var mainPart = "word/document.xml"

    static let operations = ["replace_text", "insert_paragraph", "delete_paragraph", "set_table_cell", "append_markdown"]

    init(package: OOXMLPackage) throws {
        self.package = package
        mainPart = try package.mainPart()
        guard try package.root(mainPart).firstChild("body") != nil else {
            throw DocumentEditError("This Word document has no body to edit.")
        }
    }

    mutating func apply(_ op: DocumentOperation) throws {
        switch op.name {
        case "replace_text": try replaceText(op)
        case "insert_paragraph": try insertParagraph(op)
        case "delete_paragraph": try deleteParagraph(op)
        case "set_table_cell": try setTableCell(op)
        case "append_markdown": try appendMarkdown(op)
        default:
            throw op.fail("unknown op for .docx; use one of \(Self.operations.joined(separator: ", ")).")
        }
    }

    // MARK: - Structure

    private func body() throws -> XMLElement {
        try package.root(mainPart).firstChild("body")!
    }

    func paragraphs() throws -> [XMLElement] { try body().childElements("p") }
    func tables() throws -> [XMLElement] { try body().childElements("tbl") }

    /// Text parts searched by replace_text: body, headers, footers, notes.
    private func textParts() throws -> [String] {
        var parts = [mainPart]
        for rel in try package.relationships(of: mainPart) where !rel.external {
            let type = rel.type.split(separator: "/").last.map(String.init) ?? ""
            if ["header", "footer", "footnotes", "endnotes"].contains(type) {
                parts.append(OOXMLPackage.resolve(rel.target, from: mainPart))
            }
        }
        return parts
    }

    func paragraphStyleIds() throws -> [String: String] {
        guard let stylesPart = try package.relationships(of: mainPart)
            .first(where: { $0.type.hasSuffix("/styles") })
            .map({ OOXMLPackage.resolve($0.target, from: mainPart) }),
            package.has(stylesPart)
        else { return [:] }
        var out: [String: String] = [:]
        for style in try package.root(stylesPart).childElements("style") where style.attr("w:type") == "paragraph" {
            guard let id = style.attr("w:styleId") else { continue }
            out[id] = style.firstChild("name")?.attr("w:val") ?? id
        }
        return out
    }

    static func styleId(of paragraph: XMLElement) -> String? {
        paragraph.firstChild("pPr")?.firstChild("pStyle")?.attr("w:val")
    }

    // MARK: - Operations

    private mutating func replaceText(_ op: DocumentOperation) throws {
        let find = try op.string(op.has("find") ? "find" : "old_string")
        let replacement = try op.string(op.has("replace") ? "replace" : "new_string", allowEmpty: true)
        let all = op.bool("replace_all") || op.bool("all")
        guard find != replacement else {
            throw op.fail("`old_string` and `new_string` are identical; nothing to change.")
        }
        do {
            try replaceText(op, find: find, replacement: replacement, all: all)
        } catch let error as DocumentEditError where error.isMatchMiss {
            // Markdown syntax is formatting in Word, not text: list bullets
            // and numbers (`file_read` renders "•\t…", a model that drafted
            // the file writes "- item"), heading hashes ("## Scope") and
            // inline emphasis ("**Kickoff: April 7**") all become styles
            // when `file_write` renders the draft. Match without the syntax,
            // and drop it from the replacement too so a literal marker is
            // not written into a styled paragraph.
            let strippedFind = Self.strippingMarkdownSyntax(find)
            guard strippedFind.stripped else { throw error }
            // A multi-line replacement is read as block Markdown by the
            // paragraph expansion below (its markers pick heading/list
            // styling for the new paragraphs), so only a single-line
            // replacement is pre-stripped here.
            let strippedReplacement =
                Self.editLines(replacement).count > 1 ? replacement : Self.strippingMarkdownSyntax(replacement).text
            do {
                try replaceText(op, find: strippedFind.text, replacement: strippedReplacement, all: all)
            } catch let second as DocumentEditError {
                // Another miss reports the original text; a failure past
                // matching (the stripped text matched but couldn't be
                // applied) is the more specific story.
                throw second.isMatchMiss ? error : second
            }
            summaries.append(
                "Markdown syntax in `old_string` (list markers, heading hashes, emphasis) was treated as formatting — Word stores it as paragraph and run styling, not text")
        }
    }

    /// `strippingListMarkers` plus ATX heading hashes and inline emphasis
    /// (`**bold**`, `__bold__`, `*italic*`, `_italic_`, `` `code` ``,
    /// `~~strike~~`) per line. Underscores inside words (`file_name`) are
    /// left alone: an emphasis run must start after whitespace/start and
    /// end before whitespace/punctuation/end.
    static func strippingMarkdownSyntax(_ text: String) -> (text: String, stripped: Bool) {
        var changed = false
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var out = line
            let leading = out.prefix { $0 == " " || $0 == "\t" }
            let body = out.dropFirst(leading.count)
            let hashes = body.prefix(while: { $0 == "#" }).count
            if hashes > 0, hashes <= 6, body.dropFirst(hashes).first == " " {
                out = String(leading) + String(body.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
            let list = strippingListMarkers(out)
            if list.stripped { out = list.text; changed = true }
            for pattern in Self.inlineEmphasisPatterns {
                let range = NSRange(out.startIndex..., in: out)
                let replaced = pattern.stringByReplacingMatches(in: out, range: range, withTemplate: "$1$2")
                if replaced != out { out = replaced; changed = true }
            }
            return out
        }
        return (changed ? lines.joined(separator: "\n") : text, changed)
    }

    private static let inlineEmphasisPatterns: [NSRegularExpression] = {
        let boundaryBefore = "(^|[\\s(\\[\"'“‘])"
        let boundaryAfter = "(?=$|[\\s.,;:!?)\\]\"'”’])"
        let patterns = [
            "\\*\\*(\\S(?:[^*\\n]*?\\S)?)\\*\\*",
            "__(\\S(?:[^_\\n]*?\\S)?)__",
            "~~(\\S(?:[^~\\n]*?\\S)?)~~",
            "`([^`\\n]+)`",
            "\\*(\\S(?:[^*\\n]*?\\S)?)\\*",
            "_(\\S(?:[^_\\n]*?\\S)?)_",
        ]
        return patterns.compactMap { core in
            try? NSRegularExpression(pattern: boundaryBefore + core + boundaryAfter, options: [])
        }
    }()

    /// Leading list markers per line: `•`, `◦`, `▪`, `-`, `*`, `+`, or `1.` /
    /// `1)` followed by a space or tab. Returns the text without them and
    /// whether anything changed.
    static func strippingListMarkers(_ text: String) -> (text: String, stripped: Bool) {
        var changed = false
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            var rest = Substring(line.dropFirst(leading.count))
            if let first = rest.first, "•◦▪■-*+–".contains(first) {
                rest = rest.dropFirst()
            } else {
                let digits = rest.prefix { $0.isNumber }
                guard (1...3).contains(digits.count), let punct = rest.dropFirst(digits.count).first, punct == "." || punct == ")"
                else { return line }
                rest = rest.dropFirst(digits.count + 1)
            }
            guard let separator = rest.first, separator == " " || separator == "\t" else { return line }
            changed = true
            return String(leading) + String(rest.drop { $0 == " " || $0 == "\t" })
        }
        return (changed ? lines.joined(separator: "\n") : text, changed)
    }

    private mutating func replaceText(_ op: DocumentOperation, find: String, replacement: String, all: Bool) throws {
        // A multi-line old_string means "this run of paragraphs".
        let findLines = Self.editLines(find)
        if findLines.count > 1 {
            try replaceAcrossParagraphs(op, lines: findLines, replacement: replacement, all: all)
            return
        }
        let needle = findLines.first ?? find

        // Match cascade: byte-for-byte first, then punctuation/whitespace
        // folded. The mode is chosen document-wide so a count of N always
        // means N replacements under one rule.
        var paragraphsByPart: [(part: String, paras: [XMLElement])] = []
        for part in try textParts() where package.has(part) {
            paragraphsByPart.append((part, try package.root(part).descendants("p")))
        }
        var mode: OOXMLText.MatchMode = .exact
        var perPart: [(part: String, hits: Int)] = []
        var total = 0
        for candidate in [OOXMLText.MatchMode.exact, .normalized] {
            perPart = paragraphsByPart.map { entry in
                (entry.part, entry.paras.reduce(0) { $0 + OOXMLText.occurrences(of: needle, in: $1, mode: candidate) })
            }
            total = perPart.reduce(0) { $0 + $1.hits }
            mode = candidate
            if total > 0 { break }
        }
        guard total > 0 else {
            throw op.fail(
                "\"\(OOXMLText.preview(needle, max: 80))\" wasn't found in the document text."
                    + Self.closestParagraphHint(for: needle, in: try paragraphs()),
                isMatchMiss: true)
        }
        guard all || total == 1 else {
            throw op.fail(
                "\"\(OOXMLText.preview(needle, max: 80))\" appears \(total) times (\(Self.describeParts(perPart))); "
                    + "add surrounding words to `old_string`, or pass `replace_all: true`.")
        }

        // A multi-line replacement means "these paragraphs": the first line
        // stays in the matched paragraph, the rest become new paragraphs
        // (read as block Markdown, so `## Heading` / `- item` pick styles
        // instead of landing as literal text) — the way the same text
        // would have been rendered by `file_write`. Soft line breaks
        // inside one paragraph would read back as one run-on line and no
        // later `old_string` could address the new paragraphs.
        let replacementLines = Self.editLines(replacement)
        if replacementLines.count > 1 {
            let expanded = try expandIntoParagraphs(op, needle: needle, lines: replacementLines, paragraphsByPart: paragraphsByPart, mode: mode)
            var summary =
                "Replaced \(expanded) occurrence\(expanded == 1 ? "" : "s") of \"\(OOXMLText.preview(needle, max: 60))\" with \(replacementLines.count) paragraphs (each line of `new_string` is a paragraph; `## ` headings and `- ` bullets became styles)"
            if mode == .normalized { summary += " (matched with punctuation and whitespace normalized)" }
            summaries.append(summary)
            return
        }

        var replaced = 0
        for (part, paras) in paragraphsByPart {
            var changed = false
            for p in paras {
                let n: Int
                do {
                    n = try OOXMLText.replace(in: p, find: needle, with: replacement, flavor: .word, mode: mode)
                } catch OOXMLText.ReplaceError.spansBreak {
                    throw op.fail(
                        "\"\(OOXMLText.preview(needle, max: 80))\" runs across a tab or line break in the document; replace the text on each side of it separately.",
                        isMatchMiss: true)
                }
                if n > 0 { changed = true; replaced += n }
            }
            if changed { package.markDirty(part) }
        }
        var summary = "Replaced \(replaced) occurrence\(replaced == 1 ? "" : "s") of \"\(OOXMLText.preview(needle, max: 60))\""
        if mode == .normalized {
            summary += " (matched with punctuation and whitespace normalized: the document's own quotes/dashes differed from `old_string`)"
        }
        summaries.append(summary)
    }

    /// Replace one match per paragraph with `lines` as paragraphs: the
    /// matched paragraph keeps its head text and takes the first line; any
    /// tail text after the match moves to a clone (keeping its runs) that
    /// takes the last line; the lines in between are built from block
    /// Markdown next to the matched paragraph. Returns the number of
    /// paragraphs expanded.
    private mutating func expandIntoParagraphs(
        _ op: DocumentOperation, needle: String, lines: [String],
        paragraphsByPart: [(part: String, paras: [XMLElement])], mode: OOXMLText.MatchMode
    ) throws -> Int {
        var expanded = 0
        for (part, paras) in paragraphsByPart {
            var changed = false
            for p in paras {
                let text = OOXMLText.text(of: p)
                let ranges = OOXMLText.matchRanges(of: needle, in: text, mode: mode)
                guard let range = ranges.first else { continue }
                guard ranges.count == 1 else {
                    throw op.fail(
                        "\"\(OOXMLText.preview(needle, max: 80))\" appears \(ranges.count) times inside one paragraph; a multi-line `new_string` splits the paragraph there, so add surrounding words to match one occurrence.")
                }
                let units = Array(text.utf16)
                let tailIsBlank = units[range.upperBound...].allSatisfy { OOXMLText.foldUnit($0) == [0x20] || OOXMLText.foldUnit($0).isEmpty }
                var tailHolder: XMLElement?
                if !tailIsBlank {
                    let clone = p.deepCopy()
                    try Self.spansBreak {
                        try OOXMLText.replace(in: clone, ranges: [0..<range.upperBound], with: Self.blockMarkdown(lines[lines.count - 1]).text, flavor: .word)
                    }
                    Self.pruneEmptyTextRuns(clone)
                    tailHolder = clone
                }
                let firstText =
                    range.lowerBound == 0 ? Self.lineText(lines[0], replacingStartOf: text) : Self.blockMarkdown(lines[0]).text
                try Self.spansBreak {
                    try OOXMLText.replace(in: p, ranges: [range.lowerBound..<units.count], with: firstText, flavor: .word)
                }
                Self.pruneEmptyTextRuns(p)
                let fresh = tailHolder == nil ? lines[1...] : lines[1..<(lines.count - 1)]
                var cursor: XMLNode = p
                for line in fresh {
                    let paragraph = try markdownParagraph(line, near: p)
                    paragraph.insertSibling(after: cursor)
                    cursor = paragraph
                }
                if let tailHolder { tailHolder.insertSibling(after: cursor) }
                changed = true
                expanded += 1
            }
            if changed { package.markDirty(part) }
        }
        return expanded
    }

    /// Drop runs whose text was emptied by a range replacement and that
    /// carry nothing else (no tab/break/drawing), so a split paragraph
    /// doesn't keep a stray `<w:t/>`.
    private static func pruneEmptyTextRuns(_ paragraph: XMLElement) {
        for run in paragraph.childElements("r") {
            let content = run.elementChildren.filter { $0.local != "rPr" }
            guard !content.isEmpty, content.allSatisfy({ $0.local == "t" && ($0.stringValue ?? "").isEmpty }) else { continue }
            run.detach()
        }
    }

    private static func spansBreak<T>(_ work: () throws -> T) throws -> T {
        do { return try work() } catch OOXMLText.ReplaceError.spansBreak {
            throw DocumentEditError(
                "`old_string` runs across a tab or line break inside a paragraph; replace the text on each side of it separately.",
                isMatchMiss: true)
        }
    }

    // MARK: Block Markdown lines

    enum BlockKind: Equatable { case heading(Int), listItem, plain }

    /// One line of a multi-line `new_string` read as block Markdown: an
    /// ATX heading (`## Title`), a list item (`- item`, `* item`, `1. item`
    /// — the same markers `strippingListMarkers` accepts, including the
    /// `•\t` that `file_read` renders), or plain text.
    static func blockMarkdown(_ line: String) -> (kind: BlockKind, text: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        if hashes > 0, hashes <= 6, trimmed.dropFirst(hashes).first == " " {
            return (.heading(hashes), String(trimmed.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces))
        }
        let stripped = strippingListMarkers(trimmed)
        if stripped.stripped { return (.listItem, stripped.text) }
        return (.plain, trimmed)
    }

    static func isListParagraph(_ paragraph: XMLElement) -> Bool {
        if paragraph.firstChild("pPr")?.firstChild("numPr") != nil { return true }
        return styleId(of: paragraph)?.lowercased().hasPrefix("list") == true
    }

    /// A paragraph for one block-Markdown line, styled from the document:
    /// headings use the `HeadingN` style when defined (bold text
    /// otherwise), list items clone the nearest list paragraph's
    /// formatting (then `ListBullet`, then a literal bullet), plain lines
    /// clone the nearest unstyled body paragraph.
    private func markdownParagraph(_ line: String, near anchor: XMLElement) throws -> XMLElement {
        let block = Self.blockMarkdown(line)
        let styles = try paragraphStyleIds()
        let paras = try paragraphs()
        let plainTemplate = paras.last { Self.styleId(of: $0) == nil && !Self.isListParagraph($0) }
        func plainParagraph() -> XMLElement {
            if let plainTemplate { return makeParagraph("", like: plainTemplate, style: nil) }
            let p = makeParagraph("", like: anchor, style: nil)
            if let pPr = p.firstChild("pPr") {
                pPr.firstChild("numPr")?.detach()
                pPr.firstChild("pStyle")?.detach()
            }
            return p
        }
        switch block.kind {
        case .heading(let level):
            let style = styles["Heading\(level)"] != nil ? "Heading\(level)" : nil
            let p = style == nil ? plainParagraph() : makeParagraph("", like: nil, style: style)
            appendInlineMarkdown(style == nil ? "**\(block.text)**" : block.text, to: p, runTemplate: plainTemplate)
            return p
        case .listItem:
            if let listTemplate = Self.nearestListParagraph(to: anchor, in: paras) {
                let p = makeParagraph("", like: listTemplate, style: nil)
                appendInlineMarkdown(block.text, to: p, runTemplate: listTemplate)
                return p
            }
            if styles["ListBullet"] != nil {
                let p = makeParagraph("", like: nil, style: "ListBullet")
                appendInlineMarkdown(block.text, to: p, runTemplate: plainTemplate)
                return p
            }
            // Documents rendered from Markdown by `file_write` carry their
            // bullets as literal "•\t" text; match that shape (and its
            // paragraph formatting) so new items look like their siblings.
            if let literal = Self.nearestLiteralBulletParagraph(to: anchor, in: paras) {
                let p = makeParagraph("", like: literal.paragraph, style: nil)
                appendInlineMarkdown(literal.prefix + block.text, to: p, runTemplate: literal.paragraph)
                return p
            }
            let p = plainParagraph()
            appendInlineMarkdown("• " + block.text, to: p, runTemplate: plainTemplate)
            return p
        case .plain:
            let p = plainParagraph()
            appendInlineMarkdown(block.text, to: p, runTemplate: plainTemplate ?? anchor)
            return p
        }
    }

    /// The anchor itself when it is a list paragraph, else the closest list
    /// paragraph before it, else the closest after it.
    static func nearestListParagraph(to anchor: XMLElement, in paras: [XMLElement]) -> XMLElement? {
        nearest(to: anchor, in: paras, where: isListParagraph)
    }

    /// Closest paragraph whose text starts with a literal bullet glyph and
    /// a tab/space, with that prefix, for documents that carry bullets as
    /// text rather than numbering.
    static func nearestLiteralBulletParagraph(to anchor: XMLElement, in paras: [XMLElement]) -> (paragraph: XMLElement, prefix: String)? {
        func prefix(of paragraph: XMLElement) -> String? { literalBulletPrefix(OOXMLText.text(of: paragraph)) }
        guard let paragraph = nearest(to: anchor, in: paras, where: { prefix(of: $0) != nil }),
            let found = prefix(of: paragraph)
        else { return nil }
        return (paragraph, found)
    }

    /// "•\t" / "• " when the paragraph text starts with a literal bullet, or
    /// "1.\t" / "12) " when it starts with a literal list number (rendered
    /// drafts store list items this way).
    static func literalBulletPrefix(_ text: String) -> String? {
        if let glyph = text.first, "•◦▪■".contains(glyph),
            let separator = text.dropFirst().first, separator == "\t" || separator == " "
        {
            return String(glyph) + String(separator)
        }
        let digits = text.prefix { $0.isNumber }
        guard (1...3).contains(digits.count) else { return nil }
        let rest = text.dropFirst(digits.count)
        guard let punct = rest.first, punct == "." || punct == ")",
            let separator = rest.dropFirst().first, separator == "\t" || separator == " "
        else { return nil }
        return String(digits) + String(punct) + String(separator)
    }

    /// Text for a `new_string` line that lands on an existing paragraph,
    /// replacing it from its start: block-Markdown syntax is dropped (the
    /// paragraph keeps its style), except that a list-item line keeps the
    /// paragraph's own literal bullet prefix when it has one, so
    /// "•\tKickoff: April 7" → "- Kickoff: May 5" stays a bulleted line.
    static func lineText(_ line: String, replacingStartOf paragraphText: String) -> String {
        let block = blockMarkdown(line)
        if block.kind == .listItem, let prefix = literalBulletPrefix(paragraphText) {
            return prefix + block.text
        }
        return block.text
    }

    private static func nearest(to anchor: XMLElement, in paras: [XMLElement], where matches: (XMLElement) -> Bool) -> XMLElement? {
        if matches(anchor) { return anchor }
        guard let index = paras.firstIndex(where: { $0 === anchor }) else {
            return paras.first(where: matches)
        }
        if let before = paras[..<index].last(where: matches) { return before }
        return paras[(index + 1)...].first(where: matches)
    }

    // MARK: Multi-paragraph replace

    /// Lines of an `old_string` / `new_string`, split on newlines, edge
    /// whitespace trimmed, blank lines dropped (paragraph boundaries are the
    /// unit of matching; blank lines between them are the model's
    /// formatting, not the document's).
    static func editLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Replace a run of consecutive body paragraphs whose text matches
    /// `lines`: the first line matches the END of the first paragraph, the
    /// last line matches the START of the last paragraph, and any middle
    /// lines match whole paragraphs. The replacement's lines land on the
    /// same paragraphs (first/last keep their unmatched text and run
    /// formatting; middles are rewritten, added as clones, or removed as the
    /// line counts require), so paragraph styles survive the edit.
    private mutating func replaceAcrossParagraphs(_ op: DocumentOperation, lines: [String], replacement: String, all: Bool) throws {
        let paras = try paragraphs()
        let texts = paras.map { OOXMLText.text(of: $0) }
        var mode: OOXMLText.MatchMode = .exact
        var matches: [ParagraphRunMatch] = []
        for candidate in [OOXMLText.MatchMode.exact, .normalized] {
            matches = Self.paragraphRunMatches(lines: lines, texts: texts, mode: candidate)
            mode = candidate
            if !matches.isEmpty { break }
        }
        guard !matches.isEmpty else {
            let first = lines[0]
            var message = "the \(lines.count)-line `old_string` doesn't match \(lines.count) consecutive paragraphs. "
            var starts: [Int] = []
            for (index, text) in texts.enumerated()
            where !OOXMLText.matchRanges(of: first, in: text, mode: .normalized).isEmpty {
                starts.append(index + 1)
            }
            if starts.isEmpty {
                message += "Its first line wasn't found in any body paragraph."
                    + Self.closestParagraphHint(for: first, in: paras)
            } else {
                message += "Its first line occurs in paragraph\(starts.count == 1 ? "" : "s") \(starts.prefix(8).map(String.init).joined(separator: ", ")); "
                    + "the following paragraph\(lines.count == 2 ? "" : "s") there read"
                if let start = starts.first {
                    let following = texts[start..<min(start + lines.count - 1, texts.count)]
                    message += ":\n" + following.map { "  \"\(OOXMLText.preview($0, max: 120))\"" }.joined(separator: "\n")
                }
                message += "\nCopy the paragraph text as `file_read` mode \"structure\" lists it."
            }
            throw op.fail(message, isMatchMiss: true)
        }
        guard all || matches.count == 1 else {
            throw op.fail(
                "the \(lines.count)-line `old_string` matches \(matches.count) paragraph runs (starting at paragraphs \(matches.map { String($0.start + 1) }.joined(separator: ", "))); "
                    + "add surrounding text, or pass `replace_all: true`.")
        }

        let newLines = Self.editLines(replacement)
        for match in matches.reversed() {
            try applyParagraphRun(match, paras: paras, newLines: newLines, mode: mode)
        }
        package.markDirty(mainPart)

        var summary =
            "Replaced \(matches.count) run\(matches.count == 1 ? "" : "s") of \(lines.count) paragraphs (starting at paragraph \(matches.map { String($0.start + 1) }.joined(separator: ", "))) with \(newLines.count) paragraph\(newLines.count == 1 ? "" : "s")"
        if mode == .normalized { summary += " (matched with punctuation and whitespace normalized)" }
        summaries.append(summary)
    }

    struct ParagraphRunMatch {
        /// 0-based index of the first matched paragraph.
        let start: Int
        let count: Int
        /// UTF-16 range of the first line inside the first paragraph's text.
        let firstRange: Range<Int>
        /// UTF-16 range of the last line inside the last paragraph's text.
        let lastRange: Range<Int>
    }

    static func paragraphRunMatches(lines: [String], texts: [String], mode: OOXMLText.MatchMode) -> [ParagraphRunMatch] {
        let k = lines.count
        guard k >= 2, texts.count >= k else { return [] }
        var out: [ParagraphRunMatch] = []
        var start = 0
        while start + k <= texts.count {
            guard let first = edgeRange(of: lines[0], in: texts[start], edge: .suffix, mode: mode),
                let last = edgeRange(of: lines[k - 1], in: texts[start + k - 1], edge: .prefix, mode: mode)
            else {
                start += 1
                continue
            }
            var middlesMatch = true
            for offset in 1..<(k - 1) where edgeRange(of: lines[offset], in: texts[start + offset], edge: .whole, mode: mode) == nil {
                middlesMatch = false
                break
            }
            if middlesMatch {
                out.append(ParagraphRunMatch(start: start, count: k, firstRange: first, lastRange: last))
                start += k
            } else {
                start += 1
            }
        }
        return out
    }

    enum Edge { case prefix, suffix, whole }

    /// The range of `line` in `text` anchored to the given edge (only
    /// whitespace may surround it on the anchored side(s)). A literal list
    /// prefix at the start of the paragraph ("•\t", "1.\t" — how rendered
    /// drafts store list items) counts as blank on the leading side, so a
    /// line whose list marker was stripped as Markdown syntax still
    /// addresses the whole item; the prefix itself stays in the paragraph.
    static func edgeRange(of line: String, in text: String, edge: Edge, mode: OOXMLText.MatchMode) -> Range<Int>? {
        let units = Array(text.utf16)
        func blank(_ range: Range<Int>) -> Bool {
            units[range].allSatisfy { OOXMLText.foldUnit($0) == [0x20] || OOXMLText.foldUnit($0).isEmpty }
        }
        let prefixLength = literalBulletPrefix(text)?.utf16.count ?? 0
        func leadingBlank(_ upper: Int) -> Bool {
            blank(0..<upper) || (upper >= prefixLength && blank(prefixLength..<upper))
        }
        let ranges = OOXMLText.matchRanges(of: line, in: text, mode: mode)
        switch edge {
        case .suffix:
            return ranges.last { blank($0.upperBound..<units.count) }
        case .prefix:
            return ranges.first { leadingBlank($0.lowerBound) }
        case .whole:
            return ranges.first { leadingBlank($0.lowerBound) && blank($0.upperBound..<units.count) }
        }
    }

    private mutating func applyParagraphRun(_ match: ParagraphRunMatch, paras: [XMLElement], newLines: [String], mode: OOXMLText.MatchMode) throws {
        let first = paras[match.start]
        let last = paras[match.start + match.count - 1]
        let middles = Array(paras[(match.start + 1)..<(match.start + match.count - 1)])
        let firstLength = OOXMLText.text(of: first).utf16.count
        // Lines written into existing paragraphs keep those paragraphs'
        // styles, so a block-Markdown prefix is formatting to drop, not
        // text to write.
        let firstParagraphText = OOXMLText.text(of: first)
        let firstText =
            newLines.first.map {
                match.firstRange.lowerBound == 0 ? Self.lineText($0, replacingStartOf: firstParagraphText) : Self.blockMarkdown($0).text
            } ?? ""
        // A literal list prefix ("•\t" — a `<w:tab/>` in the document) that
        // the match was anchored after stays in place and is written around;
        // replacing across it would span the tab.
        let lastParagraphText = OOXMLText.text(of: last)
        let lastKeep = min(Self.literalBulletPrefix(lastParagraphText)?.utf16.count ?? 0, match.lastRange.upperBound)
        let lastText =
            newLines.last.map {
                lastKeep > 0 ? Self.blockMarkdown($0).text : Self.lineText($0, replacingStartOf: lastParagraphText)
            } ?? ""

        if newLines.count <= 1 {
            // Everything collapses into the first paragraph: its unmatched
            // head, the (optional) single new line, then the last
            // paragraph's unmatched tail (runs moved over, formatting kept).
            try Self.spansBreak {
                try OOXMLText.replace(in: first, ranges: [match.firstRange.lowerBound..<firstLength], with: firstText, flavor: .word)
            }
            try Self.spansBreak {
                try OOXMLText.replace(in: last, ranges: [lastKeep..<match.lastRange.upperBound], with: "", flavor: .word)
            }
            // A last paragraph reduced to its literal bullet has no tail to
            // carry over; moving the bullet would prepend it to the first.
            let remainder = OOXMLText.text(of: last)
            let tailIsOnlyPrefix = lastKeep > 0 && remainder.utf16.count <= lastKeep
            for child in last.elementChildren where !tailIsOnlyPrefix && !["pPr", "endParaRPr"].contains(child.local) {
                child.detach()
                if let end = first.firstChild("endParaRPr") {
                    first.insertChild(child, at: end.index)
                } else {
                    first.addChild(child)
                }
            }
            for paragraph in middles { paragraph.detach() }
            last.detach()
            return
        }

        try Self.spansBreak {
            try OOXMLText.replace(in: first, ranges: [match.firstRange.lowerBound..<firstLength], with: firstText, flavor: .word)
        }
        try Self.spansBreak {
            try OOXMLText.replace(in: last, ranges: [lastKeep..<match.lastRange.upperBound], with: lastText, flavor: .word)
        }
        let newMiddles = Array(newLines[1..<(newLines.count - 1)])
        let paired = min(middles.count, newMiddles.count)
        for index in 0..<paired {
            let block = Self.blockMarkdown(newMiddles[index])
            // A heading or list line landing on a paragraph that isn't one
            // is rebuilt with the matching style; otherwise the paragraph
            // keeps its formatting and only the text changes.
            let needsRestyle: Bool
            switch block.kind {
            case .heading: needsRestyle = Self.styleId(of: middles[index])?.lowercased().hasPrefix("heading") != true
            case .listItem:
                needsRestyle =
                    !Self.isListParagraph(middles[index]) && Self.literalBulletPrefix(OOXMLText.text(of: middles[index])) == nil
            case .plain: needsRestyle = false
            }
            if needsRestyle {
                let rebuilt = try markdownParagraph(newMiddles[index], near: middles[index])
                rebuilt.insertSibling(after: middles[index])
                middles[index].detach()
            } else {
                let middleText = OOXMLText.text(of: middles[index])
                let keep = Self.literalBulletPrefix(middleText)?.utf16.count ?? 0
                if keep > 0 {
                    try Self.spansBreak {
                        try OOXMLText.replace(
                            in: middles[index], ranges: [keep..<middleText.utf16.count], with: block.text, flavor: .word)
                    }
                } else {
                    OOXMLText.setText(middles[index], Self.lineText(newMiddles[index], replacingStartOf: middleText), flavor: .word)
                }
            }
        }
        for paragraph in middles.dropFirst(paired) { paragraph.detach() }
        if newMiddles.count > paired {
            // Extra new lines become paragraphs built from block Markdown
            // next to the last paragraph, inserted just before it.
            for line in newMiddles.dropFirst(paired) {
                let paragraph = try markdownParagraph(line, near: paired > 0 ? middles[paired - 1] : first)
                paragraph.insertSibling(before: last)
            }
        }
    }

    // MARK: Diagnostics

    private static func describeParts(_ perPart: [(part: String, hits: Int)]) -> String {
        perPart.filter { $0.hits > 0 }.map { entry in
            let name = (entry.part as NSString).lastPathComponent
            let label = name == "document.xml" ? "body" : name.replacingOccurrences(of: ".xml", with: "")
            return "\(entry.hits) in \(label)"
        }.joined(separator: ", ")
    }

    /// Quote the paragraph most similar to `needle` (verbatim, bounded) so
    /// the model can copy the document's real text.
    static func closestParagraphHint(for needle: String, in paras: [XMLElement]) -> String {
        let needleNorm = OOXMLText.NormalizedUnits(needle).units
        guard needleNorm.count >= 4 else { return "" }
        var best: (index: Int, text: String, score: Int)?
        for (index, paragraph) in paras.enumerated() {
            let text = OOXMLText.text(of: paragraph)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let hayNorm = OOXMLText.NormalizedUnits(text).units
            let score: Int
            if !OOXMLText.matchOffsets(of: needleNorm, in: hayNorm, limit: 1).isEmpty
                || (!hayNorm.isEmpty && !OOXMLText.matchOffsets(of: hayNorm, in: needleNorm, limit: 1).isEmpty)
            {
                score = min(needleNorm.count, hayNorm.count)
            } else {
                score = Self.longestCommonRun(needleNorm, hayNorm)
            }
            if score > (best?.score ?? 0) { best = (index, text, score) }
        }
        guard let best, best.score >= max(4, needleNorm.count / 2) else { return "" }
        return " The closest paragraph text is (paragraph \(best.index + 1)):\n\"\(OOXMLText.preview(best.text, max: 400))\"\nCompare it against your `old_string`."
    }

    /// Length of the longest common contiguous run of code units — cheap
    /// similarity for short paragraphs.
    private static func longestCommonRun(_ a: [UInt16], _ b: [UInt16]) -> Int {
        guard !a.isEmpty, !b.isEmpty, a.count * b.count <= 4_000_000 else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var best = 0
        for i in 1...a.count {
            var current = [Int](repeating: 0, count: b.count + 1)
            for j in 1...b.count where a[i - 1] == b[j - 1] {
                current[j] = previous[j - 1] + 1
                if current[j] > best { best = current[j] }
            }
            previous = current
        }
        return best
    }

    private mutating func insertParagraph(_ op: DocumentOperation) throws {
        let text = try op.string("text", allowEmpty: true)
        let paras = try paragraphs()
        let after = try op.optionalInt("after")
        let before = try op.optionalInt("before")
        guard after == nil || before == nil else { throw op.fail("pass `after` or `before`, not both.") }

        let anchor: XMLElement?
        var insertAfter = true
        if let after {
            anchor = after == 0 ? nil : paras[try op.position(after, of: paras.count, noun: "paragraph")]
            if after == 0 { insertAfter = false }
        } else if let before {
            anchor = paras[try op.position(before, of: paras.count, noun: "paragraph")]
            insertAfter = false
        } else {
            anchor = paras.last
        }
        let styleSource = anchor ?? paras.first
        var style: String?
        if let requested = try op.optionalString("style"), !requested.isEmpty {
            style = try resolveStyle(requested, op: op)
        }
        var newParagraphs: [XMLElement] = []
        for line in text.components(separatedBy: "\n") {
            newParagraphs.append(makeParagraph(line, like: styleSource, style: style))
        }
        let bodyElement = try body()
        if let anchor {
            var cursor: XMLNode = anchor
            if insertAfter {
                for p in newParagraphs {
                    p.insertSibling(after: cursor)
                    cursor = p
                }
            } else {
                for p in newParagraphs { p.insertSibling(before: anchor) }
            }
        } else if after == 0, let first = bodyElement.elementChildren.first {
            for p in newParagraphs { p.insertSibling(before: first) }
        } else {
            for p in newParagraphs { try appendToBody(p) }
        }
        package.markDirty(mainPart)
        let position = after.map { "after paragraph \($0)" } ?? before.map { "before paragraph \($0)" } ?? "at the end"
        summaries.append("Inserted \(newParagraphs.count) paragraph\(newParagraphs.count == 1 ? "" : "s") \(position)")
    }

    private mutating func deleteParagraph(_ op: DocumentOperation) throws {
        let paras = try paragraphs()
        var targets = try op.optionalInts("indices") ?? []
        if let single = try op.optionalInt("index") { targets.append(single) }
        guard !targets.isEmpty else { throw op.fail("pass `index` (or `indices`) of the paragraph(s) to delete.") }
        let unique = Array(Set(targets)).sorted()
        let doomed = try unique.map { paras[try op.position($0, of: paras.count, noun: "paragraph")] }
        guard doomed.count < paras.count else {
            throw op.fail("that would delete every paragraph; a Word document needs at least one.")
        }
        for (number, p) in zip(unique, doomed) where p.firstChild("pPr")?.firstChild("sectPr") != nil {
            throw op.fail("paragraph \(number) ends a section (it carries page layout); deleting it would change the layout of the pages before it.")
        }
        for p in doomed { p.detach() }
        package.markDirty(mainPart)
        summaries.append("Deleted paragraph\(unique.count == 1 ? "" : "s") \(unique.map(String.init).joined(separator: ", "))")
    }

    private mutating func setTableCell(_ op: DocumentOperation) throws {
        let tbls = try tables()
        guard !tbls.isEmpty else { throw op.fail("the document has no tables.") }
        let table = tbls[try op.position(try op.optionalInt("table") ?? 1, of: tbls.count, noun: "table")]
        let rows = table.childElements("tr")
        let rowNumber = try op.int("row")
        let row = rows[try op.position(rowNumber, of: rows.count, noun: "row")]
        let cells = row.childElements("tc")
        let columnNumber = try op.int("column")
        let cell = cells[try op.position(columnNumber, of: cells.count, noun: "column")]
        let text = try op.string("text", allowEmpty: true)

        let cellParas = cell.childElements("p")
        let template = cellParas.first
        for p in cellParas { p.detach() }
        var insertAt = cell.childElements("tcPr").first.map { $0.index + 1 } ?? 0
        for line in text.components(separatedBy: "\n") {
            let p = makeParagraph(line, like: template, style: nil)
            cell.insertChild(p, at: insertAt)
            insertAt += 1
        }
        package.markDirty(mainPart)
        summaries.append("Set table \(try op.optionalInt("table") ?? 1) row \(rowNumber) column \(columnNumber)")
    }

    private mutating func appendMarkdown(_ op: DocumentOperation) throws {
        let markdown = try op.string("markdown")
        let styles = try paragraphStyleIds()
        let body = try paragraphs()
        let template = body.last { Self.styleId(of: $0) == nil } ?? body.last
        var added = 0
        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            var content = line
            var style: String?
            var prefix = ""
            let hashes = line.prefix(while: { $0 == "#" }).count
            if hashes > 0, hashes <= 6, line.dropFirst(hashes).first == " " {
                content = String(line.dropFirst(hashes + 1))
                style = styles["Heading\(hashes)"] != nil ? "Heading\(hashes)" : nil
                if style == nil { content = "**\(content)**" }
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                content = String(line.dropFirst(2))
                if styles["ListBullet"] != nil { style = "ListBullet" } else { prefix = "• " }
            }
            let p = makeParagraph("", like: style == nil ? template : nil, style: style)
            appendInlineMarkdown(prefix + content, to: p, runTemplate: template)
            try appendToBody(p)
            added += 1
        }
        guard added > 0 else { throw op.fail("`markdown` has no text to add.") }
        package.markDirty(mainPart)
        summaries.append("Appended \(added) paragraph\(added == 1 ? "" : "s") of Markdown")
    }

    // MARK: - Building

    private func resolveStyle(_ requested: String, op: DocumentOperation) throws -> String {
        let styles = try paragraphStyleIds()
        if styles[requested] != nil { return requested }
        if let match = styles.first(where: { $0.value.caseInsensitiveCompare(requested) == .orderedSame }) {
            return match.key
        }
        let compact = requested.replacingOccurrences(of: " ", with: "")
        if styles[compact] != nil { return compact }
        let names = styles.values.sorted().prefix(30).joined(separator: ", ")
        throw op.fail("style \"\(requested)\" isn't defined in this document. Available paragraph styles: \(names).")
    }

    /// New paragraph that copies `template`'s paragraph and first-run
    /// formatting (minus section/numbering-restart specifics).
    private func makeParagraph(_ text: String, like template: XMLElement?, style: String?) -> XMLElement {
        let bodyElement = (try? body()) ?? XMLElement(name: "w:body", uri: ns)
        let p = bodyElement.makeChild("p", uri: ns)
        if let pPr = template?.firstChild("pPr")?.deepCopy() {
            pPr.firstChild("sectPr")?.detach()
            p.addChild(pPr)
        }
        if let style {
            let pPr = p.firstChild("pPr") ?? {
                let created = p.makeChild("pPr", uri: ns)
                p.insertChild(created, at: 0)
                return created
            }()
            pPr.firstChild("numPr")?.detach()
            if let existing = pPr.firstChild("pStyle") {
                existing.setAttr("w:val", style, uri: ns)
            } else {
                let pStyle = pPr.makeChild("pStyle", uri: ns)
                pStyle.setAttr("w:val", style, uri: ns)
                pPr.insertChild(pStyle, at: 0)
            }
        }
        if !text.isEmpty {
            p.addChild(makeRun(text, like: style == nil ? template : nil, parent: p))
        }
        return p
    }

    private func makeRun(_ text: String, like template: XMLElement?, parent: XMLElement, bold: Bool = false, italic: Bool = false)
        -> XMLElement
    {
        let run = parent.makeChild("r", uri: ns)
        var rPr = template?.descendants("r").first?.firstChild("rPr")?.deepCopy()
        if bold || italic {
            let props = rPr ?? run.makeChild("rPr", uri: ns)
            if bold, props.firstChild("b") == nil { props.insertChild(props.makeChild("b", uri: ns), at: 0) }
            if italic, props.firstChild("i") == nil { props.insertChild(props.makeChild("i", uri: ns), at: 0) }
            rPr = props
        }
        if let rPr { run.addChild(rPr) }
        let t = run.makeChild("t", uri: ns)
        let text = OOXMLText.stripInvalidXML(text)
        t.stringValue = text
        OOXMLText.applySpacePreserve(t, text)
        run.addChild(t)
        return run
    }

    /// `**bold**`, `*italic*` / `_italic_`, and `` `code` `` spans.
    private func appendInlineMarkdown(_ text: String, to p: XMLElement, runTemplate: XMLElement?) {
        var bold = false
        var italic = false
        var buffer = ""
        let chars = Array(text)
        var i = 0
        func flush() {
            guard !buffer.isEmpty else { return }
            p.addChild(makeRun(buffer, like: runTemplate, parent: p, bold: bold, italic: italic))
            buffer = ""
        }
        while i < chars.count {
            if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "*" {
                flush(); bold.toggle(); i += 2; continue
            }
            if chars[i] == "*" || (chars[i] == "_" && (i == 0 || chars[i - 1] == " " || italic)) {
                flush(); italic.toggle(); i += 1; continue
            }
            if chars[i] == "`" {
                i += 1
                continue
            }
            buffer.append(chars[i])
            i += 1
        }
        flush()
    }

    private func appendToBody(_ p: XMLElement) throws {
        let bodyElement = try body()
        if let sectPr = bodyElement.childElements("sectPr").last {
            p.insertSibling(before: sectPr)
        } else {
            bodyElement.addChild(p)
        }
    }
}
