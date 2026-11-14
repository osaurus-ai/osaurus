//
//  PPTXEditor.swift
//  osaurus
//
//  In-place presentation edits: find/replace across runs, setting a
//  slide's title/body/any text shape, and duplicating, deleting, or
//  reordering slides. Slide numbers follow the presentation's slide list
//  (what `file_read` structure mode shows).
//

import Foundation

struct PPTXEditor {
    struct SlideInfo {
        let part: String
        let relationshipId: String
        let element: XMLElement
    }

    let package: OOXMLPackage
    private(set) var summaries: [String] = []
    private(set) var warnings: [String] = []

    private let presentationPart: String
    private let a = OOXMLNamespace.drawing

    static let operations = ["replace_text", "set_slide_text", "duplicate_slide", "delete_slide", "reorder_slides"]
    static let slideContentType = "application/vnd.openxmlformats-officedocument.presentationml.slide+xml"

    init(package: OOXMLPackage) throws {
        self.package = package
        presentationPart = try package.mainPart()
        _ = try package.root(presentationPart)
    }

    mutating func apply(_ op: DocumentOperation) throws {
        switch op.name {
        case "replace_text": try replaceText(op)
        case "set_slide_text": try setSlideText(op)
        case "duplicate_slide": try duplicateSlide(op)
        case "delete_slide": try deleteSlide(op)
        case "reorder_slides": try reorderSlides(op)
        default:
            throw op.fail("unknown op for .pptx; use one of \(Self.operations.joined(separator: ", ")).")
        }
    }

    // MARK: - Structure

    private func slideList() throws -> XMLElement? {
        try package.root(presentationPart).firstChild("sldIdLst")
    }

    func slides() throws -> [SlideInfo] {
        guard let list = try slideList() else { return [] }
        return try list.childElements("sldId").compactMap { element in
            guard let rid = element.attr("r:id") ?? element.attr("id"),
                let part = try package.target(of: rid, from: presentationPart)
            else { return nil }
            return SlideInfo(part: part, relationshipId: rid, element: element)
        }
    }

    private func slide(_ op: DocumentOperation, key: String = "slide") throws -> (Int, SlideInfo) {
        let all = try slides()
        guard !all.isEmpty else { throw op.fail("the presentation has no slides.") }
        let number = try op.int(key)
        return (number, all[try op.position(number, of: all.count, noun: "slide")])
    }

    /// Shapes that carry text, in drawing order.
    static func textShapes(in slideRoot: XMLElement) -> [XMLElement] {
        slideRoot.descendants("sp").filter { $0.firstChild("txBody") != nil }
    }

    static func placeholderType(_ shape: XMLElement) -> String? {
        guard let ph = shape.firstChild("nvSpPr")?.firstChild("nvPr")?.firstChild("ph") else { return nil }
        return ph.attr("type") ?? "body"
    }

    static func shapeText(_ shape: XMLElement) -> String {
        (shape.firstChild("txBody")?.childElements("p") ?? []).map(OOXMLText.text(of:)).joined(separator: "\n")
    }

    // MARK: - Operations

    private mutating func replaceText(_ op: DocumentOperation) throws {
        let find = try op.string(op.has("find") ? "find" : "old_string")
        let replacement = try op.string(op.has("replace") ? "replace" : "new_string", allowEmpty: true)
        guard !find.contains("\n") else {
            throw op.fail("`old_string` can't span paragraphs; replace within one text line at a time.")
        }
        let all = op.bool("replace_all") || op.bool("all")
        var targets = try slides().enumerated().map { ($0.offset + 1, $0.element) }
        if op.has("slide") {
            let (number, info) = try slide(op)
            targets = [(number, info)]
        }
        guard find != replacement else {
            throw op.fail("`old_string` and `new_string` are identical; nothing to change.")
        }
        do {
            try replaceText(op, find: find, replacement: replacement, all: all, targets: targets)
        } catch let error as DocumentEditError where error.isMatchMiss {
            // Slide bullets are paragraph formatting (`a:buChar`), not text;
            // match without a leading marker and don't write one back.
            let strippedFind = DOCXEditor.strippingMarkdownSyntax(find)
            guard strippedFind.stripped else { throw error }
            let strippedReplacement = DOCXEditor.strippingMarkdownSyntax(replacement)
            do {
                try replaceText(op, find: strippedFind.text, replacement: strippedReplacement.text, all: all, targets: targets)
            } catch is DocumentEditError {
                throw error
            }
            summaries.append("Markdown syntax in `old_string` (list markers, heading hashes, emphasis) was treated as formatting — slides store it as paragraph and run styling, not text")
        }
    }

