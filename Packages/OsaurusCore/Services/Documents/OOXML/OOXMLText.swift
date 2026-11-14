//
//  OOXMLText.swift
//  osaurus
//
//  Run-aware text for WordprocessingML (`w:p/w:r/w:t`) and DrawingML
//  (`a:p/a:r/a:t`) paragraphs. Word and PowerPoint split a visible
//  sentence across many runs (spell-check marks, revision ids, a bold
//  word), so find/replace works on the paragraph's joined text and maps
//  matches back onto the runs: the replacement lands in the run where the
//  match starts (keeping that run's formatting) and the matched text is
//  removed from any following runs.
//

import Foundation

enum OOXMLText {
    struct Flavor {
        let uri: String
        /// Word needs `xml:space="preserve"` to keep edge whitespace; DrawingML
        /// preserves it by default.
        let needsSpacePreserve: Bool

        static let word = Flavor(uri: OOXMLNamespace.wordprocessing, needsSpacePreserve: true)
        static let drawing = Flavor(uri: OOXMLNamespace.drawing, needsSpacePreserve: false)
    }

    /// One piece of a paragraph's visible text: an editable `t` element, or
    /// a tab / line-break element that shows up in the joined text as a
    /// sentinel character so a match can't silently jump across it.
    enum Piece {
        case text(XMLElement)
        case tab(XMLElement)
        case lineBreak(XMLElement)

        var sentinel: String? {
            switch self {
            case .text: return nil
            case .tab: return "\t"
            case .lineBreak: return "\n"
            }
        }
    }

    /// Pieces in reading order (skips deleted revision text, field
    /// instructions, and nested paragraphs such as text boxes, which are
    /// handled as paragraphs of their own).
    static func pieces(in paragraph: XMLElement) -> [Piece] {
        var out: [Piece] = []
        func walk(_ element: XMLElement) {
            for child in element.elementChildren {
                switch child.local {
                case "t" where element.local == "r":
                    out.append(.text(child))
                case "tab" where element.local == "r":
                    out.append(.tab(child))
                case "br", "cr":
                    // Word: `w:br`/`w:cr` inside a run; DrawingML: `a:br`
                    // as a sibling of runs. Page breaks count as breaks too.
                    out.append(.lineBreak(child))
                case "p", "del", "txbxContent", "instrText", "delText":
                    continue
                default:
                    walk(child)
                }
            }
        }
        walk(paragraph)
        return out
    }

    /// `t` elements that belong to runs, in reading order.
    static func textElements(in paragraph: XMLElement) -> [XMLElement] {
        pieces(in: paragraph).compactMap { if case .text(let e) = $0 { return e } else { return nil } }
    }

    /// The paragraph's text with tabs and line breaks as `\t` / `\n`.
    static func text(of paragraph: XMLElement) -> String {
        pieces(in: paragraph).map { piece in
            if case .text(let e) = piece { return e.stringValue ?? "" }
            return piece.sentinel ?? ""
        }.joined()
    }

    enum ReplaceError: Error {
        /// A match runs across a tab or line-break element.
        case spansBreak
        /// The replacement has a newline where the format can't carry one
        /// inside a run (DrawingML).
        case newlineUnsupported
    }

    /// Non-overlapping match offsets of `needle` in `haystack`, left to
    /// right — the one matcher used both to count and to replace, so a
    /// count of N always means N replacements.
    static func matchOffsets(of needle: [UInt16], in haystack: [UInt16], limit: Int = .max) -> [Int] {
        guard !needle.isEmpty, needle.count <= haystack.count, limit > 0 else { return [] }
        var matches: [Int] = []
        var i = 0
        while i + needle.count <= haystack.count, matches.count < limit {
            if haystack[i] == needle[0], haystack[i..<i + needle.count].elementsEqual(needle) {
                matches.append(i)
                i += needle.count
            } else {
                i += 1
            }
        }
        return matches
    }

