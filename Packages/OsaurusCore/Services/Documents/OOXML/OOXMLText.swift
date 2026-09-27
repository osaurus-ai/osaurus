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
    static func occurrences(of find: String, in paragraph: XMLElement) -> Int {
        matchOffsets(of: Array(find.utf16), in: Array(text(of: paragraph).utf16)).count
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
        flavor: Flavor
    ) throws -> Int {
        guard !find.isEmpty, limit > 0 else { return 0 }
        let pieces = pieces(in: paragraph)
        guard !pieces.isEmpty else { return 0 }
        let replacement = stripInvalidXML(replacement)
        if replacement.contains("\n"), !flavor.needsSpacePreserve { throw ReplaceError.newlineUnsupported }

        // Segment texts; sentinels are one code unit each.
        var texts: [[UInt16]] = pieces.map { piece in
            if case .text(let e) = piece { return Array((e.stringValue ?? "").utf16) }
            return Array((piece.sentinel ?? "").utf16)
        }
        let joined = texts.flatMap { $0 }
        let needle = Array(find.utf16)
        let matches = matchOffsets(of: needle, in: joined, limit: limit)
        guard !matches.isEmpty else { return 0 }

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
        for start in matches where sentinelPositions.contains(where: { $0 >= start && $0 < start + needle.count }) {
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
        for start in matches.reversed() {
            let end = start + needle.count
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
        return matches.count
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