    private mutating func replaceText(
        _ op: DocumentOperation, find: String, replacement: String, all: Bool, targets: [(Int, SlideInfo)]
    ) throws {
        var paragraphs: [(slide: Int, part: String, paras: [XMLElement])] = []
        for (number, info) in targets {
            let paras = try package.root(info.part).descendants("p").filter { $0.uri == a || $0.name?.hasPrefix("a:") == true }
            paragraphs.append((number, info.part, paras))
        }
        // Match cascade: byte-for-byte first, then punctuation/whitespace
        // folded (PowerPoint autocorrects quotes and dashes too).
        var mode: OOXMLText.MatchMode = .exact
        var perSlide: [(slide: Int, hits: Int)] = []
        var total = 0
        for candidate in [OOXMLText.MatchMode.exact, .normalized] {
            perSlide = paragraphs.map { entry in
                (entry.slide, entry.paras.reduce(0) { $0 + OOXMLText.occurrences(of: find, in: $1, mode: candidate) })
            }
            total = perSlide.reduce(0) { $0 + $1.hits }
            mode = candidate
            if total > 0 { break }
        }
        guard total > 0 else {
            let allParas = paragraphs.flatMap(\.paras)
            var message = "\"\(OOXMLText.preview(find, max: 80))\" wasn't found on \(op.has("slide") ? "that slide" : "any slide")."
            let hint = DOCXEditor.closestParagraphHint(for: find, in: allParas)
            if !hint.isEmpty {
                message += hint.replacingOccurrences(of: "paragraph text is (paragraph", with: "slide text is (text line")
            }
            throw op.fail(message, isMatchMiss: true)
        }
        guard all || total == 1 else {
            let where_ = perSlide.filter { $0.hits > 0 }.map { "\($0.hits) on slide \($0.slide)" }.joined(separator: ", ")
            throw op.fail(
                "\"\(OOXMLText.preview(find, max: 80))\" appears \(total) times (\(where_)); add surrounding words, pass `slide`, or pass `replace_all: true`.")
        }
        var replaced = 0
        for (_, part, paras) in paragraphs {
            var changed = false
            for p in paras {
                let n: Int
                do {
                    n = try OOXMLText.replace(in: p, find: find, with: replacement, flavor: .drawing, mode: mode)
                } catch OOXMLText.ReplaceError.spansBreak {
                    throw op.fail(
                        "\"\(OOXMLText.preview(find, max: 80))\" runs across a line break on the slide; replace the text on each side of it separately.",
                        isMatchMiss: true)
                } catch OOXMLText.ReplaceError.newlineUnsupported {
                    throw op.fail("`new_string` can't contain line breaks on a slide; use set_slide_text to rewrite the shape's lines.")
                }
                if n > 0 { replaced += n; changed = true }
            }
            if changed { package.markDirty(part) }
        }
        var summary = "Replaced \(replaced) occurrence\(replaced == 1 ? "" : "s") of \"\(OOXMLText.preview(find, max: 60))\""
        if mode == .normalized {
            summary += " (matched with punctuation and whitespace normalized: the slide's own quotes/dashes differed from `old_string`)"
        }
        summaries.append(summary)
    }

    private mutating func setSlideText(_ op: DocumentOperation) throws {
        let (number, info) = try slide(op)
        let text = try op.string("text", allowEmpty: true)
        let root = try package.root(info.part)
        let shapes = Self.textShapes(in: root)
        let shape: XMLElement
        let label: String
        if let index = DocumentOperation.coerceInt(op.args["shape"]) {
            shape = shapes[try op.position(index, of: shapes.count, noun: "text shape")]
            label = "text shape \(index)"
        } else {
            let wanted = ((try op.optionalString("shape")) ?? "body").lowercased()
            let types: [String]
            switch wanted {
            case "title": types = ["title", "ctrTitle"]
            case "subtitle": types = ["subTitle"]
            case "body", "content": types = ["body", "obj"]
            default: throw op.fail("`shape` must be \"title\", \"subtitle\", \"body\", or a text shape number.")
            }
            guard let match = shapes.first(where: { Self.placeholderType($0).map(types.contains) ?? false }) else {
                let available = shapes.enumerated().map { i, s in
                    "\(i + 1)" + (Self.placeholderType(s).map { " (\($0))" } ?? "") + ": \"\(OOXMLText.preview(Self.shapeText(s), max: 40))\""
                }
                throw op.fail("slide \(number) has no \(wanted) placeholder. Pass `shape` as a number instead; text shapes: \(available.isEmpty ? "none" : available.joined(separator: "; ")).")
            }
            shape = match
            label = wanted
        }
        let isBody = !(["title", "ctrTitle", "subTitle"].contains(Self.placeholderType(shape) ?? ""))
        setText(text, in: shape, bulletLevels: isBody)
        package.markDirty(info.part)
        summaries.append("Set the \(label) text on slide \(number)")
    }

