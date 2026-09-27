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
        guard !find.contains("\n") else {
            throw op.fail("`old_string` can't span paragraphs; replace within one paragraph at a time.")
        }
        let all = op.bool("replace_all") || op.bool("all")
        var paragraphsByPart: [(String, [XMLElement])] = []
        var total = 0
        for part in try textParts() where package.has(part) {
            let paras = try package.root(part).descendants("p")
            let count = paras.reduce(0) { $0 + OOXMLText.occurrences(of: find, in: $1) }
            total += count
            paragraphsByPart.append((part, paras))
        }
        guard total > 0 else {
            throw op.fail("\"\(OOXMLText.preview(find, max: 80))\" wasn't found in the document text.")
        }
        guard all || total == 1 else {
            throw op.fail("\"\(OOXMLText.preview(find, max: 80))\" appears \(total) times; add surrounding words to `old_string`, or pass `all: true`.")
        }
        var replaced = 0
        for (part, paras) in paragraphsByPart {
            var changed = false
            for p in paras {
                let n: Int
                do {
                    n = try OOXMLText.replace(in: p, find: find, with: replacement, flavor: .word)
                } catch OOXMLText.ReplaceError.spansBreak {
                    throw op.fail(
                        "\"\(OOXMLText.preview(find, max: 80))\" runs across a tab or line break in the document; replace the text on each side of it separately.")
                }
                if n > 0 { changed = true; replaced += n }
            }
            if changed { package.markDirty(part) }
        }
        if replacement.contains("\n") {
            summaries.append("Line breaks in the replacement became soft line breaks (Shift+Enter)")
        }
        summaries.append("Replaced \(replaced) occurrence\(replaced == 1 ? "" : "s") of \"\(OOXMLText.preview(find, max: 60))\"")
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