    /// How many times `find` occurs in the paragraph (same matcher as
    /// `replace`).
    static func occurrences(of find: String, in paragraph: XMLElement, mode: MatchMode = .exact) -> Int {
        matchRanges(of: find, in: text(of: paragraph), mode: mode).count
    }

    // MARK: - Tolerant matching

    /// How `find` is compared against a paragraph's text. `exact` is a
    /// byte-for-byte (UTF-16) match; `normalized` folds unicode punctuation
    /// look-alikes (curly quotes, dashes, non-breaking spaces — Word
    /// autocorrects all of them) and collapses whitespace runs on both
    /// sides, then maps the match back onto the paragraph's real code units
    /// so the replacement still lands on the document's own text.
    enum MatchMode: String {
        case exact
        case normalized
    }

    /// Match ranges (UTF-16 offsets into `text`) for `find`, non-overlapping
    /// left to right, under `mode`.
    static func matchRanges(of find: String, in text: String, mode: MatchMode, limit: Int = .max) -> [Range<Int>] {
        switch mode {
        case .exact:
            let needle = Array(find.utf16)
            return matchOffsets(of: needle, in: Array(text.utf16), limit: limit).map { $0..<($0 + needle.count) }
        case .normalized:
            let needleFolded = NormalizedUnits(find).units
            guard !needleFolded.isEmpty else { return [] }
            // Trim the needle's edge whitespace: a model routinely pads a
            // phrase with a space it copied from the surrounding text.
            let trimmedNeedle = trimSpace(needleFolded)
            guard !trimmedNeedle.isEmpty else { return [] }
            let hay = NormalizedUnits(text)
            return matchOffsets(of: trimmedNeedle, in: hay.units, limit: limit).map { start in
                let end = start + trimmedNeedle.count - 1
                return hay.origin[start].lowerBound..<hay.origin[end].upperBound
            }
        }
    }

    /// A folded, whitespace-collapsed view of a string where every unit
    /// remembers the original UTF-16 range it came from.
    struct NormalizedUnits {
        var units: [UInt16] = []
        var origin: [Range<Int>] = []

        init(_ text: String) {
            let raw = Array(text.utf16)
            var index = 0
            var pendingSpace: Range<Int>? = nil
            while index < raw.count {
                let unit = raw[index]
                let folded = OOXMLText.foldUnit(unit)
                var width = 1
                var out: [UInt16]
                if UTF16.isLeadSurrogate(unit), index + 1 < raw.count, UTF16.isTrailSurrogate(raw[index + 1]) {
                    width = 2
                    out = [unit, raw[index + 1]]
                } else {
                    out = folded
                }
                if out == [0x20] {
                    // Whitespace: collapse the run to one space spanning it.
                    pendingSpace = (pendingSpace?.lowerBound ?? index)..<(index + width)
                } else if out.isEmpty {
                    // Dropped (zero-width) unit: absorbed into the neighbours.
                } else {
                    if let space = pendingSpace {
                        units.append(0x20)
                        origin.append(space)
                        pendingSpace = nil
                    }
                    // Multi-unit expansions (… -> ...) all point at the
                    // same original unit.
                    for u in out {
                        units.append(u)
                        origin.append(index..<(index + width))
                    }
                }
                index += width
            }
            if let space = pendingSpace {
                units.append(0x20)
                origin.append(space)
            }
        }
    }

    /// Fold one UTF-16 unit for `MatchMode.normalized`: whitespace variants
    /// to a space, quote/dash look-alikes to ASCII, zero-width marks
    /// dropped. Everything else is returned unchanged.
    static func foldUnit(_ unit: UInt16) -> [UInt16] {
        switch unit {
        case 0x09, 0x0A, 0x0D, 0x20, 0xA0, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x202F,
            0x205F, 0x3000:
            return [0x20]
        case 0x2018, 0x2019, 0x201A, 0x201B, 0x2032, 0x00B4, 0x02BC:
            return [0x27]  // '
        case 0x201C, 0x201D, 0x201E, 0x201F, 0x2033, 0x00AB, 0x00BB:
            return [0x22]  // "
        case 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212:
            return [0x2D]  // -
        case 0x2026:
            return [0x2E, 0x2E, 0x2E]  // ...
        case 0x200B, 0x200C, 0x200D, 0xFEFF, 0x00AD:
            return []
        default:
            return [unit]
        }
    }