    private func setText(_ text: String, in shape: XMLElement, bulletLevels: Bool) {
        guard let body = shape.firstChild("txBody") else { return }
        let existing = body.childElements("p")
        let template = existing.first
        for p in existing { p.detach() }
        let lines = text.isEmpty ? [""] : text.components(separatedBy: "\n")
        for line in lines {
            var content = line
            var level = 0
            if bulletLevels {
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                level = min(8, indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2)
                content = String(line.dropFirst(indent.count))
                for marker in ["- ", "* ", "• "] where content.hasPrefix(marker) {
                    content = String(content.dropFirst(marker.count))
                    break
                }
            }
            let p = body.makeChild("p", uri: a)
            if let pPr = template?.firstChild("pPr")?.deepCopy() { p.addChild(pPr) }
            if bulletLevels {
                if level > 0 {
                    let pPr = p.firstChild("pPr") ?? {
                        let created = p.makeChild("pPr", uri: a)
                        p.insertChild(created, at: 0)
                        return created
                    }()
                    pPr.setAttr("lvl", String(level))
                } else {
                    p.firstChild("pPr")?.removeAttr("lvl")
                }
            }
            if !content.isEmpty {
                let r = p.makeChild("r", uri: a)
                if let rPr = template?.descendants("r").first?.firstChild("rPr")?.deepCopy() { r.addChild(rPr) }
                let t = r.makeChild("t", uri: a)
                t.stringValue = OOXMLText.stripInvalidXML(content)
                r.addChild(t)
                p.addChild(r)
            }
            if let end = template?.firstChild("endParaRPr")?.deepCopy() { p.addChild(end) }
            body.addChild(p)
        }
    }

    private mutating func duplicateSlide(_ op: DocumentOperation) throws {
        let (number, source) = try slide(op)
        var n = try slides().count + 1
        while package.has("ppt/slides/slide\(n).xml") { n += 1 }
        let part = "ppt/slides/slide\(n).xml"
        package.setData(part, try package.data(source.part))

        let sourceRels = OOXMLPackage.relsPath(for: source.part)
        var clonedParts = 0
        if package.has(sourceRels) {
            let rels = try OOXMLPackage.newXML(String(decoding: try package.data(sourceRels), as: UTF8.self))
            for rel in rels.rootElement()?.childElements("Relationship") ?? [] {
                guard let type = rel.attr("Type"), rel.attr("TargetMode") != "External", let target = rel.attr("Target") else { continue }
                // Speaker notes belong to exactly one slide; the copy starts without.
                if type == OOXMLRelationshipType.notesSlide {
                    rel.detach()
                    continue
                }
                // Charts, SmartArt and embedded objects are edited per
                // slide, so the copy gets its own parts instead of sharing
                // (a later edit to one slide's chart must not change the
                // other). Layouts, masters, themes and pictures stay shared.
                guard Self.isPerSlidePartType(type) else { continue }
                let original = OOXMLPackage.resolve(target, from: source.part)
                guard package.has(original) else { continue }
                let copy = try clonePart(original, cloned: &clonedParts)
                rel.setAttr("Target", OOXMLPackage.relativeTarget(from: part, to: copy))
            }
            package.setXML(OOXMLPackage.relsPath(for: part), rels)
        }
        try package.addOverride(part, contentType: Self.slideContentType)
        let rid = try package.addRelationship(from: presentationPart, type: OOXMLRelationshipType.slide, to: part)

        let list = try slideList()!
        let maxId = list.childElements("sldId").compactMap { Int($0.attr("id") ?? "") }.max() ?? 255
        let element = list.makeChild("sldId", uri: OOXMLNamespace.presentation)
        element.setAttr("id", String(max(256, maxId + 1)))
        element.insertSibling(after: source.element)
        element.setRelationshipId(rid)
        package.markDirty(presentationPart)
        summaries.append(
            "Duplicated slide \(number) as slide \(number + 1)"
                + (clonedParts > 0 ? " (with its own copy of \(clonedParts) chart/diagram part\(clonedParts == 1 ? "" : "s"))" : ""))
    }

    /// Relationship types whose targets are owned by a single slide.
    private static func isPerSlidePartType(_ type: String) -> Bool {
        let last = type.split(separator: "/").last.map(String.init) ?? ""
        return ["chart", "diagramData", "diagramLayout", "diagramQuickStyle", "diagramColors", "diagramDrawing", "oleObject", "package"]
            .contains(last)
            || last.hasPrefix("chart")  // chartUserShapes, chartStyle, chartColorStyle
    }

    /// Deep-copy a part (and, recursively, the per-part targets it owns:
    /// a chart's embedded workbook, style and colour parts) under a fresh
    /// name in the same folder. Content types follow the original.
    private func clonePart(_ original: String, cloned: inout Int) throws -> String {
        let copy = try freePartName(like: original)
        package.setData(copy, try package.data(original))
        let overrides = try package.root("[Content_Types].xml").childElements("Override")
        if let contentType = overrides.first(where: { $0.attr("PartName") == "/" + original })?.attr("ContentType") {
            try package.addOverride(copy, contentType: contentType)
        }
        cloned += 1
        let originalRels = OOXMLPackage.relsPath(for: original)
        guard package.has(originalRels) else { return copy }
        let rels = try OOXMLPackage.newXML(String(decoding: try package.data(originalRels), as: UTF8.self))
        for rel in rels.rootElement()?.childElements("Relationship") ?? [] {
            guard let type = rel.attr("Type"), rel.attr("TargetMode") != "External", let target = rel.attr("Target"),
                Self.isPerSlidePartType(type)
            else { continue }
            let nested = OOXMLPackage.resolve(target, from: original)
            guard package.has(nested) else { continue }
            let nestedCopy = try clonePart(nested, cloned: &cloned)
            rel.setAttr("Target", OOXMLPackage.relativeTarget(from: copy, to: nestedCopy))
        }
        package.setXML(OOXMLPackage.relsPath(for: copy), rels)
        return copy
    }

    /// `ppt/charts/chart2.xml` → `ppt/charts/chart<N>.xml` for the first free N.
    private func freePartName(like part: String) throws -> String {
        let url = URL(fileURLWithPath: "/" + part)
        let directory = url.deletingLastPathComponent().path.dropFirst()  // strip leading "/"
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let base = String(stem.reversed().drop(while: \.isNumber).reversed())
        guard !base.isEmpty else { throw DocumentEditError("Can't derive a name for a copy of '\(part)'.") }
        var n = 1
        while true {
            let candidate = "\(directory)/\(base)\(n)" + (ext.isEmpty ? "" : ".\(ext)")
            if !package.has(candidate) { return candidate }
            n += 1
        }
    }

    private mutating func deleteSlide(_ op: DocumentOperation) throws {
        let all = try slides()
        var numbers = try op.optionalInts("slides") ?? []
        if let single = try op.optionalInt("slide") { numbers.append(single) }
        guard !numbers.isEmpty else { throw op.fail("pass `slide` (or `slides`) to delete.") }
        let unique = Array(Set(numbers)).sorted()
        let doomed = try unique.map { all[try op.position($0, of: all.count, noun: "slide")] }
        guard doomed.count < all.count else { throw op.fail("that would delete every slide; keep at least one.") }
        var deletedIds: Set<String> = []
        var deletedRids: Set<String> = []
        for info in doomed {
            for rel in try package.relationships(of: info.part) where rel.type == OOXMLRelationshipType.notesSlide && !rel.external {
                let notes = OOXMLPackage.resolve(rel.target, from: info.part)
                if package.has(notes) { try package.removePart(notes) }
            }
            if let id = info.element.attr("id") { deletedIds.insert(id) }
            deletedRids.insert(info.relationshipId)
            info.element.detach()
            try package.removeRelationship(from: presentationPart, id: info.relationshipId)
            try package.removePart(info.part)
        }
        // Sections (p14:sectionLst) and custom shows keep their own slide
        // id lists; a stale entry makes PowerPoint show a repair prompt.
        let presentation = try package.root(presentationPart)
        let mainList = try slideList()
        for sldId in presentation.descendants("sldId") where sldId.parent !== mainList {
            if let id = sldId.attr("id"), deletedIds.contains(id) { sldId.detach() }
        }
        for show in presentation.descendants("custShow") {
            for sld in show.descendants("sld") {
                if let rid = sld.attr("r:id") ?? sld.attr("id"), deletedRids.contains(rid) { sld.detach() }
            }
            if show.descendants("sld").isEmpty { show.detach() }
        }
        if let shows = presentation.firstChild("custShowLst"), shows.childElements("custShow").isEmpty { shows.detach() }
        package.markDirty(presentationPart)
        summaries.append("Deleted slide\(unique.count == 1 ? "" : "s") \(unique.map(String.init).joined(separator: ", "))")
    }

    private mutating func reorderSlides(_ op: DocumentOperation) throws {
        let all = try slides()
        guard all.count > 1 else { throw op.fail("there's only one slide.") }
        let order = try op.permutation("order", count: all.count, noun: "slide")
        guard let list = try slideList() else { return }
        for info in all { info.element.detach() }
        for index in order { list.addChild(all[index].element) }
        package.markDirty(presentationPart)
        summaries.append("Reordered slides to \(order.map { String($0 + 1) }.joined(separator: ", "))")
    }
}