    private static func trimSpace(_ units: [UInt16]) -> [UInt16] {
        var slice = units[...]
        while slice.first == 0x20 { slice = slice.dropFirst() }
        while slice.last == 0x20 { slice = slice.dropLast() }
        return Array(slice)
    }

    /// Strip scalars XML 1.0 can't carry (C0 controls other than tab /
    /// newline / CR, lone surrogates, U+FFFE/U+FFFF) so a pasted string
    /// never produces a part Word or PowerPoint refuses to open.
    static func stripInvalidXML(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { Self.isInvalidXML($0) }) else { return text }
        var out = ""
        out.unicodeScalars.append(contentsOf: text.unicodeScalars.filter { !Self.isInvalidXML($0) })
        return out
    }

    static func isInvalidXML(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value < 0x20 { return scalar != "\t" && scalar != "\n" && scalar != "\r" }
        return (0xD800...0xDFFF).contains(scalar.value) || scalar.value == 0xFFFE || scalar.value == 0xFFFF
    }

    /// Replace occurrences of `find` inside one paragraph. Returns the
    /// number of replacements made (0 when nothing matched). Throws when a
    /// match would cross a tab/line-break element, or when `replacement`
    /// carries a newline the flavor can't express inside a run.
    @discardableResult
    static func replace(
        in paragraph: XMLElement,
        find: String,
        with replacement: String,
        limit: Int = .max,
        flavor: Flavor,
        mode: MatchMode = .exact
    ) throws -> Int {
        guard !find.isEmpty, limit > 0 else { return 0 }
        let ranges = matchRanges(of: find, in: text(of: paragraph), mode: mode, limit: limit)
        guard !ranges.isEmpty else { return 0 }
        try replace(in: paragraph, ranges: ranges, with: replacement, flavor: flavor)
        return ranges.count
    }

    /// Replace explicit UTF-16 ranges of the paragraph's joined text (as
    /// returned by `matchRanges` / `text(of:)`) with `replacement`. Ranges
    /// must be sorted and non-overlapping. Throws when a range crosses a
    /// tab/line-break element, or when `replacement` carries a newline the
    /// flavor can't express inside a run.
    static func replace(
        in paragraph: XMLElement,
        ranges: [Range<Int>],
        with replacement: String,
        flavor: Flavor
    ) throws {
        guard !ranges.isEmpty else { return }
        let pieces = pieces(in: paragraph)
        guard !pieces.isEmpty else { return }
        let replacement = stripInvalidXML(replacement)
        if replacement.contains("\n"), !flavor.needsSpacePreserve { throw ReplaceError.newlineUnsupported }

        // Segment texts; sentinels are one code unit each.
        var texts: [[UInt16]] = pieces.map { piece in
            if case .text(let e) = piece { return Array((e.stringValue ?? "").utf16) }
            return Array((piece.sentinel ?? "").utf16)
        }

        // Segment start offsets in the joined text.
        var starts: [Int] = []
        var running = 0
        for t in texts {
            starts.append(running)
            running += t.count
        }
        func isSentinel(_ index: Int) -> Bool {
            if case .text = pieces[index] { return false }
            return true
        }
        let sentinelPositions = pieces.indices.filter(isSentinel).map { starts[$0] }
        for range in ranges where sentinelPositions.contains(where: { range.contains($0) }) {
            throw ReplaceError.spansBreak
        }
        func locate(_ offset: Int, preferEnd: Bool) -> (segment: Int, index: Int) {
            for s in pieces.indices.reversed() where !isSentinel(s) {
                let lower = starts[s]
                let upper = lower + texts[s].count
                if preferEnd ? (offset > lower && offset <= upper) : (offset >= lower && offset < upper) {
                    return (s, offset - lower)
                }
            }
            let textIndices = pieces.indices.filter { !isSentinel($0) }
            return preferEnd
                ? (textIndices.last ?? 0, texts[textIndices.last ?? 0].count) : (textIndices.first ?? 0, 0)
        }

        let replacementUnits = Array(replacement.utf16)
        // Apply right to left so earlier offsets stay valid.
        for range in ranges.reversed() {
            let start = range.lowerBound
            let end = range.upperBound
            let (s0, i0) = locate(start, preferEnd: false)
            let (s1, i1) = locate(end, preferEnd: true)
            if s0 == s1 {
                texts[s0].replaceSubrange(i0..<i1, with: replacementUnits)
            } else {
                texts[s0].replaceSubrange(i0..<texts[s0].count, with: replacementUnits)
                if s0 + 1 < s1 {
                    for mid in (s0 + 1)..<s1 where !isSentinel(mid) { texts[mid] = [] }
                }
                texts[s1].removeSubrange(0..<i1)
            }
        }

        for (index, piece) in pieces.enumerated() {
            guard case .text(let element) = piece else { continue }
            let value = String(decoding: texts[index], as: UTF16.self)
            guard value != element.stringValue else { continue }
            if flavor.needsSpacePreserve, value.contains("\n") {
                // Word: a newline inside a run becomes `w:br` between `w:t`s.
                let lines = value.components(separatedBy: "\n")
                element.stringValue = lines[0]
                applySpacePreserve(element, lines[0])
                guard let run = element.parent as? XMLElement else { continue }
                var cursor: XMLNode = element
                for line in lines.dropFirst() {
                    let br = run.makeChild("br", uri: flavor.uri)
                    br.insertSibling(after: cursor)
                    let t = run.makeChild("t", uri: flavor.uri)
                    t.stringValue = line
                    applySpacePreserve(t, line)
                    t.insertSibling(after: br)
                    cursor = t
                }
                continue
            }
            element.stringValue = value
            if flavor.needsSpacePreserve {
                applySpacePreserve(element, value)
            }
        }
    }

    static func applySpacePreserve(_ element: XMLElement, _ value: String) {
        if value.first?.isWhitespace == true || value.last?.isWhitespace == true {
            element.setAttr("xml:space", "preserve", uri: "http://www.w3.org/XML/1998/namespace")
        }
    }

    /// Replace the paragraph's runs with one run carrying `text`, keeping the
    /// paragraph properties and the first run's formatting.
    static func setText(_ paragraph: XMLElement, _ text: String, flavor: Flavor) {
        let firstRun = paragraph.descendants("r").first
        let runProps = firstRun?.firstChild("rPr")?.deepCopy()
        for child in paragraph.elementChildren where !["pPr", "endParaRPr"].contains(child.local) {
            child.detach()
        }
        let text = stripInvalidXML(text)
        guard !text.isEmpty else { return }
        let run = paragraph.makeChild("r", uri: flavor.uri)
        if let runProps { run.addChild(runProps) }
        let t = run.makeChild("t", uri: flavor.uri)
        t.stringValue = text
        if flavor.needsSpacePreserve { applySpacePreserve(t, text) }
        run.addChild(t)
        if let end = paragraph.firstChild("endParaRPr") {
            paragraph.insertChild(run, at: end.index)
        } else {
            paragraph.addChild(run)
        }
    }

    /// Short single-line preview for structure listings.
    static func preview(_ text: String, max: Int = 160) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }
}

extension XMLNode {
    /// Insert `node` right after this node in its parent.
    func insertSibling(after node: XMLNode) {
        guard let parent = node.parent as? XMLElement else { return }
        parent.insertChild(self, at: node.index + 1)
    }

    /// Insert `node` right before this node in its parent.
    func insertSibling(before node: XMLNode) {
        guard let parent = node.parent as? XMLElement else { return }
        parent.insertChild(self, at: node.index)
    }
}
